# Open ■
# ┬────┴  Start-BusmonBridge
# ■ KNX   2026 OpenKNX - Erkan Çolak

<#
.SYNOPSIS
    KNXnet/IP Busmonitor -> Server-Sent-Events (SSE) bridge for OpenKNX devices.

.DESCRIPTION
    A local HTTP/SSE bridge. The browser (BusmonViewer.html, opened via file://)
    connects with:

        new EventSource("http://localhost:8671/stream?ip=<knxIp>&port=3671")

    On each SSE connection the bridge opens a KNXnet/IP tunnel (UDP) to the target
    ip/port chosen IN THE QUERY STRING, in BUSMONITOR mode (KNX layer 0x80) exactly
    like the ETS busmonitor. Every busmon frame arrives as a TUNNELING_REQUEST
    carrying a cEMI L_Busmon.ind (msg code 0x2B); the raw cEMI is streamed as
    uppercase hex to that SSE client. When the SSE client disconnects, the bridge
    tears down that KNX connection (DISCONNECT_REQUEST).

    So the target device is chosen by the WEBPAGE, per connection. Start the bridge
    once with no arguments; point different pages at different devices.

    Cross-platform: runs on Windows / macOS / Linux under Windows PowerShell 5.1+
    or PowerShell 7 (pwsh), using only .NET (UdpClient, HttpListener) + runspaces.

.PARAMETER Ip
    Optional DEFAULT interface IP, used only when the /stream query omits `ip`.

.PARAMETER Port
    Optional DEFAULT UDP port, used only when the query omits `port`. Default 3671.

.PARAMETER HttpPort
    Local TCP port for the SSE HTTP endpoint. Default 8671.

.PARAMETER DryRun
    Build and print the CONNECT_REQUEST bytes (plus HPAI / CRI) and exit 0.
    No network activity, no hardware needed.

.PARAMETER LinkLayer
    CLI default for the KNX layer: use 0x02 (LinkLayer) instead of 0x80 (Busmonitor).
    Overridden per request by the query `layer=busmon|link`. In LinkLayer mode every
    received cEMI is forwarded regardless of its message code.

.EXAMPLE
    pwsh -NoProfile -File scripts/Test/Start-BusmonBridge.ps1 -Ip 1.2.3.4 -DryRun

.EXAMPLE
    pwsh -NoProfile -File scripts/Test/Start-BusmonBridge.ps1
    # then the page opens EventSource("http://localhost:8671/stream?ip=11.11.0.210&port=3671")

.NOTES
    Author : Erkan Çolak
    Project: OAM-IP-Interface (OpenKNX)
    License : see repository
#>

[CmdletBinding()]
param(
    [string]$Ip = '',

    [int]$Port = 3671,

    [int]$HttpPort = 8671,

    [switch]$DryRun,

    [switch]$LinkLayer,

    [switch]$NoBrowser   # do not auto-open BusmonViewer.html in the default browser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# OpenKNX logo header (console) -- same brand as Build-Release.ps1 / Build-knxprods.ps1
function OpenKNX_ShowLogo($AddCustomText = $null) {
    Write-Host ""
    Write-Host "Open " -NoNewline
    Write-Host "$( [char]::ConvertFromUtf32(0x25A0) )" -ForegroundColor Green
    $bar = "$( [char]::ConvertFromUtf32(0x252C) )$( [char]::ConvertFromUtf32(0x2500) )$( [char]::ConvertFromUtf32(0x2500) )$( [char]::ConvertFromUtf32(0x2500) )$( [char]::ConvertFromUtf32(0x2500) )$( [char]::ConvertFromUtf32(0x2534) ) "
    if ($AddCustomText) { Write-Host "$bar $AddCustomText" -ForegroundColor Green } else { Write-Host "$bar" -ForegroundColor Green }
    Write-Host "$( [char]::ConvertFromUtf32(0x25A0) )" -NoNewline -ForegroundColor Green
    Write-Host " KNX"
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Shared helper library (single source of truth).
# Kept as text so it can be dot-sourced both in this scope (for -DryRun) and
# inside the per-client runspace that runs the actual KNX connection.
# ---------------------------------------------------------------------------
$HelpersText = @'
# Return a spaced uppercase hex string for a byte array (for logging).
function ConvertTo-HexSpaced {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }
    return ([System.BitConverter]::ToString($Bytes)).Replace('-', ' ')
}

# Return a continuous uppercase hex string for a byte array.
function ConvertTo-HexPacked {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }
    return ([System.BitConverter]::ToString($Bytes)).Replace('-', '')
}

# Build a KNXnet/IP HPAI. Route-back form 08 01 00 00 00 00 00 00: the interface
# replies to the UDP source socket, so we need not resolve the real local IP
# (unreliable behind multiple interfaces / NAT).
function New-HpaiRouteBack {
    return [byte[]]@(0x08, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
}

# Build a CONNECT_REQUEST (service 0x0205) for a tunnel connection.
function New-ConnectRequest {
    param([int]$KnxLayer, [byte[]]$Hpai)
    $hpai = if ($Hpai) { [byte[]]$Hpai } else { [byte[]](New-HpaiRouteBack) }
    $cri = [byte[]]@(0x04, 0x04, [byte]$KnxLayer, 0x00)   # len, TUNNEL_CONNECTION, layer, reserved
    $body = New-Object System.Collections.Generic.List[byte]
    $body.AddRange([byte[]]$hpai)   # HPAI control endpoint
    $body.AddRange([byte[]]$hpai)   # HPAI data endpoint
    $body.AddRange([byte[]]$cri)
    $totalLen = 6 + $body.Count
    $header = [byte[]]@(0x06, 0x10, 0x02, 0x05, [byte](($totalLen -shr 8) -band 0xFF), [byte]($totalLen -band 0xFF))
    $frame = New-Object System.Collections.Generic.List[byte]
    $frame.AddRange([byte[]]$header)
    $frame.AddRange([byte[]]$body)
    return , $frame.ToArray()
}

# Build a CONNECTIONSTATE_REQUEST (0x0207) or DISCONNECT_REQUEST (0x0209).
# Layout: header(6) + channelId(1) + reserved(1) + HPAI(8) = 16 bytes.
function New-ChannelRequest {
    param([int]$Service, [byte]$ChannelId, [byte[]]$Hpai)
    $hpai = if ($Hpai) { [byte[]]$Hpai } else { [byte[]](New-HpaiRouteBack) }
    $header = [byte[]]@(0x06, 0x10, [byte](($Service -shr 8) -band 0xFF), [byte]($Service -band 0xFF), 0x00, 0x10)
    $frame = New-Object System.Collections.Generic.List[byte]
    $frame.AddRange([byte[]]$header)
    $frame.Add($ChannelId)
    $frame.Add(0x00)
    $frame.AddRange([byte[]]$hpai)
    return , $frame.ToArray()
}

# Build a TUNNELING_ACK (0x0421) echoing the given channel + sequence.
function New-TunnelingAck {
    param([byte]$ChannelId, [byte]$Seq)
    return [byte[]]@(0x06, 0x10, 0x04, 0x21, 0x00, 0x0A, 0x04, $ChannelId, $Seq, 0x00)
}

# Validate an IPv4 dotted quad string.
function Test-DottedQuad {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { return $false }
    foreach ($o in $Value.Split('.')) { if ([int]$o -gt 255) { return $false } }
    return $true
}

# Minimal JSON string escaping (backslash + double-quote).
function ConvertTo-JsonStr {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    return ($Value -replace '\\', '\\' -replace '"', '\"')
}

# --- mDNS / DNS-SD discovery of OpenKNX devices (service _openknx._tcp) ------------------------------
# Pure .NET/UDP -- identical on Windows (PS 5.1), macOS and Linux (no dns-sd/avahi). Ported verbatim from
# OGM-Common OTA-Upload-Firmware-Generic.ps1 so both tools resolve devices the same way.

# Reads a (possibly compressed) DNS name from $bytes at $offset. Returns @{Name; Next}.
function Read-DnsName([byte[]]$bytes, [int]$offset) {
    $labels = @(); $jumped = $false; $next = $offset; $safety = 0
    while ($true) {
        if ($safety++ -gt 128 -or $offset -ge $bytes.Length) { break }
        $len = $bytes[$offset]
        if ($len -eq 0) { if (-not $jumped) { $next = $offset + 1 }; break }
        if (($len -band 0xC0) -eq 0xC0) {
            if ($offset + 1 -ge $bytes.Length) { break }
            $ptr = (($len -band 0x3F) -shl 8) -bor $bytes[$offset + 1]
            if (-not $jumped) { $next = $offset + 2 }
            $jumped = $true; $offset = $ptr; continue
        }
        $offset++
        if ($offset + $len -gt $bytes.Length) { break }
        $labels += [System.Text.Encoding]::UTF8.GetString($bytes, $offset, $len)
        $offset += $len
    }
    return @{ Name = ($labels -join '.'); Next = $next }
}

# Builds a single mDNS PTR query for $service (QU bit set for a unicast response).
function Build-MdnsQuery([string]$service) {
    $ms = New-Object System.IO.MemoryStream
    $w  = New-Object System.IO.BinaryWriter($ms)
    foreach ($v in @(0, 0, 1, 0, 0, 0)) { $w.Write([byte]($v -shr 8)); $w.Write([byte]($v -band 0xFF)) }
    foreach ($label in $service.Split('.')) {
        $b = [System.Text.Encoding]::UTF8.GetBytes($label)
        $w.Write([byte]$b.Length); $w.Write($b)
    }
    $w.Write([byte]0)
    $w.Write([byte]0); $w.Write([byte]12)
    $w.Write([byte]0x80); $w.Write([byte]0x01)
    $w.Flush()
    return $ms.ToArray()
}

# Discovers OpenKNX devices via mDNS. Returns objects {Name, Ip, Pa, Version, OtaPort, Chip, ...}.
function Get-OpenKnxDevices([int]$timeoutMs = 2500) {
    $query = Build-MdnsQuery "_openknx._tcp.local"
    $udp = New-Object System.Net.Sockets.UdpClient
    $out = @{}
    try {
        $udp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
        $udp.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)))
        $udp.Client.ReceiveTimeout = 350
        $mcast = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse("224.0.0.251"), 5353)
        [void]$udp.Send($query, $query.Length, $mcast)

        $ptr = @{}; $srv = @{}; $addr = @{}; $txt = @{}
        $deadline = (Get-Date).AddMilliseconds($timeoutMs)
        while ((Get-Date) -lt $deadline) {
            $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
            $buf = $null
            try { $buf = $udp.Receive([ref]$remote) } catch { continue }
            if (-not $buf -or $buf.Length -lt 12) { continue }
            $qd = ($buf[4] -shl 8) -bor $buf[5]
            $rr = (($buf[6] -shl 8) -bor $buf[7]) + (($buf[8] -shl 8) -bor $buf[9]) + (($buf[10] -shl 8) -bor $buf[11])
            $pos = 12
            for ($i = 0; $i -lt $qd; $i++) { $n = Read-DnsName $buf $pos; $pos = $n.Next + 4 }
            for ($i = 0; $i -lt $rr; $i++) {
                if ($pos + 10 -gt $buf.Length) { break }
                $nm = Read-DnsName $buf $pos; $pos = $nm.Next; $name = $nm.Name
                $type  = ($buf[$pos] -shl 8) -bor $buf[$pos + 1]
                $rdlen = ($buf[$pos + 8] -shl 8) -bor $buf[$pos + 9]
                $rdpos = $pos + 10
                if ($rdpos + $rdlen -gt $buf.Length) { break }
                switch ($type) {
                    12 { $t = Read-DnsName $buf $rdpos; $ptr[$t.Name] = $true }
                    33 { $srv[$name] = @{ Port = (($buf[$rdpos + 4] -shl 8) -bor $buf[$rdpos + 5]);
                                          Target = (Read-DnsName $buf ($rdpos + 6)).Name } }
                    1  { if ($rdlen -ge 4) { $addr[$name] = "$($buf[$rdpos]).$($buf[$rdpos+1]).$($buf[$rdpos+2]).$($buf[$rdpos+3])" } }
                    16 { $kv = @{}; $tp = $rdpos; $end = $rdpos + $rdlen
                         while ($tp -lt $end) {
                             $l = $buf[$tp]; $tp++
                             if ($l -eq 0 -or $tp + $l -gt $end) { break }
                             $item = [System.Text.Encoding]::UTF8.GetString($buf, $tp, $l); $tp += $l
                             $eq = $item.IndexOf('='); if ($eq -ge 0) { $kv[$item.Substring(0, $eq)] = $item.Substring($eq + 1) }
                         }
                         $txt[$name] = $kv }
                }
                $pos = $rdpos + $rdlen
            }
        }
        foreach ($inst in @($ptr.Keys + $srv.Keys | Sort-Object -Unique)) {
            $targetHost = if ($srv.ContainsKey($inst)) { $srv[$inst].Target } else { $null }
            $ip = if ($targetHost -and $addr.ContainsKey($targetHost)) { $addr[$targetHost] } else { $targetHost }
            if (-not $ip) { continue }
            $tx = if ($txt.ContainsKey($inst)) { $txt[$inst] } else { @{} }
            $otaPort = $tx['ota']
            $chip = if ($otaPort -eq '3232') { 'ESP32' } elseif ($otaPort -eq '2040') { 'RP2040/RP2350' } else { '' }
            $out[$inst] = [PSCustomObject]@{
                Name = ($inst -replace '\._openknx\._tcp\.local\.?$', '')
                Ip = $ip; Pa = $tx['address']; Version = $tx['version']; OtaPort = $otaPort; Chip = $chip
                Configured = $tx['configured']; Firmware = $tx['firmware']; Serial = $tx['serial']; OtaMode = $tx['otamode']
            }
        }
    } catch {
    } finally {
        $udp.Close()
    }
    return @($out.Values | Sort-Object Name)
}

# --- Standard KNXnet/IP discovery (SEARCH_REQUEST -> SEARCH_RESPONSE) -------------------------------
# Finds ANY KNXnet/IP router/interface (Siemens, MDT, ...), not just OpenKNX. Multicast SEARCH to
# 224.0.23.12:3671; responses carry the control-endpoint HPAI, the KNX individual address, the friendly
# name, and the supported service families (0x05 ROUTING -> router, 0x04 TUNNELLING -> interface).
function Get-KnxNetIpDevices([int]$timeoutMs = 1800) {
    $out = @{}
    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        $udp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
        $udp.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)))
        $udp.Client.ReceiveTimeout = 300
        $localPort = ([System.Net.IPEndPoint]$udp.Client.LocalEndPoint).Port
        # local IP on the multicast-routing interface (connect() only resolves the route, sends nothing)
        $probe = New-Object System.Net.Sockets.Socket([System.Net.Sockets.AddressFamily]::InterNetwork, [System.Net.Sockets.SocketType]::Dgram, [System.Net.Sockets.ProtocolType]::Udp)
        try { $probe.Connect((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse('224.0.23.12'), 3671))); $lip = ([System.Net.IPEndPoint]$probe.LocalEndPoint).Address.GetAddressBytes() }
        finally { $probe.Close() }
        # force the multicast SEARCH out the KNX-LAN interface (essential on multi-homed hosts; harmless otherwise)
        try { $udp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::IP, [System.Net.Sockets.SocketOptionName]::MulticastInterface, [System.BitConverter]::ToInt32($lip, 0)) } catch {}
        $hpai = [byte[]]@(0x08, 0x01, $lip[0], $lip[1], $lip[2], $lip[3], [byte](($localPort -shr 8) -band 0xFF), [byte]($localPort -band 0xFF))
        $search = [byte[]]@(0x06, 0x10, 0x02, 0x01, 0x00, 0x0E) + $hpai
        $mcast = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse('224.0.23.12'), 3671)
        [void]$udp.Send($search, $search.Length, $mcast)

        $deadline = (Get-Date).AddMilliseconds($timeoutMs)
        while ((Get-Date) -lt $deadline) {
            $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
            $buf = $null
            try { $buf = $udp.Receive([ref]$remote) } catch { continue }
            if (-not $buf -or $buf.Length -lt 68) { continue }
            $svc = ([int]$buf[2] -shl 8) -bor [int]$buf[3]                      # [int] cast: [byte] -shl 8 overflows to 0
            if ($svc -ne 0x0202) { continue }                                  # SEARCH_RESPONSE only
            $ctrlIp   = "$($buf[8]).$($buf[9]).$($buf[10]).$($buf[11])"          # control-endpoint HPAI
            $ctrlPort = ([int]$buf[12] -shl 8) -bor [int]$buf[13]
            $di = 14                                                            # device-info DIB
            $pa = "{0}.{1}.{2}" -f ($buf[$di + 4] -shr 4), ($buf[$di + 4] -band 0x0F), $buf[$di + 5]
            $name = ([System.Text.Encoding]::ASCII.GetString($buf[($di + 24)..($di + 53)]) -split "`0")[0].Trim()
            $kind = ''                                                          # from supported service families DIB
            $sf = $di + $buf[$di]
            if ($sf + 1 -lt $buf.Length -and $buf[$sf + 1] -eq 0x02) {
                $end = $sf + $buf[$sf]; $p = $sf + 2; $rt = $false; $tn = $false
                while ($p + 1 -lt $end -and $p + 1 -lt $buf.Length) { if ($buf[$p] -eq 0x05) { $rt = $true }; if ($buf[$p] -eq 0x04) { $tn = $true }; $p += 2 }
                $kind = if ($rt) { 'router' } elseif ($tn) { 'interface' } else { '' }
            }
            $ip = if ($ctrlIp -ne '0.0.0.0') { $ctrlIp } else { $remote.Address.ToString() }
            $out[$ip] = [PSCustomObject]@{
                Name = $name; Ip = $ip; Pa = $pa; Port = $ctrlPort; Kind = $kind; Chip = ''; Version = ''
                Source = 'knxip'; OtaMode = ''; Configured = ''; Firmware = ''
            }
        }
    } catch {
    } finally {
        $udp.Close()
    }
    return @($out.Values)
}

# Merges OpenKNX (mDNS, rich detail) with all KNXnet/IP devices (SEARCH), deduped by IP.
function Get-AllDevices {
    $byIp = @{}
    foreach ($d in @(Get-KnxNetIpDevices 1800)) { if ($d.Ip) { $byIp[$d.Ip] = $d } }
    foreach ($d in @(Get-OpenKnxDevices 2500)) {
        if (-not $d.Ip) { continue }
        if ($byIp.ContainsKey($d.Ip)) {
            $e = $byIp[$d.Ip]                                                    # same box seen by both -> enrich
            $e.Chip = $d.Chip; $e.Version = $d.Version; $e.OtaMode = $d.OtaMode; $e.Configured = $d.Configured; $e.Firmware = $d.Firmware
            if ($d.Name) { $e.Name = $d.Name }
            if (-not $e.Pa) { $e.Pa = $d.Pa }
            $e.Source = 'both'
        } else {
            $byIp[$d.Ip] = [PSCustomObject]@{
                Name = $d.Name; Ip = $d.Ip; Pa = $d.Pa; Port = 3671; Kind = ''; Chip = $d.Chip; Version = $d.Version
                Source = 'openknx'; OtaMode = $d.OtaMode; Configured = $d.Configured; Firmware = $d.Firmware
            }
        }
    }
    return @($byIp.Values | Sort-Object Name)
}

# Serialises discovered devices to a JSON array string (5.1-safe: manual build, lowercase keys the UI expects).
function ConvertTo-DevicesJson($devices) {
    if ($null -eq $devices) { return '[]' }
    $items = @()
    foreach ($d in @($devices)) {
        $items += ('{{"name":"{0}","ip":"{1}","pa":"{2}","version":"{3}","chip":"{4}","kind":"{5}","source":"{6}","otamode":"{7}","configured":"{8}","firmware":"{9}"}}' -f `
            (ConvertTo-JsonStr ([string]$d.Name)), (ConvertTo-JsonStr ([string]$d.Ip)), (ConvertTo-JsonStr ([string]$d.Pa)), `
            (ConvertTo-JsonStr ([string]$d.Version)), (ConvertTo-JsonStr ([string]$d.Chip)), (ConvertTo-JsonStr ([string]$d.Kind)), `
            (ConvertTo-JsonStr ([string]$d.Source)), (ConvertTo-JsonStr ([string]$d.OtaMode)), `
            (ConvertTo-JsonStr ([string]$d.Configured)), (ConvertTo-JsonStr ([string]$d.Firmware)))
    }
    return '[' + ($items -join ',') + ']'
}
'@

# Load helpers into this scope (needed for -DryRun).
. ([scriptblock]::Create($HelpersText))

$CliLayer = if ($LinkLayer) { 0x02 } else { 0x80 }   # CLI default; per-request query can override

# ---------------------------------------------------------------------------
# DryRun: print the wire bytes and exit (no network, no hardware)
# ---------------------------------------------------------------------------
if ($DryRun) {
    $modeName = if ($LinkLayer) { 'LinkLayer' } else { 'Busmonitor' }
    $connect = New-ConnectRequest -KnxLayer $CliLayer
    $hpai = New-HpaiRouteBack
    $cri  = [byte[]]@(0x04, 0x04, [byte]$CliLayer, 0x00)

    Write-Host ''
    OpenKNX_ShowLogo 'Start-BusmonBridge - DryRun (KNXnet/IP Busmonitor)'
    Write-Host ("Mode            : {0} (KNX layer 0x{1:X2})" -f $modeName, $CliLayer)
    Write-Host ("Default target  : {0}:{1}" -f ($(if ($Ip) { $Ip } else { '<none>' }), $Port))
    Write-Host ("HTTP/SSE port   : {0}  (endpoint http://localhost:{0}/stream?ip=<knxIp>&port={1})" -f $HttpPort, $Port)
    Write-Host ''
    Write-Host ("HPAI (route-back): {0}" -f (ConvertTo-HexSpaced $hpai))
    Write-Host ("CRI              : {0}" -f (ConvertTo-HexSpaced $cri))
    Write-Host ''
    Write-Host ("CONNECT_REQUEST (spaced): {0}" -f (ConvertTo-HexSpaced $connect))
    Write-Host ("CONNECT_REQUEST (packed): {0}" -f (ConvertTo-HexPacked $connect))
    Write-Host ''
    exit 0
}

# ---------------------------------------------------------------------------
# Shared state (thread-safe) between the main thread and the HTTP runspace
# ---------------------------------------------------------------------------
$State = [hashtable]::Synchronized(@{
    Running   = $true
    HttpUp    = $false
    DefaultIp = $Ip
    DefaultPt = $Port
    CliLayer  = $CliLayer
    # thread-safe message queue: per-client runspaces enqueue connect/disconnect/discover lines,
    # the main loop drains it and writes them to the console (Write-Host from a child runspace is not shown).
    Log       = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
})

# ---------------------------------------------------------------------------
# Per-client SSE + KNX handler.
# Opens the KNX busmon connection on demand from the query string, streams its
# frames to this one SSE client, and tears the KNX connection down on disconnect.
# ---------------------------------------------------------------------------
$clientScript = {
    param($ctx, $State, $HelpersText)
    . ([scriptblock]::Create($HelpersText))

    $resp = $ctx.Response
    $out = $null
    $udp = $null
    $remote = $null
    $channelId = [byte]0
    $connected = $false
    $enc = [System.Text.Encoding]::UTF8

    $writeStr = {
        param($s)
        $b = $enc.GetBytes($s)
        $out.Write($b, 0, $b.Length)
        $out.Flush()
    }

    try {
        $path = $ctx.Request.Url.AbsolutePath

        # -- /discover : one-shot mDNS scan for OpenKNX devices -> JSON array ------
        if ($path -eq '/discover') {
            $resp.StatusCode = 200
            $resp.ContentType = 'application/json'
            try { $resp.Headers.Add('Access-Control-Allow-Origin', '*') } catch {}
            $devices = @()
            try { $devices = Get-AllDevices } catch {}
            $json = ConvertTo-DevicesJson $devices
            $b = $enc.GetBytes($json)
            $resp.OutputStream.Write($b, 0, $b.Length)
            $resp.OutputStream.Flush()
            $resp.Close()
            $State.Log.Enqueue("[discover] scan -> $($devices.Count) KNX-IP device(s) (mDNS + KNXnet/IP SEARCH)")
            return
        }

        if ($path -ne '/stream') {
            $resp.StatusCode = 404
            $resp.Close()
            return
        }

        # SSE response headers.
        $resp.StatusCode = 200
        $resp.SendChunked = $true
        $resp.ContentType = 'text/event-stream'
        try { $resp.Headers.Add('Cache-Control', 'no-cache') } catch {}
        try { $resp.Headers.Add('Access-Control-Allow-Origin', '*') } catch {}
        $resp.KeepAlive = $true
        try { $resp.Headers.Add('Connection', 'keep-alive') } catch {}
        $out = $resp.OutputStream

        # -- Parse + validate query (HttpListener.QueryString is already URL-decoded) --
        $qs = $ctx.Request.QueryString
        $ip = $qs['ip']
        if ([string]::IsNullOrWhiteSpace($ip)) { $ip = $State.DefaultIp }
        $ip = [string]$ip

        $portRaw = $qs['port']
        $port = [int]$State.DefaultPt
        if (-not [string]::IsNullOrWhiteSpace($portRaw)) {
            $parsed = 0
            if (-not [int]::TryParse($portRaw, [ref]$parsed)) {
                & $writeStr "event: error`ndata: {""msg"":""invalid port""}`n`n"
                $resp.Close(); return
            }
            $port = $parsed
        }

        $layerRaw = $qs['layer']
        $layer = [int]$State.CliLayer
        if (-not [string]::IsNullOrWhiteSpace($layerRaw)) {
            switch ($layerRaw.ToLowerInvariant()) {
                'link'   { $layer = 0x02 }
                'busmon' { $layer = 0x80 }
                default  {
                    & $writeStr "event: error`ndata: {""msg"":""invalid layer (use busmon|link)""}`n`n"
                    $resp.Close(); return
                }
            }
        }
        $forwardAll = ($layer -eq 0x02)
        $modeName = if ($forwardAll) { 'LinkLayer' } else { 'Busmonitor' }

        if (-not (Test-DottedQuad $ip)) {
            $msg = ConvertTo-JsonStr ("invalid or missing ip: '$ip'")
            & $writeStr "event: error`ndata: {""msg"":""$msg""}`n`n"
            $resp.Close(); return
        }
        if ($port -lt 1 -or $port -gt 65535) {
            & $writeStr "event: error`ndata: {""msg"":""port out of range (1-65535)""}`n`n"
            $resp.Close(); return
        }

        # -- Open UDP + CONNECT handshake to the chosen target --------------
        try {
            $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($ip), $port)
            $udp = [System.Net.Sockets.UdpClient]::new(0)   # bind ephemeral local port
            $udp.Connect($remote)                            # bind local endpoint to the real source IP for this route
            $udp.Client.ReceiveTimeout = 5000
            # real local HPAI (Siemens & others require the actual control endpoint in CONNECTIONSTATE, not route-back)
            $le  = [System.Net.IPEndPoint]$udp.Client.LocalEndPoint
            $ipb = $le.Address.GetAddressBytes()
            $localHpai = [byte[]]@(0x08, 0x01, $ipb[0], $ipb[1], $ipb[2], $ipb[3], [byte](([int]$le.Port -shr 8) -band 0xFF), [byte]([int]$le.Port -band 0xFF))
            $connect = New-ConnectRequest -KnxLayer $layer -Hpai $localHpai
            [void]$udp.Send($connect, $connect.Length)

            $rref = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            $cr = $udp.Receive([ref]$rref)
        } catch {
            $msg = ConvertTo-JsonStr ("connect failed: $($_.Exception.Message)")
            try { & $writeStr "event: error`ndata: {""msg"":""$msg""}`n`n" } catch {}
            if ($null -ne $udp) { try { $udp.Close() } catch {} }
            try { $resp.Close() } catch {}
            return
        }

        $svc = ([int]$cr[2] -shl 8) -bor [int]$cr[3]
        if ($svc -ne 0x0206) {
            $dbg = (($cr[0..([Math]::Min(23,$cr.Length-1))] | ForEach-Object { $_.ToString('X2') }) -join ' ')
            $msg = ConvertTo-JsonStr ("unexpected response service 0x{0:X4} len={1} raw=[{2}]" -f $svc, $cr.Length, $dbg)
            try { & $writeStr "event: error`ndata: {""msg"":""$msg""}`n`n" } catch {}
            try { $udp.Close() } catch {}
            try { $resp.Close() } catch {}
            return
        }
        $channelId = $cr[6]
        $status = $cr[7]
        if ($status -ne 0x00) {
            $msg = ConvertTo-JsonStr ("CONNECT_RESPONSE status 0x{0:X2} (refused; busmon in use / unsupported?)" -f $status)
            try { & $writeStr "event: error`ndata: {""msg"":""$msg""}`n`n" } catch {}
            try { $udp.Close() } catch {}
            try { $resp.Close() } catch {}
            return
        }
        $connected = $true

        # Hello event (iface reflects the live, query-chosen target).
        $ifaceJson = ConvertTo-JsonStr ("$($ip):$($port)")
        & $writeStr "event: hello`ndata: {""mode"":""$modeName"",""iface"":""$ifaceJson""}`n`n"

        # Tell the console a browser attached to this router / interface.
        $State.Log.Enqueue("[connect] browser -> $modeName $($ip):$($port) (channel $channelId)")

        # -- Main receive loop ---------------------------------------------
        $udp.Client.ReceiveTimeout = 250   # short: the loop notices $State.Running=$false (Ctrl+C) within 250ms and reaches its DISCONNECT in `finally` before the shutdown grace elapses
        $lastConnState = [DateTime]::UtcNow
        $lastPing = [DateTime]::UtcNow

        while ($State.Running) {

            # 60s CONNECTIONSTATE_REQUEST keepalive to the interface.
            if (([DateTime]::UtcNow - $lastConnState).TotalSeconds -ge 60) {
                try {
                    $cs = New-ChannelRequest -Service 0x0207 -ChannelId $channelId -Hpai $localHpai
                    [void]$udp.Send($cs, $cs.Length)
                } catch {}
                $lastConnState = [DateTime]::UtcNow
            }

            $buf = $null
            try {
                $buf = $udp.Receive([ref]$rref)
            } catch [System.Net.Sockets.SocketException] {
                # Receive timeout -> emit SSE keepalive (also detects browser disconnect).
                if (([DateTime]::UtcNow - $lastPing).TotalSeconds -ge 4) {
                    & $writeStr ": ping`n`n"
                    $lastPing = [DateTime]::UtcNow
                }
                continue
            }
            if ($null -eq $buf -or $buf.Length -lt 4) { continue }

            $svc = ([int]$buf[2] -shl 8) -bor [int]$buf[3]

            if ($svc -eq 0x0420) {
                # TUNNELING_REQUEST: header(6) + connHeader(4) + cEMI
                if ($buf.Length -lt 11) { continue }
                $reqChannel = $buf[7]
                $seq = $buf[8]
                $cemiLen = $buf.Length - 10
                $cemi = New-Object byte[] $cemiLen
                [System.Array]::Copy($buf, 10, $cemi, 0, $cemiLen)

                # Always ACK (echo sequence), even for duplicates.
                try {
                    $ack = New-TunnelingAck -ChannelId $reqChannel -Seq $seq
                    [void]$udp.Send($ack, $ack.Length)
                } catch {}

                # Forward L_Busmon.ind (0x2B); in LinkLayer mode forward everything.
                if ($forwardAll -or ($cemiLen -gt 0 -and $cemi[0] -eq 0x2B)) {
                    $hex = ConvertTo-HexPacked $cemi
                    $ts = [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                    & $writeStr "data: {""hex"":""$hex"",""ts"":$ts}`n`n"
                }
            }
            elseif ($svc -eq 0x0208) {
                # CONNECTIONSTATE_RESPONSE
                if ($buf.Length -ge 8 -and $buf[7] -ne 0x00) {
                    # Non-zero status: interface reports a problem; keep going (best effort).
                }
            }
            elseif ($svc -eq 0x0209) {
                # DISCONNECT_REQUEST from interface -> reply and stop this client.
                try {
                    $dr = [byte[]]@(0x06, 0x10, 0x02, 0x0A, 0x00, 0x08, $channelId, 0x00)
                    [void]$udp.Send($dr, $dr.Length)
                } catch {}
                break
            }

            # Periodic SSE keepalive even under steady traffic.
            if (([DateTime]::UtcNow - $lastPing).TotalSeconds -ge 4) {
                & $writeStr ": ping`n`n"
                $lastPing = [DateTime]::UtcNow
            }
        }
    }
    catch {
        # Browser disconnect (write failure) or fatal error -> fall through to teardown.
    }
    finally {
        # Tear down the KNX connection for this client.
        if ($connected -and $null -ne $udp -and $null -ne $remote) {
            try {
                $disc = New-ChannelRequest -Service 0x0209 -ChannelId $channelId -Hpai $localHpai
                [void]$udp.Send($disc, $disc.Length)
            } catch {}
            try { $State.Log.Enqueue("[disconnect] browser x $($ip):$($port)") } catch {}
        }
        if ($null -ne $udp) { try { $udp.Close() } catch {} }
        try { $resp.Close() } catch {}
    }
}

# ---------------------------------------------------------------------------
# HTTP listener runspace: accept SSE clients, hand each to its own runspace.
# ---------------------------------------------------------------------------
$httpScript = {
    param($HttpPort, $State, $HelpersText, $ClientScriptText)

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("http://localhost:$HttpPort/")
    try {
        $listener.Start()
        $State['HttpUp'] = $true
    } catch {
        Write-Warning "HTTP listener failed to start on http://localhost:$HttpPort/ : $($_.Exception.Message)"
        Write-Warning "On Windows a URL-ACL may be required: netsh http add urlacl url=http://localhost:$HttpPort/ user=Everyone (or run elevated)."
        $State['Running'] = $false
        return
    }

    $clients = New-Object System.Collections.Generic.List[object]
    try {
        while ($State.Running) {
            $task = $listener.GetContextAsync()
            $ar = [System.IAsyncResult]$task
            while (-not $ar.AsyncWaitHandle.WaitOne(200)) {
                if (-not $State.Running) { break }
            }
            if (-not $State.Running) { break }
            if (-not $task.IsCompleted) { continue }

            $ctx = $task.Result

            # Serve this client (KNX connect + SSE stream) on its own runspace,
            # so concurrent clients / devices are supported.
            $ps = [powershell]::Create()
            $rs = [runspacefactory]::CreateRunspace()
            $rs.Open()
            $ps.Runspace = $rs
            [void]$ps.AddScript($ClientScriptText)
            [void]$ps.AddArgument($ctx)
            [void]$ps.AddArgument($State)
            [void]$ps.AddArgument($HelpersText)
            [void]$ps.BeginInvoke()
            $clients.Add([pscustomobject]@{ PS = $ps; RS = $rs })

            # Opportunistic cleanup of finished client runspaces.
            if ($clients.Count -gt 8) {
                for ($i = $clients.Count - 1; $i -ge 0; $i--) {
                    if ($clients[$i].PS.InvocationStateInfo.State -ne 'Running') {
                        try { $clients[$i].PS.Dispose() } catch {}
                        try { $clients[$i].RS.Dispose() } catch {}
                        $clients.RemoveAt($i)
                    }
                }
            }
        }
    } catch {
        # Listener stopped -> exit.
    } finally {
        try { $listener.Stop() } catch {}
        try { $listener.Close() } catch {}
        foreach ($c in $clients) {
            try { $c.PS.Dispose() } catch {}
            try { $c.RS.Dispose() } catch {}
        }
    }
}

$httpPs = [powershell]::Create()
$httpRs = [runspacefactory]::CreateRunspace()
$httpRs.Open()
$httpPs.Runspace = $httpRs
[void]$httpPs.AddScript($httpScript.ToString())
[void]$httpPs.AddArgument($HttpPort)
[void]$httpPs.AddArgument($State)
[void]$httpPs.AddArgument($HelpersText)
[void]$httpPs.AddArgument($clientScript.ToString())
$httpHandle = $httpPs.BeginInvoke()

# ---------------------------------------------------------------------------
# Banner + idle wait (graceful shutdown on Ctrl+C)
# ---------------------------------------------------------------------------
$cancelHandler = {
    param($s, $e)
    $e.Cancel = $true
    $State['Running'] = $false
}
[Console]::add_CancelKeyPress($cancelHandler)

# Give the listener a moment to bind, then print the banner.
Start-Sleep -Milliseconds 300
Write-Host ''
OpenKNX_ShowLogo 'Start-BusmonBridge - KNXnet/IP Busmonitor -> SSE'
if ($Ip) { Write-Host ("Default target: {0}:{1} (used when query omits ip/port)" -f $Ip, $Port) }
else     { Write-Host  'Default target: <none> (the webpage must supply ?ip=...)' }
Write-Host ("CLI default layer: {0}" -f $(if ($LinkLayer) { 'LinkLayer (0x02)' } else { 'Busmonitor (0x80)' }))
Write-Host ("Bridge up - open BusmonViewer, Connect live -> http://localhost:{0}/stream?ip=<knxIp>&port={1}" -f $HttpPort, $Port) -ForegroundColor Yellow
Write-Host "Press 'X' or Ctrl+C to stop."
Write-Host ''

# Open the BusmonViewer page in the default browser (unless -NoBrowser). $IsWindows/$IsMacOS are PS7-only,
# so probe the major version first -- Windows PowerShell 5.1 is always Windows.
if (-not $NoBrowser) {
    $htmlPath = Join-Path $PSScriptRoot 'BusmonViewer.html'
    if (Test-Path $htmlPath) {
        $onWindows = $true; $onMac = $false
        if ($PSVersionTable.PSVersion.Major -ge 6) { $onWindows = $IsWindows; $onMac = $IsMacOS }
        try {
            if     ($onWindows) { Start-Process -FilePath $htmlPath }
            elseif ($onMac)     { & open $htmlPath }
            else                { & xdg-open $htmlPath }
            Write-Host ("Opened {0} in the default browser." -f $htmlPath) -ForegroundColor DarkGray
        } catch { Write-Host ("Could not auto-open a browser -- open it manually: {0}" -f $htmlPath) -ForegroundColor Yellow }
    }
}

try {
    while ($State.Running) {
        Start-Sleep -Milliseconds 200
        # 'X' for a clean exit (in addition to Ctrl+C). KeyAvailable throws if stdin is redirected -> guard.
        try { if ([Console]::KeyAvailable) { if (([Console]::ReadKey($true)).Key -eq 'X') { $State['Running'] = $false } } } catch { }
        # Drain connect/disconnect/discover messages from the client runspaces to the console.
        while ($State.Log.Count -gt 0) {
            $line = [string]$State.Log.Dequeue()
            if     ($line.StartsWith('[connect]'))    { Write-Host $line -ForegroundColor Green }
            elseif ($line.StartsWith('[disconnect]')) { Write-Host $line -ForegroundColor DarkGray }
            else                                      { Write-Host $line -ForegroundColor Cyan }
        }
        # If the HTTP runspace died (e.g. bind failure), stop.
        if ($httpHandle.IsCompleted -and $State.Running) {
            $State['Running'] = $false
        }
    }
}
finally {
    $State['Running'] = $false
    try { [Console]::remove_CancelKeyPress($cancelHandler) } catch {}

    # Let the HTTP runspace exit its accept loop, then dispose.
    Start-Sleep -Milliseconds 800
    try { $httpPs.Stop() } catch {}
    try { [void]$httpPs.EndInvoke($httpHandle) } catch {}
    try { $httpPs.Dispose() } catch {}
    try { $httpRs.Dispose() } catch {}

    Write-Host 'Bridge stopped.' -ForegroundColor Cyan
}
