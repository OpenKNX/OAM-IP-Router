function New-KnxFrame([int]$svc, [byte[]]$b) { $l = 6 + $b.Length; return [byte[]](@(0x06, 0x10, (($svc -shr 8) -band 0xFF), ($svc -band 0xFF), (($l -shr 8) -band 0xFF), ($l -band 0xFF)) + $b) }
function New-Hpai([byte[]]$ip, [int]$p) { return [byte[]](@(0x08, 0x01) + $ip + @((($p -shr 8) -band 0xFF), ($p -band 0xFF))) }
function LocalIp([string]$d) { $u = New-Object System.Net.Sockets.UdpClient; try { $u.Connect($d, 3671); return $u.Client.LocalEndPoint.Address.GetAddressBytes() } finally { $u.Close() } }
function Describe([string]$ip) {
    $me = LocalIp $ip; $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($ip), 3671)
    $s = New-Object System.Net.Sockets.Socket("InterNetwork", "Dgram", "Udp"); $s.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
    $mp = ([System.Net.IPEndPoint]$s.LocalEndPoint).Port; $h = New-Hpai $me $mp
    $null = $s.SendTo((New-KnxFrame 0x0203 $h), $ep)      # DESCRIPTION_REQUEST
    $s.ReceiveTimeout = 1500; $buf = New-Object byte[] 512; $from = [System.Net.EndPoint]([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
    try { $rn = $s.ReceiveFrom($buf, [ref]$from) } catch { Write-Host "  $ip : no DESCRIPTION_RESPONSE"; $s.Close(); return }
    $s.Close()
    $o = 6   # Device Info DIB: [len][type=01][medium][status][PA hi][PA lo]...[serial 6]...[name 30]
    if ($buf[$o + 1] -ne 0x01) { Write-Host ("  {0} : unexpected DIB type 0x{1:X2}" -f $ip, $buf[$o + 1]); return }
    $status = $buf[$o + 3]; $prog = ($status -band 0x01)
    $pa = ([int]$buf[$o + 4] -shl 8) -bor $buf[$o + 5]
    $paStr = "{0}.{1}.{2}" -f ($pa -shr 12), (($pa -shr 8) -band 0x0F), ($pa -band 0xFF)
    $serial = ($buf[($o + 8)..($o + 13)] | ForEach-Object { '{0:X2}' -f $_ }) -join ''
    $name = [System.Text.Encoding]::ASCII.GetString($buf, $o + 24, 30).TrimEnd([char]0)
    $tag = if ($prog) { 'PROGMODE ON' } else { 'progmode off' }
    Write-Host ("  {0,-14} PA={1,-10} {2}  status=0x{3:X2}  serial={4}  name={5}" -f $ip, $paStr, $tag, $status, $serial, $name)
}
Write-Host "DESCRIPTION_RESPONSE device-info DIB (advertised PA + progmode):"
Describe "11.11.0.126"
Describe "11.11.0.210"
Describe "11.11.0.5"
