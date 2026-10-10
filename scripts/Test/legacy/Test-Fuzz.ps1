#!/usr/bin/env pwsh
# Open ■
# ┬────┴  Test-Fuzz
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/legacy/Test-Fuzz.ps1
# wiki.openknx.de - forum.openknx.de

<#
.SYNOPSIS
    Fires malformed / edge-case KNXnet/IP and cEMI frames at an OpenKNX IP-Interface to prove it never
    crashes, reboots, leaks, or drops the BCU. Covers the surfaces hardened per KNX 03_08_02 (Core),
    03_08_03 (DevMgmt), 03_08_04 (Tunnelling) and 03_06_03 (cEMI): short/oversized headers, bad header
    length, wrong protocol version, unknown services, runt/oversized connection frames, unknown channel
    ids, bad sequence counters, malformed cEMI (zero length, huge addInfo, apduLength=255, octetCount=0xFF),
    broadcast/GA floods. Optional: generate REAL bus traffic through a second interface (-TrafficIp).

.PARAMETER Ip         IP-Interface under test (e.g. 11.11.0.126).
.PARAMETER Port       KNXnet/IP UDP port. Default 3671.
.PARAMETER Rounds     Repetitions per malformed-case category. Default 30.
.PARAMETER Flood      Group-write telegrams fired on a real tunnel. Default 500.
.PARAMETER TrafficIp  Optional 2nd interface (e.g. Siemens 5.0.50 at 11.11.0.5) to inject real bus traffic.

.EXAMPLE
    ./Test-Fuzz.ps1 -Ip 11.11.0.126 -TrafficIp 11.11.0.5

.NOTES
    AUTHOR : Erkan Çolak
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Ip,
    [int]$Port = 3671,
    [int]$Rounds = 30,
    [int]$Flood = 500,
    [int]$LoadSeconds = 0,
    [string]$TrafficIp = "",
    [switch]$Help
)
$ErrorActionPreference = 'Continue'

if ($Help) {
    Write-Host @"

  Test-Fuzz — KNXnet/IP + cEMI robustness bombardment for the OpenKNX IP-Interface.
  Proves the interface never crashes / reboots / leaks / drops the BCU under malformed input + load.

  USAGE
    ./Test-Fuzz.ps1 -Ip <interface-ip> [-Rounds N] [-Flood N] [-LoadSeconds S] [-TrafficIp <ip>]

  PARAMETERS
    -Ip          IP-Interface under test (required)         e.g. 11.11.0.126
    -Rounds      repetitions per malformed-case category    (default 30)
    -Flood       group-writes fired on a real tunnel        (default 500)
    -LoadSeconds sustained max-rate bus saturation, seconds (0 = off; needs -TrafficIp)
    -TrafficIp   2nd interface to inject REAL bus traffic   e.g. Siemens 11.11.0.5

  EXAMPLES
    ./Test-Fuzz.ps1 -Ip 11.11.0.126
        malformed KNXnet/IP + cEMI edge cases + connect/disconnect storm.
    ./Test-Fuzz.ps1 -Ip 11.11.0.126 -TrafficIp 11.11.0.5 -Flood 2000
        + real bus traffic through the Siemens interface.
    ./Test-Fuzz.ps1 -Ip 11.11.0.126 -TrafficIp 11.11.0.5 -LoadSeconds 20
        + ~20 s of near-100% TP bus saturation (watch 'bcu stat' Load on the device console).
"@ -ForegroundColor Cyan
    return
}

function New-KnxFrame([int]$svc, [byte[]]$body) {
    $len = 6 + $body.Length
    return [byte[]](@(0x06, 0x10, (($svc -shr 8) -band 0xFF), ($svc -band 0xFF), (($len -shr 8) -band 0xFF), ($len -band 0xFF)) + $body)
}
function New-Hpai([byte[]]$ipB, [int]$port) { return [byte[]](@(0x08, 0x01) + $ipB + @((($port -shr 8) -band 0xFF), ($port -band 0xFF))) }
function New-UdpSocket { return New-Object System.Net.Sockets.Socket([System.Net.Sockets.AddressFamily]::InterNetwork, [System.Net.Sockets.SocketType]::Dgram, [System.Net.Sockets.ProtocolType]::Udp) }
function Get-LocalIpBytes([string]$dst) { $u = New-Object System.Net.Sockets.UdpClient; try { $u.Connect($dst, 3671); return $u.Client.LocalEndPoint.Address.GetAddressBytes() } finally { $u.Close() } }

$MeB = Get-LocalIpBytes $Ip
$Dst = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($Ip), $Port)
$TxSock = New-UdpSocket
$TxSock.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
$MyPort = ([System.Net.IPEndPoint]$TxSock.Client.LocalEndPoint).Port
$Hpai = New-Hpai $MeB $MyPort
function Send-Raw([byte[]]$b) { try { $null = $TxSock.SendTo($b, $Dst) } catch {} }

$sent = 0
function Fire([string]$name, [byte[]]$b) {
    for ($i = 0; $i -lt $Rounds; $i++) { Send-Raw $b; $script:sent++ }
    Write-Host ("  fired x{0,-3} : {1}" -f $Rounds, $name) -ForegroundColor DarkGray
}

$cemiOk = [byte[]]@(0x11, 0x00, 0xBC, 0xE0, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x81)  # small valid group write to 0/0/1

. (Join-Path $PSScriptRoot '../lib/KnxLogo.ps1')
Write-KnxLogo -Title 'Test-Fuzz'
Write-Host ("  {0}:{1}  (client {2})  rounds={3} flood={4}" -f $Ip, $Port, ($MeB -join '.'), $Rounds, $Flood) -ForegroundColor Green
Write-Host ""
Write-Host "  Phase 1: malformed KNXnet/IP (connectionless)" -ForegroundColor Cyan

Fire "truncated frame (<6-byte header)"            ([byte[]]@(0x06, 0x10, 0x02))
Fire "bad header-length byte 0xFF (underflow bait)" ([byte[]](@(0xFF, 0x10, 0x02, 0x05) + @(0x00, 0x1A) + $Hpai + $Hpai + @(0x04, 0x04, 0x02, 0x00)))
Fire "wrong protocol version 0x99"                 ([byte[]](@(0x06, 0x99, 0x02, 0x05, 0x00, 0x1A) + $Hpai + $Hpai + @(0x04, 0x04, 0x02, 0x00)))
Fire "unknown service 0x0999"                      (New-KnxFrame 0x0999 @(0x00, 0x00, 0x00, 0x00))
Fire "oversized total-length field (0xFFFF)"       ([byte[]](@(0x06, 0x10, 0x02, 0x05, 0xFF, 0xFF) + $Hpai + $Hpai + @(0x04, 0x04, 0x02, 0x00)))
Fire "CONNECT with 1-byte (truncated) CRI"         (New-KnxFrame 0x0205 ([byte[]]($Hpai + $Hpai + @(0x04))))
Fire "CONNECT bad connection type 0xFF"            (New-KnxFrame 0x0205 ([byte[]]($Hpai + $Hpai + @(0x04, 0xFF, 0x02, 0x00))))
Fire "CONNECT empty body"                          (New-KnxFrame 0x0205 @())
Fire "CONNECTIONSTATE unknown channel 0x99"        (New-KnxFrame 0x0207 ([byte[]](@(0x99, 0x00) + $Hpai)))
Fire "CONNECTIONSTATE runt (2 bytes)"              (New-KnxFrame 0x0207 @(0x99, 0x00))
Fire "DISCONNECT unknown channel 0x99"             (New-KnxFrame 0x0209 ([byte[]](@(0x99, 0x00) + $Hpai)))
Fire "DISCONNECT runt (1 byte)"                    (New-KnxFrame 0x0209 @(0x99))
Fire "TUNNELLING unknown channel 0x99"             (New-KnxFrame 0x0420 ([byte[]](@(0x04, 0x99, 0x00, 0x00) + $cemiOk)))
Fire "TUNNELLING runt (no cEMI)"                   (New-KnxFrame 0x0420 @(0x04, 0x99, 0x00, 0x00))
Fire "TUNNELLING conn-header too short"            (New-KnxFrame 0x0420 @(0x04, 0x99))
Fire "DEVCONF unknown channel 0x99"                (New-KnxFrame 0x0310 ([byte[]](@(0x04, 0x99, 0x00, 0x00) + $cemiOk)))
Fire "DEVCONF runt"                                (New-KnxFrame 0x0310 @(0x04))
Fire "SEARCH_REQUEST malformed HPAI"               (New-KnxFrame 0x0201 @(0x08, 0x01, 0x00))
Fire "DESCRIPTION_REQUEST malformed HPAI"          (New-KnxFrame 0x0203 @(0x08))
Fire "random 40-byte garbage"                      ([byte[]](1..40 | ForEach-Object { ($_ * 7 + 13) -band 0xFF }))
# pure random garbage: varying length + content, each frame different (fuzz the whole parser surface)
$rng = New-Object Random
for ($i = 0; $i -lt ($Rounds * 5); $i++) { $rl = $rng.Next(2, 300); $g = New-Object byte[] $rl; $rng.NextBytes($g); Send-Raw $g; $script:sent++ }
Write-Host ("  fired x{0,-3} : pure random garbage (2..300 bytes, varying)" -f ($Rounds * 5)) -ForegroundColor DarkGray
# also random garbage stamped with a valid KNXnet/IP header (passes the length gate, junk body)
for ($i = 0; $i -lt ($Rounds * 5); $i++) { $rl = $rng.Next(0, 260); $g = New-Object byte[] $rl; $rng.NextBytes($g); Send-Raw (New-KnxFrame ($rng.Next(0x200, 0x540)) $g); $script:sent++ }
Write-Host ("  fired x{0,-3} : random garbage under a valid KNXnet/IP header" -f ($Rounds * 5)) -ForegroundColor DarkGray

# ── Phase 2: open a REAL tunnel, then malformed cEMI + GA abuse on it ──
Write-Host ""
Write-Host "  Phase 2: open a real tunnel -> malformed cEMI + GA flood" -ForegroundColor Cyan
$rb = New-Object byte[] 1024
$from = [System.Net.EndPoint]([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
$sock = $null; $ch = -1; $h2 = $null
for ($try = 0; $try -lt 6 -and $ch -lt 0; $try++) {          # retry: slots may be transiently full
    if ($sock) { $sock.Close() }
    $sock = New-UdpSocket
    $sock.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
    $mp = ([System.Net.IPEndPoint]$sock.LocalEndPoint).Port
    $h2 = New-Hpai $MeB $mp
    $null = $sock.SendTo((New-KnxFrame 0x0205 ([byte[]]($h2 + $h2 + @(0x04, 0x04, 0x02, 0x00)))), $Dst)
    $sock.ReceiveTimeout = 1500
    try { $rn = $sock.ReceiveFrom($rb, [ref]$from); if ($rn -ge 8 -and $rb[7] -eq 0) { $ch = $rb[6] } } catch {}
    if ($ch -lt 0) { Start-Sleep -Milliseconds 300 }
}
if ($ch -ge 0) {
    Write-Host ("  tunnel open: channel 0x{0:X2}" -f $ch) -ForegroundColor Green
    $seq = 0
    function Tun([byte[]]$cemi) {
        $null = $sock.SendTo((New-KnxFrame 0x0420 ([byte[]](@(0x04, [byte]$ch, [byte]($seq -band 0xFF), 0x00) + $cemi))), $Dst)
        $script:seq = ($seq + 1) -band 0xFF; $script:sent++
        # drain + ACK anything the interface sends back so its FIFO keeps flowing
        while ($sock.Available -gt 0) { $f2 = $from; $n2 = $sock.ReceiveFrom($rb, [ref]$f2); if ($n2 -ge 10 -and $rb[3] -eq 0x20) { $null = $sock.SendTo((New-KnxFrame 0x0421 ([byte[]]@(0x04, $rb[7], $rb[8], 0x00))), $Dst) } }
    }
    function FireTun([string]$name, [byte[]]$cemi) { for ($i = 0; $i -lt $Rounds; $i++) { Tun $cemi }; Write-Host ("  fired x{0,-3} : {1}" -f $Rounds, $name) -ForegroundColor DarkGray }

    FireTun "zero-length cEMI"                 ([byte[]]@())
    FireTun "1-byte cEMI"                      ([byte[]]@(0x11))
    FireTun "cEMI huge addInfo len 0xFF"       ([byte[]]@(0x11, 0xFF, 0xBC, 0xE0, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x81))
    FireTun "cEMI octetCount 0xFF (illegal)"   ([byte[]]@(0x11, 0x00, 0xBC, 0xE0, 0x00, 0x00, 0x00, 0x01, 0xFF, 0x00, 0x81))
    FireTun "cEMI len says 200, only 2 bytes"  ([byte[]]@(0x11, 0x00, 0xBC, 0xE0, 0x00, 0x00, 0x00, 0x01, 0xC8, 0x00, 0x81))
    FireTun "extended write, apduLength ~253"  ([byte[]](@(0x11, 0x00, 0xBC, 0xE0, 0x00, 0x00, 0x00, 0x01, 0xFE, 0x00, 0x80) + (1..252 | ForEach-Object { $_ -band 0xFF })))
    FireTun "oversized cEMI (300 bytes)"       ([byte[]](@(0x11, 0x00, 0xBC, 0xE0, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x81) + (1..289 | ForEach-Object { $_ -band 0xFF })))
    FireTun "broadcast write 0/0/0"            ([byte[]]@(0x11, 0x00, 0xBC, 0xE0, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x81))
    FireTun "bad ctrl1 (bit6 set)"             ([byte[]]@(0x11, 0x00, 0xFC, 0xE0, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x81))
    FireTun "wrong message code 0xFF"          ([byte[]]@(0xFF, 0x00, 0xBC, 0xE0, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x81))

    # GA flood: valid group writes across the whole GA space, fast
    Write-Host ("  GA flood: {0} group writes across 0/0/1..0/7/255 ..." -f $Flood) -ForegroundColor Cyan
    for ($i = 0; $i -lt $Flood; $i++) {
        $ga = (($i % 8) -shl 8) -bor ($i % 256)
        Tun ([byte[]]@(0x11, 0x00, 0xBC, 0xE0, 0x00, 0x00, (($ga -shr 8) -band 0xFF), ($ga -band 0xFF), 0x01, 0x00, (0x80 -bor ($i -band 0x3F))))
    }
    # duplicate + out-of-order sequence abuse
    Write-Host "  sequence abuse: replay + jump ..." -ForegroundColor Cyan
    for ($i = 0; $i -lt $Rounds; $i++) {
        $null = $sock.SendTo((New-KnxFrame 0x0420 ([byte[]](@(0x04, [byte]$ch, 0x00, 0x00) + $cemiOk))), $Dst)          # always seq 0 (replay)
        $null = $sock.SendTo((New-KnxFrame 0x0420 ([byte[]](@(0x04, [byte]$ch, 0x7F, 0x00) + $cemiOk))), $Dst)          # jump to 0x7F
        $script:sent += 2
    }
    try { $null = $sock.SendTo((New-KnxFrame 0x0209 ([byte[]](@([byte]$ch, 0x00) + $h2))), $Dst) } catch {}
} else {
    Write-Host "  (could not open a tunnel for phase 2 -- all slots busy? skipping cEMI/GA)" -ForegroundColor Yellow
}
$sock.Close()

# ── Phase 3: connect/disconnect storm ──
Write-Host ""
Write-Host "  Phase 3: connect/disconnect storm" -ForegroundColor Cyan
for ($i = 0; $i -lt $Rounds; $i++) {
    $s = New-UdpSocket; $s.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
    $p = ([System.Net.IPEndPoint]$s.Client.LocalEndPoint).Port; $hh = New-Hpai $MeB $p
    $null = $s.SendTo((New-KnxFrame 0x0205 ([byte[]]($hh + $hh + @(0x04, 0x04, 0x02, 0x00)))), $Dst)
    $s.ReceiveTimeout = 500
    try { $rn = $s.ReceiveFrom($rb, [ref]$from); if ($rn -ge 8 -and $rb[7] -eq 0) { $null = $s.SendTo((New-KnxFrame 0x0209 ([byte[]](@([byte]$rb[6], 0x00) + $hh))), $Dst) } } catch {}
    $s.Close(); $script:sent += 2
}
Write-Host ("  storm: {0} connect/disconnect cycles" -f $Rounds) -ForegroundColor DarkGray

# ── Phase 4 (optional): real bus traffic via a 2nd interface ──
if ($TrafficIp) {
    Write-Host ""
    Write-Host ("  Phase 4: real bus traffic via {0} (-> TP -> interface RX)" -f $TrafficIp) -ForegroundColor Cyan
    $td = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($TrafficIp), 3671)
    $ts = New-UdpSocket; $ts.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
    $tp = ([System.Net.IPEndPoint]$ts.Client.LocalEndPoint).Port; $th = New-Hpai (Get-LocalIpBytes $TrafficIp) $tp
    $null = $ts.SendTo((New-KnxFrame 0x0205 ([byte[]]($th + $th + @(0x04, 0x04, 0x02, 0x00)))), $td)
    $ts.ReceiveTimeout = 2000
    $tch = -1; try { $rn = $ts.ReceiveFrom($rb, [ref]$from); if ($rn -ge 8 -and $rb[7] -eq 0) { $tch = $rb[6] } } catch {}
    if ($tch -ge 0) {
        Write-Host ("  traffic tunnel open on {0}: channel 0x{1:X2} -> flooding bus" -f $TrafficIp, $tch) -ForegroundColor Green
        $tseq = 0; $i = 0
        $loadEnd = if ($LoadSeconds -gt 0) { ([datetime]::Now).AddSeconds($LoadSeconds) } else { $null }
        if ($loadEnd) { Write-Host ("  SATURATING the bus at max rate for {0} s (watch 'bcu stat' Load) ..." -f $LoadSeconds) -ForegroundColor Yellow }
        while ( ($loadEnd -and [datetime]::Now -lt $loadEnd) -or (-not $loadEnd -and $i -lt $Flood) ) {
            $ga = (($i % 8) -shl 8) -bor ($i % 256)
            $c = [byte[]]@(0x11, 0x00, 0xBC, 0xE0, 0x00, 0x00, (($ga -shr 8) -band 0xFF), ($ga -band 0xFF), 0x01, 0x00, (0x80 -bor ($i -band 0x3F)))
            $null = $ts.SendTo((New-KnxFrame 0x0420 ([byte[]](@(0x04, [byte]$tch, [byte]($tseq -band 0xFF), 0x00) + $c))), $td)
            $tseq = ($tseq + 1) -band 0xFF; $script:sent++; $i++
            while ($ts.Available -gt 0) { $f3 = $from; $n3 = $ts.ReceiveFrom($rb, [ref]$f3); if ($n3 -ge 10 -and $rb[3] -eq 0x20) { $null = $ts.SendTo((New-KnxFrame 0x0421 ([byte[]]@(0x04, $rb[7], $rb[8], 0x00))), $td) } }
        }
        Write-Host ("  flooded {0} telegrams onto the bus" -f $i) -ForegroundColor DarkGray
        try { $null = $ts.SendTo((New-KnxFrame 0x0209 ([byte[]](@([byte]$tch, 0x00) + $th))), $td) } catch {}
    } else { Write-Host "  (traffic interface did not accept a tunnel)" -ForegroundColor Yellow }
    $ts.Close()
}

$TxSock.Close()
Write-Host ""
Write-Host ("  DONE — fired {0} datagrams total." -f $sent) -ForegroundColor Green
