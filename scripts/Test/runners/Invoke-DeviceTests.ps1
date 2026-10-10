#!/usr/bin/env pwsh
# Open ■
# ┬────┴  Invoke-DeviceTests
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/runners/Invoke-DeviceTests.ps1

<#
.SYNOPSIS
    Runs the KNX device conformance cases against one or more TP devices, through an
    interface or a router, and writes a Markdown + JSON report.

.DESCRIPTION
    The other runners judge a KNXnet/IP device against Volume 8. This one judges ordinary
    bus devices against Volume 3 - the layer under the application, the one a firmware
    change can break without anyone noticing.

    The interface passed as -Ip is NOT the object under test here. It is the window. Run
    the KNXnet/IP suites first: a red case here only means something once the window has
    proven itself, and this runner refuses to start if the window is not usable.

    Every target is probed before its cases run. A device that does not answer at all is
    reported once with that reason instead of producing a screen of red that all says the
    same thing.

.PARAMETER Ip
    IP address of the interface or router used to reach the bus.

.PARAMETER Targets
    Individual addresses of the devices to test, comma separated, e.g. 1.1.7,1.1.9.

.PARAMETER SkipSlow
    Skip the case that measures the six second connection timeout (about 12 s per device).

.PARAMETER TestGa
    Group address(es), comma separated, that only the device under test acts on. D-21.1 writes
    a read value back to one of them; without it that case is skipped.
.PARAMETER IsolatedLine
    Declares the 08_02_02 test set-up for D-30.2: only the single target and the rig's own interfaces are on the
    line, none of them is a coupler or router, the target holds no addresses besides its own (no tunnelling
    server), and the target's neighbour address (device number + 1, or - 1 at 255) belongs to none of the
    interfaces or their tunnel pools.

.PARAMETER TrafficIp
    Second interface on the same line. The "did not come back" results ask the target through it once more,
    so a target that answers there is not blamed for the window losing its bus access.

.PARAMETER PowerGuard
    on | off (default). On: the restart and "did not come back" results check the rig power relays first,
    through -PowerRelayVia, and -ProtectedTargets get no restart, master reset, address, memory or property write.

.PARAMETER PowerRelayWrite
    Relay switch GAs, comma separated; paired by position with -PowerRelayStatus.

.PARAMETER PowerRelayStatus
    Relay status GAs, comma separated.

.PARAMETER PowerRelayVia
    Interface that carries every guard telegram.

.PARAMETER ProtectedTargets
    Individual addresses that power the rig, comma separated.

.PARAMETER ReportDir
    Output directory. Default: scripts/Test/Reports.

.EXAMPLE
    ./Invoke-DeviceTests.ps1 -Ip 11.11.0.126 -Targets 1.1.7,1.1.9
.EXAMPLE
    ./Invoke-DeviceTests.ps1 -Ip 11.11.0.126 -Targets 1.1.7 -SkipSlow
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Ip,
    [int]$Port = 3671,
    [Parameter(Mandatory)][string[]]$Targets,
    [switch]$SkipSlow,
    [switch]$ReadOnly,
    [string]$WitnessIp = '',      # a SECOND interface, put into busmonitor mode to observe the bus
    [string]$TestGa = '',         # group address(es) of the target that only the target acts on
    [switch]$Guided,              # a human is present: cases that need a handgrip or ETS may ask
    [switch]$IncludeDestructive,
    [switch]$IsolatedLine,        # 08_02_02 set-up declared, see the help; D-30.2 runs only with it
    [switch]$IncludeTableUnload,  # load-state tests that UNLOAD a table - needs an ETS download afterwards  # allow cases that change device state (prog mode, addresses)
    [string]$Case = '',           # wildcard filter on case ids, e.g. 'D-17.5*'; empty runs everything
    [string]$TrafficIp = '',      # cross-check path for the "did not come back" results
    [ValidateSet('on', 'off')]
    [string]$PowerGuard = 'off',  # rig power guard, see the help
    [string]$PowerRelayWrite = '',
    [string]$PowerRelayStatus = '',
    [string]$PowerRelayVia = '',
    [string]$ProtectedTargets = '',
    [string]$ReportDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $here 'lib/KnxTest.psm1') -Force
# Setting UTF-8 output is harmless on every platform, so it needs no $IsWindows guard - and
# that guard was itself the portability bug: 5.1 does not define the variable, and under
# Set-StrictMode reading it throws before the first test ever runs.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
if (-not $ReportDir) { $ReportDir = Join-Path $here 'Reports' }

function Show-Logo {
    . (Join-Path $PSScriptRoot '../lib/KnxLogo.ps1')
    Write-KnxLogo -Title 'KNX device conformance'
}
function Write-Section {
    param([string]$Text)
    Write-Host ''
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * $Text.Length)) -ForegroundColor DarkGray
}

Show-Logo

# "pwsh script.ps1 -Targets a,b" hands the script one STRING, so a [string[]] parameter
# would carry a single element "a,b" and every case would address a device that does not
# exist. Split every spelling here rather than blame the caller for correct-looking input.
$paList = @()
foreach ($t in $Targets) {
    if ($null -eq $t) { continue }
    foreach ($part in ($t -split '[,;\s]+')) {
        $p = $part.Trim()
        if (-not $p) { continue }
        if ($p -notmatch '^(\d{1,2})\.(\d{1,2})\.(\d{1,3})$' -or [int]$Matches[1] -gt 15 -or [int]$Matches[2] -gt 15 -or [int]$Matches[3] -gt 255) {
            Write-Host "  '$p' is not an individual address (area 0-15 . line 0-15 . device 0-255)" -ForegroundColor Red; exit 3
        }
        # 0.0.0 is no device: the session layer treats it as broadcast and every case would run as one.
        if ([int]$Matches[1] -eq 0 -and [int]$Matches[2] -eq 0 -and [int]$Matches[3] -eq 0) {
            Write-Host "  '$p' is the broadcast address, not a device" -ForegroundColor Red; exit 3
        }
        # Canonical spelling: the cases compare addresses as text ("1.1.013" never equals "1.1.13").
        $p = '{0}.{1}.{2}' -f [int]$Matches[1], [int]$Matches[2], [int]$Matches[3]
        if ($paList -notcontains $p) { $paList += $p }
    }
}
if ($paList.Count -eq 0) { Write-Host '  -Targets is empty' -ForegroundColor Red; exit 3 }

# Same canonical spelling as the targets, so the protected check compares like with like. Off reads nothing.
$protList = @()
foreach ($part in $(if ($PowerGuard -eq 'on') { $ProtectedTargets -split '[,;\s]+' })) {
    $p = $part.Trim()
    if (-not $p) { continue }
    if ($p -notmatch '^(\d{1,2})\.(\d{1,2})\.(\d{1,3})$' -or [int]$Matches[1] -gt 15 -or [int]$Matches[2] -gt 15 -or [int]$Matches[3] -gt 255) {
        Write-Host "  -ProtectedTargets: '$p' is not an individual address" -ForegroundColor Red; exit 3
    }
    $protList += ('{0}.{1}.{2}' -f [int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
}

# ─── The window has to work before anything it shows can be believed ────────────

Write-Section 'Window check'
$desc = $null
try { $desc = Get-KnxDescription -Ip $Ip -Port $Port } catch { }
if ($null -eq $desc) {
    Write-Host "  $Ip does not answer a DESCRIPTION_REQUEST - no window to the bus." -ForegroundColor Red
    Write-Host '  Every case would report the device as dead when it is the interface that is missing.' -ForegroundColor Yellow
    exit 3
}
$windowPa = if ($null -ne $desc.Device) { $desc.Device.IndividualAddr } else { '?' }
$windowName = if ($null -ne $desc.Device) { $desc.Device.FriendlyName } else { '' }
Write-Host "  $Ip  $windowPa  '$windowName'" -ForegroundColor Gray

$K = Get-KnxConstants
$probe = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION `
                           -Layer $K.Layer.TUNNEL_LINKLAYER -TimeoutMs 3000
if (-not $probe.Ok) {
    Write-Host "  $Ip has no free tunnel ($($probe.StatusName)) - the cases cannot reach the bus." -ForegroundColor Red
    Write-Host '  Wait for its connection timeout to reap the old channels, or use another interface.' -ForegroundColor Yellow
    exit 3
}
[void](Close-KnxConnection -Connection $probe)
Write-Host '  Tunnel available.' -ForegroundColor DarkGray

# A device on a different line than the window is reached only if something routes between
# them. Saying so up front turns a wall of timeouts into one sentence.
if ($windowPa -match '^(\d+)\.(\d+)\.') {
    $winLine = "$($Matches[1]).$($Matches[2])"
    foreach ($pa in $paList) {
        if ($pa -notmatch '^(\d+)\.(\d+)\.') { continue }
        $devLine = "$($Matches[1]).$($Matches[2])"
        if ($devLine -ne $winLine) {
            Write-Host "  $pa is on line $devLine, the interface on $winLine - this needs a coupler in between." -ForegroundColor Yellow
        }
    }
}

# ─── Run ────────────────────────────────────────────────────────────────────────

$environment = @{
    'Interface'   = "$Ip ($windowPa)"
    'Targets'     = ($paList -join ', ')
    'Skip slow'   = $(if ($SkipSlow) { 'yes' } else { 'no' })
    'Test client' = 'PowerShell KnxTest.psm1'
    'Specification' = 'KNX Standard v3.0.0 Volume 3'
    'Traffic interface' = $(if ($TrafficIp) { $TrafficIp } else { 'none' })
    'Rig power guard' = $(if ($PowerGuard -eq 'on') { "on - relays $PowerRelayWrite (status $PowerRelayStatus) via $PowerRelayVia$(if ($protList.Count -gt 0) { ', protected ' + ($protList -join ',') })" } else { 'off' })
}
if ($Case) {
    # free-form patterns, so no allowed-set validation: split on the usual separators only.
    # D-1.1 is always included: it is the gate that establishes the device profile every later case
    # reads, and filtering it out made every selected case skip with "device did not answer in D-1.1",
    # which names the wrong reason and hides that the filter, not the device, was the cause.
    $patterns = @($Case -split '[,;\s]+' | Where-Object { $_ })
    if (-not ($patterns | Where-Object { 'D-1.1' -like $_ -or $_ -like 'D-1.1*' })) { $patterns += 'D-1.1*' }
    Set-KnxCaseFilter -Pattern $patterns
    Write-Host ("  Case filter: {0}" -f $Case) -ForegroundColor Cyan
}

[void](Start-KnxTestRun -Product 'KNX-Device' -BdutIp $Ip -Environment $environment `
                        -RunProfile $(if ($ReadOnly) { 'ReadOnly' } else { 'Full' }))

$ctx = [pscustomobject]@{
    BdutIp   = $Ip
    Port     = $Port
    SkipSlow = [bool]$SkipSlow
    ReadOnly = [bool]$ReadOnly
    Guided   = [bool]$Guided
    WitnessIp = $WitnessIp
    TestGa   = $TestGa
    AllowDestructive = ([bool]$IncludeDestructive -and -not [bool]$ReadOnly)
    IsolatedLine = [bool]$IsolatedLine
    TargetCount = @($paList).Count
    # Its OWN switch, deliberately not folded into -IncludeDestructive. Unloading a table wipes the
    # device's ETS configuration and it needs a download to work again - that is a different class
    # from every other destructive case here, and -IncludeDestructive is on in all three profiles.
    AllowTableUnload = ([bool]$IncludeTableUnload -and -not [bool]$ReadOnly)
    # The window's own address: the guard waits for it after a restore.
    DutPa    = $(if ($windowPa -match '^\d+\.\d+\.\d+$') { $windowPa } else { '' })
    TrafficIp = $TrafficIp
    PowerGuard = ($PowerGuard -eq 'on')
    PowerRelayWrite = $PowerRelayWrite
    PowerRelayStatus = $PowerRelayStatus
    PowerRelayVia = $PowerRelayVia
    # Off enforces nothing.
    ProtectedTargets = $protList
}

# Rig power before the first case: D-1.1 decides whether a target is judged at all.
if ($ctx.PowerGuard) {
    Import-Module (Join-Path $here 'lib/KnxDevice.psm1') -Force -DisableNameChecking
    $g0 = Assert-KnxRigPower -Via $PowerRelayVia -Port $Port -WriteGa $PowerRelayWrite -StatusGa $PowerRelayStatus -DutPa $ctx.DutPa
    $col = if (-not $g0.Ok) { 'Red' } elseif ($g0.Restored) { 'Yellow' } else { 'DarkGray' }
    Write-Host "  Rig power: $(if ($g0.Restored) { 'RESTORED - ' })$($g0.Detail)" -ForegroundColor $col
}

. (Join-Path $here 'Suites/D-Device.Tests.ps1')

foreach ($pa in $paList) {
    Write-Section "Device $pa"
    Invoke-KnxSuiteDevice -Ctx $ctx -Target $pa -SuiteTitle "D Device $pa"
}

# ─── Report ─────────────────────────────────────────────────────────────────────

$out = Export-KnxTestReport -Directory $ReportDir
$sum = $out.Summary

Write-Section 'Summary'
# Shared printer, so the console carries the same buckets as the Markdown table and the JSON.
Write-KnxRunSummary
Write-Host ''
Write-Host "  Report: $($out.Markdown)" -ForegroundColor Cyan
Write-Host "  Data  : $($out.Json)" -ForegroundColor DarkGray
Write-Host ''

if ($sum.Fail -gt 0) { exit 1 }
exit 0
