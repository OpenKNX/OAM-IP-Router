#!/usr/bin/env pwsh
# Open ■
# ┬────┴  5-Tunnelling.Tests
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/Suites/5-Tunnelling.Tests.ps1

<#
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
      * 5.1.3/5.1.4/5.1.5 name E_CONNECTION_OPTION (0x23) for an unsupported or invalid
        KNX layer; 03_08_04 itself names 0x23 (Figure 6 p.27) and 0x29 (text p.28), so both pass.
      * 5.2.3 (sequence not increased) must be ACKED but NOT put on the bus.
      * 5.2.4 (sequence one too large) must NOT be acked and NOT put on the bus.
      * 5.2.7 repeats ONCE after 1 second - unlike 4.2.11, which repeats 3 times / 10 s.
      * 5.3.1 forbids a returned tunnel address of the form x.y.0.
#>

Set-StrictMode -Version Latest
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/KnxDevice.psm1') -Force -DisableNameChecking

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
        LocalIp = $HpaiIp; LocalPort = (Get-SocketLocalPort -Socket $sock); Parsed = $cr
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
        Reads PID_ADDITIONAL_INDIVIDUAL_ADDRESSES from the KNXnet/IP parameter object - completely, or
        not at all.
    .DESCRIPTION
        03_03_07 array semantics, and the stack implements exactly them (knx data_property.cpp): element
        index 0 carries the current number of elements, and a read of N elements from index S is
        all-or-nothing - a device holding 16 refuses "15 from index 16" outright.

        So the procedure is: ask index 0 how many there are, then read them in blocks of at most 15 (the
        cEMI element-count field is 4 bits), advancing by what each block actually returned and asking
        again for the remainder. If the total still falls short of the stated count the list is
        INCOMPLETE, and that is reported rather than returned short:
        a caller that rewrites a short list overlays the front and leaves the tail standing, the device
        hands the old tail out as a tunnel address, and the case reports a correct device as defective.
    .OUTPUTS
        Addresses: the "a.l.d" strings, in element order. Complete: false when the device holds more than
        was read. Held: what the device says it holds.
    #>
    param($Connection)
    $K = Get-KnxConstants
    $raw = [byte[]]@()
    $c0 = Read-KnxProperty -Connection $Connection -ObjectType $K.ObjType.KNXNETIP_PARAM `
                           -PropertyId $K.Pid.ADDITIONAL_INDIVIDUAL_ADDRESSES -ElementCount 1 -StartIndex 0
    $held = -1
    if ($null -ne $c0.Parsed -and -not $c0.Parsed.IsError -and $c0.Parsed.Data.Length -ge 2) {
        $held = Get-Uint16 -Bytes $c0.Parsed.Data -Offset 0
    }
    if ($held -lt 0) {
        # No count to go by. Walk element by element - one at a time is the only request an
        # all-or-nothing read cannot refuse for being too large - and take where it stops as the length.
        # The cap is a runaway guard, not an expectation: this property holds KNX_TUNNELING entries.
        for ($i = 1; $i -le 64; $i++) {
            $r = Read-KnxProperty -Connection $Connection -ObjectType $K.ObjType.KNXNETIP_PARAM `
                                  -PropertyId $K.Pid.ADDITIONAL_INDIVIDUAL_ADDRESSES -ElementCount 1 -StartIndex $i
            if ($null -eq $r.Parsed -or $r.Parsed.IsError -or $r.Parsed.Data.Length -lt 2) { break }
            $raw = [byte[]]($raw + $r.Parsed.Data)
        }
        # NOT $held = what the walk found: that would make Complete below compare a number with itself
        # and swear a truncated list is whole. On this path the length is unknown by definition - the
        # count read is the only thing that can state it, and it did not answer.
        $held = -1
    }
    else {
        $index = 1
        while ($index -le $held -and $index -le 64) {
            $n = [Math]::Min(15, $held - $index + 1)
            $r = Read-KnxProperty -Connection $Connection -ObjectType $K.ObjType.KNXNETIP_PARAM `
                                  -PropertyId $K.Pid.ADDITIONAL_INDIVIDUAL_ADDRESSES -ElementCount $n -StartIndex $index
            if ($null -eq $r.Parsed -or $r.Parsed.IsError) { break }
            # Advance by what CAME BACK, never by what was asked for: a positive answer carrying fewer
            # elements than requested would otherwise shift every following block in the buffer.
            # Floor, not [int]: PowerShell rounds .5 to even, so an odd octet count would advance the
            # index by one element too many and shift every following block in the buffer.
            $got = [int][Math]::Floor($r.Parsed.Data.Length / 2)
            if ($got -le 0) { break }
            $raw = [byte[]]($raw + $r.Parsed.Data)
            $index += $got
        }
    }
    $list = @()
    for ($i = 0; ($i + 1) -lt $raw.Length; $i += 2) {
        $list += ConvertFrom-KnxPa -Raw (Get-Uint16 -Bytes $raw -Offset $i)
    }
    return [pscustomobject]@{
        Addresses = $list
        Held      = $held
        # Complete only when the device stated a length AND that many elements came back. An element walk
        # without a stated length cannot tell its natural end from a lost answer, so it is never complete.
        Complete  = ($held -ge 0 -and $list.Count -eq $held)
    }
}

function Get-AdditionalAddressesOrSkip {
    <#
    .SYNOPSIS
        The list, or a skip naming what could not be read. For the cases that go on to WRITE it.
    .DESCRIPTION
        Not knowing the device's state is a reason not to touch it, not a reason to touch part of it.
    #>
    param($Connection)
    $a = Get-AdditionalAddresses -Connection $Connection
    if (-not $a.Complete) {
        $what = if ($a.Held -lt 0) { "the device did not state how many it holds, and $($a.Addresses.Count) came back element by element" }
                else { "$($a.Addresses.Count) of $($a.Held) elements came back" }
        Set-KnxTestSkip "the additional address list could not be read completely - $what. Rewriting a partial list would leave the rest of the pool standing, and the device would hand those addresses out"
    }
    # An empty pool is a configuration, not a defect: say so instead of failing the assertion below.
    if ($a.Addresses.Count -eq 0) { Set-KnxTestNotApplicable 'the device exposes no additional individual addresses to test with' }
    return , @($a.Addresses)
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

        The list is NOT cleared first. Every caller here writes exactly as many entries as the device
        holds, so an overlay is complete - and a clear (element index 0 written as zero, 03_03_07) is one
        refused element write away from leaving the device with an EMPTY pool, which the restore in a
        finally would then repeat rather than repair. A future caller that writes a SHORTER list has to
        deal with the tail itself, and should say in its own code why that is safe there.
    #>
    param($Connection, [string[]]$Addresses)
    $K = Get-KnxConstants
    $total = $Addresses.Count
    if ($total -eq 0) { return [pscustomobject]@{ Ok = $false; ErrorCode = -1 } }
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


function Get-KnxForeignEndpoint {
    <#
    .SYNOPSIS
        Picks a second local address that plays the foreign client, or $null when the rig has none.
    .DESCRIPTION
        Only an address on the same network interface as the owner's and on its /24 is taken: an address
        of another interface in the same range (a second LAN) would send elsewhere. The address must also
        reach the device - a DESCRIPTION_REQUEST from it has to be answered (03_08_02 4.3 p.11, 7.7.2 p.36) - or a foreign
        datagram that never arrived would read as "the device ignored it".
    #>
    param([Parameter(Mandatory)][string]$Ip, [int]$Port = 3671, [Parameter(Mandatory)][string]$Mine)
    $KC = Get-KnxConstants
    $subnet = ($Mine -replace '\.\d+$', '')
    $candidates = @()
    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
        $addrs = @($nic.GetIPProperties().UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
                   ForEach-Object { $_.Address.ToString() })
        if ($addrs -notcontains $Mine) { continue }
        $candidates += @($addrs | Where-Object { $_ -ne $Mine -and ($_ -replace '\.\d+$', '') -eq $subnet })
    }
    foreach ($cand in $candidates) {
        $sock = New-Object System.Net.Sockets.Socket([System.Net.Sockets.AddressFamily]::InterNetwork, [System.Net.Sockets.SocketType]::Dgram, [System.Net.Sockets.ProtocolType]::Udp)
        try {
            $sock.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($cand), 0)))
            $f = New-KnxDescriptionRequest -ControlIp $cand -ControlPort $sock.LocalEndPoint.Port
            [void]$sock.SendTo($f, (New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($Ip), $Port)))
            $r = Wait-KnxService -Socket $sock -Service @($KC.Service.DESCRIPTION_RESPONSE) -TimeoutMs 1500
            if (-not $r.TimedOut -and ($r.Packet.From -replace ':\d+$', '') -eq [System.Net.IPAddress]::Parse($Ip).ToString()) { return $cand }
        }
        catch { }
        finally { $sock.Dispose() }
    }
    return $null
}

function Wait-KnxDisconnectWhileAcking {
    <#
    .SYNOPSIS
        Waits for a DISCONNECT_REQUEST on a tunnel while acknowledging everything the device sends.
    .DESCRIPTION
        A client that stays silent is not idle, it is broken: the device forwards bus traffic into the
        tunnel, gets no TUNNELLING_ACK, repeats and then drops the connection (03_08_04 2.6.1). Measured
        on both products, that takes about two seconds, which is short enough to land inside any waiting
        window and be mistaken for the effect under test. So every frame is acknowledged here, and a
        disconnect that still arrives belongs to what the case did.
    .OUTPUTS
        The Sync-KnxTunnel result when the device ended the connection, null when it did not. The result
        is returned rather than the datagram: a teardown the heartbeat answered is reported through the
        connection state and carries no packet, and returning null there would read as "still open".
    #>
    param([Parameter(Mandatory)]$Connection, [int]$TimeoutMs = 2500)
    # Sync-KnxTunnel is the one place that knows how to stay a valid client while waiting.
    $r = Sync-KnxTunnel -Connection $Connection -Ms $TimeoutMs
    # Only the device ending it is an answer about the device. A teardown this client sent after a failed
    # acknowledge is recorded on the same connection, and reporting that as "the device disconnected"
    # would let the harness's own mishap decide the result.
    if ($r.Disconnected -and (Get-KnxTunnelGoneBy -Connection $Connection) -eq 'device') { return $r }
    return $null
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
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - exhausting the tunnel pool locks out other clients' }
        $r = Open-AllTunnels -Ip $ip -Port $port -Layer $K.Layer.TUNNEL_LINKLAYER
        try {
            if ($null -ne $r.RefusalResponse) { Add-KnxEvidence -Received $r.RefusalResponse }
            Add-KnxEvidence -Note "$($r.Open.Count) tunnel(s) granted, then $(Get-KnxErrorName -Status $r.RefusalStatus)"
            Assert-KnxTrue ($r.Open.Count -ge 1) 'device granted no tunnel connection at all'
            Assert-KnxTrue ($r.RefusalStatus -ge 0) "device accepted $($r.Open.Count) tunnels without ever refusing"
            # This case only drives the device to ITS limit - it does not set up which limit that
            # is. Demanding 0x24 fails a device that ran out of unique addresses first, and the
            # reverse fails one whose slots went first; the server answers 0x24 on paths where a
            # slot is still free, so the rig cannot tell them apart from outside either. Which
            # limit was hit is what H-5.3.4 and H-5.3.5 set up and separate. Here: accept both,
            # record which one came, so a change of answer still shows up in the report.
            Assert-KnxStatusAny -Accept @($K.Error.E_NO_MORE_CONNECTIONS, $K.Error.E_NO_MORE_UNIQUE_CONNECTIONS) `
                                -Actual $r.RefusalStatus `
                                -Message 'refusal is neither E_NO_MORE_CONNECTIONS nor E_NO_MORE_UNIQUE_CONNECTIONS'
        }
        finally { Close-AllTunnels -Connections $r.Open }
    }

    foreach ($case in @(
            @{ Id = 'H-5.1.3'; Title = 'cEMI Raw Mode tunnelling connection';    Clause = 'TSSH 5.1.3, p.64 (fn 30105)'; Layer = 0x04 },
            @{ Id = 'H-5.1.4'; Title = 'KNX Busmonitor Mode tunnelling connection'; Clause = 'TSSH 5.1.4, p.65 (fn 30107)'; Layer = 0x80 })) {
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
                    # On a non-router this branch asserted nothing, so the case passed on any answer
                    # that merely carried E_NO_ERROR. What IS required of a grant: a CRD of the
                    # tunnelling type. 03_08_02 7.8.2 Figure 36 p.39 makes the CRD part of every
                    # successful CONNECT_RESPONSE and 03_08_04 5.4.4 p.30 fixes it at four octets,
                    # [len=04h][TUNNEL_CONNECTION=04h][IA]. TunnelPa is $null exactly when that
                    # structure is missing or carries another type code, so this judges the structure.
                    # Deliberately NOT asserted: a range on the communication channel id. 7.8.2 p.38
                    # only requires it to identify the connection uniquely and names no range, so a
                    # server handing out 0 would fail a rule the standard does not contain. Nor is a
                    # non-zero individual address required here: 2.2.2 p.6 assigns an IA to a LINK
                    # LAYER tunnel, while 2.2.4 p.8 (busmonitor) says nothing about one - a busmonitor
                    # connection carries only L_Busmon.ind upward and has no source address to assign.
                    Assert-KnxTrue ($null -ne $c.TunnelPa) `
                        'the device granted the mode but the CONNECT_RESPONSE carries no tunnelling CRD (03_08_04 5.4.4 p.30: four octets, type code 04h)'
                }
                else {
                    # 08_TSSH 5.1.3 p.64 / 5.1.4 p.65 and 03_08_04 Figure 6 p.27 (step 4.a) give E_CONNECTION_OPTION (23h); the text of step 4.a p.28 gives E_TUNNELLING_LAYER (29h).
                    # The references split on raw mode (MDT SCN-IP000.03 29h, Siemens N148 23h); both codes are accepted and the one that was used is recorded.
                    Assert-KnxTrue ($c.Status -ge 0) 'device did not answer the connect request at all'
                    Add-KnxEvidence -Note "refused with $(Get-KnxErrorName -Status $c.Status)"
                    Assert-KnxTrue (@($K.Error.E_CONNECTION_OPTION, $K.Error.E_TUNNELING_LAYER) -contains $c.Status) `
                        "unsupported tunnelling mode refused with $(Get-KnxErrorName -Status $c.Status) - expected E_CONNECTION_OPTION (0x23) or E_TUNNELING_LAYER (0x29)"
                }
            }
            finally { if ($c.Ok) { [void](Close-KnxConnection -Connection $c) } }
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.1.5' -Title 'Invalid KNX layer code' -Clause 'TSSH 5.1.5, p.66 (fn 30108)' -Body {
        # 08_TSSH 5.1.5 p.66 sends 3 random invalid layer codes; here the first three of a fixed list.
        # 0x02/0x04/0x80 are the defined ones (03_08_04 Table 10 p.26); 5.1.5 expects E_CONNECTION_OPTION.
        $bad = @(0x00, 0x01, 0x03, 0x7F, 0x81, 0xFF)
        $tried = 0
        $codes = @()
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
            # 03_08_04 step 4.a gives 23h in Figure 6 p.27 and 29h in the text p.28; for layer 03h the
            # references split: MDT SCN-IP000.03 29h, Siemens N148 23h. Both accepted.
            $codes += ("{0:X2}h -> {1}" -f $l, (Get-KnxErrorName -Status $c.Status))
            Assert-KnxTrue (@($K.Error.E_CONNECTION_OPTION, $K.Error.E_TUNNELING_LAYER) -contains $c.Status) `
                ("undefined KNX layer code 0x{0:X2} refused with {1} - expected E_CONNECTION_OPTION (0x23) or E_TUNNELING_LAYER (0x29)" -f $l, (Get-KnxErrorName -Status $c.Status))
        }
        Add-KnxEvidence -Note ("$tried undefined layer codes refused: " + ($codes -join ', '))
    }

    # ── 5.2 Tunnelling Request ──────────────────────────────────────────────────

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.2.1' -Title 'Standard Case - Tunnelling to KNX' -Clause 'TSSH 5.2.1, p.67 (fn 30204)' -Body {
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case writes a group telegram to the bus' }
        $c = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $TUN -Layer $K.Layer.TUNNEL_LINKLAYER
        Assert-KnxTrue $c.Ok "could not open a tunnel ($($c.StatusName))"
        try {
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination (ConvertTo-KnxGa -Address '0/0/1') -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 0)
            Add-KnxEvidence -Sent $cemi
            $r = Send-KnxTunnelCemi -Connection $c -Cemi $cemi -TimeoutMs 3000
            # Judge the fields first: an acknowledge that arrived with the wrong channel or sequence is
            # a finding in itself, and reporting it as "no acknowledge" would name the wrong defect.
            Assert-KnxTrue $r.AckSeen 'no TUNNELLING_ACK for the L_Data.req'
            Assert-KnxEqual 0 $r.AckSeq 'TUNNELLING_ACK carries the wrong sequence number'
            Assert-KnxEqual $c.Channel $r.AckChannel 'TUNNELLING_ACK carries the wrong channel id'
            # The status of the acknowledge that arrived, before asking whether it counted for this
            # frame: an error status is its own finding and must not be reported as "it did not belong".
            Assert-KnxStatus 0 $r.AckStatusSeen 'TUNNELLING_ACK reports an error status'
            Assert-KnxTrue $r.Acked 'the acknowledge did not belong to this frame'

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

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.2.2' -Title 'Standard Case - Tunnelling from KNX' -Clause 'TSSH 5.2.2, p.68 (fn 30205)' -Body {
        if (-not $Ctx.TrafficIp) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason 'needs a second interface (-TrafficIp) to put a telegram on the bus' }
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case writes a group telegram to the bus' }

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

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.2.3' -Title 'Not increased Sequence Counter' -Clause 'TSSH 5.2.3, p.69 (fn 30206)' -Body {
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case writes to the bus' }
        $c = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $TUN -Layer $K.Layer.TUNNEL_LINKLAYER
        Assert-KnxTrue $c.Ok "could not open a tunnel ($($c.StatusName))"
        try {
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination (ConvertTo-KnxGa -Address '0/0/3') -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 0)
            foreach ($i in 0..2) {
                $r = Send-KnxTunnelCemi -Connection $c -Cemi $cemi -TimeoutMs 3000
                Assert-KnxTrue $r.Acked "no ACK for tunnelling request with sequence $($r.Sequence)"
            }
            [void](Clear-KnxTunnelTraffic -Connection $c -QuietMs 400)

            # Repeat the LAST sequence number. Per the prufvorschrift this must still be
            # acknowledged - but must not be repeated on the bus.
            $repeat = ($c.SeqSend - 1) -band 0xFF
            $r = Send-KnxTunnelCemi -Connection $c -Cemi $cemi -Sequence $repeat -TimeoutMs 3000 -NoAdvance
            Add-KnxEvidence -Sent $r.Sent -Note "repeated sequence $repeat"
            Assert-KnxTrue $r.AckSeen 'a repeated (not increased) sequence number must still be acknowledged'
            Assert-KnxEqual $repeat $r.AckSeq 'the ACK must echo the repeated sequence number'
            Assert-KnxTrue $r.Acked 'the acknowledge did not carry this channel and sequence'
            Assert-KnxStatus 0 $r.Status 'ACK for the repeated sequence reports an error status'
        }
        finally { [void](Close-KnxConnection -Connection $c) }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.2.4' -Title 'Sequence Counter increased by two' -Clause 'TSSH 5.2.4, p.71 (fn 30207)' -Body {
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case writes to the bus' }
        $c = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $TUN -Layer $K.Layer.TUNNEL_LINKLAYER
        Assert-KnxTrue $c.Ok "could not open a tunnel ($($c.StatusName))"
        try {
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination (ConvertTo-KnxGa -Address '0/0/4') -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 0)
            foreach ($i in 0..1) {
                $r = Send-KnxTunnelCemi -Connection $c -Cemi $cemi -TimeoutMs 3000
                Assert-KnxTrue $r.Acked "no ACK for tunnelling request with sequence $($r.Sequence)"
            }
            [void](Clear-KnxTunnelTraffic -Connection $c -QuietMs 400)

            # Skip one: send the expected sequence + 1. This must NOT be acknowledged.
            $skipped = ($c.SeqSend + 1) -band 0xFF
            $r = Send-KnxTunnelCemi -Connection $c -Cemi $cemi -Sequence $skipped -TimeoutMs 2500 -NoAdvance
            Add-KnxEvidence -Sent $r.Sent -Note "sent sequence $skipped, expected was $($c.SeqSend)"
            # AckSeen, not Acked: a device that acknowledges the skipped frame with some OTHER sequence
            # number has still acknowledged it, and asking only whether it matched let that pass.
            # For THIS sequence: a stray or late acknowledge for an earlier frame can land in the five
            # seconds this send listens, and reading any acknowledge as the defect made the case fail
            # with a message that contradicted its own number.
            Assert-KnxTrue (-not ($r.AckSeen -and $r.AckSeq -eq $skipped)) `
                           "device acknowledged a sequence number one too large (acked seq $($r.AckSeq))"
        }
        finally { [void](Close-KnxConnection -Connection $c) }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.2.5' -Title 'Busmonitor indication tunnelled from KNX' -Clause 'TSSH 5.2.5, p.73 (fn 30208)' -Body {
        if (-not $Ctx.TrafficIp) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason 'needs a second interface (-TrafficIp) to generate bus traffic' }
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case writes to the bus' }

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

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.2.6' -Title 'Raw mode indication tunnelled from KNX' -Clause 'TSSH 5.2.6, p.74 (fn 30209)' -Body {
        if (-not $Ctx.TrafficIp) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason 'needs a second interface (-TrafficIp) to generate bus traffic' }
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case writes to the bus' }

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

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.2.7' -Title 'Repeat and timeout after missing ACK' -Clause 'TSSH 5.2.7, p.75 (fn 30210)' -Body {
        if ($Ctx.SkipSlow) { Set-KnxTestSkip 'measures a repetition timeout - excluded by -SkipSlow' }
        if (-not $Ctx.TrafficIp) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason 'needs a second interface (-TrafficIp) to make the device send on the tunnel' }
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case writes to the bus' }

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

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.2.8' -Title 'Broadcast telegram tunnelled to KNX' -Clause 'TSSH 5.2.8, p.76 (fn 30211)' -Body {
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case writes a broadcast to the bus' }
        $c = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $TUN -Layer $K.Layer.TUNNEL_LINKLAYER
        Assert-KnxTrue $c.Ok "could not open a tunnel ($($c.StatusName))"
        try {
            # Broadcast = destination 0x0000 with the group-address flag set.
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination 0x0000 -IsGroup -Tpdu (New-TpduDeviceDescriptorRead -Descriptor 0) -Priority 0
            Add-KnxEvidence -Sent $cemi
            $r = Send-KnxTunnelCemi -Connection $c -Cemi $cemi -TimeoutMs 3000
            Assert-KnxTrue $r.Acked 'no TUNNELLING_ACK for the broadcast telegram'
            # Take the confirmation out of what arrives instead of assuming it comes first: on a live bus
            # an L_Data.ind can overtake it, which failed this case against a correct device.
            $con = $null
            $deadline = [DateTime]::UtcNow.AddSeconds(4)
            while ([DateTime]::UtcNow -lt $deadline) {
                $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
                $in = Receive-KnxTunnelCemi -Connection $c -TimeoutMs $left
                if ($null -eq $in) { continue }
                if ($in.Cemi[0] -eq $K.Cemi.L_DATA_CON) { $con = $in; break }
                Add-KnxEvidence -Note ("ignored a 0x{0:X2} while waiting for the confirmation" -f $in.Cemi[0])
            }
            Assert-KnxTrue ($null -ne $con) 'no L_Data.con returned for the broadcast telegram'
            Add-KnxEvidence -Received $con.Cemi
            Assert-KnxEqual ('0x{0:X2}' -f $K.Cemi.L_DATA_CON) ('0x{0:X2}' -f $con.Cemi[0]) 'returned frame is not an L_Data.con'
        }
        finally { [void](Close-KnxConnection -Connection $c) }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.2.9' -Title 'Broadcast telegram tunnelled from KNX' -Clause 'TSSH 5.2.9, p.77 (fn 30212)' -Body {
        if (-not $Ctx.TrafficIp) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason 'needs a second interface (-TrafficIp) to put a broadcast on the bus' }
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case writes a broadcast to the bus' }

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

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.2.10' -Title 'Point-to-point telegram tunnelled to KNX and back' -Clause 'TSSH 5.2.10, p.78 (fn 30213)' -Body {
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case addresses a device on the bus' }
        # TSSH addresses the load switch here; any device that answers on the test line
        # proves the same thing, so -P2pTarget is accepted and preferred.
        $target = $Ctx.P2pTarget
        if (-not $target) { $target = $Ctx.LoadSwitchPa }
        if (-not $target) { Set-KnxTestSkip 'no point-to-point target on the test line - pass -P2pTarget (e.g. 1.1.7)' }

        $c = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $TUN -Layer $K.Layer.TUNNEL_LINKLAYER
        Assert-KnxTrue $c.Ok "could not open a tunnel ($($c.StatusName))"
        $dst = ConvertTo-KnxPa -Address $target
        $connected = $false
        try {
            $cn = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $dst -Tpdu (New-TpduConnect) -Priority 0
            $r = Send-KnxTunnelCemi -Connection $c -Cemi $cn -TimeoutMs 3000
            Assert-KnxTrue $r.Acked 'no ACK for the T_Connect'
            $connected = $true
            [void](Wait-KnxTunnel -Connection $c -Ms 300)

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

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.2.11' -Title 'Group address telegram tunnelled to KNX' -Clause 'TSSH 5.2.11, p.81 (fn 30215)' -Body {
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case writes a group telegram to the bus' }
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

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.2.12' -Title 'Group address telegram tunnelled from KNX' -Clause 'TSSH 5.2.12, p.82 (fn 30216)' -Body {
        if (-not $Ctx.TrafficIp) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason 'needs a second interface (-TrafficIp) to put a telegram on the bus' }
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case writes to the bus' }

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

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'P-5.2.13' -Title 'An acknowledge from another endpoint does not count' `
                       -Clause '03_08_02 5.5 p.14: a connection belongs to the endpoint that opened it' -Body {
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case leaves a frame unacknowledged' }
        $target = $Ctx.BdutPa
        if (-not $target) { Set-KnxTestNotRun -MissingInput '-BdutPa' -Reason 'BDUT individual address unknown (-BdutPa)' }
        # A second local address plays the foreign client; found before the tunnel opens, so its probe leaves no frame unacknowledged.
        $other = Get-KnxForeignEndpoint -Ip $ip -Port $port -Mine (Get-LocalEndpointFor -DestinationIp $ip -Port $port)
        if (-not $other) { Set-KnxTestSkip 'needs a second local address on the same network interface that reaches the device, to act as the foreign client' }

        $c = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $TUN -Layer $K.Layer.TUNNEL_LINKLAYER
        Assert-KnxTrue $c.Ok "could not open a tunnel ($($c.StatusName))"
        try {
            $mine = [string]$c.LocalIp

            # Ask the device something it answers, and do NOT acknowledge the answer: it stays armed.
            $tpdu = New-TpduPropertyValueRead -ObjectIndex 0 -PropertyId $K.Pid.SERIAL_NUMBER -ElementCount 1 -StartIndex 1
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination (ConvertTo-KnxPa -Address $target) -Tpdu $tpdu -Priority 0
            [void](Send-KnxTunnelCemi -Connection $c -Cemi $cemi -TimeoutMs 3000)
            $first = Receive-KnxTunnelCemi -Connection $c -TimeoutMs 4000 -NoAck
            if ($null -eq $first) { Set-KnxTestNotApplicable 'the device sent nothing that needs an acknowledge' }
            Add-KnxEvidence -Note "device frame sequence $($first.Sequence), left unacknowledged by this client"

            $sock = New-Object System.Net.Sockets.Socket([System.Net.Sockets.AddressFamily]::InterNetwork, [System.Net.Sockets.SocketType]::Dgram, [System.Net.Sockets.ProtocolType]::Udp)
            try {
                $sock.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($other), 0)))
                $ack = New-KnxTunnellingAck -Channel $c.Channel -Sequence $first.Sequence
                [void]$sock.SendTo($ack, (New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($ip), $port)))
                Add-KnxEvidence -Sent $ack -Note "acknowledge sent from $other for the channel of $mine"
            }
            finally { $sock.Close() }

            # A device that ignores the foreign acknowledge still has the frame armed and repeats it.
            $repeat = $null
            $end = [DateTime]::UtcNow.AddSeconds(4)
            while ([DateTime]::UtcNow -lt $end -and $null -eq $repeat) {
                $in = Receive-KnxTunnelCemi -Connection $c -TimeoutMs 500 -NoAck
                if ($null -ne $in -and $in.Sequence -eq $first.Sequence) { $repeat = $in }
            }
            Add-KnxEvidence -Note $(if ($null -ne $repeat) { 'the frame was repeated' } else { 'no repetition within 4 s' })
            Assert-KnxTrue ($null -ne $repeat) "the device took an acknowledge from $other for a channel opened by $mine"
        }
        finally { [void](Close-KnxConnection -Connection $c) }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.3.1' -Title 'Tunnel Addresses - Standard Case' -Clause 'TSSH 5.3.1, p.83 (fn 30110)' -Body {
        if (-not $Ctx.AllowDestructive) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'rewrites PID_ADDITIONAL_INDIVIDUAL_ADDRESSES - needs -IncludeDestructive with profile Full' }

        $mgmt = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
        Assert-KnxTrue $mgmt.Ok "could not open a device management connection ($($mgmt.StatusName))"
        $original = @()
        $restoreOk = $false
        $restoreNote = 'the management connection was already gone'
        try {
            $original = Get-AdditionalAddressesOrSkip -Connection $mgmt
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
            # The restore was fired and forgotten. If the management channel died during the case -
            # the server reaps a silent one after 120 s (03_08_02 5.4 p.14) - every write fails and the
            # device keeps the TEST address list. Recording that as a note only meant the row still read
            # PASS while the device was left with a rewritten tunnel pool - on a router that is its own
            # individual address in every slot. The result is asserted after this block.
            # Caught throughout: an exception out of a finally replaces the result the case reached.
            if ($original.Count -gt 0 -and $mgmt.Ok) {
                $written = $false
                try {
                    $rs = Set-AdditionalAddresses -Connection $mgmt -Addresses $original
                    $written = $rs.Ok
                    if (-not $rs.Ok) { $restoreNote = "the write was refused (error $($rs.ErrorCode))" }
                }
                catch { $restoreNote = "the write threw ($($_.Exception.Message))" }
                if ($written) {
                    # A write that was acknowledged is not yet a device that holds what was asked for.
                    try {
                        $rb = Get-AdditionalAddresses -Connection $mgmt
                        if (-not $rb.Complete) { $restoreNote = 'the write was accepted but could not be read back for confirmation' }
                        elseif ((@($rb.Addresses) -join ',') -ne (@($original) -join ',')) {
                            $restoreNote = "the device holds $(@($rb.Addresses) -join ', ') instead"
                        }
                        else { $restoreOk = $true }
                    }
                    catch { $restoreNote = "the write was accepted but could not be read back ($($_.Exception.Message))" }
                }
            }
            else { $restoreOk = $true }
            [void](Close-KnxConnection -Connection $mgmt)
        }
        # Outside the finally on purpose: an assertion thrown from inside it would replace whatever
        # result the case had reached. A case that already failed keeps its own reason; one that
        # would otherwise pass now fails when the device was left rewritten.
        Assert-KnxTrue $restoreOk "the address list was NOT restored to $($original -join ', ') - $restoreNote. The device is left holding the test list"
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.3.2' -Title 'Tunnel Addresses - Uniqueness' -Clause 'TSSH 5.3.2, p.84 (fn 30111)' -Body {
        if (-not $Ctx.AllowDestructive) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'rewrites PID_ADDITIONAL_INDIVIDUAL_ADDRESSES - needs -IncludeDestructive with profile Full' }

        $mgmt = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
        Assert-KnxTrue $mgmt.Ok "could not open a device management connection ($($mgmt.StatusName))"
        $original = @()
        $restoreOk = $false
        $restoreNote = 'the management connection was already gone'
        try {
            $original = Get-AdditionalAddressesOrSkip -Connection $mgmt
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
                # Without a single granted tunnel there is nothing to judge uniqueness on, and the
                # -le 1 below would pass on an empty list - a green row for an observation never made.
                Assert-KnxTrue ($given.Count -gt 0) 'the device granted no tunnel at all after the address list was written, so uniqueness could not be observed'
                $withTa = @($given | Where-Object { $_ -eq $ta })
                Assert-KnxTrue ($withTa.Count -le 1) "address $ta was handed out $($withTa.Count) times - a tunnel address must be unique"
            }
            finally { Close-AllTunnels -Connections $r.Open }
        }
        finally {
            # The restore was fired and forgotten. If the management channel died during the case -
            # the server reaps a silent one after 120 s (03_08_02 5.4 p.14) - every write fails and the
            # device keeps the TEST address list. Recording that as a note only meant the row still read
            # PASS while the device was left with a rewritten tunnel pool - on a router that is its own
            # individual address in every slot. The result is asserted after this block.
            # Caught throughout: an exception out of a finally replaces the result the case reached.
            if ($original.Count -gt 0 -and $mgmt.Ok) {
                $written = $false
                try {
                    $rs = Set-AdditionalAddresses -Connection $mgmt -Addresses $original
                    $written = $rs.Ok
                    if (-not $rs.Ok) { $restoreNote = "the write was refused (error $($rs.ErrorCode))" }
                }
                catch { $restoreNote = "the write threw ($($_.Exception.Message))" }
                if ($written) {
                    # A write that was acknowledged is not yet a device that holds what was asked for.
                    try {
                        $rb = Get-AdditionalAddresses -Connection $mgmt
                        if (-not $rb.Complete) { $restoreNote = 'the write was accepted but could not be read back for confirmation' }
                        elseif ((@($rb.Addresses) -join ',') -ne (@($original) -join ',')) {
                            $restoreNote = "the device holds $(@($rb.Addresses) -join ', ') instead"
                        }
                        else { $restoreOk = $true }
                    }
                    catch { $restoreNote = "the write was accepted but could not be read back ($($_.Exception.Message))" }
                }
            }
            else { $restoreOk = $true }
            [void](Close-KnxConnection -Connection $mgmt)
        }
        # Outside the finally on purpose: an assertion thrown from inside it would replace whatever
        # result the case had reached. A case that already failed keeps its own reason; one that
        # would otherwise pass now fails when the device was left rewritten.
        Assert-KnxTrue $restoreOk "the address list was NOT restored to $($original -join ', ') - $restoreNote. The device is left holding the test list"
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.3.3' -Title 'Tunnel Addresses - Assignment Method' -Clause 'TSSH 5.3.3, p.85 (fn 30112)' -Body {
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - opens and closes tunnels on a production device' }
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
            [void](Wait-KnxTunnel -Connection $b -Ms 700)

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

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-5.3.4' -Title 'Tunnel E_NO_MORE_CONNECTIONS' -Clause 'TSSH 5.3.4, p.85 (fn 30113)' -Body {
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - exhausting the tunnel pool locks out other clients' }
        # Read the pool BEFORE the tunnels are taken. It needs a device-management connection, and on a
        # device that draws management and tunnelling from one table that connection is refused once the
        # pool is exhausted - the case would then judge on an empty read of its own making.
        $poolRead = Get-KnxTunnelPool -Ip $ip -Port $port
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
            $pool = @($poolRead.Addresses)
            # An unassigned slot reads as 0.0.0. It is reported, because a pool that is half empty is
            # worth seeing - but two empty slots are not the "duplicate address" of 03_08_04 p.6, and
            # demanding 0x25 for them would invent a requirement. Only real addresses are counted.
            $assignable = @($pool | Where-Object { $_ -ne '0.0.0' })
            $empties = $pool.Count - $assignable.Count
            $poolUnique = @($assignable | Sort-Object -Unique)
            $poolHasDuplicate = ($assignable.Count -gt 0 -and $poolUnique.Count -lt $assignable.Count)
            if ($pool.Count -gt 0) {
                Add-KnxEvidence -Note "pool: $($pool.Count) entries, $($assignable.Count) with an address, $($poolUnique.Count) distinct$(if ($empties -gt 0) { ", $empties unassigned" }) - $($pool -join ', ')"
            }
            if ($poolHasDuplicate) {
                Assert-KnxStatus $K.Error.E_NO_MORE_UNIQUE_CONNECTIONS $r.RefusalStatus 'the pool contains duplicate addresses, so exhaustion must report E_NO_MORE_UNIQUE_CONNECTIONS'
            }
            elseif ($Ctx.BdutPa -and $assignable -contains [string]$Ctx.BdutPa) {
                # 03_08_03 2.5.4 p.9: an entry equal to the own IA is not unique while the device does not tunnel on it.
                Assert-KnxStatus $K.Error.E_NO_MORE_UNIQUE_CONNECTIONS $r.RefusalStatus "the pool contains the device's own address $($Ctx.BdutPa), so exhaustion must report E_NO_MORE_UNIQUE_CONNECTIONS"
            }
            elseif (-not $poolRead.Complete) {
                # The pool could not be read in FULL - not at all, or one answer lost mid-way. Either way
                # the harness does not know what the device holds, and demanding the strict code on a
                # partial read failed conformant devices. Both codes are accepted, and the report says why.
                Add-KnxEvidence -Note "the additional address pool could not be read completely ($($pool.Count) of $($poolRead.Held)), so the strict distinction between 0x24 and 0x25 is not judged here"
                Assert-KnxTrue (@($K.Error.E_NO_MORE_CONNECTIONS, $K.Error.E_NO_MORE_UNIQUE_CONNECTIONS) -contains $r.RefusalStatus) `
                    "refusal status $(Get-KnxErrorName -Status $r.RefusalStatus) is neither E_NO_MORE_CONNECTIONS nor E_NO_MORE_UNIQUE_CONNECTIONS"
            }
            elseif ($assignable.Count -eq $pool.Count -and $unique.Count -eq $given.Count) {
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
            @{ Id = 'H-5.3.5'; Title = 'Tunnel E_NO_MORE_UNIQUE_CONNECTIONS - Case 1'; Clause = 'TSSH 5.3.5, p.88 (fn 30114)'; UseOwn = $false },
            @{ Id = 'H-5.3.6'; Title = 'Tunnel E_NO_MORE_UNIQUE_CONNECTIONS - Case 2'; Clause = 'TSSH 5.3.6, p.90 (fn 30115)'; UseOwn = $true })) {
        $useOwn = $case.UseOwn
        Invoke-KnxTestCase -Suite $SuiteTitle -Id $case.Id -Title $case.Title -Clause $case.Clause -Body {
            if (-not $Ctx.AllowDestructive) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'rewrites PID_ADDITIONAL_INDIVIDUAL_ADDRESSES - needs -IncludeDestructive with profile Full' }

            $mgmt = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
            Assert-KnxTrue $mgmt.Ok "could not open a device management connection ($($mgmt.StatusName))"
            $original = @()
            $restoreOk = $false
            $restoreNote = 'the management connection was already gone'
            try {
                $original = Get-AdditionalAddressesOrSkip -Connection $mgmt
                Assert-KnxTrue ($original.Count -gt 0) 'device exposes no PID_ADDITIONAL_INDIVIDUAL_ADDRESSES to test with'
                $na = $original.Count

                # Case 1 fills the list with one arbitrary address; case 2 fills it with the
                # BDUT's own address. The expected code depends on NA and on whether the
                # device's own address may serve as a tunnel address at all.
                $ta = '1.1.111'
                if ($useOwn) {
                    if (-not $Ctx.BdutPa) { Set-KnxTestNotRun -MissingInput '-BdutPa' -Reason 'BDUT individual address unknown (-BdutPa)' }
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
                # The restore was fired and forgotten. If the management channel died during the case -
                # the server reaps a silent one after 120 s (03_08_02 5.4 p.14) - every write fails and the
                # device keeps the TEST address list. Recording that as a note only meant the row still read
                # PASS while the device was left with a rewritten tunnel pool - on a router that is its own
                # individual address in every slot. The result is asserted after this block.
                # Caught throughout: an exception out of a finally replaces the result the case reached.
                if ($original.Count -gt 0 -and $mgmt.Ok) {
                    $written = $false
                    try {
                        $rs = Set-AdditionalAddresses -Connection $mgmt -Addresses $original
                        $written = $rs.Ok
                        if (-not $rs.Ok) { $restoreNote = "the write was refused (error $($rs.ErrorCode))" }
                    }
                    catch { $restoreNote = "the write threw ($($_.Exception.Message))" }
                    if ($written) {
                        # A write that was acknowledged is not yet a device that holds what was asked for.
                        try {
                            $rb = Get-AdditionalAddresses -Connection $mgmt
                            if (-not $rb.Complete) { $restoreNote = 'the write was accepted but could not be read back for confirmation' }
                            elseif ((@($rb.Addresses) -join ',') -ne (@($original) -join ',')) {
                                $restoreNote = "the device holds $(@($rb.Addresses) -join ', ') instead"
                            }
                            else { $restoreOk = $true }
                        }
                        catch { $restoreNote = "the write was accepted but could not be read back ($($_.Exception.Message))" }
                    }
                }
                else { $restoreOk = $true }
                [void](Close-KnxConnection -Connection $mgmt)
            }
            # Outside the finally on purpose: an assertion thrown from inside it would replace whatever
            # result the case had reached. A case that already failed keeps its own reason; one that
            # would otherwise pass now fails when the device was left rewritten.
            Assert-KnxTrue $restoreOk "the address list was NOT restored to $($original -join ', ') - $restoreNote. The device is left holding the test list"
        }
    }

    # 08_TSSH 5.4.1 p.93 / 5.4.4 p.98 pin the CONNECT_RESPONSE for a route-back request and show its data
    # endpoint HPAI as 00000000h : 0000h - the server must not push an address at a client that told it,
    # by sending an all-zero HPAI, that it cannot use one (03_08_02 8.6.2.2 p.49; the same symmetry is
    # written out for TCP in 8.4.3.4.3 p.45). A half-zero HPAI is NOT a route-back request - 8.6.2.2
    # declares it invalid - so there the real address is correct and only its presence is checked.
    function Assert-KnxRouteBackHpai {
        param($Parsed, [bool]$RouteBack)
        if ($null -eq $Parsed -or $null -eq $Parsed.DataHpaiIp) { return }
        $got = "$($Parsed.DataHpaiIp):$($Parsed.DataHpaiPort)"
        Add-KnxEvidence -Note "CONNECT_RESPONSE data endpoint HPAI = $got"
        if ($RouteBack) {
            Assert-KnxTrue ($Parsed.DataHpaiIp -eq '0.0.0.0' -and $Parsed.DataHpaiPort -eq 0) `
                "route-back request answered with HPAI $got - it must be 0.0.0.0:0 (08_TSSH 5.4.1 p.93)"
        }
        # Nothing is asserted for a half-zero HPAI. There is no clause that says what to answer to one:
        # 8.6.2.2 p.49 declares it invalid, and 08_TSSH 5.4.2/5.4.3 shows an all-zero response for it
        # anyway. Measured 2026-09-06 on the certified MDT SCN-IP000.03: it answers those with port 0 too,
        # i.e. it treats them as route back. An assertion demanding the real address here failed the
        # reference device - which makes it a defect of the test, not of any device under test.
    }

    # ── 5.4 NAT Compatibility ───────────────────────────────────────────────────
    #
    # A NAT-compatible client sends 0.0.0.0:0 in its HPAI ("route back"): the server must
    # then answer to the UDP source endpoint it actually received the frame from. The
    # variants additionally set only the IP or only the port, which must not change that.

    $natCases = @(
        @{ Id = 'H-5.4.1'; Title = 'NAT compatible tunnelling to KNX - Standard Case'; Clause = 'TSSH 5.4.1, p.91 (fn 30301)'; SetIp = $false; SetPort = $false },
        @{ Id = 'H-5.4.2'; Title = 'NAT compatible tunnelling to KNX - IP address set'; Clause = 'TSSH 5.4.2, p.95 (fn 30302)'; SetIp = $true;  SetPort = $false },
        @{ Id = 'H-5.4.3'; Title = 'NAT compatible tunnelling to KNX - port number set'; Clause = 'TSSH 5.4.3, p.96 (fn 30303)'; SetIp = $false; SetPort = $true }
    )
    foreach ($case in $natCases) {
        $setIp = $case.SetIp; $setPort = $case.SetPort
        Invoke-KnxTestCase -Suite $SuiteTitle -Id $case.Id -Title $case.Title -Clause $case.Clause -Body {
            if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case writes a group telegram to the bus' }
            $hIp = '0.0.0.0'
            if ($setIp) { $hIp = Get-LocalEndpointFor -DestinationIp $ip -Port $port }
            $c = Open-TunnelRaw -Ip $ip -Port $port -HpaiIp $hIp -HpaiPort 0 -UseRealPort:$setPort -Layer $K.Layer.TUNNEL_LINKLAYER
            Add-KnxEvidence -Sent $c.Request
            if ($null -ne $c.Response) { Add-KnxEvidence -Received $c.Response }
            Assert-KnxTrue $c.Ok "device refused a NAT-compatible connect request ($($c.StatusName)) - it must answer to the UDP source endpoint"
            Assert-KnxRouteBackHpai -Parsed $c.Parsed -RouteBack (-not $setIp -and -not $setPort)
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
        @{ Id = 'H-5.4.4'; Title = 'NAT compatible tunnelling from KNX - Standard Case'; Clause = 'TSSH 5.4.4, p.98 (fn 30304)'; SetIp = $false; SetPort = $false },
        @{ Id = 'H-5.4.5'; Title = 'NAT compatible tunnelling from KNX - IP address set'; Clause = 'TSSH 5.4.5, p.99 (fn 30305)'; SetIp = $true;  SetPort = $false },
        @{ Id = 'H-5.4.6'; Title = 'NAT compatible tunnelling from KNX - port number set'; Clause = 'TSSH 5.4.6, p.100 (fn 30306)'; SetIp = $false; SetPort = $true }
    )
    foreach ($case in $natFrom) {
        $setIp = $case.SetIp; $setPort = $case.SetPort
        Invoke-KnxTestCase -Suite $SuiteTitle -Id $case.Id -Title $case.Title -Clause $case.Clause -Body {
            if (-not $Ctx.TrafficIp) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason 'needs a second interface (-TrafficIp) to put a telegram on the bus' }
            if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case writes to the bus' }

            $hIp = '0.0.0.0'
            if ($setIp) { $hIp = Get-LocalEndpointFor -DestinationIp $ip -Port $port }
            $c = Open-TunnelRaw -Ip $ip -Port $port -HpaiIp $hIp -HpaiPort 0 -UseRealPort:$setPort -Layer $K.Layer.TUNNEL_LINKLAYER
            Add-KnxEvidence -Sent $c.Request
            Assert-KnxTrue $c.Ok "device refused a NAT-compatible connect request ($($c.StatusName))"
            Assert-KnxRouteBackHpai -Parsed $c.Parsed -RouteBack (-not $setIp -and -not $setPort)

            $src = Get-KnxTrafficConnection -Ip $Ctx.TrafficIp -Port $port
            try {
                Assert-KnxTrue ($null -ne $src) 'no tunnel available on the traffic interface'
                $ga = ConvertTo-KnxGa -Address '0/0/14'
                $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $ga -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)
                [void](Send-KnxTunnelCemi -Connection $src -Cemi $cemi -TimeoutMs 3000)

                # Receive on the DEVICE tunnel FIRST. The device starts sending the indication immediately
                # and expects a TUNNELLING_ACK: waiting on the traffic tunnel first would leave it unacked,
                # the device repeats it after 1 s and then disconnects (03_08_04 2.6.1 p.9) - and the case
                # would report "never arrived" for a device that in fact sent it twice.
                $seen = $null
                $deadline = [DateTime]::UtcNow.AddSeconds(6)
                while ([DateTime]::UtcNow -lt $deadline) {
                    $in = Receive-KnxTunnelCemi -Connection $c -TimeoutMs 1500
                    if ($null -eq $in) { continue }
                    $ld = Read-CemiLData -Cemi $in.Cemi
                    if ($null -eq $ld) { continue }
                    if ($ld.MessageCode -eq $K.Cemi.L_DATA_IND -and $ld.Destination -eq $ga) { $seen = $in; break }
                }

                # Only if nothing arrived: did the telegram reach the BUS at all? The TUNNELLING_ACK of the
                # traffic interface only says it accepted the request, the L_Data.con says it transmitted.
                # Asking now - and not before - keeps a rig that did not send from being charged to the
                # device under test, without disturbing the measurement itself.
                if ($null -eq $seen) {
                    $onBus = $false
                    $conDeadline = [DateTime]::UtcNow.AddSeconds(3)
                    while ([DateTime]::UtcNow -lt $conDeadline -and -not $onBus) {
                        $cf = Receive-KnxTunnelCemi -Connection $src -TimeoutMs 1000
                        if ($null -eq $cf) { continue }
                        $cl = Read-CemiLData -Cemi $cf.Cemi
                        if ($null -ne $cl -and $cl.MessageCode -eq $K.Cemi.L_DATA_CON -and $cl.Destination -eq $ga) { $onBus = $true }
                    }
                    Add-KnxEvidence -Note "traffic interface confirmed the telegram on the bus: $onBus"
                    Assert-KnxTrue $onBus 'the traffic interface never confirmed the telegram on the bus (L_Data.con) - this is a rig fault, not a result about the device under test'
                }

                Assert-KnxTrue ($null -ne $seen) 'the bus telegram never arrived on the NAT-compatible tunnel - the device is not answering to the UDP source endpoint'
                Add-KnxEvidence -Received $seen.Cemi
            }
            finally {
                [void](Close-KnxConnection -Connection $c)
            }
        }
    }

    # ── Protocol version change on an established connection (03_08_02 6.2) ────────────────────

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'P-6.2.1' -Title 'A protocol version change on an open channel shuts it down' `
                       -Clause '03_08_02 6.2 p.15: "If a connection is established and the protocol version changes within the received data packets, the server shall shut down the connection."' -Body {
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case ends a connection on purpose' }

        $c = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $TUN -Layer $K.Layer.TUNNEL_LINKLAYER
        Assert-KnxTrue $c.Ok "could not open a tunnel ($($c.StatusName))"
        try {
            # A well-formed tunnelling request whose only fault is the version octet in the header.
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination (ConvertTo-KnxGa -Address '0/0/1') -IsGroup -Tpdu (New-TpduGroupValueRead)
            $frame = New-KnxTunnellingRequest -Channel $c.Channel -Sequence $c.SeqSend -Cemi $cemi
            $frame[1] = 0x11   # KNXnet/IP version 1.1 -- not the 1.0 this server speaks
            Send-KnxFrame -Socket $c.Socket -Frame $frame -Ip $ip -Port $port
            Add-KnxEvidence -Sent $frame -Note 'tunnelling request with protocol version 0x11 from the endpoint that owns the channel'

            $r = Wait-KnxDisconnectWhileAcking -Connection $c -TimeoutMs 4000
            Assert-KnxTrue ($null -ne $r) 'the connection stayed open after the protocol version changed'
            # A teardown the heartbeat answered carries no datagram, so the evidence is conditional.
            if ($null -ne $r.Disconnect) { Add-KnxEvidence -Received $r.Disconnect.Packet.Bytes -Note 'device disconnected the channel' }
            else { Add-KnxEvidence -Note 'device disconnected the channel' }
        }
        finally { Close-KnxConnection -Connection $c | Out-Null }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'P-6.2.2' -Title 'The same datagram from another endpoint does not end the connection' `
                       -Clause '03_08_02 6.2 p.15 with 5.5 p.14: the connection belongs to the endpoint that opened it' -Body {
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case sends an unsolicited datagram' }
        $other = Get-KnxForeignEndpoint -Ip $ip -Port $port -Mine (Get-LocalEndpointFor -DestinationIp $ip -Port $port)
        if (-not $other) { Set-KnxTestSkip 'needs a second local address on the same network interface that reaches the device, to act as the foreign client' }

        $c = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $TUN -Layer $K.Layer.TUNNEL_LINKLAYER
        Assert-KnxTrue $c.Ok "could not open a tunnel ($($c.StatusName))"
        try {
            $mine = [string]$c.LocalIp

            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination (ConvertTo-KnxGa -Address '0/0/1') -IsGroup -Tpdu (New-TpduGroupValueRead)
            $frame = New-KnxTunnellingRequest -Channel $c.Channel -Sequence 0 -Cemi $cemi
            $frame[1] = 0x11

            $sock = New-Object System.Net.Sockets.Socket([System.Net.Sockets.AddressFamily]::InterNetwork, [System.Net.Sockets.SocketType]::Dgram, [System.Net.Sockets.ProtocolType]::Udp)
            try {
                $sock.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($other), 0)))
                [void]$sock.SendTo($frame, (New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($ip), $port)))
                Add-KnxEvidence -Sent $frame -Note "sent from $other for the channel opened by $mine"
            }
            finally { $sock.Dispose() }

            $r = Wait-KnxDisconnectWhileAcking -Connection $c -TimeoutMs 2500
            Assert-KnxTrue ($null -eq $r) 'a foreign datagram ended the connection - eight forged octets would end any running session'

            # The channel must still carry traffic, not merely have survived the datagram.
            $csr = New-KnxConnectionStateRequest -Channel $c.Channel -ControlIp $c.LocalIp -ControlPort $c.LocalPort
            Send-KnxFrame -Socket $c.Socket -Frame $csr -Ip $ip -Port $port
            $alive = Wait-KnxService -Socket $c.Socket -Service @($K.Service.CONNECTIONSTATE_RESPONSE) -TimeoutMs 3000
            Assert-KnxTrue (-not $alive.TimedOut) 'the connection no longer answers a connection-state request'
            Assert-KnxTrue ($alive.Header.Body[1] -eq 0) ('connection state status 0x{0:X2}' -f $alive.Header.Body[1])
            Add-KnxEvidence -Note 'channel still alive after the foreign version-change datagram'
        }
        finally { Close-KnxConnection -Connection $c | Out-Null }
    }

    # A control request for an open channel from a second local address; only the owner's side is judged. The foreign
    # answer is recorded: 03_08_02 7.8.4 p.40 answers the request HPAI, but Table 9 p.40 has no status for a foreign sender.
    $foreignKinds = @(
        @{ Name = 'device management'; Type = $K.ConnType.DEVICE_MGMT_CONNECTION; Layer = -1 },
        @{ Name = 'link-layer tunnel'; Type = $TUN; Layer = $K.Layer.TUNNEL_LINKLAYER },
        @{ Name = 'busmonitor tunnel'; Type = $TUN; Layer = 0x80 })
    $foreignAddress = {
        $other = Get-KnxForeignEndpoint -Ip $ip -Port $port -Mine (Get-LocalEndpointFor -DestinationIp $ip -Port $port)
        if (-not $other) { Set-KnxTestSkip 'needs a second local address on the same network interface that reaches the device, to act as the foreign client' }
        [string]$other
    }
    $foreignControl = {
        param($Conn, [int]$Service, [string]$Other, [string]$Kind)
        $sock = New-Object System.Net.Sockets.Socket([System.Net.Sockets.AddressFamily]::InterNetwork, [System.Net.Sockets.SocketType]::Dgram, [System.Net.Sockets.ProtocolType]::Udp)
        try {
            $sock.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($Other), 0)))
            $lp = $sock.LocalEndPoint.Port
            $f = if ($Service -eq $K.Service.DISCONNECT_REQUEST) { New-KnxDisconnectRequest -Channel $Conn.Channel -ControlIp $Other -ControlPort $lp }
                 else { New-KnxConnectionStateRequest -Channel $Conn.Channel -ControlIp $Other -ControlPort $lp }
            [void]$sock.SendTo($f, (New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($ip), $port)))
            Add-KnxEvidence -Sent $f -Note ("{0}: sent from {1}:{2} for channel {3} opened by {4}" -f $Kind, $Other, $lp, $Conn.Channel, $Conn.LocalIp)
            $back = Receive-KnxFrame -Socket $sock -TimeoutMs 1500
            if ($null -eq $back) { Add-KnxEvidence -Note "${Kind}: no answer to the foreign endpoint" }
            else {
                $h = Read-KnxHeader -Frame $back.Bytes
                $st = if ($null -ne $h -and $h.Body.Length -ge 2) { Get-KnxErrorName -Status $h.Body[1] } else { 'malformed' }
                Add-KnxEvidence -Received $back.Bytes -Note "${Kind}: answer to the foreign endpoint $st"
            }
        }
        finally { $sock.Dispose() }
    }
    $ownerAlive = {
        param($Conn, [string]$What, [string]$Kind)
        $gone = Wait-KnxDisconnectWhileAcking -Connection $Conn -TimeoutMs 2500
        Assert-KnxTrue ($null -eq $gone) "${Kind}: a $What from a foreign endpoint ended the owner's connection"
        $csr = New-KnxConnectionStateRequest -Channel $Conn.Channel -ControlIp $Conn.LocalIp -ControlPort $Conn.LocalPort
        $alive = Invoke-KnxRequest -Socket $Conn.Socket -Frame $csr -Ip $ip -Port $port -Expect @($K.Service.CONNECTIONSTATE_RESPONSE) -TimeoutMs 3000
        Assert-KnxTrue (-not $alive.TimedOut) "${Kind}: after the foreign $What the connection no longer answers its owner's connection-state request"
        Assert-KnxTrue ($alive.Header.Body.Length -ge 2) "${Kind}: after the foreign $What the CONNECTIONSTATE_RESPONSE body is $($alive.Header.Body.Length) octets"
        Assert-KnxEqual $Conn.Channel $alive.Header.Body[0] "${Kind}: the CONNECTIONSTATE_RESPONSE names a different channel"
        Assert-KnxStatus $K.Error.E_NO_ERROR $alive.Header.Body[1] "${Kind}: after the foreign $What the owner's connection state is not normal"
    }

    # Product rule, not a clause: 03_08_02 5.5 and 5.4 p.14 describe the requests of the communication partner
    # and say nothing about other senders. Without the source check a foreign DISCONNECT would end a busmonitor tunnel.
    foreach ($fc in @(
            @{ Id = 'P-6.2.3'; Service = $K.Service.DISCONNECT_REQUEST; What = 'DISCONNECT_REQUEST'
               Title = 'A DISCONNECT_REQUEST from another endpoint does not end the connection'
               Clause = 'product rule; 03_08_02 5.5 p.14 names the communication partner as sender' },
            @{ Id = 'P-6.2.4'; Service = $K.Service.CONNECTIONSTATE_REQUEST; What = 'CONNECTIONSTATE_REQUEST'
               Title = 'A CONNECTIONSTATE_REQUEST from another endpoint does not end the connection'
               Clause = 'product rule; 03_08_02 5.4 p.14 names the client as sender' })) {
        $foreignCase = $fc
        Invoke-KnxTestCase -Suite $SuiteTitle -Id $foreignCase.Id -Title $foreignCase.Title -Clause $foreignCase.Clause -Body {
            if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case sends control requests for a channel it does not own' }
            $other = & $foreignAddress
            $judged = 0
            # Busmonitor last: while it is open the device refuses every further connection.
            foreach ($kind in $foreignKinds) {
                $c = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $kind.Type -Layer $kind.Layer
                try {
                    if (-not $c.Ok) {
                        Assert-KnxTrue ($kind.Layer -ne $K.Layer.TUNNEL_LINKLAYER) "could not open a link-layer tunnel ($($c.StatusName))"
                        # A non-router may offer the busmonitor; any refusal but "layer not supported" leaves that kind unjudged.
                        if ($kind.Layer -eq 0x80 -and -not $Ctx.IsRouter -and
                            @($K.Error.E_CONNECTION_OPTION, $K.Error.E_TUNNELING_LAYER) -notcontains $c.Status) {
                            Set-KnxTestSkip "busmonitor tunnel refused with $($c.StatusName) - occupied or unanswered, so that kind cannot be judged"
                        }
                        Add-KnxEvidence -Note "$($kind.Name) not opened ($($c.StatusName)), not judged"
                        continue
                    }
                    & $foreignControl $c ([int]$foreignCase.Service) $other $kind.Name
                    & $ownerAlive $c $foreignCase.What $kind.Name
                    Add-KnxEvidence -Note "$($kind.Name): owner's connection kept and answering"
                    $judged++
                }
                finally { if ($c.Ok) { [void](Close-KnxConnection -Connection $c) } }
            }
            Add-KnxEvidence -Note "$judged connection kind(s) judged"
        }
    }

    # -- Connection-oriented session through the device's own tunnel to its own address --
    # A local answer puts con, T_ACK and answer on the tunnel at once; neither that nor a client's T_ACK arriving with its next request may end the tunnel (validation tool 80131). A_DeviceDescriptor_Read is the probe: every family answers it.

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'P-5.LOC.1' -Title 'Two numbered requests in a T_Connect session through the device''s own tunnel to its own address' `
                       -Clause '03_03_04 5.3 p.19 (T_ACK per numbered request); 03_08_04 2.6.1 p.9 (names a missing or negative TUNNELLING_ACK as the trigger to end the tunnel); validation tool 80131' -Body {
        $d = Get-KnxDescription -Ip $ip -Port $port
        $pa = if ($null -ne $d -and $null -ne $d.Device) { $d.Device.IndividualAddr } elseif ($Ctx.BdutPa) { $Ctx.BdutPa } else { $null }
        if (-not $pa) { Set-KnxTestNotRun -MissingInput '-BdutPa' -Reason 'no description and no -BdutPa - the device address is unknown' }
        $hex = { param($b) if ($null -eq $b) { '<none>' } else { ($b | ForEach-Object { '{0:X2}' -f $_ }) -join ' ' } }
        $gone = { param($c) "the tunnel was closed (by: $(Get-KnxTunnelGoneBy -Connection $c))" }

        # 1: the library client acknowledges each answer at once and sends the next request after a pause.
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $pa -Connect
        if (-not $s.Ok) { Set-KnxTestSkip "no connection-oriented session through the device's own tunnel: $($s.Reason)" }
        try {
            foreach ($i in 1..2) {
                $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@()) -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 3000
                Add-KnxEvidence -Note ("request ${i}: sent {0}; T_ACK seq {1}; answer {2}" -f (& $hex $r.SentTpdu), $r.AckSequence, (& $hex $r.Response))
                # T_Connect answered with T_Disconnect: another client holds the device's transport connection.
                if ($i -eq 1 -and $r.Disconnected -and -not $r.Acked) { Set-KnxTestSkip 'the device ended the transport connection at once - another client holds it (ETS, a tool, a session still in its 6 s timeout)' }
                Assert-KnxTrue (-not (Test-KnxTunnelGone -Connection $s.Conn)) "request ${i}: $(& $gone $s.Conn)"
                Assert-KnxTrue ($r.Acked -and $r.AckSequence -eq $i - 1) "numbered request $i (sequence $($i - 1)) got no T_ACK with its sequence (seen: $($r.AckSequence))"
                # A numbered answer (TPCI 01xxxxxx) with the device's sending sequence; a connectionless answer does not count.
                $seqAns = if ($null -ne $r.Response -and $r.Response.Length -ge 1 -and ($r.Response[0] -band 0xC0) -eq 0x40) { ($r.Response[0] -shr 2) -band 0x0F } else { -1 }
                Assert-KnxTrue ($seqAns -eq $i - 1) "numbered request $i got no answer with the device's sequence $($i - 1) (seen: $(& $hex $r.Response))"
            }
        }
        finally { Close-KnxDeviceSession -Session $s }

        # 2: the T_ACK for the first answer waits 500 ms, then it and the second request leave back to back.
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $pa -Connect
        if (-not $s.Ok) { Set-KnxTestSkip "no second session: $($s.Reason)" }
        $req = { param([byte[]]$Tpdu) New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $s.Dst -Tpdu $Tpdu -Priority 0 }
        $take = {
            param([int]$Ms)
            $got = @(); $end = [DateTime]::UtcNow.AddMilliseconds($Ms)
            while ([DateTime]::UtcNow -lt $end) {
                $in = Receive-KnxTunnelCemi -Connection $s.Conn -TimeoutMs 100
                if ($null -eq $in) { continue }
                $ld = Read-CemiLData -Cemi $in.Cemi
                if ($null -ne $ld) { $got += [pscustomobject]@{ Mc = [int]$in.Cemi[0]; Tpdu = $ld.Tpdu } }
            }
            , $got
        }
        # Indications from the device (cEMI 29h) whose TPDU starts with these octets.
        $has = { param($List, [byte[]]$Head) @($List | Where-Object { $_.Mc -eq 0x29 -and $_.Tpdu.Length -ge $Head.Length -and (@(Compare-Object ([byte[]]$_.Tpdu[0..($Head.Length - 1)]) $Head -SyncWindow 0).Count -eq 0) }).Count -gt 0 }
        $order = { param($l) (@($l | ForEach-Object { '{0:X2}:{1}' -f $_.Mc, (& $hex $_.Tpdu) })) -join ' | ' }
        try {
            [void](& $take 200)
            $r1 = Send-KnxTunnelCemi -Connection $s.Conn -Cemi (& $req ([byte[]]@(0x43, 0x00))) -TimeoutMs 1000   # seq 0, A_DeviceDescriptor_Read
            $f1 = & $take 500
            Add-KnxEvidence -Note ("back to back, after request 1: {0}" -f (& $order $f1))
            Assert-KnxTrue (-not (Test-KnxTunnelGone -Connection $s.Conn)) "at request 1 of the second session, $(& $gone $s.Conn)"
            Assert-KnxTrue ($r1.Acked) 'request 1 of the second session was not acknowledged on the tunnel'
            Assert-KnxTrue (& $has $f1 ([byte[]]@(0xC2))) 'request 1 (sequence 0) of the second session got no T_ACK'
            Assert-KnxTrue (& $has $f1 ([byte[]]@(0x43, 0x40))) 'request 1 (sequence 0) of the second session got no answer'
            [void](Send-KnxTunnelCemi -Connection $s.Conn -Cemi (& $req ([byte[]]@(0xC2))) -TimeoutMs 1000)
            [void](Send-KnxTunnelCemi -Connection $s.Conn -Cemi (& $req ([byte[]]@(0x47, 0x00))) -TimeoutMs 1000)
            $f2 = & $take 800
            Add-KnxEvidence -Note ("back to back, after T_ACK + request 2: {0} (the order of confirmation and answer is recorded, not judged)" -f (& $order $f2))
            $ans2 = & $has $f2 ([byte[]]@(0x47, 0x40))
            if ($ans2) { [void](Send-KnxTunnelCemi -Connection $s.Conn -Cemi (& $req ([byte[]]@(0xC6))) -TimeoutMs 1000) }
            Assert-KnxTrue (-not (Test-KnxTunnelGone -Connection $s.Conn)) "after a T_ACK and the next request arrived back to back, $(& $gone $s.Conn)"
            Assert-KnxTrue (& $has $f2 ([byte[]]@(0xC6))) 'request 2 (sequence 1) sent right after the T_ACK got no T_ACK'
            Assert-KnxTrue $ans2 'request 2 (sequence 1) sent right after the T_ACK got no answer'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }
}
