<#
.SYNOPSIS
    Hebrew voice dictation for Windows - one-command, no-admin setup.
.DESCRIPTION
    Installs Handy (free, open-source, local dictation) and the ivrit.ai
    Hebrew fine-tune of Whisper large-v3-turbo, then configures everything:
    Hebrew language lock, best available compute device (NVIDIA > AMD > Intel
    GPU > CPU), and Windows autostart. All speech recognition runs locally.

    Usage (normal PowerShell, no admin):
        irm "https://raw.githubusercontent.com/dewdad/hebrew-dictation/main/setup.ps1" | iex

    Idempotent: safe to re-run; skips components already installed.
.NOTES
    License: MIT. Model: Apache-2.0 (ivrit.ai / OpenAI Whisper).
    Everything installs per-user: %LOCALAPPDATA%\Handy, %APPDATA%\com.pais.handy
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$HandyRepo      = 'cjpais/Handy'
$ModelUrl       = 'https://huggingface.co/vladkens/ivrit-whisper-large-v3-turbo-gguf/resolve/main/ivrit-whisper-large-v3-turbo-Q8_0.gguf'
$ModelFileName  = 'ivrit-whisper-large-v3-turbo-Q8_0.gguf'
$ModelSha256    = 'da1f765ce2cfc495459fb3cc5deb2aaa2fa741eec79bff259b3da0481c4533ac'
$ModelId        = 'ivrit-whisper-large-v3-turbo-Q8_0'   # Handy custom-model id = filename stem

$HandyDir   = Join-Path $env:LOCALAPPDATA 'Handy'
$HandyExe   = Join-Path $HandyDir 'handy.exe'
$DataDir    = Join-Path $env:APPDATA 'com.pais.handy'
$ModelsDir  = Join-Path $DataDir 'models'
$SettingsFile = Join-Path $DataDir 'settings_store.json'

function Write-Step($msg)  { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    [!] $msg" -ForegroundColor Yellow }

if ($PSVersionTable.PSVersion.Major -lt 5) { throw 'PowerShell 5.1 or newer is required.' }
if (-not $env:LOCALAPPDATA) { throw 'This script must run as a normal interactive user (not SYSTEM).' }

Write-Host 'Hebrew Dictation Setup - Handy + ivrit.ai Whisper (local, no admin)' -ForegroundColor White

# ---------------------------------------------------------------------------
# 1. Stop any running Handy so files/settings are not locked
# ---------------------------------------------------------------------------
Get-Process handy -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 800

# ---------------------------------------------------------------------------
# 2. Install Handy (per-user NSIS silent install, no admin, no winget needed)
# ---------------------------------------------------------------------------
Write-Step 'Checking Handy installation'
if (Test-Path $HandyExe) {
    Write-Ok "Handy already installed: $HandyExe"
} else {
    Write-Host '    Fetching latest Handy release info...'
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$HandyRepo/releases/latest" -Headers @{ 'User-Agent' = 'hebrew-dictation-setup' }
    $asset = $release.assets | Where-Object { $_.name -like '*x64-setup.exe' } | Select-Object -First 1
    if (-not $asset) { throw "Could not find a Windows x64 installer in the latest $HandyRepo release." }

    $installerPath = Join-Path $env:TEMP $asset.name
    Write-Host "    Downloading $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) MB)..."
    & curl.exe -L --retry 3 --retry-delay 2 -sS -o $installerPath $asset.browser_download_url
    if ($LASTEXITCODE -ne 0) { throw "Installer download failed (curl exit $LASTEXITCODE)." }

    Write-Host '    Installing silently (per-user)...'
    $p = Start-Process -FilePath $installerPath -ArgumentList '/S' -Wait -PassThru
    Remove-Item $installerPath -ErrorAction SilentlyContinue
    if (-not (Test-Path $HandyExe)) { throw "Handy installer finished (exit $($p.ExitCode)) but handy.exe was not found at $HandyExe." }
    Write-Ok "Handy $($release.tag_name) installed"
    # The installer may leave a first-run process behind; keep things controlled.
    Get-Process handy -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 800
}

# ---------------------------------------------------------------------------
# 3. Download the ivrit.ai Hebrew Whisper model (sha256-verified, resumable)
# ---------------------------------------------------------------------------
Write-Step 'Checking Hebrew speech model (ivrit.ai Whisper large-v3-turbo, Q8_0)'
New-Item -ItemType Directory -Path $ModelsDir -Force | Out-Null
$modelPath = Join-Path $ModelsDir $ModelFileName

$needDownload = $true
if (Test-Path $modelPath) {
    $h = (Get-FileHash $modelPath -Algorithm SHA256).Hash.ToLower()
    if ($h -eq $ModelSha256) {
        Write-Ok 'Model already present and hash-verified'
        $needDownload = $false
    } else {
        Write-Warn2 'Existing model file failed hash check - re-downloading'
        Remove-Item $modelPath -Force
    }
}
if ($needDownload) {
    Write-Host '    Downloading ~886 MB from Hugging Face (resumable)...'
    & curl.exe -L --retry 3 --retry-delay 2 -C - -o $modelPath $ModelUrl
    if ($LASTEXITCODE -ne 0) { throw "Model download failed (curl exit $LASTEXITCODE). Re-run the script to resume." }
    $h = (Get-FileHash $modelPath -Algorithm SHA256).Hash.ToLower()
    if ($h -ne $ModelSha256) {
        Remove-Item $modelPath -Force
        throw 'Model hash mismatch after download. Re-run the script to try again.'
    }
    Write-Ok 'Model downloaded and hash-verified'
}

# ---------------------------------------------------------------------------
# 4. Pick the best compute device dynamically
#    Ranking: NVIDIA > AMD > Intel; discrete GPUs (PCI bus > 0) before iGPUs.
#    Handy pins Vulkan GPUs by PCI id (domain:bus:device.function).
# ---------------------------------------------------------------------------
Write-Step 'Selecting compute device'
$accelerator = 'cpu'
$gpuDevice   = $null
$gpuLabel    = 'CPU (no usable GPU found)'

$vulkanLoader = Test-Path (Join-Path $env:SystemRoot 'System32\vulkan-1.dll')
if (-not $vulkanLoader) {
    Write-Warn2 'vulkan-1.dll not found - GPU acceleration unavailable, using CPU.'
    Write-Warn2 'Install the latest GPU driver (or Vulkan runtime) and re-run to enable GPU.'
} else {
    $candidates = @()
    $gpus = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPDeviceID -like 'PCI\VEN_*' -and $_.ConfigManagerErrorCode -eq 0 }
    foreach ($g in $gpus) {
        if ($g.Name -match 'Virtual|Basic Render|Remote|DisplayLink|USB Display|VITURE|Meta |Oculus|Parallels|VMware|Hyper-V') { continue }
        $vendorScore = 0
        if ($g.PNPDeviceID -match 'VEN_10DE') { $vendorScore = 300 }        # NVIDIA
        elseif ($g.PNPDeviceID -match 'VEN_1002|VEN_1022') { $vendorScore = 200 } # AMD
        elseif ($g.PNPDeviceID -match 'VEN_8086') { $vendorScore = 100 }   # Intel
        if ($vendorScore -eq 0) { continue }

        $bus = 0; $dev = 0; $fn = 0; $domain = 0; $havePci = $false
        try {
            $locInfo = (Get-PnpDeviceProperty -InstanceId $g.PNPDeviceID -KeyName 'DEVPKEY_Device_LocationInfo' -ErrorAction Stop).Data
            if ($locInfo -match 'PCI bus (\d+), device (\d+), function (\d+)') {
                $bus = [int]$Matches[1]; $dev = [int]$Matches[2]; $fn = [int]$Matches[3]; $havePci = $true
            }
            $locPaths = (Get-PnpDeviceProperty -InstanceId $g.PNPDeviceID -KeyName 'DEVPKEY_Device_LocationPaths' -ErrorAction SilentlyContinue).Data
            if ($locPaths) {
                $first = @($locPaths)[0]
                if ($first -match 'PCIROOT\((\d+)\)') { $domain = [int]$Matches[1] }
            }
        } catch { }

        $candidates += [pscustomobject]@{
            Name   = $g.Name
            Score  = $vendorScore + $(if ($bus -gt 0) { 50 } else { 0 })
            PciId  = $(if ($havePci) { '{0:x4}:{1:x2}:{2:x2}.{3:x}' -f $domain, $bus, $dev, $fn } else { $null })
        }
    }
    $best = $candidates | Sort-Object Score -Descending | Select-Object -First 1
    if ($best) {
        $accelerator = 'gpu'
        $gpuDevice   = $best.PciId
        $gpuLabel    = $best.Name
        if ($gpuDevice) { $gpuLabel += " (Vulkan, PCI $gpuDevice)" } else { $gpuLabel += ' (Vulkan, auto device)' }
    } else {
        Write-Warn2 'No supported GPU detected - using CPU.'
    }
}
Write-Ok "Compute: $gpuLabel"

# ---------------------------------------------------------------------------
# 5. Configure Handy settings (create via first launch if needed, then patch)
# ---------------------------------------------------------------------------
Write-Step 'Configuring Handy for Hebrew'
if (-not (Test-Path $SettingsFile)) {
    Write-Host '    First run: generating default settings...'
    Start-Process $HandyExe
    $waited = 0
    while (-not (Test-Path $SettingsFile) -and $waited -lt 30) { Start-Sleep 1; $waited++ }
    Get-Process handy -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 800
    if (-not (Test-Path $SettingsFile)) { throw "Handy did not create its settings file at $SettingsFile." }
}

$cfg = Get-Content $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
$cfg.settings.selected_model        = $ModelId
$cfg.settings.selected_language     = 'he'
$cfg.settings.spoken_languages      = @('he')
$cfg.settings.translate_to_english  = $false
$cfg.settings.autostart_enabled     = $true
$cfg.settings.onboarding_completed  = $true
$cfg.settings.start_hidden          = $true
$cfg.settings.transcribe_accelerator = $accelerator
$cfg.settings.transcribe_gpu_device  = $gpuDevice

$json = $cfg | ConvertTo-Json -Depth 30
[IO.File]::WriteAllText($SettingsFile, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Ok "Model: $ModelId | Language: Hebrew | Accelerator: $accelerator"

# ---------------------------------------------------------------------------
# 6. Start Handy and verify
# ---------------------------------------------------------------------------
Write-Step 'Starting Handy'
Start-Process $HandyExe
$waited = 0
while (-not (Get-Process handy -ErrorAction SilentlyContinue) -and $waited -lt 15) { Start-Sleep 1; $waited++ }
if (-not (Get-Process handy -ErrorAction SilentlyContinue)) { throw 'Handy failed to start.' }

# Confirm settings survived app startup (app rewrites the store on launch).
Start-Sleep 3
$check = Get-Content $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
if ($check.settings.selected_model -ne $ModelId) { throw "Settings verification failed: selected_model is '$($check.settings.selected_model)'." }
Write-Ok 'Handy running in the system tray with the Hebrew model selected'

Write-Host @'

============================================================
  Hebrew dictation is ready.

  How to use:
    1. Click into any text field (any app).
    2. HOLD Ctrl+Space, speak Hebrew, release -> text appears.
       (Quick tap = toggle hands-free mode. Esc = cancel.)
    3. First dictation loads the model (a few seconds);
       after that it is fast. Everything stays on this PC.

  Notes:
    - The ivrit.ai model is Hebrew-specialized. For other
      languages, add a stock Whisper model in Handy settings.
    - Settings: right-click the Handy tray icon.
    - Re-run this script any time to repair/update the setup.
============================================================
'@ -ForegroundColor Green