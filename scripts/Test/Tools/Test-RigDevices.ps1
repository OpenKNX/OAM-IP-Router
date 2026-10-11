#!/usr/bin/env pwsh
# Open ■
# ┬────┴  Test-RigDevices
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/Tools/Test-RigDevices.ps1

<#
.SYNOPSIS
    Checks that the TP devices of the test rig are on the bus and answer.

.DESCRIPTION
    Tools/Test-RigNetwork.ps1 answers "does this computer reach the KNXnet/IP devices". This script
    answers the next question: are the TP devices behind them there. A device that is switched off or
    not on the line otherwise shows up half an hour later as SKIP or FAIL in cases that are about
    something else.

    For each target the script opens a tunnel on a KNXnet/IP device of the rig and sends an
    A_DeviceDescriptor_Read (03_03_07 clause 3.4.2.1), connectionless, up to three times. That is
    the request case D-1.1 uses; it reads and changes nothing. An answer counts when it comes from
    the target, is addressed to this tunnel and is an A_DeviceDescriptor_Response.

    The targets come from the rig block of Test-Bench-Config.json (p2pTarget, deviceTargets,
    ftcTarget, speedTarget) unless -Targets names them. A target outside safety.allowedLines is
    never addressed: the script stops before the first telegram.

    Exit code 0: every target answers. 1: at least one does not. 2: the check could not be made.

.PARAMETER Targets
    The individual addresses to check, as a list or one comma separated string.

.PARAMETER Via
    The KNXnet/IP devices to look through, as IP addresses, in the order they are tried. The first
    one that grants a tunnel is used. Default: the devices of Test-Bench-Config.json.

.PARAMETER AllowedLines
    The lines the check may address, as area.line. Default: safety.allowedLines of
    Test-Bench-Config.json. Empty means no restriction.

.PARAMETER Port
    KNXnet/IP port of the devices in -Via. Default 3671.

.PARAMETER TimeoutMs
    How long one attempt waits for the answer. Default 3000.

.PARAMETER Quiet
    Print only problems and the result line.

.EXAMPLE
    ./Test-RigDevices.ps1
.EXAMPLE
    ./Test-RigDevices.ps1 -Targets 1.1.5,1.1.8 -Via 11.11.0.126
#>

[CmdletBinding()]
param(
    [string[]]$Targets = @(),
    [string[]]$Via = @(),
    [string[]]$AllowedLines = @(),
    [int]$Port = 3671,
    [int]$TimeoutMs = 3000,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Write-Line {
    param([string]$Mark, [string]$Text, [string]$Color = 'Gray')
    if ($Quiet -and $Mark -eq 'OK') { return }
    Write-Host ("  {0,-5} {1}" -f $Mark, $Text) -ForegroundColor $Color
}

function Split-List {
    param([string[]]$Values)
    $out = @()
    foreach ($v in @($Values | ForEach-Object { "$_" -split '[,;\s]+' } | Where-Object { $_ })) {
        if ($out -notcontains $v) { $out += $v }
    }
    return $out
}

. (Join-Path $testRoot 'lib/KnxLogo.ps1')
. (Join-Path $testRoot 'lib/KnxBench.ps1')
if (-not $Quiet) { Write-KnxLogo -Title 'Rig device check' }
$bench = Read-KnxBenchConfig -TestRoot $testRoot

# One comma separated string is accepted as well: -File passes an array only as separate arguments.
$Targets = @(Split-List $Targets)
$Via = @(Split-List $Via)
$AllowedLines = @(Split-List $AllowedLines)

if ($Targets.Count -eq 0 -and (Test-KnxObjectHas $bench 'rig')) {
    $fromBench = @()
    foreach ($f in @('p2pTarget', 'deviceTargets', 'ftcTarget', 'speedTarget')) {
        if (Test-KnxObjectHas $bench.rig $f) { $fromBench += "$($bench.rig.$f)" }
    }
    $Targets = @(Split-List $fromBench)
}
if ($Via.Count -eq 0 -and (Test-KnxObjectHas $bench 'devices')) {
    $Via = @(Split-List @($bench.devices.PSObject.Properties | ForEach-Object { "$($_.Value.ip)" }))
}
if ($AllowedLines.Count -eq 0 -and (Test-KnxObjectHas $bench 'safety') -and (Test-KnxObjectHas $bench.safety 'allowedLines')) {
    $AllowedLines = @(Split-List @($bench.safety.allowedLines))
}

if ($Targets.Count -eq 0) { Write-Host '  no TP device to check: -Targets is empty and Test-Bench-Config.json names none' -ForegroundColor Yellow; exit 0 }
if ($Via.Count -eq 0) { Write-Host '  no KNXnet/IP device to look through: pass -Via or enter the devices in Test-Bench-Config.json' -ForegroundColor Red; exit 2 }

$malformed = @($Targets | Where-Object { $_ -notmatch '^\d{1,2}\.\d{1,2}\.\d{1,3}$' })
if ($malformed.Count -gt 0) { Write-Host "  not an individual address: $($malformed -join ', ')" -ForegroundColor Red; exit 2 }

# Production lines are off limits, for a read as well.
if ($AllowedLines.Count -gt 0) {
    $offside = @($Targets | Where-Object { $AllowedLines -notcontains ((($_ -split '\.')[0, 1]) -join '.') })
    if ($offside.Count -gt 0) {
        Write-Host "  not checked: $($offside -join ', ') is outside the allowed lines $($AllowedLines -join ', '). Nothing was sent." -ForegroundColor Red
        exit 2
    }
}

Import-Module (Join-Path $testRoot 'lib/KnxTest.psm1') -Force
Import-Module (Join-Path $testRoot 'lib/KnxDevice.psm1') -Force -DisableNameChecking
$K = Get-KnxConstants

function Test-Target {
    <#
    .SYNOPSIS
        Asks one target for its device descriptor through one KNXnet/IP device.
    .DESCRIPTION
        State is 'answers', 'silent' (acknowledged on TP, no answer), 'absent' (nothing on TP
        acknowledged the request) or 'unchecked' (no tunnel, or the request never left).
    #>
    param([string]$ViaIp, [string]$Pa)
    $res = [pscustomobject]@{ State = 'unchecked'; Detail = ''; Attempts = 0 }
    $s = Open-KnxDeviceSession -Ip $ViaIp -Port $Port -Pa $Pa
    if (-not $s.Ok) { $res.Detail = $s.Reason; return $res }
    try {
        $r = $null
        while ($res.Attempts -lt 3) {
            $res.Attempts++
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@()) `
                                         -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs $TimeoutMs -Connectionless
            if ($r.Confirmed -ne $false -and $null -ne $r.Response) { break }
            if ($res.Attempts -lt 3) { [void](Wait-KnxTunnel -Connection $s.Conn -Ms 700) }
        }
        if ($null -ne $r.Response -and $r.Response.Length -ge 4) {
            $res.State = 'answers'
            $res.Detail = ('mask 0x{0:X4}' -f ((([int]$r.Response[2]) -shl 8) -bor ([int]$r.Response[3])))
        }
        elseif (-not $r.TunnelAcked) { $res.Detail = "$ViaIp did not take the request" }
        elseif ($r.Confirmed -eq $false) { $res.State = 'absent'; $res.Detail = 'nothing on the TP line acknowledged the request' }
        else { $res.State = 'silent'; $res.Detail = 'no A_DeviceDescriptor_Response' }
    }
    finally { Close-KnxDeviceSession -Session $s }
    return $res
}

# ─── Check ──────────────────────────────────────────────────────────────────────

if (-not $Quiet) {
    Write-Host "  targets: $($Targets -join ', ')" -ForegroundColor DarkGray
    Write-Host "  through: $($Via -join ', ') (first one that grants a tunnel)" -ForegroundColor DarkGray
    Write-Host ''
}

$missing = 0
$unchecked = 0
$usedVia = ''
$ownPa = @{}
foreach ($pa in $Targets) {
    $res = $null
    $tryVia = $Via
    if ($usedVia) { $tryVia = @($usedVia) }
    foreach ($v in $tryVia) {
        # A device does not answer a telegram it sends to itself, so its own address is not asked through it.
        if (-not $ownPa.ContainsKey($v)) {
            $ownPa[$v] = ''
            try { $d = Get-KnxDescription -Ip $v -Port $Port -TimeoutMs 2000; if ($null -ne $d -and $null -ne $d.Device) { $ownPa[$v] = [string]$d.Device.IndividualAddr } } catch { }
        }
        if ($ownPa[$v] -eq $pa) { $res = [pscustomobject]@{ State = 'answers'; Detail = "is $v itself, which answered on IP"; Attempts = 0 }; break }
        # A host the system has no route to makes the socket throw instead of timing out.
        try { $res = Test-Target -ViaIp $v -Pa $pa }
        catch { $res = [pscustomobject]@{ State = 'unchecked'; Detail = "$v is not reachable: $($_.Exception.Message)"; Attempts = 0 } }
        if ($res.State -ne 'unchecked') { $usedVia = $v; break }
        if (-not $Quiet) { Write-Line 'WARN' "no tunnel on $v for $pa - $($res.Detail)" 'Yellow' }
    }
    $where = ''
    if ($usedVia) { $where = " through $usedVia" }
    switch ($res.State) {
        'answers' {
            $note = ''
            if ($res.Attempts -gt 1) { $note = ", on attempt $($res.Attempts) of 3" }
            Write-Line 'OK' "$pa answers$where ($($res.Detail)$note)" 'Green'
        }
        'absent'  { $missing++; Write-Line 'FAIL' "$pa is not on the bus$where - $($res.Detail), 3 attempts" 'Red' }
        'silent'  { $missing++; Write-Line 'FAIL' "$pa is acknowledged on the bus but does not answer$where - $($res.Detail), 3 attempts" 'Red' }
        default   { $unchecked++; Write-Line 'FAIL' "$pa could not be checked - $($res.Detail)" 'Red' }
    }
}

Write-Host ''
if ($missing -eq 0 -and $unchecked -eq 0) { Write-Host "  the rig devices answer ($($Targets.Count) of $($Targets.Count))" -ForegroundColor Green; exit 0 }
if ($missing -gt 0) {
    Write-Host "  $missing of $($Targets.Count) rig device(s) do not answer. Check bus power and the TP wiring of the device." -ForegroundColor Red
    exit 1
}
Write-Host "  $unchecked of $($Targets.Count) rig device(s) could not be checked: no KNXnet/IP device granted a tunnel." -ForegroundColor Red
exit 2
