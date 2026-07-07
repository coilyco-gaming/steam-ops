#Requires -Version 5.1
<#
  steam-airgap.ps1
  ----------------
  Client-side ops helper (NOT part of the steam-mcp service). Toggles a Windows Firewall
  block on Steam's networking executables so the Steam client goes OFFLINE while the rest
  of the machine stays online.

  Why: Steam allows only one *online* session per account. A client that can't reach Steam's
  servers can't be kicked when the account logs in online elsewhere - so an "airgapped" Steam
  on a streaming host can keep running a game (e.g. X4) while a housemate plays the same copy
  online on another box. This blocks STEAM's connection only; Tailscale / Sunshine / Moonlight
  and the game's own networking keep working - you are NOT air-gapping the machine, just Steam.

  Reliable where Steam's built-in "Go Offline" is flaky: Steam physically can't phone home.

  FLOW
    1. Launch Steam ONLINE once first (cache creds, tick "remember password", update the game).
    2. steam-airgap.ps1 -On     # block Steam's servers; it drops to offline mode
    3. Launch the game + stream as usual (Sunshine steam://rungameid tiles still work offline).
    4. Housemate logs the account in ONLINE elsewhere and launches the same game.
    5. steam-airgap.ps1 -Off    # restore Steam's connection when done

  USAGE
    pwsh ./scripts/steam-airgap.ps1 -Status   # show current state (no admin needed)
    pwsh ./scripts/steam-airgap.ps1 -On       # airgap Steam  (self-elevates via UAC)
    pwsh ./scripts/steam-airgap.ps1 -Off      # restore Steam (self-elevates via UAC)

  GOTCHAS
    * Steam Cloud will clobber saves if two instances sync the same slot - DISABLE Steam Cloud
      for the game first (game -> Properties -> General) before dual-play.
    * Offline-capable games only: X4 works; anything with anti-cheat / always-online / Denuvo
      online activation will not.
    * One purchase, two concurrent players is a Steam ToS gray area - your call.
#>
[CmdletBinding()]
param(
  [switch] $On,
  [switch] $Off,
  [switch] $Status
)

$ErrorActionPreference = 'Stop'
$GROUP = 'SteamAirgap'

function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
   ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-SteamExes {
  $steam = $null
  foreach ($k in 'HKCU:\Software\Valve\Steam','HKLM:\SOFTWARE\WOW6432Node\Valve\Steam','HKLM:\SOFTWARE\Valve\Steam') {
    $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
    $v = $p.SteamPath; if (-not $v) { $v = $p.InstallPath }
    if ($v) { $steam = ($v -replace '/','\'); break }
  }
  if (-not $steam) { throw 'Steam install not found in registry.' }

  $exes = [System.Collections.Generic.List[string]]::new()
  $root = Join-Path $steam 'steam.exe'
  if (Test-Path $root) { $exes.Add((Resolve-Path $root).Path) }
  # steamwebhelper.exe lives under bin\cef\... and moves across Steam updates - resolve live.
  Get-ChildItem $steam -Recurse -Depth 3 -Filter 'steamwebhelper.exe' -ErrorAction SilentlyContinue |
    ForEach-Object { $exes.Add($_.FullName) }
  $exes | Sort-Object -Unique
}

function Show-Status {
  $rules = @(Get-NetFirewallRule -Group $GROUP -ErrorAction SilentlyContinue)
  $active = @($rules | Where-Object { $_.Enabled -eq 'True' -and $_.Action -eq 'Block' })
  if ($active.Count -gt 0) {
    Write-Host "STATE: AIRGAPPED - Steam is blocked from its servers ($($active.Count) rule(s))." -ForegroundColor Yellow
    foreach ($r in $active) {
      $prog = ($r | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue).Program
      Write-Host "   blocked: $prog"
    }
  } else {
    Write-Host 'STATE: ONLINE - no Steam block in place.' -ForegroundColor Green
  }
}

function Set-Airgap([bool]$enable) {
  if (-not (Test-Admin)) {
    # Re-launch this script elevated with the same intent; UAC prompt appears on the desktop.
    $host_exe = (Get-Process -Id $PID).Path
    $verb = if ($enable) { '-On' } else { '-Off' }
    Write-Host 'Elevating (accept the UAC prompt)...'
    Start-Process $host_exe -Verb RunAs -Wait -ArgumentList '-NoProfile','-File',"`"$PSCommandPath`"",$verb
    return
  }

  # Always rebuild rules so paths track Steam updates.
  Get-NetFirewallRule -Group $GROUP -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
  if ($enable) {
    $i = 0
    foreach ($exe in (Get-SteamExes)) {
      $i++
      New-NetFirewallRule -DisplayName "SteamAirgap $i - $([IO.Path]::GetFileName($exe))" `
        -Group $GROUP -Direction Outbound -Action Block -Program $exe -Enabled True -Profile Any |
        Out-Null
      Write-Host "  blocked: $exe"
    }
    Write-Host "`nSteam is now AIRGAPPED. It will drop to offline mode (relaunch Steam if it was open)." -ForegroundColor Yellow
  } else {
    Write-Host 'Steam block removed - Steam is back ONLINE.' -ForegroundColor Green
  }
}

# ---- dispatch ----
if ($On -and $Off) { throw 'Pass only one of -On / -Off.' }
if ($On)      { Set-Airgap $true;  Show-Status }
elseif ($Off) { Set-Airgap $false; Show-Status }
else {
  Show-Status
  if (-not $Status) {
    Write-Host "`nUsage: steam-airgap.ps1 -On | -Off | -Status" -ForegroundColor DarkGray
  }
}
