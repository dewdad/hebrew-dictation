# Hebrew Dictation for Windows

One-command setup for **Hebrew voice dictation** on Windows 10/11 — no admin privileges, fully local (no audio leaves your PC).

Windows' built-in voice typing (Win+H) does not support Hebrew. This script installs [Handy](https://github.com/cjpais/Handy) (free, open-source dictation) with the [ivrit.ai Hebrew fine-tune of Whisper large-v3-turbo](https://huggingface.co/ivrit-ai/whisper-large-v3-turbo), which roughly halves the word-error rate of stock Whisper on Hebrew.

## Install

Open **PowerShell** (normal, not admin) and run:

```powershell
irm "https://raw.githubusercontent.com/dewdad/hebrew-dictation/main/setup.ps1" | iex
```

## What it does

1. Installs Handy silently, per-user (`%LOCALAPPDATA%\Handy`) — no winget or admin required.
2. Downloads the ivrit.ai Hebrew Whisper model (Q8_0 GGUF, ~886 MB), sha256-verified and resumable.
3. Picks the best compute device automatically: NVIDIA > AMD > Intel GPU (Vulkan), CPU fallback.
4. Configures Hebrew language lock, GPU pinning, and Windows autostart.
5. Starts Handy in the system tray.

Safe to re-run: existing components are detected and skipped (idempotent).

## Usage

- Click into any text field, **hold `Ctrl+Space`**, speak Hebrew, release — the text is typed at your cursor.
- Quick tap = toggle hands-free mode. `Esc` = cancel.
- First dictation loads the model (a few seconds); afterwards it's fast.
- Settings: right-click the Handy tray icon.

## Requirements

- Windows 10/11 x64, PowerShell 5.1+
- Internet for the one-time download (~920 MB total)
- A microphone
- Optional: a Vulkan-capable GPU (NVIDIA/AMD/Intel) for acceleration; CPU works too

## Notes

- The ivrit.ai model is Hebrew-specialized. For other languages, add a stock Whisper model in Handy's settings and switch.
- Model conversion: [vladkens/ivrit-whisper-large-v3-turbo-gguf](https://huggingface.co/vladkens/ivrit-whisper-large-v3-turbo-gguf) (Apache-2.0), built for Handy's transcribe.cpp engine.

## License

MIT (script). Handy is MIT; the model is Apache-2.0 (ivrit.ai / OpenAI).