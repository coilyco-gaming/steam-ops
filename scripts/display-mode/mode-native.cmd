@echo off
REM Called by Sunshine (global_prep_cmd "undo") when a Moonlight stream ends,
REM returning the machine to its resting state: physical monitor only.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-DisplayMode.ps1" -Mode native -Quiet
exit /b 0
