@echo off
REM Called by Sunshine (global_prep_cmd "do") when a Moonlight stream starts.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Set-DisplayMode.ps1" -Mode remote -Quiet
exit /b 0
