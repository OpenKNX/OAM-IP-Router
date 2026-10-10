#!/usr/bin/env pwsh
# Open ■
# ┬────┴  Test-WdWindow
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/repro/Test-WdWindow.ps1
# wiki.openknx.de - forum.openknx.de

<#
.SYNOPSIS
    Decides WHY the IP-Interface goes away under an unpaced tunnel flood: was the CPU actually stuck
    (hard fault / hang -> the 16 s RP2040 hardware watchdog is the only way back), or did the device
    merely drop our probes while it was overloaded?

    The trick is to STOP jetting and then probe finely:
      * recovery within a few hundred ms of jet-stop  -> the device never died; the "reboot" that
        jet_diag.ps1 reports after one missed 800 ms DESCRIPTION probe is a false positive.
      * a contiguous silence of ~16 s (OPENKNX_WATCHDOG_MAX_PERIOD) that ends only long after the
        jet stopped -> the CPU was stuck and the hardware watchdog reset it.

    After recovery the previously opened tunnel channel is re-queried with a CONNECTIONSTATE_REQUEST.
    A reply of E_CONNECTION_ID (0x21) proves the device lost all tunnel state = it really rebooted.
    This is a KNX-only reboot proof; no serial console is involved, so the timing is not perturbed.

.PARAMETER Ip        Interface under test.                                    e.g. 11.11.0.126
.PARAMETER JetSecs   Seconds of unpaced incrementing-seq jetting.             Default 3
.PARAMETER WatchSecs Seconds to keep probing after the jet stopped.           Default 40
.PARAMETER ProbeMs   Probe interval in milliseconds.                          Default 100
.PARAMETER Rounds    Number of jet/observe rounds.                            Default 1
.PARAMETER Help      Show this help.

.EXAMPLE
    ./Test-WdWindow.ps1 -Ip 11.11.0.126
        One round: 3 s jet, then watch for up to 40 s and classify the outcome.

.EXAMPLE
    ./Test-WdWindow.ps1 -Ip 11.11.0.126 -JetSecs 6 -Rounds 3
        Three rounds with a longer jet, to catch a timing-sensitive fault.

.NOTES
    AUTHOR : Erkan Çolak
#>
[CmdletBinding()]
param(
    [string]$Ip = "11.11.0.126",
    [int]$JetSecs = 3,
    [int]$WatchSecs = 40,
    [int]$ProbeMs = 100,
    [int]$Rounds = 1,
    [switch]$Help
)

if ($Help) { Get-Help $MyInvocation.MyCommand.Path -Detailed; exit 0 }

# ---- KNXnet/IP helpers -------------------------------------------------------------------------
function Kf([int]$svc, [byte[]]$body) {
    $l = 6 + $body.Length
    return [byte[]](@(0x06, 0x10, (($svc -shr 8) -band 0xFF), ($svc -band 0xFF), (($l -shr 8) -band 0xFF), ($l -band 0xFF)) + $body)
}
function Hp([byte[]]$ip, [int]$p) { return [byte[]](@(0x08, 0x01) + $ip + @((($p -shr 8) -band 0xFF), ($p -band 0xFF))) }
function LocalIp([string]$d) {
    $u = New-Object System.Net.Sockets.UdpClient
    try { $u.Connect($d, 3671); return $u.Client.LocalEndPoint.Address.GetAddressBytes() } finally { $u.Close() }
}
function NewSock() {
    $s = New-Object System.Net.Sockets.Socket("InterNetwork", "Dgram", "Udp")
    $s.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
    return $s
}
$AnyEp = { [System.Net.EndPoint]([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)) }

$me = LocalIp $Ip
$ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($Ip), 3671)

# Dedicated probe socket: never used for jetting, so its RX queue stays clean.
$probe = NewSock
$probe.Blocking = $false
$probePort = ([System.Net.IPEndPoint]$probe.LocalEndPoint).Port
$probeHpai = Hp $me $probePort
$probeBuf = New-Object byte[] 256

function SendProbe() { try { $null = $probe.SendTo((Kf 0x0203 $probeHpai), $ep) } catch {} }
# Drain the probe socket; returns $true if a DESCRIPTION_RESPONSE (0x0204) arrived.
function DrainProbe() {
    $got = $false
    while ($probe.Available -gt 0) {
        $f = & $AnyEp
        try {
            $n = $probe.ReceiveFrom($probeBuf, [ref]$f)
            if ($n -ge 8 -and $probeBuf[2] -eq 0x02 -and $probeBuf[3] -eq 0x04) { $got = $true }
        }
        catch { break }
    }
    return $got
}
# Blocking alive check with retries, for the calm phases (no flood in flight).
function AliveNow([int]$tries = 3) {
    for ($i = 0; $i -lt $tries; $i++) {
        $null = DrainProbe
        SendProbe
        $deadline = [datetime]::Now.AddMilliseconds(600)
        while ([datetime]::Now -lt $deadline) {
            if (DrainProbe) { return $true }
            Start-Sleep -Milliseconds 10
        }
    }
    return $false
}

. (Join-Path $PSScriptRoot '../lib/KnxLogo.ps1')
Write-KnxLogo -Title 'Test-WdWindow'
Write-Host "  target=$Ip  jet=${JetSecs}s  watch=${WatchSecs}s  probe=${ProbeMs}ms  rounds=$Rounds" -ForegroundColor Cyan
Write-Host ""

for ($round = 1; $round -le $Rounds; $round++) {

    Write-Host ("--- round {0}/{1} ---" -f $round, $Rounds) -ForegroundColor Yellow

    if (-not (AliveNow 5)) { Write-Host "  device not answering DESCRIPTION before the test - aborting" -ForegroundColor Red; break }
    Write-Host "  baseline: alive"

    # ---- open one data tunnel ------------------------------------------------------------------
    $jet = NewSock
    $jetPort = ([System.Net.IPEndPoint]$jet.LocalEndPoint).Port
    $jetHpai = Hp $me $jetPort
    $null = $jet.SendTo((Kf 0x0205 ([byte[]]($jetHpai + $jetHpai + @(0x04, 0x04, 0x02, 0x00)))), $ep)
    $jet.ReceiveTimeout = 2000
    $rb = New-Object byte[] 256
    $f = & $AnyEp
    try { $n = $jet.ReceiveFrom($rb, [ref]$f) } catch { Write-Host "  CONNECT timed out - aborting round" -ForegroundColor Red; $jet.Close(); continue }
    if ($rb[7] -ne 0) { Write-Host ("  CONNECT refused, status=0x{0:X2}" -f $rb[7]) -ForegroundColor Red; $jet.Close(); continue }
    $ch = $rb[6]
    Write-Host ("  tunnel open, channel=0x{0:X2}" -f $ch)

    # ---- phase 1: unpaced incrementing-seq jet, never ACK anything ------------------------------
    $jet.Blocking = $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $seq = 0; $sent = 0; $disc = 0
    $lastProbeAliveMs = -1
    $nextProbe = 0

    while ($sw.ElapsedMilliseconds -lt ($JetSecs * 1000)) {
        for ($k = 0; $k -lt 100; $k++) {
            $ga = (((($sent % 8) + 1) -shl 8) -bor ($sent % 200))
            $cemi = [byte[]](@(0x11, 0x00, 0xBC, 0xE0, 0x00, 0x00, (($ga -shr 8) -band 0xFF), ($ga -band 0xFF), 0x01, 0x00, 0x81))
            try { $null = $jet.SendTo((Kf 0x0420 ([byte[]](@(0x04, [byte]$ch, [byte]($seq -band 0xFF), 0x00) + $cemi))), $ep) } catch {}
            $seq = ($seq + 1) -band 0xFF
            $sent++
        }
        # count server-initiated DISCONNECT_REQUESTs, but never ACK anything
        while ($jet.Available -gt 0) {
            $f = & $AnyEp
            try { $n = $jet.ReceiveFrom($rb, [ref]$f); if ($n -ge 4 -and $rb[2] -eq 0x02 -and $rb[3] -eq 0x09) { $disc++ } } catch { break }
        }
        # lightweight non-blocking liveness sampling DURING the jet
        if ($sw.ElapsedMilliseconds -ge $nextProbe) {
            if (DrainProbe) { $lastProbeAliveMs = $sw.ElapsedMilliseconds }
            SendProbe
            $nextProbe = $sw.ElapsedMilliseconds + $ProbeMs
        }
    }
    $jetStopMs = $sw.ElapsedMilliseconds
    $jet.Close()   # stop all load; from here the device has nothing left to do
    Write-Host ("  jet done: sent={0:N0} in {1} ms  (server DISCONNECTs seen={2}, last alive-probe during jet at {3} ms)" -f $sent, $jetStopMs, $disc, $lastProbeAliveMs)

    # ---- phase 2: fine-grained recovery watch --------------------------------------------------
    $null = DrainProbe
    $recoveredMs = -1
    $nextProbe = $sw.ElapsedMilliseconds
    while ($sw.ElapsedMilliseconds -lt ($jetStopMs + $WatchSecs * 1000)) {
        if (DrainProbe) { $recoveredMs = $sw.ElapsedMilliseconds; break }
        if ($sw.ElapsedMilliseconds -ge $nextProbe) {
            SendProbe
            $nextProbe = $sw.ElapsedMilliseconds + $ProbeMs
        }
        Start-Sleep -Milliseconds 5
    }

    if ($recoveredMs -lt 0) {
        Write-Host ("  NO recovery within {0}s after jet stop" -f $WatchSecs) -ForegroundColor Red
        continue
    }

    $gap = $recoveredMs - $jetStopMs
    Write-Host ("  first answer {0} ms after jet stop" -f $gap)

    # ---- phase 3: did the device lose its tunnel state? ----------------------------------------
    $cs = NewSock
    $csPort = ([System.Net.IPEndPoint]$cs.LocalEndPoint).Port
    $csHpai = Hp $me $csPort
    $null = $cs.SendTo((Kf 0x0207 ([byte[]](@([byte]$ch, 0x00) + $csHpai))), $ep)
    $cs.ReceiveTimeout = 1500
    $csStatus = -1
    $f = & $AnyEp
    try { $n = $cs.ReceiveFrom($rb, [ref]$f); if ($n -ge 8) { $csStatus = $rb[7] } } catch {}
    $cs.Close()

    $stateLost = ($csStatus -eq 0x21)   # E_CONNECTION_ID: channel unknown -> tunnel table was wiped
    Write-Host ("  CONNECTIONSTATE on old channel 0x{0:X2}: status=0x{1:X2} ({2})" -f $ch, $csStatus, $(if ($stateLost) { "channel GONE" } else { "still known" }))

    # ---- result -------------------------------------------------------------------------------
    Write-Host ""
    if ($gap -lt 1000 -and -not $stateLost) {
        Write-Host "  RESULT: no reboot. The device stayed alive and only dropped probes while overloaded." -ForegroundColor Green
    }
    elseif ($gap -ge 12000 -and $gap -le 22000) {
        Write-Host ("  RESULT: HARDWARE WATCHDOG. Silence of {0:N1}s ~= OPENKNX_WATCHDOG_MAX_PERIOD (16s)." -f ($gap / 1000)) -ForegroundColor Red
        Write-Host "           The CPU was stuck (hard fault / hang) - loop() starvation would have logged first." -ForegroundColor Red
    }
    else {
        Write-Host ("  RESULT: unclassified - {0:N1}s silence, tunnel state lost={1}. Needs a look." -f ($gap / 1000), $stateLost) -ForegroundColor Yellow
    }
    Write-Host ""

    if ($round -lt $Rounds) { Start-Sleep -Seconds 3 }
}

$probe.Close()
Write-Host "=== done ===" -ForegroundColor Cyan
