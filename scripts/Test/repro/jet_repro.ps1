param([string]$Ip = "11.11.0.126", [int]$Secs = 12)
function Kf([int]$s, [byte[]]$b) { $l = 6 + $b.Length; return [byte[]](@(0x06, 0x10, (($s -shr 8) -band 0xFF), ($s -band 0xFF), (($l -shr 8) -band 0xFF), ($l -band 0xFF)) + $b) }
function Hp([byte[]]$ip, [int]$p) { return [byte[]](@(0x08, 0x01) + $ip + @((($p -shr 8) -band 0xFF), ($p -band 0xFF))) }
function Li([string]$d) { $u = New-Object System.Net.Sockets.UdpClient; try { $u.Connect($d, 3671); return $u.Client.LocalEndPoint.Address.GetAddressBytes() } finally { $u.Close() } }
$me = Li $Ip; $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($Ip), 3671)
$any = { [System.Net.EndPoint]([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)) }
function Open() {
    $s = New-Object System.Net.Sockets.Socket("InterNetwork", "Dgram", "Udp"); $s.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0))
    $mp = ([System.Net.IPEndPoint]$s.LocalEndPoint).Port; $h = Hp $me $mp
    $null = $s.SendTo((Kf 0x0205 ([byte[]]($h + $h + @(0x04, 0x04, 0x02, 0x00)))), $ep); $s.ReceiveTimeout = 1500; $b = New-Object byte[] 64; $f = & $any
    try { $rn = $s.ReceiveFrom($b, [ref]$f) } catch { $s.Close(); return $null }
    if ($b[7] -ne 0) { $s.Close(); return $null }
    return @{ Sock = $s; Ch = $b[6]; Hpai = $h; Seq = 0 }
}
function GwInc($t, [int]$ga) {
    $cemi = [byte[]](@(0x11, 0x00, 0xBC, 0xE0, 0x00, 0x00, (($ga -shr 8) -band 0xFF), ($ga -band 0xFF), 0x01, 0x00, 0x81))
    $null = $t.Sock.SendTo((Kf 0x0420 ([byte[]](@(0x04, [byte]$t.Ch, [byte]($t.Seq -band 0xFF), 0x00) + $cemi))), $ep); $t.Seq = ($t.Seq + 1) -band 0xFF
}
function DrainT($t) { $b = New-Object byte[] 256; while ($t.Sock.Available -gt 0) { $f = & $any; $null = $t.Sock.ReceiveFrom($b, [ref]$f) } }
function Close($t) { try { $null = $t.Sock.SendTo((Kf 0x0209 ([byte[]](@([byte]$t.Ch, 0x00) + $t.Hpai))), $ep) } catch {}; try { $t.Sock.Close() } catch {} }
function Reachable() { $d = Open; if ($d) { Close $d; return $true } return $false }

function Jet([int]$n, [string]$label) {
    Write-Host ("--- {0}: opening {1} tunnel(s) ---" -f $label, $n)
    $tt = @(); for ($i = 0; $i -lt $n; $i++) { $t = Open; if ($t) { $tt += $t } }
    if ($tt.Count -eq 0) { Write-Host "  no tunnel"; return }
    $end = [datetime]::Now.AddSeconds($Secs); $sent = 0; $it = 0
    while ([datetime]::Now -lt $end) {
        foreach ($t in $tt) { GwInc $t (((($sent % 8) + 1) -shl 8) -bor ($sent % 200)); $sent++ }   # INCREMENTING seq -> forwarded to TP
        if ($it % 8 -eq 0) { foreach ($t in $tt) { DrainT $t } }; $it++
    }
    foreach ($t in $tt) { Close $t }
    Write-Host ("  {0}: jetted {1:N0} incrementing-seq telegrams via {2} tunnel(s) in {3}s" -f $label, $sent, $tt.Count, $Secs)
}

Write-Host "reachable before: $(Reachable)"
Jet 1 "A(1-tunnel)"
Start-Sleep -Milliseconds 500
Write-Host "reachable after 1-tunnel jet: $(Reachable)"
Jet 8 "B(8-tunnel)"
Start-Sleep -Milliseconds 500
Write-Host "reachable after 8-tunnel jet: $(Reachable)"
