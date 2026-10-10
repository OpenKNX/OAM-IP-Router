#!/usr/bin/env pwsh
# Open ■
# ┬────┴  Test-FloodBisect
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/repro/Test-FloodBisect.ps1
# wiki.openknx.de - forum.openknx.de

<#
.SYNOPSIS
    Runs an unpaced incrementing-sequence tunnel flood and counts how many WATCHDOG RESETS it caused,
    read from the device console before and after the run. The console is opened only while the device
    is idle -- never during the jet -- so the measurement never perturbs the fault and never hangs on
    the USB-CDC node disappearing at reset.

    The point is to bisect DataLinkLayer::dataRequestFromTunnel:

      -Mode Group   destination is a GROUP address -> the full chain runs, including frameReceived()
                    and the TP sendFrame() at the end (new TPUart::Frame, transmit queue).

      -Mode OwnPa   destination is the device's OWN individual address -> dataRequestFromTunnel returns
                    early (data_link_layer.cpp:86-87), so the TP send path is NOT reached. Everything
                    before it (ACK, cEMI server, dataConfirmationToTunnel, tunnel FIFO, frameReceived)
                    still runs.

    Reboots in Group but not in OwnPa  => the fault is in the TP send path.
    Reboots in both                    => the fault is before it (tunnel FIFO / cEMI / frameReceived).

.PARAMETER Ip       Interface under test.                                     e.g. 11.11.0.126
.PARAMETER Serial   Device console port (read only between phases).           e.g. /dev/cu.usbmodem3101
.PARAMETER Mode     Group | OwnPa | Both                                      Default Both
.PARAMETER OwnPa    Device individual address, for -Mode OwnPa.               Default 5.0.10
.PARAMETER JetSecs  Seconds of jetting per mode.                              Default 30
.PARAMETER Help     Show this help.

.EXAMPLE
    ./Test-FloodBisect.ps1 -Ip 11.11.0.126 -Serial /dev/cu.usbmodem3101
        Run both modes for 30 s each and report the watchdog-reset delta of each.

.NOTES
    AUTHOR : Erkan Çolak
#>
[CmdletBinding()]
param(
    [string]$Ip = "11.11.0.126",
    [string]$Serial = "/dev/cu.usbmodem3101",
    [ValidateSet("Group", "OwnPa", "Both")][string]$Mode = "Both",
    [string]$OwnPa = "5.0.10",
    [int]$JetSecs = 30,
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
function PaToInt([string]$pa) {
    $p = $pa.Split(".")
    return ((([int]$p[0]) -shl 12) -bor (([int]$p[1]) -shl 8) -bor ([int]$p[2]))
}
$AnyEp = { [System.Net.EndPoint]([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)) }

$me = LocalIp $Ip
$ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($Ip), 3671)

# ---- console: read watchdog reset count + uptime (device must be idle) --------------------------
function ReadState() {
    $res = @{ Resets = -1; Uptime = "?"; MemMin = "?"; StackMin = "?" }
    try {
        Add-Type -AssemblyName System.IO.Ports -ErrorAction SilentlyContinue
        $sp = New-Object System.IO.Ports.SerialPort($Serial, 115200)
        $sp.ReadTimeout = 200; $sp.DtrEnable = $true; $sp.RtsEnable = $true
        $sp.Open(); Start-Sleep -Milliseconds 400; $sp.DiscardInBuffer()
        $out = ""
        foreach ($c in @("watchdog", "uptime", "mem")) {
            $sp.Write($c + "`r"); Start-Sleep -Milliseconds 1000
            $out += $sp.ReadExisting()
        }
        $sp.Close()
        $out = ($out -replace "\x1b\[[0-9;]*[A-Za-z]", "")
        if ($out -match "Running \((\d+) Resets\)") { $res.Resets = [int]$Matches[1] }
        if ($out -match "Uptime:\s+(\S+ \S+)") { $res.Uptime = $Matches[1] }
        if ($out -match "Free memory:\s+([\d\.]+ KiB \(min\. [\d\.]+ KiB\))") { $res.MemMin = $Matches[1] }
        if ($out -match "Free stack size:\s+(.*)") { $res.StackMin = $Matches[1].Trim() }
    }
    catch { Write-Host ("  (console read failed: {0})" -f $_.Exception.Message) -ForegroundColor DarkYellow }
    return $res
}

function WaitAlive([int]$maxSecs = 60) {
    $p = NewSock; $p.Blocking = $false
    $hp = Hp $me ([System.Net.IPEndPoint]$p.LocalEndPoint).Port
    $buf = New-Object byte[] 256
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $maxSecs) {
        try { $null = $p.SendTo((Kf 0x0203 $hp), $ep) } catch {}
        $d = [datetime]::Now.AddMilliseconds(300)
        while ([datetime]::Now -lt $d) {
            if ($p.Available -gt 0) {
                $f = & $AnyEp
                try { $n = $p.ReceiveFrom($buf, [ref]$f); if ($n -ge 8 -and $buf[2] -eq 0x02 -and $buf[3] -eq 0x04) { $p.Close(); return $true } } catch {}
            }
            Start-Sleep -Milliseconds 10
        }
    }
    $p.Close(); return $false
}

# ---- one jet run -------------------------------------------------------------------------------
function RunJet([string]$mode, [int]$secs) {
    $s = NewSock
    $hp = Hp $me ([System.Net.IPEndPoint]$s.LocalEndPoint).Port
    $null = $s.SendTo((Kf 0x0205 ([byte[]]($hp + $hp + @(0x04, 0x04, 0x02, 0x00)))), $ep)
    $s.ReceiveTimeout = 2000
    $rb = New-Object byte[] 256; $f = & $AnyEp
    try { $n = $s.ReceiveFrom($rb, [ref]$f) } catch { Write-Host "  CONNECT timed out" -ForegroundColor Red; $s.Close(); return 0 }
    if ($rb[7] -ne 0) { Write-Host ("  CONNECT refused 0x{0:X2}" -f $rb[7]) -ForegroundColor Red; $s.Close(); return 0 }
    $ch = $rb[6]
    Write-Host ("  tunnel ch=0x{0:X2}, jetting {1} for {2}s ..." -f $ch, $mode, $secs)

    $paInt = PaToInt $OwnPa
    $s.Blocking = $false
    $seq = 0; $sent = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt ($secs * 1000)) {
        for ($k = 0; $k -lt 100; $k++) {
            if ($mode -eq "OwnPa") {
                # individual-addressed to our OWN PA: dataRequestFromTunnel returns before sendFrame()
                $cemi = [byte[]](@(0x11, 0x00, 0xBC, 0x60, 0x00, 0x00, (($paInt -shr 8) -band 0xFF), ($paInt -band 0xFF), 0x01, 0x00, 0x00))
            }
            else {
                $ga = (((($sent % 8) + 1) -shl 8) -bor ($sent % 200))
                $cemi = [byte[]](@(0x11, 0x00, 0xBC, 0xE0, 0x00, 0x00, (($ga -shr 8) -band 0xFF), ($ga -band 0xFF), 0x01, 0x00, 0x81))
            }
            try { $null = $s.SendTo((Kf 0x0420 ([byte[]](@(0x04, [byte]$ch, [byte]($seq -band 0xFF), 0x00) + $cemi))), $ep) } catch {}
            $seq = ($seq + 1) -band 0xFF
            $sent++
        }
        # never ACK; just keep the socket from filling up
        while ($s.Available -gt 0) { $f = & $AnyEp; try { $null = $s.ReceiveFrom($rb, [ref]$f) } catch { break } }
    }
    $s.Close()
    return $sent
}

# ---- main --------------------------------------------------------------------------------------
Write-Host ""
Write-Host "=== Test-FloodBisect  target=$Ip  mode=$Mode  jet=${JetSecs}s ===" -ForegroundColor Cyan

$modes = if ($Mode -eq "Both") { @("Group", "OwnPa") } else { @($Mode) }

foreach ($m in $modes) {
    Write-Host ""
    Write-Host ("--- mode: {0} ---" -f $m) -ForegroundColor Yellow

    if (-not (WaitAlive 30)) { Write-Host "  device not reachable - abort" -ForegroundColor Red; break }
    $before = ReadState
    Write-Host ("  before: resets={0}  uptime={1}  {2}  stack={3}" -f $before.Resets, $before.Uptime, $before.MemMin, $before.StackMin)

    $sent = RunJet $m $JetSecs
    Write-Host ("  jet done: sent={0:N0}" -f $sent)

    if (-not (WaitAlive 60)) { Write-Host "  device did NOT come back within 60s" -ForegroundColor Red; continue }
    Start-Sleep -Seconds 2
    $after = ReadState
    Write-Host ("  after : resets={0}  uptime={1}  {2}  stack={3}" -f $after.Resets, $after.Uptime, $after.MemMin, $after.StackMin)

    if ($before.Resets -ge 0 -and $after.Resets -ge 0) {
        $delta = $after.Resets - $before.Resets
        if ($delta -gt 0) { Write-Host ("  RESULT: {0} -> {1} WATCHDOG RESET(S)" -f $m, $delta) -ForegroundColor Red }
        else { Write-Host ("  RESULT: {0} -> no reset" -f $m) -ForegroundColor Green }
    }
    Start-Sleep -Seconds 3
}

Write-Host ""
Write-Host "=== done ===" -ForegroundColor Cyan
