# Install-DisplayMode.ps1
#
# The elevated half of the display-mode setup. Run this once, as administrator,
# from the repo checkout. Re-running it is safe - it is how a script edit here
# reaches the live host.
#
# It does three things:
#   1. Deploys the mode scripts to C:\ProgramData\DisplayMode. Sunshine's
#      global_prep_cmd and the "Toggle Display Mode" desktop shortcut both point
#      at that fixed path, so the repo stays the source and ProgramData stays the
#      deployed copy - never edit the deployed copy by hand.
#   2. Points Sunshine's global_prep_cmd at the deployed scripts, so a Moonlight
#      stream turns the virtual display on and hands it back on disconnect.
#   3. Drops the machine into native mode now, which persists across reboots.
#
# The unprivileged half (autostart removal, desktop shortcut) is a one-time
# manual step and is not repeated here.

$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning 'Not elevated. Relaunching through UAC...'
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    )
    exit 0
}

$conf    = 'C:\Program Files\Sunshine\config\sunshine.conf'
$install = 'C:\ProgramData\DisplayMode'
$prep    = '[{"do":"C:\\ProgramData\\DisplayMode\\mode-remote.cmd","undo":"C:\\ProgramData\\DisplayMode\\mode-native.cmd","elevated":"false"}]'

$payload = @(
    'Set-DisplayMode.ps1'
    'toggle-display-mode.cmd'
    'mode-native.cmd'
    'mode-remote.cmd'
)

Write-Host "==> Deploying scripts to $install" -ForegroundColor Cyan
if ((Resolve-Path $PSScriptRoot).Path.TrimEnd('\') -eq $install) {
    # Running the deployed copy in place - nothing to copy, and Copy-Item onto
    # itself would fail. Reinstalling from the repo is the supported path.
    Write-Host '    running from the install dir, skipping copy' -ForegroundColor DarkGray
} else {
    New-Item -ItemType Directory -Force -Path $install | Out-Null
    foreach ($file in $payload) {
        Copy-Item (Join-Path $PSScriptRoot $file) (Join-Path $install $file) -Force
    }
    Write-Host "    copied $($payload.Count) files" -ForegroundColor DarkGray
}

Write-Host '==> Backing up sunshine.conf' -ForegroundColor Cyan
Copy-Item $conf "$install\sunshine.conf.bak" -Force
Write-Host "    saved to $install\sunshine.conf.bak" -ForegroundColor DarkGray

Write-Host '==> Wiring global_prep_cmd' -ForegroundColor Cyan
$lines = @(Get-Content $conf)
if ($lines -match '^\s*global_prep_cmd\s*=') {
    # Replace the existing key in place so surrounding settings keep their order.
    $lines = $lines | ForEach-Object {
        if ($_ -match '^\s*global_prep_cmd\s*=') { "global_prep_cmd = $prep" } else { $_ }
    }
} else {
    $lines += "global_prep_cmd = $prep"
}
Set-Content -Path $conf -Value $lines -Encoding UTF8
Write-Host '    done' -ForegroundColor DarkGray

Write-Host '==> Restarting SunshineService to load the new config' -ForegroundColor Cyan
Restart-Service -Name SunshineService -Force
Start-Sleep -Seconds 3
Write-Host "    $((Get-Service SunshineService).Status)" -ForegroundColor DarkGray

Write-Host '==> Switching to native mode' -ForegroundColor Cyan
$result = & "$install\Set-DisplayMode.ps1" -Mode native -Quiet
Write-Host "    mode is now: $result" -ForegroundColor DarkGray

Write-Host ''
Write-Host 'Setup complete.' -ForegroundColor Green
Write-Host 'The machine now boots into native mode. Moonlight flips it automatically.' -ForegroundColor Green
Write-Host 'The desktop shortcut "Toggle Display Mode" flips it by hand if you ever need to.' -ForegroundColor Green
Write-Host ''
Read-Host 'Press Enter to close'
