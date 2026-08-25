#!/usr/bin/env pwsh
<#
Open ■
┬────┴  Test-KnxRouter
■ KNX   2026 OpenKNX - Erkan Çolak

FILEPATH: Test-KnxRouter.ps1

.SYNOPSIS
    Test & stress tool for the OpenKNX KNX-over-IP router

.DESCRIPTION
    One script, several tests. Verifies the device builds/responds correctly and
    reproduces the failure modes we fixed (heap leaks). UDP only - no extra deps.
    Runs on Windows 10 + PowerShell 5.1 and on PowerShell 7 (macOS/Linux).

    Tests:
      selftest  Offline - builds every KNXnet/IP frame and checks the bytes against
                the proven Python reference. No device needed. (PASS/FAIL, exit code)
      health    Is KNX-IP alive? Ping + a KNXnet/IP DESCRIPTION round-trip. SAFE.
      leak      Gentle cEMI M_PropRead negative-path flood (our cEMI leak). Watch the
                device console 'HEAP free=' : flat = fixed, dropping = leak. SAFE-ISH.
      route     KNXnet/IP routing flood -> forces IP->TP routing -> fills the TP TX
                queue (our tpuart 'transmit queue is full' leak path). Writes to the
                bus. MODERATE.
      flood     Raw discovery flood (search|desc|mdns) - CPU/DoS robustness. MODERATE.
      wreck     Aggressive unlimited M_PropRead flood. Can CPU-starve the device into
                a watchdog loop -> OpenKNX auto-erase WIPES the KNX config. DANGER.
      soak      Long-run regression: sustained cEMI load while KNX-IP must stay
                responsive (the heap-leak hang). Periodic health probes. SAFE-ISH.
      tunnel    Open tunnel connections to exhaustion, free them, reconnect ->
                checks for tunnel-slot leaks. SAFE.
      load      Multicast routing back-pressure: auto-ramp ROUTING_INDICATION and
                count ROUTING_BUSY / ROUTING_LOST_MESSAGE. Writes to the bus. MODERATE.
      discover  Repeated DESCRIPTION round-trips; parses DIBs (name/PA/families). SAFE.
      robust    Sends malformed/unsupported KNXnet/IP frames; device must ignore them
                and stay responsive (misbehaving-client hardening). SAFE.

.PARAMETER Test
    selftest | health | leak | route | flood | wreck |
    soak | tunnel | load | discover | robust            (default: shows help)

.PARAMETER Ip
    Router IP address. Default 11.11.0.210.

.PARAMETER Rate
    Requests/sec for leak/route. 0 = unlimited (max speed). Default 30.

.PARAMETER Seconds
    Auto-stop after N seconds. 0 = run until Ctrl-C. Default 0.
    soak defaults to 300, load to 30 when 0.

.PARAMETER Count
    Iteration count for tunnel (connections, default 16) and discover (round-trips,
    default 5). Default 0 -> per-mode default.

.PARAMETER Sub
    flood sub-mode: mdns | search | desc. Default search.

.PARAMETER Ga
    route group address to write, e.g. 1/2/3. Default 1/2/3.

.PARAMETER Yes
    Skip the danger confirmation (route/wreck). Use with care.

.EXAMPLE
    ./Test-KnxRouter.ps1 selftest
.EXAMPLE
    ./Test-KnxRouter.ps1 health 11.11.0.210
.EXAMPLE
    ./Test-KnxRouter.ps1 leak 11.11.0.210 -Rate 5 -Seconds 600
.EXAMPLE
    ./Test-KnxRouter.ps1 route 11.11.0.210 -Ga 31/7/255 -Rate 0
.EXAMPLE
    ./Test-KnxRouter.ps1 wreck 11.11.0.210      # DANGER: can wipe the config
.EXAMPLE
    ./Test-KnxRouter.ps1 soak 11.11.0.210 -Seconds 600 -Rate 20
.EXAMPLE
    ./Test-KnxRouter.ps1 tunnel 11.11.0.210 -Count 16
.EXAMPLE
    ./Test-KnxRouter.ps1 load 11.11.0.210 -Seconds 30 -Ga 1/2/3
.EXAMPLE
    ./Test-KnxRouter.ps1 discover 11.11.0.210 -Count 5
.EXAMPLE
    ./Test-KnxRouter.ps1 robust 11.11.0.210
#>
param(
    [Parameter(Position = 0)][string]$Ip   = "",
    [Parameter(Position = 1)][string]$Test = "",
    [int]$Rate    = 30,
    [int]$Seconds = 0,
    [int]$Count   = 0,
    [string]$Sub  = "search",
    [string]$Ga   = "31/7/255",
    [string]$Pa   = "",
    [int]$ApduBytes = 0,
    [switch]$Yes,
    [switch]$Loop
)

# Usage is IP-first: <ip> <command> [options]. Be tolerant so nothing breaks on habit:
# accept the two positionals in EITHER order, and allow a no-IP command (e.g. selftest) alone.
$ipRe = '^\d{1,3}(\.\d{1,3}){3}$'
if ($Ip -notmatch $ipRe -and $Test -match $ipRe) {
    # given as <command> <ip> -> swap to <ip> <command>
    $swap = $Ip; $Ip = $Test; $Test = $swap
}
elseif ($Test -eq "" -and $Ip -ne "" -and $Ip -notmatch $ipRe) {
    # single positional that isn't an IP -> it's the command (e.g. selftest)
    $Test = $Ip
    $Ip   = ""
}
if ($Ip -eq "") { $Ip = "11.11.0.210" } # convenience default when a command omits the IP

# PS 5.1 (Windows) doesn't define $IsWindows/$IsMacOS/$IsLinux - shim them.
if ($null -eq (Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue)) {
    $IsWindows = $true; $IsMacOS = $false; $IsLinux = $false
}
if ($IsWindows) { try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {} }

# ─── Helpers: frame construction ────────────────────────────────────────────────
function New-KnxFrame([int]$svc, [byte[]]$body) {
    # KNXnet/IP header: 06 10 <service(2)> <totalLen(2)> <body>
    $len = 6 + $body.Length
    $hdr = [byte[]]@(0x06, 0x10, (($svc -shr 8) -band 0xFF), ($svc -band 0xFF), (($len -shr 8) -band 0xFF), ($len -band 0xFF))
    return [byte[]]($hdr + $body)
}
function New-Hpai([byte[]]$ipB, [int]$port) {
    return [byte[]](@(0x08, 0x01) + $ipB + @((($port -shr 8) -band 0xFF), ($port -band 0xFF)))
}
function New-DnsLabel([string]$s) { return [byte[]](@([byte]$s.Length) + [System.Text.Encoding]::ASCII.GetBytes($s)) }
function New-MdnsFrame {
    return [byte[]](@(0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0) +
        (New-DnsLabel "_services") + (New-DnsLabel "_dns-sd") + (New-DnsLabel "_udp") + (New-DnsLabel "local") +
        @(0x00, 0x00, 0x0C, 0x80, 0x01))
}
function ConvertTo-Ga([string]$ga) {
    $p = $ga -split '/'
    if ($p.Count -ge 3) { return (([int]$p[0] -shl 11) -bor ([int]$p[1] -shl 8) -bor [int]$p[2]) }
    return (([int]$p[0] -shl 11) -bor [int]$p[1])   # 2-level main/sub
}
function New-RoutingFrame([int]$ga, [int]$val) {
    # ROUTING_INDICATION (0x0530) carrying a cEMI L_Data.ind GroupValueWrite
    $cemi = [byte[]]@(0x29, 0x00, 0xBC, 0xE0, 0x00, 0x00, (($ga -shr 8) -band 0xFF), ($ga -band 0xFF), 0x01, 0x00, (0x80 -bor ($val -band 1)))
    return New-KnxFrame 0x0530 $cemi
}
function ConvertTo-Hex([byte[]]$b) { return (($b | ForEach-Object { $_.ToString('X2') }) -join '') }
function Get-Color([bool]$ok) { if ($ok) { 'Green' } else { 'Red' } }
function Get-PassFail([bool]$ok) { if ($ok) { 'PASS' } else { 'FAIL' } }

# ─── Helpers: sockets ───────────────────────────────────────────────────────────
function Get-LocalIpBytes([string]$dst) {
    $u = New-Object System.Net.Sockets.UdpClient
    try { $u.Connect($dst, 3671); $b = $u.Client.LocalEndPoint.Address.GetAddressBytes() }
    finally { $u.Close() }
    return $b
}
function New-UdpSocket {
    return New-Object System.Net.Sockets.Socket(
        [System.Net.Sockets.AddressFamily]::InterNetwork,
        [System.Net.Sockets.SocketType]::Dgram,
        [System.Net.Sockets.ProtocolType]::Udp)
}

# DESCRIPTION round-trip on a fresh ephemeral socket. $true iff a DESCRIPTION_RESPONSE (0x0204) arrives.
function Test-KnxAlive([string]$ip, [int]$timeoutMs = 1500) {
    $sock = $null
    try {
        $sock = New-UdpSocket
        $sock.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
        $myport = ([System.Net.IPEndPoint]$sock.LocalEndPoint).Port
        $meB = Get-LocalIpBytes $ip
        $dst = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($ip), 3671)
        $null = $sock.SendTo((New-KnxFrame 0x0203 (New-Hpai $meB $myport)), $dst)
        $sock.ReceiveTimeout = $timeoutMs
        $buf = New-Object byte[] 1024
        $sender = [System.Net.EndPoint]([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
        $rn = $sock.ReceiveFrom($buf, [ref]$sender)
        return ($rn -ge 4 -and $buf[2] -eq 0x02 -and $buf[3] -eq 0x04)
    } catch { return $false }
    finally { if ($null -ne $sock) { try { $sock.Close() } catch {} } }
}

# Open a KNXnet/IP device-management connection. Returns @{Sock;Ch;Hpai;Dst} or $null.
function Connect-DevMgmt([string]$ip) {
    $sock = New-UdpSocket
    try {
        $sock.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
        $myport = ([System.Net.IPEndPoint]$sock.LocalEndPoint).Port
        $meB = Get-LocalIpBytes $ip
        $hpai = New-Hpai $meB $myport
        $dst = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($ip), 3671)
        # CONNECT_REQUEST (0x0205): controlHPAI + dataHPAI + device-mgmt CRI (0x02 0x03)
        $null = $sock.SendTo((New-KnxFrame 0x0205 ([byte[]]($hpai + $hpai + @(0x02, 0x03)))), $dst)
        $sock.ReceiveTimeout = 3000
        $buf = New-Object byte[] 1024
        $sender = [System.Net.EndPoint]([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
        $rn = $sock.ReceiveFrom($buf, [ref]$sender)
        if ($rn -lt 8 -or $buf[7] -ne 0) { $sock.Close(); return $null }
        return [PSCustomObject]@{ Sock = $sock; Ch = $buf[6]; Hpai = $hpai; Dst = $dst }
    } catch { try { $sock.Close() } catch {}; return $null }
}

# Walk DIBs of a DESCRIPTION/SEARCH_RESPONSE (frame). Returns @{Name;Pa;Families}.
function Parse-Dibs([byte[]]$buf, [int]$len) {
    $name = ""; $pa = ""; $families = @()
    $famNames = @{ 0x02 = 'Core'; 0x03 = 'DeviceMgmt'; 0x04 = 'Tunneling'; 0x05 = 'Routing' }
    $off = 6
    while ($off + 2 -le $len) {
        $structLen = $buf[$off]
        if ($structLen -eq 0 -or ($off + $structLen) -gt $len) { break }
        $type = $buf[$off + 1]
        if ($type -eq 0x01 -and $structLen -ge 54) {
            $a = ([int]$buf[$off + 4] -shl 8) -bor $buf[$off + 5]
            $pa = "{0}.{1}.{2}" -f (($a -shr 12) -band 0xF), (($a -shr 8) -band 0xF), ($a -band 0xFF)
            $nb = New-Object System.Collections.Generic.List[byte]
            for ($i = $off + 24; $i -lt $off + 54; $i++) { if ($buf[$i] -eq 0) { break }; $nb.Add($buf[$i]) }
            $name = [System.Text.Encoding]::ASCII.GetString($nb.ToArray())
        }
        elseif ($type -eq 0x02) {
            for ($i = $off + 2; $i + 1 -lt $off + $structLen; $i += 2) {
                $fid = $buf[$i]
                if ($famNames.ContainsKey([int]$fid)) { $families += $famNames[[int]$fid] }
                else { $families += ("0x{0:X2}" -f $fid) }
            }
        }
        $off += $structLen
    }
    return [PSCustomObject]@{ Name = $name; Pa = $pa; Families = $families }
}

function Show-Logo {
    Write-Host ""
    Write-Host "Open " -NoNewline; Write-Host ([char]0x25A0) -ForegroundColor Green
    Write-Host (([string][char]0x252C) + ([char]0x2500) + ([char]0x2500) + ([char]0x2500) + ([char]0x2500) + ([char]0x2534) + " Test-KnxRouter") -ForegroundColor Green
    Write-Host ([char]0x25A0) -NoNewline -ForegroundColor Green; Write-Host " KNX   OpenKNX IP-Router test & stress tool"
    Write-Host ""
}

# ─── Tests ──────────────────────────────────────────────────────────────────────

function Invoke-SelfTest {
    Show-Logo
    Write-Host "Self-test: KNXnet/IP frame construction (offline, no device)" -ForegroundColor Cyan
    $me = [System.Net.IPAddress]::Parse("11.11.0.144").GetAddressBytes()
    $hpai = New-Hpai $me 55123; $hpai5 = New-Hpai $me 55000
    $cemi = [byte[]]@(0xFC, 0x00, 0x00, 0x01, 0xC8, 0x10, 0x00)
    $frames = [ordered]@{
        CONNECT = New-KnxFrame 0x0205 ([byte[]]($hpai + $hpai + @(0x02, 0x03)))
        DEVCONF = New-KnxFrame 0x0310 ([byte[]](@(0x04, 0x15, 0x00, 0x00) + $cemi))
        ACK     = New-KnxFrame 0x0311 ([byte[]]@(0x04, 0x15, 0x00, 0x00))
        DISCONN = New-KnxFrame 0x0209 ([byte[]](@(0x15, 0x00) + $hpai))
        SEARCH  = New-KnxFrame 0x0201 $hpai5
        DESC    = New-KnxFrame 0x0203 $hpai5
        ROUTING = New-RoutingFrame (ConvertTo-Ga "1/2/3") 1
        MDNS    = New-MdnsFrame
    }
    # Golden vectors
    $gold = @{
        CONNECT = '06100205001808010B0B0090D75308010B0B0090D7530203'
        DEVCONF = '06100310001104150000FC000001C81000'
        ACK     = '06100311000A04150000'
        DISCONN = '061002090010150008010B0B0090D753'
        SEARCH  = '06100201000E08010B0B0090D6D8'
        DESC    = '06100203000E08010B0B0090D6D8'
        ROUTING = '0610053000112900BCE000000A03010081'
        MDNS    = '000000000001000000000000095F7365727669636573075F646E732D7364045F756470056C6F63616C00000C8001'
    }
    $fail = 0
    foreach ($k in $frames.Keys) {
        $h = ConvertTo-Hex $frames[$k]
        $ok = ($h -eq $gold[$k])
        if (-not $ok) { $fail++ }
        Write-Host ("  {0,-8} {1}" -f $k, (Get-PassFail $ok)) -ForegroundColor (Get-Color $ok)
        if (-not $ok) {
            Write-Host "      exp $($gold[$k])" -ForegroundColor DarkGray
            Write-Host "      got $h" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
    if ($fail -eq 0) { Write-Host "  ALL $($frames.Count) frames byte-identical to the Python reference." -ForegroundColor Green; exit 0 }
    else { Write-Host "  $fail frame(s) MISMATCH" -ForegroundColor Red; exit 1 }
}

function Invoke-Health([string]$ip) {
    Show-Logo
    Write-Host "Health check: $ip" -ForegroundColor Cyan
    $okPing = $null
    try { $okPing = Test-Connection -Quiet -Count 2 -ErrorAction Stop $ip } catch { $okPing = $null }

    # DESCRIPTION_REQUEST (0x0203) -> expect DESCRIPTION_RESPONSE (0x0204)
    $knx = Test-KnxAlive $ip 2000

    if ($null -ne $okPing) { Write-Host ("  Ping (ICMP)        : {0}" -f (Get-PassFail $okPing)) -ForegroundColor (Get-Color $okPing) }
    else { Write-Host "  Ping (ICMP)        : n/a" -ForegroundColor DarkGray }
    Write-Host ("  KNXnet/IP DESCRIBE : {0}" -f (Get-PassFail $knx)) -ForegroundColor (Get-Color $knx)
    Write-Host ""
    if ($knx) { Write-Host "  => KNX-IP is ALIVE" -ForegroundColor Green; exit 0 }
    else { Write-Host "  => KNX-IP NOT responding (router may be hung / heap exhausted)" -ForegroundColor Red; exit 1 }
}

# Shared cEMI M_PropRead engine. rate 0 = unlimited; stopOnSilence avoids flooding across reboots.
function Invoke-PropRead([string]$ip, [int]$rate, [bool]$stopOnSilence, [int]$seconds) {
    $sock = New-UdpSocket
    $sock.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
    $myport = ([System.Net.IPEndPoint]$sock.LocalEndPoint).Port
    $meB = Get-LocalIpBytes $ip
    $hpai = New-Hpai $meB $myport
    $dst = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($ip), 3671)

    # CONNECT_REQUEST, device-management CRI (0x03)
    $null = $sock.SendTo((New-KnxFrame 0x0205 ([byte[]]($hpai + $hpai + @(0x02, 0x03)))), $dst)
    $sock.ReceiveTimeout = 3000
    $buf = New-Object byte[] 1024
    $sender = [System.Net.EndPoint]([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
    try { $null = $sock.ReceiveFrom($buf, [ref]$sender) } catch { Write-Host "CONNECT: no response" -ForegroundColor Red; $sock.Close(); return }
    if ($buf[7] -ne 0) { Write-Host ("CONNECT failed status=0x{0:X2} (no free channel? wait 120s/reboot)" -f $buf[7]) -ForegroundColor Red; $sock.Close(); return }
    $ch = $buf[6]
    Write-Host ("connected ch=0x{0:X2}  -> watch device 'HEAP free='  (Ctrl-C to stop)" -f $ch) -ForegroundColor Cyan

    $combos = @(@(0, 1), @(0, 0)); $propId = 200
    $n = 0; $cons = 0; $negs = 0; $seq = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastResp = $sw.Elapsed.TotalSeconds
    $delay = 0; if ($rate -gt 0) { $delay = [int](1000 / $rate) }
    try {
        while ($true) {
            if ($seconds -gt 0 -and $sw.Elapsed.TotalSeconds -ge $seconds) { break }
            $c = $combos[$n % 2]
            $cemi = [byte[]]@(0xFC, (($c[0] -shr 8) -band 0xFF), ($c[0] -band 0xFF), $c[1], $propId, 0x10, 0x00)
            $null = $sock.SendTo((New-KnxFrame 0x0310 ([byte[]](@(0x04, $ch, ($seq -band 0xFF), 0x00) + $cemi))), $dst)
            $seq++; $n++
            while ($sock.Available -gt 0) {
                $rn = $sock.ReceiveFrom($buf, [ref]$sender)
                if ($rn -ge 10 -and $buf[2] -eq 0x03 -and $buf[3] -eq 0x10) {
                    $null = $sock.SendTo((New-KnxFrame 0x0311 ([byte[]]@(0x04, $buf[7], $buf[8], 0x00))), $dst)
                    $cons++; $lastResp = $sw.Elapsed.TotalSeconds
                    if ($rn -ge 16 -and $buf[10] -eq 0xFB -and (($buf[15] -shr 4) -eq 0)) { $negs++ }
                }
            }
            if ($n % 200 -eq 0) { Write-Host ("  reqs={0} cons={1} neg={2}  {3:n0}/s" -f $n, $cons, $negs, ($n / $sw.Elapsed.TotalSeconds)) -ForegroundColor DarkGray }
            if ($stopOnSilence -and $cons -gt 0 -and (($sw.Elapsed.TotalSeconds - $lastResp) -gt 3)) {
                Write-Host "`n  device silent 3s -> stop (avoid flooding across reboot)" -ForegroundColor Yellow; break
            }
            if ($delay -gt 0) { Start-Sleep -Milliseconds $delay }
        }
    }
    finally {
        try { $null = $sock.SendTo((New-KnxFrame 0x0209 ([byte[]](@($ch, 0x00) + $hpai))), $dst) } catch {}
        $sock.Close()
        Write-Host ("`nstopped: reqs={0} cons={1} neg={2}" -f $n, $cons, $negs) -ForegroundColor Cyan
    }
}

function Invoke-Flood([string]$ip, [string]$sub, [int]$seconds) {
    Show-Logo
    $meB = Get-LocalIpBytes $ip
    $port = 3671
    switch ($sub.ToLower()) {
        'mdns'   { $pkt = New-MdnsFrame; $port = 5353 }
        'search' { $pkt = New-KnxFrame 0x0201 (New-Hpai $meB 55000) }
        'desc'   { $pkt = New-KnxFrame 0x0203 (New-Hpai $meB 55000) }
        default  { Write-Host "sub: mdns | search | desc" -ForegroundColor Red; return }
    }
    $u = New-Object System.Net.Sockets.UdpClient
    $n = 0; $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host "flooding ${ip}:${port} ($sub) - Ctrl-C to stop" -ForegroundColor Cyan
    try {
        while ($true) {
            if ($seconds -gt 0 -and $sw.Elapsed.TotalSeconds -ge $seconds) { break }
            $null = $u.Send($pkt, $pkt.Length, $ip, $port); $n++
            if ($n % 5000 -eq 0) { Write-Host ("  {0} pkts {1:n0}/s" -f $n, ($n / $sw.Elapsed.TotalSeconds)) -ForegroundColor DarkGray }
        }
    }
    finally { $u.Close(); Write-Host "`nstopped after $n" -ForegroundColor Cyan }
}

function Invoke-Route([string]$ip, [string]$ga, [int]$rate, [int]$seconds) {
    Show-Logo
    Write-Host "  ROUTE sends GroupValueWrite=1 to the TP bus. Use a FREE group address that NO" -ForegroundColor Yellow
    Write-Host "  device listens to - high main groups (16-31) are usually free, e.g. 31/7/255." -ForegroundColor Yellow
    if (-not $Yes) {
        $g = Read-Host "  Group address to write [$ga]"
        if ($g) { $ga = $g }
        $a = Read-Host "  Write GroupValueWrite($ga)=1 to the bus - proceed? [y/N]"
        if ($a -notmatch '^[Yy]') { Write-Host "  aborted" -ForegroundColor Yellow; return }
    }
    $pkt = New-RoutingFrame (ConvertTo-Ga $ga) 1
    $mc = "224.0.23.12"; $port = 3671
    $u = New-Object System.Net.Sockets.UdpClient
    $n = 0; $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $delay = 0; if ($rate -gt 0) { $delay = [int](1000 / $rate) }
    Write-Host "routing-flood ${mc}:${port} GA=$ga (-Rate 0 = max) - watch 'transmit queue is full' on device (Ctrl-C)" -ForegroundColor Cyan
    try {
        while ($true) {
            if ($seconds -gt 0 -and $sw.Elapsed.TotalSeconds -ge $seconds) { break }
            $null = $u.Send($pkt, $pkt.Length, $mc, $port); $n++
            if ($n % 500 -eq 0) { Write-Host ("  {0} telegrams {1:n0}/s" -f $n, ($n / $sw.Elapsed.TotalSeconds)) -ForegroundColor DarkGray }
            if ($delay -gt 0) { Start-Sleep -Milliseconds $delay }
        }
    }
    finally { $u.Close(); Write-Host "`nstopped after $n" -ForegroundColor Cyan }
}

function Invoke-Wreck([string]$ip, [int]$seconds) {
    Show-Logo
    Write-Host "  !! DANGER - aggressive unlimited M_PropRead flood." -ForegroundColor Red
    Write-Host "  !! Can CPU-starve the device into a watchdog loop -> OpenKNX auto-erase WIPES the KNX config." -ForegroundColor Red
    Write-Host "  !! Use ONLY on a test device you can reprogram in ETS." -ForegroundColor Red
    if (-not $Yes) {
        $a = Read-Host "  Type WRECK to proceed"
        if ($a -ne 'WRECK') { Write-Host "  aborted" -ForegroundColor Yellow; return }
    }
    # rate 0 = max speed, stopOnSilence=$false = keep flooding even across reboots (that is what wipes the config)
    Invoke-PropRead $ip 0 $false $seconds
}

# ─── soak: sustained cEMI load + periodic health probes (heap-leak regression) ───
function Invoke-Soak([string]$ip, [int]$seconds, [int]$rate) {
    Show-Logo
    if ($seconds -le 0) { $seconds = 300 }
    if ($rate -le 0) { $rate = 20 }
    Write-Host "Soak test: $ip  (${seconds}s @ ${rate}/s cEMI + 10s health probes)" -ForegroundColor Cyan
    $conn = Connect-DevMgmt $ip
    if ($null -eq $conn) { Write-Host "  CONNECT failed (no free channel? wait 120s/reboot)" -ForegroundColor Red; exit 1 }
    $sock = $conn.Sock; $ch = $conn.Ch; $hpai = $conn.Hpai; $dst = $conn.Dst
    Write-Host ("  connected ch=0x{0:X2}" -f $ch) -ForegroundColor Cyan
    $buf = New-Object byte[] 1024
    $sender = [System.Net.EndPoint]([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
    $seq = 0; $n = 0; $probes = 0; $hfails = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastProbe = 0
    $delay = [int](1000 / $rate)
    try {
        while ($sw.Elapsed.TotalSeconds -lt $seconds) {
            # M_PropRead_req on the negative path (prop 200 / object 1 does not exist)
            $cemi = [byte[]]@(0xFC, 0x00, 0x00, 0x01, 200, 0x10, 0x00)
            $null = $sock.SendTo((New-KnxFrame 0x0310 ([byte[]](@(0x04, $ch, ($seq -band 0xFF), 0x00) + $cemi))), $dst)
            $seq++; $n++
            # drain + ACK any incoming DEVICE_CONFIGURATION_REQUEST (0x0310)
            while ($sock.Available -gt 0) {
                $rn = $sock.ReceiveFrom($buf, [ref]$sender)
                if ($rn -ge 10 -and $buf[2] -eq 0x03 -and $buf[3] -eq 0x10) {
                    $null = $sock.SendTo((New-KnxFrame 0x0311 ([byte[]]@(0x04, $buf[7], $buf[8], 0x00))), $dst)
                }
            }
            $elapsed = [int]$sw.Elapsed.TotalSeconds
            if ($elapsed - $lastProbe -ge 10) {
                $lastProbe = $elapsed
                $alive = Test-KnxAlive $ip 1500
                $probes++; if (-not $alive) { $hfails++ }
                Write-Host ("  t={0,4}s  reqs={1,-7} probe={2}" -f $elapsed, $n, (Get-PassFail $alive)) -ForegroundColor (Get-Color $alive)
            }
            if ($delay -gt 0) { Start-Sleep -Milliseconds $delay }
        }
    }
    finally {
        try { $null = $sock.SendTo((New-KnxFrame 0x0209 ([byte[]](@($ch, 0x00) + $hpai))), $dst) } catch {}
        $sock.Close()
    }
    Write-Host ""
    Write-Host ("  total reqs={0}  health probes={1}  failures={2}" -f $n, $probes, $hfails) -ForegroundColor Cyan
    if ($hfails -eq 0) { Write-Host "  => PASS: KNX-IP stayed responsive under sustained cEMI load" -ForegroundColor Green; exit 0 }
    else { Write-Host "  => FAIL: device went unresponsive (heap exhaustion / hang)" -ForegroundColor Red; exit 1 }
}

# ─── tunnel: open tunnels to exhaustion, free them, reconnect (slot-leak check) ──
function Open-Tunnel([string]$ip) {
    $sock = New-UdpSocket
    try {
        $sock.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
        $myport = ([System.Net.IPEndPoint]$sock.LocalEndPoint).Port
        $meB = Get-LocalIpBytes $ip
        $hpai = New-Hpai $meB $myport
        $dst = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($ip), 3671)
        # CONNECT_REQUEST with tunnel CRI 0x04 0x04 0x02 0x00 (TUNNEL_CONNECTION, LinkLayer)
        $null = $sock.SendTo((New-KnxFrame 0x0205 ([byte[]]($hpai + $hpai + @(0x04, 0x04, 0x02, 0x00)))), $dst)
        $sock.ReceiveTimeout = 3000
        $buf = New-Object byte[] 1024
        $sender = [System.Net.EndPoint]([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
        $rn = $sock.ReceiveFrom($buf, [ref]$sender)
        $status = $buf[7]
        $pa = ""
        if ($status -eq 0 -and $rn -ge 20) {
            $a = ([int]$buf[18] -shl 8) -bor $buf[19]
            $pa = "{0}.{1}.{2}" -f (($a -shr 12) -band 0xF), (($a -shr 8) -band 0xF), ($a -band 0xFF)
        }
        return [PSCustomObject]@{ Sock = $sock; Ch = $buf[6]; Status = $status; Pa = $pa; Hpai = $hpai; Dst = $dst }
    } catch { try { $sock.Close() } catch {}; return $null }
}
function Invoke-Tunnel([string]$ip, [int]$count) {
    Show-Logo
    if ($count -le 0) { $count = 16 }
    Write-Host "Tunnel slot test: $ip  (open up to $($count + 1), then free + reconnect)" -ForegroundColor Cyan
    $opened = @()
    $exhausted = $false
    for ($i = 0; $i -le $count; $i++) {
        $t = Open-Tunnel $ip
        if ($null -eq $t) { Write-Host ("  #{0,-2} error/timeout -> stop" -f ($i + 1)) -ForegroundColor Yellow; break }
        if ($t.Status -eq 0x24) {
            Write-Host ("  #{0,-2} E_NO_MORE_CONNECTIONS (0x24) -> all slots used (correct conformance)" -f ($i + 1)) -ForegroundColor Green
            $exhausted = $true; $t.Sock.Close(); break
        }
        if ($t.Status -ne 0) {
            Write-Host ("  #{0,-2} status=0x{1:X2} -> stop" -f ($i + 1), $t.Status) -ForegroundColor Yellow
            $t.Sock.Close(); break
        }
        Write-Host ("  #{0,-2} ch=0x{1:X2}  PA={2}" -f ($i + 1), $t.Ch, $t.Pa) -ForegroundColor Gray
        $opened += $t
    }
    # DISCONNECT all opened tunnels
    foreach ($t in $opened) {
        try { $null = $t.Sock.SendTo((New-KnxFrame 0x0209 ([byte[]](@($t.Ch, 0x00) + $t.Hpai))), $t.Dst) } catch {}
        try { $t.Sock.Close() } catch {}
    }
    Write-Host ("  opened={0}  exhaustion-signalled={1}  -> freeing + waiting 500ms" -f $opened.Count, $exhausted) -ForegroundColor Cyan
    Start-Sleep -Milliseconds 500
    # Reconnect ONE tunnel to verify slots were freed
    $re = Open-Tunnel $ip
    $reOk = ($null -ne $re -and $re.Status -eq 0)
    if ($null -ne $re) {
        if ($reOk) { Write-Host ("  reconnect ch=0x{0:X2} PA={1}" -f $re.Ch, $re.Pa) -ForegroundColor Gray }
        try { $null = $re.Sock.SendTo((New-KnxFrame 0x0209 ([byte[]](@($re.Ch, 0x00) + $re.Hpai))), $re.Dst) } catch {}
        try { $re.Sock.Close() } catch {}
    }
    Write-Host ""
    Write-Host ("  opened={0}  exhaustion={1}  reconnect={2}" -f $opened.Count, $exhausted, (Get-PassFail $reOk)) -ForegroundColor Cyan
    if ($reOk) { Write-Host "  => PASS: tunnel slots recycled (no slot leak)" -ForegroundColor Green; exit 0 }
    else { Write-Host "  => FAIL: could not reconnect after freeing (slot leak?)" -ForegroundColor Red; exit 1 }
}

# ─── load: multicast routing back-pressure (ROUTING_BUSY / LOST_MESSAGE) ─────────
function Invoke-Load([string]$ip, [int]$seconds, [string]$ga) {
    Show-Logo
    if ($seconds -le 0) { $seconds = 30 }
    Write-Host "  LOAD writes ROUTING_INDICATION($ga)=1 to multicast 224.0.23.12 (may toggle real devices)." -ForegroundColor Yellow
    Write-Host "  NOTE: -Rate is ignored (auto-ramp 20 -> 400/s). -Ga selects the group address." -ForegroundColor DarkGray
    if (-not $Yes) {
        $a = Read-Host "  Proceed? [y/N]"
        if ($a -notmatch '^[Yy]') { Write-Host "  aborted" -ForegroundColor Yellow; exit 1 }
    }
    $mc = "224.0.23.12"; $port = 3671
    $pkt = New-RoutingFrame (ConvertTo-Ga $ga) 1
    $u = New-Object System.Net.Sockets.UdpClient
    $busy = 0; $lost = 0; $lostMsgs = 0; $sent = 0
    try {
        $u.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
        $u.Client.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, $port))
        $u.JoinMulticastGroup([System.Net.IPAddress]::Parse($mc))
        $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $rate = 20.0; $lastRamp = 0.0
        Write-Host ("  ramping send rate (start 20/s) for ${seconds}s ...") -ForegroundColor Cyan
        while ($sw.Elapsed.TotalSeconds -lt $seconds) {
            $now = $sw.Elapsed.TotalSeconds
            if ($now - $lastRamp -ge 3) {
                $lastRamp = $now; $rate = [Math]::Min(400.0, $rate * 1.6)
            }
            $null = $u.Send($pkt, $pkt.Length, $mc, $port); $sent++
            # drain received packets
            while ($u.Client.Available -gt 0) {
                $rb = $u.Receive([ref]$ep)
                if ($rb.Length -ge 4 -and $rb[2] -eq 0x05) {
                    if ($rb[3] -eq 0x32) { $busy++ }                # ROUTING_BUSY 0x0532
                    elseif ($rb[3] -eq 0x31) {                      # ROUTING_LOST_MESSAGE 0x0531
                        $lost++
                        if ($rb.Length -ge 10) { $lostMsgs += (([int]$rb[8] -shl 8) -bor $rb[9]) }
                    }
                    # 0x0530 (ROUTING_INDICATION) echoes ignored
                }
            }
            $d = [int](1000 / $rate); if ($d -gt 0) { Start-Sleep -Milliseconds $d }
        }
        $u.DropMulticastGroup([System.Net.IPAddress]::Parse($mc))
    }
    finally { try { $u.Close() } catch {} }
    $alive = Test-KnxAlive $ip 1500
    Write-Host ""
    Write-Host ("  sent={0}  ROUTING_BUSY={1}  ROUTING_LOST_MESSAGE={2} (lost telegrams={3})" -f $sent, $busy, $lost, $lostMsgs) -ForegroundColor Cyan
    Write-Host ("  post-load health: {0}" -f (Get-PassFail $alive)) -ForegroundColor (Get-Color $alive)
    if ($alive) { Write-Host "  => PASS: device applied flow control and stayed alive" -ForegroundColor Green; exit 0 }
    else { Write-Host "  => FAIL: device unresponsive after load (hang)" -ForegroundColor Red; exit 1 }
}

# ─── discover: repeated DESCRIPTION round-trips + DIB parse ──────────────────────
function Invoke-Discover([string]$ip, [int]$count) {
    Show-Logo
    if ($count -le 0) { $count = 5 }
    Write-Host "Discover: $ip  ($count x DESCRIPTION round-trip)" -ForegroundColor Cyan
    $sock = New-UdpSocket
    $sock.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
    $myport = ([System.Net.IPEndPoint]$sock.LocalEndPoint).Port
    $meB = Get-LocalIpBytes $ip
    $dst = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($ip), 3671)
    $buf = New-Object byte[] 1024
    $sender = [System.Net.EndPoint]([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
    $ok = 0; $info = $null
    try {
        for ($i = 0; $i -lt $count; $i++) {
            $null = $sock.SendTo((New-KnxFrame 0x0203 (New-Hpai $meB $myport)), $dst)
            $sock.ReceiveTimeout = 1500
            try {
                $rn = $sock.ReceiveFrom($buf, [ref]$sender)
                if ($rn -ge 4 -and $buf[2] -eq 0x02 -and $buf[3] -eq 0x04) {
                    $ok++
                    if ($null -eq $info) { $info = Parse-Dibs $buf $rn }
                }
            } catch {}
        }
    }
    finally { $sock.Close() }
    Write-Host ""
    Write-Host ("  responses : {0}/{1}" -f $ok, $count) -ForegroundColor (Get-Color ($ok -eq $count))
    $fams = @()
    if ($null -ne $info) {
        Write-Host ("  name      : {0}" -f $info.Name) -ForegroundColor Gray
        Write-Host ("  PA        : {0}" -f $info.Pa) -ForegroundColor Gray
        $fams = $info.Families
        Write-Host ("  families  : {0}" -f ($fams -join ', ')) -ForegroundColor Gray
    }
    $hasCore = ($fams -contains 'Core')
    $hasTunRoute = (($fams -contains 'Tunneling') -or ($fams -contains 'Routing'))
    $pass = ($ok -eq $count -and $hasCore -and $hasTunRoute)
    Write-Host ""
    if ($pass) { Write-Host "  => PASS: all responses + Core + (Tunneling|Routing)" -ForegroundColor Green; exit 0 }
    else { Write-Host "  => FAIL: missing responses or required service families" -ForegroundColor Red; exit 1 }
}

# ─── robust: malformed/unsupported frame barrage (misbehaving-client hardening) ──
function Invoke-Robust([string]$ip) {
    Show-Logo
    Write-Host "Robustness test: $ip  (malformed/unsupported KNXnet/IP frames)" -ForegroundColor Cyan
    $meB = Get-LocalIpBytes $ip
    $hpai = New-Hpai $meB 55000
    $u = New-Object System.Net.Sockets.UdpClient
    $shots = [ordered]@{
        'truncated header'         = [byte[]]@(0x06, 0x10, 0x02)
        'bad header-length byte'   = [byte[]]@(0xFF, 0x10, 0x02, 0x01, 0x00, 0x06)
        'wrong total-length'       = [byte[]]@(0x06, 0x10, 0x02, 0x01, 0x00, 0xFF)
        'unsupported service'      = (New-KnxFrame 0x0999 $hpai)
        'truncated CRI in CONNECT' = (New-KnxFrame 0x0205 ([byte[]]($hpai + $hpai + @(0x04))))
        'oversized junk'           = [byte[]](@(0x06, 0x10, 0x05, 0x30, 0x02, 0x00) + (New-Object byte[] 600))
    }
    try {
        foreach ($k in $shots.Keys) {
            $p = $shots[$k]
            try { $null = $u.Send($p, $p.Length, $ip, 3671) } catch {}
            Write-Host ("  sent {0,-26} ({1} bytes)" -f $k, $p.Length) -ForegroundColor Gray
            Start-Sleep -Milliseconds 100
        }
    }
    finally { try { $u.Close() } catch {} }
    $alive = Test-KnxAlive $ip 1500
    Write-Host ""
    Write-Host ("  post-barrage health: {0}" -f (Get-PassFail $alive)) -ForegroundColor (Get-Color $alive)
    if ($alive) { Write-Host "  => PASS: device ignored the garbage and stayed responsive" -ForegroundColor Green; exit 0 }
    else { Write-Host "  => FAIL: device crashed/hung on malformed input" -ForegroundColor Red; exit 1 }
}

function Invoke-Info([string]$ip) {
    Show-Logo
    Write-Host "info: read the Device-Object properties ETS reads (device-mgmt M_PropRead) on $ip" -ForegroundColor Cyan
    $ctx = Connect-DevMgmt $ip
    if ($null -eq $ctx) { Write-Host "  CONNECT failed (no free device-mgmt channel? wait/reboot)" -ForegroundColor Red; exit 1 }
    $buf = New-Object byte[] 1024
    $sender = [System.Net.EndPoint]([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
    $ctx.Sock.ReceiveTimeout = 1500
    # Device Object (object type 0, instance 1) - the standard properties ETS reads.
    $props = @(
        @{ PID = 11; Name = 'Serial number';   Fmt = 'hex' },
        @{ PID = 12; Name = 'Manufacturer ID'; Fmt = 'u16' },
        @{ PID = 78; Name = 'Hardware type';   Fmt = 'hex' },
        @{ PID = 15; Name = 'Order info';      Fmt = 'ascii' },
        @{ PID = 56; Name = 'Max APDU length'; Fmt = 'u16' },
        @{ PID = 25; Name = 'Version';         Fmt = 'hex' }
    )
    $seq = 0; $got = 0
    foreach ($p in $props) {
        # M_PropRead_req: FC <objType hi lo> <objInst=1> <PID> <NoE=1<<4 | startIdx_hi> <startIdx_lo=1>
        $cemi = [byte[]]@(0xFC, 0x00, 0x00, 0x01, [byte]$p.PID, 0x10, 0x01)
        $null = $ctx.Sock.SendTo((New-KnxFrame 0x0310 ([byte[]](@(0x04, $ctx.Ch, ($seq -band 0xFF), 0x00) + $cemi))), $ctx.Dst)
        $seq++
        $data = $null
        try {
            for ($t = 0; $t -lt 4; $t++) {
                $rn = $ctx.Sock.ReceiveFrom($buf, [ref]$sender)
                if ($rn -ge 10 -and $buf[2] -eq 0x03 -and $buf[3] -eq 0x10) {
                    $null = $ctx.Sock.SendTo((New-KnxFrame 0x0311 ([byte[]]@(0x04, $buf[7], $buf[8], 0x00))), $ctx.Dst)
                    if ($rn -ge 17 -and $buf[10] -eq 0xFB) {
                        if (($buf[15] -shr 4) -eq 0) { break }   # NoE 0 -> property not present (negative)
                        $len = $rn - 17
                        $data = New-Object byte[] $len
                        [Array]::Copy($buf, 17, $data, 0, $len)
                        break
                    }
                }
            }
        } catch {}
        $val = 'n/a'; $col = 'DarkGray'
        if ($null -ne $data -and $data.Length -gt 0) {
            $got++; $col = 'Green'
            switch ($p.Fmt) {
                'u16'   { $v = 0; foreach ($b in $data) { $v = ($v -shl 8) -bor $b }; $val = "$v" }
                'u8'    { $val = "$($data[0])" }
                'ascii' { $val = (-join ($data | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { '.' } })) + "  (0x$(ConvertTo-Hex $data))" }
                default { $val = "0x$(ConvertTo-Hex $data)" }
            }
        }
        Write-Host ("  {0,-18} {1}" -f ($p.Name + ':'), $val) -ForegroundColor $col
    }
    # Real individual address (PA) = what ETS shows: from the DESCRIPTION DIB, NOT from
    # PID_DEVICE_ADDR/PID_SUBNET_ADDR (the cEMI server patches those to the client address).
    $pa = "n/a"
    $ds = New-UdpSocket
    try {
        $ds.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
        $dp = ([System.Net.IPEndPoint]$ds.LocalEndPoint).Port
        $meB = Get-LocalIpBytes $ip
        $null = $ds.SendTo((New-KnxFrame 0x0203 (New-Hpai $meB $dp)), $ctx.Dst)
        $ds.ReceiveTimeout = 1500
        $db = New-Object byte[] 1024
        $de = [System.Net.EndPoint]([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
        $dn = $ds.ReceiveFrom($db, [ref]$de)
        if ($dn -ge 4 -and $db[2] -eq 0x02 -and $db[3] -eq 0x04) { $pa = (Parse-Dibs $db $dn).Pa }
    } catch {}
    $ds.Close()
    $pcol = 'Green'; if ($pa -eq 'n/a') { $pcol = 'DarkGray' }
    Write-Host ("  {0,-18} {1}" -f 'Individual addr:', $pa) -ForegroundColor $pcol
    try { $null = $ctx.Sock.SendTo((New-KnxFrame 0x0209 ([byte[]](@($ctx.Ch, 0x00) + $ctx.Hpai))), $ctx.Dst) } catch {}
    $ctx.Sock.Close()
    Write-Host ""
    if ($got -gt 0) { Write-Host "  INFO PASS: read $got/$($props.Count) properties via the path ETS uses." -ForegroundColor Green; exit 0 }
    else { Write-Host "  INFO FAIL: no properties returned." -ForegroundColor Red; exit 1 }
}

# SAFE + hardening suite. Each entry: @{ m='name'; args=@(...) }. Extend to add a test to `all`.
# tunnel = S1 tunnel-slot reaper · robust = cEMI OOB/runt guards · leak = cEMI heap-leak negative path.
$SuiteBase = @(
    @{ m = 'selftest' }
    @{ m = 'health' }
    @{ m = 'discover' }
    @{ m = 'info' }
    @{ m = 'tunnel' }                                            # hardening: S1 tunnel-slot reaper / slot leak
    @{ m = 'robust' }                                            # hardening: cEMI OOB / runt-frame guards
    @{ m = 'leak'; args = @('-Seconds', '20', '-Rate', '10') }   # hardening: cEMI heap-leak negative path (bounded)
)

function Invoke-Suite([string]$ip, [bool]$loop, [string]$pa, [int]$apduBytes) {
    Show-Logo
    $exe = 'powershell'; if ($PSVersionTable.PSEdition -eq 'Core') { $exe = 'pwsh' }
    $suite = @($SuiteBase)
    # connection-oriented programming-path hardening (threshold) - only if a target device is given
    if (-not [string]::IsNullOrWhiteSpace($pa)) {
        $pargs = @('-Pa', $pa, '-Count', '20')
        if ($apduBytes -gt 0) { $pargs += @('-ApduBytes', "$apduBytes") }
        $suite += @{ m = 'prog'; args = $pargs }                 # hardening: connection-oriented / rx-threshold
    }
    $names = ($suite | ForEach-Object { $_.m }) -join ', '
    $tail = ''; if ($loop) { $tail = '  (loop - Ctrl-C to stop)' }
    Write-Host ("suite: [$names] on $ip$tail") -ForegroundColor Cyan
    if ([string]::IsNullOrWhiteSpace($pa)) { Write-Host "  (add -Pa x.y.z to also loop the connection-oriented 'prog' hardening)" -ForegroundColor DarkGray }
    $round = 0; $exitCode = 0
    do {
        $round++
        Write-Host ""; Write-Host ("========== run #$round ==========") -ForegroundColor Cyan
        $pass = 0; $failed = @()
        foreach ($entry in $suite) {
            $m = $entry.m
            Write-Host ""; Write-Host ("----- $m -----") -ForegroundColor DarkCyan
            if ($entry.args) { $ea = $entry.args; & $exe -NoProfile -File $PSCommandPath $ip $m @ea }
            else { & $exe -NoProfile -File $PSCommandPath $ip $m }
            if ($LASTEXITCODE -eq 0) { $pass++ } else { $failed += $m }
        }
        Write-Host ""
        if ($failed.Count -eq 0) { Write-Host ("  RUN #${round}: ALL $pass tests PASS") -ForegroundColor Green }
        else { $exitCode = 1; Write-Host ("  RUN #${round}: $($failed.Count) FAILED ($($failed -join ', ')), $pass passed") -ForegroundColor Red }
        if ($loop) { Start-Sleep -Seconds 3 }
    } while ($loop)
    exit $exitCode
}

function Invoke-Mdns([string]$ip) {
    Show-Logo
    Write-Host "mdns: query _openknx._tcp on $ip (OpenKNX-specific Bonjour/DNS-SD advertising)" -ForegroundColor Cyan
    $s = New-UdpSocket
    $q = [byte[]](@(0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0) + (New-DnsLabel '_openknx') + (New-DnsLabel '_tcp') + (New-DnsLabel 'local') + @(0x00, 0x00, 0x0C, 0x80, 0x01))
    $dst = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse('224.0.0.251'), 5353)
    $null = $s.SendTo($q, $dst)
    $s.ReceiveTimeout = 2500
    $buf = New-Object byte[] 2048
    $ep = [System.Net.EndPoint]([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
    $txt = @()
    for ($r = 0; $r -lt 8; $r++) {
        try { $n = $s.ReceiveFrom($buf, [ref]$ep) } catch { break }
        if (([System.Net.IPEndPoint]$ep).Address.ToString() -ne $ip) { continue }
        # TXT records are length-prefixed printable key=value strings; the length bytes
        # (small ints) are non-printable and split the runs cleanly.
        $cur = ''
        for ($i = 0; $i -lt $n; $i++) {
            $b = $buf[$i]
            if ($b -ge 32 -and $b -lt 127) { $cur += [char]$b }
            else { if ($cur.Contains('=')) { $txt += $cur }; $cur = '' }
        }
        if ($cur.Contains('=')) { $txt += $cur }
        break
    }
    $s.Close()
    Write-Host ""
    if ($txt.Count -eq 0) {
        Write-Host "  no _openknx mDNS record from $ip." -ForegroundColor Yellow
        Write-Host "  -> non-OpenKNX router or mDNS off. Use 'discover'/'info' (standard KNXnet/IP," -ForegroundColor DarkGray
        Write-Host "     vendor-neutral) - those read name/PA/serial/services on ANY router." -ForegroundColor DarkGray
        exit 0
    }
    foreach ($t in ($txt | Select-Object -Unique)) {
        $kv = $t -split '=', 2
        Write-Host ("  {0,-12} {1}" -f ($kv[0] + ':'), $kv[1]) -ForegroundColor Green
    }
    Write-Host ""
    Write-Host "  MDNS PASS: $(($txt | Select-Object -Unique).Count) TXT record(s) (OpenKNX device)." -ForegroundColor Green
    exit 0
}

function Invoke-Diag([string]$ip) {
    Show-Logo
    Write-Host "diag: router + KNXnet/IP config & diagnostics (device-mgmt M_PropRead) on $ip" -ForegroundColor Cyan
    $ctx = Connect-DevMgmt $ip
    if ($null -eq $ctx) { Write-Host "  CONNECT failed (no free device-mgmt channel? wait/reboot)" -ForegroundColor Red; exit 1 }
    $buf = New-Object byte[] 1024
    $sender = [System.Net.EndPoint]([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
    $ctx.Sock.ReceiveTimeout = 1500
    # OT 11 = KNXnet/IP parameter object, OT 6 = Router object. PIDs from the knx stack.
    $props = @(
        @{ OT = 11; PID = 52; Name = 'Individual addr (PA)'; Fmt = 'pa';     NoE = 1 },
        @{ OT = 11; PID = 57; Name = 'Current IP';           Fmt = 'ip';     NoE = 1 },
        @{ OT = 11; PID = 58; Name = 'Subnet mask';          Fmt = 'ip';     NoE = 1 },
        @{ OT = 11; PID = 59; Name = 'Default gateway';      Fmt = 'ip';     NoE = 1 },
        @{ OT = 11; PID = 64; Name = 'MAC address';          Fmt = 'mac';    NoE = 1 },
        @{ OT = 11; PID = 66; Name = 'Routing multicast';    Fmt = 'ip';     NoE = 1 },
        @{ OT = 11; PID = 53; Name = 'Tunnel addresses';     Fmt = 'palist'; NoE = 15 },
        @{ OT = 11; PID = 72; Name = 'Queue ovfl ->IP';      Fmt = 'u';      NoE = 1 },
        @{ OT = 11; PID = 73; Name = 'Queue ovfl ->KNX';     Fmt = 'u';      NoE = 1 },
        @{ OT = 11; PID = 74; Name = 'Msg sent ->IP';        Fmt = 'u';      NoE = 1 },
        @{ OT = 11; PID = 75; Name = 'Msg sent ->KNX';       Fmt = 'u';      NoE = 1 },
        @{ OT = 6;  PID = 52; Name = 'LC config main';       Fmt = 'hex';    NoE = 1 },
        @{ OT = 6;  PID = 53; Name = 'LC config sub';        Fmt = 'hex';    NoE = 1 },
        @{ OT = 6;  PID = 54; Name = 'LC grp config main';   Fmt = 'hex';    NoE = 1 }
    )
    $seq = 0; $got = 0; $lastOt = -1
    foreach ($p in $props) {
        if ([int]$p.OT -ne $lastOt) {
            $lastOt = [int]$p.OT
            $on = 'Router object (OT 6)'
            if ([int]$p.OT -eq 11) { $on = 'KNXnet/IP parameter object (OT 11)' }
            Write-Host ("  -- $on --") -ForegroundColor DarkCyan
        }
        $noe = [int]$p.NoE
        $cemi = [byte[]]@(0xFC, (([int]$p.OT -shr 8) -band 0xFF), ([int]$p.OT -band 0xFF), 0x01, [byte]([int]$p.PID), [byte]((($noe -shl 4) -band 0xF0)), 0x01)
        $null = $ctx.Sock.SendTo((New-KnxFrame 0x0310 ([byte[]](@(0x04, $ctx.Ch, ($seq -band 0xFF), 0x00) + $cemi))), $ctx.Dst)
        $seq++
        $data = $null
        try {
            for ($t = 0; $t -lt 4; $t++) {
                $rn = $ctx.Sock.ReceiveFrom($buf, [ref]$sender)
                if ($rn -ge 10 -and $buf[2] -eq 0x03 -and $buf[3] -eq 0x10) {
                    $null = $ctx.Sock.SendTo((New-KnxFrame 0x0311 ([byte[]]@(0x04, $buf[7], $buf[8], 0x00))), $ctx.Dst)
                    if ($rn -ge 17 -and $buf[10] -eq 0xFB) {
                        if (([int]$buf[15] -shr 4) -eq 0) { break }   # NoE 0 -> n/a (property not present)
                        $len = $rn - 17
                        $data = New-Object byte[] $len
                        [Array]::Copy($buf, 17, $data, 0, $len)
                        break
                    }
                }
            }
        } catch {}
        $val = 'n/a'; $col = 'DarkGray'
        if ($null -ne $data -and $data.Length -gt 0) {
            $got++; $col = 'Green'
            switch ($p.Fmt) {
                'pa'     { $val = "{0}.{1}.{2}" -f (([int]$data[0] -shr 4) -band 0xF), ([int]$data[0] -band 0xF), [int]$data[1] }
                'ip'     { $val = (($data | ForEach-Object { [int]$_ }) -join '.') }
                'mac'    { $val = (($data | ForEach-Object { '{0:X2}' -f $_ }) -join ':') }
                'u'      { $v = 0; foreach ($b in $data) { $v = ($v -shl 8) -bor $b }; $val = "$v" }
                'hex'    { $val = "0x$(ConvertTo-Hex $data)" }
                'palist' {
                    $list = @()
                    for ($k = 0; $k + 1 -lt $data.Length; $k += 2) {
                        $list += ("{0}.{1}.{2}" -f (([int]$data[$k] -shr 4) -band 0xF), ([int]$data[$k] -band 0xF), [int]$data[$k + 1])
                    }
                    if ($list.Count -gt 0) {
                        $val = ($list -join ', ')
                        if ($list.Count -ge 15) { $val += '  (+more; M_PropRead NoE cap = 15)' }
                    }
                    else { $val = 'none' }
                }
                default  { $val = "0x$(ConvertTo-Hex $data)" }
            }
        }
        Write-Host ("  {0,-22} {1}" -f ($p.Name + ':'), $val) -ForegroundColor $col
    }
    try { $null = $ctx.Sock.SendTo((New-KnxFrame 0x0209 ([byte[]](@($ctx.Ch, 0x00) + $ctx.Hpai))), $ctx.Dst) } catch {}
    $ctx.Sock.Close()
    Write-Host ""
    if ($got -gt 0) { Write-Host "  DIAG PASS: read $got/$($props.Count) properties (n/a = not implemented on this device)." -ForegroundColor Green; exit 0 }
    else { Write-Host "  DIAG FAIL: no properties returned." -ForegroundColor Red; exit 1 }
}

function Invoke-Speed([string]$ip, [int]$count) {
    Show-Logo
    if ($count -le 0) { $count = 50 }
    Write-Host "speed: APDU capability + request/response round-trip benchmark on $ip ($count samples)" -ForegroundColor Cyan
    Write-Host "  closed-loop M_PropRead ping-pong = device KNXnet/IP + cEMI response speed." -ForegroundColor DarkGray
    Write-Host "  NOT the TP forwarding limit (TP1 caps real routing at ~40-50 telegrams/s)." -ForegroundColor DarkGray
    $ctx = Connect-DevMgmt $ip
    if ($null -eq $ctx) { Write-Host "  CONNECT failed (no free device-mgmt channel? wait/reboot)" -ForegroundColor Red; exit 1 }
    $buf = New-Object byte[] 1024
    $sender = [System.Net.EndPoint]([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
    $ctx.Sock.ReceiveTimeout = 2000
    $seq = 0
    # --- APDU capability: max APDU length (router OT 6 PID 58, device OT 0 PID 56) ---
    foreach ($cap in @(@{ OT = 6; PID = 58; N = 'Max APDU (router)' }, @{ OT = 0; PID = 56; N = 'Max APDU (device)' })) {
        $cemi = [byte[]]@(0xFC, 0x00, ([int]$cap.OT -band 0xFF), 0x01, [byte]([int]$cap.PID), 0x10, 0x01)
        $null = $ctx.Sock.SendTo((New-KnxFrame 0x0310 ([byte[]](@(0x04, $ctx.Ch, ($seq -band 0xFF), 0x00) + $cemi))), $ctx.Dst)
        $seq++
        $v = 'n/a'
        try {
            for ($t = 0; $t -lt 4; $t++) {
                $rn = $ctx.Sock.ReceiveFrom($buf, [ref]$sender)
                if ($rn -ge 10 -and $buf[2] -eq 0x03 -and $buf[3] -eq 0x10) {
                    $null = $ctx.Sock.SendTo((New-KnxFrame 0x0311 ([byte[]]@(0x04, $buf[7], $buf[8], 0x00))), $ctx.Dst)
                    if ($rn -ge 18 -and $buf[10] -eq 0xFB -and ([int]$buf[15] -shr 4) -ne 0) {
                        $n = 0; for ($k = 17; $k -lt $rn; $k++) { $n = ($n -shl 8) -bor $buf[$k] }; $v = "$n bytes"
                    }
                    break
                }
            }
        } catch {}
        Write-Host ("  {0,-20} {1}" -f ($cap.N + ':'), $v) -ForegroundColor Green
    }
    # --- round-trip benchmark: closed-loop M_PropRead of PID_OBJECT_TYPE (OT 0 PID 1, always present) ---
    $cemi = [byte[]]@(0xFC, 0x00, 0x00, 0x01, 0x01, 0x10, 0x01)
    $lat = @(); $ok = 0; $sw = [System.Diagnostics.Stopwatch]::new()
    $wall = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $count; $i++) {
        $sw.Restart()
        $null = $ctx.Sock.SendTo((New-KnxFrame 0x0310 ([byte[]](@(0x04, $ctx.Ch, ($seq -band 0xFF), 0x00) + $cemi))), $ctx.Dst)
        $seq++
        try {
            for ($t = 0; $t -lt 4; $t++) {
                $rn = $ctx.Sock.ReceiveFrom($buf, [ref]$sender)
                if ($rn -ge 11 -and $buf[2] -eq 0x03 -and $buf[3] -eq 0x10) {
                    if ($buf[10] -eq 0xFB) { $lat += $sw.Elapsed.TotalMilliseconds; $ok++ }
                    $null = $ctx.Sock.SendTo((New-KnxFrame 0x0311 ([byte[]]@(0x04, $buf[7], $buf[8], 0x00))), $ctx.Dst)
                    break
                }
            }
        } catch {}
    }
    $wall.Stop()
    try { $null = $ctx.Sock.SendTo((New-KnxFrame 0x0209 ([byte[]](@($ctx.Ch, 0x00) + $ctx.Hpai))), $ctx.Dst) } catch {}
    $ctx.Sock.Close()
    Write-Host ""
    if ($ok -gt 0) {
        $min = [math]::Round(($lat | Measure-Object -Minimum).Minimum, 2)
        $max = [math]::Round(($lat | Measure-Object -Maximum).Maximum, 2)
        $avg = [math]::Round(($lat | Measure-Object -Average).Average, 2)
        $rate = 0
        if ($wall.Elapsed.TotalSeconds -gt 0) { $rate = [math]::Round($ok / $wall.Elapsed.TotalSeconds, 1) }
        Write-Host ("  round-trips:   {0}/{1} ok" -f $ok, $count) -ForegroundColor Green
        Write-Host ("  latency (ms):  min {0}  avg {1}  max {2}" -f $min, $avg, $max) -ForegroundColor Green
        Write-Host ("  throughput:    {0} round-trips/s (closed-loop, serialized)" -f $rate) -ForegroundColor Green
        Write-Host ""
        Write-Host "  SPEED PASS." -ForegroundColor Green; exit 0
    }
    else { Write-Host "  SPEED FAIL: no responses (device busy/unreachable?)." -ForegroundColor Red; exit 1 }
}

# ─── prog: connection-oriented "programming-like" handshake to a REAL TP device ──
# ETS starts every download with T_Connect -> A_DeviceDescriptor_Read; that is the
# connection-oriented, per-telegram-L_ACK path the rx-threshold-80 bug broke. This
# reproduces exactly that handshake over a tunnel, READ-ONLY (no memory is written),
# in a loop. PASS = the device's DeviceDescriptor came back = the path is healthy.
function ConvertTo-PaInt([string]$pa) {
    $p = $pa -split '\.'
    if ($p.Count -lt 3) { return -1 }
    return (([int]$p[0] -shl 12) -bor ([int]$p[1] -shl 8) -bor [int]$p[2])
}
function New-Tunneling([byte]$ch, [int]$seq, [byte[]]$cemi) {
    # TUNNELING_REQUEST (0x0420): conn-header 04 <ch> <seq> 00 + cEMI
    return New-KnxFrame 0x0420 ([byte[]](@(0x04, $ch, ($seq -band 0xFF), 0x00) + $cemi))
}
function New-LDataReqCo([int]$dst, [byte[]]$tpdu) {
    # cEMI L_Data.req to an INDIVIDUAL address; src 0.0.0 (router substitutes the tunnel PA).
    # ctrl1 0xBC, ctrl2 0x60 (AT=individual, hops=6). KNX length octet = TPDU octets - 1.
    $len = $tpdu.Length - 1
    return [byte[]](@(0x11, 0x00, 0xBC, 0x60, 0x00, 0x00, (($dst -shr 8) -band 0xFF), ($dst -band 0xFF), ($len -band 0xFF)) + $tpdu)
}
# Drain inbound frames up to $ms ms; auto-ACK every TUNNELING_REQUEST; return its cEMIs.
# Returns EARLY as soon as the awaited frame arrives: $stopMc matches a cEMI message code
# (e.g. 0x2E L_Data.con), $stopApci matches an L_Data.ind APCI (e.g. 0x340 descriptor resp).
function Receive-TunnelCemi($sock, [byte]$ch, [int]$ms, [int]$stopApci = -1, [int]$stopMc = -1) {
    $out = New-Object System.Collections.Generic.List[object]
    $buf = New-Object byte[] 1024
    $sender = [System.Net.EndPoint]([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalMilliseconds -lt $ms) {
        if ($sock.Available -le 0) { Start-Sleep -Milliseconds 2; continue }
        $rn = $sock.ReceiveFrom($buf, [ref]$sender)
        if ($rn -lt 6) { continue }
        $svc = ([int]$buf[2] -shl 8) -bor $buf[3]
        if ($svc -ne 0x0420) { continue }            # only inbound TUNNELING_REQUEST
        $null = $sock.SendTo((New-KnxFrame 0x0421 ([byte[]]@(0x04, $ch, $buf[8], 0x00))), $sender)   # ACK it
        if ($rn -le 10) { continue }
        $c = New-Object byte[] ($rn - 10); [Array]::Copy($buf, 10, $c, 0, $rn - 10); $out.Add($c)
        if ($stopMc -ge 0 -and $c[0] -eq $stopMc) { break }
        if ($stopApci -ge 0 -and $c.Length -ge 11 -and $c[0] -eq 0x29 -and (($c[9] -band 0xC0) -eq 0x40)) {
            $apci = (((([int]$c[9]) -band 0x03) -shl 8) -bor [int]$c[10])
            if (($apci -band 0xFC0) -eq $stopApci) { break }
        }
    }
    return $out
}
function Invoke-Prog([string]$ip, [string]$pa, [int]$count, [int]$seconds, [int]$apduBytes) {
    Show-Logo
    $dst = ConvertTo-PaInt $pa
    if ($dst -lt 0) {
        Write-Host "  prog needs a target device: -Pa x.y.z  (a REAL TP device, e.g. 2.0.100)" -ForegroundColor Red
        Write-Host "  read-only DeviceDescriptor_Read over a tunnel = ETS programming's connect phase." -ForegroundColor DarkGray
        Write-Host "  add -ApduBytes N (1..63) to also A_Memory_Read N bytes/cycle = large-APDU traversal." -ForegroundColor DarkGray
        exit 1
    }
    if ($count -le 0) { $count = 20 }
    if ($apduBytes -gt 63) { $apduBytes = 63 }       # A_Memory_Read byte-count field is 6-bit
    if ($apduBytes -lt 0) { $apduBytes = 0 }
    Write-Host "prog: connection-oriented handshake to $pa over a tunnel (read-only, ETS-like connect phase)" -ForegroundColor Cyan
    if ($apduBytes -gt 0) { Write-Host ("  + A_Memory_Read of {0} bytes/cycle (large-APDU traversal test, read-only)" -f $apduBytes) -ForegroundColor DarkGray }
    $t = Open-Tunnel $ip
    if ($null -eq $t) { Write-Host "  tunnel CONNECT: no response (wait 120s/reboot?)" -ForegroundColor Red; exit 1 }
    if ($t.Status -ne 0) { Write-Host ("  tunnel CONNECT failed status=0x{0:X2} (no free slot?)" -f $t.Status) -ForegroundColor Red; $t.Sock.Close(); exit 1 }
    $sock = $t.Sock; $ch = $t.Ch
    Write-Host ("  tunnel ch=0x{0:X2}  our PA={1}  -> target {2}" -f $ch, $t.Pa, $pa) -ForegroundColor Gray
    $tSeq = 0; $ok = 0; $fail = 0; $lat = @(); $i = 0
    $txB = 0; $rxB = 0; $apduOk = 0; $apduMax = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        while ($true) {
            if ($seconds -gt 0) { if ($sw.Elapsed.TotalSeconds -ge $seconds) { break } }
            elseif ($i -ge $count) { break }
            $i++
            $cyc = [System.Diagnostics.Stopwatch]::StartNew()
            # 1) T_Connect (TPCI 0x80) - return as soon as the L_Data.con (MC 0x2E) of our request is in
            $f = New-LDataReqCo $dst @(0x80); $null = $sock.SendTo((New-Tunneling $ch $tSeq $f), $t.Dst); $txB += $f.Length; $tSeq = ($tSeq + 1) -band 0xFF
            $null = Receive-TunnelCemi $sock $ch 1000 (-1) 0x2E
            # 2) A_DeviceDescriptor_Read(0), transport seq 0 (TPDU 0x43 0x00); stop on response APCI 0x340 -> REAL latency
            $f = New-LDataReqCo $dst @(0x43, 0x00); $null = $sock.SendTo((New-Tunneling $ch $tSeq $f), $t.Dst); $txB += $f.Length; $tSeq = ($tSeq + 1) -band 0xFF
            $resps = Receive-TunnelCemi $sock $ch 3000 0x340 (-1)
            $gotDesc = $false; $devSeq = 0
            foreach ($c in $resps) {
                if ($c[0] -eq 0x29) { $rxB += $c.Length }      # device -> us bytes on the bus
                # cEMI L_Data.ind (MC 0x29): [0]MC [2]ctrl1 [3]ctrl2 [4..5]src [6..7]dst [8]len [9]tpci [10]apci
                if ($c.Length -ge 11 -and $c[0] -eq 0x29 -and (($c[9] -band 0xC0) -eq 0x40)) {
                    $apci = (((([int]$c[9]) -band 0x03) -shl 8) -bor [int]$c[10])
                    if (($apci -band 0xFC0) -eq 0x340) { $gotDesc = $true; $devSeq = (([int]$c[9] -shr 2) -band 0x0F) }
                }
            }
            if ($gotDesc) {
                # T_ACK the descriptor response (TPCI 0xC2 | devSeq<<2)
                $tack = [byte](0xC2 -bor (($devSeq -band 0x0F) -shl 2))
                $f = New-LDataReqCo $dst @($tack); $null = $sock.SendTo((New-Tunneling $ch $tSeq $f), $t.Dst); $txB += $f.Length; $tSeq = ($tSeq + 1) -band 0xFF
                $ok++; $lat += $cyc.Elapsed.TotalMilliseconds
                if ($apduBytes -gt 0) {
                    # A_Memory_Read N bytes @ 0x0000, transport seq 1: TPDU 0x46 <N> 00 00  (read-only)
                    $f = New-LDataReqCo $dst @(0x46, ($apduBytes -band 0x3F), 0x00, 0x00)
                    $null = $sock.SendTo((New-Tunneling $ch $tSeq $f), $t.Dst); $txB += $f.Length; $tSeq = ($tSeq + 1) -band 0xFF
                    $mresps = Receive-TunnelCemi $sock $ch 3000 0x240 (-1)
                    $gotMem = $false; $mSeq2 = 0; $mlen = 0
                    foreach ($c in $mresps) {
                        if ($c[0] -eq 0x29) { $rxB += $c.Length }
                        if ($c.Length -ge 13 -and $c[0] -eq 0x29 -and (($c[9] -band 0xC0) -eq 0x40)) {
                            $apci2 = (((([int]$c[9]) -band 0x03) -shl 8) -bor [int]$c[10])
                            if (($apci2 -band 0xFC0) -eq 0x240) { $gotMem = $true; $mSeq2 = (([int]$c[9] -shr 2) -band 0x0F); $mlen = $c.Length - 13 }
                        }
                    }
                    if ($gotMem) {
                        $tack2 = [byte](0xC2 -bor (($mSeq2 -band 0x0F) -shl 2))
                        $f = New-LDataReqCo $dst @($tack2); $null = $sock.SendTo((New-Tunneling $ch $tSeq $f), $t.Dst); $txB += $f.Length; $tSeq = ($tSeq + 1) -band 0xFF
                        $apduOk++; if ($mlen -gt $apduMax) { $apduMax = $mlen }
                    }
                }
            } else { $fail++ }
            # 3) T_Disconnect (TPCI 0x81) - clean up the connection either way
            $f = New-LDataReqCo $dst @(0x81); $null = $sock.SendTo((New-Tunneling $ch $tSeq $f), $t.Dst); $txB += $f.Length; $tSeq = ($tSeq + 1) -band 0xFF
            $null = Receive-TunnelCemi $sock $ch 150
            if ($i % 10 -eq 0) { Write-Host ("  cycles={0} ok={1} fail={2}" -f $i, $ok, $fail) -ForegroundColor DarkGray }
        }
    }
    finally {
        try { $null = $sock.SendTo((New-KnxFrame 0x0209 ([byte[]](@($ch, 0x00) + $t.Hpai))), $t.Dst) } catch {}
        try { $sock.Close() } catch {}
    }
    $wall = $sw.Elapsed.TotalSeconds
    Write-Host ""
    Write-Host ("  cycles={0}  ok={1}  fail={2}" -f $i, $ok, $fail) -ForegroundColor Cyan
    if ($ok -gt 0) {
        $min = [math]::Round(($lat | Measure-Object -Minimum).Minimum, 1)
        $avg = [math]::Round(($lat | Measure-Object -Average).Average, 1)
        $max = [math]::Round(($lat | Measure-Object -Maximum).Maximum, 1)
        Write-Host ("  connect+descriptor latency (ms): min {0}  avg {1}  max {2}" -f $min, $avg, $max) -ForegroundColor Green
        $hz = 0; if ($wall -gt 0) { $hz = [math]::Round($ok / $wall, 1) }
        Write-Host ("  throughput: {0} handshakes/s (connection-oriented round-trips over the TP bus)" -f $hz) -ForegroundColor Green
        $txBps = 0; $rxBps = 0; if ($wall -gt 0) { $txBps = [math]::Round($txB / $wall, 0); $rxBps = [math]::Round($rxB / $wall, 0) }
        Write-Host ("  bus bytes: sent {0} B ({1} B/s) / received {2} B ({3} B/s)  [cEMI on the bus, rough]" -f $txB, $txBps, $rxB, $rxBps) -ForegroundColor Green
        if ($apduBytes -gt 0) {
            Write-Host ("  APDU read-back: {0}/{1} ok  (max {2} data bytes per single APDU, requested {3})" -f $apduOk, $ok, $apduMax, $apduBytes) -ForegroundColor Green
        }
    }
    if ($ok -gt 0 -and $fail -eq 0) { Write-Host "  => PASS: every connection-oriented handshake completed (programming path healthy)" -ForegroundColor Green; exit 0 }
    elseif ($ok -gt 0) { Write-Host "  => PARTIAL: some handshakes failed - check bus / target online / threshold" -ForegroundColor Yellow; exit 1 }
    else { Write-Host "  => FAIL: no descriptor returned (target offline? or connection-oriented path broken)" -ForegroundColor Red; exit 1 }
}

function Show-Help {
    Show-Logo
    Write-Host "USAGE" -ForegroundColor Yellow
    Write-Host "  ./Test-KnxRouter.ps1 <ip> <command> [-Rate n] [-Seconds n] [-Count n] [-Sub m] [-Ga a/b/c] [-Yes] [-Loop]"
    Write-Host "  (selftest needs no <ip>; omit <ip> on any command to use the default 11.11.0.210)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "TESTS" -ForegroundColor Yellow
    Write-Host ("  {0,-10}{1,-52}" -f "selftest", "offline frame byte-check (no device)")          -NoNewline; Write-Host "SAFE"     -ForegroundColor Green
    Write-Host ("  {0,-10}{1,-52}" -f "health",   "ping + KNXnet/IP DESCRIBE round-trip")          -NoNewline; Write-Host "SAFE"     -ForegroundColor Green
    Write-Host ("  {0,-10}{1,-52}" -f "leak",     "gentle cEMI M_PropRead flood (cEMI leak A/B)")  -NoNewline; Write-Host "SAFE-ISH" -ForegroundColor DarkYellow
    Write-Host ("  {0,-10}{1,-52}" -f "route",    "routing flood -> TP TX queue (tpuart leak path)") -NoNewline; Write-Host "MODERATE" -ForegroundColor DarkYellow
    Write-Host ("  {0,-10}{1,-52}" -f "flood",    "discovery flood: -Sub mdns|search|desc")        -NoNewline; Write-Host "MODERATE" -ForegroundColor DarkYellow
    Write-Host ("  {0,-10}{1,-52}" -f "wreck",    "unlimited flood, can wipe the config")          -NoNewline; Write-Host "DANGER"   -ForegroundColor Red
    Write-Host ("  {0,-10}{1,-52}" -f "soak",     "sustained cEMI load + health probes (leak run)") -NoNewline; Write-Host "SAFE-ISH" -ForegroundColor DarkYellow
    Write-Host ("  {0,-10}{1,-52}" -f "tunnel",   "open tunnels to exhaustion, free, reconnect")   -NoNewline; Write-Host "SAFE"     -ForegroundColor Green
    Write-Host ("  {0,-10}{1,-52}" -f "load",     "multicast routing back-pressure (busy/lost)")   -NoNewline; Write-Host "MODERATE" -ForegroundColor DarkYellow
    Write-Host ("  {0,-10}{1,-52}" -f "discover", "repeated DESCRIBE + DIB parse (name/PA/families)") -NoNewline; Write-Host "SAFE"     -ForegroundColor Green
    Write-Host ("  {0,-10}{1,-52}" -f "robust",   "malformed/unsupported frame barrage")           -NoNewline; Write-Host "SAFE"     -ForegroundColor Green
    Write-Host ("  {0,-10}{1,-52}" -f "info",     "read Device-Object props ETS reads (M_PropRead)") -NoNewline; Write-Host "SAFE"     -ForegroundColor Green
    Write-Host ("  {0,-10}{1,-52}" -f "mdns",     "OpenKNX-only mDNS TXT (configured/version/...)") -NoNewline; Write-Host "SAFE"     -ForegroundColor Green
    Write-Host ("  {0,-10}{1,-52}" -f "diag",     "router + IP config & diagnostics (M_PropRead)") -NoNewline; Write-Host "SAFE"     -ForegroundColor Green
    Write-Host ("  {0,-10}{1,-52}" -f "speed",    "max APDU + round-trip latency/throughput benchmark") -NoNewline; Write-Host "SAFE"     -ForegroundColor Green
    Write-Host ("  {0,-10}{1,-52}" -f "prog",     "ETS-like connect+descriptor (-Pa x.y.z [-ApduBytes N])") -NoNewline; Write-Host "MODERATE" -ForegroundColor DarkYellow
    Write-Host ("  {0,-10}{1,-52}" -f "all",      "SAFE + hardening tests (-Loop; -Pa x.y.z adds prog)") -NoNewline; Write-Host "SAFE"     -ForegroundColor Green
    Write-Host ""
    Write-Host "EXAMPLES" -ForegroundColor Yellow
    Write-Host "  ./Test-KnxRouter.ps1 selftest"
    Write-Host "  ./Test-KnxRouter.ps1 11.11.0.210 health"
    Write-Host "  ./Test-KnxRouter.ps1 11.11.0.210 leak     -Rate 5 -Seconds 600"
    Write-Host "  ./Test-KnxRouter.ps1 11.11.0.210 flood    -Sub search"
    Write-Host "  ./Test-KnxRouter.ps1 11.11.0.210 route    -Ga 31/7/255 -Rate 0"
    Write-Host "  ./Test-KnxRouter.ps1 11.11.0.210 wreck    # can wipe the config"
    Write-Host "  ./Test-KnxRouter.ps1 11.11.0.210 soak     -Seconds 600 -Rate 20"
    Write-Host "  ./Test-KnxRouter.ps1 11.11.0.210 tunnel   -Count 16"
    Write-Host "  ./Test-KnxRouter.ps1 11.11.0.210 load     -Seconds 30 -Ga 1/2/3"
    Write-Host "  ./Test-KnxRouter.ps1 11.11.0.210 discover -Count 5"
    Write-Host "  ./Test-KnxRouter.ps1 11.11.0.210 robust"
    Write-Host "  ./Test-KnxRouter.ps1 11.11.0.210 info"
    Write-Host "  ./Test-KnxRouter.ps1 11.11.0.210 mdns"
    Write-Host "  ./Test-KnxRouter.ps1 11.11.0.210 diag"
    Write-Host "  ./Test-KnxRouter.ps1 11.11.0.210 speed    -Count 100"
    Write-Host "  ./Test-KnxRouter.ps1 11.11.0.210 prog     -Pa 2.0.100 -Count 50               # simulate ETS programming connect"
    Write-Host "  ./Test-KnxRouter.ps1 11.11.0.210 prog     -Pa 2.0.100 -Count 50 -ApduBytes 50  # + large-APDU read-back"
    Write-Host "  ./Test-KnxRouter.ps1 11.11.0.210 all      -Loop                          # SAFE+hardening watchdog"
    Write-Host "  ./Test-KnxRouter.ps1 11.11.0.210 all      -Loop -Pa 2.0.50 -ApduBytes 50  # + connection-oriented prog"
    Write-Host "  ./Test-KnxRouter.ps1 health              # IP omitted -> default 11.11.0.210" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "TIP: leak check -> run 'soak', then type 'mem' on the device console:" -ForegroundColor DarkGray
    Write-Host "     'Heap: free / min / largest' must stay FLAT. Dropping = leak." -ForegroundColor DarkGray
    Write-Host "     (periodic auto-log 'HEAP free=' only with the OPENKNX_DEBUG_HEAP_LOG build flag.)" -ForegroundColor DarkGray
    Write-Host ""
}

# ─── Dispatch ───────────────────────────────────────────────────────────────────
switch ($Test.ToLower()) {
    'selftest' { Invoke-SelfTest }
    'health'   { Invoke-Health $Ip }
    'leak'     { Invoke-PropRead $Ip $Rate $true $Seconds }
    'route'    { Invoke-Route $Ip $Ga $Rate $Seconds }
    'flood'    { Invoke-Flood $Ip $Sub $Seconds }
    'wreck'    { Invoke-Wreck $Ip $Seconds }
    'soak'     { Invoke-Soak $Ip $Seconds $Rate }
    'tunnel'   { Invoke-Tunnel $Ip $Count }
    'load'     { Invoke-Load $Ip $Seconds $Ga }
    'discover' { Invoke-Discover $Ip $Count }
    'robust'   { Invoke-Robust $Ip }
    'info'     { Invoke-Info $Ip }
    'mdns'     { Invoke-Mdns $Ip }
    'diag'     { Invoke-Diag $Ip }
    'speed'    { Invoke-Speed $Ip $Count }
    'prog'     { Invoke-Prog $Ip $Pa $Count $Seconds $ApduBytes }
    'program'  { Invoke-Prog $Ip $Pa $Count $Seconds $ApduBytes }
    'all'      { Invoke-Suite $Ip ([bool]$Loop) $Pa $ApduBytes }
    'suite'    { Invoke-Suite $Ip ([bool]$Loop) $Pa $ApduBytes }
    default    { Show-Help }
}
