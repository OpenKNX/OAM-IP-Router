#!/usr/bin/env pwsh
# Open ■
# ┬────┴  Test-Soak
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/legacy/Test-Soak.ps1
# wiki.openknx.de - forum.openknx.de

<#
.SYNOPSIS
    Runs every IP-Interface test, optionally in an endless loop, so it can be left running for hours: a
    tunnel ramp, a large-data stress burst, the malformed-frame fuzz bombardment, a HW busmonitor fed with
    REAL bus traffic from a 2nd interface, a ~100% TP bus saturation, a rich all-flags/all-lengths telegram
    matrix, and (periodically) a dead-connection test that proves the 120 s KNXnet/IP timeout reaper. Each
    cycle also reads 'bcu stat' over serial and re-checks every device's advertised discovery identity.

    Run it BARE ( pwsh scripts/Test/Test-Soak.ps1 ) for an interactive wizard: it discovers all KNXnet/IP
    devices, lets you pick the TARGET and a traffic SOURCE (or none), choose which tests to run, a serial
    port, loop count and logging. Or pass everything as parameters for a scripted, non-interactive run.

    Watch the device console in parallel: it must never reboot, the free memory must stay flat, and
    'bcu stat' must stay Connected with 0 resets / 0 errors.

.PARAMETER Ip         Interface under test. If omitted, the interactive wizard runs.  e.g. 11.11.0.126
.PARAMETER TrafficIp  2nd interface that injects real bus traffic (feeds the busmon). e.g. 11.11.0.210
.PARAMETER Cycles     Number of loop cycles (0 = forever, default).
.PARAMETER Tests      Scripted test selection, e.g. "all" or "A,B,E,G". Default: all.
.PARAMETER Serial     Device console port for 'bcu stat'.                e.g. /dev/cu.usbmodem3101 (macOS) or COM5 (Windows)
.PARAMETER LogDir     Directory for run logs (default: logs).
.PARAMETER Log        Force a log file even in endless mode (off by default there).
.PARAMETER Help       Show this help.

.EXAMPLE
    ./Test-Soak.ps1
        Interactive wizard: discover devices, pick target/source/tests, then run.

.EXAMPLE
    ./Test-Soak.ps1 -Ip 11.11.0.126 -TrafficIp 11.11.0.210 -Serial /dev/cu.usbmodem3101 -Cycles 3
        Scripted: 3 cycles, real traffic + busmon + 100% load, bcu stat each cycle.

.NOTES
    AUTHOR : Erkan Çolak
#>
[CmdletBinding()]
param(
    [string]$Ip = "",
    [string]$TrafficIp = "",
    [int]$Cycles = 0,
    [string]$Tests = "",
    [string]$LogDir = "logs",
    [string]$Serial = "",
    [switch]$Log,
    [switch]$Help
)

# The serial helpers live in their own module. This script called Get-KnxSerialPorts without
# ever importing anything, which only worked when some other script had loaded the library
# into the same session first - and failed by itself.
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'lib/KnxSerial.psm1') -Force

# The logo lives in a dot-sourced script, sourced at SCRIPT scope: Invoke-Wizard and the
# non-interactive path both call Write-KnxLogo.
. (Join-Path $PSScriptRoot '../lib/KnxLogo.ps1')

$ErrorActionPreference = 'Continue'

if ($Help) {
    Write-Host @"

  Test-Soak — robustness runner for the OpenKNX IP-Interface (interactive or scripted).

  INTERACTIVE
    ./Test-Soak.ps1                 # discovers devices, asks target/source/tests/serial/loop/log

  SCRIPTED
    ./Test-Soak.ps1 -Ip <ip> [-TrafficIp <ip>] [-Tests A,B,E] [-Serial <port>] [-Cycles N] [-Log]

  TESTS (letters for -Tests)
    A tunnel ramp 1..16          B large-data stress          C fuzz bombardment
    D busmon + real traffic*     E ~100% bus saturation       G rich telegram matrix (all flags/lengths)
    F dead-connection 120s reaper (every 4th cycle)           * needs a traffic SOURCE
    Health (bcu stat) + discovery run every cycle regardless.

  PARAMETERS
    -Ip / -TrafficIp  target / traffic-source interface (source must differ from target)
    -Cycles     loop count, 0 = forever (default)
    -Serial     device console port -> 'bcu stat' each cycle
    -LogDir     log directory (default: logs)
    -Log        force a log file even in endless mode (off by default there -- it would grow forever)

  LOGGING
    A finite run (-Cycles N) always writes logs/soak_<timestamp>.log (console + file).
    An endless run writes NO file unless -Log is given.
"@ -ForegroundColor Cyan
    return
}

$col = @{ h = 'Green'; p = 'Cyan'; ok = 'Gray'; warn = 'Yellow' }

# ── base helpers (needed by discovery, wizard and the test phases) ──
function New-KnxFrame([int]$svc, [byte[]]$body) {
    $len = 6 + $body.Length
    return [byte[]](@(0x06, 0x10, (($svc -shr 8) -band 0xFF), ($svc -band 0xFF), (($len -shr 8) -band 0xFF), ($len -band 0xFF)) + $body)
}
function New-Hpai([byte[]]$ipB, [int]$port) { return [byte[]](@(0x08, 0x01) + $ipB + @((($port -shr 8) -band 0xFF), ($port -band 0xFF))) }
function New-UdpSocket { return New-Object System.Net.Sockets.Socket([System.Net.Sockets.AddressFamily]::InterNetwork, [System.Net.Sockets.SocketType]::Dgram, [System.Net.Sockets.ProtocolType]::Udp) }
function Get-LocalIpBytes([string]$dst) { $u = New-Object System.Net.Sockets.UdpClient; try { $u.Connect($dst, 3671); return $u.Client.LocalEndPoint.Address.GetAddressBytes() } finally { $u.Close() } }
$AnyMk = { [System.Net.EndPoint]([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)) }

# Multicast SEARCH -> every KNXnet/IP device on the net with its advertised identity (PA, progmode, name).
# This is exactly the source ETS's connection list uses, so it catches a device advertising a wrong/stale
# PA or a stuck programming mode under load. Returns a list of @{Ip;Pa;Raw;Prog;Name}.
function Get-AllDibs([int]$waitMs = 2500, [byte[]]$localHint = $null) {
    $res = @()
    try {
        $me = if ($localHint) { $localHint } else { Get-LocalIpBytes "224.0.23.12" }
        $s = New-UdpSocket; $s.SetSocketOption("Socket", "ReuseAddress", $true)
        $s.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
        $mp = ([System.Net.IPEndPoint]$s.LocalEndPoint).Port; $h = New-Hpai $me $mp
        $mc = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse("224.0.23.12"), 3671)
        $searchFrame = New-KnxFrame 0x0201 $h
        $null = $s.SendTo($searchFrame, $mc)                             # SEARCH_REQUEST -> multicast
        $s.ReceiveTimeout = 400; $buf = New-Object byte[] 512
        $deadline = [datetime]::Now.AddMilliseconds($waitMs); $seen = @{}; $resend = [datetime]::Now.AddMilliseconds(700)
        while ([datetime]::Now -lt $deadline) {
            if ([datetime]::Now -gt $resend) { try { $null = $s.SendTo($searchFrame, $mc) } catch {}; $resend = [datetime]::Now.AddMilliseconds(99999) }   # one resend for stragglers (e.g. the just-hammered DUT)
            $from = & $AnyMk
            try { $null = $s.ReceiveFrom($buf, [ref]$from) } catch { continue }
            if ((([int]$buf[2] -shl 8) -bor $buf[3]) -ne 0x0202) { continue }   # SEARCH_RESPONSE
            $src = ([System.Net.IPEndPoint]$from).Address.ToString()
            if ($seen.ContainsKey($src)) { continue }; $seen[$src] = $true
            $o = 14                                                       # header(6) + control HPAI(8) -> device-info DIB
            if ($buf[$o + 1] -ne 0x01) { continue }
            $pa = ([int]$buf[$o + 4] -shl 8) -bor $buf[$o + 5]
            $res += @{
                Ip   = $src
                Pa   = "{0}.{1}.{2}" -f ($pa -shr 12), (($pa -shr 8) -band 0x0F), ($pa -band 0xFF)
                Raw  = $pa
                Prog = ($buf[$o + 3] -band 0x01)
                Name = ([System.Text.Encoding]::ASCII.GetString($buf, $o + 24, 30).TrimEnd([char]0))
            }
        }
        $s.Close()
    } catch {}
    return $res
}

# ── which tests are enabled (all by default; wizard or -Tests narrows it) ──
$enabled = @{ A = $true; B = $true; C = $true; D = $true; E = $true; F = $true; G = $true; J = $true; K = $true; L = $true; M = $true }
function Set-EnabledFromList([string]$spec) {
    if ($spec -match '^(?i)\s*all\s*$' -or [string]::IsNullOrWhiteSpace($spec)) { return }
    foreach ($k in @('A', 'B', 'C', 'D', 'E', 'F', 'G', 'J', 'K', 'L', 'M')) { $script:enabled[$k] = $false }
    foreach ($k in ($spec -split '[,\s]+')) { $u = $k.ToUpper(); if ($script:enabled.ContainsKey($u)) { $script:enabled[$u] = $true } }
}

# ── interactive wizard (bare launch): discover -> pick target/source/tests/serial/loop/log ──
function Invoke-Wizard {
    Write-KnxLogo -Title 'Test-Soak'
    Write-Host "  interactive setup" -ForegroundColor $col.h
    Write-Host "  Discovering KNXnet/IP devices (multicast SEARCH)..." -ForegroundColor $col.ok
    $devs = @(Get-AllDibs 3000 | Sort-Object { $_.Ip })
    if ($devs.Count -eq 0) {
        Write-Host "  No devices found. Enter the target IP manually." -ForegroundColor $col.warn
        $script:Ip = (Read-Host "  TARGET interface IP").Trim(); return
    }
    Write-Host ""
    Write-Host "  Devices found:" -ForegroundColor $col.p
    for ($i = 0; $i -lt $devs.Count; $i++) {
        $d = $devs[$i]; $pm = if ($d.Prog) { ' [PROGMODE]' } else { '' }
        Write-Host ("    {0,2}) {1,-14} PA={2,-10} {3}{4}" -f ($i + 1), $d.Ip, $d.Pa, $d.Name, $pm)
    }
    # TARGET
    $sel = (Read-Host "`n  TARGET interface under test (number or IP)").Trim()
    if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $devs.Count) { $script:Ip = $devs[[int]$sel - 1].Ip } else { $script:Ip = $sel }
    # SOURCE (traffic generator for the busmon test)
    Write-Host "`n  SOURCE for real bus traffic (a DIFFERENT interface/router generates it, feeds the busmon)." -ForegroundColor $col.p
    Write-Host "  0 = none -> tests that need external traffic (busmon) are skipped." -ForegroundColor $col.ok
    $sel = (Read-Host "  SOURCE (number, or 0 = none)").Trim()
    if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $devs.Count) { $script:TrafficIp = $devs[[int]$sel - 1].Ip }
    elseif ($sel -eq '' -or $sel -eq '0') { $script:TrafficIp = '' } else { $script:TrafficIp = $sel }
    if ($script:TrafficIp -eq $script:Ip -and $script:TrafficIp) { Write-Host "  (a device can't feed its own busmon -> source cleared)" -ForegroundColor $col.warn; $script:TrafficIp = '' }
    # TESTS
    Write-Host "`n  Tests to run:" -ForegroundColor $col.p
    $menu = @(
        @{ K = 'A'; T = 'tunnel ramp 1..16' },
        @{ K = 'B'; T = 'large-data stress (extended frames)' },
        @{ K = 'C'; T = 'fuzz bombardment (malformed frames)' },
        @{ K = 'D'; T = 'busmon + real traffic          (needs a SOURCE)' },
        @{ K = 'E'; T = '~100% bus saturation' },
        @{ K = 'J'; T = 'overload flood  (fire-and-forget >100% -> forces drops)' },
        @{ K = 'M'; T = 'relentless connect-churn + data jet (zero idle)' },
        @{ K = 'G'; T = 'rich telegram matrix (all flags/prios/lengths/DPTs)' },
        @{ K = 'K'; T = 'full KNX APCI catalog (every telegram type + security/mgmt)' },
        @{ K = 'L'; T = 'transport layer (T_Connect/numbered/T_ACK/T_Disconnect)' },
        @{ K = 'F'; T = 'dead-connection 120s reaper (every 4th cycle)' }
    )
    for ($i = 0; $i -lt $menu.Count; $i++) { Write-Host ("    {0,2}) {1}" -f ($i + 1), $menu[$i].T) }
    $sel = (Read-Host "  Select (Enter or 'all' = everything, or e.g. 1,2,5)").Trim()
    if ($sel -and $sel -notmatch '^(?i)(all|a|\*)$') {                    # 'all' / 'a' / '*' / empty -> keep everything
        foreach ($m in $menu) { $script:enabled[$m.K] = $false }
        foreach ($n in ($sel -split '[,\s]+')) { if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $menu.Count) { $script:enabled[$menu[[int]$n - 1].K] = $true } }
        if (-not ($menu.K | Where-Object { $script:enabled[$_] })) { Write-Host "  (nothing valid selected -> enabling all)" -ForegroundColor $col.warn; foreach ($m in $menu) { $script:enabled[$m.K] = $true } }
    }
    # SERIAL
    Write-Host "`n  Serial console (reads 'bcu stat' each cycle):" -ForegroundColor $col.p
    # Portable: /dev globs only exist on macOS/Linux, on Windows the ports are COMn.
    $script:Serial = Select-KnxSerialDevice -Probe -Optional
    # LOOP + LOG
    Write-Host ""
    $sel = (Read-Host "  Cycles (Enter = 0 = forever)").Trim(); if ($sel -match '^\d+$') { $script:Cycles = [int]$sel }
    $sel = (Read-Host "  Write a log file? (y/N)").Trim(); if ($sel -match '^(?i)(y|yes|j|ja)$') { $script:Log = $true }
}

if (-not $Ip -and -not $Help) { Invoke-Wizard } else { Set-EnabledFromList $Tests }
if (-not $Ip) { Write-Host "  no target selected -- nothing to do." -ForegroundColor $col.warn; return }
if (-not $TrafficIp) { $enabled.D = $false }   # busmon test needs an external traffic source

# ── file logging (each run -> its own timestamped log + console) ──
# Endless loop (Cycles 0) would grow one file without bound, so logging is OFF there unless -Log forces it.
$doLog = ($Cycles -gt 0) -or $Log
$logPath = $null
if ($doLog) {
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $logPath = Join-Path $LogDir ("soak_{0}.log" -f ([datetime]::Now.ToString('yyyyMMdd_HHmmss')))
    try { Start-Transcript -Path $logPath | Out-Null } catch {}
}

# ── optional serial link to the device console (bcu stat watch) ──
$serialPort = $null
if ($Serial) {
    try {
        Add-Type -AssemblyName System.IO.Ports -ErrorAction SilentlyContinue
        $serialPort = New-Object System.IO.Ports.SerialPort($Serial, 115200)
        $serialPort.ReadTimeout = 400; $serialPort.NewLine = "`r`n"
        $serialPort.DtrEnable = $true; $serialPort.RtsEnable = $true     # RP2040 USB-CDC needs DTR to talk
        $serialPort.Open(); Start-Sleep -Milliseconds 300
    } catch { Write-Host "  (serial $Serial not available: $($_.Exception.Message))" -ForegroundColor Yellow; $serialPort = $null }
}
# Strip ANSI escapes + the per-character command echo the OpenKNX console emits.
function Clear-Ansi([string]$s) { return ($s -replace "\x1b\[[0-9;]*[A-Za-z]", "" -replace "\x1b\[2K", "") }
# Request 'bcu stat' over serial and print the statistics table. The console spews async tunnel-event
# lines under load, so we flush first, retry, keep only stat-relevant lines, strip echo/timestamp and
# dedupe. Red only when a reset/error COUNT is non-zero (not a mere header word).
function Show-Health([int]$cycle) {
    if ($null -eq $serialPort) { return }
    Write-Host "  [H] device health (bcu stat):" -ForegroundColor Magenta
    Start-Sleep -Milliseconds 500   # let the console catch up after a heavy blast so the stat reply is not missed
    $stat = @()
    for ($try = 0; $try -lt 4 -and $stat.Count -eq 0; $try++) {
        try { $serialPort.DiscardInBuffer() } catch {}
        Start-Sleep -Milliseconds 250; try { [void]$serialPort.ReadExisting() } catch {}   # drain async spam
        $raw = ''
        try {
            $serialPort.Write("bcu stat`r`n")
            $deadline = [datetime]::Now.AddMilliseconds(1500)
            while ([datetime]::Now -lt $deadline) { try { $raw += $serialPort.ReadExisting() } catch {}; Start-Sleep -Milliseconds 30 }
        } catch {}
        $lines = ($raw -split "`r?`n") | ForEach-Object { (Clear-Ansi $_).Trim() } | Where-Object { $_.Length -gt 0 }
        $stat = @($lines | Where-Object { $_ -match '(?i)state\s*:|baud|tx frames|rx frames|discard|resets|errors|connected|statistics' })
    }
    if ($stat.Count -eq 0) { Write-Host "      (no stat reply -- console busy)" -ForegroundColor Yellow; return }
    $seen = @{}
    foreach ($l in $stat) {
        $txt = ($l -replace '^\$\s*', '' -replace '^bcu stat\s*', '' -replace '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d:\s*', '' -replace '^\d+d \d\d:\d\d:\d\d:\s*', '').Trim()
        if ($txt.Length -eq 0 -or $seen.ContainsKey($txt)) { continue }       # strip echo/timestamp, dedupe double dumps
        $seen[$txt] = $true
        $bad = $txt -match '(?i)\b(reboot|crash|watchdog|panic)\b|reset\w*\s*:?\s*[1-9]|error\w*\s*:?\s*[1-9]'
        Write-Host ("      " + $txt) -ForegroundColor $(if ($bad) { 'Red' } else { 'DarkGray' })
    }
}

# ── device/socket context (target now known) ──
$MeB = Get-LocalIpBytes $Ip
$Dst = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($Ip), 3671)

# Open a connection to $ep (default $Dst). $layer 0x02 data / 0x80 busmon. Returns @{Sock;Ch;Hpai;Dst;Seq} or $null.
function Open-Conn([byte]$layer, $ep, [byte[]]$ipForHpai, [int]$timeoutMs = 1500) {
    if ($null -eq $ep) { $ep = $Dst }
    if ($null -eq $ipForHpai) { $ipForHpai = $MeB }
    $s = New-UdpSocket; $s.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
    $mp = ([System.Net.IPEndPoint]$s.LocalEndPoint).Port; $h = New-Hpai $ipForHpai $mp
    $null = $s.SendTo((New-KnxFrame 0x0205 ([byte[]]($h + $h + @(0x04, 0x04, $layer, 0x00)))), $ep)
    $s.ReceiveTimeout = $timeoutMs; $buf = New-Object byte[] 1024; $from = & $AnyMk
    try { $rn = $s.ReceiveFrom($buf, [ref]$from) } catch { $s.Close(); return $null }
    if ($rn -lt 8 -or ((([int]$buf[2] -shl 8) -bor $buf[3]) -ne 0x0206) -or $buf[7] -ne 0) { $s.Close(); return $null }
    return @{ Sock = $s; Ch = $buf[6]; Hpai = $h; Dst = $ep; Seq = 0 }
}
function Close-Conn($t) { if ($t) { try { $null = $t.Sock.SendTo((New-KnxFrame 0x0209 ([byte[]](@([byte]$t.Ch, 0x00) + $t.Hpai))), $t.Dst) } catch {}; try { $t.Sock.Close() } catch {} } }

# Send one group write of $size payload bytes (size<=1 -> 1-bit). Returns bytes on the wire.
function Send-Gw($t, [int]$ga, [int]$val, [int]$size) {
    if ($size -le 1) { $npdu = @(0x00, (0x80 -bor ($val -band 0x3F))) }
    else { if ($size -gt 240) { $size = 240 }; $d = New-Object byte[] $size; for ($j = 0; $j -lt $size; $j++) { $d[$j] = [byte](($val + $j) -band 0xFF) }; $npdu = @(0x00, 0x80) + $d }
    $len = $npdu.Length - 1
    $cemi = [byte[]](@(0x11, 0x00, 0xBC, 0xE0, 0x00, 0x00, (($ga -shr 8) -band 0xFF), ($ga -band 0xFF), ($len -band 0xFF)) + $npdu)
    $f = New-KnxFrame 0x0420 ([byte[]](@(0x04, [byte]$t.Ch, [byte]($t.Seq -band 0xFF), 0x00) + $cemi))
    $null = $t.Sock.SendTo($f, $t.Dst); $t.Seq = ($t.Seq + 1) -band 0xFF
    return $f.Length
}
# Drain inbound TUNNELLING_REQUESTs, ACK each, return count.
function Drain($t) {
    $n = 0; $buf = New-Object byte[] 1024
    while ($t.Sock.Available -gt 0) { $from = & $AnyMk; $rn = $t.Sock.ReceiveFrom($buf, [ref]$from); if ($rn -ge 10 -and $buf[3] -eq 0x20) { $null = $t.Sock.SendTo((New-KnxFrame 0x0421 ([byte[]]@(0x04, $buf[7], $buf[8], 0x00))), $t.Dst); $n++ } }
    return $n
}
# Wait (briefly) for the TUNNELLING_ACK of the last send -> window-1 pacing = real bus rate.
function Wait-Ack($t, [int]$ms = 60) {
    $t.Sock.ReceiveTimeout = $ms; $buf = New-Object byte[] 64; $from = & $AnyMk
    try { $rn = $t.Sock.ReceiveFrom($buf, [ref]$from); if ($rn -ge 6 -and $buf[3] -eq 0x21) { return $true } } catch {}
    return $false
}
function Open-Retry([byte]$layer, $ep, [byte[]]$ipb, [int]$tries = 5) {
    for ($i = 0; $i -lt $tries; $i++) { $c = Open-Conn $layer $ep $ipb; if ($c) { return $c }; Start-Sleep -Milliseconds 250 }
    return $null
}
# Rich telegram covering everything the ETS group monitor / busmonitor shows: service (Read/Write/Response),
# priority (0 system .. 3 low), hop count 0-7, DPT payload size (1-bit embedded .. 240-byte extended), plus
# optional repeated-frame flag and destination type (1 = group, 0 = individual; ga 0 = broadcast).
function Send-Rich($t, [int]$ga, [string]$svc, [int]$prio, [int]$hop, [byte[]]$data, [int]$val, [int]$destType = 1, [bool]$repeat = $false) {
    $ctrl1 = 0xB0 -bor (($prio -band 0x03) -shl 2)      # standard frame, no-repeat, priority bits
    if ($repeat) { $ctrl1 = $ctrl1 -band 0xDF }         # clear bit5 -> "repeated frame" (monitors show it)
    $ctrl2 = (($destType -band 0x01) -shl 7) -bor (($hop -band 0x07) -shl 4)   # dest type (group/individual) + hop count
    switch ($svc) {
        'read'     { $tpdu = @(0x00, 0x00) }
        'response' { if ($data.Count -eq 0) { $tpdu = @(0x00, (0x40 -bor ($val -band 0x3F))) } else { $tpdu = @(0x00, 0x40) + $data } }
        default    { if ($data.Count -eq 0) { $tpdu = @(0x00, (0x80 -bor ($val -band 0x3F))) } else { $tpdu = @(0x00, 0x80) + $data } }
    }
    $len = $tpdu.Length - 1
    $cemi = [byte[]](@(0x11, 0x00, $ctrl1, $ctrl2, 0x00, 0x00, (($ga -shr 8) -band 0xFF), ($ga -band 0xFF), ($len -band 0xFF)) + $tpdu)
    $null = $t.Sock.SendTo((New-KnxFrame 0x0420 ([byte[]](@(0x04, [byte]$t.Ch, [byte]($t.Seq -band 0xFF), 0x00) + $cemi))), $t.Dst)
    $t.Seq = ($t.Seq + 1) -band 0xFF
}
# Send an arbitrary application-layer service (10-bit APCI) with a payload, to a group/individual/broadcast
# address. TPCI = 0 (unnumbered) so the raw frame is what the busmonitor shows and ETS decodes the APCI.
function Send-Apci($t, [int]$addr, [int]$apci, [int]$destType, [byte[]]$data, [int]$prio, [int]$hop) {
    $ctrl1 = 0xB0 -bor (($prio -band 0x03) -shl 2)
    $ctrl2 = (($destType -band 0x01) -shl 7) -bor (($hop -band 0x07) -shl 4)
    $tpdu = @((($apci -shr 8) -band 0x03), ($apci -band 0xFF)) + $data     # TPDU[0]=TPCI|APCIhi, TPDU[1]=APCIlo
    $len = $tpdu.Length - 1
    $cemi = [byte[]](@(0x11, 0x00, $ctrl1, $ctrl2, 0x00, 0x00, (($addr -shr 8) -band 0xFF), ($addr -band 0xFF), ($len -band 0xFF)) + $tpdu)
    $null = $t.Sock.SendTo((New-KnxFrame 0x0420 ([byte[]](@(0x04, [byte]$t.Ch, [byte]($t.Seq -band 0xFF), 0x00) + $cemi))), $t.Dst)
    $t.Seq = ($t.Seq + 1) -band 0xFF
}
# Send a raw transport-layer PDU (the whole TPDU incl. the TPCI byte). Used for T_Connect / numbered
# T_Data_Connected / T_ACK / T_Disconnect sequences that a plain group write never produces.
function Send-Tpdu($t, [int]$addr, [int]$destType, [byte[]]$tpdu, [int]$prio, [int]$hop) {
    $ctrl1 = 0xB0 -bor (($prio -band 0x03) -shl 2)
    $ctrl2 = (($destType -band 0x01) -shl 7) -bor (($hop -band 0x07) -shl 4)
    $len = $tpdu.Length - 1
    $cemi = [byte[]](@(0x11, 0x00, $ctrl1, $ctrl2, 0x00, 0x00, (($addr -shr 8) -band 0xFF), ($addr -band 0xFF), ($len -band 0xFF)) + $tpdu)
    $null = $t.Sock.SendTo((New-KnxFrame 0x0420 ([byte[]](@(0x04, [byte]$t.Ch, [byte]($t.Seq -band 0xFF), 0x00) + $cemi))), $t.Dst)
    $t.Seq = ($t.Seq + 1) -band 0xFF
}
# Every application service that exists in the KNX world. Group services -> a test GA; broadcast services
# -> 0/0/0; all point-to-point management services -> a DUMMY PA (15.15.254) so no real device is touched
# (Memory/Property writes, Restart, etc. reach nobody) yet each telegram type still shows in the monitors.
$APCI = @(
    @{ N = 'GroupValueRead'; A = 0x000; G = $true; D = @() },
    @{ N = 'GroupValueResponse'; A = 0x040; G = $true; D = @(0x01) },
    @{ N = 'GroupValueWrite'; A = 0x080; G = $true; D = @(0x01) },
    @{ N = 'IndAddrWrite'; A = 0x0C0; BC = $true; D = @(0xFF, 0xFE) },
    @{ N = 'IndAddrRead'; A = 0x100; BC = $true; D = @() },
    @{ N = 'IndAddrResponse'; A = 0x140; BC = $true; D = @() },
    @{ N = 'ADCRead'; A = 0x180; D = @(0x01, 0x08) },
    @{ N = 'ADCResponse'; A = 0x1C0; D = @(0x01, 0x08, 0x00, 0x00) },
    @{ N = 'MemoryRead'; A = 0x200; D = @(0x03, 0x00, 0x60) },
    @{ N = 'MemoryResponse'; A = 0x240; D = @(0x03, 0x00, 0x60, 0x00, 0x00, 0x00) },
    @{ N = 'MemoryWrite'; A = 0x280; D = @(0x03, 0x00, 0x60, 0x11, 0x22, 0x33) },
    @{ N = 'DeviceDescriptorRead'; A = 0x300; D = @(0x00) },
    @{ N = 'DeviceDescriptorResponse'; A = 0x340; D = @(0x00, 0x07, 0xB0) },
    @{ N = 'Restart'; A = 0x380; D = @() },
    @{ N = 'PropValueRead'; A = 0x3D5; D = @(0x00, 0x38, 0x01, 0x10) },
    @{ N = 'PropValueResponse'; A = 0x3D6; D = @(0x00, 0x38, 0x01, 0x10, 0x00) },
    @{ N = 'PropValueWrite'; A = 0x3D7; D = @(0x00, 0x38, 0x01, 0x10, 0x00) },
    @{ N = 'PropDescRead'; A = 0x3D8; D = @(0x00, 0x38, 0x00) },
    @{ N = 'PropDescResponse'; A = 0x3D9; D = @(0x00, 0x38, 0x00, 0x00, 0x00, 0x00, 0x00) },
    # management + broadcast services
    @{ N = 'IndAddrSerialNumRead'; A = 0x3DC; BC = $true; D = @(0x00, 0xFA, 0x13, 0x2F, 0x85, 0x31) },
    @{ N = 'IndAddrSerialNumResponse'; A = 0x3DD; BC = $true; D = @(0x00, 0xFA, 0x13, 0x2F, 0x85, 0x31, 0x0B, 0x0B, 0x00, 0x00) },
    @{ N = 'IndAddrSerialNumWrite'; A = 0x3DE; BC = $true; D = @(0x00, 0xFA, 0x13, 0x2F, 0x85, 0x31, 0xFF, 0xFE, 0x00, 0x00, 0x00, 0x00) },
    @{ N = 'DomainAddrWrite'; A = 0x3E0; BC = $true; D = @(0x12, 0x34) },
    @{ N = 'DomainAddrRead'; A = 0x3E1; BC = $true; D = @() },
    @{ N = 'DomainAddrResponse'; A = 0x3E2; BC = $true; D = @(0x12, 0x34) },
    @{ N = 'DomainAddrSelectiveRead'; A = 0x3E3; BC = $true; D = @(0x00, 0x12, 0x34, 0x11, 0x11, 0x00) },
    @{ N = 'NetworkParamRead'; A = 0x3DA; BC = $true; D = @(0x00, 0x38, 0x0C) },
    @{ N = 'NetworkParamWrite'; A = 0x3E4; BC = $true; D = @(0x00, 0x38, 0x0C, 0x01) },
    @{ N = 'SystemNetworkParamRead'; A = 0x1C8; BC = $true; D = @(0x00, 0x00, 0x38, 0x0C) },
    # point-to-point management (dummy PA -> nobody reacts) incl. security-relevant services
    @{ N = 'UserMemoryRead'; A = 0x2C0; D = @(0x10, 0x00, 0x00, 0x60) },
    @{ N = 'UserMemoryWrite'; A = 0x2C2; D = @(0x10, 0x00, 0x00, 0x60, 0x11) },
    @{ N = 'UserManufacturerInfoRead'; A = 0x2C5; D = @() },
    @{ N = 'FunctionPropertyCommand'; A = 0x3E7; D = @(0x00, 0x38, 0x01, 0x01) },
    @{ N = 'FunctionPropertyStateRead'; A = 0x3E8; D = @(0x00, 0x38, 0x01) },
    @{ N = 'Authorize'; A = 0x3D1; D = @(0x00, 0xFF, 0xFF, 0xFF, 0xFF) },
    @{ N = 'AuthorizeResponse'; A = 0x3D2; D = @(0x00) },
    @{ N = 'KeyWrite'; A = 0x3D3; D = @(0x00, 0xAA, 0xBB, 0xCC, 0xDD) },
    @{ N = 'KeyResponse'; A = 0x3D4; D = @(0x00) },
    @{ N = 'SecureService'; A = 0x3F1; D = @(0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0xAA, 0xBB, 0xCC, 0xDD) }
)

# ── run ──
$active = (@('A', 'B', 'C', 'D', 'E', 'J', 'M', 'G', 'K', 'L', 'F') | Where-Object { $enabled[$_] }) -join ','
Write-KnxLogo -Title 'Test-Soak'
Write-Host ("  {0} (client {1}){2}" -f $Ip, ($MeB -join '.'), $(if ($TrafficIp) { " · traffic via $TrafficIp" } else { " · no traffic source" })) -ForegroundColor $col.h
Write-Host ("  tests: {0}   cycles: {1}   serial: {2}   log: {3}" -f $active, $(if ($Cycles -le 0) { 'forever' } else { $Cycles }), $(if ($serialPort) { $Serial } else { 'none' }), $(if ($doLog) { $logPath } else { 'off' })) -ForegroundColor $col.ok
Write-Host "  Ctrl-C to stop. Watch the device console: no reboot, flat memory, bcu stat clean." -ForegroundColor $col.ok

$cycle = 0; $t0 = [datetime]::Now
while ($Cycles -le 0 -or $cycle -lt $Cycles) {
    $cycle++
    Write-Host ""
    Write-Host ("  ===== cycle {0}  (elapsed {1:hh\:mm\:ss}) =====" -f $cycle, ([datetime]::Now - $t0)) -ForegroundColor $col.h

    # ── A: ramp 1..16 (open k, send+recv, close) ──
    if ($enabled.A) {
        Write-Host "  [A] ramp 1..16" -ForegroundColor $col.p
        for ($k = 1; $k -le 16; $k++) {
            $list = @(); for ($i = 1; $i -le $k; $i++) { $t = Open-Conn 0x02 $null $null; if ($t) { $list += $t } else { break } }
            $rx = 0; $v = 0; foreach ($t in $list) { $null = Send-Gw $t 1 $v 1; $v++ }
            Start-Sleep -Milliseconds 40; foreach ($t in $list) { $rx += (Drain $t) }
            foreach ($t in $list) { Close-Conn $t }
            if ($k -eq 16) { Write-Host ("      ramp top: opened {0}/16  rx {1}" -f $list.Count, $rx) -ForegroundColor $col.ok }
            Start-Sleep -Milliseconds 30
        }
    }

    # ── B: large-data stress (extended frames) ──
    if ($enabled.B) {
        Write-Host "  [B] large-data stress (200-byte extended writes, 6 s)" -ForegroundColor $col.p
        $lt = Open-Conn 0x02 $null $null
        if ($lt) {
            $end = ([datetime]::Now).AddSeconds(6); $txB = 0; $rxN = 0; $val = 0
            while ([datetime]::Now -lt $end) { $txB += (Send-Gw $lt 1 $val 200); $val++; $rxN += (Drain $lt); Start-Sleep -Milliseconds 5 }
            Close-Conn $lt
            Write-Host ("      sent {0:N0} KB, rx {1} frames" -f ($txB / 1024), $rxN) -ForegroundColor $col.ok
        } else { Write-Host "      (no free slot)" -ForegroundColor $col.warn }
    }

    # ── C: fuzz bombardment ──
    if ($enabled.C) {
        Write-Host "  [C] fuzz bombardment" -ForegroundColor $col.p
        $fz = Join-Path $PSScriptRoot 'Test-Fuzz.ps1'
        if (Test-Path $fz) { & $fz -Ip $Ip -Rounds 20 -Flood 800 -TrafficIp $TrafficIp 2>&1 | Select-String 'DONE' | ForEach-Object { Write-Host ("      " + $_.Line.Trim()) -ForegroundColor $col.ok } }
        Start-Sleep -Milliseconds 500   # brief reap of the fuzz's abandoned/stormed tunnel slots
    }

    # ── D: busmonitor fed by REAL bus traffic (needs a traffic SOURCE) ──
    # The monitored interface cannot self-transmit during busmon, so traffic must come from outside.
    # Pump 4 tunnels on the traffic interface batch-style to keep TP saturated -> busmon sees a busy bus.
    if ($enabled.D -and $TrafficIp) {
        Write-Host "  [D] busmon + real traffic flood (8 s)" -ForegroundColor $col.p
        $tdip = Get-LocalIpBytes $TrafficIp; $tep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($TrafficIp), 3671)
        $bm = Open-Retry 0x80 $null $null 6
        $gens = @(); for ($i = 0; $i -lt 4; $i++) { $gg = Open-Retry 0x02 $tep $tdip 6; if ($gg) { $gens += $gg } }
        if ($bm -and $gens.Count -gt 0) {
            $end = ([datetime]::Now).AddSeconds(8); $frames = 0; $sent = 0; $val = 0
            while ([datetime]::Now -lt $end) {
                foreach ($g in $gens) { $null = Send-Gw $g ((($val % 8) -shl 8) -bor ($val % 256)) $val 1; $val++; $sent++ }   # burst one per tunnel
                foreach ($g in $gens) { [void](Wait-Ack $g 25); $null = Drain $g }                                          # collect ACKs
                $frames += (Drain $bm)                                                                                       # count L_Busmon.ind
            }
            Start-Sleep -Milliseconds 200; $frames += (Drain $bm)
            Write-Host ("      injected {0} telegrams via {1} tunnels -> busmon captured {2} L_Busmon.ind" -f $sent, $gens.Count, $frames) -ForegroundColor $col.ok
        } else { Write-Host "      (busmon or traffic tunnels unavailable)" -ForegroundColor $col.warn }
        Close-Conn $bm; foreach ($g in $gens) { Close-Conn $g }
        Start-Sleep -Milliseconds 150
    }

    # ── E: ~100% bus saturation (8 interface tunnels, batch-pumped -> TP TX queue never drains) ──
    if ($enabled.E) {
        Write-Host "  [E] ~100% bus saturation (8-tunnel batch flood, 10 s)" -ForegroundColor $col.p
        $sat = @(); for ($i = 0; $i -lt 8; $i++) { $st = Open-Retry 0x02 $null $null 3; if ($st) { $sat += $st } }
        if ($sat.Count -gt 0) {
            $end = ([datetime]::Now).AddSeconds(10); $n = 0; $val = 0
            while ([datetime]::Now -lt $end) {
                foreach ($st in $sat) { $null = Send-Gw $st ((($val % 8) -shl 8) -bor ($val % 256)) $val 1; $val++; $n++ }   # burst: one per tunnel
                foreach ($st in $sat) { [void](Wait-Ack $st 20); $null = Drain $st }                                        # collect ACKs, then repeat
            }
            foreach ($st in $sat) { Close-Conn $st }
            Write-Host ("      pushed {0} telegrams via {1} tunnels (~{2}/s onto TP)" -f $n, $sat.Count, [int]($n / 10)) -ForegroundColor $col.ok
        } else { Write-Host "      (no free interface tunnel)" -ForegroundColor $col.warn }
    }

    # ── J: MAX blast -- precomputed frames, no build, no drain, no pacing: the fastest datagram torrent
    # PowerShell can push. Offers many multiples of bus capacity so the device must shed excess and stay up. ──
    if ($enabled.J) {
        Write-Host "  [J] MAX blast (16 tunnels, precomputed, unpaced, 8 s)" -ForegroundColor $col.p
        $ov = @(); for ($i = 0; $i -lt 16; $i++) { $o = Open-Retry 0x02 $null $null 2; if ($o) { $ov += $o } }
        if ($ov.Count -gt 0) {
            $shots = @(); $vv = 0                                                    # one ready-to-send datagram per tunnel -> hot loop is pure SendTo
            foreach ($o in $ov) {
                $ga = (($vv % 8) -shl 8) -bor ($vv % 256)
                $cemi = [byte[]](@(0x11, 0x00, 0xBC, 0xE0, 0x00, 0x00, (($ga -shr 8) -band 0xFF), ($ga -band 0xFF), 0x01, 0x00, (0x80 -bor ($vv -band 0x3F))))
                $shots += @{ Sock = $o.Sock; Frame = (New-KnxFrame 0x0420 ([byte[]](@(0x04, [byte]$o.Ch, 0x00, 0x00) + $cemi))); Dst = $o.Dst }; $vv++
            }
            $end = ([datetime]::Now).AddSeconds(8); $blast = 0
            while ([datetime]::Now -lt $end) {
                foreach ($s in $shots) { try { $null = $s.Sock.SendTo($s.Frame, $s.Dst); $blast++ } catch {} }   # raw torrent, no ACK, no drain
            }
            foreach ($o in $ov) { Close-Conn $o }
            Write-Host ("      MAX-blasted {0:N0} datagrams via {1} tunnels (~{2:N0}/s = many x bus capacity)" -f $blast, $ov.Count, [int]($blast / 8)) -ForegroundColor $col.ok
        } else { Write-Host "      (no free interface tunnels)" -ForegroundColor $col.warn }
    }

    # ── M: relentless load -- pool of tunnels jetting data + a connection churned every iteration, no idle ──
    if ($enabled.M) {
        Write-Host "  [M] rapid connect-churn (5 s) then relentless data jet (10 s)" -ForegroundColor $col.p
        # part 1: rapid connect/disconnect churn -- device is not being jetted here, so CONNECTs are fast
        $cEnd = ([datetime]::Now).AddSeconds(5); $churn = 0; $val = 0
        while ([datetime]::Now -lt $cEnd) {
            $c = Open-Conn 0x02 $null $null 400
            if ($c) { $churn++; $null = Send-Gw $c 1 $val 1; $null = Send-Gw $c 1 ($val + 1) 1; $val += 2; Close-Conn $c }
        }
        # part 2: pure relentless jet from a persistent pool (zero idle)
        $pool = @(); for ($i = 0; $i -lt 8; $i++) { $p = Open-Retry 0x02 $null $null 2; if ($p) { $pool += $p } }
        $jet = 0; $it = 0; $jEnd = ([datetime]::Now).AddSeconds(10)
        while ([datetime]::Now -lt $jEnd) {
            foreach ($p in $pool) { $null = Send-Gw $p ((($val % 8) -shl 8) -bor ($val % 256)) $val 1; $val++; $jet++ }
            if ($it % 8 -eq 0) { foreach ($p in $pool) { $null = Drain $p } }; $it++
        }
        foreach ($p in $pool) { Close-Conn $p }
        Write-Host ("      {0} fast connect/disconnect cycles + {1:N0} telegrams jetted" -f $churn, $jet) -ForegroundColor $col.ok
    }

    # ── G: rich telegram matrix -- everything the ETS group monitor can show ──
    # services (Read/Write/Response) x priority (0-3) x hop count x payload length (1-bit .. 240 byte),
    # sprayed from several interface tunnels so distinct source PAs appear in the monitor.
    if ($enabled.G) {
        Write-Host "  [G] rich matrix: Read/Write/Response - prio 0-3 - hop - len 1bit..240B - multi-source" -ForegroundColor $col.p
        $gens = @(); for ($i = 0; $i -lt 4; $i++) { $gg = Open-Retry 0x02 $null $null 3; if ($gg) { $gens += $gg } }
        if ($gens.Count -gt 0) {
            $lens = @(0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 14, 16, 32, 64, 128, 200, 240, 250)   # every canonical DPT size 1-bit..14-byte, then extended up to max APDU
            $svcs = @('write', 'response', 'read')
            $n = 0; $val = 0
            foreach ($svc in $svcs) {
                for ($prio = 0; $prio -lt 4; $prio++) {
                    foreach ($ln in $lens) {
                        if ($svc -eq 'read' -and $ln -gt 0) { continue }   # read carries no payload
                        $payload = New-Object byte[] ([Math]::Max($ln, 0))
                        for ($j = 0; $j -lt $ln; $j++) { $payload[$j] = [byte](($val + $j) -band 0xFF) }
                        $g = $gens[$n % $gens.Count]
                        $ga = ((($n % 15) + 1) -shl 8) -bor (($n * 7) % 250)
                        Send-Rich $g $ga $svc $prio ($n % 8) $payload $val
                        [void](Wait-Ack $g 40); $null = Drain $g; $n++; $val++
                    }
                }
            }
            # exotic edge telegrams so both monitors light up extra ways: broadcast, repeated-frame flag, individual-addressed
            $gx = $gens[0]; $ex = 0
            foreach ($p in 0..3) { Send-Rich $gx 0 'write' $p 6 ([byte[]]@(($val -band 0xFF))) $val 1; [void](Wait-Ack $gx 30); $null = Drain $gx; $ex++; $val++ }               # broadcast 0/0/0
            foreach ($p in 0..3) { Send-Rich $gx ((($p + 1) -shl 8) -bor 7) 'write' $p 6 ([byte[]]@(0xAA, 0x55)) $val 1 $true; [void](Wait-Ack $gx 30); $null = Drain $gx; $ex++; $val++ }  # repeated-frame flag
            foreach ($dpa in @(0xFFFA, 0xFFFB, 0xFFFC)) { Send-Rich $gx $dpa 'read' 1 6 ([byte[]]@()) $val 0; [void](Wait-Ack $gx 30); $null = Drain $gx; $ex++ }                  # individual-addressed to dummy PA (nobody reacts)
            $dpts = @(                                                    # realistic DPT-encoded values -> monitors show meaningful readouts
                @(0x2B), @(0x0C, 0x5E), @(0x12, 0x34), @(0x0A, 0x1E, 0x2D), @(0x19, 0x07, 0x1A),
                @(0x00, 0x00, 0x04, 0xD2), @(0x42, 0x28, 0x00, 0x00), @(0xFF, 0x80, 0x00),
                @(0xFF, 0x80, 0x00, 0x40, 0x00, 0x00), (0..13 | ForEach-Object { [byte](65 + $_) })
            )                                                             # DPT5 %, DPT9 temp, DPT7, DPT10 time, DPT11 date, DPT12/13, DPT14 float, DPT232 RGB, DPT251 RGBW, DPT16 string
            foreach ($dv in $dpts) { Send-Rich $gx (((($ex % 15) + 1) -shl 8) -bor 9) 'write' 3 6 ([byte[]]$dv) $val; [void](Wait-Ack $gx 30); $null = Drain $gx; $ex++; $val++ }
            $n += $ex
            foreach ($g in $gens) { Close-Conn $g }
            Write-Host ("      fired {0} rich telegrams ({1} exotic: broadcast/repeated/individual) from {2} source PAs" -f $n, $ex, $gens.Count) -ForegroundColor $col.ok
        } else { Write-Host "      (no traffic tunnels)" -ForegroundColor $col.warn }
    }

    # ── K: full KNX APCI catalog -- every application service appears at least once on the bus ──
    if ($enabled.K) {
        Write-Host "  [K] full KNX APCI catalog (every telegram type; pt-to-pt -> dummy PA 15.15.254 = safe)" -ForegroundColor $col.p
        $kt = Open-Retry 0x02 $null $null 3
        if ($kt) {
            $dummyPa = 0xFFFE; $testGa = 0x0901; $ksent = 0
            foreach ($a in $APCI) {
                $addr = if ($a.BC) { 0 } elseif ($a.G) { $testGa } else { $dummyPa }
                $dt = if ($a.G -or $a.BC) { 1 } else { 0 }
                Write-Verbose ("    K: {0,-26} APCI 0x{1:X3}  {2}" -f $a.N, $a.A, $(if ($a.BC) { 'broadcast' } elseif ($a.G) { 'group' } else { 'individual->15.15.254' }))
                foreach ($prio in 0..3) { Send-Apci $kt $addr $a.A $dt ([byte[]]$a.D) $prio 6; [void](Wait-Ack $kt 30); $null = Drain $kt; $ksent++ }
            }
            Close-Conn $kt
            Write-Host ("      sent {0} telegrams across {1} APCI types x 4 priorities" -f $ksent, $APCI.Count) -ForegroundColor $col.ok
        } else { Write-Host "      (no free interface tunnel)" -ForegroundColor $col.warn }
    }

    # ── L: transport layer -- T_Connect -> numbered T_Data_Connected -> T_ACK -> T_Disconnect ──
    # A plain group write never produces these; sent to a dummy PA so no real device opens a connection.
    if ($enabled.L) {
        Write-Host "  [L] transport layer: connect -> numbered services -> ack -> disconnect (dummy PA, safe)" -ForegroundColor $col.p
        $lt = Open-Retry 0x02 $null $null 3
        if ($lt) {
            $dummyPa = 0xFFFE; $lsent = 0
            foreach ($rep in 1..4) {
                Send-Tpdu $lt $dummyPa 0 @(0x80) 3 6; $lsent++                                   # T_Connect
                for ($seq = 0; $seq -lt 4; $seq++) {
                    $tp = @(((0x40 -bor ($seq -shl 2)) -bor ((0x300 -shr 8) -band 0x03)), (0x300 -band 0xFF), 0x00)   # numbered T_Data_Connected: DeviceDescriptorRead
                    Send-Tpdu $lt $dummyPa 0 $tp 3 6; $lsent++
                    Send-Tpdu $lt $dummyPa 0 @((0xC2 -bor ($seq -shl 2))) 3 6; $lsent++          # T_ACK(seq)
                }
                Send-Tpdu $lt $dummyPa 0 @(0x81) 3 6; $lsent++                                   # T_Disconnect
                [void](Wait-Ack $lt 30); $null = Drain $lt
            }
            Close-Conn $lt
            Write-Host ("      sent {0} transport-layer PDUs (Connect / numbered Data_Connected / ACK / Disconnect)" -f $lsent) -ForegroundColor $col.ok
        } else { Write-Host "      (no free interface tunnel)" -ForegroundColor $col.warn }
    }

    # ── H: device health snapshot (bcu stat) over serial -- always ──
    Show-Health $cycle

    # ── I: full network discovery -- every KNXnet/IP device + its advertised identity (must stay correct) ──
    Write-Host "  [I] discovery: every device ETS's connection list sees (multicast SEARCH):" -ForegroundColor $col.p
    $all = Get-AllDibs 2500 $MeB
    if ($all.Count -eq 0) { Write-Host "      (no SEARCH_RESPONSE)" -ForegroundColor $col.warn }
    foreach ($d in ($all | Sort-Object { $_.Ip })) {
        $bad = ($d.Prog -eq 1) -or ($d.Raw -eq 0xFFFF) -or ($d.Raw -eq 0)               # progmode stuck / unprogrammed / lost PA
        $mark = if ($d.Ip -eq $Ip) { '  <- DUT' } elseif ($d.Ip -eq $TrafficIp) { '  <- traffic' } else { '' }
        $tag = if ($d.Prog) { 'PROGMODE ON' } else { 'progmode off' }
        Write-Host ("      {0,-14} PA={1,-10} {2}  name={3}{4}" -f $d.Ip, $d.Pa, $tag, $d.Name, $mark) -ForegroundColor $(if ($bad) { 'Red' } else { $col.ok })
    }

    # ── F: every 4th cycle -- dead-connection 120 s timeout reaper ──
    if ($enabled.F -and $cycle % 4 -eq 0) {
        Write-Host "  [F] dead-connection test: open 4 tunnels, abandon (no disconnect) -> device reaps at 120 s" -ForegroundColor $col.p
        for ($i = 0; $i -lt 4; $i++) { $t = Open-Conn 0x02 $null $null; if ($t) { $t.Sock.Close() } }   # close socket, never DISCONNECT -> zombie until 120 s
        Write-Host "      abandoned 4 tunnels (watch 'tun' history: they end with reason Timeout after ~120 s)" -ForegroundColor $col.ok
    }
}
Write-Host ""
Write-Host ("  soak done: {0} cycles in {1:hh\:mm\:ss}" -f $cycle, ([datetime]::Now - $t0)) -ForegroundColor $col.h
if ($serialPort) { try { $serialPort.Close() } catch {} }
if ($doLog) { try { Stop-Transcript | Out-Null } catch {}; Write-Host ("  log: {0}" -f $logPath) -ForegroundColor $col.ok }
