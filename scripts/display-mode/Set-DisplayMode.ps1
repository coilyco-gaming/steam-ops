# Set-DisplayMode.ps1
#
# Flips this machine between "native" mode (physical monitor only) and
# "remote" mode (Virtual Display Driver enabled for Sunshine/Moonlight).
#
# The VDD is a root-enumerated PnP device. Disabling it writes CONFIGFLAG_DISABLED,
# which persists across reboots, so "native" survives a restart with no autostart
# helper needed.
#
# Usage:
#   Set-DisplayMode.ps1 -Mode native|remote|toggle|status [-Quiet]
#
# Sunshine calls this as LocalSystem via global_prep_cmd (already elevated).
# The desktop shortcut calls it interactively and self-elevates through UAC.
#
# This file is the source. The copy that actually runs lives in
# C:\ProgramData\DisplayMode - edit here, then re-run Install-DisplayMode.ps1.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('native', 'remote', 'toggle', 'status')]
    [string]$Mode,

    # Suppress the tray balloon. Set for non-interactive callers.
    [switch]$Quiet,

    # Override the resolution restored on entering native mode. Left unset, the
    # script picks the monitor's best supported mode.
    [int]$Width,
    [int]$Height,
    [int]$Refresh
)

$ErrorActionPreference = 'Stop'

# The live VDD instance. ROOT\DISPLAY\0001 is a stale disabled duplicate and is
# deliberately NOT managed here - enabling it would produce a second phantom monitor.
$VddInstanceId = 'ROOT\DISPLAY\0000'

$LogPath = Join-Path $PSScriptRoot 'display-mode.log'

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try {
        $line | Out-File -FilePath $LogPath -Append -Encoding UTF8
    } catch {
        # A locked or unwritable log must never take the mode switch down.
    }
    Write-Verbose $line
}

function Get-VddDevice {
    $device = Get-PnpDevice -InstanceId $VddInstanceId -ErrorAction SilentlyContinue
    if (-not $device) {
        throw "Virtual Display Driver not found at $VddInstanceId. Re-run VDD Control setup, or update `$VddInstanceId in this script."
    }
    return $device
}

# A root display device reports Status 'OK' only when started. Disabled instances
# report 'Error' with ConfigFlags carrying CONFIGFLAG_DISABLED, so read the flag
# rather than trusting Status alone.
function Test-VddEnabled {
    $device = Get-VddDevice
    $flags = (Get-PnpDeviceProperty -InstanceId $VddInstanceId -KeyName 'DEVPKEY_Device_ConfigFlags' -ErrorAction SilentlyContinue).Data
    if ($null -ne $flags -and ($flags -band 1)) { return $false }
    return ($device.Status -eq 'OK')
}

function Show-Balloon {
    param(
        [string]$Title,
        [string]$Text
    )
    if ($Quiet) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $icon = New-Object System.Windows.Forms.NotifyIcon
        $icon.Icon = [System.Drawing.SystemIcons]::Information
        $icon.BalloonTipTitle = $Title
        $icon.BalloonTipText = $Text
        $icon.Visible = $true
        $icon.ShowBalloonTip(4000)
        Start-Sleep -Seconds 5
        $icon.Dispose()
    } catch {
        Write-Log "Balloon suppressed: $($_.Exception.Message)"
    }
}

# --------------------------------------------------------------------------
# Resolution restore
#
# Disabling the VDD tears down a monitor, and Windows routinely leaves the
# surviving physical display parked at whatever fallback mode the streaming
# session negotiated (1280x720 is the usual landing spot). Flipping the PnP
# device back is therefore only half of "native" - the desktop mode has to be
# put back too, which the PnP APIs will not do for us.
# --------------------------------------------------------------------------

if (-not ('DisplayApi' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class DisplayApi {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
    public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra;
    public int dmFields; public int dmPositionX; public int dmPositionY;
    public int dmDisplayOrientation; public int dmDisplayFixedOutput;
    public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
    public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight;
    public int dmDisplayFlags; public int dmDisplayFrequency;
    public int dmICMMethod; public int dmICMIntent; public int dmMediaType; public int dmDitherType;
    public int dmReserved1; public int dmReserved2; public int dmPanningWidth; public int dmPanningHeight;
  }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct DISPLAY_DEVICE {
    public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceString;
    public int StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceKey;
  }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  public static extern int EnumDisplaySettingsW(string device, int mode, ref DEVMODE dm);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  public static extern bool EnumDisplayDevicesW(string device, uint index, ref DISPLAY_DEVICE dd, uint flags);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  public static extern int ChangeDisplaySettingsExW(string device, ref DEVMODE dm, IntPtr wnd, int flags, IntPtr param);
}
'@
}

$ENUM_CURRENT_SETTINGS = -1
$DM_BITSPERPEL         = 0x00040000
$DM_PELSWIDTH          = 0x00080000
$DM_PELSHEIGHT         = 0x00100000
$DM_DISPLAYFREQUENCY   = 0x00400000
$CDS_UPDATEREGISTRY    = 0x00000001
$DISP_CHANGE_SUCCESSFUL = 0
$DISPLAY_DEVICE_PRIMARY = 0x00000004

function New-Devmode {
    $dm = New-Object DisplayApi+DEVMODE
    $dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type]([DisplayApi+DEVMODE]))
    return $dm
}

function Get-PrimaryDeviceName {
    for ($i = 0; $i -lt 16; $i++) {
        $dd = New-Object DisplayApi+DISPLAY_DEVICE
        $dd.cb = [System.Runtime.InteropServices.Marshal]::SizeOf([type]([DisplayApi+DISPLAY_DEVICE]))
        if (-not [DisplayApi]::EnumDisplayDevicesW([NullString]::Value, $i, [ref]$dd, 0)) { break }
        if ($dd.StateFlags -band $DISPLAY_DEVICE_PRIMARY) { return $dd.DeviceName }
    }
    return $null
}

# Highest pixel count wins, then highest refresh at that size. Modes are filtered
# to 32bpp so the legacy 8/16bpp entries can never outrank a real one.
function Get-BestMode {
    param([string]$Device)

    $best = $null
    for ($i = 0; $i -lt 512; $i++) {
        $dm = New-Devmode
        if ([DisplayApi]::EnumDisplaySettingsW($Device, $i, [ref]$dm) -eq 0) { break }
        if ($dm.dmBitsPerPel -ne 32) { continue }
        if ($null -eq $best) { $best = $dm; continue }

        $pixels     = $dm.dmPelsWidth * $dm.dmPelsHeight
        $bestPixels = $best.dmPelsWidth * $best.dmPelsHeight
        if ($pixels -gt $bestPixels -or
            ($pixels -eq $bestPixels -and $dm.dmDisplayFrequency -gt $best.dmDisplayFrequency)) {
            $best = $dm
        }
    }
    return $best
}

function Restore-NativeResolution {
    $device = Get-PrimaryDeviceName
    if (-not $device) {
        Write-Log 'Resolution restore skipped: no primary display found.'
        return $null
    }

    $target = Get-BestMode -Device $device
    if (-not $target) {
        Write-Log "Resolution restore skipped: no modes enumerated for $device."
        return $null
    }

    # Explicit overrides win over the auto-picked best mode.
    if ($Width)   { $target.dmPelsWidth = $Width }
    if ($Height)  { $target.dmPelsHeight = $Height }
    if ($Refresh) { $target.dmDisplayFrequency = $Refresh }

    $current = New-Devmode
    [void][DisplayApi]::EnumDisplaySettingsW($device, $ENUM_CURRENT_SETTINGS, [ref]$current)
    if ($current.dmPelsWidth -eq $target.dmPelsWidth -and
        $current.dmPelsHeight -eq $target.dmPelsHeight -and
        $current.dmDisplayFrequency -eq $target.dmDisplayFrequency) {
        Write-Log "Resolution already $($target.dmPelsWidth)x$($target.dmPelsHeight)@$($target.dmDisplayFrequency), left alone."
        return "$($target.dmPelsWidth)x$($target.dmPelsHeight)"
    }

    $target.dmFields = $DM_PELSWIDTH -bor $DM_PELSHEIGHT -bor $DM_DISPLAYFREQUENCY -bor $DM_BITSPERPEL

    $rc = [DisplayApi]::ChangeDisplaySettingsExW(
        $device, [ref]$target, [IntPtr]::Zero, $CDS_UPDATEREGISTRY, [IntPtr]::Zero)

    if ($rc -ne $DISP_CHANGE_SUCCESSFUL) {
        Write-Log "Resolution restore FAILED on ${device}: ChangeDisplaySettingsEx rc=$rc"
        return $null
    }

    Write-Log "Restored $device to $($target.dmPelsWidth)x$($target.dmPelsHeight)@$($target.dmDisplayFrequency)Hz"
    return "$($target.dmPelsWidth)x$($target.dmPelsHeight)"
}

# Elevate only for the state-changing modes. 'status' is read-only and must stay
# usable from an unprivileged prompt.
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin -and $Mode -ne 'status') {
    $argList = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-File', "`"$PSCommandPath`""
        '-Mode', $Mode
    )
    if ($Quiet)   { $argList += '-Quiet' }
    if ($Width)   { $argList += @('-Width', $Width) }
    if ($Height)  { $argList += @('-Height', $Height) }
    if ($Refresh) { $argList += @('-Refresh', $Refresh) }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -WindowStyle Hidden
    exit 0
}

$enabled = Test-VddEnabled
$current = if ($enabled) { 'remote' } else { 'native' }

if ($Mode -eq 'status') {
    Write-Output $current
    exit 0
}

$target = if ($Mode -eq 'toggle') { if ($enabled) { 'native' } else { 'remote' } } else { $Mode }

# Already-in-target is not always a no-op: a native desktop can still be parked
# at a fallback resolution from an earlier session, and re-running the shortcut
# is the natural way to ask for that to be fixed.
if ($target -eq $current) {
    Write-Log "Already in $current mode."
    if ($target -eq 'native') {
        $res = Restore-NativeResolution
        $text = if ($res) { "Already in native mode. Display at $res." } else { 'Already in native mode.' }
    } else {
        $text = 'Already in remote mode.'
    }
    Show-Balloon -Title 'Display mode' -Text $text
    Write-Output $current
    exit 0
}

Write-Log "Switching $current -> $target"

try {
    if ($target -eq 'remote') {
        Enable-PnpDevice -InstanceId $VddInstanceId -Confirm:$false
    } else {
        Disable-PnpDevice -InstanceId $VddInstanceId -Confirm:$false
    }
} catch {
    Write-Log "FAILED switching to ${target}: $($_.Exception.Message)"
    Show-Balloon -Title 'Display mode FAILED' -Text $_.Exception.Message
    throw
}

# The PnP change is asynchronous. Give Windows a moment to tear down or bring up
# the monitor before reporting, so the caller sees a settled state.
Start-Sleep -Seconds 2

$now = if (Test-VddEnabled) { 'remote' } else { 'native' }
Write-Log "Now in $now mode."

# Only native gets its resolution forced. In remote mode Sunshine negotiates the
# streaming mode itself, and overriding it here would fight the client.
$restored = $null
if ($now -eq 'native') {
    # The monitor's mode list is not trustworthy the instant the VDD goes away -
    # a too-early enumeration can miss the panel's top modes. Retry until the
    # best mode stops being a fallback-sized one, or the budget runs out.
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $restored = Restore-NativeResolution
        if ($restored) { break }
        Write-Log "Resolution restore attempt $attempt failed, retrying..."
        Start-Sleep -Seconds 1
    }
}

$blurb = if ($now -eq 'native') {
    if ($restored) {
        "Virtual display OFF. Your monitor is the only display, at $restored."
    } else {
        'Virtual display OFF, but the resolution could not be restored. See display-mode.log.'
    }
} else {
    'Virtual display ON. Ready for Moonlight.'
}
Show-Balloon -Title "Display mode: $now" -Text $blurb

Write-Output $now
