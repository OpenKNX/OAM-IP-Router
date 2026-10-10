param([string]$Ip = "11.11.0.126", [string]$Port = "/dev/cu.usbmodem3101", [int]$MaxSecs = 20)
function Kf([int]$s, [byte[]]$b) { $l = 6 + $b.Length; return [byte[]](@(0x06, 0x10, (($s -shr 8) -band 0xFF), ($s -band 0xFF), (($l -shr 8) -band 0xFF), ($l -band 0xFF)) + $b) }
function Hp([byte[]]$ip, [int]$p) { return [byte[]](@(0x08, 0x01) + $ip + @((($p -shr 8) -band 0xFF), ($p -band 0xFF))) }
function Li([string]$d) { $u = New-Object System.Net.Sockets.UdpClient; try { $u.Connect($d, 3671); return $u.Client.LocalEndPoint.Address.GetAddressBytes() } finally { $u.Close() } }
function Ansi([string]$s) { return ($s -replace "\x1b\[[0-9;]*[A-Za-z]", "" -replace "\x1b\[2K", "") }
$me = Li $Ip; $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($Ip), 3671); $any = { [System.Net.EndPoint]([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)) }

Add-Type -AssemblyName System.IO.Ports -ErrorAction SilentlyContinue
$sp = New-Object System.IO.Ports.SerialPort($Port, 115200); $sp.ReadTimeout = 200; $sp.DtrEnable = $true; $sp.RtsEnable = $true; $sp.Open(); Start-Sleep -Milliseconds 300; $sp.DiscardInBuffer()
function Pump() { try { $t = $sp.ReadExisting(); if ($t) { foreach ($ln in ((Ansi $t) -split "`r?`n")) { $x = $ln.Trim(); if ($x.Length -gt 0) { Write-Host ("  SER| " + $x) } } } } catch {} }

# open a tunnel
$s = New-Object System.Net.Sockets.Socket("InterNetwork", "Dgram", "Udp"); $s.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
$mp = ([System.Net.IPEndPoint]$s.LocalEndPoint).Port; $h = Hp $me $mp
$null = $s.SendTo((Kf 0x0205 ([byte[]]($h + $h + @(0x04, 0x04, 0x02, 0x00)))), $ep); $s.ReceiveTimeout = 1500; $b = New-Object byte[] 64; $f = & $any
$rn = $s.ReceiveFrom($b, [ref]$f); if ($b[7] -ne 0) { Write-Host "connect failed"; $sp.Close(); exit }
$ch = $b[6]; Write-Host ("tunnel open ch=0x{0:X2} -- jetting UNPACED incrementing-seq group writes..." -f $ch)
$s.Blocking = $false
$seq = 0; $sent = 0; $t0 = [datetime]::Now
while (([datetime]::Now - $t0).TotalSeconds -lt $MaxSecs) {
    for ($k = 0; $k -lt 50; $k++) {
        $ga = (((($sent % 8) + 1) -shl 8) -bor ($sent % 200))
        $cemi = [byte[]](@(0x11, 0x00, 0xBC, 0xE0, 0x00, 0x00, (($ga -shr 8) -band 0xFF), ($ga -band 0xFF), 0x01, 0x00, 0x81))
        try { $null = $s.SendTo((Kf 0x0420 ([byte[]](@(0x04, [byte]$ch, [byte]($seq -band 0xFF), 0x00) + $cemi))), $ep) } catch {}
        $seq = ($seq + 1) -band 0xFF; $sent++
    }
    Pump
    if (($sent % 500) -eq 0) { Write-Host ("  ... sent {0}" -f $sent) }
}
$s.Close()
Write-Host ("jet done, sent={0}; reading serial tail for boot/fault..." -f $sent)
for ($i = 0; $i -lt 25; $i++) { Pump; Start-Sleep -Milliseconds 200 }
$sp.Close()
