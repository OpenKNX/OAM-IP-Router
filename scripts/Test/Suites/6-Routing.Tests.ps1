#!/usr/bin/env pwsh
# Open ■
# ┬────┴  6-Routing.Tests
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/Suites/6-Routing.Tests.ps1

<#
.SYNOPSIS
    TSSH section 6 - Routing. Full coverage for a router; a MUST-NOT check for an interface.

.DESCRIPTION
    Dot-sourced by Invoke-Conformance.ps1, which then calls Invoke-KnxSuiteRouting.

    For an INTERFACE this section is not "not applicable" - it is a negative test. The
    device must not advertise the ROUTING service family and must not act on a
    ROUTING_INDICATION. That property is what makes its hardware busmonitor permissible
    at all (03_08_04 section 2.2.4), so it is verified actively rather than assumed.

    SAFETY: these cases put traffic on a multicast group. Invoke-Conformance.ps1 refuses
    to run this suite on the production group; the suite additionally re-checks it here,
    because a suite that can be dot-sourced directly must carry its own guard.
#>

Set-StrictMode -Version Latest
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/KnxDevice.psm1') -Force -DisableNameChecking

$script:ProductionMulticastGroup = '224.0.23.12'

function Send-RoutingIndication {
    <#
    .SYNOPSIS
        Sends a ROUTING_INDICATION to the multicast group and returns the socket used.
    #>
    param([string]$Group, [int]$Port, [byte[]]$Cemi)
    $s = New-KnxSocket -TimeoutMs 1500
    try {
        $f = New-KnxRoutingIndication -Cemi $Cemi
        Send-KnxFrame -Socket $s -Frame $f -Ip $Group -Port $Port
        return $f
    }
    finally { $s.Dispose() }
}

function Get-RoutingCounter {
    <#
    .SYNOPSIS
        Reads one of the routing message counters from the KNXnet/IP parameter object.
    #>
    param($Connection, [int]$PropertyId)
    $K = Get-KnxConstants
    $r = Read-KnxProperty -Connection $Connection -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $PropertyId
    if ($null -eq $r.Parsed -or $r.Parsed.IsError) { return -1 }
    $d = $r.Parsed.Data
    # PID 74/75 are PDT_UNSIGNED_LONG (4 octets), PID 72/73 PDT_UNSIGNED_INT: reading two octets of a long gave its high word.
    if ($d.Length -ge 4) { return ([long]$d[0] * 16777216) + ([long]$d[1] * 65536) + ([long]$d[2] * 256) + [long]$d[3] }
    if ($d.Length -ge 2) { return (Get-Uint16 -Bytes $d -Offset 0) }
    if ($d.Length -eq 1) { return [int]$d[0] }
    return -1
}

function Find-KnxLineRouters {
    <#
    .SYNOPSIS
        KNXnet/IP routers on a routing group found by SEARCH, flagged when they couple to a given line (same area.line).
    .DESCRIPTION
        A router on the same group and line routes a ROUTING_INDICATION onto that line, so a copy seen there is not
        by itself the device under test. Discovery runs on 224.0.23.12 (03_08_02 8.5.2.1), three times. Returns
        Routers (one entry per PA) and DutAnswered: whether $ExcludeIp answered, i.e. multicast from here reaches it.
    #>
    param([Parameter(Mandatory)][string]$ExcludeIp, [Parameter(Mandatory)][string]$Group, [Parameter(Mandatory)][string]$Line, [int]$Port = 3671)
    $K = Get-KnxConstants
    $found = @{}
    $dut = $false
    $s = New-KnxSocket -TimeoutMs 500
    try {
        $f = New-KnxSearchRequest -DiscoveryIp (Get-LocalEndpointFor -DestinationIp '224.0.23.12') -DiscoveryPort (Get-SocketLocalPort -Socket $s)
        foreach ($try in 1..3) {   # a device can miss discovery for seconds (see 3-Core H-3.5.x)
            Send-KnxFrame -Socket $s -Frame $f -Ip '224.0.23.12' -Port $Port
            $deadline = [DateTime]::UtcNow.AddMilliseconds(2000)
            while ([DateTime]::UtcNow -lt $deadline) {
                $pkt = Receive-KnxFrame -Socket $s -TimeoutMs ([int][Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
                if ($null -eq $pkt) { break }
                $h = Read-KnxHeader -Frame $pkt.Bytes
                if ($null -eq $h -or $h.Service -ne $K.Service.SEARCH_RESPONSE -or $h.Body.Length -le 8) { continue }
                $from = ($pkt.From -split ':')[0]
                if ($from -eq $ExcludeIp) { $dut = $true; continue }
                $dev = $null; $routing = $false
                foreach ($d in (Read-KnxDibs -Body $h.Body -Offset 8)) {
                    if ($d.Type -eq 0x01) { $dev = $d.Decoded }
                    if ($d.Type -eq 0x02 -and $null -ne $d.Decoded) { foreach ($fam in @($d.Decoded)) { if ($fam.Id -eq $K.Family.ROUTING) { $routing = $true } } }
                }
                if ($null -eq $dev -or -not $routing -or $dev.MulticastAddr -ne $Group) { continue }
                # One entry per PA: a router answering from two addresses would count its telegrams twice.
                if ($found.ContainsKey($dev.IndividualAddr)) { continue }
                $parts = $dev.IndividualAddr -split '\.'
                $found[$dev.IndividualAddr] = [pscustomobject]@{ Ip = $from; Pa = $dev.IndividualAddr; Name = $dev.FriendlyName; SameLine = ("$($parts[0]).$($parts[1])" -eq $Line) }
            }
        }
    }
    finally { $s.Dispose() }
    [pscustomobject]@{ Routers = @($found.Values); DutAnswered = $dut }
}


# ── IP system broadcast (03_02_06 4.1.3, behaviour verified by 08_TSSK 2.4.3 / 2.4.4) ──────────────

$script:SystemSetupMulticastGroup = '224.0.23.12'

function Set-KnxIpSbcMode {
    <#
    .SYNOPSIS
        Writes the IP System Broadcast Routing Mode of a router and reads it back.
    .DESCRIPTION
        PID_IP_SBC_CONTROL (120) on the router object is a function property: 03_05_01 4.5.16.1 puts a
        reserved octet first, then the ServiceID, then the mode. Returns the mode the device reports, or
        -1 when it did not answer.
    #>
    param([Parameter(Mandatory)]$Connection, [Parameter(Mandatory)][int]$Mode)
    $write = [byte[]]@(0xF8, 0x00, 0x06, 0x01, 0x78, 0x00, 0x00, ($Mode -band 0xFF))
    [void](Send-KnxDeviceConfiguration -Connection $Connection -Cemi $write)
    $read = [byte[]]@(0xF9, 0x00, 0x06, 0x01, 0x78, 0x00, 0x00)
    $r = Send-KnxDeviceConfiguration -Connection $Connection -Cemi $read
    if ($r -and $r.Cemi -and $r.Cemi.Length -ge 8) { return [int]$r.Cemi[7] }
    return -1
}

function Get-KnxSystemBroadcastEcho {
    <#
    .SYNOPSIS
        Puts one system broadcast on TP through a second interface and reports how the router relayed it.
    .DESCRIPTION
        A_SystemNetworkParameter_Read object type 0, PID 11, operand 1, the first stimulus of 08_TSSK 2.4.3 p.163, sent
        with the system-broadcast bit of control field 1 cleared. Returns the service types and frames seen on the
        system setup group that carry this request.
    #>
    param([Parameter(Mandatory)][string]$InjectorIp, [string]$DeviceIp = '', [string]$RoutingGroup = '', [int]$Port = 3671, [int]$CollectMs = 2000)
    $marker = [byte[]]@(0x01, 0xC8, 0x00, 0x00, 0x00, 0xB0, 0x01)   # TPCI/APCI A_SystemNetworkParameter_Read, 0 / 11 / 1
    $seen = @()
    $mc = New-KnxMulticastSocket -Group $script:SystemSetupMulticastGroup -Port $Port -TimeoutMs 400
    try {
        # With the mode off the telegram is relayed as a plain routing indication, and a router sends
        # those to its CONFIGURED group (PID_ROUTING_MULTICAST_ADDRESS), not to the system setup group.
        # Listening on the system setup group alone made K-2.4.4 fail against a correct router.
        $groupAddr = $null
        if ($RoutingGroup -and $RoutingGroup -ne $script:SystemSetupMulticastGroup -and
            [System.Net.IPAddress]::TryParse($RoutingGroup, [ref]$groupAddr)) {
            $extra = New-Object System.Net.Sockets.MulticastOption($groupAddr)
            $mc.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::IP, [System.Net.Sockets.SocketOptionName]::AddMembership, $extra)
        }
        $buf = New-Object byte[] 1024
        for ($i = 0; $i -lt 40; $i++) { try { [void]$mc.Receive($buf) } catch { break } }

        $tun = Open-KnxConnection -Ip $InjectorIp -ConnectionType 0x04 -Layer 0x02
        if (-not $tun.Ok) { return $null }
        try {
            $cemi = New-CemiLData -MessageCode 0x11 -Source 0 -Destination 0 -IsGroup -Tpdu $marker -HopCount 6
            $cemi[2] = [byte]($cemi[2] -band 0xEF)   # control field 1 bit 4 = 0: system broadcast (New-CemiLData sets a normal one)
            [void](Send-KnxTunnelCemi -Connection $tun -Cemi $cemi)
        }
        finally { Close-KnxConnection -Connection $tun | Out-Null }

        $deadline = [DateTime]::UtcNow.AddMilliseconds($CollectMs)
        # ReceiveFrom, not Receive: the marker only says which telegram this is, not who relayed it. Any
        # other router bridging the same TP line onto this group - and -TrafficIp is one such device by
        # definition - would otherwise be counted as the device under test.
        $any = [System.Net.EndPoint](New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0))
        while ([DateTime]::UtcNow -lt $deadline) {
            $from = $any
            try { $n = $mc.ReceiveFrom($buf, [ref]$from) } catch { continue }
            if ($n -lt 6) { continue }
            if ($DeviceIp -and ([System.Net.IPEndPoint]$from).Address.ToString() -ne $DeviceIp) { continue }
            # A byte shifted left by 8 is 0 in PowerShell, so the service type is assembled by arithmetic.
            $svc = ([int]$buf[2] * 256) + [int]$buf[3]
            $pkt = $buf[0..($n - 1)]
            for ($k = 0; $k -le $n - $marker.Length; $k++) {
                if ($pkt[$k] -eq $marker[0] -and $pkt[$k+1] -eq $marker[1] -and $pkt[$k+2] -eq $marker[2] -and $pkt[$k+3] -eq $marker[3] -and
                    $pkt[$k+4] -eq $marker[4] -and $pkt[$k+5] -eq $marker[5] -and $pkt[$k+6] -eq $marker[6]) {
                    $seen += [pscustomobject]@{ Service = $svc; Bytes = $pkt }
                    break
                }
            }
        }
    }
    finally { $mc.Dispose() }
    return , $seen
}

# ── ROUTING_BUSY flow control (03_08_05 2.3.5 p.10-11) ─────────────────────────────────────────────

function Start-KnxMcListener {
    <#
    .SYNOPSIS
        Receives on a multicast group in a background runspace and stamps every datagram when it is read.
    .DESCRIPTION
        Time stamps are Stopwatch ticks taken right after ReceiveFrom, in a thread of their own. A datagram that was
        already waiting when the reader came back (Available > 0) is marked Queued: its stamp is the read time. An
        unmarked stamp can still be late by a thread stall or a process-wide GC pause (one reader loop pass took up to
        ~9 ms unloaded), so these stamps cannot resolve a single sub-5 ms interval; Start-KnxCapture takes kernel time stamps.
        Stop with Stop-KnxMcListener.
    #>
    param([Parameter(Mandatory)][string]$Group, [int]$Port = 3671, [object[]]$KeepAlive = @())
    $sock = New-KnxMulticastSocket -Group $Group -Port $Port -TimeoutMs 200
    $list = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
    $flag = [hashtable]::Synchronized(@{ Stop = $false; Ready = $false })
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        param($Sock, $List, $Flag)
        $buf = New-Object byte[] 1500
        $Flag.Ready = $true
        while (-not $Flag.Stop) {
            $ep = [Net.EndPoint](New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0))
            $queued = ($Sock.Available -gt 0)
            try { $n = $Sock.ReceiveFrom($buf, [ref]$ep) } catch { continue }
            $t = [Diagnostics.Stopwatch]::GetTimestamp()
            $b = New-Object byte[] $n
            [Array]::Copy($buf, $b, $n)
            [void]$List.Add([pscustomobject]@{ T = $t; Queued = $queued; From = ([Net.IPEndPoint]$ep).Address.ToString(); Bytes = $b })
        }
    }).AddArgument($sock).AddArgument($list).AddArgument($flag)
    $handle = $ps.BeginInvoke()
    # The runspace can take seconds to start; datagrams read later carry late stamps and miss the caller's window.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    # Tunnels open meanwhile are acknowledged, else the device ends them after its repeat (03_08_04 2.6.1).
    while (-not $flag.Ready -and $sw.ElapsedMilliseconds -lt 10000) {
        $open = @($KeepAlive | Where-Object { $null -ne $_ -and $null -ne $_.Socket })
        if ($open.Count -gt 0) { foreach ($c in $open) { [void](Sync-KnxTunnel -Connection $c -Ms 5) } } else { Start-Sleep -Milliseconds 10 }
    }
    [pscustomobject]@{ Ps = $ps; Handle = $handle; List = $list; Flag = $flag; Socket = $sock; Ready = $flag.Ready }
}

function Stop-KnxMcListener {
    param($Listener)
    if ($null -eq $Listener) { return }
    $Listener.Flag.Stop = $true
    try { [void]$Listener.Ps.EndInvoke($Listener.Handle) } catch { }
    $Listener.Ps.Dispose()
    $Listener.Socket.Dispose()
}

function Find-KnxDumpcap {
    <#
    .SYNOPSIS
        Path of Wireshark's dumpcap: $env:KNX_DUMPCAP, then PATH, then the default install; $null if none.
    #>
    $cands = @()
    if ($env:KNX_DUMPCAP) { $cands += $env:KNX_DUMPCAP }
    $cmd = Get-Command dumpcap -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd) { $cands += $cmd.Path }
    $cands += '/Applications/Wireshark.app/Contents/MacOS/dumpcap'
    if ($env:ProgramFiles) { $cands += (Join-Path $env:ProgramFiles 'Wireshark\dumpcap.exe') }
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c } }
    return $null
}

function Start-KnxCapture {
    <#
    .SYNOPSIS
        Captures datagrams to a multicast group from the router and from this host with dumpcap (kernel time stamps).
    .DESCRIPTION
        The network card is the one the OS sends the group on, which is where the router's indications arrive and
        this host's ROUTING_BUSY leaves (not the route to the router). dumpcap writes pcapng to a pipe, which it
        flushes per packet; the call returns once the capture is live (its file header arrived). Ok is $false with
        a Reason when dumpcap is missing or cannot capture (no access to the capture device), or when the card is Wi-Fi.
        Stop with Stop-KnxCapture.
    #>
    param([Parameter(Mandatory)][string]$RouterIp, [Parameter(Mandatory)][string]$Group, [int]$Port = 3671)
    $exe = Find-KnxDumpcap
    if (-not $exe) { return [pscustomobject]@{ Ok = $false; Reason = 'dumpcap (Wireshark) not found - install Wireshark or set KNX_DUMPCAP' } }
    $local = Get-LocalEndpointFor -DestinationIp $Group
    $nic = $null
    foreach ($ni in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        foreach ($ua in $ni.GetIPProperties().UnicastAddresses) { if ($ua.Address.ToString() -eq $local) { $nic = $ni } }
    }
    if ($null -eq $nic) { return [pscustomobject]@{ Ok = $false; Reason = "no network card holds $local, the address used to send to $Group" } }
    # On Wi-Fi the egress stamp precedes the airtime by milliseconds; the BUSY bounds need a wired card.
    if ($nic.NetworkInterfaceType -eq [Net.NetworkInformation.NetworkInterfaceType]::Wireless80211) { return [pscustomobject]@{ Ok = $false; Reason = "the group is sent on $($nic.Name), a Wi-Fi card - its time stamps do not resolve 1 ms" } }
    $windows = ([Environment]::OSVersion.Platform -eq 'Win32NT')
    $device = if ($windows) { "\Device\NPF_$($nic.Id)" } else { $nic.Name }
    $filter = "udp and dst host $Group and dst port $Port and (src host $RouterIp or src host $local)"
    $psi = New-Object Diagnostics.ProcessStartInfo $exe
    $psi.Arguments = ('-q -i "{0}" -f "{1}" -w -' -f $device, $filter)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($psi)
    $buf = New-Object IO.MemoryStream
    $ready = $false
    try {
        $copy = $p.StandardOutput.BaseStream.CopyToAsync($buf)
        $err = $p.StandardError.ReadToEndAsync()
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($buf.Length -eq 0 -and -not $p.HasExited -and $sw.ElapsedMilliseconds -lt 5000) { Start-Sleep -Milliseconds 20 }
        $ready = ($buf.Length -gt 0 -and -not $p.HasExited)
        if (-not $ready) {
            if (-not $p.HasExited) { try { $p.Kill() } catch { } }
            [void]$p.WaitForExit(2000)
            $msg = if ($err.Wait(1000)) { (@($err.Result -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) | Select-Object -First 2) -join ' ' } else { '' }
            return [pscustomobject]@{ Ok = $false; Reason = "dumpcap did not start capturing on $device`: $msg" }
        }
        return [pscustomobject]@{ Ok = $true; Proc = $p; Buffer = $buf; Copy = $copy; Err = $err; LocalIp = $local; Device = $device; Windows = $windows
                                  StartTicks = [Diagnostics.Stopwatch]::GetTimestamp(); StartUnix = (([DateTime]::UtcNow.Ticks - 621355968000000000) / 1e7)
                                  StopTicks = 0L; StopUnix = 0.0; Result = $null }
    }
    finally {
        # Not ready (a failure or an interrupted wait): no capture is handed out, so none may keep running.
        if (-not $ready) {
            if (-not $p.HasExited) { try { $p.Kill() } catch { } }
            $p.Dispose(); $buf.Dispose()
        }
    }
}

function Stop-KnxCapture {
    <#
    .SYNOPSIS
        Stops dumpcap and returns the captured datagrams (Ms, Unix, From, To, Service, Bytes) and its drop count (-1 = unknown).
    .DESCRIPTION
        SIGINT lets dumpcap write its statistics block with the drop count; Windows has no SIGINT, so the process is
        killed and the drop count stays unknown. A second call returns the first result.
    #>
    param([Parameter(Mandatory)]$Capture)
    if ($null -ne $Capture.Result) { return $Capture.Result }
    $p = $Capture.Proc
    # The kernel hands packets to dumpcap only at its read timeout, and a stopped dumpcap drops what is still held there.
    $sw = [Diagnostics.Stopwatch]::StartNew(); $last = $Capture.Buffer.Length; $quiet = 0
    while ($sw.ElapsedMilliseconds -lt 3000 -and -not $p.HasExited -and ($sw.ElapsedMilliseconds -lt 1000 -or $quiet -lt 500)) {
        Start-Sleep -Milliseconds 50
        $now = $Capture.Buffer.Length
        if ($now -eq $last) { $quiet += 50 } else { $quiet = 0; $last = $now }
    }
    $Capture.StopTicks = [Diagnostics.Stopwatch]::GetTimestamp()
    $Capture.StopUnix = (([DateTime]::UtcNow.Ticks - 621355968000000000) / 1e7)
    $died = $p.HasExited   # before the stop or during the drain
    if (-not $p.HasExited -and -not $Capture.Windows) { try { & /bin/kill -INT $p.Id } catch { } }
    if (-not $p.WaitForExit(3000)) { try { $p.Kill() } catch { }; [void]$p.WaitForExit(2000) }
    $done = $false
    try { $done = $Capture.Copy.Wait(3000) } catch { }
    try {
        $parsed = ConvertFrom-KnxPcapng -Bytes $Capture.Buffer.ToArray()
        $why = if ($died) { 'dumpcap ended before the capture was stopped' } elseif (-not $done) { 'the capture pipe did not close' } else { '' }
        $Capture.Result = [pscustomobject]@{ Ok = ($why -eq ''); Frames = $parsed.Frames; Dropped = $parsed.Dropped; Reason = $why }
    }
    catch { $Capture.Result = [pscustomobject]@{ Ok = $false; Frames = @(); Dropped = -1; Reason = "the capture could not be read: $($_.Exception.Message)" } }
    $Capture.Buffer.Dispose()
    $p.Dispose()
    return $Capture.Result
}

function ConvertFrom-KnxPcapng {
    <#
    .SYNOPSIS
        UDP over IPv4 over Ethernet from a little-endian pcapng stream; time in ms from the first packet and in Unix seconds.
    .DESCRIPTION
        Honours if_tsresol (default microseconds) and reads the drop count from an Interface Statistics Block
        (isb_ifdrop). A block cut off at the end of the stream is ignored.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes)
    $u32 = { param([int]$o) [BitConverter]::ToUInt32($Bytes, $o) }
    if ($Bytes.Length -lt 12 -or (& $u32 0) -ne 0x0A0D0D0A) { throw 'no pcapng section header' }
    if ((& $u32 8) -ne 0x1A2B3C4D) { throw 'pcapng is not little-endian' }
    $res = @()   # time units per second, per interface
    $link = @()
    $frames = New-Object Collections.Generic.List[object]
    $dropped = -1
    $t0 = $null
    $o = 0
    while ($o + 12 -le $Bytes.Length) {
        $type = & $u32 $o
        $len = [int](& $u32 ($o + 4))
        if ($len -lt 12 -or $o + $len -gt $Bytes.Length) { break }
        if ($type -eq 1) {
            $link += [int][BitConverter]::ToUInt16($Bytes, $o + 8)
            $r = [decimal]1000000
            $q = $o + 16
            while ($q + 4 -le $o + $len - 4) {
                $code = [BitConverter]::ToUInt16($Bytes, $q); $olen = [BitConverter]::ToUInt16($Bytes, $q + 2)
                if ($code -eq 0) { break }
                if ($code -eq 9 -and $olen -ge 1) {
                    $v = $Bytes[$q + 4]
                    $r = if ($v -band 0x80) { [decimal][Math]::Pow(2, $v -band 0x7F) } else { [decimal][Math]::Pow(10, $v) }
                }
                $q += 4 + [int]([Math]::Ceiling($olen / 4.0) * 4)
            }
            $res += $r
        }
        elseif ($type -eq 5) {
            $q = $o + 20
            while ($q + 4 -le $o + $len - 4) {
                $code = [BitConverter]::ToUInt16($Bytes, $q); $olen = [BitConverter]::ToUInt16($Bytes, $q + 2)
                if ($code -eq 0) { break }
                if ($code -eq 5 -and $olen -eq 8) { $dropped = [long][BitConverter]::ToUInt64($Bytes, $q + 4) }
                $q += 4 + [int]([Math]::Ceiling($olen / 4.0) * 4)
            }
        }
        elseif ($type -eq 6) {
            $ifi = [int](& $u32 ($o + 8))
            if ($ifi -ge $res.Count) { throw "packet on undeclared interface $ifi" }
            if ($link[$ifi] -ne 1) { throw "link type $($link[$ifi]) is not Ethernet" }
            $ts = ([decimal](& $u32 ($o + 12)) * 4294967296 + [decimal](& $u32 ($o + 16))) / $res[$ifi]   # seconds
            $cap = [int](& $u32 ($o + 20))
            $d = $o + 28
            $e = $d + 12
            $eth = ([int]$Bytes[$e] * 256) + [int]$Bytes[$e + 1]
            if ($eth -eq 0x8100) { $e += 4; $eth = ([int]$Bytes[$e] * 256) + [int]$Bytes[$e + 1] }
            $ipo = $e + 2
            if ($eth -eq 0x0800 -and $ipo + 20 -le $d + $cap -and $Bytes[$ipo + 9] -eq 17) {
                $ihl = ($Bytes[$ipo] -band 0x0F) * 4
                $udp = $ipo + $ihl
                if ($udp + 8 -gt $d + $cap) { $o += $len; continue }
                $ulen = ([int]$Bytes[$udp + 4] * 256) + [int]$Bytes[$udp + 5]
                $pl = [Math]::Min($ulen - 8, $d + $cap - $udp - 8)
                if ($pl -ge 0) {
                    if ($null -eq $t0) { $t0 = $ts }
                    $b = New-Object byte[] $pl
                    [Array]::Copy($Bytes, $udp + 8, $b, 0, $pl)
                    $svc = if ($pl -ge 4) { ([int]$b[2] * 256) + [int]$b[3] } else { -1 }
                    $frames.Add([pscustomobject]@{
                        Ms = [double](($ts - $t0) * 1000)
                        Unix = [double]$ts   # pcapng time is seconds since 1970, the system clock
                        From = ([Net.IPAddress]::new([byte[]]$Bytes[($ipo + 12)..($ipo + 15)])).ToString()
                        To = ([Net.IPAddress]::new([byte[]]$Bytes[($ipo + 16)..($ipo + 19)])).ToString()
                        Service = $svc; Bytes = $b })
                }
            }
        }
        $o += $len
    }
    [pscustomobject]@{ Frames = $frames.ToArray(); Dropped = $dropped }
}

function Get-KnxMcFrames {
    <#
    .SYNOPSIS
        Datagrams the listener caught from one sender with one service type, in arrival order.
    #>
    param([Parameter(Mandatory)]$Listener, [Parameter(Mandatory)][string]$FromIp, [Parameter(Mandatory)][int]$Service, [long]$AfterTicks = 0, [int]$FromIndex = 0, [int]$ToIndex = -1)
    $all = $Listener.List.ToArray()
    $end = if ($ToIndex -ge 0 -and $ToIndex -lt $all.Length) { $ToIndex } else { $all.Length }
    $out = @()
    for ($i = $FromIndex; $i -lt $end; $i++) {
        $f = $all[$i]
        if ($f.From -eq $FromIp -and $f.Bytes.Length -ge 6 -and (([int]$f.Bytes[2] * 256) + [int]$f.Bytes[3]) -eq $Service -and $f.T -gt $AfterTicks) { $out += $f }
    }
    return , $out
}

function ConvertTo-KnxMs { param([long]$Ticks) [double]$Ticks * 1000.0 / [Diagnostics.Stopwatch]::Frequency }
function ConvertFrom-KnxMs { param([double]$Ms) [long]($Ms * [Diagnostics.Stopwatch]::Frequency / 1000.0) }

function New-KnxRoutingBusy {
    <#
    .SYNOPSIS
        ROUTING_BUSY with a wait time in ms and routing_busy_control 0000h (03_08_05 5.4 Figure 8 p.17).
    #>
    param([Parameter(Mandatory)][int]$WaitMs, [int]$Control = 0)
    [byte[]]@(0x06, 0x10, 0x05, 0x32, 0x00, 0x0C, 0x06, 0x00, (($WaitMs -shr 8) -band 0xFF), ($WaitMs -band 0xFF), (($Control -shr 8) -band 0xFF), ($Control -band 0xFF))
}

function Get-KnxOutsideAddress {
    <#
    .SYNOPSIS
        An individual address outside the router's area, so a telegram to it is routed to IP.
    #>
    param([Parameter(Mandatory)][string]$RouterPa, [int]$Device = 250)
    $area = [int]($RouterPa.Split('.')[0])
    $other = if ($area -eq 1) { 2 } else { 1 }
    "$other.1.$Device"
}

function New-KnxBusyGenerator {
    <#
    .SYNOPSIS
        A tunnel on the router that sends individual telegrams out of its area, so the router emits ROUTING_INDICATIONs.
    #>
    param([Parameter(Mandatory)][string]$Ip, [int]$Port = 3671, [Parameter(Mandatory)][string]$Destination)
    $K = Get-KnxConstants
    $t = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_LINKLAYER
    if (-not $t.Ok) { return $null }
    $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination (ConvertTo-KnxPa -Address $Destination) -Tpdu (New-TpduDisconnect) -Priority 3
    [pscustomobject]@{ Conn = $t; Cemi = $cemi; Sent = 0; Due = 0L; Log = (New-Object 'System.Collections.Generic.List[long]') }
}

function Invoke-KnxBusyGenerator {
    <#
    .SYNOPSIS
        Sends one telegram through the generator tunnel when due ($IntervalMs apart; 0 = as fast as acknowledged).
    .DESCRIPTION
        Sent counts acknowledged telegrams only. Every tenth one drains and acknowledges what the router sent back.
        Returns $false once the tunnel is gone, so a dead generator cannot read as "nothing was routed".
    #>
    param([Parameter(Mandatory)]$Generator, [int]$IntervalMs = 0)
    if ($null -eq $Generator.Conn.Socket -or (Test-KnxTunnelGone -Connection $Generator.Conn)) { return $false }
    $now = [Diagnostics.Stopwatch]::GetTimestamp()
    if ($IntervalMs -gt 0 -and $now -lt $Generator.Due) { return $true }
    $r = Send-KnxTunnelCemi -Connection $Generator.Conn -Cemi $Generator.Cemi -TimeoutMs 300
    if ($null -ne $Generator.PSObject.Properties['Log']) { $Generator.Log.Add($now) }
    if ($r.Acked) { $Generator.Sent++ }
    $Generator.Due = $now + (ConvertFrom-KnxMs $IntervalMs)
    if (($Generator.Sent % 10) -eq 0) { [void](Sync-KnxTunnel -Connection $Generator.Conn -Ms 1) }
    return ($null -ne $Generator.Conn.Socket -and -not (Test-KnxTunnelGone -Connection $Generator.Conn))   # a DISCONNECT_REQUEST from the router keeps the socket
}

function Test-KnxBusyRig {
    <#
    .SYNOPSIS
        Ok when this host receives ROUTING_INDICATIONs the router emits on the group; the flow-control cases need that.
    .DESCRIPTION
        A second attempt follows after 2 to 4 s of drain: a router still in the pause or slow resume of the previous case refuses the tunnel
        telegrams (negative L_Data.con). Note counts the confirmations of each attempt, so a refusal is told apart from missing multicast.
    #>
    param([Parameter(Mandatory)]$Listener, [Parameter(Mandatory)]$Generator, [Parameter(Mandatory)][string]$Ip)
    $K = Get-KnxConstants
    $notes = @()
    foreach ($try in 1, 2) {
        if ($try -eq 2) { [void](Clear-KnxTunnelTraffic -Connection $Generator.Conn -QuietMs 2000 -MaxMs 4000) }
        $t0 = [Diagnostics.Stopwatch]::GetTimestamp()
        foreach ($i in 1..10) { [void](Invoke-KnxBusyGenerator -Generator $Generator) }
        $pos = 0; $neg = 0
        $until = [DateTime]::UtcNow.AddMilliseconds(800)
        while ([DateTime]::UtcNow -lt $until) {
            $in = Receive-KnxTunnelCemi -Connection $Generator.Conn -TimeoutMs 50
            if ($null -eq $in -or $in.Cemi.Length -lt 3 -or $in.Cemi[0] -ne $K.Cemi.L_DATA_CON) { continue }
            $ld = Read-CemiLData -Cemi $in.Cemi
            if ($null -eq $ld) { continue }
            if (($ld.Ctrl1 -band 0x01) -eq 0) { $pos++ } else { $neg++ }
        }
        $heard = (Get-KnxMcFrames -Listener $Listener -FromIp $Ip -Service $K.Service.ROUTING_INDICATION -AfterTicks $t0).Count
        $notes += "attempt ${try}: $pos positive / $neg negative L_Data.con, $heard ROUTING_INDICATION(s) heard"
        if ($heard -gt 0) { return [pscustomobject]@{ Ok = $true; Note = ($notes -join '; ') } }
    }
    return [pscustomobject]@{ Ok = $false; Note = ($notes -join '; ') }
}

function Invoke-KnxSuiteRouting {
    param([Parameter(Mandatory)]$Ctx, [string]$SuiteTitle = '6 Routing')

    $K = Get-KnxConstants
    $ip = $Ctx.BdutIp
    $port = $Ctx.Port
    $group = $Ctx.Multicast
    # -IsolatedNetwork: the rig is its own segment, so the production group may be used (TSSH 1.2.1).
    $isolated = ($null -ne $Ctx.PSObject.Properties['IsolatedNetwork'] -and [bool]$Ctx.IsolatedNetwork)

    # ── Interface: the whole section is a MUST-NOT ──────────────────────────────

    if (-not $Ctx.IsRouter) {
        Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-6.NEG.1' -Title 'Interface must not advertise the ROUTING service family' -Clause '03_08_02 Core, Supported Service Families DIB; 03_08_04 section 2.2.4' -Body {
            $d = Get-KnxDescription -Ip $ip -Port $port
            Assert-KnxTrue ($null -ne $d) 'no description'
            Add-KnxEvidence -Received $d.Body -Note ("advertised: " + (($d.Families | ForEach-Object { $_.Name }) -join ', '))
            Assert-KnxTrue (-not (Test-KnxFamilySupported -Body $d.Body -Family $K.Family.ROUTING)) `
                'the device advertises ROUTING - it is therefore a KNXnet/IP routing device, and a routing device must not offer a KNX busmonitor'
        }

        Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-6.NEG.2' -Title 'Interface must not forward a ROUTING_INDICATION to the bus' -Clause 'TSSH 6.1.1 (inverted); 03_08_05 Routing' -Body {
            if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case emits multicast traffic' }
            if ($group -eq $script:ProductionMulticastGroup -and -not $isolated) { Set-KnxTestNotRun -MissingInput '-IsolatedNetwork' -Reason "the interface listens on $group only, the production group - run on an isolated rig" }
            if (-not $Ctx.TrafficIp) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason 'needs a second interface (-TrafficIp) to observe the bus' }
            if ($Ctx.TrafficIp -eq $ip) { Set-KnxTestNotRun -MissingInput 'a -TrafficIp other than the interface' -Reason 'the witness is the interface under test' }

            # The interface listens on its discovery group only (PID 65, 224.0.23.12); a probe on another group never
            # reaches it and would pass without testing anything.
            if ($group -ne $script:SystemSetupMulticastGroup) { Set-KnxTestNotRun -MissingInput '-Multicast 224.0.23.12 with -IsolatedNetwork' -Reason "the interface listens on 224.0.23.12, a probe on $group does not reach it" }

            # 08_TSSH 1.2/1.4 p.7-8 puts no other router on the line; when one is there, its PID 75 is read around the probe to attribute
            # each copy. A copy in the same bit slot as the router's merges with it and cannot be told apart (03_02_02 1.1.5 p.11).
            $d = Get-KnxDescription -Ip $ip -Port $port
            $pa = if ($null -ne $d -and $null -ne $d.Device) { $d.Device.IndividualAddr } elseif ($Ctx.BdutPa) { $Ctx.BdutPa } else { $null }
            if (-not $pa -or $pa -notmatch '^\d+\.\d+\.\d+$') { Set-KnxTestNotRun -MissingInput '-BdutPa' -Reason 'no description and no valid -BdutPa - the line of the interface is unknown' }
            $pp = $pa -split '\.'
            $line = "$($pp[0]).$($pp[1])"
            $disc = Find-KnxLineRouters -ExcludeIp $ip -Group $group -Line $line -Port $port
            $routers = @($disc.Routers | Where-Object { $_.SameLine })
            if ($disc.Routers.Count -gt 0) { Add-KnxEvidence -Note ("routers on $group`: " + (($disc.Routers | ForEach-Object { "$($_.Ip) ($($_.Pa)$(if ($_.SameLine) { ', this line' }))" }) -join ', ')) }
            if (-not $disc.DutAnswered) { Set-KnxTestNotRun -MissingInput 'multicast from this host to the interface' -Reason 'the interface did not answer SEARCH on 224.0.23.12 - a probe on the group may not reach it either' }
            # A router as witness reports its own copy on queueing, not from the bus.
            if (@($disc.Routers | Where-Object { $_.Ip -eq $Ctx.TrafficIp }).Count -gt 0) { Set-KnxTestNotRun -MissingInput 'a -TrafficIp that is not a router on the group' -Reason "the witness $($Ctx.TrafficIp) is itself a router on $group" }

            $control = Get-KnxOutsideAddress -RouterPa $pa -Device 251
            $gaProbe = ConvertTo-KnxGa -Address '0/0/21'
            $gaCtl = ConvertTo-KnxGa -Address '0/0/22'
            $indCtl = ConvertTo-KnxPa -Address $control
            # Telegrams the witness reports in $Ms (IsGroup, Dest, Src, Repeated, Cemi).
            $collect = {
                param($W, [int]$Ms)
                $seen = @()
                $end = [DateTime]::UtcNow.AddMilliseconds($Ms)
                while ([DateTime]::UtcNow -lt $end) {
                    $in = Receive-KnxTunnelCemi -Connection $W -TimeoutMs 500
                    if ($null -eq $in) { continue }
                    $ld = Read-CemiLData -Cemi $in.Cemi
                    if ($null -ne $ld) { $seen += [pscustomobject]@{ IsGroup = $ld.IsGroup; Dest = $ld.Destination; Src = $ld.Source; Repeated = $ld.IsRepeated; Cemi = $in.Cemi } }
                }
                , $seen
            }
            $count = { param($List, [bool]$G, [int]$Dest) @($List | Where-Object { $_.IsGroup -eq $G -and $_.Dest -eq $Dest }).Count }

            $dms = @()
            $watch = $null
            $tun = $null
            try {
                $watch = Get-KnxTrafficConnection -Ip $Ctx.TrafficIp
                if ($null -eq $watch) { Set-KnxTestNotRun -MissingInput 'a tunnel on -TrafficIp' -Reason 'the traffic interface granted no tunnel - there is no witness on TP' }
                $tun = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_LINKLAYER
                if ($null -eq $tun -or -not $tun.Ok) { Set-KnxTestNotRun -MissingInput 'a free tunnel on the interface' -Reason 'the interface granted no tunnel for the witness check' }

                # Witness check: the interface sends one group and one individual telegram itself; the witness must report both,
                # or an absent copy below proves nothing.
                [void](Clear-KnxTunnelTraffic -Connection $watch -QuietMs 500)
                [void](Send-KnxTunnelCemi -Connection $tun -Cemi (New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $gaCtl -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 0)) -TimeoutMs 1000)
                [void](Send-KnxTunnelCemi -Connection $tun -Cemi (New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $indCtl -Tpdu (New-TpduDisconnect)) -TimeoutMs 1000)
                $ctl = & $collect $watch 2000
                $hearsGroup = (& $count $ctl $true $gaCtl) -gt 0
                # Nobody acknowledges 0/0/22, so the interface repeats it: more than one report shows a witness that passes
                # repetitions up; with none flagged (cEMI Ctrl1 bit 5, 03_06_03 4.1.5.3.5 p.81) the flag cannot be trusted.
                $ctlCopies = @($ctl | Where-Object { $_.IsGroup -and $_.Dest -eq $gaCtl })
                $repeatsUnflagged = ($ctlCopies.Count -gt 1 -and @($ctlCopies | Where-Object { $_.Repeated }).Count -eq 0)
                $hearsInd = (& $count $ctl $false $indCtl) -gt 0
                Add-KnxEvidence -Note "witness check: group telegram of the interface seen $($ctlCopies.Count)x ($(@($ctlCopies | Where-Object { $_.Repeated }).Count) flagged as repetition); individual telegram to $control seen: $hearsInd"
                [void](Close-KnxConnection -Connection $tun); $tun = $null

                if ($routers.Count -eq 0) {
                    # Rig as in 08_TSSH: every copy on TP is the interface's; a copy seen proves the leak whatever the witness check said.
                    $sent = Send-RoutingIndication -Group $group -Port $port -Cemi (New-CemiLData -MessageCode $K.Cemi.L_DATA_IND -Destination $gaProbe -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1))
                    Add-KnxEvidence -Sent $sent -Note "emitted on $group (no other router on line $line, rig as 08_TSSH 1.2)"
                    $seen = & $collect $watch 4000
                    $g = & $count $seen $true $gaProbe
                    foreach ($x in @($seen | Where-Object { $_.IsGroup -and $_.Dest -eq $gaProbe })) { Add-KnxEvidence -Received $x.Cemi }
                    Add-KnxEvidence -Note "copies of the probe on TP: $g"
                    # A router on the group with another line can still reach this one through a TP coupler.
                    if ($g -gt 0 -and $disc.Routers.Count -gt 0) { Set-KnxTestNotRun -MissingInput 'a rig without other routers on the group (08_TSSH 1.2)' -Reason "$g copies on TP, and routers on $group that are not on line $line ($(($disc.Routers | ForEach-Object { $_.Pa }) -join ', ')) may reach it through a coupler" }
                    Assert-KnxTrue ($g -eq 0) "the ROUTING_INDICATION appeared $g times on the TP line and no other router on the group couples to line $line (SEARCH) - the interface is routing, which it must not do"
                    # An absent copy only counts when the witness reports the interface's group telegrams at all.
                    if (-not $hearsGroup) { Set-KnxTestNotRun -MissingInput 'a witness that reports group telegrams' -Reason "the witness $($Ctx.TrafficIp) did not report the interface's group telegram" }
                }
                else {
                    # Another router on this line: attribute the group copies by its PID_MSG_TRANSMIT_TO_KNX (75).
                    if (-not $hearsGroup) { Set-KnxTestNotRun -MissingInput 'a witness that reports group telegrams' -Reason "the witness $($Ctx.TrafficIp) did not report the interface's group telegram" }
                    foreach ($rt in $routers) {
                        $c = $null
                        try { $c = Open-KnxConnection -Ip $rt.Ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1 } catch { }
                        $dms += [pscustomobject]@{ R = $rt; Conn = $c; Before = -1 }
                    }
                    [void](Clear-KnxTunnelTraffic -Connection $watch -QuietMs 300)
                    foreach ($x in $dms) { if ($null -ne $x.Conn -and $x.Conn.Ok) { $x.Before = Get-RoutingCounter -Connection $x.Conn -PropertyId 75 } }
                    $sent = Send-RoutingIndication -Group $group -Port $port -Cemi (New-CemiLData -MessageCode $K.Cemi.L_DATA_IND -Destination $gaProbe -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1))
                    Add-KnxEvidence -Sent $sent -Note "emitted on $group (router on line $line - copies attributed by its counter)"
                    $seen = & $collect $watch 4000
                    $by = 0
                    $unknown = @()
                    $busy = @()
                    foreach ($x in $dms) {
                        $after = if ($null -ne $x.Conn -and $x.Conn.Ok) { Get-RoutingCounter -Connection $x.Conn -PropertyId 75 } else { -1 }
                        Add-KnxEvidence -Note ("$($x.R.Ip) PID_MSG_TRANSMIT_TO_KNX {0} -> {1}" -f $x.Before, $after)
                        if ($x.Before -lt 0 -or $after -lt $x.Before) { $unknown += $x.R.Ip; continue }
                        $by += ($after - $x.Before)
                        if ($after - $x.Before -gt 1) { $busy += $x.R.Ip }
                    }
                    $copies = & $count $seen $true $gaProbe
                    # The interface's own telegrams (its group objects, source = its PA) are not in a router's count, and a
                    # routed copy keeps the probe's source, so only telegrams from other sources can stand in for a copy.
                    $dutRaw = ConvertTo-KnxPa -Address $pa
                    $other = @($seen | Where-Object { -not ($_.IsGroup -and $_.Dest -eq $gaProbe) -and $_.Src -ne $dutRaw })
                    foreach ($x in @($seen | Where-Object { $_.IsGroup -and $_.Dest -eq $gaProbe })) { Add-KnxEvidence -Received $x.Cemi }
                    Add-KnxEvidence -Note ("copies on TP: {0}; sent to KNX by the routers on this line: {1}; other telegrams not from the interface: {2}" -f $copies, $by, $other.Count)
                    $rest = @($seen | Where-Object { -not ($_.IsGroup -and $_.Dest -eq $gaProbe) })
                    if ($rest.Count -gt 0) { Add-KnxEvidence -Note ("telegrams besides the probe: " + ((@($rest | Select-Object -First 5) | ForEach-Object { '{0} -> {1}{2}' -f (ConvertFrom-KnxPa -Raw $_.Src), $(if ($_.IsGroup) { 'GA 0x' } else { 'PA 0x' }), ('{0:X4}' -f $_.Dest) }) -join ', ')) }
                    # Each unreadable router stands for at most one copy; beyond that the leak is proven. If only repeats (Ctrl1 bit 5 = 0) make
                    # the excess, or the witness does not flag repeats, NOT-RUN: the flag turns a FAIL into NOT-RUN, never a copy into nothing.
                    $first = @($seen | Where-Object { $_.IsGroup -and $_.Dest -eq $gaProbe -and -not $_.Repeated }).Count
                    $bound = $by + $unknown.Count
                    if ($copies -gt $bound -and ($first -le $bound -or $repeatsUnflagged)) { Set-KnxTestNotRun -MissingInput 'a device on the line that acknowledges 0/0/21' -Reason "$copies copies seen, $($copies - $first) flagged as repetitions$(if ($repeatsUnflagged) { ', and the witness reports repetitions unflagged' }) - the excess over $bound may be TP repetitions of the routers' unacknowledged copy" }
                    Assert-KnxTrue ($copies -le $by + $unknown.Count) ("{0} copies on the TP line ({1} not flagged as repetitions), the routers on this line sent {2} (unreadable: {3}) - the interface routed a ROUTING_INDICATION, which it must not do" -f $copies, $first, $by, $unknown.Count)
                    # The gates below only stop a PASS the counts cannot carry.
                    if (Test-KnxTunnelGone -Connection $watch) { Set-KnxTestNotRun -MissingInput 'a witness tunnel that stays up' -Reason 'the tunnel on the traffic interface was lost while watching' }
                    if ($copies -gt 0 -and $unknown.Count -gt 0) { Set-KnxTestNotRun -MissingInput 'PID_MSG_TRANSMIT_TO_KNX of the other routers' -Reason "a router on this line ($($unknown -join ', ')) could not be read, so the copies on TP cannot be attributed" }
                    if ($busy.Count -gt 0) { Set-KnxTestNotRun -MissingInput 'a quiet routing group' -Reason "$($busy -join ', ') sent more than the probe to KNX in the window" }
                    # Any other telegram on TP may be one of the router's sends standing in for a copy from the interface.
                    if ($other.Count -gt 0) { Set-KnxTestNotRun -MissingInput 'a quiet TP line' -Reason "$($other.Count) telegrams from other sources than the interface on TP in the window - a router's send among them could hide a copy from the interface" }
                    # More sent than seen: the witness misses telegrams, so a copy from the interface could be missed too.
                    if ($by -gt $copies) { Set-KnxTestNotRun -MissingInput 'a witness that sees every telegram' -Reason "the routers on this line sent $by telegrams to KNX but only $copies copies were seen on TP" }
                    Add-KnxEvidence -Note ('the counts account for every copy seen. Not detectable: a copy in the same bit slot as the router''s merges with it (03_02_02 1.1.5); a router send the witness does not report' + $(if (-not $hearsInd) { ' (this witness does not report individual telegrams to other devices)' } else { '' }) + ' could stand in for a copy')
                }
                if (Test-KnxTunnelGone -Connection $watch) { Set-KnxTestNotRun -MissingInput 'a witness tunnel that stays up' -Reason 'the tunnel on the traffic interface was lost while watching - an absent copy proves nothing' }
            }
            finally {
                if ($null -ne $tun) { try { [void](Close-KnxConnection -Connection $tun) } catch { } }
                foreach ($x in $dms) { if ($null -ne $x.Conn) { try { [void](Close-KnxConnection -Connection $x.Conn) } catch { } } }
                # NOT closed: this is the shared traffic connection, and on an interface that grants one
                # channel and does not free it at once, closing it makes every later case wait or skip.
                # Draining gives the next case the same clean start without taking the channel away.
                if ($null -ne $watch) { [void](Clear-KnxTunnelTraffic -Connection $watch -QuietMs 200) }
            }
        }

        foreach ($id in @('H-6.1.1', 'H-6.1.2', 'H-6.1.3', 'H-6.1.4', 'H-6.1.5', 'H-6.1.6', 'H-6.1.7', 'H-6.1.8', 'H-6.1.9', 'H-6.2.1', 'H-6.2.2')) {
            Invoke-KnxTestCase -Suite $SuiteTitle -Id $id -Title 'Routing case (router only)' -Clause "TSSH $($id.Substring(2))" -Body {
                Set-KnxTestNotApplicable 'device is a KNXnet/IP interface: it does not advertise ROUTING, so the routing cases do not apply (verified positively by H-6.NEG.1 and H-6.NEG.2)'
            }
        }
        return
    }

    # ── Router: the full section ────────────────────────────────────────────────

    # ── IP SBC control over the bus (TP only; P-6.SBC.3 adds one routing indication and checks the group) ────

    $sbcGate = {
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case switches the IP System Broadcast Routing Mode' }
        if (-not $Ctx.TrafficIp) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason 'needs a second interface on the same TP line (-TrafficIp) to reach the router over the bus' }
        if (-not $Ctx.BdutPa) { Set-KnxTestNotRun -MissingInput '-BdutPa' -Reason 'the router individual address is unknown (-BdutPa)' }
        # While the mode is on (up to 20 s) the router relays TP system broadcasts to 224.0.23.12, whatever the routing group.
        if (-not $isolated) { Set-KnxTestNotRun -MissingInput '-IsolatedNetwork' -Reason 'switching the IP System Broadcast Routing Mode on makes the router send on 224.0.23.12 - only on an isolated rig' }
    }
    $sbcSession = {
        $s = Open-KnxDeviceSession -Ip $Ctx.TrafficIp -Port $port -Pa $Ctx.BdutPa
        if (-not $s.Ok) { Set-KnxTestSkip "no tunnel on the traffic interface: $($s.Reason)" }
        $s
    }
    # Waits keep acknowledging the traffic tunnel; a plain sleep loses it to an unacknowledged indication (03_08_04 2.6.1).
    $sbcWait = { param($Session, [int]$Ms) if ($Ms -gt 0) { [void](Wait-KnxTunnel -Connection $Session.Conn -Ms $Ms) } }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'P-6.SBC.1' -Title 'IP System Broadcast Routing Mode is written and read back over the bus, classic and extended' `
                       -Clause '03_05_01 4.5.16.1.2-4.5.16.1.3 p.107-109' -Body {
        & $sbcGate
        $s = & $sbcSession
        try {
            $idx = Get-KnxRouterObjectIndex -Session $s
            Assert-KnxTrue ($idx -ge 0) 'no object of type 6 (router) answered PID_OBJECT_TYPE over the bus'
            Add-KnxEvidence -Note "router object index $idx"
            foreach ($step in @(@{ Form = 'Classic'; Mode = 1 }, @{ Form = 'Ext'; Mode = 0 })) {
                $w = Invoke-KnxSbcControl -Session $s -Form $step.Form -ObjectIndex $idx -Mode $step.Mode
                Add-KnxEvidence -Received $w.Response -Note "$($step.Form) write $($step.Mode)"
                Assert-KnxSbcAnswer -Result $w -What "$($step.Form) write of mode $($step.Mode)"
                Assert-KnxTrue $w.HeaderEcho "the $($step.Form) answer does not echo the object and PID of the request"
                Assert-KnxEqual 0 $w.ServiceId 'the answer does not repeat WriteServiceID 00h (Figure 18 p.108)'
                $r = Invoke-KnxSbcControl -Session $s -Form $step.Form -ObjectIndex $idx
                Add-KnxEvidence -Received $r.Response -Note "$($step.Form) read"
                Assert-KnxSbcAnswer -Result $r -What "$($step.Form) read" -Read
                Assert-KnxEqual $step.Mode $r.Mode "$($step.Form) read does not report the mode just written"
            }
        }
        finally {
            try { [void](Invoke-KnxSbcControl -Session $s -Form 'Ext' -Mode 0) } catch { }
            Close-KnxDeviceSession -Session $s
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'P-6.SBC.2' -Title 'IP System Broadcast Routing Mode falls back after 20 s, a second enable restarts the time' `
                       -Clause '03_05_01 4.5.16.1.1 p.107; 08_TSSK 2.4.11 (80111) p.176' -Body {
        & $sbcGate
        if ($Ctx.SkipSlow) { Set-KnxTestSkip 'measures the 20 s fall-back - excluded by -SkipSlow' }
        $s = & $sbcSession
        try {
            # Enable, enable again after 10 s: 19 s after the second enable (29 s after the first) the mode must still
            # be on, 21 s after it off. 1 s either side, the TimeoutIpSystemBroadcastFallbackToDisableDelta of 08_TSSK.
            Assert-KnxSbcAnswer -Result (Invoke-KnxSbcControl -Session $s -Form 'Ext' -Mode 1) -What 'first enable'
            & $sbcWait $s 10000
            Assert-KnxSbcAnswer -Result (Invoke-KnxSbcControl -Session $s -Form 'Ext' -Mode 1) -What 'second enable'
            $t1 = [Diagnostics.Stopwatch]::StartNew()
            & $sbcWait $s (19000 - [int]$t1.ElapsedMilliseconds)
            $r19 = Invoke-KnxSbcControl -Session $s -Form 'Ext'
            Add-KnxEvidence -Received $r19.Response -Note ("read {0:N1} s after the second enable" -f $t1.Elapsed.TotalSeconds)
            Assert-KnxSbcAnswer -Result $r19 -What 'read 19 s after the second enable' -Read
            Assert-KnxEqual 1 $r19.Mode 'the mode was off 19 s after the second enable - the second enable did not restart the 20 s'
            & $sbcWait $s (21000 - [int]$t1.ElapsedMilliseconds)
            $r21 = Invoke-KnxSbcControl -Session $s -Form 'Ext'
            Add-KnxEvidence -Received $r21.Response -Note ("read {0:N1} s after the second enable" -f $t1.Elapsed.TotalSeconds)
            Assert-KnxSbcAnswer -Result $r21 -What 'read 21 s after the second enable' -Read
            Assert-KnxEqual 0 $r21.Mode 'the mode was still on 21 s after the last enable - no fall-back to Disable'
        }
        finally {
            try { [void](Invoke-KnxSbcControl -Session $s -Form 'Ext' -Mode 0) } catch { }
            Close-KnxDeviceSession -Session $s
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'P-6.SBC.3' -Title 'An enable sent over IP routing switches the IP System Broadcast Routing Mode' `
                       -Clause '03_05_01 4.5.16.1.2 p.107-108' -Body {
        & $sbcGate
        if ($group -eq $script:ProductionMulticastGroup -and -not $isolated) { Set-KnxTestSkip "refusing to send on the production multicast group $script:ProductionMulticastGroup - pass a lab group via -Multicast or -IsolatedNetwork" }
        $s = & $sbcSession
        try {
            Assert-KnxSbcAnswer -Result (Invoke-KnxSbcControl -Session $s -Form 'Ext' -Mode 0) -What 'disable before the case'
            # A_FunctionPropertyExtCommand from the backbone (0.0.250) to the router, as a routing indication.
            $tpdu = New-TpduService -Apci $K.Apci.FUNCTION_PROPERTY_EXT_COMMAND -Data ([byte[]]@(0x00, 0x06, 0x00, 0x10, 0x78, 0x00, 0x00, 0x01)) -Sequence -1
            $cemi = New-CemiLData -MessageCode 0x29 -Source (ConvertTo-KnxPa -Address '0.0.250') -Destination (ConvertTo-KnxPa -Address $Ctx.BdutPa) -Tpdu $tpdu -Priority 0
            $f = Send-RoutingIndication -Group $group -Port $port -Cemi $cemi
            Add-KnxEvidence -Sent $f -Note "enable sent to $group"
            & $sbcWait $s 500
            $r = Invoke-KnxSbcControl -Session $s -Form 'Ext'
            Add-KnxEvidence -Received $r.Response -Note 'mode read over the bus'
            Assert-KnxSbcAnswer -Result $r -What 'read over the bus' -Read
            Assert-KnxEqual 1 $r.Mode 'the enable received over IP routing did not switch the mode on'
        }
        finally {
            try { [void](Invoke-KnxSbcControl -Session $s -Form 'Ext' -Mode 0) } catch { }
            Close-KnxDeviceSession -Session $s
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'P-6.SBC.4' -Title 'Enabling the mode while broadcasts are locked is refused with E_COMMAND_IMPOSSIBLE or lifts the lock' `
                       -Clause '03_05_01 4.5.16.1.1 p.107, Table 30 p.109; 08_TSSK 2.4.31 (80131) p.197' -Body {
        & $sbcGate
        # An open device management connection puts the transport layer in cEMI Transport Layer mode, which ignores the bus requests (TSSH 8.3.6): DM only around the PID 52 accesses.
        $dm = $null
        $orig = $null
        $s = $null
        $restore = 'not needed'
        try {
            $s = & $sbcSession
            # Start from Disable: a mode left on by an earlier case would read as 1 after a correct F3h.
            Assert-KnxSbcAnswer -Result (Invoke-KnxSbcControl -Session $s -Form 'Ext' -Mode 0) -What 'disable before the case'
            $dm = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
            Assert-KnxTrue ($dm -and $dm.Ok) 'no device-management connection for PID_MAIN_LCCONFIG'
            $rd = Read-KnxProperty -Connection $dm -ObjectType $K.ObjType.ROUTER -PropertyId 52
            if ($null -eq $rd.Parsed) { Set-KnxTestSkip 'no answer to the PID_MAIN_LCCONFIG read' }
            if ($rd.Parsed.IsError -or $rd.Parsed.Data.Length -lt 1) { Set-KnxTestNotApplicable 'PID_MAIN_LCCONFIG (52) is not readable, so broadcasts cannot be locked the way 08_TSSK 2.4.31 does' }
            $orig = [byte]$rd.Parsed.Data[0]
            $locked = [byte]($orig -bor 0x08)   # BROADCAST_LOCK
            $restore = 'pending'
            [void](Send-KnxDeviceConfiguration -Connection $dm -Cemi (New-CemiMPropWrite -ObjectType $K.ObjType.ROUTER -PropertyId 52 -Data ([byte[]]@($locked))))
            $chk = Read-KnxProperty -Connection $dm -ObjectType $K.ObjType.ROUTER -PropertyId 52
            if ($null -eq $chk.Parsed -or $chk.Parsed.IsError -or $chk.Parsed.Data.Length -lt 1 -or $chk.Parsed.Data[0] -ne $locked) {
                Set-KnxTestSkip 'BROADCAST_LOCK could not be confirmed in PID_MAIN_LCCONFIG, so there is no lock to test against'
            }
            Add-KnxEvidence -Note ("PID_MAIN_LCCONFIG 0x{0:X2} -> 0x{1:X2}" -f $orig, $locked)
            if (-not (Close-KnxConnection -Connection $dm)) { Set-KnxTestNotRun -MissingInput 'a confirmed DISCONNECT of the device management connection' -Reason 'with the connection possibly open the bus requests would be ignored' }
            $dm = $null
            & $sbcWait $s 700   # the mode ends in the device's next loop pass
            $w = Invoke-KnxSbcControl -Session $s -Form 'Ext' -Mode 1
            Add-KnxEvidence -Received $w.Response -Note 'enable while BROADCAST_LOCK is set'
            Assert-KnxTrue ($null -ne $w.Response) 'no answer to the enable while broadcasts are locked'
            $r = Invoke-KnxSbcControl -Session $s -Form 'Ext'
            Add-KnxEvidence -Received $r.Response -Note 'mode read after the enable'
            Assert-KnxSbcAnswer -Result $r -What 'mode read after the enable' -Read
            if ($w.ReturnCode -eq 0xF3) {
                Assert-KnxEqual 0 $r.Mode 'E_COMMAND_IMPOSSIBLE was returned, but the mode reads as enabled'
            }
            else {
                Assert-KnxTrue ($w.ReturnCode -eq 0) ("the enable was answered with return code 0x{0:X2}, neither 00h nor E_COMMAND_IMPOSSIBLE F3h (Table 30 p.109)" -f $w.ReturnCode)
                Assert-KnxEqual 1 $r.Mode 'the enable was accepted, but the mode reads as disabled'
                # 4.5.16.1.1 p.107: accepting obliges the router to route broadcasts while the mode is on; that is only visible on IP.
                Set-KnxTestSkip 'the enable was accepted while BROADCAST_LOCK was set; whether the lock is lifted is only visible as broadcasts on IP, not judged here'
            }
        }
        finally {
            if ($null -ne $dm) { try { Close-KnxConnection -Connection $dm | Out-Null } catch { } }
            if ($null -ne $s) {
                try { [void](Invoke-KnxSbcControl -Session $s -Form 'Ext' -Mode 0) } catch { }
                Close-KnxDeviceSession -Session $s
            }
            if ($null -ne $orig) {
                try {
                    $dm = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
                    [void](Send-KnxDeviceConfiguration -Connection $dm -Cemi (New-CemiMPropWrite -ObjectType $K.ObjType.ROUTER -PropertyId 52 -Data ([byte[]]@($orig))))
                    $back = Read-KnxProperty -Connection $dm -ObjectType $K.ObjType.ROUTER -PropertyId 52
                    $restore = if ($null -ne $back.Parsed -and -not $back.Parsed.IsError -and $back.Parsed.Data.Length -ge 1 -and $back.Parsed.Data[0] -eq $orig) { 'ok' } else { 'failed' }
                }
                catch { $restore = 'failed' }
                finally { try { Close-KnxConnection -Connection $dm | Out-Null } catch { } }
                if ($restore -ne 'ok') { Write-Host ("    WARNING: PID_MAIN_LCCONFIG was not restored to 0x{0:X2} - later SBC cases will see the lock" -f $orig) -ForegroundColor Red }
            }
            # A lock left set fails every later SBC case, so it overrides any result this case reached, SKIP included.
            if ($restore -eq 'failed') { throw ("KNXTEST_FAIL::PID_MAIN_LCCONFIG could not be restored to 0x{0:X2}" -f $orig) }
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'P-6.SBC.5' -Title 'IP System Broadcast Routing Mode written and read in a T_Connect session through the router''s own tunnel' `
                       -Clause '03_05_01 4.5.16.1.2-4.5.16.1.3 p.107-109; 03_03_04 5.3 p.19' -Body {
        # Only the router's own tunnel is used, so -TrafficIp is not needed. The mode falls back to Disable after 20 s anyway.
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case switches the IP System Broadcast Routing Mode' }
        if (-not $Ctx.BdutPa) { Set-KnxTestNotRun -MissingInput '-BdutPa' -Reason 'the router individual address is unknown (-BdutPa)' }
        if (-not $isolated) { Set-KnxTestNotRun -MissingInput '-IsolatedNetwork' -Reason 'switching the IP System Broadcast Routing Mode on makes the router send on 224.0.23.12 - only on an isolated rig' }
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Ctx.BdutPa -Connect
        if (-not $s.Ok) { Set-KnxTestSkip "no connection-oriented session through the router's own tunnel: $($s.Reason)" }
        $restored = $false
        try {
            $w = Invoke-KnxSbcControl -Session $s -Form 'Ext' -Mode 1 -Connected
            Add-KnxEvidence -Received $w.Response -Note 'enable, connection-oriented'
            Assert-KnxSbcAnswer -Result $w -What 'connection-oriented enable'
            Assert-KnxTrue $w.HeaderEcho 'the answer does not echo the object and PID of the request'
            Assert-KnxEqual 0 $w.ServiceId 'the answer does not repeat WriteServiceID 00h (Figure 18 p.108)'
            $r = Invoke-KnxSbcControl -Session $s -Form 'Ext' -Connected
            Add-KnxEvidence -Received $r.Response -Note 'state read, second request of the session'
            Assert-KnxTrue (-not (Test-KnxTunnelGone -Connection $s.Conn)) "the tunnel was closed within the session (by: $(Get-KnxTunnelGoneBy -Connection $s.Conn))"
            Assert-KnxSbcAnswer -Result $r -What 'connection-oriented state read' -Read
            Assert-KnxEqual 1 $r.Mode 'the state read in the same session does not report the mode just written'
            $o = Invoke-KnxSbcControl -Session $s -Form 'Ext' -Mode 0 -Connected
            Assert-KnxSbcAnswer -Result $o -What 'connection-oriented disable'
            $restored = ($o.ReturnCode -eq 0)
        }
        finally {
            Close-KnxDeviceSession -Session $s
            if (-not $restored) {
                # Second try, connectionless on the same tunnel path; the 20 s fall-back covers the rest.
                $ok = $false
                try { $t = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Ctx.BdutPa; try { $ok = ((Invoke-KnxSbcControl -Session $t -Form 'Ext' -Mode 0).ReturnCode -eq 0) } finally { Close-KnxDeviceSession -Session $t } } catch { }
                if (-not $ok) { Write-Host '    WARNING: the IP System Broadcast Routing Mode could not be reset - it falls back to Disable within 20 s' -ForegroundColor Yellow }
            }
        }
    }

    if ($group -eq $script:ProductionMulticastGroup -and -not $isolated) {
        foreach ($id in @('H-6.1.1', 'H-6.1.2', 'H-6.1.3', 'H-6.1.4', 'H-6.1.5', 'H-6.1.6', 'H-6.1.7', 'H-6.1.8', 'H-6.1.9', 'H-6.2.1', 'H-6.2.2')) {
            Invoke-KnxTestCase -Suite $SuiteTitle -Id $id -Title 'Routing case' -Clause "TSSH $($id.Substring(2))" -Body {
                Set-KnxTestSkip "refusing to flood the production multicast group $script:ProductionMulticastGroup - pass a lab group via -Multicast"
            }
        }
        return
    }

    # ── ROUTING_BUSY flow control (03_08_05 2.3.5 p.10-11); counterparts of validation tool 40301-40315 ──────
    # Sending side: the router's tunnel produces indications, this host sends ROUTING_BUSY and times the next one; receiving side: this host floods the router for its ROUTING_BUSY. Both need multicast from the router, else NOT-RUN. Timing cases offer 40/s (limit 50/s).

    $busyOutside = Get-KnxOutsideAddress -RouterPa $(if ($Ctx.BdutPa) { $Ctx.BdutPa } else { '0.0.0' })
    $busyRig = {
        param([switch]$Destructive, [switch]$Capture, [switch]$Twin)
        if ($Ctx.ReadOnly -or $Ctx.RunProfile -eq 'Safe') { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason "profile $($Ctx.RunProfile) - this case sends ROUTING_BUSY on the routing group" }
        if ($Destructive -and -not $Ctx.AllowDestructive) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'floods the router - needs -IncludeDestructive with profile Full' }
        if (-not $Ctx.BdutPa) { Set-KnxTestNotRun -MissingInput '-BdutPa' -Reason 'the router individual address is unknown (-BdutPa)' }
        $l = Start-KnxMcListener -Group $group -Port $port
        if (-not $l.Ready) { Stop-KnxMcListener $l; Set-KnxTestNotRun -MissingInput 'a multicast reader on this host' -Reason 'the listener runspace did not start within 10 s' }
        $g = $null
        try { $g = New-KnxBusyGenerator -Ip $ip -Port $port -Destination $busyOutside } catch { }
        if ($null -eq $g) { Stop-KnxMcListener $l; Set-KnxTestSkip 'no tunnel on the router to generate routed telegrams' }
        $ok = $false; $rigNote = ''
        try { $rc = Test-KnxBusyRig -Listener $l -Generator $g -Ip $ip; $ok = $rc.Ok; $rigNote = $rc.Note; if ($rigNote -match 'attempt 2') { Add-KnxEvidence -Note "rig check: $rigNote" } }
        catch {
            Stop-KnxMcListener $l; try { [void](Close-KnxConnection -Connection $g.Conn) } catch { }
            Set-KnxTestSkip "the flow-control rig check failed: $($_.Exception.Message)"
        }
        if (-not $ok) {
            Stop-KnxMcListener $l; try { [void](Close-KnxConnection -Connection $g.Conn) } catch { }
            Set-KnxTestNotRun -MissingInput 'multicast reception on this host' -Reason "this host receives no ROUTING_INDICATION from $ip on $group (IGMP snooping without querier, or the router does not route the probe to $busyOutside) - flow control cannot be observed ($rigNote)"
        }
        $cap = $null; $capReason = 'not requested'
        if ($Capture) {
            $c = $null
            try { $c = Start-KnxCapture -RouterIp $ip -Group $group -Port $port } catch { $capReason = "dumpcap failed to start: $($_.Exception.Message)" }
            if ($null -ne $c) { if ($c.Ok) { $cap = $c } else { $capReason = $c.Reason } }
        }
        # -Twin: a second generator tunnel in a thread of its own. Each generator waits for its TUNNELLING_ACK, so two
        # tunnels in one thread offer no faster than one; in two threads their round trips overlap.
        $twinRun = $null; $twinNote = 'one generator tunnel'
        if ($Twin) {
            $g2 = $null
            try { $g2 = New-KnxBusyGenerator -Ip $ip -Port $port -Destination $busyOutside } catch { }
            if ($null -eq $g2) { $twinNote = 'one generator tunnel (the router granted no second one)' }
            else {
              try {
                $flag = [hashtable]::Synchronized(@{ Stop = $false; Error = '' })
                $defs = @(foreach ($n in 'Invoke-KnxBusyGenerator', 'ConvertFrom-KnxMs') { [pscustomobject]@{ Name = $n; Body = (Get-Item "function:$n").ScriptBlock.ToString() } })
                $tps = [powershell]::Create()
                [void]$tps.AddScript({
                    param($Lib, $G, $Flag, $Defs)
                    Import-Module $Lib -DisableNameChecking
                    foreach ($d in $Defs) { Set-Item -Path "function:$($d.Name)" -Value ([scriptblock]::Create($d.Body)) }
                    try { while (-not $Flag.Stop) { if (-not (Invoke-KnxBusyGenerator -Generator $G -IntervalMs 0)) { $Flag.Error = 'the second generator tunnel was lost'; break } } }
                    catch { $Flag.Error = $_.Exception.Message }
                }).AddArgument((Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/KnxTest.psm1')).AddArgument($g2).AddArgument($flag).AddArgument($defs)
                $twinRun = [pscustomobject]@{ Ps = $tps; Handle = $tps.BeginInvoke(); Flag = $flag; G = $g2; Stopped = $false }
                $twinNote = 'two generator tunnels in separate threads'
              }
              catch {
                  # No twin handed out: its tunnel must not hold a slot on the router.
                  try { [void](Close-KnxConnection -Connection $g2.Conn) } catch { }
                  $twinRun = $null; $twinNote = "one generator tunnel (the second could not start: $($_.Exception.Message))"
              }
            }
        }
        [pscustomobject]@{ L = $l; G = $g; Cap = $cap; CapReason = $capReason; BusySent = 0; Twin = $twinRun; TwinNote = $twinNote }
    }
    # Acknowledged telegrams of all generator tunnels.
    $busyOffered = { param($Rig) $Rig.G.Sent + $(if ($null -ne $Rig.Twin) { $Rig.Twin.G.Sent } else { 0 }) }
    # Stops the second generator and frees its tunnel; a second call does nothing.
    $busyTwinStop = {
        param($Rig)
        if ($null -eq $Rig -or $null -eq $Rig.Twin -or $Rig.Twin.Stopped) { return }
        $Rig.Twin.Stopped = $true
        $Rig.Twin.Flag.Stop = $true
        try { [void]$Rig.Twin.Ps.EndInvoke($Rig.Twin.Handle) } catch { }
        try { $Rig.Twin.Ps.Dispose() } catch { }
        try { [void](Close-KnxConnection -Connection $Rig.Twin.G.Conn) } catch { }
    }
    $busyDone = {
        param($Rig)
        if ($null -eq $Rig) { return }
        & $busyTwinStop $Rig
        if ($null -ne $Rig.Cap) { try { [void](Stop-KnxCapture -Capture $Rig.Cap) } catch { } }
        try { Stop-KnxMcListener $Rig.L } catch { }
        try { [void](Close-KnxConnection -Connection $Rig.G.Conn) } catch { }
    }
    $busySend = {
        param([byte[]]$Frame, $Rig)
        $u = New-KnxSocket -TimeoutMs 200
        try { $t = [Diagnostics.Stopwatch]::GetTimestamp(); Send-KnxFrame -Socket $u -Frame $Frame -Ip $group -Port $port } finally { $u.Dispose() }
        if ($null -ne $Rig) { $Rig.BusySent++ }
        $t
    }
    # Stops the capture: the router's indications and this host's ROUTING_BUSY frames with kernel time stamps, or Ok
    # $false with the reason the case has to do without them. Every BUSY sent must be in it, the n-th being the n-th sent.
    $busyKernel = {
        param($Rig)
        if ($null -eq $Rig.Cap) { return [pscustomobject]@{ Ok = $false; Reason = $Rig.CapReason } }
        $c = Stop-KnxCapture -Capture $Rig.Cap
        if (-not $c.Ok) { return $c }
        $busy = @($c.Frames | Where-Object { $_.From -eq $Rig.Cap.LocalIp -and $_.Service -eq $K.Service.ROUTING_BUSY })
        $ri = @($c.Frames | Where-Object { $_.From -eq $ip -and $_.Service -eq $K.Service.ROUTING_INDICATION })
        if ($busy.Count -ne $Rig.BusySent) { return [pscustomobject]@{ Ok = $false; Reason = "the capture holds $($busy.Count) of the $($Rig.BusySent) ROUTING_BUSY frames sent" } }
        if ($c.Dropped -gt 0) { return [pscustomobject]@{ Ok = $false; Reason = "the capture dropped $($c.Dropped) packets" } }
        # SIGINT always yields dumpcap's statistics block; without it the stop went wrong and losses are unknown.
        if ($c.Dropped -lt 0 -and -not $Rig.Cap.Windows) { return [pscustomobject]@{ Ok = $false; Reason = 'dumpcap left no drop count' } }
        # A drop count of 0 misses packets discarded at the stop: every indication the listener read up to 600 ms before the
        # stop (over twice dumpcap's ~250 ms read timeout) must be in the same capture window, bounded by the same instants.
        $until = $Rig.Cap.StopTicks - (ConvertFrom-KnxMs 600)
        $heard = @((Get-KnxMcFrames -Listener $Rig.L -FromIp $ip -Service $K.Service.ROUTING_INDICATION -AfterTicks $Rig.Cap.StartTicks) | Where-Object { $_.T -le $until }).Count
        $held = @($ri | Where-Object { $_.Unix -gt $Rig.Cap.StartUnix - 0.05 -and $_.Unix -le $Rig.Cap.StopUnix - 0.6 }).Count
        if ($held -lt $heard) { return [pscustomobject]@{ Ok = $false; Reason = "the capture holds $held indications in the window in which the listener read $heard" } }
        $drops = if ($c.Dropped -lt 0) { 'drop count unknown' } else { 'no drops' }
        [pscustomobject]@{ Ok = $true; Busy = $busy; Ri = $ri; Note = "kernel time stamps (dumpcap on $($Rig.Cap.Device), $($ri.Count) indications, $drops)" }
    }
    # An indication arriving within one LAN round trip of the BUSY's egress left the router before the BUSY reached it;
    # everything later counts. The validation tool allows nothing (40301/40303/40309).
    $busyInFlight = 1.0
    # Kernel delay from the $Idx-th BUSY to the router's next indication (after the in-flight window); -1 when none came.
    $kernelDelay = {
        param($Kd, [int]$Idx)
        $tb = $Kd.Busy[$Idx].Ms
        $m = @($Kd.Ri | Where-Object { $_.Ms -gt $tb + $busyInFlight })
        if ($m.Count -eq 0) { -1 } else { ($m | Measure-Object -Property Ms -Minimum).Minimum - $tb }   # unrounded: 39.996 ms is below 40
    }
    # 03_08_05 2.3.5 p.11: after a ROUTING_BUSY the router stops for tw. For EVERY captured BUSY of this host, the next
    # indication must come tw or later (40309 "immediately stop sending"); returns the violations.
    $busyStopCheck = {
        param($Kd)
        $v = @()
        for ($q = 0; $q -lt $Kd.Busy.Count; $q++) {
            $b = $Kd.Busy[$q].Bytes
            $tw = ([int]$b[8] * 256) + [int]$b[9]
            $d = & $kernelDelay $Kd $q
            if ($d -ge 0 -and $d -lt $tw) { $v += ('BUSY #{0} (tw {1}): next indication after {2:N2} ms' -f ($q + 1), $tw, $d) }
        }
        , $v
    }
    # Runs the generator for $Ms at $IntervalMs. A lost generator tunnel: FAIL if the router then answers no DESCRIPTION
    # (it may have restarted), NOT-RUN otherwise - the loss says nothing about flow control.
    $busyPump = {
        param($Rig, [int]$Ms, [int]$IntervalMs = 25)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt $Ms) {
            if (-not (Invoke-KnxBusyGenerator -Generator $Rig.G -IntervalMs $IntervalMs)) {
                $by = Get-KnxTunnelGoneBy -Connection $Rig.G.Conn
                Assert-KnxTrue ($null -ne (Get-KnxDescription -Ip $ip -Port $port)) "the generator tunnel was lost (ended by: $(if ($by) { $by } else { 'unknown' })) and the router answers no DESCRIPTION - it may have restarted under ROUTING_BUSY load"
                Set-KnxTestNotRun -MissingInput 'a generator tunnel that stays up' -Reason "the generator tunnel on the router was lost during the case (ended by: $(if ($by) { $by } else { 'unknown' }))"
            }
        }
    }
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'P-6.BUSY.1' -Title 'ROUTING_BUSY: the router stops for tw and resumes after tw + trandom (0..50 ms), with a random spread (tw 40/80/100)' `
                       -Clause '03_08_05 2.3.5 p.10-11, 3.7.1 p.13; validation tool 40301, 40309' -Body {
        $rig = $null
        try {
            $rig = & $busyRig -Capture
            if ($null -eq $rig.Cap) { Set-KnxTestNotRun -MissingInput 'kernel time stamps (Wireshark dumpcap)' -Reason "$($rig.CapReason) - read-time stamps cannot hold the bound t_d >= tw" }
            $recs = @()
            foreach ($tw in 40, 80, 100) {
                foreach ($n in 1..10) {
                    & $busyPump $rig (600 + (Get-Random -Maximum 300))   # irregular spacing; N falls back to 1 in between
                    [void](& $busySend (New-KnxRoutingBusy -WaitMs $tw) $rig)
                    & $busyPump $rig ($tw + 250)
                    $recs += [pscustomobject]@{ Tw = $tw; Name = "tw $tw #$n"; Idx = $rig.BusySent - 1 }
                }
            }
            $kd = & $busyKernel $rig
            if (-not $kd.Ok) { Set-KnxTestNotRun -MissingInput 'kernel time stamps (Wireshark dumpcap)' -Reason "$($kd.Reason) - read-time stamps cannot hold the bound t_d >= tw" }
            Add-KnxEvidence -Note "timing from $($kd.Note)"
            $stop = & $busyStopCheck $kd
            Assert-KnxTrue ($stop.Count -eq 0) ("indication within tw after a ROUTING_BUSY (validation tool 40301): " + (@($stop | Select-Object -First 5) -join '; '))
            $bad = @()
            $rand = @()
            foreach ($r in $recs) {
                $d = & $kernelDelay $kd $r.Idx
                Add-KnxEvidence -Note ("$($r.Name): t_d {0:N2} ms" -f $d)
                # As the validation tool (40301): tw <= t_d <= tw + 50 ms, no slack. A router queues what it cannot forward
                # (03_08_05 3.7.1 p.13), so its first indication leaves at the resume.
                if ($d -lt 0 -or $d -lt $r.Tw -or $d -gt $r.Tw + 50) {
                    $bad += ("$($r.Name): t_d {0:N2} ms" -f $d)
                    # Where the generator stood: its last send before that indication, in host time (capture clock mapped).
                    if ($d -ge 0) {
                        $riTicks = $rig.Cap.StartTicks + [long](($kd.Busy[$r.Idx].Unix - $rig.Cap.StartUnix + $d / 1000.0) * [Diagnostics.Stopwatch]::Frequency)
                        $prev = @($rig.G.Log | Where-Object { $_ -le $riTicks })
                        if ($prev.Count -gt 0) { Add-KnxEvidence -Note ("$($r.Name): last generator send {0:N1} ms before that indication, the one before {1:N1} ms" -f (ConvertTo-KnxMs ($riTicks - $prev[-1])), $(if ($prev.Count -gt 1) { ConvertTo-KnxMs ($riTicks - $prev[-2]) } else { -1 })) }
                    }
                }
                if ($d -ge 0) { $rand += ($d - $r.Tw) }
            }
            # trandom is random in [0, 50 ms] for N = 1 (p.11). Pooled over the 30 samples, a spread below half of
            # that (the validation tool's rule) misses a uniform draw with p < 2e-6: a constant delay is not random.
            Assert-KnxTrue ($bad.Count -eq 0) ("resume outside [tw, tw + 50 ms]: " + ($bad -join '; '))
            $spread = ($rand | Measure-Object -Maximum).Maximum - ($rand | Measure-Object -Minimum).Minimum
            Add-KnxEvidence -Note ("spread of t_d - tw over {0} samples: {1:N1} ms" -f $rand.Count, $spread)
            Assert-KnxTrue ($spread -ge 25) ("spread of t_d - tw {0:N1} ms over {1} samples below 25 ms - trandom is not random" -f $spread, $rand.Count)
        }
        finally { & $busyDone $rig }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'P-6.BUSY.2' -Title 'ROUTING_BUSY sequence: N BUSY frames in a row extend the random part to N * 50 ms (N 2..5)' `
                       -Clause '03_08_05 2.3.5 p.11 (N, trandom <= N * 50 ms), 3.7.1 p.13; validation tool 40303 (per N spread >= N * 25; upper side as the t_d bound)' -Body {
        $rig = $null
        try {
            $rig = & $busyRig -Capture
            if ($null -eq $rig.Cap) { Set-KnxTestNotRun -MissingInput 'kernel time stamps (Wireshark dumpcap)' -Reason "$($rig.CapReason) - read-time stamps cannot hold the bound t_d >= tw" }
            $recs = @()
            foreach ($nb in 2..5) {
                foreach ($rep in 1..20) {
                    & $busyPump $rig 800
                    # 13 ms apart: N counts a BUSY received more than 10 ms after the last one; spun, as Sleep may return early.
                    foreach ($bi in 1..$nb) {   # not $k: it would overwrite $K
                        [void](& $busySend (New-KnxRoutingBusy -WaitMs 40) $rig)
                        $sp = [Diagnostics.Stopwatch]::StartNew(); while ($sp.Elapsed.TotalMilliseconds -lt 13) { }
                    }
                    & $busyPump $rig (40 + $nb * 50 + 200)
                    $recs += [pscustomobject]@{ Nb = $nb; Name = "N $nb #$rep"; First = $rig.BusySent - $nb; Idx = $rig.BusySent - 1 }
                }
            }
            $kd = & $busyKernel $rig
            if (-not $kd.Ok) { Set-KnxTestNotRun -MissingInput 'kernel time stamps (Wireshark dumpcap)' -Reason "$($kd.Reason) - read-time stamps cannot hold the bound t_d >= tw" }
            Add-KnxEvidence -Note "timing from $($kd.Note)"
            # Every BUSY of a sequence counts, not only the last: the router must stop at the first (validation tool 40303).
            $stop = & $busyStopCheck $kd
            Assert-KnxTrue ($stop.Count -eq 0) ("indication within tw after a ROUTING_BUSY of the sequence: " + (@($stop | Select-Object -First 5) -join '; '))
            $bad = @()
            $stat = @()
            $unmeasurable = 0
            $few = @()
            foreach ($nb in 2..5) {
                $ds = @()
                $tds = @()
                foreach ($r in @($recs | Where-Object { $_.Nb -eq $nb })) {
                    $d = & $kernelDelay $kd $r.Idx
                    $spaced = $true
                    # N counts a BUSY only 10 ms after the last one. Only compression on this host's side is seen here; the
                    # router counts by its own loop time. A sample sent closer is kept out of the statistics, not the bound.
                    $gap = 1000.0
                    for ($q = $r.First + 1; $q -le $r.Idx; $q++) { $gap = [Math]::Min($gap, $kd.Busy[$q].Ms - $kd.Busy[$q - 1].Ms) }
                    if ($gap -lt 11.0) { Add-KnxEvidence -Note ("$($r.Name): BUSY frames left {0:N2} ms apart - kept out of the statistics" -f $gap); $spaced = $false }
                    Add-KnxEvidence -Note ("$($r.Name): t_d {0:N2} ms after the last BUSY" -f $d)
                    # The bound holds for any N up to nb: the last BUSY always sets tw = 40 ms, and N is 0 again at each repetition.
                    if ($d -lt 0 -or $d -lt 40 -or $d -gt 40 + $nb * 50) { $bad += ("$($r.Name): t_d {0:N2} ms" -f $d) }
                    if (-not $spaced) { $unmeasurable++; continue }
                    if ($d -ge 0) { $ds += ($d - 40); $tds += $d }
                }
                # Validation tool 40303 per N: N * 25 <= t_d_max - t_d_min <= N * 50. Only the lower side is checked here (16+
                # uniform draws: a correct router misses it with p < 3e-4 per N); the upper side is the t_d bound above.
                if ($tds.Count -ge 16) {
                    $rng = ($tds | Measure-Object -Maximum).Maximum - ($tds | Measure-Object -Minimum).Minimum
                    Add-KnxEvidence -Note ("N ${nb}: t_d {0:N1}..{1:N1} ms, spread {2:N1} ms, required >= {3} ms (the tool also caps it at {4} ms; here the t_d bound applies)" -f ($tds | Measure-Object -Minimum).Minimum, ($tds | Measure-Object -Maximum).Maximum, $rng, ($nb * 25), ($nb * 50))
                    if ($rng -lt $nb * 25) { $stat += ("N ${nb}: spread of t_d {0:N1} ms below {1} ms - trandom is not random" -f $rng, ($nb * 25)) }
                }
                else { $few += "N $nb ($($tds.Count))" }
                # trandom is uniform in [0, N * 50 ms] (p.11): a mean over 4 standard errors (N * 50 / sqrt(12 * samples)) below
                # N * 25 shows trandom not scaling with N; over 16..20 samples a correct router misses it with p < 2e-5 per N.
                if ($ds.Count -ge 16) {
                    $mean = ($ds | Measure-Object -Average).Average
                    $floor = $nb * 25 - 4 * $nb * 50 / [Math]::Sqrt(12 * $ds.Count)
                    Add-KnxEvidence -Note ("N ${nb}: mean trandom {0:N1} ms, floor {1:N1} ms" -f $mean, $floor)
                    if ($mean -lt $floor) { $stat += ("N ${nb}: mean trandom {0:N1} ms below {1:N1} ms - trandom does not scale with N" -f $mean, $floor) }
                }
            }
            Assert-KnxTrue ($bad.Count -eq 0) ("resume outside [tw, tw + N * 50 ms]: " + ($bad -join '; '))
            # Each N is judged on its own complete sample, so a finding there stands even when another N is short.
            Assert-KnxTrue ($stat.Count -eq 0) ("trandom not scaling with N or not random: " + ($stat -join '; '))
            if ($few.Count -gt 0) { Set-KnxTestNotRun -MissingInput 'timestamps that resolve the resume' -Reason "$unmeasurable of 80 sequences left this host with BUSY frames less than 11 ms apart; fewer than 16 measured: $($few -join ', ')" }
        }
        finally { & $busyDone $rig }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'P-6.BUSY.3' -Title 'After ROUTING_BUSY the router resumes slowly: at least 5 ms between indications' `
                       -Clause '03_08_05 2.3.5 Figure 5 p.10 (t >= tslow = 5 ms); 03_02_06 2.1 p.6; validation tool 40302' -Body {
        $rig = $null
        try {
            $rig = & $busyRig -Destructive -Capture -Twin   # runs the generator flat out
            # Read-time stamps cannot resolve one sub-5 ms interval (see Start-KnxMcListener); only the capture decides.
            if ($null -eq $rig.Cap) { Set-KnxTestNotRun -MissingInput 'kernel time stamps (Wireshark dumpcap)' -Reason "$($rig.CapReason) - host read-time stamps cannot resolve a single interval below 5 ms" }
            $reps = @()
            foreach ($rep in 1..10) {
                & $busyPump $rig 300 0
                $t = & $busySend (New-KnxRoutingBusy -WaitMs 40) $rig
                & $busyPump $rig 100 0   # tw + trandom is at most 90 ms for N = 1; the pace is taken from here on
                $s1 = & $busyOffered $rig; $t1 = [Diagnostics.Stopwatch]::GetTimestamp()
                & $busyPump $rig 300 0
                $t2 = [Diagnostics.Stopwatch]::GetTimestamp()
                $reps += [pscustomobject]@{ Idx = $rig.BusySent - 1; WindowMs = (ConvertTo-KnxMs ($t2 - $t)); Offered = (& $busyOffered $rig) - $s1; OfferMs = (ConvertTo-KnxMs ($t2 - $t1)) }
            }
            & $busyTwinStop $rig   # the capture stops on a quiet group
            $kd = & $busyKernel $rig
            if (-not $kd.Ok) { Set-KnxTestNotRun -MissingInput 'kernel time stamps (Wireshark dumpcap)' -Reason "$($kd.Reason) - host read-time stamps cannot resolve a single interval below 5 ms" }
            Add-KnxEvidence -Note "timing from $($kd.Note); $($rig.TwinNote)$(if ($null -ne $rig.Twin -and $rig.Twin.Flag.Error) { ' - ' + $rig.Twin.Flag.Error })"
            $stop = & $busyStopCheck $kd
            Assert-KnxTrue ($stop.Count -eq 0) ("indication within tw after a ROUTING_BUSY (validation tool 40302): " + (@($stop | Select-Object -First 5) -join '; '))
            $gaps = @()
            foreach ($r in $reps) {
                $tb = $kd.Busy[$r.Idx].Ms
                $after = @($kd.Ri | Where-Object { $_.Ms -gt $tb -and $_.Ms -le $tb + $r.WindowMs })
                for ($i = 1; $i -lt $after.Count; $i++) { $gaps += ($after[$i].Ms - $after[$i - 1].Ms) }
            }
            # Every interval counts, there is no budget.
            $short = @($gaps | Where-Object { $_ -lt 5.0 })
            $min = if ($gaps.Count) { ($gaps | Measure-Object -Minimum).Minimum } else { -1 }
            $list = { param($v) (@($v | Sort-Object | Select-Object -First 5) | ForEach-Object { '{0:N2}' -f $_ }) -join ', ' }
            $offered = ($reps | Measure-Object -Property Offered -Sum).Sum
            $span = ($reps | Measure-Object -Property OfferMs -Sum).Sum
            $pace = if ($offered -gt 0) { $span / $offered } else { -1 }
            Add-KnxEvidence -Note ("{0} intervals after 10 BUSY frames; below 5 ms: {1} [{2}]; smallest {3:N2} ms; generator offered one telegram every {4:N2} ms from 100 ms after each BUSY (the 5 ms pause also holds without a BUSY, 03_02_06 2.1)" -f $gaps.Count, $short.Count, (& $list $short), $min, $pace)
            Assert-KnxTrue ($short.Count -eq 0) ("{0} of {1} intervals below tslow = 5 ms after a BUSY: {2} ms" -f $short.Count, $gaps.Count, (& $list $short))
            if ($gaps.Count -lt 50) { Set-KnxTestNotRun -MissingInput 'more resume traffic' -Reason "only $($gaps.Count) intervals were captured after the BUSY frames" }
            # Offered no faster than 5 ms, a router without any pacing shows the same intervals: nothing proven.
            if ($pace -lt 0 -or $pace -ge 5.0) { Set-KnxTestNotRun -MissingInput 'a faster generator' -Reason ("the generator offered one telegram every {0:N2} ms from 100 ms after each BUSY - a router that does not pace would pass as well" -f $pace) }
        }
        finally { & $busyDone $rig }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'P-6.BUSY.4' -Title 'At most 50 ROUTING_INDICATIONs in any second under load' `
                       -Clause '03_02_06 2.1 p.6; validation tool 40310' -Body {
        $rig = $null
        try {
            $rig = & $busyRig -Destructive -Capture
            $t0 = [Diagnostics.Stopwatch]::GetTimestamp()
            $sent0 = $rig.G.Sent
            & $busyPump $rig 5000 0
            [void](Wait-KnxTunnel -Connection $rig.G.Conn -Ms 1500)
            $offered = $rig.G.Sent - $sent0
            # A host stall bunches read-time stamps and can show 51 in a second that were not; kernel stamps do not.
            $kd = & $busyKernel $rig
            Add-KnxEvidence -Note ('timing from ' + $(if ($kd.Ok) { $kd.Note } else { "host read-time stamps: $($kd.Reason)" }))
            $stamps = if ($kd.Ok) { @($kd.Ri | ForEach-Object { $_.Ms }) } else { @((Get-KnxMcFrames -Listener $rig.L -FromIp $ip -Service $K.Service.ROUTING_INDICATION -AfterTicks $t0) | ForEach-Object { ConvertTo-KnxMs $_.T }) }
            $max = 0; $j = 0
            for ($i = 0; $i -lt $stamps.Count; $i++) {
                while ($stamps[$i] - $stamps[$j] -ge 1000) { $j++ }
                if ($i - $j + 1 -gt $max) { $max = $i - $j + 1 }
            }
            Add-KnxEvidence -Note "generator: $offered acknowledged telegrams in 5 s; $($stamps.Count) indications; at most $max within 1 s"
            Assert-KnxTrue ($offered -gt 250) "only $offered telegrams offered in 5 s - more than 50 per second are needed to exercise the limit"
            Assert-KnxTrue ($max -ge 45) "at most $max indications in a second although more than 50/s were offered - the limit was not reached, nothing proven"
            Assert-KnxTrue ($max -le 50) "$max ROUTING_INDICATIONs within one second"
        }
        finally { & $busyDone $rig }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'P-6.BUSY.9' -Title 'The router stops sending at once on ROUTING_BUSY: 10 BUSY frames, tw = 100 ms, 125 ms apart, under full load' `
                       -Clause '03_08_05 2.3.5 p.11 (stop for tw); validation tool 40309' -Body {
        $rig = $null
        try {
            $rig = & $busyRig -Destructive -Capture -Twin   # the router sends at its highest rate
            if ($null -eq $rig.Cap) { Set-KnxTestNotRun -MissingInput 'kernel time stamps (Wireshark dumpcap)' -Reason "$($rig.CapReason) - read-time stamps cannot hold the bound t_d >= tw" }
            & $busyPump $rig 500 0
            $o9 = & $busyOffered $rig
            foreach ($k9 in 1..10) {
                $t = & $busySend (New-KnxRoutingBusy -WaitMs 100) $rig
                & $busyPump $rig ([int][Math]::Max(1, 125 - (ConvertTo-KnxMs ([Diagnostics.Stopwatch]::GetTimestamp() - $t)))) 0
            }
            $o9 = (& $busyOffered $rig) - $o9
            & $busyPump $rig 600 0   # the router resumes after the last one
            & $busyTwinStop $rig
            $kd = & $busyKernel $rig
            if (-not $kd.Ok) { Set-KnxTestNotRun -MissingInput 'kernel time stamps (Wireshark dumpcap)' -Reason "$($kd.Reason) - read-time stamps cannot hold the bound t_d >= tw" }
            Add-KnxEvidence -Note "timing from $($kd.Note); $($rig.TwinNote)"
            $ds = @(for ($q = 0; $q -lt $kd.Busy.Count; $q++) { & $kernelDelay $kd $q })
            $measured = @($ds | Where-Object { $_ -ge 0 })
            $last = $kd.Busy[$kd.Busy.Count - 1].Ms
            $resumed = @($kd.Ri | Where-Object { $_.Ms -gt $last + $busyInFlight }).Count
            $sp9 = @(for ($q = 1; $q -lt $kd.Busy.Count; $q++) { $kd.Busy[$q].Ms - $kd.Busy[$q - 1].Ms })
            Add-KnxEvidence -Note ("t_d per BUSY: {0} ms; BUSY spacing {1:N1}..{2:N1} ms; telegrams offered during the BUSY phase: {3}; indications after the last BUSY: {4}" -f (($ds | ForEach-Object { '{0:N2}' -f $_ }) -join ', '), ($sp9 | Measure-Object -Minimum).Minimum, ($sp9 | Measure-Object -Maximum).Maximum, $o9, $resumed)
            $stop = & $busyStopCheck $kd
            Assert-KnxTrue ($stop.Count -eq 0) ("indication within tw = 100 ms after a ROUTING_BUSY: " + (@($stop | Select-Object -First 5) -join '; '))
            # The router must have been sending: without indications after the BUSY frames nothing was proven.
            # No indication afterwards with hardly any offer is a missing input, not a router that failed to resume.
            if ($resumed -eq 0 -and $o9 -lt 50) { Set-KnxTestNotRun -MissingInput 'a generator that keeps offering' -Reason "only $o9 telegrams were offered during the BUSY frames and none followed the last one" }
            Assert-KnxTrue ($resumed -gt 0) 'no indication after the last ROUTING_BUSY - the router did not resume, or was not sending'
            # Only a PASS needs proof that traffic was offered while the BUSY frames were sent.
            if ($o9 -lt 50) { Set-KnxTestNotRun -MissingInput 'a generator that keeps offering' -Reason "only $o9 telegrams were offered during the 1.25 s of BUSY frames" }
            Add-KnxEvidence -Note ("t_d_min {0:N2} ms over {1} BUSY frames with a following indication" -f ($measured | Measure-Object -Minimum).Minimum, $measured.Count)
        }
        finally { & $busyDone $rig }
    }

    # Receiving side: this host floods the router with indications and watches for its ROUTING_BUSY.
    $busyFlood = {
        param($Rig, [string]$Destination, [int]$Ms, [switch]$StopAtBusy)
        $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_IND -Source (ConvertTo-KnxPa -Address '0.0.250') -Destination (ConvertTo-KnxPa -Address $Destination) -Tpdu (New-TpduDisconnect) -Priority 3
        $frame = New-KnxRoutingIndication -Cemi $cemi
        $u = New-KnxSocket -TimeoutMs 200
        $t0 = [Diagnostics.Stopwatch]::GetTimestamp()
        $start = $Rig.L.List.Count
        $sent = 0
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while ($sw.ElapsedMilliseconds -lt $Ms) {
                Send-KnxFrame -Socket $u -Frame $frame -Ip $group -Port $port
                $sent++
                if ($StopAtBusy -and ($sent % 5) -eq 0 -and (Get-KnxMcFrames -Listener $Rig.L -FromIp $ip -Service $K.Service.ROUTING_BUSY -FromIndex $start).Count -gt 0) { break }
                [Threading.Thread]::Sleep(1)
            }
        }
        finally { $u.Dispose() }
        [pscustomobject]@{ Sent = $sent; Busy = (Get-KnxMcFrames -Listener $Rig.L -FromIp $ip -Service $K.Service.ROUTING_BUSY -FromIndex $start) }
    }
    $busyWait = { param($b) if ($b.Bytes.Length -ge 10) { ([int]$b.Bytes[8] * 256) + [int]$b.Bytes[9] } else { -1 } }
    $busyP2p = { if (-not $Ctx.P2pTarget) { Set-KnxTestNotRun -MissingInput '-P2pTarget' -Reason 'needs a real device on the line (-P2pTarget) so the flood is sent on TP and queues up' } }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'P-6.BUSY.5' -Title 'The router sends ROUTING_BUSY with the wait time of PID_ROUTING_BUSY_WAIT_TIME (40/60/80/100 ms)' `
                       -Clause '03_08_05 2.3.5 p.11 (tw stored in PID 78, 20..100 ms); validation tool 40311' -Body {
        & $busyP2p
        $rig = $null; $dm = $null; $orig = -1
        try {
            $rig = & $busyRig -Destructive
            $dm = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
            Assert-KnxTrue $dm.Ok 'no device-management connection for PID_ROUTING_BUSY_WAIT_TIME'
            $orig = Get-RoutingCounter -Connection $dm -PropertyId 78
            Assert-KnxTrue ($orig -ge 0) 'PID_ROUTING_BUSY_WAIT_TIME (78) is not readable'
            foreach ($tw in 40, 60, 80, 100) {
                [void](Send-KnxDeviceConfiguration -Connection $dm -Cemi (New-CemiMPropWrite -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId 78 -Data ([byte[]]@(($tw -shr 8), ($tw -band 0xFF)))))
                $stored = Get-RoutingCounter -Connection $dm -PropertyId 78
                Assert-KnxEqual $tw $stored 'PID_ROUTING_BUSY_WAIT_TIME did not take the written value'
                $f = & $busyFlood $rig $Ctx.P2pTarget 3000 -StopAtBusy
                $w = if ($f.Busy.Count -gt 0) { & $busyWait $f.Busy[0] } else { -1 }
                Add-KnxEvidence -Note "PID 78 = ${tw}: $($f.Sent) indications sent, first ROUTING_BUSY wait time $w"
                Assert-KnxTrue ($f.Busy.Count -gt 0) "no ROUTING_BUSY from the router after $($f.Sent) indications for its line (PID 78 = $tw)"
                Assert-KnxEqual $tw $w 'the ROUTING_BUSY wait time differs from PID_ROUTING_BUSY_WAIT_TIME'
                Start-Sleep -Seconds 3   # let the queue drain before the next value
            }
        }
        finally {
            if ($null -ne $dm -and $dm.Ok) {
                if ($orig -ge 0) {
                    [void](Send-KnxDeviceConfiguration -Connection $dm -Cemi (New-CemiMPropWrite -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId 78 -Data ([byte[]]@(($orig -shr 8), ($orig -band 0xFF)))))
                    if ((Get-RoutingCounter -Connection $dm -PropertyId 78) -ne $orig) { Write-Host "    WARNING: PID_ROUTING_BUSY_WAIT_TIME was not restored to $orig" -ForegroundColor Red }
                }
                try { [void](Close-KnxConnection -Connection $dm) } catch { }
            }
            & $busyDone $rig
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'P-6.BUSY.6' -Title 'A sender that ignores ROUTING_BUSY gets further ROUTING_BUSY within tw' `
                       -Clause '03_08_05 2.3.5 p.11; validation tool 40312' -Body {
        & $busyP2p
        $rig = $null
        try {
            $rig = & $busyRig -Destructive
            $f = & $busyFlood $rig $Ctx.P2pTarget 3000
            $within = 0
            for ($i = 1; $i -lt $f.Busy.Count; $i++) {
                if ((ConvertTo-KnxMs ($f.Busy[$i].T - $f.Busy[$i - 1].T)) -le (& $busyWait $f.Busy[$i - 1])) { $within++ }
            }
            Add-KnxEvidence -Note "$($f.Sent) indications sent ignoring BUSY; $($f.Busy.Count) ROUTING_BUSY; $within followed the previous one within its wait time"
            Assert-KnxTrue ($f.Busy.Count -ge 2) 'fewer than two ROUTING_BUSY although the sender ignored them'
            Assert-KnxTrue ($within -ge 1) 'no ROUTING_BUSY followed another within its wait time'
        }
        finally { & $busyDone $rig; Start-Sleep -Seconds 3 }   # let the router drain its queue before the next case
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'P-6.BUSY.7' -Title 'Indications not addressed to the router or its line cause no ROUTING_BUSY' `
                       -Clause '03_08_05 2.3.5 p.11 (BUSY reflects the incoming queue to the line); validation tool 40313' -Body {
        & $busyP2p
        $rig = $null
        try {
            $rig = & $busyRig -Destructive
            # Control first: the same flood for the line must produce a BUSY, or a silent router would pass.
            $c = & $busyFlood $rig $Ctx.P2pTarget 3000 -StopAtBusy
            Add-KnxEvidence -Note "control: $($c.Sent) indications for $($Ctx.P2pTarget), $($c.Busy.Count) ROUTING_BUSY"
            Assert-KnxTrue ($c.Busy.Count -gt 0) 'the control flood for the line produced no ROUTING_BUSY, so silence below would prove nothing'
            Start-Sleep -Seconds 3
            $f = & $busyFlood $rig $busyOutside 10000
            Add-KnxEvidence -Note "$($f.Sent) indications for $busyOutside in 10 s; $($f.Busy.Count) ROUTING_BUSY"
            Assert-KnxTrue ($f.Sent -gt 1000) 'fewer than 1000 indications were sent, so the queue was not loaded'
            Assert-KnxEqual 0 $f.Busy.Count 'the router sent ROUTING_BUSY for indications not addressed to its line'
        }
        finally { & $busyDone $rig }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'P-6.BUSY.8' -Title 'A sender honouring ROUTING_BUSY loses nothing: 1000 indications reach the bus' `
                       -Clause '03_08_05 2.3.5 p.10 (flow control avoids the loss); validation tool 40315' -Body {
        & $busyP2p
        $rig = $null; $dm = $null
        try {
            $rig = & $busyRig -Destructive
            $dm = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
            Assert-KnxTrue $dm.Ok 'no device-management connection for the routing counters'
            $tx0 = Get-RoutingCounter -Connection $dm -PropertyId $K.Pid.MSG_TRANSMIT_TO_KNX
            $ov0 = Get-RoutingCounter -Connection $dm -PropertyId $K.Pid.QUEUE_OVERFLOW_TO_KNX
            Assert-KnxTrue ($tx0 -ge 0 -and $ov0 -ge 0) 'PID 75 / PID 73 are not readable'
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_IND -Source (ConvertTo-KnxPa -Address '0.0.250') -Destination (ConvertTo-KnxPa -Address $Ctx.P2pTarget) -Tpdu (New-TpduDisconnect) -Priority 3
            $frame = New-KnxRoutingIndication -Cemi $cemi
            $u = New-KnxSocket -TimeoutMs 200
            $seenIdx = $rig.L.List.Count; $pauses = 0
            try {
                for ($i = 0; $i -lt 1000; $i++) {
                    $snapCount = $rig.L.List.Count   # scan up to here only; later arrivals are seen next round
                    $new = Get-KnxMcFrames -Listener $rig.L -FromIp $ip -Service $K.Service.ROUTING_BUSY -FromIndex $seenIdx -ToIndex $snapCount
                    $seenIdx = $snapCount
                    if ($new.Count -gt 0) {
                        # 2.3.5: stop for tw, then resume after tw + trandom (N = 1: one pause per new BUSY).
                        $w = & $busyWait $new[-1]; $pauses++
                        [Threading.Thread]::Sleep([Math]::Max(20, $w) + (Get-Random -Maximum 50))
                    }
                    Send-KnxFrame -Socket $u -Frame $frame -Ip $group -Port $port
                    [Threading.Thread]::Sleep(5)
                }
            }
            finally { $u.Dispose() }
            # The queue drains at bus speed: wait until PID 75 stops moving (at most 60 s).
            $tx1 = $tx0; $sw = [Diagnostics.Stopwatch]::StartNew()
            do { $prev = $tx1; Start-Sleep -Seconds 2; $tx1 = Get-RoutingCounter -Connection $dm -PropertyId $K.Pid.MSG_TRANSMIT_TO_KNX } while ($tx1 -ge 0 -and $tx1 -ne $prev -and $sw.Elapsed.TotalSeconds -lt 60)
            $ov1 = Get-RoutingCounter -Connection $dm -PropertyId $K.Pid.QUEUE_OVERFLOW_TO_KNX
            Assert-KnxTrue ($tx1 -ge 0 -and $ov1 -ge 0) 'PID 75 / PID 73 could not be read after the flood'
            Add-KnxEvidence -Note "1000 sent, $pauses BUSY pauses; PID 75 $tx0 -> $tx1, PID 73 $ov0 -> $ov1"
            Assert-KnxTrue ($pauses -ge 1) 'the router never sent ROUTING_BUSY, so flow control was not exercised'
            Assert-KnxEqual 0 ($ov1 - $ov0) 'telegrams were lost in the LAN to KNX queue (PID_QUEUE_OVERFLOW_TO_KNX advanced)'
            Assert-KnxTrue (($tx1 - $tx0) -ge 1000) "only $($tx1 - $tx0) of 1000 telegrams were sent to the bus (PID_MSG_TRANSMIT_TO_KNX)"
        }
        finally {
            if ($null -ne $dm) { try { [void](Close-KnxConnection -Connection $dm) } catch { } }
            & $busyDone $rig
        }
    }

    # ── TP side of a ROUTING_BUSY pause: counterparts of validation tool 40304-40308 (AN117 6.2.1.4-6.2.1.6, not in the set) ──
    # 03_02_02 2.4.2 p.39 allows BUSY for group, broadcast and own-address frames only; for routed ones the tool is the source.

    $witnessIp = if ($null -ne $Ctx.PSObject.Properties['WitnessIp']) { [string]$Ctx.WitnessIp } else { '' }
    $tpLine = if ($Ctx.BdutPa -match '^\d+\.\d+\.\d+$') { (($Ctx.BdutPa -split '\.')[0..1]) -join '.' } else { '' }
    $tpProbe = {
        param([ValidateSet('Ia', 'Broadcast', 'Ga', 'Local')][string]$Kind)
        switch ($Kind) {
            'Ia'        { [pscustomobject]@{ Dst = (ConvertTo-KnxPa -Address $busyOutside); Group = $false; Tpdu = [byte[]](New-TpduDisconnect); Name = "T_Disconnect to $busyOutside" } }
            'Broadcast' { [pscustomobject]@{ Dst = 0; Group = $true; Tpdu = [byte[]]@(0x01, 0x00); Name = 'A_IndividualAddress_Read broadcast' } }
            'Ga'        { [pscustomobject]@{ Dst = (ConvertTo-KnxGa -Address '0/0/23'); Group = $true; Tpdu = [byte[]](New-TpduGroupValueWrite -Value 1); Name = 'A_GroupValue_Write to 0/0/23' } }
            'Local'     {
                $to = "$tpLine.251"   # no device there: a BUSY can only come from a router
                [pscustomobject]@{ Dst = (ConvertTo-KnxPa -Address $to); Group = $false; Tpdu = [byte[]](New-TpduDisconnect); Name = "T_Disconnect to $to (the router's own line)" }
            }
        }
    }
    $tpGate = {
        if ($Ctx.ReadOnly -or $Ctx.RunProfile -eq 'Safe') { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason "profile $($Ctx.RunProfile) - this case sends ROUTING_BUSY on the routing group" }
        if (-not $tpLine) { Set-KnxTestNotRun -MissingInput '-BdutPa' -Reason 'the router individual address is unknown (-BdutPa)' }
        if (-not $Ctx.TrafficIp) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason 'needs a second interface on the TP line to put the routed telegrams on the bus' }
        if (-not $witnessIp) { Set-KnxTestNotRun -MissingInput '-WitnessIp' -Reason 'the router acknowledges on TP; only a busmonitor on a further interface sees it' }
        # A ROUTING_BUSY on the group pauses every router there; another one on this line would BUSY the probes as well.
        $disc = Find-KnxLineRouters -ExcludeIp $ip -Group $group -Line $tpLine -Port $port
        if (-not $disc.DutAnswered) { Set-KnxTestNotRun -MissingInput 'discovery on 224.0.23.12' -Reason 'the router did not answer SEARCH, so no other router of the line can be ruled out' }
        $others = @($disc.Routers | Where-Object { $_.SameLine })
        if ($others.Count -gt 0) { Set-KnxTestNotRun -MissingInput "no other router of line $tpLine on $group" -Reason ("a BUSY could come from " + (($others | ForEach-Object { "$($_.Ip) ($($_.Pa))" }) -join ', ')) }
    }
    # Sends $Count probes of $Kind through the traffic tunnel, each right after a ROUTING_BUSY (tw = 100 ms) unless -NoBusy,
    # and reports from the witness: originals and repetitions of the probe and the acknowledge that followed each original.
    $tpBusyRound = {
        param($Witness, $Src, [string]$Kind, [int]$Count = 10, [switch]$NoBusy)
        $p = & $tpProbe $Kind
        $srcPa = ConvertTo-KnxPa -Address $Src.TunnelPa
        $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $p.Dst -IsGroup:$p.Group -Tpdu $p.Tpdu -Priority 3
        $busyFrame = New-KnxRoutingBusy -WaitMs 100
        $u = New-KnxSocket -TimeoutMs 200
        $mcl = Start-KnxMcListener -Group $group -Port $port -KeepAlive @($Src, $Witness.Conn)
        if (-not $mcl.Ready) { Stop-KnxMcListener $mcl; $u.Dispose(); Set-KnxTestNotRun -MissingInput 'a multicast reader on this host' -Reason 'the listener runspace did not start within 10 s' }
        $t0 = [Diagnostics.Stopwatch]::GetTimestamp()
        try {
            for ($i = 0; $i -lt $Count; $i++) {
                if (-not $NoBusy) { Send-KnxFrame -Socket $u -Frame $busyFrame -Ip $group -Port $port }
                [void](Send-KnxTunnelCemi -Connection $Src -Cemi $cemi -TimeoutMs 1000)
                [Threading.Thread]::Sleep(60)
            }
            [void](Clear-KnxTunnelTraffic -Connection $Src -QuietMs 100)   # acknowledges the L_Data.con of the probes
            [Threading.Thread]::Sleep(700)
        }
        finally { $u.Dispose(); Stop-KnxMcListener $mcl }
        # The router's own indications of the probe: proof that it routes this kind of telegram at all.
        $routedRi = @((Get-KnxMcFrames -Listener $mcl -FromIp $ip -Service $K.Service.ROUTING_INDICATION -AfterTicks $t0) | Where-Object {
            $ld = Read-CemiLData -Cemi ([byte[]]$_.Bytes[6..($_.Bytes.Length - 1)]); $null -ne $ld -and $ld.Destination -eq $p.Dst -and $ld.IsGroup -eq $p.Group }).Count
        # Comma-returned list: assigned, not wrapped in @(), or it nests into one element.
        $seen = Read-KnxBusWitness -Witness $Witness -WindowMs 1500
        $r = [pscustomobject]@{ Name = $p.Name; Orig = 0; Rep = 0; Acks = 0; BUSY = 0; ACK = 0; NAK = 0; None = 0; Other = 0; Routed = $routedRi; Lost = @($seen | Where-Object { $_.Lost }).Count; Text = '' }
        for ($i = 0; $i -lt $seen.Count; $i++) {
            $l = [byte[]]$seen[$i].Lpdu
            if ($l.Length -eq 1) { $r.Acks++; continue }
            if ($l.Length -ne 7 + $p.Tpdu.Length) { continue }
            $s = ([int]$l[1] * 256) + [int]$l[2]
            $d = ([int]$l[3] * 256) + [int]$l[4]
            if ($s -ne $srcPa -or $d -ne $p.Dst -or ((($l[5] -band 0x80) -ne 0) -ne $p.Group) -or ($l[5] -band 0x0F) -ne ($p.Tpdu.Length - 1)) { continue }
            $same = $true
            for ($j = 0; $j -lt $p.Tpdu.Length; $j++) { if ($l[6 + $j] -ne $p.Tpdu[$j]) { $same = $false; break } }
            if (-not $same) { continue }
            if (($l[0] -band 0x20) -eq 0) { $r.Rep++; continue }   # 03_02_02 2.2.2: repeat bit 0 = repetition
            $r.Orig++
            # Assigned directly: an if-expression unrolls a one-octet acknowledge into a scalar byte.
            $next = $null
            if ($i + 1 -lt $seen.Count) { $next = [byte[]]$seen[$i + 1].Lpdu }
            if ($null -eq $next -or $next.Length -ne 1) { $r.None++ }
            elseif ($next[0] -eq 0xC0 -or $next[0] -eq 0x00) { $r.BUSY++ }   # 00h = NAK and BUSY at once, handled as BUSY (03_02_02 p.32)
            elseif ($next[0] -eq 0xCC) { $r.ACK++ }
            elseif ($next[0] -eq 0x0C) { $r.NAK++ }
            else { $r.Other++ }
        }
        $r.Text = '{0}{1}: {2} originals, {3} repetitions; after an original BUSY {4}, ACK {5}, NAK {6}, none {7}, other {8}; {9} acknowledge frames, {10} lost by the witness; routed to IP {11}' -f `
            $p.Name, $(if ($NoBusy) { ' (no ROUTING_BUSY)' } else { '' }), $r.Orig, $r.Rep, $r.BUSY, $r.ACK, $r.NAK, $r.None, $r.Other, $r.Acks, $r.Lost, $r.Routed
        $r
    }
    # Opens the witness and the traffic tunnel; NOT-RUN when either is missing.
    $tpOpen = {
        $w = Open-KnxBusWitness -WitnessIp $witnessIp -Port $port -TargetPa $Ctx.BdutPa -BdutIp $Ctx.TrafficIp
        if (-not $w.Ok) { Set-KnxTestNotRun -MissingInput 'a busmonitor on -WitnessIp' -Reason $w.Reason }
        $src = Get-KnxTrafficConnection -Ip $Ctx.TrafficIp
        if ($null -eq $src -or -not $src.TunnelPa) { try { [void](Close-KnxConnection -Connection $w.Conn) } catch { }; Set-KnxTestNotRun -MissingInput 'a tunnel on -TrafficIp' -Reason 'no tunnel (or no tunnel address) on the traffic interface' }
        [pscustomobject]@{ W = $w; Src = $src }
    }
    # A round whose probes the witness saw without any acknowledge frame says nothing about BUSY.
    $tpSeen = {
        param($R)
        if ($R.Orig -eq 0) { Set-KnxTestNotRun -MissingInput 'a witness that reports the probes' -Reason "the busmonitor on $witnessIp saw none of the probes ($($R.Name))" }
        if ($R.Acks -eq 0) { Set-KnxTestNotRun -MissingInput 'a witness that reports acknowledge frames' -Reason "the busmonitor on $witnessIp reported no acknowledge frame at all" }
        if ($R.Lost -gt 0) { Set-KnxTestNotRun -MissingInput 'a witness without losses' -Reason "the busmonitor on $witnessIp flagged $($R.Lost) frame(s) as lost, so the acknowledge pairing is not reliable" }
    }

    foreach ($case in @(
            @{ Id = 'P-6.BUSY.11'; Kind = 'Ia'; Tool = '40305'; What = 'individually addressed' },
            @{ Id = 'P-6.BUSY.12'; Kind = 'Broadcast'; Tool = '40306'; What = 'broadcast' },
            @{ Id = 'P-6.BUSY.13'; Kind = 'Ga'; Tool = '40307'; What = 'group addressed' })) {
        $kind = $case.Kind
        Invoke-KnxTestCase -Suite $SuiteTitle -Id $case.Id -Title "During a ROUTING_BUSY pause the router answers a routed $($case.What) TP telegram with BUSY, and not without the pause" `
                           -Clause "validation tool $($case.Tool) (AN117 6.2.1.5); 03_02_02 2.4.2 p.39; 03_08_05 2.3.5 p.11" -Body {
            & $tpGate
            if ($kind -eq 'Ga' -and $Ctx.PSObject.Properties['GroupRoutingLock'] -and $Ctx.GroupRoutingLock) { Set-KnxTestNotRun -MissingInput 'group routing' -Reason "the router is configured not to route group telegrams: $($Ctx.GroupRoutingLock)" }
            $o = & $tpOpen
            try {
                $ctl = & $tpBusyRound $o.W $o.Src $kind 5 -NoBusy
                $r = & $tpBusyRound $o.W $o.Src $kind 10
                Add-KnxEvidence -Note $ctl.Text
                Add-KnxEvidence -Note $r.Text
                & $tpSeen $ctl
                & $tpSeen $r
                Assert-KnxEqual 0 $ctl.BUSY 'the router answered BUSY without a ROUTING_BUSY pause'
                if ($ctl.Routed -eq 0) { Set-KnxTestNotRun -MissingInput 'routing of the probe' -Reason 'the router routed none of the control probes to IP (configuration or filter), so a BUSY cannot be expected' }
                if ($ctl.ACK -eq 0) { Set-KnxTestNotRun -MissingInput 'an ACK next to the control probes' -Reason 'no control probe was followed by ACK: the witness does not report acknowledges next to their frames' }
                Assert-KnxTrue ($r.BUSY -ge 1) "no BUSY acknowledge for $($r.Orig) routed telegrams sent during the pause"
            }
            finally { try { [void](Close-KnxConnection -Connection $o.W.Conn) } catch { } }
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'P-6.BUSY.14' -Title 'During a ROUTING_BUSY pause the router answers routed TP telegrams with BUSY and telegrams it does not route without' `
                       -Clause 'validation tool 40308 (AN117 6.2.1.6); 03_02_02 2.4.2 p.39; 03_08_05 2.3.5 p.11' -Body {
        & $tpGate
        $o = & $tpOpen
        try {
            $ctl = & $tpBusyRound $o.W $o.Src 'Ia' 5 -NoBusy
            $routed = & $tpBusyRound $o.W $o.Src 'Ia' 10
            $local = & $tpBusyRound $o.W $o.Src 'Local' 10
            Add-KnxEvidence -Note $ctl.Text
            Add-KnxEvidence -Note $routed.Text
            Add-KnxEvidence -Note $local.Text
            & $tpSeen $routed
            if ($ctl.Routed -eq 0) { Set-KnxTestNotRun -MissingInput 'routing of the probe' -Reason 'the router routed none of the control probes to IP (configuration or filter)' }
            if ($local.Orig -eq 0) { Set-KnxTestNotRun -MissingInput 'a witness that reports the probes' -Reason "the busmonitor on $witnessIp saw none of the probes ($($local.Name))" }
            # The routed set is the positive control: without a BUSY there, silence for the local set proves nothing (P-6.BUSY.11 judges it).
            if ($routed.BUSY -eq 0) { Set-KnxTestNotRun -MissingInput 'a BUSY on routed telegrams' -Reason "no BUSY for $($routed.Orig) routed telegrams, so the pause is not visible on TP; P-6.BUSY.11 judges that" }
            Assert-KnxEqual 0 $local.BUSY 'telegrams the router does not route were answered BUSY'
        }
        finally { try { [void](Close-KnxConnection -Connection $o.W.Conn) } catch { } }
    }

    # tw = 100 instead of the tool's 40: an accepted copy of the probe can then be shown on TP before tw.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'P-6.BUSY.10' -Title 'ROUTING_BUSY collision: after the router sent ROUTING_BUSY, a ROUTING_BUSY back still stops it for tw' `
                       -Clause 'validation tool 40304 (AN117 6.2.1.4, tool tw 40 ms); 03_08_05 2.3.5 p.11 (stop sending for tw on a received ROUTING_BUSY)' -Body {
        & $busyP2p
        if (-not $Ctx.TrafficIp) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason 'needs a second interface on the TP line for the telegram the router routes after the collision' }
        if ($Ctx.TrafficIp -eq $ip) { Set-KnxTestNotRun -MissingInput 'a -TrafficIp other than the router' -Reason 'the probe must come from TP' }
        $tw = 100
        $rig = $null
        try {
            $rig = & $busyRig -Destructive -Capture
            $src = Get-KnxTrafficConnection -Ip $Ctx.TrafficIp
            Assert-KnxTrue ($null -ne $src) 'no tunnel available on the traffic interface'
            $f = & $busyFlood $rig $Ctx.P2pTarget 3000 -StopAtBusy
            Assert-KnxTrue ($f.Busy.Count -gt 0) "no ROUTING_BUSY from the router after $($f.Sent) indications for its line"
            $p = & $tpProbe 'Ia'
            # System priority wins the bus arbitration against the router's low-priority backlog (03_02_02 2.3.3 p.36).
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $p.Dst -Tpdu $p.Tpdu -Priority 0
            $tb = & $busySend (New-KnxRoutingBusy -WaitMs $tw) $rig
            [void](Send-KnxTunnelCemi -Connection $src -Cemi $cemi -TimeoutMs 1000)
            # The L_Data.con (positive or negative) follows the last attempt, so every copy was on TP before it. If the router
            # then routes that very probe, it held it before the con.
            $onTp = -1.0
            $deadline = [DateTime]::UtcNow.AddMilliseconds(1000)
            while ($onTp -lt 0 -and [DateTime]::UtcNow -lt $deadline) {
                $in = Receive-KnxTunnelCemi -Connection $src -TimeoutMs 50
                if ($null -eq $in -or $in.Cemi[0] -ne $K.Cemi.L_DATA_CON) { continue }
                $ld = Read-CemiLData -Cemi $in.Cemi
                if ($null -eq $ld -or $ld.Destination -ne $p.Dst) { continue }
                $onTp = ConvertTo-KnxMs ([Diagnostics.Stopwatch]::GetTimestamp() - $tb)
                Add-KnxEvidence -Note ('L_Data.con of the probe after {0:N1} ms, {1}' -f $onTp, $(if (($ld.Ctrl1 -band 0x01) -eq 0) { 'positive' } else { 'negative' }))
            }
            [Threading.Thread]::Sleep(500)
            [void](Clear-KnxTunnelTraffic -Connection $src -QuietMs 100)
            $kd = & $busyKernel $rig
            if (-not $kd.Ok) { Set-KnxTestNotRun -MissingInput 'kernel time stamps (dumpcap on a wired interface)' -Reason $kd.Reason }
            $d = & $kernelDelay $kd 0
            # Is the first indication after the ROUTING_BUSY back the probe itself?
            $tb0 = $kd.Busy[0].Ms
            $first = @($kd.Ri | Where-Object { $_.Ms -gt $tb0 + $busyInFlight } | Sort-Object Ms | Select-Object -First 1)
            $isProbe = $false
            if ($first.Count -eq 1) { $fl = Read-CemiLData -Cemi ([byte[]]$first[0].Bytes[6..($first[0].Bytes.Length - 1)]); $isProbe = ($null -ne $fl -and $fl.Destination -eq $p.Dst -and -not $fl.IsGroup) }
            Add-KnxEvidence -Note ("{0}; router BUSY after {1} indications; probe con after {2} ms; next indication {3} ms after the ROUTING_BUSY back (tw {4}), {5}" -f $kd.Note, $f.Sent, $(if ($onTp -ge 0) { '{0:N1}' -f $onTp } else { 'never' }), $(if ($d -ge 0) { '{0:N2}' -f $d } else { 'none' }), $tw, $(if ($isProbe) { 'the probe' } else { 'not the probe' }))
            if ($d -ge 0) { Assert-KnxTrue ($d -ge $tw) ('the router sent a ROUTING_INDICATION {0:N2} ms after the ROUTING_BUSY back, before tw = {1} ms' -f $d, $tw) }
            if ($onTp -lt 0 -or $onTp -ge $tw) { Set-KnxTestNotRun -MissingInput 'the probe on TP before tw' -Reason "no L_Data.con of the probe within tw = $tw ms, so it is not shown on TP before tw" }
            if (-not $isProbe) { Set-KnxTestNotRun -MissingInput 'the probe routed after the pause' -Reason 'the first indication after the ROUTING_BUSY back is not the probe, so the router holding it is not shown' }
            if ($d -lt 0) { Set-KnxTestNotRun -MissingInput 'an indication after the collision' -Reason 'the router sent no ROUTING_INDICATION within 1.5 s after the ROUTING_BUSY back, so t_d cannot be measured' }
        }
        finally { & $busyDone $rig }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-6.1.1' -Title 'Routing Indication - Standard Case 1 (IP to KNX)' -Clause 'TSSH 6.1.1, p.102' -Body {
        if (-not $Ctx.TrafficIp) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason 'needs a second interface (-TrafficIp) to observe the bus' }
        $watch = Get-KnxTrafficConnection -Ip $Ctx.TrafficIp
        Assert-KnxTrue ($null -ne $watch) 'no tunnel available on the traffic interface'
        try {
            [void](Clear-KnxTunnelTraffic -Connection $watch -QuietMs 500)
            $ga = ConvertTo-KnxGa -Address '0/0/22'
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_IND -Destination $ga -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)
            $sent = Send-RoutingIndication -Group $group -Port $port -Cemi $cemi
            Add-KnxEvidence -Sent $sent

            $seen = $null
            $deadline = [DateTime]::UtcNow.AddSeconds(6)
            while ([DateTime]::UtcNow -lt $deadline) {
                $in = Receive-KnxTunnelCemi -Connection $watch -TimeoutMs 1500
                if ($null -eq $in) { continue }
                $ld = Read-CemiLData -Cemi $in.Cemi
                if ($null -ne $ld -and $ld.Destination -eq $ga) { $seen = $in; break }
            }
            Assert-KnxTrue ($null -ne $seen) 'the routed telegram never reached the TP line'
            Add-KnxEvidence -Received $seen.Cemi
        }
        finally {
                # NOT closed: this is the shared traffic connection, and on an interface that grants one
                # channel and does not free it at once, closing it makes every later case wait or skip.
                # Draining gives the next case the same clean start without taking the channel away.
                [void](Clear-KnxTunnelTraffic -Connection $watch -QuietMs 200)
            }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-6.1.2' -Title 'Routing Indication - Standard Case 2 (KNX to IP)' -Clause 'TSSH 6.1.2, p.102' -Body {
        # The coupler may be configured not to route group telegrams at all. That does not excuse the
        # case: as configured, the device does not fulfil the clause, and that is what the report has
        # to say. The cause is recorded with the case so nobody has to guess where the FAIL comes from.
        if ($Ctx.PSObject.Properties['GroupRoutingLock'] -and $Ctx.GroupRoutingLock) {
            Add-KnxEvidence -Note "configuration: $($Ctx.GroupRoutingLock)"
        }
        if (-not $Ctx.TrafficIp) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason 'needs a second interface (-TrafficIp) to put a telegram on the bus' }
        $mc = New-KnxMulticastSocket -Group $group -Port $port -TimeoutMs 2000
        $src = Get-KnxTrafficConnection -Ip $Ctx.TrafficIp
        try {
            Assert-KnxTrue ($null -ne $src) 'no tunnel available on the traffic interface'
            $ga = ConvertTo-KnxGa -Address '0/0/23'
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $ga -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)
            [void](Send-KnxTunnelCemi -Connection $src -Cemi $cemi -TimeoutMs 3000)

            $seen = $null
            $deadline = [DateTime]::UtcNow.AddSeconds(6)
            while ([DateTime]::UtcNow -lt $deadline) {
                $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
                $r = Wait-KnxService -Socket $mc -Service @($K.Service.ROUTING_INDICATION) -TimeoutMs $left
                if ($r.TimedOut) { break }
                $ld = Read-CemiLData -Cemi $r.Header.Body
                if ($null -ne $ld -and $ld.Destination -eq $ga) { $seen = $r; break }
            }
            Assert-KnxTrue ($null -ne $seen) "the bus telegram was never emitted as ROUTING_INDICATION on $group"
            Add-KnxEvidence -Received $seen.Packet.Bytes
        }
        finally {
            $mc.Dispose()
        }
    }

    foreach ($case in @(
            @{ Id = 'H-6.1.3'; Title = 'Changed multicast address, Case 1'; Clause = 'TSSH 6.1.3, p.103' },
            @{ Id = 'H-6.1.4'; Title = 'Changed multicast address, Case 2'; Clause = 'TSSH 6.1.4, p.104' })) {
        Invoke-KnxTestCase -Suite $SuiteTitle -Id $case.Id -Title $case.Title -Clause $case.Clause -Body {
            if (-not $Ctx.AllowDestructive) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'rewrites PID_ROUTING_MULTICAST_ADDRESS - needs -IncludeDestructive with profile Full' }
            $mgmt = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
            Assert-KnxTrue $mgmt.Ok "could not open a device management connection ($($mgmt.StatusName))"
            $original = $null
            try {
                $r = Read-KnxProperty -Connection $mgmt -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.ROUTING_MULTICAST_ADDRESS
                Assert-KnxTrue ($null -ne $r.Parsed -and -not $r.Parsed.IsError) 'PID_ROUTING_MULTICAST_ADDRESS not readable'
                $original = [byte[]]$r.Parsed.Data[0..3]

                $newGroup = '224.0.23.14'
                $bytes = ([System.Net.IPAddress]::Parse($newGroup)).GetAddressBytes()
                $w = New-CemiMPropWrite -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.ROUTING_MULTICAST_ADDRESS -Data $bytes
                $wr = Send-KnxDeviceConfiguration -Connection $mgmt -Cemi $w -TimeoutMs 4000
                Assert-KnxTrue ($null -ne $wr.Parsed -and -not $wr.Parsed.IsError) 'could not write the routing multicast address'

                Start-Sleep -Seconds 2
                $back = Read-KnxProperty -Connection $mgmt -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.ROUTING_MULTICAST_ADDRESS
                Assert-KnxTrue ($null -ne $back.Parsed -and -not $back.Parsed.IsError) 'multicast address not readable after the write'
                Assert-KnxBytes $bytes ([byte[]]$back.Parsed.Data[0..3]) 'the device did not take over the new routing multicast address'
                Add-KnxEvidence -Note "switched to $newGroup and back"
            }
            finally {
                if ($null -ne $original -and $mgmt.Ok) {
                    $restore = New-CemiMPropWrite -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.ROUTING_MULTICAST_ADDRESS -Data $original
                    [void](Send-KnxDeviceConfiguration -Connection $mgmt -Cemi $restore -TimeoutMs 4000)
                }
                [void](Close-KnxConnection -Connection $mgmt)
            }
        }
    }

    foreach ($case in @(
            @{ Id = 'H-6.1.5'; Title = 'Property PID_MSG_TRANSMIT_TO_KNX'; Clause = 'TSSH 6.1.5, p.105'; ToKnx = $true },
            @{ Id = 'H-6.1.6'; Title = 'Property PID_MSG_TRANSMIT_TO_IP';  Clause = 'TSSH 6.1.6, p.107'; ToKnx = $false })) {
        $toKnx = $case.ToKnx
        Invoke-KnxTestCase -Suite $SuiteTitle -Id $case.Id -Title $case.Title -Clause $case.Clause -Body {
            if (-not $Ctx.TrafficIp) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason 'needs a second interface (-TrafficIp) to generate the routed traffic' }
            # The coupler may be configured not to route group telegrams at all. That does not excuse the
            # case: as configured, the device does not fulfil the clause, and that is what the report has
            # to say. The cause is recorded with the case so nobody has to guess where the FAIL comes from.
            if ($Ctx.PSObject.Properties['GroupRoutingLock'] -and $Ctx.GroupRoutingLock) {
                Add-KnxEvidence -Note "configuration: $($Ctx.GroupRoutingLock)"
            }
            # Not $pid - that is a read-only PowerShell automatic variable (the process id).
            $propId = if ($toKnx) { $K.Pid.MSG_TRANSMIT_TO_KNX } else { $K.Pid.MSG_TRANSMIT_TO_IP }
            $mgmt = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
            Assert-KnxTrue $mgmt.Ok "could not open a device management connection ($($mgmt.StatusName))"
            try {
                $before = Get-RoutingCounter -Connection $mgmt -PropertyId $propId
                Assert-KnxTrue ($before -ge 0) "counter property $propId not readable"

                if ($toKnx) {
                    $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_IND -Destination (ConvertTo-KnxGa -Address '0/0/24') -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)
                    foreach ($i in 1..3) { [void](Send-RoutingIndication -Group $group -Port $port -Cemi $cemi); Start-Sleep -Milliseconds 250 }
                }
                else {
                    $src = Get-KnxTrafficConnection -Ip $Ctx.TrafficIp
                    Assert-KnxTrue ($null -ne $src) 'no tunnel available on the traffic interface'
                    try {
                        $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination (ConvertTo-KnxGa -Address '0/0/25') -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)
                        foreach ($i in 1..3) { [void](Send-KnxTunnelCemi -Connection $src -Cemi $cemi -TimeoutMs 3000); [void](Wait-KnxTunnel -Connection $src -Ms 250) }
                    }
                    # Drained, not closed: this is the shared traffic connection (see above).
                    finally { [void](Clear-KnxTunnelTraffic -Connection $src -QuietMs 200) }
                }

                Start-Sleep -Seconds 2
                $after = Get-RoutingCounter -Connection $mgmt -PropertyId $propId
                Add-KnxEvidence -Note "counter $before -> $after after 3 routed telegrams"
                Assert-KnxTrue ($after -ge 0) "counter property $propId not readable after the traffic"
                Assert-KnxTrue ($after -gt $before) "counter did not advance ($before -> $after) although telegrams were routed"
            }
            finally { [void](Close-KnxConnection -Connection $mgmt) }
        }
    }

    # Validation tool 40206: PID 74 counts every KNXnet/IP telegram sent, including the device management answers
    # (03_08_03 2.5.25 p.15-16). A read costs a fixed number; each routed indication adds one, a telegram not routed none.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'P-6.1.6b' -Title 'PID_MSG_TRANSMIT_TO_IP advances by the cost of a read plus exactly one per routed indication' `
                       -Clause '03_08_03 2.5.25 p.15-16; 03_03_03 2.4.2.4.2 p.13 (hop count 0 is not routed); TSSH 6.1.6 p.107; validation tool 40206' -Body {
        if (-not $Ctx.TrafficIp) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason 'needs a second interface (-TrafficIp) to generate the routed traffic' }
        if ($Ctx.TrafficIp -eq $ip) { Set-KnxTestNotRun -MissingInput 'a -TrafficIp other than the router' -Reason 'the telegrams must come from TP' }
        if ($Ctx.PSObject.Properties['GroupRoutingLock'] -and $Ctx.GroupRoutingLock) { Set-KnxTestNotRun -MissingInput 'group routing' -Reason "the router is configured not to route group telegrams: $($Ctx.GroupRoutingLock)" }
        $listen = $null; $wit = $null
        $mgmt = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
        Assert-KnxTrue $mgmt.Ok "could not open a device management connection ($($mgmt.StatusName))"
        try {
            # Other devices on the line are routed and counted too; the listener places every indication between two reads.
            $listen = Start-KnxMcListener -Group $group -Port $port
            if (-not $listen.Ready) { Set-KnxTestNotRun -MissingInput 'a multicast reader on this host' -Reason 'the listener runspace did not start within 10 s' }
            $routedIn = { param([long]$From, [long]$To) @((Get-KnxMcFrames -Listener $listen -FromIp $ip -Service $K.Service.ROUTING_INDICATION -AfterTicks $From) | Where-Object { $_.T -le $To }) }
            $read = { $v = Get-RoutingCounter -Connection $mgmt -PropertyId $K.Pid.MSG_TRANSMIT_TO_IP; [pscustomobject]@{ V = $v; T = [Diagnostics.Stopwatch]::GetTimestamp() } }
            $r0 = & $read; Start-Sleep -Milliseconds 300; $r1 = & $read; Start-Sleep -Milliseconds 300; $r2 = & $read
            Assert-KnxTrue ($r0.V -ge 0 -and $r1.V -ge 0 -and $r2.V -ge 0) 'PID_MSG_TRANSMIT_TO_IP is not readable'
            $c1 = $r1.V - $r0.V - @(& $routedIn $r0.T $r1.T).Count
            $c2 = $r2.V - $r1.V - @(& $routedIn $r1.T $r2.T).Count
            Add-KnxEvidence -Note "reads without traffic: $($r0.V), $($r1.V), $($r2.V); cost of a read $c1, $c2"
            if ($c1 -ne $c2 -or $c1 -lt 0) { Set-KnxTestNotRun -MissingInput 'a router without other KNXnet/IP traffic' -Reason "the cost of one read is not stable ($c1, $c2): the router sends to other clients too" }
            $src = Get-KnxTrafficConnection -Ip $Ctx.TrafficIp
            Assert-KnxTrue ($null -ne $src) 'no tunnel available on the traffic interface'
            $ga25 = ConvertTo-KnxGa -Address '0/0/25'; $ga26 = ConvertTo-KnxGa -Address '0/0/26'
            try {
                $routedCemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $ga25 -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)
                $localCemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $ga26 -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1) -HopCount 0
                foreach ($i in 1..5) { [void](Send-KnxTunnelCemi -Connection $src -Cemi $routedCemi -TimeoutMs 3000); [void](Wait-KnxTunnel -Connection $src -Ms 250) }
                # A witness shows the hop-count-0 telegrams on TP; without one the "not routed" half is not exercised.
                if ($witnessIp) {
                    $w = Open-KnxBusWitness -WitnessIp $witnessIp -Port $port -TargetPa $Ctx.BdutPa -BdutIp $Ctx.TrafficIp
                    if ($w.Ok) { $wit = $w }
                }
                foreach ($i in 1..3) { [void](Send-KnxTunnelCemi -Connection $src -Cemi $localCemi -TimeoutMs 3000); [void](Wait-KnxTunnel -Connection $src -Ms 250) }
            }
            finally { [void](Clear-KnxTunnelTraffic -Connection $src -QuietMs 200) }
            $hop0OnTp = -1
            if ($null -ne $wit) {
                $seen = Read-KnxBusWitness -Witness $wit -WindowMs 800
                $hop0OnTp = @($seen | Where-Object { $l = [byte[]]$_.Lpdu; $l.Length -ge 8 -and (([int]$l[3] * 256) + [int]$l[4]) -eq $ga26 -and ($l[5] -band 0xF0) -eq 0x80 }).Count
            }
            Start-Sleep -Seconds 2
            $ra = & $read; Start-Sleep -Milliseconds 300; $r3 = & $read; Start-Sleep -Milliseconds 300; $r4 = & $read
            $routed = @(& $routedIn $r2.T $ra.T)
            $dstOf = { param($f) $ld = Read-CemiLData -Cemi ([byte[]]$f.Bytes[6..($f.Bytes.Length - 1)]); if ($null -eq $ld) { -1 } else { $ld.Destination } }
            $ours = @($routed | Where-Object { (& $dstOf $_) -eq $ga25 })
            $local = @($routed | Where-Object { (& $dstOf $_) -eq $ga26 })
            $c3 = $r3.V - $ra.V - @(& $routedIn $ra.T $r3.T).Count
            $c4 = $r4.V - $r3.V - @(& $routedIn $r3.T $r4.T).Count
            $expected = $r2.V + $c1 + $routed.Count
            Add-KnxEvidence -Note "after 5 routed (0/0/25) and 3 not routed (0/0/26, hop count 0, $(if ($hop0OnTp -ge 0) { "$hop0OnTp seen on TP with hop count 0" } else { 'no witness' })): $($ra.V); the router routed $($routed.Count) indications ($($ours.Count) to 0/0/25, $($local.Count) to 0/0/26); expected $expected; reads after $c3, $c4"
            if ($ours.Count -eq 0) { Set-KnxTestNotRun -MissingInput 'multicast reception on this host' -Reason 'not one routed indication reached this host' }
            # Read stamps are taken after the answer, listener stamps in a thread of its own: traffic close to a read is not placed.
            $near = @(@(& $routedIn $r0.T $r4.T) | Where-Object { $t = $_.T; @($r0, $r1, $r2, $ra, $r3, $r4 | Where-Object { [Math]::Abs((ConvertTo-KnxMs ($t - $_.T))) -lt 30 }).Count -gt 0 })
            if ($near.Count -gt 0) { Set-KnxTestNotRun -MissingInput 'no line traffic close to a read' -Reason "$($near.Count) routed indication(s) within 30 ms of a counter read cannot be placed" }
            if ($c3 -ne $c1 -or $c4 -ne $c1) { Set-KnxTestNotRun -MissingInput 'a router without other KNXnet/IP traffic' -Reason "the cost of one read changed after the traffic ($c3, $c4 instead of $c1): the router sent to other clients in the window" }
            if ($hop0OnTp -gt 0) { Assert-KnxEqual 0 $local.Count 'the router routed telegrams that carried hop count 0 on TP' }
            elseif ($local.Count -gt 0) { Set-KnxTestNotRun -MissingInput 'a witness that shows hop count 0 on TP' -Reason 'telegrams sent with hop count 0 were routed; nothing shows they carried hop count 0 on TP' }
            Assert-KnxEqual 5 $ours.Count 'the router did not route each of the five telegrams to 0/0/25 once'
            # Precondition, as for the tool: no other client on the router (each tunnel would count every TP telegram too).
            Assert-KnxEqual $expected $ra.V 'PID_MSG_TRANSMIT_TO_IP is not the read cost plus one per routed indication'
        }
        finally {
            if ($null -ne $wit) { try { [void](Close-KnxConnection -Connection $wit.Conn) } catch { } }
            if ($null -ne $listen) { Stop-KnxMcListener $listen }
            [void](Close-KnxConnection -Connection $mgmt)
        }
    }

    foreach ($case in @(
            @{ Id = 'H-6.1.7'; Title = 'Routing Indication - Mixed Case 1'; Clause = 'TSSH 6.1.7, p.109' },
            @{ Id = 'H-6.1.8'; Title = 'Routing Indication - Mixed Case 2'; Clause = 'TSSH 6.1.8, p.110' },
            @{ Id = 'H-6.1.9'; Title = 'Routing Indication - Mixed Case 3'; Clause = 'TSSH 6.1.9, p.111' })) {
        Invoke-KnxTestCase -Suite $SuiteTitle -Id $case.Id -Title $case.Title -Clause $case.Clause -Body {
            if (-not $Ctx.TrafficIp) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason 'needs a second interface (-TrafficIp) to drive both directions' }
            # The coupler may be configured not to route group telegrams at all. That does not excuse the
            # case: as configured, the device does not fulfil the clause, and that is what the report has
            # to say. The cause is recorded with the case so nobody has to guess where the FAIL comes from.
            if ($Ctx.PSObject.Properties['GroupRoutingLock'] -and $Ctx.GroupRoutingLock) {
                Add-KnxEvidence -Note "configuration: $($Ctx.GroupRoutingLock)"
            }
            # Mixed = traffic in both directions at once; nothing may be lost or duplicated.
            $mc = New-KnxMulticastSocket -Group $group -Port $port -TimeoutMs 2000
            $src = Get-KnxTrafficConnection -Ip $Ctx.TrafficIp
            try {
                Assert-KnxTrue ($null -ne $src) 'no tunnel available on the traffic interface'
                $gaUp = ConvertTo-KnxGa -Address '0/0/26'
                $gaDown = ConvertTo-KnxGa -Address '0/0/27'
                $down = New-CemiLData -MessageCode $K.Cemi.L_DATA_IND -Destination $gaDown -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)
                $up = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $gaUp -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)

                foreach ($i in 1..3) {
                    [void](Send-RoutingIndication -Group $group -Port $port -Cemi $down)
                    [void](Send-KnxTunnelCemi -Connection $src -Cemi $up -TimeoutMs 3000)
                    [void](Wait-KnxTunnel -Connection $src -Ms 200)
                }

                $upSeen = 0
                $deadline = [DateTime]::UtcNow.AddSeconds(6)
                while ([DateTime]::UtcNow -lt $deadline) {
                    $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
                    $r = Wait-KnxService -Socket $mc -Service @($K.Service.ROUTING_INDICATION) -TimeoutMs $left
                    if ($r.TimedOut) { break }
                    $ld = Read-CemiLData -Cemi $r.Header.Body
                    if ($null -ne $ld -and $ld.Destination -eq $gaUp) { $upSeen++ }
                }
                Add-KnxEvidence -Note "$upSeen of 3 KNX-to-IP telegrams observed while routing in both directions"
                Assert-KnxTrue ($upSeen -ge 1) 'no KNX-to-IP telegram survived the bidirectional load'
                Assert-KnxTrue (Test-KnxAlive -Ip $ip -Port $port) 'device stopped answering under bidirectional routing load'
            }
            finally {
                $mc.Dispose()
            }
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-6.2.1' -Title 'Routing Lost Message - Standard Case' -Clause 'TSSH 6.2.1, p.111' -Body {
        # The coupler may be configured not to route group telegrams at all. That does not excuse the
        # case: as configured, the device does not fulfil the clause, and that is what the report has
        # to say. The cause is recorded with the case so nobody has to guess where the FAIL comes from.
        if ($Ctx.PSObject.Properties['GroupRoutingLock'] -and $Ctx.GroupRoutingLock) {
            Add-KnxEvidence -Note "configuration: $($Ctx.GroupRoutingLock)"
        }
        if (-not $Ctx.AllowDestructive) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'overloads the router on purpose - needs -IncludeDestructive with profile Full' }
        $mc = New-KnxMulticastSocket -Group $group -Port $port -TimeoutMs 2000
        try {
            # Push faster than TP can carry until the device reports the overflow.
            $s = New-KnxSocket -TimeoutMs 500
            try {
                $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_IND -Destination (ConvertTo-KnxGa -Address '0/0/28') -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)
                $f = New-KnxRoutingIndication -Cemi $cemi
                foreach ($i in 1..300) { Send-KnxFrame -Socket $s -Frame $f -Ip $group -Port $port }
            }
            finally { $s.Dispose() }

            $lost = $null
            $busy = $null
            $deadline = [DateTime]::UtcNow.AddSeconds(6)
            while ([DateTime]::UtcNow -lt $deadline) {
                $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
                $r = Wait-KnxService -Socket $mc -Service @($K.Service.ROUTING_LOST_MESSAGE, $K.Service.ROUTING_BUSY) -TimeoutMs $left
                if ($r.TimedOut) { break }
                if ($r.Header.Service -eq $K.Service.ROUTING_LOST_MESSAGE) { $lost = $r; break }
                if ($r.Header.Service -eq $K.Service.ROUTING_BUSY) { $busy = $r }
            }
            if ($null -ne $lost) { Add-KnxEvidence -Received $lost.Packet.Bytes -Note 'ROUTING_LOST_MESSAGE observed' }
            elseif ($null -ne $busy) { Add-KnxEvidence -Received $busy.Packet.Bytes -Note 'only ROUTING_BUSY observed' }
            Assert-KnxTrue (($null -ne $lost) -or ($null -ne $busy)) 'router neither reported ROUTING_LOST_MESSAGE nor ROUTING_BUSY while being overloaded'
            Assert-KnxTrue (Test-KnxAlive -Ip $ip -Port $port) 'device stopped answering after the overload'
        }
        finally { $mc.Dispose() }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-6.2.2' -Title 'Routing Lost Message - Continuous overflow' -Clause 'TSSH 6.2.2, p.112' -Body {
        # The coupler may be configured not to route group telegrams at all. That does not excuse the
        # case: as configured, the device does not fulfil the clause, and that is what the report has
        # to say. The cause is recorded with the case so nobody has to guess where the FAIL comes from.
        if ($Ctx.PSObject.Properties['GroupRoutingLock'] -and $Ctx.GroupRoutingLock) {
            Add-KnxEvidence -Note "configuration: $($Ctx.GroupRoutingLock)"
        }
        if (-not $Ctx.AllowDestructive) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'sustained overload - needs -IncludeDestructive with profile Full' }
        $mc = New-KnxMulticastSocket -Group $group -Port $port -TimeoutMs 2000
        try {
            $s = New-KnxSocket -TimeoutMs 500
            $reports = 0
            try {
                $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_IND -Destination (ConvertTo-KnxGa -Address '0/0/29') -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)
                $f = New-KnxRoutingIndication -Cemi $cemi
                $end = [DateTime]::UtcNow.AddSeconds(15)
                while ([DateTime]::UtcNow -lt $end) {
                    foreach ($i in 1..50) { Send-KnxFrame -Socket $s -Frame $f -Ip $group -Port $port }
                    $r = Wait-KnxService -Socket $mc -Service @($K.Service.ROUTING_LOST_MESSAGE, $K.Service.ROUTING_BUSY) -TimeoutMs 200
                    if (-not $r.TimedOut) { $reports++ }
                }
            }
            finally { $s.Dispose() }
            Add-KnxEvidence -Note "$reports overflow report(s) during 15 s of sustained overload"
            Assert-KnxTrue ($reports -ge 1) 'router never reported an overflow during sustained overload'
            # The point of the case is that the device survives, not just that it complains.
            Assert-KnxTrue (Test-KnxAlive -Ip $ip -Port $port) 'device stopped answering after sustained overload'
        }
        finally { $mc.Dispose() }
    }

    # Validation tool 40102: every telegram sent is either routed or counted in a ROUTING_LOST_MESSAGE (03_08_05 2.3.4).
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'P-6.2.2b' -Title 'Continuous overflow: lost (ROUTING_LOST_MESSAGE) plus routed equals sent, and PID 73 equals the reported loss' `
                       -Clause '03_08_05 2.3.4 p.10; 03_08_03 2.5.24 p.15; TSSH 6.2.2 p.112; validation tool 40102' -Body {
        if (-not $Ctx.AllowDestructive) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'overloads the router on purpose - needs -IncludeDestructive with profile Full' }
        if (-not $Ctx.TrafficIp) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason 'needs a second interface on the TP line to count what the router puts on the bus' }
        if (-not $tpLine) { Set-KnxTestNotRun -MissingInput '-BdutPa' -Reason 'the router individual address is unknown (-BdutPa)' }
        if ($Ctx.PSObject.Properties['GroupRoutingLock'] -and $Ctx.GroupRoutingLock) { Set-KnxTestNotRun -MissingInput 'group routing' -Reason "the router is configured not to route group telegrams: $($Ctx.GroupRoutingLock)" }
        # A second router of the line on the group would put the same telegrams on TP.
        $disc = Find-KnxLineRouters -ExcludeIp $ip -Group $group -Line $tpLine -Port $port
        if (-not $disc.DutAnswered) { Set-KnxTestNotRun -MissingInput 'discovery on 224.0.23.12' -Reason 'the router did not answer SEARCH, so no other router of the line can be ruled out' }
        $others = @($disc.Routers | Where-Object { $_.SameLine })
        if ($others.Count -gt 0) { Set-KnxTestNotRun -MissingInput "no other router of line $tpLine on $group" -Reason ("it routes the same telegrams: " + (($others | ForEach-Object { "$($_.Ip) ($($_.Pa))" }) -join ', ')) }
        $total = 1000; $intervalMs = 10.0
        $ga = ConvertTo-KnxGa -Address '0/0/30'; $gaUp = ConvertTo-KnxGa -Address '0/0/31'
        # Numbered like TSSH 6.2.2 p.112, so a repetition on TP is not counted as a second routed telegram.
        $frames = foreach ($i in 0..($total - 1)) { , (New-KnxRoutingIndication -Cemi (New-CemiLData -MessageCode $K.Cemi.L_DATA_IND -Destination $ga -IsGroup -Tpdu ([byte[]]@(0x00, 0x80, (($i -shr 8) -band 0xFF), ($i -band 0xFF))))) }
        $dm = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
        Assert-KnxTrue $dm.Ok "could not open a device management connection ($($dm.StatusName))"
        $mc = $null; $s = $null
        try {
            $src = Get-KnxTrafficConnection -Ip $Ctx.TrafficIp
            Assert-KnxTrue ($null -ne $src) 'no tunnel available on the traffic interface'
            $mc = New-KnxMulticastSocket -Group $group -Port $port -TimeoutMs 1
            $s = New-KnxSocket -TimeoutMs 200
            $acc = @{ Seq = (New-Object 'System.Collections.Generic.HashSet[int]'); Orig = @{}; Copies = 0; LostSum = 0; LostMsgs = 0; Up = 0 }
            $buf = New-Object byte[] 1500
            # Reads what is waiting on both sides: numbered telegrams to $ga on TP, the router's LOST messages and its indications to $gaUp.
            $drain = {
                param([int]$Ms)
                $sw = [Diagnostics.Stopwatch]::StartNew()
                do {
                    while ($mc.Available -gt 0) {
                        $ep = [Net.EndPoint](New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0))
                        $n = $mc.ReceiveFrom($buf, [ref]$ep)
                        if ($n -lt 10 -or ([Net.IPEndPoint]$ep).Address.ToString() -ne $ip -or $buf[2] -ne 0x05) { continue }
                        if ($buf[3] -eq 0x31) { $acc.LostSum += ([int]$buf[8] * 256) + [int]$buf[9]; $acc.LostMsgs++ }
                        elseif ($buf[3] -eq 0x30) { $ld = Read-CemiLData -Cemi ([byte[]]$buf[6..($n - 1)]); if ($null -ne $ld -and $ld.Destination -eq $gaUp) { $acc.Up++ } }
                    }
                    # Read and acknowledged every pass: an unacknowledged tunnel indication makes the interface end the tunnel.
                    $in = Receive-KnxTunnelCemi -Connection $src -TimeoutMs 1
                    if ($null -ne $in) {
                        $ld = Read-CemiLData -Cemi $in.Cemi
                        if ($null -ne $ld -and $ld.Destination -eq $ga -and $ld.MessageCode -eq $K.Cemi.L_DATA_IND -and $ld.Tpdu.Length -ge 4) {
                            $seq = (([int]$ld.Tpdu[2]) * 256) + [int]$ld.Tpdu[3]
                            $acc.Copies++; [void]$acc.Seq.Add($seq)
                            if (-not $ld.IsRepeated) { $acc.Orig[$seq] = 1 + $(if ($acc.Orig.ContainsKey($seq)) { $acc.Orig[$seq] } else { 0 }) }
                        }
                    }
                } while ($sw.ElapsedMilliseconds -lt $Ms)
            }
            # A preceding overload may still be reported (one ROUTING_LOST_MESSAGE per second): wait for 2 s without one.
            $settle = [Diagnostics.Stopwatch]::StartNew(); $quietSince = [Diagnostics.Stopwatch]::StartNew()
            while ($quietSince.Elapsed.TotalSeconds -lt 2 -and $settle.Elapsed.TotalSeconds -lt 20) {
                $before = $acc.LostMsgs
                & $drain 200
                if ($acc.LostMsgs -ne $before) { $quietSince.Restart() }
            }
            if ($quietSince.Elapsed.TotalSeconds -lt 2) { Set-KnxTestNotRun -MissingInput 'a router without a running overload' -Reason 'ROUTING_LOST_MESSAGEs kept arriving for 20 s before the case' }
            # Proofs first: a telegram from TP reaches this host, and one from here reaches TP through the traffic tunnel.
            [void](Send-KnxTunnelCemi -Connection $src -Cemi (New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $gaUp -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)) -TimeoutMs 1000)
            Send-KnxFrame -Socket $s -Frame (New-KnxRoutingIndication -Cemi (New-CemiLData -MessageCode $K.Cemi.L_DATA_IND -Destination $ga -IsGroup -Tpdu ([byte[]]@(0x00, 0x80, 0xFF, 0xFF)))) -Ip $group -Port $port
            & $drain 2000
            if ($acc.Up -eq 0) { Set-KnxTestNotRun -MissingInput 'multicast reception on this host' -Reason 'a telegram routed from TP did not reach this host, so ROUTING_LOST_MESSAGEs could not be counted' }
            if (-not $acc.Seq.Contains(0xFFFF)) { Set-KnxTestNotRun -MissingInput 'the probe telegram on TP' -Reason 'a single indication to 0/0/30 did not reach the traffic tunnel (filter table, tunnel or routing)' }
            $acc.Seq.Clear(); $acc.Orig.Clear(); $acc.Copies = 0; $acc.LostSum = 0; $acc.LostMsgs = 0
            $ov0 = Get-RoutingCounter -Connection $dm -PropertyId $K.Pid.QUEUE_OVERFLOW_TO_KNX
            Assert-KnxTrue ($ov0 -ge 0) 'PID_QUEUE_OVERFLOW_TO_KNX (73) is not readable'
            $tick = [Diagnostics.Stopwatch]::Frequency * $intervalMs / 1000.0
            $next = [Diagnostics.Stopwatch]::GetTimestamp()
            for ($i = 0; $i -lt $total; $i++) {
                while ([Diagnostics.Stopwatch]::GetTimestamp() -lt $next) { & $drain 0 }
                Send-KnxFrame -Socket $s -Frame $frames[$i] -Ip $group -Port $port
                $next += $tick
            }
            # The router drains its queue at bus speed and reports a loss about once per second: collect until 5 s pass without news.
            $quiet = [Diagnostics.Stopwatch]::StartNew(); $last = -1
            while ($quiet.Elapsed.TotalSeconds -lt 5) {
                & $drain 200
                $now = $acc.Seq.Count + $acc.LostSum
                if ($now -ne $last) { $last = $now; $quiet.Restart() }
            }
            if (Test-KnxTunnelGone -Connection $src) { Set-KnxTestNotRun -MissingInput 'a traffic tunnel that stays up' -Reason 'the traffic interface ended the tunnel during the case, so the count on TP is incomplete' }
            $seenTp = $acc.Seq.Count; $lostSum = $acc.LostSum; $lostMsgs = $acc.LostMsgs
            $twice = @($acc.Orig.Keys | Where-Object { $acc.Orig[$_] -gt 1 })
            $ov1 = Get-RoutingCounter -Connection $dm -PropertyId $K.Pid.QUEUE_OVERFLOW_TO_KNX
            Add-KnxEvidence -Note "$total sent at $intervalMs ms; on TP $seenTp different ($($acc.Copies) copies, $($twice.Count) sent twice as original); $lostMsgs ROUTING_LOST_MESSAGE(s) reporting $lostSum; PID 73 $ov0 -> $ov1; unaccounted $($total - $seenTp - $lostSum)"
            Assert-KnxTrue ($lostMsgs -ge 1) 'the router reported no loss although it was sent more than TP carries'
            # PID 73 is an unsigned int that does not wrap (03_08_03 2.5.24 p.15): near 65535 it cannot show the whole loss.
            if ($ov0 + $total -le 65535) { Assert-KnxEqual $lostSum ($ov1 - $ov0) 'PID_QUEUE_OVERFLOW_TO_KNX advanced by another number than the ROUTING_LOST_MESSAGEs reported' }
            else { Add-KnxEvidence -Note "PID 73 not compared: $ov0 is within $total of its limit 65535" }
            Assert-KnxEqual $total ($seenTp + $lostSum) 'reported loss plus telegrams seen on TP is not the number sent'
        }
        finally {
            if ($null -ne $s) { $s.Dispose() }
            if ($null -ne $mc) { $mc.Dispose() }
            [void](Close-KnxConnection -Connection $dm)
        }
    }

    # The router's TP side repeats a frame nobody acknowledges (03_02_02 p.40); every frame queued behind it must still leave.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'P-6.TX.1' -Title 'Telegrams queued behind a frame nobody acknowledges all reach TP' `
                       -Clause '03_02_02 2.4.2 p.40 (repetition of an unacknowledged frame); 03_08_05 3.7.1 p.13 (queued telegrams are routed)' -Body {
        if (-not $Ctx.TrafficIp) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason 'needs a second interface on the TP line to count what the router puts on the bus' }
        if (-not $tpLine) { Set-KnxTestNotRun -MissingInput '-BdutPa' -Reason 'the router individual address is unknown (-BdutPa)' }
        if ($Ctx.PSObject.Properties['GroupRoutingLock'] -and $Ctx.GroupRoutingLock) { Set-KnxTestNotRun -MissingInput 'group routing' -Reason "the router is configured not to route group telegrams: $($Ctx.GroupRoutingLock)" }
        $src = Get-KnxTrafficConnection -Ip $Ctx.TrafficIp
        Assert-KnxTrue ($null -ne $src) 'no tunnel available on the traffic interface'
        $ga = ConvertTo-KnxGa -Address '0/0/32'
        $absent = ConvertTo-KnxPa -Address "$tpLine.250"
        $s = New-KnxSocket -TimeoutMs 200
        # One round: optionally a frame to an absent address, then five numbered group frames 20 ms apart; returns how many reached TP.
        $round = {
            param([int]$Base, [switch]$Unacked)
            [void](Clear-KnxTunnelTraffic -Connection $src -QuietMs 200)
            if ($Unacked) { Send-KnxFrame -Socket $s -Frame (New-KnxRoutingIndication -Cemi (New-CemiLData -MessageCode $K.Cemi.L_DATA_IND -Destination $absent -Tpdu (New-TpduDisconnect))) -Ip $group -Port $port }
            foreach ($i in 0..4) {
                Send-KnxFrame -Socket $s -Frame (New-KnxRoutingIndication -Cemi (New-CemiLData -MessageCode $K.Cemi.L_DATA_IND -Destination $ga -IsGroup -Tpdu ([byte[]]@(0x00, 0x80, 0x00, [byte]($Base + $i))))) -Ip $group -Port $port
                [Threading.Thread]::Sleep(20)
            }
            $got = New-Object 'System.Collections.Generic.HashSet[int]'
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while ($sw.ElapsedMilliseconds -lt 3000) {
                $in = Receive-KnxTunnelCemi -Connection $src -TimeoutMs 100
                if ($null -eq $in) { continue }
                $ld = Read-CemiLData -Cemi $in.Cemi
                if ($null -ne $ld -and $ld.Destination -eq $ga -and $ld.Tpdu.Length -ge 4 -and $ld.Tpdu[3] -ge $Base -and $ld.Tpdu[3] -lt $Base + 5) { [void]$got.Add([int]$ld.Tpdu[3]) }
            }
            $got.Count
        }
        try {
            $ctl = & $round 0
            Add-KnxEvidence -Note "control (no unacknowledged frame before): $ctl of 5 on TP"
            if ($ctl -ne 5) { Set-KnxTestNotRun -MissingInput 'routing of 0/0/32 to TP' -Reason "only $ctl of 5 control frames reached the traffic tunnel" }
            $res = @(foreach ($r in 1..3) { & $round (10 * $r) -Unacked })
            Add-KnxEvidence -Note ("behind a frame to the absent $tpLine.250: {0} of 5 per round" -f ($res -join ', '))
            Assert-KnxTrue (@($res | Where-Object { $_ -ne 5 }).Count -eq 0) ("telegrams behind an unacknowledged frame were lost: {0} of 5 per round" -f ($res -join ', '))
            Assert-KnxTrue (Test-KnxAlive -Ip $ip -Port $port) 'the router stopped answering'
        }
        finally { $s.Dispose() }
    }

    # Validation tool 60206: in cEMI Transport Layer mode the transport layer serves the device management connection only.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-6.TL.1' -Title 'With a device management connection open, a routed T_Data_Individual read gets no answer' `
                       -Clause 'TSSH 8.3.6 p.163-164 (fn 60206); 03_08_03 2.6.1.2 and 2.6.1.6 p.18' -Body {
        if (-not $tpLine) { Set-KnxTestNotRun -MissingInput '-BdutPa' -Reason 'the router individual address is unknown (-BdutPa)' }
        $bdut = ConvertTo-KnxPa -Address $Ctx.BdutPa
        $peer = ConvertTo-KnxPa -Address "$tpLine.255"
        # A_PropertyValue_Read object index 0, PID_PROGMODE (54), one element from index 1, as in TSSH 8.3.6.
        $read = [byte[]]@(0x03, 0xD5, 0x00, 0x36, 0x10, 0x01)
        $routed = New-KnxRoutingIndication -Cemi (New-CemiLData -MessageCode $K.Cemi.L_DATA_IND -Source $peer -Destination $bdut -Tpdu $read -Priority 0)
        $listen = $null; $s = $null; $dm = $null
        try {
            $listen = Start-KnxMcListener -Group $group -Port $port
            if (-not $listen.Ready) { Set-KnxTestNotRun -MissingInput 'a multicast reader on this host' -Reason 'the listener runspace did not start within 10 s' }
            $s = New-KnxSocket -TimeoutMs 200
            # Routed A_PropertyValue_Responses from the router to the peer, after a stamp.
            $answers = {
                param([long]$After)
                @((Get-KnxMcFrames -Listener $listen -FromIp $ip -Service $K.Service.ROUTING_INDICATION -AfterTicks $After) | Where-Object {
                    $_.Bytes.Length -ge 16 -and $(
                        $ld = Read-CemiLData -Cemi ([byte[]]$_.Bytes[6..($_.Bytes.Length - 1)])
                        $null -ne $ld -and -not $ld.IsGroup -and $ld.Source -eq $bdut -and $ld.Destination -eq $peer -and $ld.Tpdu.Length -ge 2 -and (Get-TpduApci -Tpdu $ld.Tpdu) -eq 0x3D6) })
            }
            # Next T_Data_Individual.ind on the connection; every other DEVICE_CONFIGURATION_REQUEST (e.g. M_PropInfo.ind) is acked and noted.
            $nextInd = {
                param([int]$Ms)
                $until = [DateTime]::UtcNow.AddMilliseconds($Ms)
                while ([DateTime]::UtcNow -lt $until) {
                    $w = Wait-KnxService -Socket $dm.Socket -Service @($K.Service.DEVICE_CONFIGURATION_REQUEST) -TimeoutMs ([int][Math]::Max(1, ($until - [DateTime]::UtcNow).TotalMilliseconds))
                    if ($w.TimedOut) { break }
                    $b = $w.Header.Body
                    Send-KnxFrame -Socket $dm.Socket -Frame (New-KnxDeviceConfigurationAck -Channel $b[1] -Sequence $b[2]) -Ip $dm.Ip -Port $dm.Port
                    if ($b.Length -gt 4 -and $b[4] -eq 0x94) { return , ([byte[]]$b[4..($b.Length - 1)]) }
                    Add-KnxEvidence -Note ("other frame on the connection, message code 0x{0:X2}" -f $(if ($b.Length -gt 4) { $b[4] } else { 0 }))
                }
                return $null
            }
            # Control: without the mode the router answers the routed read, so silence later is the mode's doing.
            $t0 = [Diagnostics.Stopwatch]::GetTimestamp()
            Send-KnxFrame -Socket $s -Frame $routed -Ip $group -Port $port
            Start-Sleep -Milliseconds 2000
            $ctl = @(& $answers $t0).Count
            Add-KnxEvidence -Sent $routed -Note "without device management: $ctl routed answer(s) from $($Ctx.BdutPa) to $tpLine.255"
            if ($ctl -eq 0) { Set-KnxTestNotRun -MissingInput 'a routed answer without device management' -Reason "the router did not answer the routed read from $tpLine.255 over IP, so its silence in the mode would prove nothing" }

            $dm = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
            Assert-KnxTrue $dm.Ok "could not open a device management connection ($($dm.StatusName))"
            # Part 1: the same read through the device management connection is answered there and not over routing.
            $t1 = [Diagnostics.Stopwatch]::GetTimestamp()
            $r = Send-KnxDeviceConfiguration -Connection $dm -Cemi (New-CemiTransport -MessageCode 0x4A -Tpdu $read) -TimeoutMs 3000
            Assert-KnxTrue $r.Acked 'no DEVICE_CONFIGURATION_ACK for the T_Data_Individual.req'
            $ind = $r.Cemi
            if ($null -ne $ind -and $ind[0] -ne 0x94) { Add-KnxEvidence -Note ("other frame on the connection, message code 0x{0:X2}" -f $ind[0]); $ind = & $nextInd 3000 }
            if ($null -eq $ind) { Set-KnxTestNotApplicable 'the device acknowledged the T_Data_Individual.req and stayed silent. 03_08_03 2.6.1.2 p.18 (exception handling) allows a cEMI server without the mode, although 2.6.1.1 asks devices using device management to implement it - not judged here' }
            Add-KnxEvidence -Received $ind
            $ld = Read-CemiLData -Cemi $ind
            Assert-KnxTrue ($null -ne $ld -and $ld.Tpdu.Length -ge 7 -and (Get-TpduApci -Tpdu $ld.Tpdu) -eq 0x3D6) 'the answer on the device management connection is not an A_PropertyValue_Response with a value'
            Assert-KnxTrue ($ld.Tpdu[2] -eq 0x00 -and $ld.Tpdu[3] -eq 0x36 -and $ld.Tpdu[4] -eq 0x10 -and $ld.Tpdu[5] -eq 0x01) ('the answer is not element 1 of PID_PROGMODE in object 0: {0}' -f (($ld.Tpdu | ForEach-Object { '{0:X2}' -f $_ }) -join ' '))
            # TSSH 8.3.6 (1): the value agrees with the device status (bit 0 = programming mode); DESCRIPTION_RESPONSE carries the same DIB as SEARCH_RESPONSE.
            $desc = Get-KnxDescription -Ip $ip -Port $port
            Assert-KnxTrue ($null -ne $desc -and $null -ne $desc.Device) 'no DESCRIPTION_RESPONSE to compare the programming mode with'
            Assert-KnxEqual ([int]$desc.Device.ProgMode) ($ld.Tpdu[6] -band 0x01) 'PID_PROGMODE over the device management connection disagrees with the device status in the DIB'
            Start-Sleep -Milliseconds 700
            Assert-KnxEqual 0 @(& $answers $t1).Count 'the read through the device management connection was also answered over routing'

            # Part 2: the routed read while the mode is on gets no answer, neither over routing nor on the connection.
            $t2 = [Diagnostics.Stopwatch]::GetTimestamp()
            Send-KnxFrame -Socket $s -Frame $routed -Ip $group -Port $port
            $leak = & $nextInd 2500
            if ($null -ne $leak) { Add-KnxEvidence -Received $leak }
            $inMode = @(& $answers $t2).Count
            Add-KnxEvidence -Note "with device management open: $inMode routed answer(s), $(if ($null -eq $leak) { 'no' } else { 'a' }) T_Data_Individual.ind on the connection"
            Assert-KnxEqual 0 $inMode 'the router answered the routed T_Data_Individual read while the transport layer was in cEMI Transport Layer mode'
            Assert-KnxTrue ($null -eq $leak) 'the router passed the routed read to the device management connection'

            # The mode ends with the connection (2.6.1.6): the routed read is answered again.
            $closed = Close-KnxConnection -Connection $dm; $dm = $null
            Assert-KnxEqual 0 @(& $answers $t2).Count 'the router answered the routed read late, while the transport layer was still in cEMI Transport Layer mode'
            if (-not $closed) { Set-KnxTestNotRun -MissingInput 'a confirmed DISCONNECT of the device management connection' -Reason 'the close was not confirmed, so the mode may still be on and the read after it proves nothing' }
            Start-Sleep -Milliseconds 700
            $t3 = [Diagnostics.Stopwatch]::GetTimestamp()
            Send-KnxFrame -Socket $s -Frame $routed -Ip $group -Port $port
            Start-Sleep -Milliseconds 2000
            $after = @(& $answers $t3).Count
            Add-KnxEvidence -Note "after the connection closed: $after routed answer(s)"
            Assert-KnxTrue ($after -ge 1) 'the router still ignored the routed read after the device management connection closed'
        }
        finally {
            if ($null -ne $dm -and $dm.Ok) { [void](Close-KnxConnection -Connection $dm) }
            if ($null -ne $s) { $s.Dispose() }
            if ($null -ne $listen) { Stop-KnxMcListener $listen }
        }
    }

    # ── IP system broadcast: the mode decides how a TP system broadcast reaches IP ─────────────

    foreach ($case in @(
            @{ Id = 'K-2.4.3'; Mode = 1; Title = 'System broadcast is routed to IP as ROUTING_SYSTEM_BROADCAST when the mode is enabled'; Clause = '03_02_06 4.1.3 p.8; 08_TSSK 2.4.3 (80103) p.162' },
            @{ Id = 'K-2.4.4'; Mode = 0; Title = 'System broadcast is routed to IP as ROUTING_INDICATION when the mode is disabled'; Clause = '03_02_06 4.1.3 p.8; 08_TSSK 2.4.4 (80104) p.164' })) {
        Invoke-KnxTestCase -Suite $SuiteTitle -Id $case.Id -Title $case.Title -Clause $case.Clause -Body {
            if (-not $Ctx.IsRouter) { Set-KnxTestSkip 'the IP System Broadcast Routing Mode lives on the router object; an interface carries none' }
            if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case writes a property and puts one telegram on the bus' }
            if (-not $Ctx.TrafficIp) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason 'needs a second interface on the same TP line (-TrafficIp) to put the system broadcast on the bus' }
            # Mode 1 makes the router send ROUTING_SYSTEM_BROADCAST to 224.0.23.12, whatever the routing group.
            if ($case.Mode -eq 1 -and -not $isolated) { Set-KnxTestNotRun -MissingInput '-IsolatedNetwork' -Reason 'with the mode on the router sends on 224.0.23.12 - only on an isolated rig' }

            $dm = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
            Assert-KnxTrue ($dm -and $dm.Ok) 'no device-management connection for the mode property'
            try {
                $reported = Set-KnxIpSbcMode -Connection $dm -Mode $case.Mode
                Add-KnxEvidence -Note ("mode requested {0}, device reports {1}" -f $case.Mode, $reported)
                Assert-KnxTrue ($reported -eq $case.Mode) 'the device did not take the IP System Broadcast Routing Mode'

                $seen = Get-KnxSystemBroadcastEcho -InjectorIp $Ctx.TrafficIp -DeviceIp $ip -RoutingGroup $Ctx.Multicast -Port $port
                Assert-KnxTrue ($null -ne $seen) 'no tunnel on the traffic interface to inject the system broadcast'

                $sbc = @($seen | Where-Object { $_.Service -eq $K.Service.ROUTING_SYSTEM_BROADCAST })
                $ind = @($seen | Where-Object { $_.Service -eq $K.Service.ROUTING_INDICATION })
                foreach ($s in $seen) { Add-KnxEvidence -Received $s.Bytes -Note ('service 0x{0:X4}' -f $s.Service) }
                Add-KnxEvidence -Note ("{0} x ROUTING_SYSTEM_BROADCAST, {1} x ROUTING_INDICATION on the system setup group" -f $sbc.Count, $ind.Count)

                if ($case.Mode -eq 1) {
                    # A routing indication whose control field 1 has the broadcast bit SET carries a plain broadcast: the
                    # traffic interface put the request on TP that way, so no system broadcast reached the router.
                    if ($sbc.Count -eq 0 -and $ind.Count -ge 1 -and (($ind[0].Bytes[8] -band 0x10) -ne 0)) {
                        Set-KnxTestNotRun -MissingInput 'a traffic interface that sends system broadcasts' -Reason ('the traffic interface put the request on TP as a plain broadcast (control field 1 0x{0:X2}), so the router had no system broadcast to route' -f $ind[0].Bytes[8])
                    }
                    Assert-KnxTrue ($sbc.Count -ge 1) 'the system broadcast did not reach IP as ROUTING_SYSTEM_BROADCAST'
                    Assert-KnxTrue ($ind.Count -eq 0) 'the same telegram was also relayed as a routing indication'
                    # 03_02_06 4.1.3: message code L_Data.ind, SB bit of control field 1 zero, group address type, destination 0.
                    $b = $sbc[0].Bytes
                    Assert-KnxTrue ($b[6] -eq 0x29) ('message code is 0x{0:X2}, expected L_Data.ind' -f $b[6])
                    Assert-KnxTrue (($b[8] -band 0x10) -eq 0) ('control field 1 is 0x{0:X2}: the system broadcast bit is not zero' -f $b[8])
                    Assert-KnxTrue (($b[9] -band 0x80) -ne 0) ('control field 2 is 0x{0:X2}: destination is not a group address' -f $b[9])
                    Assert-KnxTrue (($b[12] -eq 0) -and ($b[13] -eq 0)) 'destination address is not 0'
                }
                else {
                    Assert-KnxTrue ($ind.Count -ge 1) 'the system broadcast did not reach IP as a routing indication'
                    Assert-KnxTrue ($sbc.Count -eq 0) 'a ROUTING_SYSTEM_BROADCAST was sent although the mode is disabled'
                }
            }
            finally {
                if ($dm -and $dm.Ok) {
                    [void](Set-KnxIpSbcMode -Connection $dm -Mode 0)  # leave the device as found
                    Close-KnxConnection -Connection $dm | Out-Null
                }
            }
        }
    }
}
