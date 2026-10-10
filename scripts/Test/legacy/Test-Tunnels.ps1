#!/usr/bin/env pwsh
# Open ■
# ┬────┴  Test-Tunnels
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/legacy/Test-Tunnels.ps1
# wiki.openknx.de - forum.openknx.de

<#
.SYNOPSIS
    Exercises the OpenKNX IP-Interface tunnelling front-end over raw KNXnet/IP UDP:
      -Ramp    : for k = 1..Count open k tunnels, brief send+receive, close; then all open/close;
                 then all open + stress. Tolerant -- if the interface only grants M < k slots it continues.
      -Hold    : open Count tunnels and keep them alive (heartbeat) until Ctrl-C.
      -Stress  : -Hold + send GroupValueWrite to -Ga on all tunnels.
      -Plus1   : open one past -Count and report the rejection (0x24 / 0x25).
      -BusMon  : open a HW busmonitor connection and print received L_Busmon.ind until Ctrl-C.
    Default (no switch): open Count tunnels, print the table, disconnect.

.DESCRIPTION
    Uses a raw System.Net.Sockets.Socket per connection (Bind 0.0.0.0:ephemeral, SendTo/ReceiveFrom) and
    puts THIS client's real IP:port into the HPAI, so the interface replies to us.

.PARAMETER Ip       IPv4 of the IP-Interface (e.g. 11.11.0.126).
.PARAMETER Port     KNXnet/IP UDP port. Default 3671.
.PARAMETER Count    Max data tunnels. Default 16.
.PARAMETER Ramp     Run the 1..Count ramp, then all open/close, then all + stress.
.PARAMETER Plus1    Open one past -Count and report the rejection code.
.PARAMETER Hold     Keep Count tunnels alive until Ctrl-C.
.PARAMETER Stress   -Hold + generate GroupValueWrite traffic to -Ga.
.PARAMETER BusMon   Open a HW busmonitor connection and print L_Busmon.ind.
.PARAMETER Ga       Group address for writes (3-level "m/mid/sub"). Default 0/0/1.
.PARAMETER Rate     Stress send rate, telegrams/second total. Default 20.
.PARAMETER Seconds  Stress/hold/busmon duration; 0 = ramp default 10 s / else until Ctrl-C.

.EXAMPLE
    ./Test-Tunnels.ps1 -Ip 11.11.0.126 -Ramp

.NOTES
    AUTHOR : Erkan Çolak
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Ip,
    [int]$Port = 3671,
    [int]$Count = 16,
    [switch]$Ramp,
    [switch]$Plus1,
    [switch]$Hold,
    [switch]$Stress,
    [switch]$BusMon,
    [string]$Ga = "0/0/1",
    [int]$Rate = 20,
    [int]$Size = 1,
    [int]$Seconds = 0
)

$ErrorActionPreference = 'Stop'

$SVC_CONNECT_REQ    = 0x0205
$SVC_CONNECT_RES    = 0x0206
$SVC_CONNSTATE_REQ  = 0x0207
$SVC_DISCONNECT_REQ = 0x0209
$SVC_TUNNEL_REQ     = 0x0420
$SVC_TUNNEL_ACK     = 0x0421

function New-KnxFrame([int]$svc, [byte[]]$body) {
    $len = 6 + $body.Length
    return [byte[]](@(0x06, 0x10, (($svc -shr 8) -band 0xFF), ($svc -band 0xFF), (($len -shr 8) -band 0xFF), ($len -band 0xFF)) + $body)
}
function New-Hpai([byte[]]$ipB, [int]$port) {
    return [byte[]](@(0x08, 0x01) + $ipB + @((($port -shr 8) -band 0xFF), ($port -band 0xFF)))
}
function New-UdpSocket {
    return New-Object System.Net.Sockets.Socket([System.Net.Sockets.AddressFamily]::InterNetwork, [System.Net.Sockets.SocketType]::Dgram, [System.Net.Sockets.ProtocolType]::Udp)
}
function Get-LocalIpBytes([string]$dst) {
    $u = New-Object System.Net.Sockets.UdpClient
    try { $u.Connect($dst, 3671); return $u.Client.LocalEndPoint.Address.GetAddressBytes() } finally { $u.Close() }
}
function Format-Pa([int]$hi, [int]$lo) {
    $pa = ($hi -shl 8) -bor $lo
    return ("{0}.{1}.{2}" -f (($pa -shr 12) -band 0x0F), (($pa -shr 8) -band 0x0F), ($pa -band 0xFF))
}
function ConvertTo-Ga([string]$s) {
    $p = $s -split '/'
    if ($p.Count -eq 3) { return (([int]$p[0] -shl 11) -bor ([int]$p[1] -shl 8) -bor [int]$p[2]) }
    if ($p.Count -eq 2) { return (([int]$p[0] -shl 11) -bor [int]$p[1]) }
    return [int]$s
}
function Get-StatusName([int]$st) {
    switch ($st) {
        0x00 { "OK" } 0x22 { "E_CONNECTION_TYPE" } 0x23 { "E_CONNECTION_OPTION" }
        0x24 { "E_NO_MORE_CONNECTIONS (0x24)" } 0x25 { "E_NO_MORE_UNIQUE_CONNECTIONS (0x25)" }
        0x29 { "E_TUNNELLING_LAYER (0x29)" } default { ("0x{0:X2}" -f $st) }
    }
}

$MeB = Get-LocalIpBytes $Ip
$Dst = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($Ip), $Port)

# Open one connection. $layer 0x02 = LinkLayer (data tunnel), 0x80 = BusMonitor.
# Returns @{Sock;Ch;Pa;Hpai;Seq;Status} on success, @{Status=<code>} on a clean rejection, $null on no response.
function Open-Conn([byte]$layer) {
    $sock = New-UdpSocket
    $sock.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
    $myport = ([System.Net.IPEndPoint]$sock.LocalEndPoint).Port
    $hpai = New-Hpai $MeB $myport
    $null = $sock.SendTo((New-KnxFrame $SVC_CONNECT_REQ ([byte[]]($hpai + $hpai + @(0x04, 0x04, $layer, 0x00)))), $Dst)
    $sock.ReceiveTimeout = 2000
    $buf = New-Object byte[] 1024
    $from = [System.Net.EndPoint]([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
    try { $rn = $sock.ReceiveFrom($buf, [ref]$from) } catch { $sock.Close(); return $null }
    if ($rn -lt 8 -or ((([int]$buf[2] -shl 8) -bor $buf[3]) -ne $SVC_CONNECT_RES)) { $sock.Close(); return $null }
    $status = $buf[7]
    if ($status -ne 0) { $sock.Close(); return @{ Status = $status } }
    $pa = if ($rn -ge 20) { Format-Pa $buf[18] $buf[19] } else { "?" }   # CRD at 16: len,type,PAhi,PAlo
    return @{ Sock = $sock; Ch = $buf[6]; Pa = $pa; Hpai = $hpai; Seq = 0; Status = 0 }
}

function Open-Tunnels([int]$n) {
    $list = @()
    for ($i = 1; $i -le $n; $i++) { $t = Open-Conn 0x02; if ($t -and $t.Status -eq 0) { $list += $t } else { break } }
    return , $list
}

function Disconnect-Tunnels($list) {
    foreach ($t in $list) {
        try { $null = $t.Sock.SendTo((New-KnxFrame $SVC_DISCONNECT_REQ ([byte[]](@([byte]$t.Ch, 0x00) + $t.Hpai))), $Dst) } catch {}
        try { $t.Sock.Close() } catch {}
    }
}

# Non-blocking drain of inbound TUNNELLING_REQUESTs; ACK each; return the count.
function Receive-Inbound($t) {
    $n = 0; $buf = New-Object byte[] 1024
    while ($t.Sock.Available -gt 0) {
        $from = [System.Net.EndPoint]([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
        $rn = $t.Sock.ReceiveFrom($buf, [ref]$from)
        if ($rn -ge 10 -and ((([int]$buf[2] -shl 8) -bor $buf[3]) -eq $SVC_TUNNEL_REQ)) {
            $null = $t.Sock.SendTo((New-KnxFrame $SVC_TUNNEL_ACK ([byte[]]@(0x04, $buf[7], $buf[8], 0x00))), $Dst)
            $n++
        }
    }
    return $n
}

# One GroupValueWrite (cEMI L_Data.req: 11 00 BC E0 src(0.0.0) GA len=1 00 (80|val)).
function Send-GroupWrite($t, [int]$gaInt, [int]$val) {
    $cemi = [byte[]]@(0x11, 0x00, 0xBC, 0xE0, 0x00, 0x00, (($gaInt -shr 8) -band 0xFF), ($gaInt -band 0xFF), 0x01, 0x00, (0x80 -bor ($val -band 0x3F)))
    $null = $t.Sock.SendTo((New-KnxFrame $SVC_TUNNEL_REQ ([byte[]](@(0x04, [byte]$t.Ch, [byte]($t.Seq -band 0xFF), 0x00) + $cemi))), $Dst)
    $t.Seq = ($t.Seq + 1) -band 0xFF
}
function Send-Heartbeat($t) {
    $null = $t.Sock.SendTo((New-KnxFrame $SVC_CONNSTATE_REQ ([byte[]](@([byte]$t.Ch, 0x00) + $t.Hpai))), $Dst)
}

. (Join-Path $PSScriptRoot '../lib/KnxLogo.ps1')
Write-KnxLogo -Title 'Test-Tunnels'
Write-Host ("  {0}:{1}  (client {2})" -f $Ip, $Port, ($MeB -join '.')) -ForegroundColor Green

# ─────────────────────────────── BusMonitor mode ───────────────────────────────
if ($BusMon) {
    Write-Host "  mode: HW BusMonitor (CRI layer 0x80) — L_Busmon.ind until Ctrl-C" -ForegroundColor Cyan
    $bm = Open-Conn 0x80
    if ($null -eq $bm -or $bm.Status -ne 0) {
        Write-Host ("  busmon connect failed: {0}" -f $(if ($bm) { Get-StatusName $bm.Status } else { "no response" })) -ForegroundColor Red; return
    }
    Write-Host ("  busmon connected: channel 0x{0:X2}" -f $bm.Ch) -ForegroundColor Green
    $frames = 0; $start = [datetime]::Now; $lastHb = [datetime]::Now; $buf = New-Object byte[] 1024
    $bm.Sock.ReceiveTimeout = 200
    try {
        while ($true) {
            if ($bm.Sock.Available -gt 0) {
                $from = [System.Net.EndPoint]([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)); $rn = $bm.Sock.ReceiveFrom($buf, [ref]$from)
                if ($rn -gt 10 -and ((([int]$buf[2] -shl 8) -bor $buf[3]) -eq $SVC_TUNNEL_REQ)) {
                    $null = $bm.Sock.SendTo((New-KnxFrame $SVC_TUNNEL_ACK ([byte[]]@(0x04, $buf[7], $buf[8], 0x00))), $Dst)
                    $frames++
                    $hex = (($buf[10..($rn - 1)]) | ForEach-Object { "{0:X2}" -f $_ }) -join ' '
                    Write-Host ("  [{0,5}] {1}" -f $frames, $hex) -ForegroundColor Gray
                }
            } else { Start-Sleep -Milliseconds 5 }
            if (([datetime]::Now - $lastHb).TotalSeconds -ge 60) { Send-Heartbeat $bm; $lastHb = [datetime]::Now }
            if ($Seconds -gt 0 -and ([datetime]::Now - $start).TotalSeconds -ge $Seconds) { break }
        }
    } finally {
        Write-Host ("  busmon: {0} frames. disconnecting." -f $frames) -ForegroundColor Cyan
        Disconnect-Tunnels @($bm)
    }
    return
}

# ─────────────────────────────── Ramp mode ───────────────────────────────
if ($Ramp) {
    $gaInt = ConvertTo-Ga $Ga
    Write-Host ("  mode: RAMP 1..{0} (open k, send+recv, close), then all open/close, then all + stress" -f $Count) -ForegroundColor Cyan
    Write-Host ""
    for ($k = 1; $k -le $Count; $k++) {
        $list = Open-Tunnels $k
        $tx = 0; $rx = 0; $v = 0
        foreach ($t in $list) { Send-GroupWrite $t $gaInt $v; $tx++; $v++ }
        Start-Sleep -Milliseconds 250
        foreach ($t in $list) { $rx += (Receive-Inbound $t) }
        $col = if ($list.Count -lt $k) { 'Yellow' } else { 'Gray' }
        Write-Host ("  ramp {0,2}: opened {1,2}/{2,-2}  tx {3,-3} rx {4,-3}{5}" -f $k, $list.Count, $k, $tx, $rx,
            $(if ($list.Count -lt $k) { "   (only $($list.Count) free -> continuing)" } else { "" })) -ForegroundColor $col
        Disconnect-Tunnels $list
        Start-Sleep -Milliseconds 400
    }
    Write-Host ""
    Write-Host "  --- all open + close ---" -ForegroundColor Cyan
    $list = Open-Tunnels $Count
    Write-Host ("  opened {0}/{1}, closing" -f $list.Count, $Count) -ForegroundColor $(if ($list.Count -lt $Count) { 'Yellow' } else { 'Gray' })
    Disconnect-Tunnels $list
    Start-Sleep -Milliseconds 500

    $secs = if ($Seconds -gt 0) { $Seconds } else { 10 }
    Write-Host ""
    Write-Host ("  --- all open + STRESS {0}s ({1} tx/s -> GA {2}) ---" -f $secs, $Rate, $Ga) -ForegroundColor Cyan
    $list = Open-Tunnels $Count
    Write-Host ("  opened {0}/{1}" -f $list.Count, $Count) -ForegroundColor $(if ($list.Count -lt $Count) { 'Yellow' } else { 'Gray' })
    if ($list.Count -gt 0) {
        $intervalMs = if ($Rate -gt 0) { [int](1000 / $Rate) } else { 50 }
        $start = [datetime]::Now; $lastStat = [datetime]::Now; $rr = 0; $val = 0; $txTotal = 0; $rxTotal = 0
        try {
            while (([datetime]::Now - $start).TotalSeconds -lt $secs) {
                $t = $list[$rr % $list.Count]; $rr++
                Send-GroupWrite $t $gaInt $val; $txTotal++; $val = ($val + 1) -band 0x3F
                foreach ($x in $list) { $rxTotal += (Receive-Inbound $x) }
                Start-Sleep -Milliseconds $intervalMs
                if (([datetime]::Now - $lastStat).TotalSeconds -ge 2) { Write-Host ("  tx {0}  rx {1}" -f $txTotal, $rxTotal) -ForegroundColor DarkGray; $lastStat = [datetime]::Now }
            }
        } finally {
            Write-Host ("  stress totals: tx {0}  rx {1}" -f $txTotal, $rxTotal) -ForegroundColor Cyan
            Disconnect-Tunnels $list
        }
    }
    Write-Host ""
    Write-Host "  ramp done." -ForegroundColor Green
    return
}

# ─────────────────────────────── default / hold / stress / plus1 ───────────────────────────────
Write-Host ("  opening {0} data tunnels..." -f $Count) -ForegroundColor Cyan
$tunnels = @()
for ($i = 1; $i -le $Count; $i++) {
    $t = Open-Conn 0x02
    if ($t -and $t.Status -eq 0) { Write-Host ("  [{0,2}] channel 0x{1:X2}  PA {2}" -f $i, $t.Ch, $t.Pa) -ForegroundColor Gray; $tunnels += $t }
    elseif ($t) { Write-Host ("  [{0,2}] {1}" -f $i, (Get-StatusName $t.Status)) -ForegroundColor Yellow; break }
    else { Write-Host ("  [{0,2}] no response" -f $i) -ForegroundColor Yellow; break }
}
Write-Host ("  opened {0}/{1} tunnels" -f $tunnels.Count, $Count) -ForegroundColor Cyan

if ($Plus1) {
    Write-Host "  probing one extra connection (expect 0x24 / 0x25):" -ForegroundColor Cyan
    $x = Open-Conn 0x02
    if ($x -and $x.Status -eq 0) { Write-Host ("  got a slot (0x{0:X2}) -> not exhausted" -f $x.Ch) -ForegroundColor Red; Disconnect-Tunnels @($x) }
    elseif ($x) { Write-Host ("  -> {0}" -f (Get-StatusName $x.Status)) -ForegroundColor Green }
    else { Write-Host "  -> no response" -ForegroundColor Yellow }
}

if (($Hold -or $Stress) -and $tunnels.Count -gt 0) {
    $gaInt = ConvertTo-Ga $Ga
    Write-Host ("  mode: {0}. Ctrl-C to disconnect." -f $(if ($Stress) { "STRESS ($Rate tx/s -> GA $Ga)" } else { "HOLD" })) -ForegroundColor Cyan
    $start = [datetime]::Now; $lastHb = [datetime]::Now; $lastStat = [datetime]::Now
    $rr = 0; $intervalMs = if ($Rate -gt 0) { [int](1000 / $Rate) } else { 50 }; $val = 0; $txTotal = 0; $rxTotal = 0
    try {
        while ($true) {
            if ($Stress) { $t = $tunnels[$rr % $tunnels.Count]; $rr++; Send-GroupWrite $t $gaInt $val; $txTotal++; $val = ($val + 1) -band 0x3F }
            foreach ($t in $tunnels) { $rxTotal += (Receive-Inbound $t) }
            Start-Sleep -Milliseconds $(if ($Stress) { $intervalMs } else { 50 })
            if (([datetime]::Now - $lastStat).TotalSeconds -ge 2) { Write-Host ("  tx {0}  rx {1}  ({2} tunnels)" -f $txTotal, $rxTotal, $tunnels.Count) -ForegroundColor DarkGray; $lastStat = [datetime]::Now }
            if (([datetime]::Now - $lastHb).TotalSeconds -ge 60) { foreach ($t in $tunnels) { Send-Heartbeat $t }; $lastHb = [datetime]::Now }
            if ($Seconds -gt 0 -and ([datetime]::Now - $start).TotalSeconds -ge $Seconds) { break }
        }
    } finally {
        Write-Host ("  totals: tx {0}  rx {1}" -f $txTotal, $rxTotal) -ForegroundColor Cyan
        Disconnect-Tunnels $tunnels
    }
} else {
    Disconnect-Tunnels $tunnels
}
