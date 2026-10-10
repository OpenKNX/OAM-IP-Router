function New-KnxFrame([int]$svc, [byte[]]$b) { $l = 6 + $b.Length; return [byte[]](@(0x06, 0x10, (($svc -shr 8) -band 0xFF), ($svc -band 0xFF), (($l -shr 8) -band 0xFF), ($l -band 0xFF)) + $b) }
function New-Hpai([byte[]]$ip, [int]$p) { return [byte[]](@(0x08, 0x01) + $ip + @((($p -shr 8) -band 0xFF), ($p -band 0xFF))) }
function LocalIp([string]$d) { $u = New-Object System.Net.Sockets.UdpClient; try { $u.Connect($d, 3671); return $u.Client.LocalEndPoint.Address.GetAddressBytes() } finally { $u.Close() } }

$me = LocalIp "11.11.0.126"
$s = New-Object System.Net.Sockets.Socket("InterNetwork", "Dgram", "Udp")
$s.SetSocketOption("Socket", "ReuseAddress", $true)
$s.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
$mp = ([System.Net.IPEndPoint]$s.LocalEndPoint).Port
$h = New-Hpai $me $mp
$mcast = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse("224.0.23.12"), 3671)
$null = $s.SendTo((New-KnxFrame 0x0201 $h), $mcast)   # SEARCH_REQUEST -> multicast
Write-Host "SEARCH_RESPONSE device-info DIBs (this is what ETS's connection list uses):"
$s.ReceiveTimeout = 2500; $buf = New-Object byte[] 512
$deadline = [datetime]::Now.AddSeconds(3)
$seen = @{}
while ([datetime]::Now -lt $deadline) {
    $from = [System.Net.EndPoint]([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
    try { $rn = $s.ReceiveFrom($buf, [ref]$from) } catch { break }
    $svc = ([int]$buf[2] -shl 8) -bor $buf[3]
    if ($svc -ne 0x0202) { continue }   # SEARCH_RESPONSE
    $src = ([System.Net.IPEndPoint]$from).Address.ToString()
    if ($seen.ContainsKey($src)) { continue }; $seen[$src] = $true
    $o = 14   # SEARCH_RESPONSE: header(6) + control HPAI(8) -> Device Info DIB at 14
    if ($buf[$o + 1] -ne 0x01) { Write-Host ("  {0} : DIB type at 14 = 0x{1:X2} (unexpected)" -f $src, $buf[$o + 1]); continue }
    $status = $buf[$o + 3]; $prog = ($status -band 0x01)
    $pa = ([int]$buf[$o + 4] -shl 8) -bor $buf[$o + 5]
    $paStr = "{0}.{1}.{2}" -f ($pa -shr 12), (($pa -shr 8) -band 0x0F), ($pa -band 0xFF)
    $name = [System.Text.Encoding]::ASCII.GetString($buf, $o + 24, 30).TrimEnd([char]0)
    $tag = if ($prog) { 'PROGMODE ON' } else { 'progmode off' }
    Write-Host ("  {0,-14} PA={1,-10} {2}  status=0x{3:X2}  name={4}" -f $src, $paStr, $tag, $status, $name)
}
$s.Close()
