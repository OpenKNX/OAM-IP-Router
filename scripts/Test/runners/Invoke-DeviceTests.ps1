#!/usr/bin/env pwsh
<#
Open ■
┬────┴  Invoke-DeviceTests
■ KNX   2026 OpenKNX - Erkan Çolak

FILEPATH: scripts/Test/runners/Invoke-DeviceTests.ps1

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
    Individual addresses of the devices to test, comma separated, e.g. 5.0.3,5.0.9.

.PARAMETER SkipSlow
    Skip the case that measures the six second connection timeout (about 12 s per device).

.PARAMETER ReportDir
    Output directory. Default: scripts/Test/Reports.

.EXAMPLE
    ./Invoke-DeviceTests.ps1 -Ip 11.11.0.126 -Targets 5.0.3,5.0.9
.EXAMPLE
    ./Invoke-DeviceTests.ps1 -Ip 11.11.0.126 -Targets 5.0.3 -SkipSlow
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Ip,
    [int]$Port = 3671,
    [Parameter(Mandatory)][string[]]$Targets,
    [switch]$SkipSlow,
    [switch]$ReadOnly,
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
    Write-Host ''
    Write-Host '  Open ■' -ForegroundColor Green
    Write-Host '  ┬────┴  KNX device conformance' -ForegroundColor Green
    Write-Host '  ■ KNX   2026 OpenKNX - Erkan Çolak' -ForegroundColor DarkGray
    Write-Host ''
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
        if ($p -notmatch '^\d{1,2}\.\d{1,2}\.\d{1,3}$') { Write-Host "  '$p' is not an individual address (area.line.device)" -ForegroundColor Red; exit 3 }
        if ($paList -notcontains $p) { $paList += $p }
    }
}
if ($paList.Count -eq 0) { Write-Host '  -Targets is empty' -ForegroundColor Red; exit 3 }

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
}
[void](Start-KnxTestRun -Product 'KNX-Device' -BdutIp $Ip -Environment $environment `
                        -RunProfile $(if ($ReadOnly) { 'ReadOnly' } else { 'Full' }))

$ctx = [pscustomobject]@{
    BdutIp   = $Ip
    Port     = $Port
    SkipSlow = [bool]$SkipSlow
    ReadOnly = [bool]$ReadOnly
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
Write-Host "  Total $($sum.Total)   " -NoNewline
Write-Host "PASS $($sum.Pass)  " -ForegroundColor Green -NoNewline
Write-Host "FAIL $($sum.Fail)  " -ForegroundColor $(if ($sum.Fail -gt 0) { 'Red' } else { 'DarkGray' }) -NoNewline
Write-Host "SKIP $($sum.Skip)  " -ForegroundColor Yellow -NoNewline
Write-Host "N-A $($sum.NA)" -ForegroundColor DarkGray
Write-Host ''
Write-Host "  Report: $($out.Markdown)" -ForegroundColor Cyan
Write-Host "  Data  : $($out.Json)" -ForegroundColor DarkGray
Write-Host ''

if ($sum.Fail -gt 0) { exit 1 }
exit 0
