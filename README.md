# Hebrew Dictation for Windows

One-command setup for **Hebrew voice dictation** on Windows 10/11 — fully local (no audio leaves your PC).

Windows' built-in voice typing (Win+H) does not support Hebrew. This script installs [Handy](https://github.com/cjpais/Handy) (free, open-source dictation) with the [ivrit.ai Hebrew fine-tune of Whisper large-v3-turbo](https://huggingface.co/ivrit-ai/whisper-large-v3-turbo), which roughly halves the word-error rate of stock Whisper on Hebrew.

## Install

### For your user (no admin)

Open **PowerShell** (normal, not admin) and run:

```powershell
irm "https://raw.githubusercontent.com/dewdad/hebrew-dictation/main/setup.ps1" | iex
```

### For the whole machine (all users)

Open **PowerShell** and run:

```powershell
irm "https://raw.githubusercontent.com/dewdad/hebrew-dictation/main/setup-machine.ps1" | iex
```

Windows asks for administrator approval once (UAC prompt); the setup then continues in its own window and ends with **Setup finished.**

| | Per-user | Machine-wide |
|---|---|---|
| Admin rights | Not needed | Needed once (UAC prompt) |
| Installed to | `%LOCALAPPDATA%\Handy` | `C:\Program Files\Handy` |
| Settings and model | `%APPDATA%\com.pais.handy` | `C:\Program Files\Handy\Data` (shared by all users) |
| Who gets it | Your user only | Every user, with a Start Menu entry |
| Starts with Windows | Your user | Every user |

A machine-wide install keeps the model on disk once for everybody, so each user gets the same Hebrew setup without repeating the ~886 MB download. Because the `Data` folder is shared, the machine-wide install turns recording history off: recordings and transcripts are not kept on disk.

One caveat comes from that sharing: Handy's settings window uses a browser profile that lives in the shared folder, and Windows does not let two users share one at the same time. If two people are signed in *simultaneously* (fast user switching or remote sessions), the second user's settings window may not open. Handy itself keeps running in that case, but only one person should use it at a time on a machine-wide install. If that does not fit, use the per-user install instead.

You only need one of the two. If both end up installed the script warns you; remove the one you do not want (see [Uninstall](#uninstall)).

## What it does

1. Downloads Handy's installer and installs it silently (per-user, or self-contained into Program Files).
2. Downloads the ivrit.ai Hebrew Whisper model (Q8_0 GGUF, ~886 MB) in the background at the same time — resumable and sha256-verified.
3. Picks the best compute device automatically: NVIDIA > AMD > Intel GPU (Vulkan), with a discrete card preferred over an integrated one; CPU fallback.
4. Configures Hebrew language lock, the compute device, and Windows autostart.
5. Verifies that Handy lists the model and that the settings were applied, then starts Handy in the notification area.

Safe to re-run at any time: finished steps are skipped, an interrupted download resumes, and a newer Handy release is picked up automatically (the Hebrew settings are re-applied afterwards).

## Usage

- Click into any text field, **hold `Ctrl+Space`**, speak Hebrew, release — the text is typed at your cursor.
- Quick tap = toggle hands-free mode. `Esc` = cancel.
- The first dictation loads the model (about 2–3 seconds on a GPU); the model then stays loaded for 15 minutes between dictations.
- Settings: click the Handy icon in the notification area.

## Uninstall

Run the same script with `-Uninstall`:

```powershell
# Per-user install
& ([scriptblock]::Create((irm "https://raw.githubusercontent.com/dewdad/hebrew-dictation/main/setup.ps1"))) -Uninstall

# Machine-wide install (asks for administrator rights)
& ([scriptblock]::Create((irm "https://raw.githubusercontent.com/dewdad/hebrew-dictation/main/setup.ps1"))) -Uninstall -MachineWide
```

Both keep your settings and the downloaded model, in case you install again. Add `-Purge` to delete them as well.

## Requirements

- Windows 10/11 (x64 or ARM64), PowerShell 5.1+
- Internet for the one-time download (~900 MB)
- A microphone
- Optional: a Vulkan-capable GPU (NVIDIA/AMD/Intel) for acceleration; the CPU works too, just slower

## Notes

- The ivrit.ai model is Hebrew-specialized. For other languages, add a stock Whisper model in Handy's settings and switch.
- Model conversion: [vladkens/ivrit-whisper-large-v3-turbo-gguf](https://huggingface.co/vladkens/ivrit-whisper-large-v3-turbo-gguf) (Apache-2.0), built for Handy's transcribe.cpp engine.
- To install machine-wide into another folder, add `-InstallRoot 'D:\Apps\Handy'`.

## License

MIT (script). Handy is MIT; the model is Apache-2.0 (ivrit.ai / OpenAI).
