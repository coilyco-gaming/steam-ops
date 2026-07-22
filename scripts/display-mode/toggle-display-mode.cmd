@echo off
REM Target of the "Toggle Display Mode" desktop shortcut. The PowerShell script
REM self-elevates through UAC, so this stays a plain unprivileged launcher.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-DisplayMode.ps1" -Mode toggle
exit /b 0
