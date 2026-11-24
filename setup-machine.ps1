<#
.SYNOPSIS
    Machine-wide Hebrew voice dictation for Windows - one-command setup.
.DESCRIPTION
    Installs Handy for every user of this PC (C:\Program Files\Handy) together
    with the ivrit.ai Hebrew Whisper model, and configures Hebrew dictation.
    Requires administrator rights: Windows shows one UAC prompt, then the setup
    continues in its own window.

        irm "https://raw.githubusercontent.com/dewdad/hebrew-dictation/main/setup-machine.ps1" | iex

    To remove: add -Uninstall (-Purge also deletes the shared settings and model).
#>
& ([scriptblock]::Create((irm "https://raw.githubusercontent.com/dewdad/hebrew-dictation/main/setup.ps1"))) -MachineWide
