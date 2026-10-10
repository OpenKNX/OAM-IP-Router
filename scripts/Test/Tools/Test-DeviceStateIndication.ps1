#!/usr/bin/env pwsh
# Open ■
# ┬────┴  Test-DeviceStateIndication
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/Tools/Test-DeviceStateIndication.ps1

<#
.SYNOPSIS
    Proves the evented PID_KNXNETIP_DEVICE_STATE: a local value change without bus traffic, and
    a real KNX fault by cutting the TP line through rig relays (DS-KF-1..3).

.DESCRIPTION
    03_08_03 2.5.20 p.14 requires PID_KNXNETIP_DEVICE_STATE on every KNXnet/IP server and
    requires it to be evented: a change is reported with M_PropInfo.ind. The frame is pinned
    by 08_TSSH 4.2.12 p.41:

        DEVICE_CONFIGURATION_REQUEST, total length 0x0012
        cEMI  F7 | 00 0B | 01 | 45 | 10 01 | <state>

    The conformance case for this (H-4.2.12, tool 20212) drives a load switch that opens the
    TP line. That measurement is IMPOSSIBLE on a bus-powered device: cutting TP cuts its
    supply, so it cannot report anything. This tool measures the half that can be measured
    there - that a value change is turned into a correctly formed M_PropInfo.ind and
    delivered on the open device management connection.

    It changes the value with a local A_PropertyValue_Write carried over the cEMI Transport
    Layer of the very same device management connection (03_06_03 4.1.6 / AN118), so nothing
    is sent on the bus and no second interface is needed. The IP-fault bit (bit 1) is used,
    not the KNX-fault bit: bit 0 is recomputed from the bus state on every loop pass and
    would be corrected back within milliseconds.

    The real bus failure (bit 0, 03_08_03 3.5.2 p.20) is judged by the KNX-fault cases DS-KF-1..3:
    a rig relay cuts the TP of the externally powered device under test, through -PowerRelayVia,
    while a device management connection is held open. They run only with the power guard on,
    relays configured, -Ip in -PowerRelayFeeds, -PowerRelayVia not in it and -IncludeDestructive;
    otherwise NOT-RUN.

    Exit: 0 all passed, 1 a check failed, 2 rig fault (a relay not confirmed ON after the cut),
    3 the KNX-fault cases did not all run.

.PARAMETER Ip
    IP address of the device under test.

.PARAMETER Port
    KNXnet/IP port, default 3671.

.PARAMETER ObjectIndex
    Interface object index of the KNXnet/IP parameter object. 6 on Bau07B0IP.

.PARAMETER BdutPa
    Individual address of the device under test; Assert-KnxRigPower waits for it after a relay restore.

.PARAMETER IncludeDestructive
    Allows the KNX-fault cases: cutting the TP changes the device state.

.PARAMETER PowerGuard
    on | off (default). The KNX-fault cases need it on.

.PARAMETER PowerRelayWrite
    Relay switch GAs, comma separated. The FIRST one is cut; it must cut the TP of every -PowerRelayFeeds device.

.PARAMETER PowerRelayStatus
    Relay status GAs, same order as -PowerRelayWrite.

.PARAMETER PowerRelayVia
    Interface that carries every relay telegram. Must not be in -PowerRelayFeeds.

.PARAMETER PowerRelayFeeds
    Device under test IPs whose TP the relays cut, comma separated.

.PARAMETER ReportDir
    Where the case report goes. Default: scripts/Test/Reports.

.EXAMPLE
    ./Test-DeviceStateIndication.ps1 -Ip 11.11.0.210
.EXAMPLE
    ./Test-DeviceStateIndication.ps1 -Ip 11.11.0.126 -BdutPa 1.1.0 -IncludeDestructive -PowerGuard on `
        -PowerRelayWrite 0/3/100,0/3/110 -PowerRelayStatus 0/3/101,0/3/111 -PowerRelayVia 11.11.0.2 -PowerRelayFeeds 11.11.0.126
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Ip,
    [int]$Port = 3671,
    [int]$ObjectIndex = 6,
    [string]$BdutPa = '',
    [switch]$IncludeDestructive,
    [ValidateSet('on', 'off')]
    [string]$PowerGuard = 'off',
    [string]$PowerRelayWrite = '',
    [string]$PowerRelayStatus = '',
    [string]$PowerRelayVia = '',
    [string]$PowerRelayFeeds = '',
    [string]$ReportDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $here 'lib/KnxTest.psm1') -Force
Import-Module (Join-Path $here 'lib/KnxDevice.psm1') -Force -DisableNameChecking

$K = Get-KnxConstants
$PidState = $K.Pid.KNXNETIP_DEVICE_STATE
$OtIp = $K.ObjType.KNXNETIP_PARAM
$IpFault = 0x02

function Show-Ok  { param([string]$T) Write-Host "  PASS  $T" -ForegroundColor Green }
function Show-Bad { param([string]$T) Write-Host "  FAIL  $T" -ForegroundColor Red }

. (Join-Path $PSScriptRoot '../lib/KnxLogo.ps1')
Write-KnxLogo -Title 'Test-DeviceStateIndication'
Write-Host '  PID_KNXNETIP_DEVICE_STATE - evented device state' -ForegroundColor White
Write-Host '  03_08_03 2.5.20 p.14 - frame per 08_TSSH 4.2.12 p.41'
Write-Host '  ---------------------------------------------------------------'

$script:failures = 0
$script:notJudged = $false
$conn = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
if (-not $conn.Ok) { Show-Bad "no device management connection ($($conn.StatusName))"; exit 1 }

function Assert-Indication {
    param($Connection, [string]$What, [int]$ExpectState)
    $ind = Wait-KnxPropInfo -Connection $Connection -Ip $Ip -Port $Port -TimeoutMs 5000 -PropertyId $PidState
    if ($null -eq $ind) { Show-Bad "$What - no M_PropInfo.ind"; $script:failures++; return }
    Write-Host ("        frame: " + (ConvertTo-HexString -Bytes $ind)) -ForegroundColor DarkGray
    $bad = 0
    if ($ind.Length -lt 8) { Show-Bad "$What - indication too short"; $script:failures++; return }
    if ($ind[0] -ne 0xF7) { Show-Bad ("$What - message code 0x{0:X2}, expected 0xF7" -f $ind[0]); $bad++ }
    $ot = Get-Uint16 -Bytes $ind -Offset 1
    if ($ot -ne $OtIp) { Show-Bad ("$What - object type $ot, expected $OtIp"); $bad++ }
    if ($ind[3] -ne 1) { Show-Bad ("$What - object instance $($ind[3]), expected 1"); $bad++ }
    if ($ind[4] -ne $PidState) { Show-Bad ("$What - PID $($ind[4]), expected $PidState"); $bad++ }
    if ($ind[5] -ne 0x10 -or $ind[6] -ne 0x01) { Show-Bad ("$What - element/index {0:X2}{1:X2}, expected 1001" -f $ind[5], $ind[6]); $bad++ }
    if ($ind[7] -ne $ExpectState) { Show-Bad ("$What - state 0x{0:X2}, expected 0x{1:X2}" -f $ind[7], $ExpectState); $bad++ }
    if ($bad -eq 0) { Show-Ok ("$What - state 0x{0:X2}, frame matches 08_TSSH 4.2.12" -f $ind[7]) }
    $script:failures += $bad
}

function Test-StateWriteRefused {
    <#
    .SYNOPSIS
        A status property must refuse a write.
    .DESCRIPTION
        03_08_03 2.5.20 p.14 describes PID_KNXNETIP_DEVICE_STATE as status information the DEVICE sets
        when a network cannot be accessed - bit 0 KNX fault, bit 1 IP fault. It is not a control, and a
        conformant server refuses a write to it. Measured on 11.11.0.210: NEGATIVE con, error 0x05
        (Read Only). Until 2026-09-26 this script tried to PROVOKE the evented indication by writing the
        property; the device refused, nothing changed, no indication was due, and the script reported two
        device failures for behaving correctly.
    #>
    param($Connection, [int]$Value)
    $tpdu = New-TpduPropertyValueWrite -ObjectIndex $ObjectIndex -PropertyId $PidState -ElementCount 1 -StartIndex 1 -Data ([byte[]]@($Value))
    $cemi = New-CemiTransport -MessageCode 0x4A -Tpdu $tpdu
    $r = Send-KnxDeviceConfiguration -Connection $Connection -Cemi $cemi -TimeoutMs 4000
    if ($null -eq $r -or $null -eq $r.Parsed) {
        Show-Bad 'write to the read-only state property produced no answer at all'
        $script:failures++
        return
    }
    if ($r.Parsed.IsError) {
        Show-Ok 'a write to the status property is refused, as a status property must'
    }
    else {
        Show-Bad 'the device ACCEPTED a write to PID_KNXNETIP_DEVICE_STATE - it is status, not control (03_08_03 2.5.20 p.14)'
        $script:failures++
    }
}

try {
    $r = Read-KnxProperty -Connection $conn -ObjectType $OtIp -PropertyId $PidState
    if ($null -eq $r.Parsed -or $r.Parsed.IsError) { Show-Bad 'PID_KNXNETIP_DEVICE_STATE is not readable - the property is missing'; exit 1 }
    $state0 = $r.Parsed.Data[0]
    Show-Ok ("property readable, state = 0x{0:X2}" -f $state0)
    if ($state0 -ne 0) { Write-Host "        note: expected 0x00 with the bus up and the network up" -ForegroundColor Yellow }

    Write-Host ''
    Write-Host '  a status property must refuse a write ...' -ForegroundColor Cyan
    Test-StateWriteRefused -Connection $conn -Value ($state0 -bor $IpFault)

    $r = Read-KnxProperty -Connection $conn -ObjectType $OtIp -PropertyId $PidState
    $stateEnd = if ($null -ne $r.Parsed -and -not $r.Parsed.IsError) { $r.Parsed.Data[0] } else { 0xFF }
    if ($stateEnd -eq $state0) { Show-Ok ("state unchanged at 0x{0:X2} after the refused write" -f $stateEnd) }
    else { Show-Bad ("the refused write still changed the state: 0x{0:X2} -> 0x{1:X2}" -f $state0, $stateEnd); $script:failures++ }

}
finally {
    [void](Close-KnxConnection -Connection $conn)
}

# --- KNX fault through the rig relays ------------------------------------------------------------
# a) DM connection  b) precheck  c) cut the first relay  d) DS-KF-1  e) DS-KF-2  f) restore in finally, watch the clear, Assert-KnxRigPower  g) DS-KF-3  h) close

$T = Get-KnxRigFaultTiming
$relayWrite = Split-KnxRigList $PowerRelayWrite
$relayStatus = Split-KnxRigList $PowerRelayStatus
$feeds = Split-KnxRigList $PowerRelayFeeds
if (-not $ReportDir) { $ReportDir = Join-Path $here 'Reports' }
$kfSuite = 'Device state - KNX fault'
$guardText = if ($PowerGuard -eq 'on') { "on - relays $PowerRelayWrite (status $PowerRelayStatus) via $PowerRelayVia, feeds $PowerRelayFeeds" } else { 'off' }
[void](Start-KnxTestRun -Product 'device-state' -BdutIp $Ip -RunProfile 'DeviceState' -Environment @{
        'Rig power guard' = $guardText
        'Destructive'     = $(if ($IncludeDestructive) { 'yes' } else { 'no' })
        'KNX-fault budgets' = ('E_KNX_CONNECTION {0} s, PID 69 set {1} s, clear {2} s, poll {3} ms' -f ($T.ConnStateMs / 1000), ($T.PropInfoMs / 1000), ($T.ClearMs / 1000), $T.PollMs)
    })

function Get-FaultGate {
    <#
    .SYNOPSIS
        $null when the KNX-fault cases may run, else Missing + Reason for NOT-RUN.
    #>
    $nr = { param($m, $r) return [pscustomobject]@{ Missing = $m; Reason = $r } }
    if ($PowerGuard -ne 'on') { return (& $nr '-PowerGuard on' 'the KNX-fault cases cut the TP through the rig relays, and the rig power guard is off') }
    if ($relayWrite.Count -eq 0 -or $relayWrite.Count -ne $relayStatus.Count) {
        return (& $nr '-PowerRelayWrite/-PowerRelayStatus' "relays not configured: $($relayWrite.Count) write GA(s), $($relayStatus.Count) status GA(s)")
    }
    $bad = @(($relayWrite + $relayStatus) | Where-Object { -not (Test-KnxGaText $_) })
    if ($bad.Count -gt 0) { return (& $nr '-PowerRelayWrite/-PowerRelayStatus' "not a group address in range: $($bad -join ', ')") }
    if ($feeds.Count -eq 0) { return (& $nr '-PowerRelayFeeds' 'no device under test is named whose TP the relays cut') }
    if ($feeds -notcontains $Ip) { return (& $nr '-PowerRelayFeeds' "-Ip $Ip is not in -PowerRelayFeeds ($($feeds -join ', ')) - the rig relays do not cut its TP") }
    if (-not $PowerRelayVia) { return (& $nr '-PowerRelayVia' 'no control interface for the relay telegrams') }
    if ($feeds -contains $PowerRelayVia) { return (& $nr '-PowerRelayVia' "-PowerRelayVia $PowerRelayVia is in -PowerRelayFeeds - the relay telegrams would go through an interface whose TP is cut") }
    if (-not $IncludeDestructive) { return (& $nr '-IncludeDestructive' 'cutting the TP changes the device state; the run does not allow destructive cases') }
    return $null
}

$fx = [pscustomobject]@{
    Gate = (Get-FaultGate); Skip = ''; SetupError = ''; Dm = $null; Log = (New-KnxDeviceStateLog)
    CutGa = ''; CutStatusGa = ''; CutPending = $false; CutNote = ''
    Restore = $null; RestoreRetried = $false; RestoreConfirmed = $false; RestoreNote = ''; RestoreError = ''; Guard = $null; RigFault = ''
}

function Find-FaultState {
    <#
    .SYNOPSIS
        First CONNECTIONSTATE answer with -Status at or after -After, or $null.
    #>
    param($Log, $After, [int]$Status)
    if ($null -eq $After) { return $null }
    foreach ($e in $Log.States) { if ($e.At -ge $After -and $e.Status -eq $Status) { return $e } }
    return $null
}

function Find-FaultIndication {
    <#
    .SYNOPSIS
        First PID 69 M_PropInfo.ind with bit 0 = -Bit0 at or after -After, or $null.
    #>
    param($Log, $After, [int]$Bit0)
    if ($null -eq $After) { return $null }
    foreach ($e in $Log.Indications) { if ($e.At -ge $After -and ($e.Value -band 1) -eq $Bit0) { return $e } }
    return $null
}

function Get-FaultSpan {
    <#
    .SYNOPSIS
        Unrounded seconds from -From to -To; -1 when -To is missing.
    #>
    param($From, $To)
    if ($null -eq $To -or $null -eq $From) { return -1.0 }
    return ($To - $From).TotalSeconds
}

function Format-FaultSec { param([double]$S) return ('{0:0.00}' -f $S) }

function Get-FaultStateTrace {
    <#
    .SYNOPSIS
        The CONNECTIONSTATE answers after -After, as value runs: "0x00 @0.01 s x3 -> 0x27 @1.72 s x4".
    #>
    param($Log, $After)
    $parts = @(); $last = -2; $n = 0
    foreach ($e in $Log.States) {
        if ($e.At -lt $After) { continue }
        if ($e.Status -ne $last) {
            if ($n -gt 0) { $parts[-1] += " x$n" }
            $parts += ('0x{0:X2} @{1} s' -f $e.Status, (Format-FaultSec (Get-FaultSpan $After $e.At))); $last = $e.Status; $n = 0
        }
        $n++
    }
    if ($n -gt 0) { $parts[-1] += " x$n" }
    if ($parts.Count -eq 0) { return 'no answer' }
    return ($parts -join ' -> ')
}

function Get-FaultStateResult {
    <#
    .SYNOPSIS
        Judges "CONNECTIONSTATE -Want within -BudgetS after -Ref" from the polled answers.
    .DESCRIPTION
        pass: the first -Want answer came within the budget. fail: an answer at or after the budget still showed
        another status, or every poll over the window went unanswered. open: the polls do not cover the budget edge.
    .OUTPUTS
        Result (pass | fail | open), Text, Timing.
    #>
    param($Ref, [string]$RefText, [double]$BudgetS, [int]$Want, [string]$What)
    $after = @($fx.Log.States | Where-Object { $_.At -ge $Ref })
    $hit = Find-FaultState $fx.Log $Ref $Want
    $gap = 0.0; $prevAt = $Ref
    foreach ($e in $after) { $g = Get-FaultSpan $prevAt $e.At; if ($g -gt $gap) { $gap = $g }; $prevAt = $e.At }
    $span = if ($after.Count -gt 0) { "answers $(Format-FaultSec (Get-FaultSpan $Ref $after[0].At))-$(Format-FaultSec (Get-FaultSpan $Ref $after[-1].At)) s, $($after.Count) answers, largest gap $(Format-FaultSec $gap) s" } else { 'no answers' }
    $wantTxt = '0x{0:X2}' -f $Want
    if ($null -ne $hit) {
        $prev = @($after | Where-Object { $_.At -lt $hit.At })
        $floor = if ($prev.Count -gt 0) { $prev[-1].At } else { $Ref }
        $t = Get-FaultSpan $Ref $hit.At; $f = Get-FaultSpan $Ref $floor
        $res = "poll resolution: last other answer at $(Format-FaultSec $f) s, first $wantTxt answer at $(Format-FaultSec $t) s"
        if ($t -le $BudgetS) { return [pscustomobject]@{ Result = 'pass'; Text = $res; Timing = "$What $(Format-FaultSec $t) s after $RefText (budget $BudgetS s; $res)" } }
        if ($f -ge $BudgetS) { return [pscustomobject]@{ Result = 'fail'; Text = "$What came $(Format-FaultSec $t) s after $RefText, budget $BudgetS s ($res)"; Timing = '' } }
        return [pscustomobject]@{ Result = 'open'; Text = "$What first answered at $(Format-FaultSec $t) s, the poll before at $(Format-FaultSec $f) s - not resolvable against the $BudgetS s budget (window not polled)"; Timing = '' }
    }
    $late = @($after | Where-Object { (Get-FaultSpan $Ref $_.At) -ge $BudgetS })
    if ($late.Count -gt 0) {
        return [pscustomobject]@{ Result = 'fail'; Text = ('no {0}: still 0x{1:X2} at {2} s after {3}, budget {4} s ({5})' -f $What, $late[-1].Status, (Format-FaultSec (Get-FaultSpan $Ref $late[-1].At)), $RefText, $BudgetS, $span); Timing = '' }
    }
    $polls = @($fx.Log.PollTimes | Where-Object { $_ -ge $Ref })
    if ($after.Count -eq 0 -and $polls.Count -gt 0 -and (Get-FaultSpan $Ref $polls[-1]) -ge ($BudgetS - 2 * $T.PollMs / 1000.0)) {
        return [pscustomobject]@{ Result = 'fail'; Text = "no $What`: no CONNECTIONSTATE_RESPONSE to $($polls.Count) polls up to $(Format-FaultSec (Get-FaultSpan $Ref $polls[-1])) s after $RefText"; Timing = '' }
    }
    return [pscustomobject]@{ Result = 'open'; Text = "no $What seen, but CONNECTIONSTATE was answered only up to $(if ($after.Count -gt 0) { Format-FaultSec (Get-FaultSpan $Ref $after[-1].At) } else { 'none' }) s of the $BudgetS s window ($span)"; Timing = '' }
}

function Get-FaultIndicationResult {
    <#
    .SYNOPSIS
        Judges "M_PropInfo.ind PID 69 with bit 0 = -Bit0 within -BudgetS after -Ref".
    .DESCRIPTION
        pass: read within the budget. fail: it cannot have arrived within the budget, or none came while the socket
        was read past the budget. open: it was read late after a stretch the socket was not read.
    #>
    param($Ref, [string]$RefText, [double]$BudgetS, [int]$Bit0, [string]$What)
    $e = Find-FaultIndication $fx.Log $Ref $Bit0
    if ($null -ne $e) {
        $t = Get-FaultSpan $Ref $e.At
        $f = if ($null -ne $e.Earliest -and $e.Earliest -gt $Ref) { Get-FaultSpan $Ref $e.Earliest } else { 0.0 }
        $res = "socket seen empty at $(Format-FaultSec $f) s, indication read at $(Format-FaultSec $t) s"
        if ($t -le $BudgetS) { return [pscustomobject]@{ Result = 'pass'; Entry = $e; Text = $res; Timing = "$What $(Format-FaultSec $t) s after $RefText (budget $BudgetS s; $res)" } }
        if ($f -gt $BudgetS) { return [pscustomobject]@{ Result = 'fail'; Entry = $e; Text = "$What came $(Format-FaultSec $t) s after $RefText, budget $BudgetS s ($res)"; Timing = '' } }
        return [pscustomobject]@{ Result = 'open'; Entry = $e; Text = "$What read at $(Format-FaultSec $t) s, but the socket was not read since $(Format-FaultSec $f) s - not resolvable against the $BudgetS s budget"; Timing = '' }
    }
    $r = Get-FaultSpan $Ref $fx.Log.EmptyAt
    if ($r -ge $BudgetS) { return [pscustomobject]@{ Result = 'fail'; Entry = $null; Text = "no $What within $BudgetS s (socket read until $(Format-FaultSec $r) s after $RefText)"; Timing = '' } }
    return [pscustomobject]@{ Result = 'open'; Entry = $null; Text = "no $What seen, but the socket was read only until $(Format-FaultSec $r) s of the $BudgetS s window"; Timing = '' }
}

function Assert-FaultReady {
    <#
    .SYNOPSIS
        Ends the case as NOT-RUN, SKIP or with the setup error when the cut is not in place.
    #>
    if ($null -ne $fx.Gate) { Set-KnxTestNotRun -MissingInput $fx.Gate.Missing -Reason $fx.Gate.Reason }
    if ($fx.SetupError) { throw "setup error before the cases: $($fx.SetupError)" }
    if ($fx.Skip) { Set-KnxTestSkip $fx.Skip }
}

function Initialize-Fault {
    <#
    .SYNOPSIS
        Steps a) to c): DM connection, precheck, cut of the first relay with its OFF status confirmed.
    #>
    $fx.CutGa = $relayWrite[0]; $fx.CutStatusGa = $relayStatus[0]
    Write-Host ''
    Write-Host "  KNX fault: relay $($fx.CutGa) (status $($fx.CutStatusGa)) via $PowerRelayVia cuts the TP of $Ip" -ForegroundColor Cyan
    $fx.Dm = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
    if (-not $fx.Dm.Ok) { $fx.Skip = "no device management connection to $Ip ($($fx.Dm.StatusName))"; return }

    $pre = [DateTime]::UtcNow
    [void](Watch-KnxDeviceState -Connection $fx.Dm -Log $fx.Log -TimeoutMs 2000 -Until { param($l) $l.States.Count -gt 0 })
    $s0 = if ($fx.Log.States.Count -gt 0) { $fx.Log.States[$fx.Log.States.Count - 1].Status } else { -1 }
    if ($s0 -ne 0) {
        $what = if ($s0 -lt 0) { 'unanswered' } else { '0x{0:X2}' -f $s0 }
        $fx.Skip = "precheck: CONNECTIONSTATE before the cut is $what, expected 0x00"; return
    }
    $rel = Get-KnxRigRelayState -Via $PowerRelayVia -Port $Port -StatusGa $relayStatus
    if (-not $rel.Ok) { $fx.Skip = "precheck: relay status not readable - $($rel.Detail)"; return }
    if (@($rel.States | Where-Object { $_.State -ne 'on' }).Count -gt 0) { $fx.Skip = "precheck: not every relay reads ON - $($rel.Detail)"; return }
    Write-Host ("  precheck: CONNECTIONSTATE 0x00 ({0} s), {1}" -f (Format-FaultSec (Get-FaultSpan $pre ([DateTime]::UtcNow))), $rel.Detail) -ForegroundColor DarkGray

    $fx.CutPending = $true
    $cut = Set-KnxRigRelay -Via $PowerRelayVia -Port $Port -WriteGa $fx.CutGa -Value 0
    $fx.Log.CutAt = $cut.SentAt
    if (-not $cut.Attempted) { $fx.CutPending = $false; $fx.Skip = "cut not sent - $($cut.Detail)"; return }
    [void](Watch-KnxDeviceState -Connection $fx.Dm -Log $fx.Log -TimeoutMs $T.SwitchSettleMs)
    # The status read blocks the DM socket; the results account for that stretch (Earliest / poll gaps).
    $chk = Get-KnxRigRelayState -Via $PowerRelayVia -Port $Port -StatusGa @($fx.CutStatusGa)
    $st = if ($chk.Ok -and @($chk.States).Count -gt 0) { $chk.States[0].State } else { 'not read' }
    $fx.CutNote = "cut $($cut.Detail); $($fx.CutStatusGa)=$st $(Format-FaultSec (Get-FaultSpan $fx.Log.CutAt ([DateTime]::UtcNow))) s after the write"
    Write-Host "  $($fx.CutNote)" -ForegroundColor DarkGray
    if ($st -ne 'off') { $fx.Skip = "relay $($fx.CutGa) not confirmed OFF after the cut ($($fx.CutStatusGa)=$st) - restored, nothing judged" }
}

function Restore-Fault {
    <#
    .SYNOPSIS
        Step f): restore write repeated until acked, the clear watched, the relay confirmed ON (bounded), then Assert-KnxRigPower.
    .DESCRIPTION
        Sets RigFault when the cut relay is not confirmed ON at the end; the script then exits 2.
    #>
    if (-not $fx.CutPending) { return }
    $notes = @()
    try {
        $deadline = [DateTime]::UtcNow.AddMilliseconds($T.RestoreMs)
        while ($true) {
            $w = $null
            try { $w = Set-KnxRigRelay -Via $PowerRelayVia -Port $Port -WriteGa $fx.CutGa -Value 1 }
            catch { $notes += "restore write error: $($_.Exception.Message)" }
            if ($null -ne $w) {
                $notes += "restore $($w.Detail)"
                if ($w.Attempted -and $null -eq $fx.Restore) { $fx.Restore = $w; $fx.Log.RestoreAt = $w.SentAt }
                if ($w.Acked) { break }
            }
            if ([DateTime]::UtcNow -ge $deadline) { break }
            Start-Sleep -Milliseconds $T.RetryMs
        }
        if ($null -ne $fx.Restore -and $fx.Restore.Acked -and -not $fx.Skip -and $null -ne $fx.Dm -and $fx.Dm.Ok) {
            try {
                [void](Watch-KnxDeviceState -Connection $fx.Dm -Log $fx.Log -TimeoutMs ($T.ClearMs + 2 * $T.PollMs) -Until {
                        param($l)
                        ($null -ne (Find-FaultIndication $l $l.RestoreAt 0)) -and ($null -ne (Find-FaultState $l $l.RestoreAt 0))
                    })
            }
            catch { $fx.RestoreError = "$($_.Exception.Message)"; $notes += "watch error: $($fx.RestoreError)" }
        }
        $deadline = [DateTime]::UtcNow.AddMilliseconds($T.RestoreMs)
        while ($true) {
            $st = 'not read'
            try {
                $chk = Get-KnxRigRelayState -Via $PowerRelayVia -Port $Port -StatusGa @($fx.CutStatusGa)
                if ($chk.Ok -and @($chk.States).Count -gt 0) { $st = $chk.States[0].State }
            }
            catch { $st = "error: $($_.Exception.Message)" }
            if ($st -eq 'on') { $fx.RestoreConfirmed = $true; $notes += "$($fx.CutStatusGa)=on"; break }
            $notes += "$($fx.CutStatusGa)=$st"
            if ([DateTime]::UtcNow -ge $deadline) { break }
            $fx.RestoreRetried = $true
            try { $w = Set-KnxRigRelay -Via $PowerRelayVia -Port $Port -WriteGa $fx.CutGa -Value 1; $notes += "restore again $($w.Detail)" }
            catch { $notes += "restore write error: $($_.Exception.Message)" }
            Start-Sleep -Milliseconds $T.RetryMs
        }
    }
    catch { $notes += "restore error: $($_.Exception.Message)" }
    finally {
        $fx.RestoreNote = ($notes -join '; ')
        Write-Host "  $($fx.RestoreNote)" -ForegroundColor $(if ($fx.RestoreConfirmed -and -not $fx.RestoreRetried) { 'DarkGray' } else { 'Yellow' })
        try {
            $fx.Guard = Assert-KnxRigPower -Via $PowerRelayVia -Port $Port -WriteGa $PowerRelayWrite -StatusGa $PowerRelayStatus -DutPa $BdutPa
            $col = if (-not $fx.Guard.Ok) { 'Red' } elseif ($fx.Guard.Restored) { 'Yellow' } else { 'DarkGray' }
            Write-Host "  Rig power after the restore: $(if ($fx.Guard.Restored) { 'RESTORED - ' })$($fx.Guard.Detail)" -ForegroundColor $col
        }
        catch { Write-Host "  RIG WARNING: Assert-KnxRigPower failed after the restore - $($_.Exception.Message)" -ForegroundColor Red }
        $guardOk = ($null -ne $fx.Guard -and $fx.Guard.Ok)
        if (-not $fx.RestoreConfirmed -and -not ($guardOk -and $fx.Guard.Restored)) { $fx.RigFault = "relay $($fx.CutGa) is OFF, switch on via $PowerRelayVia" }
        elseif (-not $guardOk) { $fx.RigFault = "rig power not confirmed after the restore ($(if ($null -ne $fx.Guard) { $fx.Guard.Detail } else { 'Assert-KnxRigPower failed' })) - switch $PowerRelayWrite on via $PowerRelayVia" }
        if ($fx.RigFault) { Write-Host "  RIG FAULT: $($fx.RigFault)" -ForegroundColor Red }
    }
}

Write-Host ''
Write-Host '  KNX fault through the rig relays ...' -ForegroundColor Cyan
try {
    if ($null -eq $fx.Gate) {
        try { Initialize-Fault } catch { $fx.SetupError = "$($_.Exception.Message)" }
    }

    Invoke-KnxTestCase -Suite $kfSuite -Id 'DS-KF-1' -Title 'KNX fault is reported in CONNECTIONSTATE' `
        -Clause '03_08_02 CONNECTIONSTATE_RESPONSE E_KNX_CONNECTION; TSSH 3.5.4 (fn 10503)' -Body {
        Assert-FaultReady
        $cutAt = $fx.Log.CutAt
        $budget = $T.ConnStateMs / 1000.0
        # One poll past the budget, so "still 0x00" rests on an answer at or after it.
        $left = [int]($T.ConnStateMs + 2 * $T.PollMs - ([DateTime]::UtcNow - $cutAt).TotalMilliseconds)
        [void](Watch-KnxDeviceState -Connection $fx.Dm -Log $fx.Log -TimeoutMs $left -Until {
                param($l)
                ($null -ne (Find-FaultState $l $l.CutAt 0x27)) -or
                (@($l.States | Where-Object { ($_.At - $l.CutAt).TotalSeconds -ge ($T.ConnStateMs / 1000.0) }).Count -gt 0)
            })
        $v = Get-FaultStateResult -Ref $cutAt -RefText 'the cut' -BudgetS $budget -Want 0x27 -What 'E_KNX_CONNECTION'
        Add-KnxEvidence -Note $fx.CutNote
        Add-KnxEvidence -Note "CONNECTIONSTATE after the cut: $(Get-FaultStateTrace $fx.Log $cutAt) ($($fx.Log.Polls) polls in total)"
        if ($v.Result -eq 'pass') { Add-KnxEvidence -Note "timing: $($v.Timing)" } else { Add-KnxEvidence -Note $v.Text }
        Assert-KnxTrue (-not $fx.Log.Disconnected) 'the device closed the device management connection after the cut'
        if ($v.Result -eq 'open') { Set-KnxTestSkip $v.Text }
        Assert-KnxTrue ($v.Result -eq 'pass') $v.Text
    }

    Invoke-KnxTestCase -Suite $kfSuite -Id 'DS-KF-2' -Title 'KNX fault raises PID_KNXNETIP_DEVICE_STATE with M_PropInfo.ind' `
        -Clause '03_08_03 2.5.20 p.14; TSSH 4.2.12 (fn 20212)' -Body {
        Assert-FaultReady
        $cutAt = $fx.Log.CutAt
        $budget = $T.PropInfoMs / 1000.0
        $left = [int]($T.PropInfoMs + $T.PollMs - ([DateTime]::UtcNow - $cutAt).TotalMilliseconds)
        [void](Watch-KnxDeviceState -Connection $fx.Dm -Log $fx.Log -TimeoutMs $left -Until { param($l) $null -ne (Find-FaultIndication $l $l.CutAt 1) })
        $v = Get-FaultIndicationResult -Ref $cutAt -RefText 'the cut' -BudgetS $budget -Bit0 1 -What 'PID 69 bit 0 = 1 indicated'
        $seen = @($fx.Log.Indications | Where-Object { $_.At -ge $cutAt } | ForEach-Object { '0x{0:X2} @{1} s' -f $_.Value, (Format-FaultSec (Get-FaultSpan $cutAt $_.At)) })
        Add-KnxEvidence -Note "PID 69 indications after the cut: $(if ($seen.Count -gt 0) { $seen -join ', ' } else { 'none' })"
        if ($null -ne $v.Entry) { Add-KnxEvidence -Received $v.Entry.Cemi }
        if ($v.Result -eq 'pass') { Add-KnxEvidence -Note "timing: $($v.Timing)" } else { Add-KnxEvidence -Note $v.Text }
        Assert-KnxTrue (-not $fx.Log.Disconnected) 'the device closed the device management connection after the cut'
        if ($v.Result -eq 'open') { Set-KnxTestSkip $v.Text }
        Assert-KnxTrue ($v.Result -eq 'pass') $v.Text
        $rd = Read-KnxDeviceStateValue -Connection $fx.Dm -Log $fx.Log
        Add-KnxEvidence -Note "M_PropRead PID 69 during the cut: $($rd.Detail)"
        Assert-KnxTrue ($rd.Value -ge 0) "PID 69 not read during the cut: $($rd.Detail)"
        Assert-KnxTrue (($rd.Value -band 1) -eq 1) ('PID 69 reads 0x{0:X2} during the cut, bit 0 not set' -f $rd.Value)
    }
}
finally {
    Restore-Fault
}

Invoke-KnxTestCase -Suite $kfSuite -Id 'DS-KF-3' -Title 'Bus return clears the KNX fault' `
    -Clause '03_08_03 2.5.20 p.14; 03_08_02 CONNECTIONSTATE_RESPONSE; TSSH 4.2.12 (fn 20212)' -Body {
    Assert-FaultReady
    Add-KnxEvidence -Note $fx.RestoreNote
    if ($null -ne $fx.Guard) { Add-KnxEvidence -Note "rig power after the restore: $($fx.Guard.Detail)" }
    # Rig faults end the case before any result on the device.
    if ($fx.RigFault) { Set-KnxTestSkip "RIG FAULT: $($fx.RigFault)" }
    if ($null -eq $fx.Restore) { Set-KnxTestSkip "the restore write was not sent - $($fx.RestoreNote)" }
    if (-not $fx.Restore.Acked) { Set-KnxTestSkip "the first restore write was not acked by $PowerRelayVia - its send time is no reference" }
    if ($fx.RestoreRetried) { Set-KnxTestSkip "the first restore write did not bring $($fx.CutStatusGa) back on; a further write was needed" }
    if ($null -ne $fx.Guard -and $fx.Guard.Restored) { Set-KnxTestSkip "Assert-KnxRigPower had to switch a relay on after the restore - $($fx.Guard.Detail)" }
    if ($fx.RestoreError) { throw "error while watching the clear: $($fx.RestoreError)" }

    $resAt = $fx.Log.RestoreAt
    $budget = $T.ClearMs / 1000.0
    $vi = Get-FaultIndicationResult -Ref $resAt -RefText 'the restore write' -BudgetS $budget -Bit0 0 -What 'PID 69 bit 0 = 0 indicated'
    $vs = Get-FaultStateResult -Ref $resAt -RefText 'the restore write' -BudgetS $budget -Want 0x00 -What 'CONNECTIONSTATE 0x00'
    Add-KnxEvidence -Note "CONNECTIONSTATE after the restore: $(Get-FaultStateTrace $fx.Log $resAt)"
    foreach ($v in @($vi, $vs)) {
        if ($v.Result -eq 'pass') { Add-KnxEvidence -Note "timing: $($v.Timing)" } else { Add-KnxEvidence -Note $v.Text }
    }
    $raised = @($fx.Log.Indications | Where-Object { $_.At -ge $fx.Log.CutAt -and $_.At -lt $resAt -and ($_.Value -band 1) -eq 1 })
    if ($raised.Count -eq 0) { Add-KnxEvidence -Note 'PID 69 bit 0 was never indicated as set during the cut (see DS-KF-2)' }
    $rd = $null
    if ($null -ne $fx.Dm -and $fx.Dm.Ok -and -not $fx.Log.Disconnected) {
        $rd = Read-KnxDeviceStateValue -Connection $fx.Dm -Log $fx.Log
        Add-KnxEvidence -Note "M_PropRead PID 69 after the restore: $($rd.Detail)"
    }
    if ($null -ne $vi.Entry) { Add-KnxEvidence -Received $vi.Entry.Cemi }
    Assert-KnxTrue (-not $fx.Log.Disconnected) 'the device closed the device management connection during the fault'
    Assert-KnxTrue ($vi.Result -ne 'fail') $vi.Text
    Assert-KnxTrue ($vs.Result -ne 'fail') $vs.Text
    Assert-KnxTrue ($null -ne $rd -and $rd.Value -ge 0) "PID 69 not read after the restore: $(if ($null -ne $rd) { $rd.Detail } else { 'no connection' })"
    Assert-KnxTrue (($rd.Value -band 1) -eq 0) ('PID 69 reads 0x{0:X2} after the restore, bit 0 still set' -f $rd.Value)
    if ($vi.Result -eq 'open') { Set-KnxTestSkip $vi.Text }
    if ($vs.Result -eq 'open') { Set-KnxTestSkip $vs.Text }
}

if ($null -ne $fx.Dm -and $fx.Dm.Ok) { [void](Close-KnxConnection -Connection $fx.Dm) }

Write-Host ''
Write-KnxRunSummary
$rep = Export-KnxTestReport -Directory $ReportDir
Write-Host "  Report: $($rep.Json)" -ForegroundColor DarkGray
$kfSum = $rep.Summary
$kfJudged = ($kfSum.Total -gt 0 -and $kfSum.Pass -eq $kfSum.Total)
$script:failures += ($kfSum.Fail + $kfSum.NoProof)
$kf2 = $null
foreach ($c in (Get-Content -Path $rep.Json -Raw | ConvertFrom-Json).results) { if ($c.Id -eq 'DS-KF-2') { $kf2 = $c } }
if (-not $kfJudged) { $script:notJudged = $true }
if ($null -eq $kf2 -or $kf2.Result -notin @('PASS', 'FAIL')) {
    # The evented part of the clause needs a real fault; DS-KF-2 is the case that judges it.
    Write-Host ''
    Write-Host '  NOT JUDGED: the evented M_PropInfo.ind on a state change.' -ForegroundColor Yellow
    Write-Host '  03_08_03 2.5.20 p.14 requires it when the value changes. The value only changes on a' -ForegroundColor Yellow
    Write-Host '  real fault (bit 0 KNX network unreachable, bit 1 IP network unreachable), and the' -ForegroundColor Yellow
    Write-Host '  property is read-only, so no client can provoke it.' -ForegroundColor Yellow
    Write-Host '  DS-KF-2 cuts the TP through the rig relays while the DM connection is held open:' -ForegroundColor Cyan
    if ($null -ne $kf2) { Write-Host "  DS-KF-2 $($kf2.Result): $($kf2.Reason)" -ForegroundColor Cyan }
}

Write-Host ''
if ($fx.RigFault) {
    # Exit 2: the rig is left in a state that needs a hand; the runner reports it as stage FAIL.
    Write-Host "  RESULT: RIG FAULT - $($fx.RigFault)" -ForegroundColor Red
    Write-Host ''
    exit 2
}
if ($script:failures -gt 0) {
    Write-Host "  RESULT: FAIL ($script:failures)" -ForegroundColor Red
    Write-Host ''
    exit 1
}
if ($script:notJudged) {
    # Exit 3 is the runner's "the rig is not ready for this" - the checks that could run passed, and
    # the KNX-fault cases did not all pass. Reporting PASS here would claim the evented behaviour
    # had been confirmed.
    Write-Host '  RESULT: the checks that can run PASS - the KNX-fault cases did not all run' -ForegroundColor Yellow
    Write-Host ''
    exit 3
}
Write-Host '  RESULT: PASS' -ForegroundColor Green
Write-Host ''
exit 0
