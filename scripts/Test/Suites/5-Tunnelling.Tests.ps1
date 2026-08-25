#!/usr/bin/env pwsh
<#
Open ■
┬────┴  5-Tunnelling.Tests
■ KNX   2026 OpenKNX - Erkan Çolak

FILEPATH: scripts/Test/Suites/5-Tunnelling.Tests.ps1

.SYNOPSIS
    TSSH section 5 - Tunnelling: connection handling, tunnelling requests, tunnel
    addresses and NAT compatibility.

.DESCRIPTION
    Dot-sourced by Invoke-Conformance.ps1, which then calls Invoke-KnxSuiteTunnelling.

    Section 5.3 (Tunnel Addresses) is the block this whole test suite exists for. It is
    where a device can satisfy every clause on paper and still pick the wrong address:
    the list may be empty, partly filled, full, contain gaps, contain duplicates, be
    exhausted, or be out of order - and only walking all of those shapes finds it.

    Expectations that are easy to get wrong and are therefore spelled out here:
      * 5.1.3/5.1.4/5.1.5 expect E_CONNECTION_OPTION (0x23) for an unsupported or
        invalid KNX layer - NOT E_TUNNELING_LAYER (0x29).
      * 5.2.3 (sequence not increased) must be ACKED but NOT put on the bus.
      * 5.2.4 (sequence one too large) must NOT be acked and NOT put on the bus.
      * 5.2.7 repeats ONCE after 1 second - unlike 4.2.11, which repeats 3 times / 10 s.
      * 5.3.1 forbids a returned tunnel address of the form x.y.0.
#>

Set-StrictMode -Version Latest

function Open-TunnelRaw {
    <#
    .SYNOPSIS
        Opens a tunnel with explicitly controlled HPAI contents, for the NAT cases.
    .DESCRIPTION
        Returns the same shape as Open-KnxConnection so the callers stay uniform. The
        socket is kept even on refusal is not - a refused connection frees it, exactly
        like Open-KnxConnection does.
    #>
    param(
        [string]$Ip, [int]$Port,
        [string]$HpaiIp = '0.0.0.0', [int]$HpaiPort = 0,
        [switch]$UseRealPort,
        [int]$Layer = 0x02, [int]$TimeoutMs = 3000
    )
    $K = Get-KnxConstants
    $sock = New-KnxSocket -TimeoutMs $TimeoutMs
    # "Port number set" means the client's OWN port, which only exists after binding.
    # Putting an arbitrary port (3671) there makes a correctly route-backing device answer
    # to a port nobody listens on - the test would then blame the device for its own bug.
    if ($UseRealPort) { $HpaiPort = Get-SocketLocalPort -Socket $sock }
    $frame = New-KnxConnectRequest -ControlIp $HpaiIp -ControlPort $HpaiPort -DataIp $HpaiIp -DataPort $HpaiPort `
                                   -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $Layer
    $rsp = Invoke-KnxRequest -Socket $sock -Frame $frame -Ip $Ip -Port $Port -Expect @($K.Service.CONNECT_RESPONSE) -TimeoutMs $TimeoutMs
    if ($rsp.TimedOut) {
        $sock.Dispose()
        return [pscustomobject]@{ Ok = $false; Status = -1; StatusName = 'NO_ANSWER'; Channel = -1; Socket = $null; Ip = $Ip; Port = $Port; SeqSend = 0; SeqRecv = 0; TunnelPa = $null; LocalIp = $HpaiIp; LocalPort = $HpaiPort; Request = $frame; Response = $null }
    }
    $cr = Read-KnxConnectResponse -Body $rsp.Header.Body
    if ($cr.IsError) {
        $sock.Dispose()
        return [pscustomobject]@{ Ok = $false; Status = $cr.Status; StatusName = $cr.StatusName; Channel = -1; Socket = $null; Ip = $Ip; Port = $Port; SeqSend = 0; SeqRecv = 0; TunnelPa = $null; LocalIp = $HpaiIp; LocalPort = $HpaiPort; Request = $frame; Response = $rsp.Packet.Bytes }
    }
    return [pscustomobject]@{
        Ok = $true; Status = $cr.Status; StatusName = $cr.StatusName; Channel = $cr.Channel
        Socket = $sock; Ip = $Ip; Port = $Port; SeqSend = 0; SeqRecv = 0; TunnelPa = $cr.TunnelPa
        LocalIp = $HpaiIp; LocalPort = (Get-SocketLocalPort -Socket $sock)
        Request = $frame; Response = $rsp.Packet.Bytes
    }
}

function Open-AllTunnels {
    <#
    .SYNOPSIS
        Opens tunnels until refused; returns the granted connections and the refusal status.
    #>
    param([string]$Ip, [int]$Port, [int]$Layer = 0x02, [int]$Limit = 32)
    $K = Get-KnxConstants
    $open = @()
    $status = -1
    $response = $null
    for ($i = 0; $i -lt $Limit; $i++) {
        $c = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $Layer -TimeoutMs 2500
        if ($c.Ok) { $open += $c; continue }
        $status = $c.Status
        $response = $c.Response
        break
    }
    return [pscustomobject]@{ Open = @($open); RefusalStatus = $status; RefusalResponse = $response }
}

function Close-AllTunnels {
    param($Connections)
    foreach ($c in $Connections) { [void](Close-KnxConnection -Connection $c) }
}

function Get-AdditionalAddresses {
    <#
    .SYNOPSIS
        Reads PID_ADDITIONAL_INDIVIDUAL_ADDRESSES from the KNXnet/IP parameter object.
    .DESCRIPTION
        The element count field is only 4 bits, so the list is read in two passes of 15.
        Returns an array of "a.l.d" strings, empty when the property is absent.
    #>
    param($Connection)
    $K = Get-KnxConstants
    $raw = [byte[]]@()
    foreach ($start in @(1, 16)) {
        $r = Read-KnxProperty -Connection $Connection -ObjectType $K.ObjType.KNXNETIP_PARAM `
                              -PropertyId $K.Pid.ADDITIONAL_INDIVIDUAL_ADDRESSES -ElementCount 15 -StartIndex $start
        if ($null -eq $r.Parsed -or $r.Parsed.IsError) { break }
        if ($r.Parsed.Data.Length -eq 0) { break }
        $raw = [byte[]]($raw + $r.Parsed.Data)
        if ($r.Parsed.Data.Length -lt 30) { break }
    }
    $list = @()
    for ($i = 0; ($i + 1) -lt $raw.Length; $i += 2) {
        $list += ConvertFrom-KnxPa -Raw (Get-Uint16 -Bytes $raw -Offset $i)
    }
    return , $list
}

function Set-AdditionalAddresses {
    <#
    .SYNOPSIS
        Writes PID_ADDITIONAL_INDIVIDUAL_ADDRESSES, in batches of at most 15 elements.
    .DESCRIPTION
        The cEMI element-count field is 4 bits, so 15 is the most that fits in one request -
        but the property holds KNX_TUNNELING entries, which is 16 on this product. Writing
        only the first 15 leaves the last address untouched, and the test then reports a
        "wrong" address that it never actually set. Hence two passes.
    #>
    param($Connection, [string[]]$Addresses)
    $K = Get-KnxConstants
    $total = $Addresses.Count
    $index = 0
    while ($index -lt $total) {
        $count = [Math]::Min(15, $total - $index)
        $data = [byte[]]@()
        for ($i = $index; $i -lt ($index + $count); $i++) {
            $raw = ConvertTo-KnxPa -Address $Addresses[$i]
            $data = [byte[]]($data + [byte[]]@((($raw -shr 8) -band 0xFF), ($raw -band 0xFF)))
        }
        $cemi = New-CemiMPropWrite -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.ADDITIONAL_INDIVIDUAL_ADDRESSES `
                                   -ElementCount $count -StartIndex ($index + 1) -Data $data
        $r = Send-KnxDeviceConfiguration -Connection $Connection -Cemi $cemi -TimeoutMs 4000
        if ($null -eq $r.Parsed -or $r.Parsed.IsError) {
            $code = -1
            if ($null -ne $r.Parsed) { $code = $r.Parsed.ErrorCode }
            return [pscustomobject]@{ Ok = $false; ErrorCode = $code }
        }
        $index += $count
    }
    return [pscustomobject]@{ Ok = $true; ErrorCode = 0 }
}

function Invoke-KnxSuiteTunnelling {
    param([Parameter(Mandatory)]$Ctx, [string]$SuiteTitle = '5 Tunnelling')

    $K = Get-KnxConstants
    $ip = $Ctx.BdutIp
    $port = $Ctx.Port
    $TUN = $K.ConnType.TUNNEL_CONNECTION

    # ── 5.1 Connection Handling ─────────────────────────────────────────────────

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.1.1' -Title 'Tunnelling connection - Standard Case (link layer)' -Clause 'TSSH 5.1.1, p.62 (fn 30101)' -Body {
        # Read the description here rather than trusting a cached one: -SkipRigCheck leaves
        # it empty, and a null dereference would be reported as an unhandled error instead
        # of the real problem.
        $d = Get-KnxDescription -Ip $ip -Port $port
        Assert-KnxTrue ($null -ne $d) 'no DESCRIPTION_RESPONSE - cannot tell whether tunnelling is advertised'
        $supported = Test-KnxFamilySupported -Body $d.Body -Family $K.Family.TUNNELLING
        $c = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $TUN -Layer $K.Layer.TUNNEL_LINKLAYER
        Add-KnxEvidence -Sent $c.Request
        if ($null -ne $c.Response) { Add-KnxEvidence -Received $c.Response }
        try {
            if ($supported) {
                Assert-KnxTrue $c.Ok "device advertises TUNNELLING but refused a link-layer tunnel ($($c.StatusName))"
                Assert-KnxTrue ($null -ne $c.TunnelPa) 'CONNECT_RESPONSE carries no tunnel individual address in its CRD'
                Add-KnxEvidence -Note "channel $($c.Channel), tunnel address $($c.TunnelPa)"
            }
            else {
                Assert-KnxTrue (-not $c.Ok) 'device does not advertise TUNNELLING but accepted a tunnel connection'
            }
        }
        finally { if ($c.Ok) { [void](Close-KnxConnection -Connection $c) } }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.1.2' -Title 'Tunnelling connection - Multiplicity' -Clause 'TSSH 5.1.2, p.63 (fn 30102)' -Body {
        if ($Ctx.ReadOnly) { Set-KnxTestSkip 'profile ReadOnly - exhausting the tunnel pool locks out other clients' }
        $r = Open-AllTunnels -Ip $ip -Port $port -Layer $K.Layer.TUNNEL_LINKLAYER
        try {
            if ($null -ne $r.RefusalResponse) { Add-KnxEvidence -Received $r.RefusalResponse }
            Add-KnxEvidence -Note "$($r.Open.Count) tunnel(s) granted, then $(Get-KnxErrorName -Status $r.RefusalStatus)"
            Assert-KnxTrue ($r.Open.Count -ge 1) 'device granted no tunnel connection at all'
            Assert-KnxTrue ($r.RefusalStatus -ge 0) "device accepted $($r.Open.Count) tunnels without ever refusing"
            Assert-KnxStatus $K.Error.E_NO_MORE_CONNECTIONS $r.RefusalStatus 'wrong status when the tunnel pool is exhausted'
        }
        finally { Close-AllTunnels -Connections $r.Open }
    }

    foreach ($case in @(
            @{ Id = 'H-5.1.3'; Title = 'cEMI Raw Mode tunnelling connection';    Clause = 'TSSH 5.1.3, p.64 (fn 30103)'; Layer = 0x04 },
            @{ Id = 'H-5.1.4'; Title = 'KNX Busmonitor Mode tunnelling connection'; Clause = 'TSSH 5.1.4, p.65 (fn 30104)'; Layer = 0x80 })) {
        $layer = $case.Layer
        Invoke-KnxTestCase -Suite $SuiteTitle -Id $case.Id -Title $case.Title -Clause $case.Clause -Body {
            # Either the mode is supported and the connection opens, or the device must
            # refuse with E_CONNECTION_OPTION. Any other outcome is a failure.
            $c = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $TUN -Layer $layer
            Add-KnxEvidence -Sent $c.Request
            if ($null -ne $c.Response) { Add-KnxEvidence -Received $c.Response }
            try {
                if ($c.Ok) {
                    Add-KnxEvidence -Note "mode supported, channel $($c.Channel), address $($c.TunnelPa)"
                    if ($layer -eq 0x80 -and $Ctx.IsRouter) {
                        Assert-KnxTrue $false 'a device advertising ROUTING accepted a busmonitor tunnel - not permitted (03_08_04 section 2.2.4)'
                    }
                }
                else {
                    # The prufvorschrift names E_CONNECTION_OPTION (0x23). Measured 2026-08-15
                    # against TWO certified devices (Siemens N148, MDT SCN-IP000.03): both
                    # answer E_TUNNELING_LAYER (0x29) here. Demanding 0x23 alone would fail
                    # every device on the market, so both codes are accepted and the one that
                    # was used is recorded.
                    Assert-KnxTrue ($c.Status -ge 0) 'device did not answer the connect request at all'
                    Add-KnxEvidence -Note "refused with $(Get-KnxErrorName -Status $c.Status)"
                    Assert-KnxTrue (@($K.Error.E_CONNECTION_OPTION, $K.Error.E_TUNNELING_LAYER) -contains $c.Status) `
                        "unsupported tunnelling mode refused with $(Get-KnxErrorName -Status $c.Status) - expected E_CONNECTION_OPTION (0x23) or E_TUNNELING_LAYER (0x29)"
                }
            }
            finally { if ($c.Ok) { [void](Close-KnxConnection -Connection $c) } }
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.1.5' -Title 'Invalid KNX layer code' -Clause 'TSSH 5.1.5, p.66 (fn 30105)' -Body {
        # Default parameter: 3 retries with random invalid layer codes. 0x02/0x04/0x80 are
        # the defined ones, so anything else must be refused with E_CONNECTION_OPTION.
        $bad = @(0x00, 0x01, 0x03, 0x7F, 0x81, 0xFF)
        $tried = 0
        foreach ($l in $bad) {
            if ($tried -ge 3) { break }
            $tried++
            $c = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $TUN -Layer $l
            if ($null -ne $c.Response) { Add-KnxEvidence -Received $c.Response }
            if ($c.Ok) {
                [void](Close-KnxConnection -Connection $c)
                Assert-KnxTrue $false ("device ACCEPTED the undefined KNX layer code 0x{0:X2}" -f $l)
            }
            Assert-KnxTrue ($c.Status -ge 0) ("no answer for KNX layer code 0x{0:X2}" -f $l)
            # Same measured reality as H-5.1.3: both certified references answer 0x29 here.
            Assert-KnxTrue (@($K.Error.E_CONNECTION_OPTION, $K.Error.E_TUNNELING_LAYER) -contains $c.Status) `
                ("undefined KNX layer code 0x{0:X2} refused with {1} - expected E_CONNECTION_OPTION (0x23) or E_TUNNELING_LAYER (0x29)" -f $l, (Get-KnxErrorName -Status $c.Status))
        }
        Add-KnxEvidence -Note "$tried undefined layer codes refused with E_CONNECTION_OPTION"
    }

    # ── 5.2 Tunnelling Request ──────────────────────────────────────────────────

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.2.1' -Title 'Standard Case - Tunnelling to KNX' -Clause 'TSSH 5.2.1, p.67 (fn 30201)' -Body {
        if ($Ctx.ReadOnly) { Set-KnxTestSkip 'profile ReadOnly - this case writes a group telegram to the bus' }
        $c = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $TUN -Layer $K.Layer.TUNNEL_LINKLAYER
        Assert-KnxTrue $c.Ok "could not open a tunnel ($($c.StatusName))"
        try {
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination (ConvertTo-KnxGa -Address '0/0/1') -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 0)
            Add-KnxEvidence -Sent $cemi
            $r = Send-KnxTunnelCemi -Connection $c -Cemi $cemi -TimeoutMs 3000
            Assert-KnxTrue $r.Acked 'no TUNNELLING_ACK for the L_Data.req'
            Assert-KnxStatus 0 $r.Status 'TUNNELLING_ACK reports an error status'
            Assert-KnxEqual 0 $r.AckSeq 'TUNNELLING_ACK carries the wrong sequence number'
            Assert-KnxEqual $c.Channel $r.AckChannel 'TUNNELLING_ACK carries the wrong channel id'

            # The device must confirm the transmission with an L_Data.con back on the tunnel.
            # 03_08_04 clause 2.5 lets the server send an L_Data.con OR an L_Data.ind for
            # every telegram it sees on the subnet, in whatever order they occur - a busy
            # bus puts foreign indications between our request and its confirmation. Taking
            # the first frame therefore judged an unrelated indication and reported 0x29
            # where 0x2E was expected. Wait for the confirmation OF THIS telegram.
            $ga = ConvertTo-KnxGa -Address '0/0/1'
            $con = $null
            $deadline = [DateTime]::UtcNow.AddSeconds(4)
            while ([DateTime]::UtcNow -lt $deadline) {
                $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
                $in = Receive-KnxTunnelCemi -Connection $c -TimeoutMs $left
                if ($null -eq $in) { continue }
                $cand = Read-CemiLData -Cemi $in.Cemi
                if ($null -eq $cand) { continue }
                if ($cand.MessageCode -ne $K.Cemi.L_DATA_CON) {
                    Add-KnxEvidence -Note ("ignored a 0x{0:X2} while waiting for the confirmation - not this request" -f $cand.MessageCode)
                    continue
                }
                if ($cand.Destination -ne $ga) {
                    Add-KnxEvidence -Note ("ignored a confirmation for {0} - not this request" -f (ConvertFrom-KnxGa -Raw $cand.Destination))
                    continue
                }
                $con = $in; break
            }
            Assert-KnxTrue ($null -ne $con) 'no L_Data.con returned for the tunnelled telegram'
            Add-KnxEvidence -Received $con.Cemi
            Assert-KnxEqual ('0x{0:X2}' -f $K.Cemi.L_DATA_CON) ('0x{0:X2}' -f $con.Cemi[0]) 'returned frame is not an L_Data.con'
        }
        finally { [void](Close-KnxConnection -Connection $c) }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.2.2' -Title 'Standard Case - Tunnelling from KNX' -Clause 'TSSH 5.2.2, p.68 (fn 30202)' -Body {
        if (-not $Ctx.TrafficIp) { Set-KnxTestSkip 'needs a second interface (-TrafficIp) to put a telegram on the bus' }
        if ($Ctx.ReadOnly) { Set-KnxTestSkip 'profile ReadOnly - this case writes a group telegram to the bus' }

        $c = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $TUN -Layer $K.Layer.TUNNEL_LINKLAYER
        Assert-KnxTrue $c.Ok "could not open a tunnel on the BDUT ($($c.StatusName))"
        $src = Get-KnxTrafficConnection -Ip $Ctx.TrafficIp -Port $port
        try {
            Assert-KnxTrue ($null -ne $src) 'no tunnel available on the traffic interface'
            $ga = ConvertTo-KnxGa -Address '0/0/2'
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $ga -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)
            Add-KnxEvidence -Sent $cemi
            [void](Send-KnxTunnelCemi -Connection $src -Cemi $cemi -TimeoutMs 3000)

            $seen = $null
            $deadline = [DateTime]::UtcNow.AddSeconds(6)
            while ([DateTime]::UtcNow -lt $deadline) {
                $in = Receive-KnxTunnelCemi -Connection $c -TimeoutMs 1500
                if ($null -eq $in) { continue }
                $ld = Read-CemiLData -Cemi $in.Cemi
                if ($null -eq $ld) { continue }
                if ($ld.MessageCode -eq $K.Cemi.L_DATA_IND -and $ld.Destination -eq $ga) { $seen = $in; break }
            }
            Assert-KnxTrue ($null -ne $seen) 'the telegram sent on the bus never arrived as L_Data.ind on the tunnel'
            Add-KnxEvidence -Received $seen.Cemi
        }
        finally {
            [void](Close-KnxConnection -Connection $c)
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.2.3' -Title 'Not increased Sequence Counter' -Clause 'TSSH 5.2.3, p.69 (fn 30203)' -Body {
        if ($Ctx.ReadOnly) { Set-KnxTestSkip 'profile ReadOnly - this case writes to the bus' }
        $c = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $TUN -Layer $K.Layer.TUNNEL_LINKLAYER
        Assert-KnxTrue $c.Ok "could not open a tunnel ($($c.StatusName))"
        try {
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination (ConvertTo-KnxGa -Address '0/0/3') -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 0)
            foreach ($i in 0..2) {
                $r = Send-KnxTunnelCemi -Connection $c -Cemi $cemi -TimeoutMs 3000
                Assert-KnxTrue $r.Acked "no ACK for tunnelling request with sequence $($r.Sequence)"
            }
            Clear-KnxSocket -Socket $c.Socket -QuietMs 400

            # Repeat the LAST sequence number. Per the prufvorschrift this must still be
            # acknowledged - but must not be repeated on the bus.
            $repeat = ($c.SeqSend - 1) -band 0xFF
            $r = Send-KnxTunnelCemi -Connection $c -Cemi $cemi -Sequence $repeat -TimeoutMs 3000 -NoAdvance
            Add-KnxEvidence -Sent $r.Sent -Note "repeated sequence $repeat"
            Assert-KnxTrue $r.Acked 'a repeated (not increased) sequence number must still be acknowledged'
            Assert-KnxEqual $repeat $r.AckSeq 'the ACK must echo the repeated sequence number'
            Assert-KnxStatus 0 $r.Status 'ACK for the repeated sequence reports an error status'
        }
        finally { [void](Close-KnxConnection -Connection $c) }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.2.4' -Title 'Sequence Counter increased by two' -Clause 'TSSH 5.2.4, p.71 (fn 30204)' -Body {
        if ($Ctx.ReadOnly) { Set-KnxTestSkip 'profile ReadOnly - this case writes to the bus' }
        $c = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $TUN -Layer $K.Layer.TUNNEL_LINKLAYER
        Assert-KnxTrue $c.Ok "could not open a tunnel ($($c.StatusName))"
        try {
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination (ConvertTo-KnxGa -Address '0/0/4') -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 0)
            foreach ($i in 0..1) {
                $r = Send-KnxTunnelCemi -Connection $c -Cemi $cemi -TimeoutMs 3000
                Assert-KnxTrue $r.Acked "no ACK for tunnelling request with sequence $($r.Sequence)"
            }
            Clear-KnxSocket -Socket $c.Socket -QuietMs 400

            # Skip one: send the expected sequence + 1. This must NOT be acknowledged.
            $skipped = ($c.SeqSend + 1) -band 0xFF
            $r = Send-KnxTunnelCemi -Connection $c -Cemi $cemi -Sequence $skipped -TimeoutMs 2500 -NoAdvance
            Add-KnxEvidence -Sent $r.Sent -Note "sent sequence $skipped, expected was $($c.SeqSend)"
            Assert-KnxTrue (-not $r.Acked) "device acknowledged a sequence number one too large (acked seq $($r.AckSeq))"
        }
        finally { [void](Close-KnxConnection -Connection $c) }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.2.5' -Title 'Busmonitor indication tunnelled from KNX' -Clause 'TSSH 5.2.5, p.73 (fn 30205)' -Body {
        if (-not $Ctx.TrafficIp) { Set-KnxTestSkip 'needs a second interface (-TrafficIp) to generate bus traffic' }
        if ($Ctx.ReadOnly) { Set-KnxTestSkip 'profile ReadOnly - this case writes to the bus' }

        $c = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $TUN -Layer $K.Layer.TUNNEL_BUSMONITOR
        if (-not $c.Ok) {
            if (@($K.Error.E_CONNECTION_OPTION, $K.Error.E_TUNNELING_LAYER) -contains $c.Status) {
                Set-KnxTestNotApplicable "device does not support busmonitor tunnelling (refused with $(Get-KnxErrorName -Status $c.Status), see H-5.1.4)"
            }
            Assert-KnxTrue $false "busmonitor tunnel refused with $($c.StatusName)"
        }
        $src = Get-KnxTrafficConnection -Ip $Ctx.TrafficIp -Port $port
        try {
            Assert-KnxTrue ($null -ne $src) 'no tunnel available on the traffic interface'
            $ga = ConvertTo-KnxGa -Address '0/0/5'
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $ga -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)
            [void](Send-KnxTunnelCemi -Connection $src -Cemi $cemi -TimeoutMs 3000)

            $seen = $null
            $deadline = [DateTime]::UtcNow.AddSeconds(6)
            while ([DateTime]::UtcNow -lt $deadline) {
                $in = Receive-KnxTunnelCemi -Connection $c -TimeoutMs 1500
                if ($null -eq $in) { continue }
                if ($in.Cemi.Length -ge 1 -and $in.Cemi[0] -eq $K.Cemi.L_BUSMON_IND) { $seen = $in; break }
            }
            Assert-KnxTrue ($null -ne $seen) 'no L_Busmon.ind arrived on the busmonitor tunnel'
            Add-KnxEvidence -Received $seen.Cemi
            $bm = Read-CemiBusmon -Cemi $seen.Cemi
            Assert-KnxTrue ($null -ne $bm) 'L_Busmon.ind could not be decoded'
            Add-KnxEvidence -Note "AddIL $($bm.AddIL), sequence $($bm.Sequence), lost $($bm.Lost), FCS ok $($bm.FcsOk)"
            # The raw LPDU must end in a valid TP1 frame check octet - a busmonitor that
            # reports a telegram with a broken FCS is reporting something it did not see.
            Assert-KnxTrue $bm.FcsOk 'the raw LPDU in L_Busmon.ind has an invalid TP1 frame check octet'
        }
        finally {
            [void](Close-KnxConnection -Connection $c)
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.2.6' -Title 'Raw mode indication tunnelled from KNX' -Clause 'TSSH 5.2.6, p.74 (fn 30206)' -Body {
        if (-not $Ctx.TrafficIp) { Set-KnxTestSkip 'needs a second interface (-TrafficIp) to generate bus traffic' }
        if ($Ctx.ReadOnly) { Set-KnxTestSkip 'profile ReadOnly - this case writes to the bus' }

        $c = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $TUN -Layer $K.Layer.TUNNEL_RAW
        if (-not $c.Ok) {
            if (@($K.Error.E_CONNECTION_OPTION, $K.Error.E_TUNNELING_LAYER) -contains $c.Status) {
                Set-KnxTestNotApplicable "device does not support cEMI raw mode tunnelling (refused with $(Get-KnxErrorName -Status $c.Status), see H-5.1.3)"
            }
            Assert-KnxTrue $false "raw tunnel refused with $($c.StatusName)"
        }
        $src = Get-KnxTrafficConnection -Ip $Ctx.TrafficIp -Port $port
        try {
            Assert-KnxTrue ($null -ne $src) 'no tunnel available on the traffic interface'
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination (ConvertTo-KnxGa -Address '0/0/6') -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)
            [void](Send-KnxTunnelCemi -Connection $src -Cemi $cemi -TimeoutMs 3000)

            $seen = $null
            $deadline = [DateTime]::UtcNow.AddSeconds(6)
            while ([DateTime]::UtcNow -lt $deadline) {
                $in = Receive-KnxTunnelCemi -Connection $c -TimeoutMs 1500
                if ($null -eq $in) { continue }
                if ($in.Cemi.Length -ge 1 -and $in.Cemi[0] -eq $K.Cemi.L_RAW_IND) { $seen = $in; break }
            }
            Assert-KnxTrue ($null -ne $seen) 'no L_Raw.ind arrived on the raw tunnel'
            Add-KnxEvidence -Received $seen.Cemi
        }
        finally {
            [void](Close-KnxConnection -Connection $c)
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.2.7' -Title 'Repeat and timeout after missing ACK' -Clause 'TSSH 5.2.7, p.75 (fn 30207)' -Body {
        if ($Ctx.SkipSlow) { Set-KnxTestSkip 'measures a repetition timeout - excluded by -SkipSlow' }
        if (-not $Ctx.TrafficIp) { Set-KnxTestSkip 'needs a second interface (-TrafficIp) to make the device send on the tunnel' }
        if ($Ctx.ReadOnly) { Set-KnxTestSkip 'profile ReadOnly - this case writes to the bus' }

        $c = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $TUN -Layer $K.Layer.TUNNEL_LINKLAYER
        Assert-KnxTrue $c.Ok "could not open a tunnel ($($c.StatusName))"
        $src = Get-KnxTrafficConnection -Ip $Ctx.TrafficIp -Port $port
        try {
            Assert-KnxTrue ($null -ne $src) 'no tunnel available on the traffic interface'
            $ga = ConvertTo-KnxGa -Address '0/0/7'
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $ga -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)
            [void](Send-KnxTunnelCemi -Connection $src -Cemi $cemi -TimeoutMs 3000)

            # Receive WITHOUT acknowledging, then count how often the device repeats it.
            $first = Receive-KnxTunnelCemi -Connection $c -TimeoutMs 5000 -NoAck
            Assert-KnxTrue ($null -ne $first) 'the device never delivered the telegram on the tunnel'
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $repeats = 0
            $stamps = @()
            $foreign = 0
            # A REPETITION carries the SAME sequence counter as the frame it repeats
            # (03_08_04 section 2.6.1 p.9: "repeated once with the same sequence counter
            # value"). Counting every TUNNELLING_REQUEST that arrives instead reports any
            # unrelated bus telegram delivered on this tunnel as a repetition - on a live
            # bus that produced a "first repetition after 7.99 s", which was simply a
            # foreign telegram landing just before the window closed.
            $origSeq = $first.Sequence
            $deadline = [DateTime]::UtcNow.AddSeconds(8)
            while ([DateTime]::UtcNow -lt $deadline) {
                $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
                $r = Wait-KnxService -Socket $c.Socket -Service @($K.Service.TUNNELLING_REQUEST) -TimeoutMs $left
                if ($r.TimedOut) { break }
                $b = $r.Header.Body
                if ($b.Length -lt 4) { continue }
                if ($b[2] -ne $origSeq) { $foreign++; continue }   # unrelated traffic, not a repeat
                $repeats++
                $stamps += [Math]::Round($sw.Elapsed.TotalSeconds, 2)
            }
            if ($foreign -gt 0) { Add-KnxEvidence -Note "$foreign unrelated telegram(s) on this tunnel were ignored - only sequence $origSeq counts as a repetition" }
            $sw.Stop()
            Add-KnxEvidence -Note "repeated $repeats time(s) at $($stamps -join ', ') s"
            # The prufvorschrift expects exactly one repetition, roughly one second later.
            Assert-KnxTrue ($repeats -ge 1) 'device did not repeat the unacknowledged telegram at all'
            Assert-KnxTrue ($repeats -le 2) "device repeated the unacknowledged telegram $repeats times, expected 1"
            if ($stamps.Count -ge 1) {
                Assert-KnxTrue ($stamps[0] -ge 0.5 -and $stamps[0] -le 2.5) "first repetition came after $($stamps[0]) s, expected about 1 s"
            }
        }
        finally {
            # The case deliberately leaves a telegram unacknowledged; the connection must
            # still be handed back, or the device carries a half-open tunnel into the next
            # case until its own reaper fires.
            [void](Close-KnxConnection -Connection $c -TimeoutMs 1000)
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.2.8' -Title 'Broadcast telegram tunnelled to KNX' -Clause 'TSSH 5.2.8, p.76 (fn 30208)' -Body {
        if ($Ctx.ReadOnly) { Set-KnxTestSkip 'profile ReadOnly - this case writes a broadcast to the bus' }
        $c = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $TUN -Layer $K.Layer.TUNNEL_LINKLAYER
        Assert-KnxTrue $c.Ok "could not open a tunnel ($($c.StatusName))"
        try {
            # Broadcast = destination 0x0000 with the group-address flag set.
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination 0x0000 -IsGroup -Tpdu (New-TpduDeviceDescriptorRead -Descriptor 0) -Priority 0
            Add-KnxEvidence -Sent $cemi
            $r = Send-KnxTunnelCemi -Connection $c -Cemi $cemi -TimeoutMs 3000
            Assert-KnxTrue $r.Acked 'no TUNNELLING_ACK for the broadcast telegram'
            $con = Receive-KnxTunnelCemi -Connection $c -TimeoutMs 4000
            Assert-KnxTrue ($null -ne $con) 'no L_Data.con returned for the broadcast telegram'
            Add-KnxEvidence -Received $con.Cemi
            Assert-KnxEqual ('0x{0:X2}' -f $K.Cemi.L_DATA_CON) ('0x{0:X2}' -f $con.Cemi[0]) 'returned frame is not an L_Data.con'
        }
        finally { [void](Close-KnxConnection -Connection $c) }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.2.9' -Title 'Broadcast telegram tunnelled from KNX' -Clause 'TSSH 5.2.9, p.77 (fn 30209)' -Body {
        if (-not $Ctx.TrafficIp) { Set-KnxTestSkip 'needs a second interface (-TrafficIp) to put a broadcast on the bus' }
        if ($Ctx.ReadOnly) { Set-KnxTestSkip 'profile ReadOnly - this case writes a broadcast to the bus' }

        $c = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $TUN -Layer $K.Layer.TUNNEL_LINKLAYER
        Assert-KnxTrue $c.Ok "could not open a tunnel on the BDUT ($($c.StatusName))"
        $src = Get-KnxTrafficConnection -Ip $Ctx.TrafficIp -Port $port
        try {
            Assert-KnxTrue ($null -ne $src) 'no tunnel available on the traffic interface'
            # A_IndividualAddress_Read is the classic broadcast the prufvorschrift uses.
            $tpdu = [byte[]]@(0x01, 0x00)
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination 0x0000 -IsGroup -Tpdu $tpdu -Priority 0
            [void](Send-KnxTunnelCemi -Connection $src -Cemi $cemi -TimeoutMs 3000)

            $seen = $null
            $deadline = [DateTime]::UtcNow.AddSeconds(6)
            while ([DateTime]::UtcNow -lt $deadline) {
                $in = Receive-KnxTunnelCemi -Connection $c -TimeoutMs 1500
                if ($null -eq $in) { continue }
                $ld = Read-CemiLData -Cemi $in.Cemi
                if ($null -eq $ld) { continue }
                if ($ld.MessageCode -eq $K.Cemi.L_DATA_IND -and $ld.Destination -eq 0x0000 -and $ld.IsGroup) { $seen = $in; break }
            }
            Assert-KnxTrue ($null -ne $seen) 'the broadcast put on the bus never arrived as L_Data.ind on the tunnel'
            Add-KnxEvidence -Received $seen.Cemi
        }
        finally {
            [void](Close-KnxConnection -Connection $c)
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.2.10' -Title 'Point-to-point telegram tunnelled to KNX and back' -Clause 'TSSH 5.2.10, p.78 (fn 30210)' -Body {
        if ($Ctx.ReadOnly) { Set-KnxTestSkip 'profile ReadOnly - this case addresses a device on the bus' }
        # TSSH addresses the load switch here; any device that answers on the test line
        # proves the same thing, so -P2pTarget is accepted and preferred.
        $target = $Ctx.P2pTarget
        if (-not $target) { $target = $Ctx.LoadSwitchPa }
        if (-not $target) { Set-KnxTestSkip 'no point-to-point target on the test line - pass -P2pTarget (e.g. 5.0.3)' }

        $c = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $TUN -Layer $K.Layer.TUNNEL_LINKLAYER
        Assert-KnxTrue $c.Ok "could not open a tunnel ($($c.StatusName))"
        $dst = ConvertTo-KnxPa -Address $target
        $connected = $false
        try {
            $cn = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $dst -Tpdu (New-TpduConnect) -Priority 0
            $r = Send-KnxTunnelCemi -Connection $c -Cemi $cn -TimeoutMs 3000
            Assert-KnxTrue $r.Acked 'no ACK for the T_Connect'
            $connected = $true
            Start-Sleep -Milliseconds 300

            # MaskVersionRead = A_DeviceDescriptor_Read, numbered, sequence 0.
            $tpdu = [byte[]]@(0x43, 0x00)
            $rq = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $dst -Tpdu $tpdu -Priority 0
            Add-KnxEvidence -Sent $rq
            $r = Send-KnxTunnelCemi -Connection $c -Cemi $rq -TimeoutMs 3000
            Assert-KnxTrue $r.Acked 'no ACK for the MaskVersionRead'

            $answer = $null
            $deadline = [DateTime]::UtcNow.AddSeconds(6)
            while ([DateTime]::UtcNow -lt $deadline) {
                $in = Receive-KnxTunnelCemi -Connection $c -TimeoutMs 1500
                if ($null -eq $in) { continue }
                $ld = Read-CemiLData -Cemi $in.Cemi
                if ($null -eq $ld -or $ld.MessageCode -ne $K.Cemi.L_DATA_IND) { continue }
                if ($ld.Source -eq $dst) { $answer = $ld; break }
            }
            Assert-KnxTrue ($null -ne $answer) "no answer from $target came back over the tunnel"
            Add-KnxEvidence -Received $answer.Tpdu -Note "source address $(ConvertFrom-KnxPa -Raw $answer.Source)"
            Assert-KnxEqual $target (ConvertFrom-KnxPa -Raw $answer.Source) 'the response does not carry the target device as source address'
        }
        finally {
            if ($connected) {
                $d = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $dst -Tpdu (New-TpduDisconnect) -Priority 0
                [void](Send-KnxTunnelCemi -Connection $c -Cemi $d -TimeoutMs 2000)
            }
            [void](Close-KnxConnection -Connection $c)
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.2.11' -Title 'Group address telegram tunnelled to KNX' -Clause 'TSSH 5.2.11, p.81 (fn 30211)' -Body {
        if ($Ctx.ReadOnly) { Set-KnxTestSkip 'profile ReadOnly - this case writes a group telegram to the bus' }
        $c = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $TUN -Layer $K.Layer.TUNNEL_LINKLAYER
        Assert-KnxTrue $c.Ok "could not open a tunnel ($($c.StatusName))"
        try {
            $ga = ConvertTo-KnxGa -Address '0/0/11'
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $ga -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)
            Add-KnxEvidence -Sent $cemi
            $r = Send-KnxTunnelCemi -Connection $c -Cemi $cemi -TimeoutMs 3000
            Assert-KnxTrue $r.Acked 'no TUNNELLING_ACK for the group telegram'
            # Wait for the confirmation OF THIS telegram, not simply the next frame that
            # arrives: a preceding case can still have a confirmation in flight, and taking
            # the first one made this case report a foreign destination as a device defect.
            $ld = $null
            $deadline = [DateTime]::UtcNow.AddSeconds(4)
            while ([DateTime]::UtcNow -lt $deadline) {
                $in = Receive-KnxTunnelCemi -Connection $c -TimeoutMs 1200
                if ($null -eq $in) { continue }
                $cand = Read-CemiLData -Cemi $in.Cemi
                if ($null -eq $cand) { continue }
                if ($cand.MessageCode -ne $K.Cemi.L_DATA_CON) { continue }
                if ($cand.Destination -ne $ga) {
                    Add-KnxEvidence -Note ("ignored a confirmation for {0} - not this request" -f (ConvertFrom-KnxGa -Raw $cand.Destination))
                    continue
                }
                $ld = $cand; Add-KnxEvidence -Received $in.Cemi; break
            }
            Assert-KnxTrue ($null -ne $ld) 'no L_Data.con for THIS group telegram returned'
        }
        finally { [void](Close-KnxConnection -Connection $c) }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.2.12' -Title 'Group address telegram tunnelled from KNX' -Clause 'TSSH 5.2.12, p.82 (fn 30212)' -Body {
        if (-not $Ctx.TrafficIp) { Set-KnxTestSkip 'needs a second interface (-TrafficIp) to put a telegram on the bus' }
        if ($Ctx.ReadOnly) { Set-KnxTestSkip 'profile ReadOnly - this case writes to the bus' }

        $c = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $TUN -Layer $K.Layer.TUNNEL_LINKLAYER
        Assert-KnxTrue $c.Ok "could not open a tunnel on the BDUT ($($c.StatusName))"
        $src = Get-KnxTrafficConnection -Ip $Ctx.TrafficIp -Port $port
        try {
            Assert-KnxTrue ($null -ne $src) 'no tunnel available on the traffic interface'
            $ga = ConvertTo-KnxGa -Address '0/0/12'
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $ga -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 0)
            [void](Send-KnxTunnelCemi -Connection $src -Cemi $cemi -TimeoutMs 3000)

            $seen = $null
            $deadline = [DateTime]::UtcNow.AddSeconds(6)
            while ([DateTime]::UtcNow -lt $deadline) {
                $in = Receive-KnxTunnelCemi -Connection $c -TimeoutMs 1500
                if ($null -eq $in) { continue }
                $ld = Read-CemiLData -Cemi $in.Cemi
                if ($null -eq $ld) { continue }
                if ($ld.MessageCode -eq $K.Cemi.L_DATA_IND -and $ld.Destination -eq $ga -and $ld.IsGroup) { $seen = $in; break }
            }
            Assert-KnxTrue ($null -ne $seen) 'the group telegram put on the bus never arrived on the tunnel'
            Add-KnxEvidence -Received $seen.Cemi
        }
        finally {
            [void](Close-KnxConnection -Connection $c)
        }
    }

    # ── 5.3 Tunnel Addresses ────────────────────────────────────────────────────
    #
    # These cases reconfigure PID_ADDITIONAL_INDIVIDUAL_ADDRESSES. Every one of them
    # restores the original list in its finally block - leaving a device with a test
    # address list would silently break every later run.

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.3.1' -Title 'Tunnel Addresses - Standard Case' -Clause 'TSSH 5.3.1, p.83 (fn 30301)' -Body {
        if (-not $Ctx.AllowDestructive) { Set-KnxTestSkip 'rewrites PID_ADDITIONAL_INDIVIDUAL_ADDRESSES - needs -IncludeDestructive with profile Full' }

        $mgmt = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
        Assert-KnxTrue $mgmt.Ok "could not open a device management connection ($($mgmt.StatusName))"
        $original = @()
        try {
            $original = Get-AdditionalAddresses -Connection $mgmt
            Assert-KnxTrue ($original.Count -gt 0) 'device exposes no PID_ADDITIONAL_INDIVIDUAL_ADDRESSES to test with'

            # Default parameter: first tunnel address 1.1.111, then consecutive.
            $first = ConvertTo-KnxPa -Address '1.1.111'
            $list = @()
            for ($i = 0; $i -lt $original.Count; $i++) { $list += ConvertFrom-KnxPa -Raw ($first + $i) }
            $w = Set-AdditionalAddresses -Connection $mgmt -Addresses $list
            Assert-KnxTrue $w.Ok "could not write the address list (error 0x$('{0:X2}' -f $w.ErrorCode))"
            Add-KnxEvidence -Note "wrote $($list.Count) addresses starting at $($list[0])"

            $r = Open-AllTunnels -Ip $ip -Port $port -Layer $K.Layer.TUNNEL_LINKLAYER
            try {
                Assert-KnxTrue ($r.Open.Count -gt 0) 'no tunnel could be opened after writing the address list'
                $given = @($r.Open | ForEach-Object { $_.TunnelPa })
                Add-KnxEvidence -Note "granted: $($given -join ', ')"

                $allowed = @($list)
                if (-not $Ctx.IsRouter) { $allowed += $Ctx.BdutPa }
                foreach ($pa in $given) {
                    Assert-KnxTrue ($allowed -contains $pa) "tunnel address $pa is not in the configured list"
                    # A device part of 0 addresses a line/area coupler, never a tunnel.
                    $dev = (ConvertTo-KnxPa -Address $pa) -band 0xFF
                    Assert-KnxTrue ($dev -ne 0) "tunnel address $pa has device part 0 - such an address must never be handed out"
                }
                if ($Ctx.IsRouter) {
                    Assert-KnxTrue ($given -notcontains $Ctx.BdutPa) "router handed out its own individual address $($Ctx.BdutPa) as a tunnel address"
                }
            }
            finally { Close-AllTunnels -Connections $r.Open }
        }
        finally {
            if ($original.Count -gt 0 -and $mgmt.Ok) { [void](Set-AdditionalAddresses -Connection $mgmt -Addresses $original) }
            [void](Close-KnxConnection -Connection $mgmt)
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.3.2' -Title 'Tunnel Addresses - Uniqueness' -Clause 'TSSH 5.3.2, p.84 (fn 30302)' -Body {
        if (-not $Ctx.AllowDestructive) { Set-KnxTestSkip 'rewrites PID_ADDITIONAL_INDIVIDUAL_ADDRESSES - needs -IncludeDestructive with profile Full' }

        $mgmt = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
        Assert-KnxTrue $mgmt.Ok "could not open a device management connection ($($mgmt.StatusName))"
        $original = @()
        try {
            $original = Get-AdditionalAddresses -Connection $mgmt
            Assert-KnxTrue ($original.Count -gt 0) 'device exposes no PID_ADDITIONAL_INDIVIDUAL_ADDRESSES to test with'

            # Fill the whole list with the SAME address (default parameter 1.1.111).
            $ta = '1.1.111'
            $list = @()
            for ($i = 0; $i -lt $original.Count; $i++) { $list += $ta }
            $w = Set-AdditionalAddresses -Connection $mgmt -Addresses $list
            Assert-KnxTrue $w.Ok "could not write the duplicate address list (error 0x$('{0:X2}' -f $w.ErrorCode))"

            $r = Open-AllTunnels -Ip $ip -Port $port -Layer $K.Layer.TUNNEL_LINKLAYER
            try {
                $given = @($r.Open | ForEach-Object { $_.TunnelPa })
                Add-KnxEvidence -Note "granted: $($given -join ', ') / refusal $(Get-KnxErrorName -Status $r.RefusalStatus)"
                $withTa = @($given | Where-Object { $_ -eq $ta })
                Assert-KnxTrue ($withTa.Count -le 1) "address $ta was handed out $($withTa.Count) times - a tunnel address must be unique"
            }
            finally { Close-AllTunnels -Connections $r.Open }
        }
        finally {
            if ($original.Count -gt 0 -and $mgmt.Ok) { [void](Set-AdditionalAddresses -Connection $mgmt -Addresses $original) }
            [void](Close-KnxConnection -Connection $mgmt)
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.3.3' -Title 'Tunnel Addresses - Assignment Method' -Clause 'TSSH 5.3.3, p.85 (fn 30303)' -Body {
        if ($Ctx.ReadOnly) { Set-KnxTestSkip 'profile ReadOnly - opens and closes tunnels on a production device' }
        # Open A, open B, close A, open C. C must get A's address back: the device always
        # returns the FIRST FREE entry of its list. This is the case that catches a device
        # which walks the list with a running index instead of searching for a free slot.
        $a = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $TUN -Layer $K.Layer.TUNNEL_LINKLAYER
        Assert-KnxTrue $a.Ok "could not open the first tunnel ($($a.StatusName))"
        $ra1 = $a.TunnelPa
        $b = $null; $cc = $null
        try {
            $b = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $TUN -Layer $K.Layer.TUNNEL_LINKLAYER
            if (-not $b.Ok) { Set-KnxTestSkip "device grants only one tunnel at a time ($($b.StatusName)) - the assignment method cannot be observed" }
            $ra2 = $b.TunnelPa
            Assert-KnxTrue ($ra1 -ne $ra2) "two simultaneous tunnels were given the same address $ra1"

            [void](Close-KnxConnection -Connection $a)
            $a = [pscustomobject]@{ Ok = $false }
            Start-Sleep -Milliseconds 700

            $cc = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $TUN -Layer $K.Layer.TUNNEL_LINKLAYER
            Assert-KnxTrue $cc.Ok "could not re-open a tunnel after freeing one ($($cc.StatusName))"
            $ra3 = $cc.TunnelPa
            Add-KnxEvidence -Note "RA1 $ra1, RA2 $ra2, RA3 $ra3"
            Assert-KnxEqual $ra1 $ra3 'after freeing the first tunnel address the device did not hand it out again - it is not returning the first free entry'
        }
        finally {
            if ($null -ne $cc -and $cc.Ok) { [void](Close-KnxConnection -Connection $cc) }
            if ($null -ne $b -and $b.Ok) { [void](Close-KnxConnection -Connection $b) }
            if ($a.Ok) { [void](Close-KnxConnection -Connection $a) }
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.3.4' -Title 'Tunnel E_NO_MORE_CONNECTIONS' -Clause 'TSSH 5.3.4, p.85 (fn 30304)' -Body {
        if ($Ctx.ReadOnly) { Set-KnxTestSkip 'profile ReadOnly - exhausting the tunnel pool locks out other clients' }
        $r = Open-AllTunnels -Ip $ip -Port $port -Layer $K.Layer.TUNNEL_LINKLAYER
        try {
            if ($null -ne $r.RefusalResponse) { Add-KnxEvidence -Received $r.RefusalResponse }
            $given = @($r.Open | ForEach-Object { $_.TunnelPa })
            Add-KnxEvidence -Note "$($r.Open.Count) tunnel(s): $($given -join ', ') / refusal $(Get-KnxErrorName -Status $r.RefusalStatus)"
            Assert-KnxTrue ($r.RefusalStatus -ge 0) 'device never refused a further tunnel'

            # Judge on the configured POOL, not on the granted addresses: those are distinct
            # by construction (the server never opens two tunnels with the same address), so
            # checking them confirms this case's own premise. An ETS tunnel entry left without
            # an address appears in the pool as a duplicate of its neighbour, and that is
            # exactly the 03_08_04 (p.6) condition under which 0x25 is the required answer.
            $unique = @($given | Sort-Object -Unique)
            $pool = Get-KnxTunnelPool -Ip $ip -Port $port
            $poolUnique = @($pool | Sort-Object -Unique)
            $poolHasDuplicate = ($pool.Count -gt 0 -and $poolUnique.Count -lt $pool.Count)
            if ($pool.Count -gt 0) {
                Add-KnxEvidence -Note "pool: $($pool.Count) entries, $($poolUnique.Count) distinct - $($pool -join ', ')"
            }
            if ($poolHasDuplicate) {
                Assert-KnxStatus $K.Error.E_NO_MORE_UNIQUE_CONNECTIONS $r.RefusalStatus 'the pool contains duplicate addresses, so exhaustion must report E_NO_MORE_UNIQUE_CONNECTIONS'
            }
            elseif ($pool.Count -eq 0 -and $unique.Count -eq $given.Count) {
                Assert-KnxStatus $K.Error.E_NO_MORE_CONNECTIONS $r.RefusalStatus 'all tunnel addresses were distinct, so exhaustion must report E_NO_MORE_CONNECTIONS'
            }
            else {
                Assert-KnxTrue (@($K.Error.E_NO_MORE_CONNECTIONS, $K.Error.E_NO_MORE_UNIQUE_CONNECTIONS) -contains $r.RefusalStatus) `
                    "refusal status $(Get-KnxErrorName -Status $r.RefusalStatus) is neither E_NO_MORE_CONNECTIONS nor E_NO_MORE_UNIQUE_CONNECTIONS"
            }
        }
        finally { Close-AllTunnels -Connections $r.Open }
    }

    foreach ($case in @(
            @{ Id = 'H-5.3.5'; Title = 'Tunnel E_NO_MORE_UNIQUE_CONNECTIONS - Case 1'; Clause = 'TSSH 5.3.5, p.88 (fn 30305)'; UseOwn = $false },
            @{ Id = 'H-5.3.6'; Title = 'Tunnel E_NO_MORE_UNIQUE_CONNECTIONS - Case 2'; Clause = 'TSSH 5.3.6, p.90 (fn 30306)'; UseOwn = $true })) {
        $useOwn = $case.UseOwn
        Invoke-KnxTestCase -Suite $SuiteTitle -Id $case.Id -Title $case.Title -Clause $case.Clause -Body {
            if (-not $Ctx.AllowDestructive) { Set-KnxTestSkip 'rewrites PID_ADDITIONAL_INDIVIDUAL_ADDRESSES - needs -IncludeDestructive with profile Full' }

            $mgmt = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
            Assert-KnxTrue $mgmt.Ok "could not open a device management connection ($($mgmt.StatusName))"
            $original = @()
            try {
                $original = Get-AdditionalAddresses -Connection $mgmt
                Assert-KnxTrue ($original.Count -gt 0) 'device exposes no PID_ADDITIONAL_INDIVIDUAL_ADDRESSES to test with'
                $na = $original.Count

                # Case 1 fills the list with one arbitrary address; case 2 fills it with the
                # BDUT's own address. The expected code depends on NA and on whether the
                # device's own address may serve as a tunnel address at all.
                $ta = '1.1.111'
                if ($useOwn) {
                    if (-not $Ctx.BdutPa) { Set-KnxTestSkip 'BDUT individual address unknown (-BdutPa)' }
                    $ta = $Ctx.BdutPa
                }
                $list = @()
                for ($i = 0; $i -lt $na; $i++) { $list += $ta }
                $w = Set-AdditionalAddresses -Connection $mgmt -Addresses $list
                Assert-KnxTrue $w.Ok "could not write the address list (error 0x$('{0:X2}' -f $w.ErrorCode))"

                $r = Open-AllTunnels -Ip $ip -Port $port -Layer $K.Layer.TUNNEL_LINKLAYER
                try {
                    $given = @($r.Open | ForEach-Object { $_.TunnelPa })
                    Add-KnxEvidence -Note "NA=$na, TA=$ta, granted $($r.Open.Count): $($given -join ', ') / refusal $(Get-KnxErrorName -Status $r.RefusalStatus)"
                    if ($null -ne $r.RefusalResponse) { Add-KnxEvidence -Received $r.RefusalResponse }
                    Assert-KnxTrue ($r.RefusalStatus -ge 0) 'device never refused a further tunnel'

                    # A router may never hand out its own individual address as a tunnel
                    # address, so the "DA can be tunnel address" branch does not apply to it.
                    $daUsable = (-not $Ctx.IsRouter)
                    $expectUnique = $false
                    if ($useOwn) { $expectUnique = -not ($na -eq 0 -and $daUsable) }
                    else { $expectUnique = ($na -gt 1) -or ($na -eq 1 -and $ta -eq $Ctx.BdutPa -and $daUsable) }

                    if ($expectUnique) {
                        Assert-KnxStatus $K.Error.E_NO_MORE_UNIQUE_CONNECTIONS $r.RefusalStatus 'duplicate tunnel addresses must be refused with E_NO_MORE_UNIQUE_CONNECTIONS'
                    }
                    else {
                        Assert-KnxStatus $K.Error.E_NO_MORE_CONNECTIONS $r.RefusalStatus 'with no duplicate left to reject the refusal must be E_NO_MORE_CONNECTIONS'
                    }
                }
                finally { Close-AllTunnels -Connections $r.Open }
            }
            finally {
                if ($original.Count -gt 0 -and $mgmt.Ok) { [void](Set-AdditionalAddresses -Connection $mgmt -Addresses $original) }
                [void](Close-KnxConnection -Connection $mgmt)
            }
        }
    }

    # ── 5.4 NAT Compatibility ───────────────────────────────────────────────────
    #
    # A NAT-compatible client sends 0.0.0.0:0 in its HPAI ("route back"): the server must
    # then answer to the UDP source endpoint it actually received the frame from. The
    # variants additionally set only the IP or only the port, which must not change that.

    $natCases = @(
        @{ Id = 'H-5.4.1'; Title = 'NAT compatible tunnelling to KNX - Standard Case'; Clause = 'TSSH 5.4.1, p.91 (fn 30401)'; SetIp = $false; SetPort = $false },
        @{ Id = 'H-5.4.2'; Title = 'NAT compatible tunnelling to KNX - IP address set'; Clause = 'TSSH 5.4.2, p.95 (fn 30402)'; SetIp = $true;  SetPort = $false },
        @{ Id = 'H-5.4.3'; Title = 'NAT compatible tunnelling to KNX - port number set'; Clause = 'TSSH 5.4.3, p.96 (fn 30403)'; SetIp = $false; SetPort = $true }
    )
    foreach ($case in $natCases) {
        $setIp = $case.SetIp; $setPort = $case.SetPort
        Invoke-KnxTestCase -Suite $SuiteTitle -Id $case.Id -Title $case.Title -Clause $case.Clause -Body {
            if ($Ctx.ReadOnly) { Set-KnxTestSkip 'profile ReadOnly - this case writes a group telegram to the bus' }
            $hIp = '0.0.0.0'
            if ($setIp) { $hIp = Get-LocalEndpointFor -DestinationIp $ip -Port $port }
            $c = Open-TunnelRaw -Ip $ip -Port $port -HpaiIp $hIp -HpaiPort 0 -UseRealPort:$setPort -Layer $K.Layer.TUNNEL_LINKLAYER
            Add-KnxEvidence -Sent $c.Request
            if ($null -ne $c.Response) { Add-KnxEvidence -Received $c.Response }
            Assert-KnxTrue $c.Ok "device refused a NAT-compatible connect request ($($c.StatusName)) - it must answer to the UDP source endpoint"
            try {
                $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination (ConvertTo-KnxGa -Address '0/0/13') -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 0)
                $r = Send-KnxTunnelCemi -Connection $c -Cemi $cemi -TimeoutMs 3000
                Assert-KnxTrue $r.Acked 'no TUNNELLING_ACK on a NAT-compatible connection - the device did not answer to the source endpoint'
                Assert-KnxStatus 0 $r.Status 'TUNNELLING_ACK reports an error status on the NAT-compatible connection'
            }
            finally { [void](Close-KnxConnection -Connection $c) }
        }
    }

    $natFrom = @(
        @{ Id = 'H-5.4.4'; Title = 'NAT compatible tunnelling from KNX - Standard Case'; Clause = 'TSSH 5.4.4, p.98 (fn 30404)'; SetIp = $false; SetPort = $false },
        @{ Id = 'H-5.4.5'; Title = 'NAT compatible tunnelling from KNX - IP address set'; Clause = 'TSSH 5.4.5, p.99 (fn 30405)'; SetIp = $true;  SetPort = $false },
        @{ Id = 'H-5.4.6'; Title = 'NAT compatible tunnelling from KNX - port number set'; Clause = 'TSSH 5.4.6, p.100 (fn 30406)'; SetIp = $false; SetPort = $true }
    )
    foreach ($case in $natFrom) {
        $setIp = $case.SetIp; $setPort = $case.SetPort
        Invoke-KnxTestCase -Suite $SuiteTitle -Id $case.Id -Title $case.Title -Clause $case.Clause -Body {
            if (-not $Ctx.TrafficIp) { Set-KnxTestSkip 'needs a second interface (-TrafficIp) to put a telegram on the bus' }
            if ($Ctx.ReadOnly) { Set-KnxTestSkip 'profile ReadOnly - this case writes to the bus' }

            $hIp = '0.0.0.0'
            if ($setIp) { $hIp = Get-LocalEndpointFor -DestinationIp $ip -Port $port }
            $c = Open-TunnelRaw -Ip $ip -Port $port -HpaiIp $hIp -HpaiPort 0 -UseRealPort:$setPort -Layer $K.Layer.TUNNEL_LINKLAYER
            Add-KnxEvidence -Sent $c.Request
            Assert-KnxTrue $c.Ok "device refused a NAT-compatible connect request ($($c.StatusName))"

            $src = Get-KnxTrafficConnection -Ip $Ctx.TrafficIp -Port $port
            try {
                Assert-KnxTrue ($null -ne $src) 'no tunnel available on the traffic interface'
                $ga = ConvertTo-KnxGa -Address '0/0/14'
                $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $ga -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)
                [void](Send-KnxTunnelCemi -Connection $src -Cemi $cemi -TimeoutMs 3000)

                $seen = $null
                $deadline = [DateTime]::UtcNow.AddSeconds(6)
                while ([DateTime]::UtcNow -lt $deadline) {
                    $in = Receive-KnxTunnelCemi -Connection $c -TimeoutMs 1500
                    if ($null -eq $in) { continue }
                    $ld = Read-CemiLData -Cemi $in.Cemi
                    if ($null -eq $ld) { continue }
                    if ($ld.MessageCode -eq $K.Cemi.L_DATA_IND -and $ld.Destination -eq $ga) { $seen = $in; break }
                }
                Assert-KnxTrue ($null -ne $seen) 'the bus telegram never arrived on the NAT-compatible tunnel - the device is not answering to the UDP source endpoint'
                Add-KnxEvidence -Received $seen.Cemi
            }
            finally {
                [void](Close-KnxConnection -Connection $c)
            }
        }
    }
}
