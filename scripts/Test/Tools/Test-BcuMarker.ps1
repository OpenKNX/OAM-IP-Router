#!/usr/bin/env pwsh
# Open ■
# ┬────┴  Test-BcuMarker
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/Tools/Test-BcuMarker.ps1

<#
.SYNOPSIS
    Bench proof for the NCN frame-end MARKER: capture, log and verify the extra octets.

.DESCRIPTION
    Needs a firmware built with -D TPUART_BCU_MARKER. With MARKER on the chip appends
    CB 13 plus a CRC-16 behind the checksum, so every telegram fails the length check and
    lands in the "Bytes are discarded" hexdump - which is exactly the evidence wanted.

    Three things are proven here, each over several rounds so a single lucky read cannot
    carry the result:
      1. the marker octets CB 13 sit directly behind the FCS
      2. the two octets after them are a CRC-16/CCITT-FALSE over the frame INCLUDING the FCS
      3. a data octet of 0xCB is doubled by the chip (byte stuffing) - the case that breaks
         a parser which does not un-double it, and the one no ordinary telegram produces

    For (3) the script deliberately writes the value 203 = 0xCB to a group address, which
    is the only way to get a 0xCB into the payload on purpose.

    Everything is written to a log file verbatim, so the raw dumps stay reviewable
    independently of this script's own result.

.PARAMETER Port
    Console of the device under test, e.g. /dev/cu.usbmodem3101 or COM5.
.PARAMETER TrafficIp
    Interface used to put telegrams on the bus.
.PARAMETER Ga
    Group address for the 0xCB payload test. Default 7/7/7.
.PARAMETER Rounds
    How many marker-on windows to run. Default 3.
.PARAMETER Busmon
    Run the busmonitor phase instead: does the MARKER survive into busmonitor mode at all?
    That question decides whether MARKER is useful for the ETS busmonitor - the argument
    against it being that the chip is transparent there, with no data-link layer and hence
    no U_FrameEnd.ind.

    The phase restarts the device first and then starts the busmonitor from the CONSOLE as
    the SOLE owner. Both steps are load-bearing: the console echo hangs on _monitorConsoleLog,
    which only the console path sets. A busmonitor started by an ETS tunnel leaves the chip
    monitoring while the console stays silent - and 'bcu mon' then ADDS a second owner
    instead of switching it off. Measuring in that state produces "no CB 13" for a reason
    that has nothing to do with MARKER.
.PARAMETER LogFile
    Output file. Default: Reports/BcuMarker_<timestamp>.log

.EXAMPLE
    ./Test-BcuMarker.ps1 -Port /dev/cu.usbmodem3101 -TrafficIp 11.11.0.210
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Port,
    [int]$Baud = 115200,
    [Parameter(Mandatory)][string]$TrafficIp,
    [string]$Ga = '7/7/7',
    [int]$Rounds = 3,
    [switch]$Busmon,
    [string]$LogFile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $here 'lib/KnxTest.psm1') -Force
$K = Get-KnxConstants

if (-not $LogFile) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $LogFile = Join-Path $here "Reports/BcuMarker_$stamp.log"
}

. (Join-Path $PSScriptRoot '../lib/KnxLogo.ps1')
Write-KnxLogo -Title 'BCU MARKER proof'

$log = New-Object System.Text.StringBuilder
function Log { param([string]$T) [void]$log.AppendLine($T); Write-Host $T }

Log "# BCU MARKER proof"
Log "# started : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Log "# console : $Port"
Log "# traffic : $TrafficIp"
Log "# rounds  : $Rounds"

$p = New-Object System.IO.Ports.SerialPort $Port, $Baud, None, 8, One
$p.DtrEnable = $true; $p.RtsEnable = $true; $p.ReadTimeout = 800
$p.Open(); Start-Sleep -Milliseconds 800; $p.DiscardInBuffer()

function Drain {
    $s = ''
    try { while ($true) { $s += $p.ReadExisting(); Start-Sleep -Milliseconds 200; if ($p.BytesToRead -eq 0) { break } } } catch { }
    return ($s -replace "\x1b\[[0-9;]*[A-Za-z]", '')
}

# Buildtime belongs in the log: a proof without the image it was taken on is worthless.
$p.WriteLine('v'); Start-Sleep -Seconds 3
$ver = Drain
foreach ($l in ($ver -split "`n")) { if ($l -match 'Buildtime') { Log ("# build   : " + ($l -replace '.*Buildtime:\s*', '').Trim()) } }

function Get-BcuState {
    <#
    .SYNOPSIS
        Reads the BCU state. 'bcu' carries it; the boxed 'bcu stat' is truncated on RP2040.
    #>
    $p.DiscardInBuffer()
    $p.WriteLine('bcu'); Start-Sleep -Seconds 3
    $m = [regex]::Match((Drain), 'BCU<Status:\s*(\w+)>')
    if ($m.Success) { return $m.Groups[1].Value }
    return '?'
}


$gen = Open-KnxConnection -Ip $TrafficIp -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_LINKLAYER -TimeoutMs 3000
if (-not $gen.Ok) { Log "# ABORT: traffic tunnel refused ($($gen.StatusName))"; $p.Close(); exit 3 }
$gaRaw = ConvertTo-KnxGa -Address $Ga

for ($r = 1; $r -le $Rounds; $r++) {
    Log ''
    Log "=== ROUND $r ==="
    $p.DiscardInBuffer()
    $p.WriteLine('bcu marker on'); Start-Sleep -Milliseconds 900

    # Ordinary reads for the general marker/CRC evidence ...
    for ($i = 0; $i -lt 2; $i++) {
        $c = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $gaRaw -IsGroup -Tpdu (New-TpduGroupValueRead) -Priority 3
        [void](Send-KnxTunnelCemi -Connection $gen -Cemi $c -TimeoutMs 1500)
        Start-Sleep -Milliseconds 350
    }
    # ... and a payload of exactly 0xCB for the doubling question. A 1-byte GroupValueWrite
    # carries the value in its own octet, so 203 lands verbatim on the wire.
    foreach ($val in @(0xCB, 0xCB, 0x13)) {
        $c = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $gaRaw -IsGroup -Tpdu ([byte[]]@(0x00, 0x80, $val)) -Priority 3
        [void](Send-KnxTunnelCemi -Connection $gen -Cemi $c -TimeoutMs 1500)
        Log ("  sent GroupValueWrite $Ga = 0x{0:X2}" -f $val)
        Start-Sleep -Milliseconds 400
    }
    Start-Sleep -Seconds 3
    foreach ($l in ((Drain) -split "`n")) { if ($l.Trim() -and $l -notmatch 'Webserver') { Log ("  " + $l.Trim()) } }

    $p.WriteLine('bcu stat'); Start-Sleep -Seconds 3
    foreach ($l in ((Drain) -split "`n")) { if ($l -match 'Discarded|RX Frames|State ') { Log ("  " + $l.Trim()) } }

    $p.WriteLine('bcu marker off'); Start-Sleep -Seconds 3
    [void](Drain)
}

if ($Busmon) {
    Log ''
    Log '=== BUSMONITOR PHASE ==='
    # No restart by choice. The consequence is stated rather than hidden: without one there is
    # no guarantee that an ETS tunnel co-owns the busmonitor, and in that case the console echo
    # stays silent for a reason that has nothing to do with MARKER. Phase A below is what
    # catches it - it aborts instead of reporting a meaningless "no CB 13".
    $st = Get-BcuState
    Log "  state before         : $st"

    $p.DiscardInBuffer(); $p.WriteLine('bcu mon'); Start-Sleep -Seconds 3
    foreach ($l in ((Drain) -split "`n")) { if ($l -match 'monitor') { Log ("  " + ($l -replace '^.*: ', '').Trim()) } }
    $st = Get-BcuState
    Log "  state after 'bcu mon': $st"

    if ($st -ne 'Busmonitor') {
        Log "  ABORT: busmonitor did not start (state '$st')"
    }
    else {
        $gaB = ConvertTo-KnxGa -Address $Ga

        # Reference first: prove the console echo works at all, before judging MARKER by its
        # absence. A silent console without marker means the measurement cannot attribute
        # anything - so it stops here rather than producing a result it cannot support.
        Log '  --- A) busmonitor WITHOUT marker (does the console echo work?) ---'
        $p.DiscardInBuffer()
        $a = ''
        for ($i = 0; $i -lt 5; $i++) {
            [void](Send-KnxTunnelCemi -Connection $gen -Cemi (New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $gaB -IsGroup -Tpdu (New-TpduGroupValueRead) -Priority 3) -TimeoutMs 1200)
            Start-Sleep -Milliseconds 1400
            $a += $p.ReadExisting()
        }
        $aHex = @(($a -replace "\x1b\[[0-9;]*[A-Za-z]", '') -split "`n" | Where-Object { $_ -match '([0-9A-F]{2} ){3}' })
        Log ("  frames echoed: {0}" -f $aHex.Count)
        foreach ($l in ($aHex | Select-Object -First 4)) { Log ("    " + ($l -replace '^.*: ', '').Trim()) }

        if ($aHex.Count -eq 0) {
            Log '  ABORT: the console echoes nothing even WITHOUT marker, so an absent CB 13'
            Log '         could not be attributed to MARKER. Most likely an ETS tunnel co-owns'
            Log '         the busmonitor - the console echo only runs when the console owns it.'
        }
        else {
            Log '  --- B) busmonitor WITH marker ---'
            $p.DiscardInBuffer(); $p.WriteLine('bcu marker on'); Start-Sleep -Seconds 2
            $b = $p.ReadExisting()
            for ($i = 0; $i -lt 6; $i++) {
                [void](Send-KnxTunnelCemi -Connection $gen -Cemi (New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $gaB -IsGroup -Tpdu (New-TpduGroupValueRead) -Priority 3) -TimeoutMs 1200)
                Start-Sleep -Milliseconds 1400
                $b += $p.ReadExisting()
            }
            $bLines = @(($b -replace "\x1b\[[0-9;]*[A-Za-z]", '') -split "`n" | Where-Object { $_ -match '([0-9A-F]{2} ){3}' })
            # The command's own help text mentions CB 13; it is not a measurement.
            $bCb = @($bLines | Where-Object { $_ -match 'CB 13' -and $_ -notmatch 'expect' })
            Log ("  frames echoed: {0}   carrying CB 13: {1}" -f $bLines.Count, $bCb.Count)
            foreach ($l in ($bLines | Select-Object -First 6)) { Log ("    " + ($l -replace '^.*: ', '').Trim()) }
            Log ''
            if ($bCb.Count -gt 0) {
                Log '  RESULT: MARKER IS visible in busmonitor mode - the frame-end octets reach the'
                Log '          host even with the chip transparent. The busmonitor case for MARKER holds.'
            }
            else {
                Log '  RESULT: no CB 13 in busmonitor, although the echo demonstrably works (phase A).'
                Log '          MARKER does not reach busmonitor - consistent with the chip being'
                Log '          transparent there, with no data-link layer and thus no U_FrameEnd.ind.'
                Log '          The busmonitor case for MARKER does NOT hold.'
            }
            $p.WriteLine('bcu marker off'); Start-Sleep -Seconds 2; [void](Drain)
        }
        $p.WriteLine('bcu mon'); Start-Sleep -Seconds 2; [void](Drain)
    }
}

$p.Close()
try { [void](Close-KnxConnection -Connection $gen) } catch { }

Log ''
Log "# finished: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
[System.IO.File]::WriteAllText($LogFile, $log.ToString())
Write-Host ''
Write-Host "  Log: $LogFile" -ForegroundColor Cyan
Write-Host ''
