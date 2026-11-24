<#
.SYNOPSIS
    Hebrew voice dictation for Windows - one-command setup.
.DESCRIPTION
    Installs Handy (free, open-source, local dictation) and the ivrit.ai Hebrew
    fine-tune of Whisper large-v3-turbo, then configures everything: Hebrew
    language lock, best available compute device (NVIDIA > AMD > Intel GPU >
    CPU), Windows autostart. All speech recognition runs locally.

    Per-user install (no admin):
        irm "https://raw.githubusercontent.com/dewdad/hebrew-dictation/main/setup.ps1" | iex

    Machine-wide install (prompts for administrator rights):
        irm "https://raw.githubusercontent.com/dewdad/hebrew-dictation/main/setup-machine.ps1" | iex

    Other switches: -Uninstall (remove Handy, keeps data) and -Uninstall -Purge
    (also delete settings, history and the model).

    Idempotent: safe to re-run; skips anything that is already in place.
.NOTES
    License: MIT. Model: Apache-2.0 (ivrit.ai / OpenAI Whisper).
#>
param(
    [switch]$MachineWide,
    [switch]$Uninstall,
    [switch]$Purge,
    [string]$InstallRoot
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$ScriptUrl      = 'https://raw.githubusercontent.com/dewdad/hebrew-dictation/main/setup.ps1'
$HandyRepo      = 'cjpais/Handy'
$HandyFallback  = 'https://github.com/cjpais/Handy/releases/download/v0.10.2/Handy_0.10.2_x64-setup.exe'
$ModelUrl       = 'https://huggingface.co/vladkens/ivrit-whisper-large-v3-turbo-gguf/resolve/main/ivrit-whisper-large-v3-turbo-Q8_0.gguf'
$ModelFileName  = 'ivrit-whisper-large-v3-turbo-Q8_0.gguf'
$ModelSha256    = 'da1f765ce2cfc495459fb3cc5deb2aaa2fa741eec79bff259b3da0481c4533ac'
$ModelSize      = 886381920
$ModelId        = 'ivrit-whisper-large-v3-turbo-Q8_0'   # Handy custom-model id = filename stem

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
function Write-Step($msg)  { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Note($msg)  { Write-Host "    [!] $msg" -ForegroundColor Yellow }

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
# Downloads (curl: resumable, retrying, with a progress bar)
# ---------------------------------------------------------------------------
function Resolve-Curl {
    $sys = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path $sys) { return $sys }
    $c = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

function Start-Curl($Url, $OutFile, [switch]$Silent) {
    $curl = Resolve-Curl
    if (-not $curl) { return $null }
    $progress = if ($Silent) { '-s' } else { '--progress-bar' }   # silent for the background download
    # curl retries transient failures only (timeouts, 5xx); the caller resumes anything else.
    $a = @('-L', '--fail', $progress, '--retry', '5', '--retry-delay', '2',
           '--speed-limit', '2048', '--speed-time', '30', '-C', '-',
           '-o', ('"{0}"' -f $OutFile), ('"{0}"' -f $Url))
    $p = Start-Process -FilePath $curl -ArgumentList $a -NoNewWindow -PassThru
    $null = $p.Handle   # required for ExitCode to be populated later
    return $p
}

# Single in-place progress line for a download running in the background.
function Wait-WithProgress($Process, $OutFile, $TotalBytes) {
    if (-not $Process) { return }
    $last = -1
    while (-not $Process.WaitForExit(500)) {
        $len = 0
        if (Test-Path -LiteralPath $OutFile) { $len = (Get-Item -LiteralPath $OutFile).Length }
        $pct = [int](100 * $len / $TotalBytes); if ($pct -gt 100) { $pct = 100 }
        if ($pct -ne $last) {
            $last = $pct
            Write-Host ("`r    {0,5:N0} MB of {1:N0} MB  ({2,3}%)   " -f ($len / 1MB), ($TotalBytes / 1MB), $pct) -NoNewline
        }
    }
    Write-Host ''
}

function Wait-Curl($Process, $Url, $OutFile, $What, [switch]$AllowPartial) {
    if (-not $Process) {
        # No curl.exe on this machine: plain download, no resume
        Write-Note 'curl.exe not found - using Invoke-WebRequest (no resume)'
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
        return
    }
    $Process.WaitForExit()
    if (Test-Path -LiteralPath $OutFile) {
        if ($Process.ExitCode -eq 0) { return }
        if ($AllowPartial) { return }   # caller checks the hash and resumes if needed
    }
    $hint = switch ($Process.ExitCode) {
        6  { ' - no network connection or DNS failure' }
        7  { ' - could not connect to the server' }
        22 { ' - the server returned an HTTP error' }
        28 { ' - timed out' }
        35 { ' - secure connection (TLS) failed' }
        56 { ' - the connection was reset' }
        default { '' }
    }
    throw "Download failed (curl exit $($Process.ExitCode)$hint): $What"
}

# Downloads a file until its size and SHA256 match. Safe to re-run at any
# point: an interrupted download resumes instead of starting over.
function Get-VerifiedDownload($Url, $OutFile, $Sha256, $ExpectedSize, $What) {
    $attempts = 0
    while ($true) {
        if (Test-Path -LiteralPath $OutFile) {
            $len = (Get-Item -LiteralPath $OutFile).Length
            if ($len -eq $ExpectedSize) {
                if ((Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash -eq $Sha256) { return }
                Write-Note "$What is complete but corrupt - downloading again"
            }
            if ($len -ge $ExpectedSize) { Remove-Item -LiteralPath $OutFile -Force }
        }
        $attempts++
        if ($attempts -gt 4) { throw "Could not download $What after several attempts. Check your connection and re-run the script (it resumes)." }
        if ($attempts -gt 1) { Write-Note "Retry $attempts/4 ..."; Start-Sleep -Seconds (2 * $attempts) }
        $proc = Start-Curl $Url $OutFile
        Wait-Curl $proc $Url $OutFile $What -AllowPartial
        if ($proc -and $proc.ExitCode -eq 33 -and (Test-Path -LiteralPath $OutFile)) { Remove-Item -LiteralPath $OutFile -Force }   # server refused to resume: start clean
    }
}

# ---------------------------------------------------------------------------
# Handy process helpers
# ---------------------------------------------------------------------------
function Stop-Handy {
    $procs = @(Get-Process -Name handy -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0) {
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        $procs | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
    }
}

# Runs a headless Handy command and returns its stdout (Handy logs to stderr).
function Invoke-HandyCli($HandyExe, [string[]]$CliArgs) {
    $out = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $HandyExe -ArgumentList $CliArgs -NoNewWindow -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError ($out + '.err')
        $null = $p.Handle
        if ($p.ExitCode -ne 0) { throw "Handy reported exit code $($p.ExitCode) for: handy $($CliArgs -join ' ')" }
        return (Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue)
    } finally {
        Remove-Item -LiteralPath $out, ($out + '.err') -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Install layout
# ---------------------------------------------------------------------------
function Get-Layout {
    if ($MachineWide) {
        $root = $InstallRoot
        if (-not $root) { $root = Join-Path $env:ProgramFiles 'Handy' }
        $root = $root.TrimEnd('\')
        if ($root -match '^[A-Za-z]:$') { throw '-InstallRoot must be a folder, not a drive root.' }
        $data = Join-Path $root 'Data'
        return [pscustomobject]@{
            Scope       = 'machine-wide'
            HandyDir    = $root
            HandyExe    = (Join-Path $root 'handy.exe')
            DataDir     = $data
            ModelsDir   = (Join-Path $data 'models')
            Settings    = (Join-Path $data 'settings_store.json')
            RunKey      = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
            Shortcut    = (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Handy.lnk')
        }
    }
    $data = Join-Path $env:APPDATA 'com.pais.handy'
    return [pscustomobject]@{
        Scope       = 'per-user'
        HandyDir    = (Join-Path $env:LOCALAPPDATA 'Handy')
        HandyExe    = (Join-Path $env:LOCALAPPDATA 'Handy\handy.exe')
        DataDir     = $data
        ModelsDir   = (Join-Path $data 'models')
        Settings    = (Join-Path $data 'settings_store.json')
        RunKey      = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        Shortcut    = $null
    }
}

function Get-HandyInstaller {
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $name = $null; $url = $null; $fallback = $false
    $assetPattern = '*_x64-setup.exe'
    if ($arch -eq 'ARM64') { $assetPattern = '*_arm64-setup.exe' }
    for ($i = 1; $i -le 3; $i++) {
        try {
            $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$HandyRepo/releases/latest" -Headers @{ 'User-Agent' = 'hebrew-dictation-setup' } -TimeoutSec 20
            $asset = $rel.assets | Where-Object { $_.name -like $assetPattern } | Select-Object -First 1
            if (-not $asset -and $arch -eq 'ARM64') { $asset = $rel.assets | Where-Object { $_.name -like '*_x64-setup.exe' } | Select-Object -First 1 }
            if ($asset) { $url = $asset.browser_download_url; $name = $asset.name; $version = $rel.tag_name; break }
        } catch { }
        Start-Sleep -Seconds 2
    }
    if (-not $url) {
        Write-Note 'GitHub release lookup failed - using the pinned Handy v0.10.2 download'
        $url = $HandyFallback; $name = 'Handy_0.10.2_x64-setup.exe'; $version = 'v0.10.2'; $fallback = $true
    }
    return [pscustomobject]@{ Name = $name; Url = $url; Version = $version; FromFallback = $fallback }
}

function Get-InstalledHandyVersion($HandyExe) {
    $v = (Get-Item -LiteralPath $HandyExe).VersionInfo.ProductVersion
    if (-not $v) { $v = (Get-Item -LiteralPath $HandyExe).VersionInfo.FileVersion }
    $v = ([string]$v).Trim().TrimStart('v')
    if ($v -match '^\d+\.\d+\.\d+$') { return $v }
    return $null   # unknown: never treat as outdated
}

function Install-Handy($Layout, $Installer, $Version) {
    if ($Layout.Scope -eq 'machine-wide') {
        # Portable layout: no registry, no uninstaller, all data in <root>\Data.
        # /D= must come last, unquoted, even when the path contains spaces.
        $p = Start-Process -FilePath $Installer -ArgumentList ('/S /PORTABLE /D=' + $Layout.HandyDir) -Wait -PassThru
    } else {
        $p = Start-Process -FilePath $Installer -ArgumentList '/S' -Wait -PassThru
    }
    $null = $p.Handle
    if ($p.ExitCode -ne 0) { throw "The Handy installer exited with code $($p.ExitCode)." }
    if (-not (Test-Path -LiteralPath $Layout.HandyExe)) { throw "The Handy installer finished but handy.exe was not found at $($Layout.HandyExe)." }
    Write-Ok "Handy $Version installed ($($Layout.Scope))"
}

# ---------------------------------------------------------------------------
# Compute device: NVIDIA > AMD > Intel GPU, then CPU. Discrete cards on a
# higher PCIe bus beat integrated GPUs within the same vendor.
# ---------------------------------------------------------------------------
function Select-ComputeDevice {
    $result = [pscustomobject]@{ Accelerator = 'cpu'; Device = $null; Label = 'CPU' }
    if (-not (Test-Path (Join-Path $env:SystemRoot 'System32\vulkan-1.dll'))) {
        Write-Note 'Vulkan is not available on this PC - using the CPU (install the latest GPU driver to enable GPU acceleration)'
        return $result
    }
    $candidates = @()
    $gpus = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
        Where-Object { $_.PNPDeviceID -like 'PCI\VEN_*' -and $_.ConfigManagerErrorCode -eq 0 }
    foreach ($g in $gpus) {
        if ($g.Name -match 'Virtual|Basic Render|Remote|DisplayLink|USB Display|VITURE|Oculus|Parallels|VMware|Hyper-V') { continue }
        $vendorScore = 0
        if     ($g.PNPDeviceID -match 'VEN_10DE')            { $vendorScore = 300 }  # NVIDIA
        elseif ($g.PNPDeviceID -match 'VEN_1002|VEN_1022')   { $vendorScore = 200 }  # AMD
        elseif ($g.PNPDeviceID -match 'VEN_8086')            { $vendorScore = 100 }  # Intel
        if ($vendorScore -eq 0) { continue }

        $pci = $null
        $onOwnBus = $false
        try {
            $loc = (Get-PnpDeviceProperty -InstanceId $g.PNPDeviceID -KeyName 'DEVPKEY_Device_LocationInfo' -ErrorAction Stop).Data
            if ($loc -match 'PCI bus (\d+), device (\d+), function (\d+)') {
                $bus = [int]$Matches[1]; $dev = [int]$Matches[2]; $fn = [int]$Matches[3]
                $onOwnBus = ($bus -gt 0)
                $domain = 0
                $paths = (Get-PnpDeviceProperty -InstanceId $g.PNPDeviceID -KeyName 'DEVPKEY_Device_LocationPaths' -ErrorAction SilentlyContinue).Data
                if ($paths) { $first = @($paths)[0]; if ($first -match 'PCIROOT\((\d+)\)') { $domain = [int]$Matches[1] } }
                # Vulkan / ggml device id = domain:bus:device.function
                $pci = '{0:x4}:{1:x2}:{2:x2}.{3:x}' -f $domain, $bus, $dev, $fn
            }
        } catch { }
        # Discrete GPUs sit on their own PCIe bus; integrated GPUs share bus 0.
        $candidates += [pscustomobject]@{ Name = $g.Name; Score = ($vendorScore + [int]$onOwnBus); Pci = $pci }
    }
    $best = $candidates | Sort-Object Score -Descending | Select-Object -First 1
    if (-not $best) { Write-Note 'No supported GPU detected - using the CPU'; return $result }
    $result.Accelerator = 'gpu'
    $result.Device = $best.Pci
    if ($best.Pci) { $result.Label = "$($best.Name) (Vulkan, $($best.Pci))" } else { $result.Label = "$($best.Name) (Vulkan)" }
    return $result
}

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
function Set-JsonProp($Obj, $Name, $Value) {
    if ($Obj.PSObject.Properties[$Name]) { $Obj.$Name = $Value }
    else { Add-Member -InputObject $Obj -MemberType NoteProperty -Name $Name -Value $Value }
}

function Initialize-HandySettings($HandyExe, $SettingsFile) {
    if (Test-Path -LiteralPath $SettingsFile) { return }
    Write-Host '    First run: letting Handy generate its default settings...'
    Start-Process -FilePath $HandyExe -ArgumentList '--start-hidden' | Out-Null
    $waited = 0
    while ($waited -lt 40) {
        Start-Sleep -Milliseconds 500; $waited += 0.5
        if (Test-Path -LiteralPath $SettingsFile) {
            try { $null = Get-Content -LiteralPath $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json; break } catch { }  # wait for a complete write
        }
    }
    Stop-Handy
    if (-not (Test-Path -LiteralPath $SettingsFile)) { throw "Handy did not create its settings file at $SettingsFile." }
}

function Set-HandySettings($Layout, $ModelId, $Compute) {
    $cfg = Get-Content -LiteralPath $Layout.Settings -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $cfg.settings) { throw "Unexpected settings file format in $($Layout.Settings)." }
    $s = $cfg.settings
    Set-JsonProp $s 'selected_model'         $ModelId
    Set-JsonProp $s 'selected_language'      'he'
    Set-JsonProp $s 'spoken_languages'       @('he')
    Set-JsonProp $s 'translate_to_english'   $false
    Set-JsonProp $s 'onboarding_completed'   $true
    Set-JsonProp $s 'start_hidden'           $true
    Set-JsonProp $s 'transcribe_accelerator' $Compute.Accelerator
    Set-JsonProp $s 'transcribe_gpu_device'  $Compute.Device
    Set-JsonProp $s 'model_unload_timeout'   'min15'   # keep the model warm for back-to-back dictation
    if ($Layout.Scope -eq 'machine-wide') {
        # Autostart is registered machine-wide below. The shared Data folder must
        # not accumulate one user's recordings and transcripts for others to read.
        Set-JsonProp $s 'autostart_enabled'          $false
        Set-JsonProp $s 'recording_retention_period' 'preserve_limit'
        Set-JsonProp $s 'history_limit'              0
    } else {
        Set-JsonProp $s 'autostart_enabled'          $true
    }
    $tmp = $Layout.Settings + '.tmp'
    [IO.File]::WriteAllText($tmp, ($cfg | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Layout.Settings -Force
    Write-Ok "Model: $ModelId | Language: Hebrew | Accelerator: $($Compute.Label)"
}

function Start-Handy($Layout) {
    if ($Layout.Scope -eq 'machine-wide' -and (Test-IsAdmin)) {
        # Launch as the signed-in desktop user, not elevated.
        Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList ('"{0}"' -f $Layout.HandyExe) | Out-Null
    } else {
        Start-Process -FilePath $Layout.HandyExe | Out-Null
    }
    $waited = 0
    while (-not (Get-Process -Name handy -ErrorAction SilentlyContinue) -and $waited -lt 15) { Start-Sleep -Milliseconds 500; $waited += 0.5 }
    Start-Sleep -Seconds 2
    if (-not (Get-Process -Name handy -ErrorAction SilentlyContinue)) { throw 'Handy started but exited immediately. Check the Handy log next to the settings file.' }
}

# ---------------------------------------------------------------------------
# Autostart / shortcut
# ---------------------------------------------------------------------------
function Set-Autostart($Layout) {
    # start_hidden in the settings file makes Handy launch into the notification area.
    Set-ItemProperty -Path $Layout.RunKey -Name 'Handy' -Value ('"{0}"' -f $Layout.HandyExe)
    Write-Ok "Starts with Windows ($($Layout.Scope))"
}

function Remove-Autostart($Layout) {
    if (Get-ItemProperty -Path $Layout.RunKey -Name 'Handy' -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $Layout.RunKey -Name 'Handy' -ErrorAction SilentlyContinue
    }
}

function Set-StartMenuShortcut($Layout) {
    $dir = Split-Path -Parent $Layout.Shortcut
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($Layout.Shortcut)
    $lnk.TargetPath = $Layout.HandyExe
    $lnk.WorkingDirectory = $Layout.HandyDir
    $lnk.IconLocation = $Layout.HandyExe
    $lnk.Save()
    Write-Ok 'Start Menu shortcut created for all users'
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
function Invoke-Install {
    $layout = Get-Layout
    Write-Host "Hebrew Dictation Setup - Handy + ivrit.ai Whisper (local, $($layout.Scope))" -ForegroundColor White
    if ($PSVersionTable.PSVersion.Major -lt 5) { throw 'PowerShell 5.1 or newer is required.' }
    if (-not $env:LOCALAPPDATA) { throw 'This script must run as a normal interactive user (not SYSTEM).' }
    if ($layout.Scope -eq 'machine-wide' -and -not (Test-IsAdmin)) { throw 'Machine-wide install requires administrator rights.' }

    Stop-Handy
    $other = $null
    if ($layout.Scope -eq 'per-user') { $other = Join-Path $env:ProgramFiles 'Handy\handy.exe' }
    elseif (Test-Path (Join-Path $env:LOCALAPPDATA 'Handy\handy.exe')) { $other = Join-Path $env:LOCALAPPDATA 'Handy\handy.exe' }
    if ($other -and (Test-Path -LiteralPath $other)) {
        Write-Note "Another Handy is installed at $other. Two copies mean two tray icons - uninstall the one you do not want (setup.ps1 -Uninstall, or -Uninstall -MachineWide)."
    }

    # Kick off the model download in the background while Handy is installed.
    $modelPath = Join-Path $layout.ModelsDir $ModelFileName
    $modelProc = $null
    $modelReady = $false
    New-Item -ItemType Directory -Path $layout.ModelsDir -Force | Out-Null
    Write-Step 'Hebrew model (ivrit.ai Whisper large-v3-turbo, Q8_0)'
    if ((Test-Path -LiteralPath $modelPath) -and ((Get-Item -LiteralPath $modelPath).Length -eq $ModelSize) -and ((Get-FileHash -LiteralPath $modelPath -Algorithm SHA256).Hash -eq $ModelSha256)) {
        $modelReady = $true
        Write-Ok 'Already downloaded and hash-verified'
    } else {
        Write-Host '    Downloading ~886 MB in the background (resumable)...'
        $modelProc = Start-Curl $ModelUrl $modelPath -Silent
    }

    Write-Step 'Checking Handy installation'
    $installed = $null
    if (Test-Path -LiteralPath $layout.HandyExe) { $installed = Get-InstalledHandyVersion $layout.HandyExe }
    $rel = $null
    $needInstall = $true
    if ($installed) {
        $rel = Get-HandyInstaller
        $latest = $rel.Version.TrimStart('v')
        if ($rel.FromFallback -or $latest -eq $installed) {
            Write-Ok "Handy $installed already installed and up to date"
            $needInstall = $false
        } else {
            Write-Host "    Updating Handy $installed -> $latest"
        }
    }
    if ($needInstall) {
        if (-not $rel) { $rel = Get-HandyInstaller }
        $installerPath = Join-Path $env:TEMP $rel.Name
        Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue   # never resume a stale installer
        Write-Host "    Downloading $($rel.Name)..."
        Wait-Curl (Start-Curl $rel.Url $installerPath) $rel.Url $installerPath 'the Handy installer'
        if (-not (Test-Path -LiteralPath $installerPath)) { throw 'The Handy installer could not be downloaded.' }
        Install-Handy $layout $installerPath $rel.Version
        Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
        Stop-Handy
    }
    if ($layout.Scope -eq 'machine-wide') {
        New-Item -ItemType Directory -Path $layout.DataDir -Force | Out-Null
        if (-not (Test-Path -LiteralPath (Join-Path $layout.HandyDir 'portable'))) {
            throw "Handy was not installed in self-contained mode at $($layout.HandyDir). Run the setup again to repair."
        }
        # Let standard users write settings/logs inside Program Files (Data only).
        & icacls.exe $layout.DataDir /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not open $($layout.DataDir) for write access by all users." }
    }

    Write-Step 'Selecting compute device'
    $compute = Select-ComputeDevice
    Write-Ok "Compute: $($compute.Label)"

    Write-Step 'Configuring Handy for Hebrew'
    Initialize-HandySettings $layout.HandyExe $layout.Settings
    Set-HandySettings $layout $ModelId $compute

    if (-not $modelReady) {
        Write-Step 'Waiting for the Hebrew model download'
        Wait-WithProgress $modelProc $modelPath $ModelSize
        Wait-Curl $modelProc $ModelUrl $modelPath 'the Hebrew model' -AllowPartial
        Get-VerifiedDownload $ModelUrl $modelPath $ModelSha256 $ModelSize 'the Hebrew model'
        Write-Ok 'Model downloaded and hash-verified'
    }

    Write-Step 'Verifying'
    $list = Invoke-HandyCli $layout.HandyExe @('--list-models')
    if (-not ($list -match [regex]::Escape($ModelId))) { throw 'Handy does not see the Hebrew model.' }
    Write-Ok "Handy lists the Hebrew model ($ModelId)"
    $check = Get-Content -LiteralPath $layout.Settings -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($check.settings.selected_model -ne $ModelId) { throw "Settings verification failed: selected_model is '$($check.settings.selected_model)'." }
    Write-Ok 'Settings verified'

    Set-Autostart $layout
    if ($layout.Scope -eq 'machine-wide') { Set-StartMenuShortcut $layout }

    Write-Step 'Starting Handy'
    Start-Handy $layout
    Write-Ok "Handy is running in the notification area ($($layout.Scope))"

    Write-Host @"
    HOW TO USE
      Hold Ctrl+Space and speak Hebrew; release to paste the text.
      Tap Ctrl+Space to start, tap again to stop. Esc cancels.
      Ctrl+Shift+Space = transcribe with AI post-processing (optional, off by default).
      Settings: click the Handy icon in the notification area.

    Re-run this script any time to repair or update. It resumes an interrupted
    download and never repeats finished steps.
"@ -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
function Invoke-Uninstall {
    $layout = Get-Layout
    if ($layout.Scope -eq 'machine-wide' -and -not (Test-IsAdmin)) { throw 'Machine-wide uninstall requires administrator rights.' }
    Write-Host "Hebrew Dictation Setup - removing Handy ($($layout.Scope))" -ForegroundColor White
    Stop-Handy
    Remove-Autostart $layout
    if ($layout.Shortcut -and (Test-Path -LiteralPath $layout.Shortcut)) { Remove-Item -LiteralPath $layout.Shortcut -Force }

    if ($layout.Scope -eq 'per-user') {
        if (Test-Path -LiteralPath (Join-Path $layout.HandyDir 'uninstall.exe')) {
            Write-Step 'Running Handy uninstaller'
            # _?= keeps the uninstaller from copying itself to %TEMP%, so -Wait works.
            $p = Start-Process -FilePath (Join-Path $layout.HandyDir 'uninstall.exe') -ArgumentList ('/S _?=' + $layout.HandyDir) -Wait -PassThru
            $null = $p.Handle
        }
        if (Test-Path -LiteralPath $layout.HandyDir) {
            Write-Step "Removing $($layout.HandyDir)"
            Remove-Item -LiteralPath $layout.HandyDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($Purge -and (Test-Path -LiteralPath $layout.DataDir)) {
            Write-Step "Deleting Handy data: $($layout.DataDir)"
            Remove-Item -LiteralPath $layout.DataDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($Purge -or -not (Test-Path -LiteralPath $layout.DataDir)) {
            Write-Host "`nHandy and all of its data were removed." -ForegroundColor Green
        } else {
            Write-Host "`nHandy removed. Settings, history and the Hebrew model were kept in:" -ForegroundColor Green
            Write-Host "    $($layout.DataDir)"
            Write-Host 'Add -Purge to delete them as well.' -ForegroundColor Green
        }
        return
    }

    # Machine-wide: Data lives inside the install folder - remove everything but Data.
    # (explicit filter: -Exclude is ignored together with -LiteralPath in Windows PowerShell 5.1)
    Write-Step "Removing $($layout.HandyDir)"
    Get-ChildItem -LiteralPath $layout.HandyDir -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'Data' } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    if ($Purge -and (Test-Path -LiteralPath $layout.DataDir)) {
        Write-Step "Deleting Handy data: $($layout.DataDir)"
        Remove-Item -LiteralPath $layout.DataDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ((Test-Path -LiteralPath $layout.HandyDir) -and @(Get-ChildItem -LiteralPath $layout.HandyDir -Force -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item -LiteralPath $layout.HandyDir -Force -ErrorAction SilentlyContinue
    }
    if ($Purge -or -not (Test-Path -LiteralPath $layout.DataDir)) {
        Write-Host "`nHandy and all of its data were removed." -ForegroundColor Green
    } else {
        Write-Host "`nHandy removed. The shared data folder (settings and model) was kept:" -ForegroundColor Green
        Write-Host "    $($layout.DataDir)"
        Write-Host 'Add -Purge to delete it as well.' -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# Elevation (machine-wide install/uninstall only)
# ---------------------------------------------------------------------------
function Invoke-Elevated {
    $cmd = if ($PSCommandPath) { "& '" + $PSCommandPath.Replace("'", "''") + "'" } else { "& ([scriptblock]::Create((irm '$ScriptUrl')))" }
    $cmd += ' -MachineWide'
    if ($Uninstall)   { $cmd += ' -Uninstall' }
    if ($InstallRoot) { $cmd += " -InstallRoot '" + $InstallRoot.Replace("'", "''") + "'" }
    if ($Purge)       { $cmd += ' -Purge' }

    # Literal template (single-quoted here-string): the elevated window must stay
    # open after a failure so the error message can be read, and report exit code 1.
    $body = @'
$ErrorActionPreference = 'Stop'
$failed = $false
try { __CMD__ } catch { $failed = $true; Write-Host "`n[ERROR] $($_.Exception.Message)" -ForegroundColor Red }
if (-not $failed) { Write-Host "`nSetup finished." -ForegroundColor Green }
Read-Host 'Press Enter to close this window'
if ($failed) { exit 1 }
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body.Replace('__CMD__', $cmd)))
    try {
        $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -Verb RunAs -Wait -PassThru
        $null = $p.Handle
    } catch {
        Write-Note 'Administrator permission was not granted - nothing was changed.'
        return
    }
    if ($p -and $p.ExitCode -ne 0) { Write-Note 'The elevated setup reported a problem - read the messages in its window.' }
}

# ---------------------------------------------------------------------------
# Entry point (skipped when dot-sourced for testing)
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    $script:Failed = $false
    try {
        if ($Uninstall) {
            if ($MachineWide -and -not (Test-IsAdmin)) { Invoke-Elevated } else { Invoke-Uninstall }
        } elseif ($MachineWide) {
            if (-not (Test-IsAdmin)) { Invoke-Elevated } else { Invoke-Install }
        } else {
            Invoke-Install
        }
    } catch {
        $script:Failed = $true
        Write-Host "`n[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    }
    if ($script:Failed) { throw 'Hebrew dictation setup failed - see the [ERROR] message above.' }
}
