#!/usr/bin/env pwsh
<#
Open ■
┬────┴  3-Core.Tests
■ KNX   2026 OpenKNX - Erkan Çolak

FILEPATH: scripts/Test/Suites/3-Core.Tests.ps1

.SYNOPSIS
    TSSH section 3 - Core: discovery, description, connect, connection state, disconnect.

.DESCRIPTION
    Dot-sourced by Invoke-Conformance.ps1, which then calls Invoke-KnxSuiteCore.
    Every expectation here is taken from the prufvorschrift text, not from the clause
    title - two of them are the opposite of what the title suggests:

      * 3.2.4 "Incomplete Message" declares a LONGER total length than sent.
      * 3.2.5 "Oversized Message" declares a SHORTER total length than sent.

    The negative cases (3.1.x, 3.2.2 - 3.2.5) all assert the same thing: the device
    stays silent AND stays alive. Silence alone is not a pass - a crashed device is
    also silent, so each of them re-probes the device afterwards.
#>

Set-StrictMode -Version Latest

function Test-KnxNoAnswer {
    <#
    .SYNOPSIS
        Sends a raw frame and returns the frames received within the window (expected: none).
    #>
    param([string]$Ip, [int]$Port, [byte[]]$Frame, [int]$WindowMs = 1200)
    $s = New-KnxSocket -TimeoutMs $WindowMs
    try {
        Send-KnxFrame -Socket $s -Frame $Frame -Ip $Ip -Port $Port
        $got = @()
        $deadline = [DateTime]::UtcNow.AddMilliseconds($WindowMs)
        while ([DateTime]::UtcNow -lt $deadline) {
            $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
            $pkt = Receive-KnxFrame -Socket $s -TimeoutMs $left
            if ($null -eq $pkt) { break }
            $got += $pkt
        }
        return , $got
    }
    finally { $s.Dispose() }
}

function Invoke-KnxSuiteCore {
    param([Parameter(Mandatory)]$Ctx, [string]$SuiteTitle = '3 Core')

    $K = Get-KnxConstants
    $ip = $Ctx.BdutIp
    $port = $Ctx.Port

    # ── 3.1 Unspecific ──────────────────────────────────────────────────────────

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-3.1.1' -Title 'Undefined Discovery Code' -Clause 'TSSH 3.1.1, p.13 (fn 10101)' -Body {
        # The prufvorschrift names 0x4910, 0xb5f1, 0x22d3 and repeats three times.
        Add-KnxExpectedLog 'Unhandled KNX-IP service identifier: 4910 / B5F1 / 22D3 (three times each)'
        $codes = @(0x4910, 0xB5F1, 0x22D3)
        foreach ($rep in 1..3) {
            foreach ($c in $codes) {
                $f = New-KnxFrame -Service $c -Body (New-KnxHpai -Ip '0.0.0.0' -Port 0)
                $got = Test-KnxNoAnswer -Ip $ip -Port $port -Frame $f -WindowMs 700
                if ($got.Count -gt 0) {
                    Add-KnxEvidence -Sent $f -Received $got[0].Bytes
                    Assert-KnxTrue $false ("device answered undefined service 0x{0:X4} (repeat $rep)" -f $c)
                }
            }
        }
        Assert-KnxTrue (Test-KnxAlive -Ip $ip -Port $port) 'device stopped answering after the undefined-service burst'
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-3.1.2' -Title 'Undefined Control Code' -Clause 'TSSH 3.1.2, p.13 (fn 10204)' -Body {
        # Open a device-management connection, then alternate an undefined service (0xabab)
        # to BOTH the control and the data endpoint with a legal request. The illegal ones
        # must be ignored, the legal ones must still be answered.
        Add-KnxExpectedLog 'Unhandled KNX-IP service identifier: ABAB (three times), around one tunnel open/close'
        $conn = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
        Assert-KnxTrue $conn.Ok "could not open a device management connection ($($conn.StatusName))"
        try {
            foreach ($rep in 1..3) {
                $bogus = New-KnxFrame -Service 0xABAB -Body ([byte[]]@($conn.Channel, 0x00) + (New-KnxHpai -Ip '0.0.0.0' -Port 0))
                Send-KnxFrame -Socket $conn.Socket -Frame $bogus -Ip $ip -Port $port
                Start-Sleep -Milliseconds 120

                $r = Read-KnxProperty -Connection $conn -ObjectType $K.ObjType.DEVICE -PropertyId $K.Pid.OBJECT_TYPE
                Add-KnxEvidence -Sent $bogus
                Assert-KnxTrue $r.Acked "legal DEVICE_CONFIGURATION_REQUEST was not acked after an undefined service (repeat $rep)"
                Assert-KnxTrue ($null -ne $r.Cemi) "no confirmation for the legal request after an undefined service (repeat $rep)"
            }
        }
        finally { [void](Close-KnxConnection -Connection $conn) }
    }

    # ── 3.2 Search Request ──────────────────────────────────────────────────────

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-3.2.1' -Title 'Search Request - Standard Case' -Clause 'TSSH 3.2.1, p.15 (fn 10201)' -Body {
        $s = New-KnxSocket -TimeoutMs 2500
        try {
            $local = Get-LocalEndpointFor -DestinationIp $ip -Port $port
            $f = New-KnxSearchRequest -DiscoveryIp $local -DiscoveryPort (Get-SocketLocalPort -Socket $s)
            Add-KnxEvidence -Sent $f
            # SEARCH_REQUEST is a DISCOVERY service and belongs on the discovery multicast
            # endpoint, not on the device's control endpoint. Sending it unicast made two
            # certified references fail this case while our device passed - they are right
            # to ignore it there. Send it where the specification puts it and pick the BDUT's
            # answer out of the responses, since every device on the group replies.
            $group = if ($Ctx.PSObject.Properties['Multicast'] -and $Ctx.Multicast) { $Ctx.Multicast } else { '224.0.23.12' }

            # Searched up to three times, and the hit rate is recorded either way. One
            # sample cannot tell "this device does not answer discovery" from "this one
            # datagram was lost", and the difference decides whether a red line means a
            # defect or a lost packet. Measured on this rig: two references and one of our
            # two devices answer 40 of 40, the third answers 30 of 40 - in multi-second
            # blocks, while unicast stays at 12 of 12. That is worth a number in the report,
            # not a coin flip in the verdict. ETS rescans too.
            $attempts = 3
            $hits = 0
            $r = $null
            $others = @()
            for ($try = 1; $try -le $attempts; $try++) {
                Clear-KnxSocket -Socket $s -QuietMs 50
                Send-KnxFrame -Socket $s -Frame $f -Ip $group -Port $port
                $found = $null
                $deadline = [DateTime]::UtcNow.AddMilliseconds(2000)
                while ([DateTime]::UtcNow -lt $deadline) {
                    $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
                    $pkt = Receive-KnxFrame -Socket $s -TimeoutMs $left
                    if ($null -eq $pkt) { break }
                    # Receive-KnxFrame returns raw bytes plus the sender - the header is parsed here.
                    $h = Read-KnxHeader -Frame $pkt.Bytes
                    if ($null -eq $h -or $h.Service -ne $K.Service.SEARCH_RESPONSE) { continue }
                    if (($pkt.From -split ":")[0] -eq $ip) { $found = [pscustomobject]@{ TimedOut = $false; Packet = $pkt; Header = $h }; break }
                    $others += ($pkt.From -split ":")[0]
                }
                if ($null -ne $found) { $hits++; if ($null -eq $r) { $r = $found } }
            }
            Add-KnxEvidence -Note "answered $hits of $attempts searches on $group"
            if ($others.Count -gt 0) { Add-KnxEvidence -Note "also answered: $(($others | Sort-Object -Unique) -join ', ')" }
            if ($hits -gt 0 -and $hits -lt $attempts) {
                Add-KnxEvidence -Note "the device misses discovery requests intermittently - ETS will sometimes not list it until a rescan"
            }
            Assert-KnxTrue ($null -ne $r) "no SEARCH_RESPONSE from $ip on the discovery group $group in $attempts attempts"
            Add-KnxEvidence -Received $r.Packet.Bytes

            # The body is: control-endpoint HPAI (8) + DEVICE_INFO DIB + SUPP_SVC_FAMILIES DIB.
            $body = $r.Header.Body
            Assert-KnxTrue ($body.Length -gt 8) 'SEARCH_RESPONSE has no DIB block'
            $dibs = Read-KnxDibs -Body $body -Offset 8
            $hasDev = $false; $hasFam = $false
            foreach ($d in $dibs) {
                if ($d.Type -eq $K.Dib.DEVICE_INFO) { $hasDev = $true }
                if ($d.Type -eq $K.Dib.SUPP_SVC_FAMILIES) { $hasFam = $true }
            }
            Assert-KnxTrue $hasDev 'mandatory DEVICE_INFO DIB missing'
            Assert-KnxTrue $hasFam 'mandatory SUPP_SVC_FAMILIES DIB missing'
        }
        finally { $s.Dispose() }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-3.2.2' -Title 'Search Request - Invalid Version' -Clause 'TSSH 3.2.2, p.15 (fn 10202)' -Body {
        Add-KnxExpectedLog 'nothing - the frame is dropped before it reaches the service dispatch'
        # Default parameter: version 0x11.
        $f = New-KnxSearchRequest -DiscoveryIp '0.0.0.0' -DiscoveryPort 0 -Version 0x11
        Add-KnxEvidence -Sent $f
        $got = Test-KnxNoAnswer -Ip $ip -Port $port -Frame $f
        if ($got.Count -gt 0) { Add-KnxEvidence -Received $got[0].Bytes }
        Assert-KnxTrue ($got.Count -eq 0) "device answered a SEARCH_REQUEST with protocol version 0x11 ($($got.Count) frame(s))"
        Assert-KnxTrue (Test-KnxAlive -Ip $ip -Port $port) 'device stopped answering after the invalid-version frame'
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-3.2.3' -Title 'Search Request - Invalid Header Size' -Clause 'TSSH 3.2.3, p.16 (fn 10203)' -Body {
        # Default parameter: header size 0x01.
        $f = New-KnxSearchRequest -DiscoveryIp '0.0.0.0' -DiscoveryPort 0 -HeaderSize 0x01
        Add-KnxEvidence -Sent $f
        $got = Test-KnxNoAnswer -Ip $ip -Port $port -Frame $f
        if ($got.Count -gt 0) { Add-KnxEvidence -Received $got[0].Bytes }
        Assert-KnxTrue ($got.Count -eq 0) "device answered a SEARCH_REQUEST with header size 0x01 ($($got.Count) frame(s))"
        Assert-KnxTrue (Test-KnxAlive -Ip $ip -Port $port) 'device stopped answering after the invalid-header-size frame'
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-3.2.4' -Title 'Search Request - Incomplete Message' -Clause 'TSSH 3.2.4, p.16 (fn 10205)' -Body {
        # "Incomplete" = the header declares a LONGER message than was actually sent
        # (0x000E + bytes missing). Confirmed by the RNA note in the prufvorschrift.
        $f = New-KnxSearchRequest -DiscoveryIp '0.0.0.0' -DiscoveryPort 0
        $f[4] = 0x00; $f[5] = 0x0F        # declare 15 octets, send 14
        Add-KnxEvidence -Sent $f -Note 'declared total length 0x000F, actually sent 14 octets'
        $got = Test-KnxNoAnswer -Ip $ip -Port $port -Frame $f
        if ($got.Count -gt 0) { Add-KnxEvidence -Received $got[0].Bytes }
        Assert-KnxTrue ($got.Count -eq 0) "device answered a SEARCH_REQUEST declaring more octets than it received ($($got.Count) frame(s))"
        Assert-KnxTrue (Test-KnxAlive -Ip $ip -Port $port) 'device stopped answering after the incomplete frame'
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-3.2.5' -Title 'Search Request - Oversized Message' -Clause 'TSSH 3.2.5, p.17 (fn 10206)' -Body {
        # "Oversized" = the header declares a SHORTER message than was actually sent
        # (0x000E - padding bytes). Confirmed by the RNA note in the prufvorschrift.
        $f = New-KnxSearchRequest -DiscoveryIp '0.0.0.0' -DiscoveryPort 0
        $f[4] = 0x00; $f[5] = 0x0D        # declare 13 octets, send 14
        Add-KnxEvidence -Sent $f -Note 'declared total length 0x000D, actually sent 14 octets'
        $got = Test-KnxNoAnswer -Ip $ip -Port $port -Frame $f
        if ($got.Count -gt 0) { Add-KnxEvidence -Received $got[0].Bytes }
        Assert-KnxTrue ($got.Count -eq 0) "device answered a SEARCH_REQUEST declaring fewer octets than it received ($($got.Count) frame(s))"
        Assert-KnxTrue (Test-KnxAlive -Ip $ip -Port $port) 'device stopped answering after the oversized frame'
    }

    # ── 3.3 Description Request ─────────────────────────────────────────────────

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-3.3.1' -Title 'Description Request - Standard Case' -Clause 'TSSH 3.3.1, p.17 (fn 10301)' -Body {
        $s = New-KnxSocket -TimeoutMs 2500
        try {
            $local = Get-LocalEndpointFor -DestinationIp $ip -Port $port
            $f = New-KnxDescriptionRequest -ControlIp $local -ControlPort (Get-SocketLocalPort -Socket $s)
            Add-KnxEvidence -Sent $f
            $r = Invoke-KnxRequest -Socket $s -Frame $f -Ip $ip -Port $port -Expect @($K.Service.DESCRIPTION_RESPONSE) -TimeoutMs 2500
            Assert-KnxTrue (-not $r.TimedOut) 'no DESCRIPTION_RESPONSE'
            Add-KnxEvidence -Received $r.Packet.Bytes

            $dibs = Read-KnxDibs -Body $r.Header.Body
            $devDib = $null; $famDib = $null
            foreach ($d in $dibs) {
                if ($d.Type -eq $K.Dib.DEVICE_INFO) { $devDib = $d }
                if ($d.Type -eq $K.Dib.SUPP_SVC_FAMILIES) { $famDib = $d }
            }
            Assert-KnxTrue ($null -ne $devDib) 'mandatory DEVICE_INFO DIB missing'
            Assert-KnxTrue ($null -ne $famDib) 'mandatory SUPP_SVC_FAMILIES DIB missing'
            Assert-KnxEqual 0x36 $devDib.Length 'DEVICE_INFO DIB has the wrong structure length'
            Assert-KnxTrue ($null -ne $devDib.Decoded) 'DEVICE_INFO DIB could not be decoded'
            Add-KnxEvidence -Note "device '$($devDib.Decoded.FriendlyName)' at $($devDib.Decoded.IndividualAddr)"

            # CORE is what every KNXnet/IP device must offer.
            Assert-KnxTrue (Test-KnxFamilySupported -Body $r.Header.Body -Family $K.Family.CORE) 'CORE service family not advertised'
        }
        finally { $s.Dispose() }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-3.3.1b' -Title 'Service families match the declared product role' -Clause '03_08_02 Core, Supported Service Families DIB' -Body {
        # Not a TSSH case, but the single most load-bearing property of this product line:
        # a device advertising ROUTING is a routing device, and a routing device must not
        # offer the KNX busmonitor (03_08_04 section 2.2.4).
        $d = Get-KnxDescription -Ip $ip -Port $port
        Assert-KnxTrue ($null -ne $d) 'no description'
        $hasRouting = Test-KnxFamilySupported -Body $d.Body -Family $K.Family.ROUTING
        $hasTunnel = Test-KnxFamilySupported -Body $d.Body -Family $K.Family.TUNNELLING
        $hasDevMgmt = Test-KnxFamilySupported -Body $d.Body -Family $K.Family.DEVICE_MANAGEMENT
        Add-KnxEvidence -Note ("advertised: " + (($d.Families | ForEach-Object { $_.Name }) -join ', '))
        Assert-KnxTrue $hasTunnel 'TUNNELLING service family not advertised'
        Assert-KnxTrue $hasDevMgmt 'DEVICE MANAGEMENT service family not advertised'
        if ($Ctx.IsRouter) {
            Assert-KnxTrue $hasRouting 'declared as router but ROUTING service family is absent'
        }
        else {
            Assert-KnxTrue (-not $hasRouting) 'declared as interface but ROUTING service family IS advertised - this device is a routing device and must not offer a busmonitor'
        }
    }

    # ── 3.4 Connect Request ─────────────────────────────────────────────────────

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-3.4.1' -Title 'Connect Request - Standard Case' -Clause 'TSSH 3.4.1, p.18 (fn 10401)' -Body {
        $conn = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
        Add-KnxEvidence -Sent $conn.Request
        if ($null -ne $conn.Response) { Add-KnxEvidence -Received $conn.Response }
        try {
            Assert-KnxTrue ($conn.Status -ge 0) 'no CONNECT_RESPONSE'
            Assert-KnxStatus $K.Error.E_NO_ERROR $conn.Status 'connect refused'
            Assert-KnxTrue ($conn.Channel -ge 0 -and $conn.Channel -le 255) 'no usable communication channel id returned'
            Add-KnxEvidence -Note "channel id $($conn.Channel)"
        }
        finally { if ($conn.Ok) { [void](Close-KnxConnection -Connection $conn) } }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-3.4.2' -Title 'Connect Request - Invalid Connection Type' -Clause 'TSSH 3.4.2, p.19 (fn 10402)' -Body {
        # Default parameter: connection type 0x42, CRI = 04 <type> FF 00.
        $s = New-KnxSocket -TimeoutMs 2500
        try {
            $local = Get-LocalEndpointFor -DestinationIp $ip -Port $port
            $lp = Get-SocketLocalPort -Socket $s
            $hpai = New-KnxHpai -Ip $local -Port $lp
            $cri = [byte[]]@(0x04, 0x42, 0xFF, 0x00)
            $f = New-KnxFrame -Service $K.Service.CONNECT_REQUEST -Body ([byte[]]($hpai + $hpai + $cri))
            Add-KnxEvidence -Sent $f
            $r = Invoke-KnxRequest -Socket $s -Frame $f -Ip $ip -Port $port -Expect @($K.Service.CONNECT_RESPONSE) -TimeoutMs 2500
            Assert-KnxTrue (-not $r.TimedOut) 'no CONNECT_RESPONSE for an undefined connection type'
            Add-KnxEvidence -Received $r.Packet.Bytes
            $cr = Read-KnxConnectResponse -Body $r.Header.Body
            Assert-KnxStatus $K.Error.E_CONNECTION_TYPE $cr.Status 'wrong status for an undefined connection type'
            Assert-KnxEqual 8 $r.Header.TotalLength 'error CONNECT_RESPONSE must be 8 octets (channel + status only)'
        }
        finally { $s.Dispose() }
    }

    # ── 3.5 Connectionstate Request ─────────────────────────────────────────────

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-3.5.1' -Title 'Connectionstate Request - Standard Case' -Clause 'TSSH 3.5.1, p.19 (fn 10501)' -Body {
        $conn = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
        Assert-KnxTrue $conn.Ok "could not open a connection ($($conn.StatusName))"
        try {
            $f = New-KnxConnectionStateRequest -Channel $conn.Channel -ControlIp $conn.LocalIp -ControlPort $conn.LocalPort
            Add-KnxEvidence -Sent $f
            $r = Invoke-KnxRequest -Socket $conn.Socket -Frame $f -Ip $ip -Port $port -Expect @($K.Service.CONNECTIONSTATE_RESPONSE) -TimeoutMs 2500
            Assert-KnxTrue (-not $r.TimedOut) 'no CONNECTIONSTATE_RESPONSE'
            Add-KnxEvidence -Received $r.Packet.Bytes
            Assert-KnxTrue ($r.Header.Body.Length -ge 2) 'CONNECTIONSTATE_RESPONSE too short'
            Assert-KnxEqual $conn.Channel $r.Header.Body[0] 'response carries a different channel id than the request'
            Assert-KnxStatus $K.Error.E_NO_ERROR $r.Header.Body[1] 'connection state is not E_NO_ERROR'
        }
        finally { [void](Close-KnxConnection -Connection $conn) }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-3.5.2' -Title 'Connectionstate Request - Invalid Channel' -Clause 'TSSH 3.5.2, p.20 (fn 10502)' -Body {
        $conn = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
        Assert-KnxTrue $conn.Ok "could not open a connection ($($conn.StatusName))"
        try {
            # Default parameter: ID offset 1.
            $bogus = ($conn.Channel + 1) -band 0xFF
            $f = New-KnxConnectionStateRequest -Channel $bogus -ControlIp $conn.LocalIp -ControlPort $conn.LocalPort
            Add-KnxEvidence -Sent $f
            $r = Invoke-KnxRequest -Socket $conn.Socket -Frame $f -Ip $ip -Port $port -Expect @($K.Service.CONNECTIONSTATE_RESPONSE) -TimeoutMs 2500
            Assert-KnxTrue (-not $r.TimedOut) 'no CONNECTIONSTATE_RESPONSE for an unknown channel'
            Add-KnxEvidence -Received $r.Packet.Bytes
            Assert-KnxEqual $bogus $r.Header.Body[0] 'response must echo the requested (invalid) channel id'
            Assert-KnxStatus $K.Error.E_CONNECTION_ID $r.Header.Body[1] 'wrong status for an unknown channel id'
        }
        finally { [void](Close-KnxConnection -Connection $conn) }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-3.5.3' -Title 'Connectionstate Request - Time Out' -Clause 'TSSH 3.5.3, p.21 (fn 10802)' -Body {
        if ($Ctx.SkipSlow) { Set-KnxTestSkip 'measures a 120 s timeout - excluded by -SkipSlow' }
        # The device must drop a connection that sends no connectionstate request.
        # Nominal 120 s; the prufvorschrift accepts 110...130 s.
        $conn = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
        Assert-KnxTrue $conn.Ok "could not open a connection ($($conn.StatusName))"
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $dropped = $false
        try {
            $r = Wait-KnxService -Socket $conn.Socket -Service @($K.Service.DISCONNECT_REQUEST) -TimeoutMs 140000
            $sw.Stop()
            $dropped = (-not $r.TimedOut)
            $sec = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
            Add-KnxEvidence -Note "measured $sec s"
            Assert-KnxTrue $dropped 'device never dropped the idle connection (no DISCONNECT_REQUEST within 140 s)'
            Assert-KnxTrue ($sec -ge 110 -and $sec -le 130) "reaper fired after $sec s, outside the accepted 110...130 s window"
        }
        finally {
            # If the reaper did not fire, the slot is still ours - release it, or every
            # later case competes with a connection this test deliberately abandoned.
            if (-not $dropped) { [void](Close-KnxConnection -Connection $conn -TimeoutMs 1000) }
            else { try { $conn.Socket.Dispose() } catch { } }
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-3.5.4' -Title 'Connectionstate Request - Bus connection interrupted' -Clause 'TSSH 3.5.4, p.21 (fn 10503)' -Body {
        if ($Ctx.ReadOnly) { Set-KnxTestSkip 'profile ReadOnly - the load switch writes to the bus' }
        if (-not $Ctx.LoadSwitchGa) { Set-KnxTestSkip 'this rig has no load switch - pass -LoadSwitchGa/-LoadSwitchPa when one is fitted (TSSH 1.2.2 specifies 1/1/50 on 1.1.50)' }
        if (-not $Ctx.LoadSwitchVia) { Set-KnxTestSkip 'no interface to drive the load switch (-TrafficIp / -LoadSwitchVia)' }

        $conn = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
        Assert-KnxTrue $conn.Ok "could not open a connection ($($conn.StatusName))"
        $opened = $false
        try {
            $off = Invoke-KnxLoadSwitch -Via $Ctx.LoadSwitchVia -On $false -GroupAddress $Ctx.LoadSwitchGa
            Assert-KnxTrue $off.Ok $off.Reason
            $opened = $true
            Start-Sleep -Seconds 3   # let the device notice the missing bus

            $f = New-KnxConnectionStateRequest -Channel $conn.Channel -ControlIp $conn.LocalIp -ControlPort $conn.LocalPort
            Add-KnxEvidence -Sent $f
            $r = Invoke-KnxRequest -Socket $conn.Socket -Frame $f -Ip $ip -Port $port -Expect @($K.Service.CONNECTIONSTATE_RESPONSE) -TimeoutMs 4000
            Assert-KnxTrue (-not $r.TimedOut) 'no CONNECTIONSTATE_RESPONSE while the bus was interrupted'
            Add-KnxEvidence -Received $r.Packet.Bytes
            Assert-KnxStatus $K.Error.E_KNX_CONNECTION $r.Header.Body[1] 'device did not report E_KNX_CONNECTION while its bus connection was open'
        }
        finally {
            # Restoring the bus matters more than the verdict - every later case needs it.
            if ($opened) {
                $on = Invoke-KnxLoadSwitch -Via $Ctx.LoadSwitchVia -On $true -GroupAddress $Ctx.LoadSwitchGa
                if (-not $on.Ok) { Write-Host "    WARNING: could not re-close the load switch - $($on.Reason)" -ForegroundColor Red }
                Start-Sleep -Seconds 2
            }
            [void](Close-KnxConnection -Connection $conn)
        }
    }

    # ── 3.6 Disconnect Request ──────────────────────────────────────────────────

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-3.6.1' -Title 'Disconnect Request - Standard Case' -Clause 'TSSH 3.6.1, p.22 (fn 10601)' -Body {
        $conn = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
        Assert-KnxTrue $conn.Ok "could not open a connection ($($conn.StatusName))"
        try {
            $f = New-KnxDisconnectRequest -Channel $conn.Channel -ControlIp $conn.LocalIp -ControlPort $conn.LocalPort
            Add-KnxEvidence -Sent $f
            $r = Invoke-KnxRequest -Socket $conn.Socket -Frame $f -Ip $ip -Port $port -Expect @($K.Service.DISCONNECT_RESPONSE) -TimeoutMs 2500
            Assert-KnxTrue (-not $r.TimedOut) 'no DISCONNECT_RESPONSE'
            Add-KnxEvidence -Received $r.Packet.Bytes
            Assert-KnxEqual $conn.Channel $r.Header.Body[0] 'response carries a different channel id than the request'
            Assert-KnxStatus $K.Error.E_NO_ERROR $r.Header.Body[1] 'disconnect did not report E_NO_ERROR'
            Assert-KnxEqual 8 $r.Header.TotalLength 'DISCONNECT_RESPONSE must be 8 octets'
        }
        finally { try { $conn.Socket.Dispose() } catch { } }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-3.6.2' -Title 'Disconnect Request - Invalid Channel' -Clause 'TSSH 3.6.2, p.23 (fn 10602)' -Body {
        $conn = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
        Assert-KnxTrue $conn.Ok "could not open a connection ($($conn.StatusName))"
        try {
            # Default parameter: ID offset 1.
            $bogus = ($conn.Channel + 1) -band 0xFF
            $f = New-KnxDisconnectRequest -Channel $bogus -ControlIp $conn.LocalIp -ControlPort $conn.LocalPort
            Add-KnxEvidence -Sent $f
            $r = Invoke-KnxRequest -Socket $conn.Socket -Frame $f -Ip $ip -Port $port -Expect @($K.Service.DISCONNECT_RESPONSE) -TimeoutMs 2500
            Assert-KnxTrue (-not $r.TimedOut) 'no DISCONNECT_RESPONSE for an unknown channel'
            Add-KnxEvidence -Received $r.Packet.Bytes
            Assert-KnxEqual $bogus $r.Header.Body[0] 'response must echo the requested (invalid) channel id'
            Assert-KnxStatus $K.Error.E_CONNECTION_ID $r.Header.Body[1] 'wrong status for an unknown channel id on disconnect'
        }
        finally { [void](Close-KnxConnection -Connection $conn) }
    }
}
