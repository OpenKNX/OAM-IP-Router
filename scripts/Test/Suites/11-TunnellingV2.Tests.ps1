#!/usr/bin/env pwsh
# Open ■
# ┬────┴  11-TunnellingV2.Tests
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/Suites/11-TunnellingV2.Tests.ps1

<#
.SYNOPSIS
    KNXnet/IP Tunnelling v2 and Core v2 - Interface Features, Extended CRI, SEARCH_REQUEST_EXTENDED.

.DESCRIPTION
    Dot-sourced by Invoke-Conformance.ps1, which then calls Invoke-KnxSuiteTunnellingV2.

    Section 11 is ours, not a TSSH chapter. TSSH v1.3 predates Tunnelling v2 entirely: it names
    neither TUNNELLING_FEATURE_GET nor the Extended CRI nor SEARCH_REQUEST_EXTENDED. The cases
    therefore assert against the normative clauses directly.

    WHERE THE MANDATORY/OPTIONAL DECISION COMES FROM
    NOT from 03_08_04 clause 7.2 "Support matrix" - that table lists only TUNNELLING_REQUEST and
    TUNNELLING_ACK and does not mention the four Feature services at all, so reading it would make
    every case here optional. The binding matrix is 06 Profiles 5.8.3.3.4 p.68 and 5.8.3.3.4.2 p.69:

      5.8.3.3.4   for KNXnet/IP Tunnelling v2:  Extended CRI = M, Tunnelling Feature services = M,
                  Interface Features = M, Tunnelling Service Family version 02h = M
      5.8.3.3.4.2 per feature, G = GET shall work, S = SET shall work, I = INFO shall be sent,
                  and a service in brackets is optional. "A service that is not listed shall not
                  make the Interface Feature available!"

        01 Supported EMI type                 (G)        -> GET optional
        02 Host Device Device Descriptor Type 0 G         -> GET mandatory
        03 Bus connection status               G/I        -> GET and INFO mandatory
        04 KNX Manufacturer Code               G          -> GET mandatory
        05 Active EMI type                    (G)         -> GET optional
        06 Individual Address                  G/S/I      -> GET, SET and INFO mandatory
        07 Max. APDU Length                    G          -> GET mandatory
        08 Interface Feature Info service Enable G/S      -> GET and SET mandatory

    The per-feature availability tables in 03_08_04 3.6.2 to 3.6.9 only ADJUST this (they name the
    Return Code a refused service must give, and what changes when Security Mode is enabled).

    A DEVICE WITHOUT THE FUNCTION IS N-A, NOT A WALL OF RED
    03_08_02 7.5.4.3 p.26 carries a version per service family, and 06 Profiles 5.8.3.3.4 binds
    every v2 feature to Tunnelling family version 02h. The suite reads that version ONCE, from the
    DESCRIPTION_RESPONSE (a Core v1 service, so it works on any device), and a v1 server gets one
    reason on every case instead of thirty timeouts. The Core v2 cases are gated separately on the
    Core family version, because SEARCH_REQUEST_EXTENDED belongs to Core, not to Tunnelling.

    THE CLIENT HAS TO ACKNOWLEDGE, OR THE TEST MEASURES ITS OWN MISTAKE
    03_08_04 3.1 p.11: "Tunnelling Feature services shall be confirmed by the receiver identically
    as the TUNNELLING_REQUEST service." That cuts both ways - the server confirms our GET, and we
    must confirm its RESPONSE and its INFO. Measured on the certified reference device: a probe that
    left the first TUNNELLING_FEATURE_RESPONSE unacknowledged got it repeated once, and from then on
    every further GET was acknowledged but never answered - the server's send window stayed blocked
    behind the unconfirmed frame. Eight features read as "one implemented, seven missing". The same
    applies to the L_Data.ind traffic of a live bus, which arrives on the same channel in between.
    Invoke-V2FeatureService therefore acknowledges everything addressed to our channel while it
    waits, and parks the bus frames on the connection the way the library's own readers do.

    SILENCE IS NEVER A RESULT
    Four clauses here demand that the server stays quiet: an unknown SRP with the M bit set
    (03_08_02 7.6.3.3.1 p.34), a Feature service on an unknown channel id (03_08_04 3.5 p.12), a
    Select By Service SRP the device cannot satisfy, a Select By MAC SRP for someone else. A case
    that only checks "nothing came back" passes against an unplugged device, and that false green
    was reproduced in section 9 before. Every negative case here therefore carries its positive
    control INSIDE the case and AFTER the negative: the identical stimulus with the one bit changed
    that should make the server answer, on the same socket, or a GET on the real channel that must
    still be served.

    VERIFIED AGAINST A CERTIFIED REFERENCE DEVICE
    Every frame this file builds and every status it expects was first exercised read-only against
    an MDT SCN-IP000.03 (Core v2, Device Management v2, Tunnelling v2, Secure disabled) before the
    case was written. The observed answers are quoted in the comment of each case. A case that is
    green there and red on an OpenKNX product describes a gap in the product.

    WHAT THIS FILE DELIBERATELY DOES NOT TEST, AND WHY
    - E_AUTHORISATION_ERROR (28h) is unreachable without KNX IP Secure. 03_08_04 5.4.3.3.2 step 7
      p.29 puts it behind "Tunnelling is a secured service family AND the Client is not authorised",
      and the same clause states that outside a Secure Session "Client authorised to use IArequest"
      is always "no" while the secured-service question decides the row. V-5.4.3.3.2-7 derives that
      from the device's own Secured Service Families DIB instead of assuming it.
    - E_ACCESS_DENIED (FCh) has no reachable trigger either; V-3.5c shows the derivation.
    - A spontaneous Feature 03 INFO needs the KNX line physically interrupted. V-3.6.4i asks for
      that step by name and reports NOT-RUN without it rather than reading 'Active' and calling it
      a pass. 06 Profiles 5.8.3.3.4.2 footnote a allows skipping it on a TP1-powered device.
    - Tunnelling over TCP: the Feature services exist there too, without TUNNELLING_ACK
      (03_08_04 3.1 NOTE 1 p.11). Section 9 owns the TCP transport; adding a second TCP session
      here would fight it for the connection pool.

    FRAME BUILDERS LIVE HERE, AND THAT IS ON PURPOSE FOR NOW
    KnxTest.psm1 has no builder for 0422h/0423h/0424h/0425h and no SEARCH_REQUEST_EXTENDED, and the
    library is not this file's to change. The six builders below are the minimum, they are named so
    they cannot collide, and they belong in the library the moment its owner adds them.
#>

Set-StrictMode -Version Latest

# ── CONNECT_RESPONSE status codes this suite asserts ──────────────────────────────────────
#
# Kept local so this section cannot be broken by an edit to the shared library, and because a bare
# 0x2E in an assertion says nothing to a reader.
#
# 28h, 2Dh and 2Eh are from Table 8 and match KnxTest.psm1 value for value; 29h is 03_08_04 Table 11 p.26, 23h
# Table 8 (version 1). The library spells 29h E_TUNNELING_LAYER with one L, the specification with two; grep for both.
$script:V2_E_AUTHORISATION_ERROR   = 0x28
$script:V2_E_NO_TUNNELLING_ADDRESS = 0x2D
$script:V2_E_CONNECTION_IN_USE     = 0x2E
$script:V2_E_TUNNELLING_LAYER      = 0x29
$script:V2_E_CONNECTION_OPTION     = 0x23

# 03_08_04 2.6.1 p.9 names TUNNELLING_REQUEST_TIMEOUT as one second and makes the sender repeat the
# frame once with the same sequence counter before terminating the connection; 3.1 p.11 binds the
# Feature services to that same handling and 3.2 p.11 gives the server three seconds AFTER the
# confirmation for the response. A conform server may therefore take 1000 + 3000 ms, so a receive
# window of exactly 4000 ms has no margin left for the rig's own latency and would time out on a
# device that is still inside its allowance.
$script:V2_ACK_TIMEOUT_MS      = 1000
$script:V2_RESPONSE_ALLOWANCE_MS = 3000

# cEMI Return Codes, 03_03_07 3.4.5.5 p.77 and p.78. These are the codes a
# TUNNELLING_FEATURE_RESPONSE carries in its Return Code octet.
$script:V2_RC_SUCCESS            = 0x00
$script:V2_RC_DATA_MIN           = 0xF6
$script:V2_RC_DATA_MAX           = 0xF7
$script:V2_RC_DATA_VOID          = 0xF8
$script:V2_RC_ACCESS_READ_ONLY   = 0xFB
$script:V2_RC_ACCESS_DENIED      = 0xFC
$script:V2_RC_ADDRESS_VOID       = 0xFD
$script:V2_RC_DATA_TYPE_CONFLICT = 0xFE

# SRP type codes, 03_08_02 Table 6 p.34. 00h is the "Invalid" code the clause reserves for
# testing unknown-SRP behaviour; 05h to 7Fh are reserved and must behave the same way.
$script:V2_SRP_INVALID  = 0x00
$script:V2_SRP_PROGMODE = 0x01
$script:V2_SRP_MAC      = 0x02
$script:V2_SRP_SERVICE  = 0x03
$script:V2_SRP_DIBS     = 0x04
$script:V2_SRP_M_BIT    = 0x80

# ── suite state, at script scope ────────────────────────────────────────────────────────
# Deliberately NOT locals of Invoke-KnxSuiteTunnellingV2: a case body is a scriptblock, and the
# only scope a body can read reliably is the script scope of the dot-sourcing runner. Writing the
# bodies as closures over suite locals is the failure this file was warned about - GetNewClosure
# rebinds the scriptblock into a fresh dynamic module, where the script-scope helpers below are
# not visible at all, and every case then fails with the same unrelated message.
$script:V2Ip       = ''
$script:V2Port     = 3671
$script:V2CoreVer  = -1
$script:V2TunVer   = -1
$script:V2TunNa    = ''
$script:V2CoreNa   = ''
$script:V2Conn     = $null
$script:V2ConnNa   = ''
$script:V2Desc     = $null
$script:V2HostIa   = -1
$script:V2Mac      = $null
$script:V2ProgMode = $false
$script:V2Slots    = @()
$script:V2SrxDibs  = @()
$script:V2SrxOk    = $false
$script:V2Cur      = $null

# ── frame builders ──────────────────────────────────────────────────────────────────────

function New-V2FeatureFrame {
    <#
    .SYNOPSIS
        Builds a TUNNELLING_FEATURE_GET / _SET / _RESPONSE / _INFO frame.
    .DESCRIPTION
        03_08_04 Figures 11, 12, 13 and 14 p.32/33: connection header (structure length 04h,
        channel, sequence counter, reserved) followed by the Feature service block. GET carries the
        Feature Identifier and one reserved octet, SET and INFO add the Feature Value, RESPONSE puts
        the Return Code where GET and SET have the reserved octet.

        The second octet of the Feature service block is passed explicitly so a case can prove the
        reserved octet is ignored, and so this one builder covers the RESPONSE shape too.
    #>
    param(
        [Parameter(Mandatory)][int]$Service,
        [Parameter(Mandatory)][int]$Channel,
        [Parameter(Mandatory)][int]$Sequence,
        [Parameter(Mandatory)][int]$Feature,
        [byte[]]$Value = @(),
        [int]$Second = 0x00
    )
    $body = [byte[]]@(0x04, ($Channel -band 0xFF), ($Sequence -band 0xFF), 0x00,
                      ($Feature -band 0xFF), ($Second -band 0xFF)) + $Value
    return , (New-KnxFrame -Service $Service -Body $body)
}

function New-V2ExtendedCri {
    <#
    .SYNOPSIS
        Builds the Extended Connection Request Information block.
    .DESCRIPTION
        03_08_04 5.4.3.2 Figure 5 p.26: structure length 06h, TUNNEL_CONNECTION 04h, KNX layer,
        one reserved octet, then the two-octet Individual Address the Client requests for this
        connection. The basic CRI of 5.4.3.1 is four octets and the library already builds it.

        NOTE 19 of the same clause: there is no "don't care" encoding for the address - a Client
        that wants any address has to send a Basic CRI instead. So this builder always writes an
        address, and 0.0.0 is a concrete request for 0.0.0, not a wildcard.
    #>
    param([Parameter(Mandatory)][int]$IndividualAddress, [int]$Layer = 0x02)
    return , ([byte[]]@(0x06, 0x04, ($Layer -band 0xFF), 0x00,
                        (($IndividualAddress -shr 8) -band 0xFF), ($IndividualAddress -band 0xFF)))
}

function New-V2Srp {
    <#
    .SYNOPSIS
        Builds one Search Request Parameter block.
    .DESCRIPTION
        03_08_02 7.6.3.3.1 Figure 27 p.33: structure length, then one octet carrying the M
        (Mandatory) flag in bit 7 and the type code in bits 6..0, then the type specific data.
    #>
    param([Parameter(Mandatory)][int]$Type, [byte[]]$Data = @(), [switch]$Mandatory)
    $flag = ($Type -band 0x7F)
    if ($Mandatory) { $flag = $flag -bor $script:V2_SRP_M_BIT }
    # The OUTER cast is the load-bearing one. [byte[]]@(a,b) + $Data yields an Object[] of boxed
    # bytes, which only survives because every consumer happens to have a [byte[]] parameter to
    # coerce it back - and stops surviving the moment two SRPs are concatenated to build a
    # multi-SRP request. Same reason KnxTest.psm1 casts every array it hands out.
    return , ([byte[]]([byte[]]@(((2 + $Data.Length) -band 0xFF), ($flag -band 0xFF)) + $Data))
}

function New-V2SearchRequestExtended {
    <#
    .SYNOPSIS
        Builds a SEARCH_REQUEST_EXTENDED (020Bh) with zero or more SRPs.
    .DESCRIPTION
        03_08_02 7.6.3.2 Figure 26 p.33: header, the Client's discovery endpoint HPAI, then the
        SRPs. A real HPAI is used rather than the route back form on purpose - the answer then
        lands on the socket the case is listening on, which is what makes a "must not respond"
        case provable on the same socket as its positive control.
    #>
    param([Parameter(Mandatory)][string]$DiscoveryIp, [Parameter(Mandatory)][int]$DiscoveryPort, [byte[]]$Srps = @())
    $hpai = New-KnxHpai -Ip $DiscoveryIp -Port $DiscoveryPort
    return , (New-KnxFrame -Service 0x020B -Body ([byte[]]($hpai + $Srps)))
}

# ── tunnel helpers ──────────────────────────────────────────────────────────────────────

function Open-V2Tunnel {
    <#
    .SYNOPSIS
        Opens a tunnelling connection with a Basic or an Extended CRI and returns a
        connection object of the same shape Open-KnxConnection produces.
    .DESCRIPTION
        The library builds only the Basic CRI, so the Extended CRI path is here. The returned
        object is shaped like the library's so Close-KnxConnection, Set-KnxTunnelGone,
        Test-KnxTunnelGone, Add-KnxTunnelParked and Update-KnxTunnelHeartbeat all work on it.

        An object is returned even on refusal - a case that expects E_NO_TUNNELLING_ADDRESS needs
        the status byte, not an exception.
    .PARAMETER IndividualAddress
        -1 sends a Basic CRI (03_08_04 5.4.3.1 p.26). Anything else sends an Extended CRI
        requesting exactly that address (5.4.3.2 p.26).
    #>
    param(
        [Parameter(Mandatory)][string]$Ip,
        [int]$Port = 3671,
        [int]$IndividualAddress = -1,
        [int]$Layer = 0x02,
        [int]$TimeoutMs = 3000
    )
    $sock = New-KnxSocket -TimeoutMs $TimeoutMs
    $localIp = Get-LocalEndpointFor -DestinationIp $Ip -Port $Port
    $localPort = Get-SocketLocalPort -Socket $sock
    $hpai = New-KnxHpai -Ip $localIp -Port $localPort
    if ($IndividualAddress -lt 0) { $cri = New-KnxCri -ConnectionType 0x04 -Layer $Layer }
    else                          { $cri = New-V2ExtendedCri -IndividualAddress $IndividualAddress -Layer $Layer }
    $frame = New-KnxFrame -Service 0x0205 -Body ([byte[]]($hpai + $hpai + $cri))

    $rsp = Invoke-KnxRequest -Socket $sock -Frame $frame -Ip $Ip -Port $Port `
                             -Expect @(0x0206) -TimeoutMs $TimeoutMs
    $dead = [pscustomobject]@{
        Ok = $false; Status = -1; StatusName = 'NO_ANSWER'; Channel = -1; Socket = $null
        Ip = $Ip; Port = $Port; SeqSend = 0; SeqRecv = 0; TunnelPa = $null; TunnelPaRaw = -1
        LocalIp = ''; LocalPort = 0; Request = $frame; Response = $null
        Disconnected = $true; DisconnectedBy = 'client'; DisconnectPacket = $null
        LastSpoke = [DateTime]::UtcNow; Cri = $cri
        # Unsolicited INFOs drained before a case began, parked ON THIS CONNECTION - a script-scope
        # buffer would hand them to the next call on ANY connection, and V-3.6.9d, which opens its own,
        # would then be failed for an INFO that belonged to the shared tunnel.
        PendingInfos = @()
    }
    if ($rsp.TimedOut) { $sock.Dispose(); return $dead }

    $cr = Read-KnxConnectResponse -Body $rsp.Header.Body
    if ($null -eq $cr -or $cr.IsError) {
        $sock.Dispose()
        $dead.Status = if ($null -eq $cr) { -1 } else { $cr.Status }
        $dead.StatusName = if ($null -eq $cr) { 'UNPARSEABLE' } else { $cr.StatusName }
        $dead.Response = $rsp.Packet.Bytes
        return $dead
    }
    $paRaw = -1
    if ($cr.Crd.Length -ge 4) { $paRaw = Get-Uint16 -Bytes $cr.Crd -Offset 2 }
    return [pscustomobject]@{
        Ok = $true; Status = $cr.Status; StatusName = $cr.StatusName; Channel = $cr.Channel
        Socket = $sock; Ip = $Ip; Port = $Port; SeqSend = 0; SeqRecv = 0
        TunnelPa = $cr.TunnelPa; TunnelPaRaw = $paRaw
        LocalIp = $localIp; LocalPort = $localPort
        Request = $frame; Response = $rsp.Packet.Bytes
        Disconnected = $false; DisconnectedBy = ''; DisconnectPacket = $null
        LastSpoke = [DateTime]::UtcNow; Cri = $cri
        # Unsolicited INFOs drained before a case began, parked ON THIS CONNECTION - a script-scope
        # buffer would hand them to the next call on ANY connection, and V-3.6.9d, which opens its own,
        # would then be failed for an INFO that belonged to the shared tunnel.
        PendingInfos = @()
    }
}

function Close-V2Tunnel {
    <#
    .SYNOPSIS
        Closes a connection and swallows anything that goes wrong doing it.
    .DESCRIPTION
        A teardown that throws turns a green case red for a reason that has nothing to do with what
        the case measured. Every case closes what it opened through this.
    #>
    param($Connection)
    if ($null -eq $Connection) { return }
    try { [void](Close-KnxConnection -Connection $Connection) } catch { }
}

function Get-V2SharedTunnel {
    <#
    .SYNOPSIS
        Returns the section's shared tunnel, reopening it when a previous case lost it.
    .DESCRIPTION
        Most cases here only read a feature, so one connection carries the whole section instead of
        putting a connect/disconnect pair in front of every case - a tunnel pool has four to eight
        slots and does not free them the instant a client leaves. But a case that provokes a
        teardown must not take the rest of the section down with it, so a dead channel is replaced.
        Returns $null when the device will not give a tunnel at all; the caller then reports N-A.
    #>
    if ($null -ne $script:V2Conn -and $script:V2Conn.Ok -and $null -ne $script:V2Conn.Socket) {
        # Read what is queued BEFORE judging the channel alive. Test-KnxTunnelGone only reads a flag,
        # and that flag is set when a DISCONNECT_REQUEST is actually READ - which happens inside
        # Clear-V2Stale. Draining here means a channel the server has already ended is discovered at
        # the START of a case, where the reopen below deals with it, instead of inside the first
        # feature call, where the case would go on to assert about a frame that was never sent.
        # Unsolicited INFOs found here are parked, not dropped: they belong to no request, and
        # V-3.6.9d asserts on that count.
        $drained = Clear-V2Stale -Connection $script:V2Conn
        if ($drained.InfoList.Count -gt 0) { $script:V2Conn.PendingInfos += $drained.InfoList }
        # 03_08_02 5.4 p.14 puts the heartbeat on the client and the 120 s deadline on the server.
        # A section that holds one tunnel across thirty cases has to discharge that duty itself.
        if (-not (Test-KnxTunnelGone -Connection $script:V2Conn) -and
            (Update-KnxTunnelHeartbeat -Connection $script:V2Conn)) { return $script:V2Conn }
    }
    if ($null -ne $script:V2Conn) { Close-V2Tunnel $script:V2Conn; $script:V2Conn = $null }
    $c = Open-V2Tunnel -Ip $script:V2Ip -Port $script:V2Port
    if ($c.Ok) { $script:V2Conn = $c; return $c }
    $script:V2ConnNa = "no tunnelling connection (CONNECT_RESPONSE status $($c.StatusName)) - no Interface Feature can be read"
    return $null
}

function Clear-V2Stale {
    <#
    .SYNOPSIS
        Drains datagrams left over from an earlier case before a new Feature frame is sent, and
        reports what was thrown away.
    .DESCRIPTION
        The teardown at the end of Invoke-V2FeatureService covers the unacknowledged frame, but not
        the frame that WAS acknowledged and whose response arrived after the receive window closed:
        that keeps the socket, so the late TUNNELLING_FEATURE_RESPONSE is still queued when the next
        case sends. The next case's loop matches inbound frames on the channel only, so it would
        adopt the previous case's answer - with the wrong value, and with ResponseMs measured against
        the wrong request. Where the two cases read the same Interface Feature (08h is the default of
        every positive control) nothing would even look wrong.

        The library's Clear-KnxSocket cannot be used here: it discards blindly, and on this shared
        tunnel that would drop bus frames a later case still wants to find parked.

        Draining is itself a client duty - 03_08_04 2.6.1 p.9 has the client acknowledge frames it
        receives, and a server whose frame goes unconfirmed repeats it and then terminates the
        connection. So everything addressed to our channel is acknowledged.

        What may be DISCARDED and what has to be carried forward follows from whether a frame answers
        a request. A TUNNELLING_FEATURE_RESPONSE is solicited: it belongs to one specific request, so
        a queued one is by definition stale and dropping it is the whole point. A
        TUNNELLING_FEATURE_INFO is unsolicited - 3.4 p.11 has the server send it on its own - so it
        belongs to no request and discarding one would destroy evidence: V-3.6.9d proves the server
        stays silent while the Info service is Disabled, and an INFO swallowed here would turn that
        device defect into a pass. INFOs are therefore returned in InfoList for the caller to fold
        into its own window, which can only ever produce a finding, never hide one. Bus frames are
        parked, where a later case finds them regardless.

        Bounded on purpose: a router on a live bus streams L_Data.ind, and an open-ended drain would
        never reach a quiet socket.

        KNOWN DEVIATION, left as it is on purpose: everything addressed to our channel is acknowledged
        without comparing the sequence counter against the expected one. 2.6.1 p.9 says a client
        receiving a counter that is neither the expected one nor one less "shall not reply and shall
        discard the received frame". Two reasons for not implementing that here yet. The main receive
        loop behaves the same way, so changing only the drain would make the two inconsistent; and the
        connection does not track a usable "expected" value (SeqRecv starts at 0 and the first inbound
        frame also carries 0), so a wrong guess would withhold acknowledges from legitimate frames -
        the server would then repeat and terminate the connection, which is far worse than the latent
        issue of acknowledging one frame too many. Settle it with a capture before changing it.
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [int]$QuietMs = 60,
        [int]$BudgetMs = 250,
        [int]$MaxFrames = 24
    )
    $sum = [pscustomobject]@{ Responses = 0; Infos = 0; BusFrames = 0; Foreign = 0; Total = 0; InfoList = @(); Truncated = $false }
    if ($null -eq $Connection -or $null -eq $Connection.Socket) { return $sum }
    $until = [DateTime]::UtcNow.AddMilliseconds($BudgetMs)
    # Did the loop stop because the socket was quiet, or because a bound ran out? Only the first means
    # "nothing left". On a busy bus the bounds can end the drain with a stale RESPONSE still queued
    # behind the bus frames - then the drain achieved nothing, and the caller must be able to SEE that
    # rather than assume it.
    $quiet = $false
    while ($sum.Total -lt $MaxFrames -and [DateTime]::UtcNow -lt $until) {
        $pkt = Receive-KnxFrame -Socket $Connection.Socket -TimeoutMs $QuietMs
        if ($null -eq $pkt) { $quiet = $true; break }
        $sum.Total++
        $h = Read-KnxHeader -Frame $pkt.Bytes
        if ($null -eq $h -or $h.Body.Length -lt 1) { continue }
        $b = $h.Body

        if ($h.Service -eq 0x0209) {
            if ($b[0] -eq $Connection.Channel) {
                Send-KnxFrame -Socket $Connection.Socket -Frame (New-KnxDisconnectResponse -Channel $b[0] -Status 0) `
                              -Ip $Connection.Ip -Port $Connection.Port
                Set-KnxTunnelGone -Connection $Connection -By 'device' -Packet ([pscustomobject]@{ Header = $h; Packet = $pkt })
                $quiet = $true
                break
            }
            continue
        }
        if ($b.Length -lt 4) { continue }
        if ($b[1] -ne $Connection.Channel) { $sum.Foreign++; continue }

        switch ($h.Service) {
            0x0420 {
                Send-KnxFrame -Socket $Connection.Socket -Frame (New-KnxTunnellingAck -Channel $b[1] -Sequence $b[2]) `
                              -Ip $Connection.Ip -Port $Connection.Port
                $Connection.SeqRecv = $b[2]
                $cemi = [byte[]]@(if ($b.Length -gt 4) { $b[4..($b.Length - 1)] } else { @() })
                [void](Add-KnxTunnelParked -Connection $Connection -Channel $b[1] -Sequence $b[2] -Cemi $cemi -Raw $pkt.Bytes)
                $sum.BusFrames++
            }
            0x0423 {
                Send-KnxFrame -Socket $Connection.Socket -Frame (New-KnxTunnellingAck -Channel $b[1] -Sequence $b[2]) `
                              -Ip $Connection.Ip -Port $Connection.Port
                $Connection.SeqRecv = $b[2]
                $sum.Responses++
            }
            0x0425 {
                Send-KnxFrame -Socket $Connection.Socket -Frame (New-KnxTunnellingAck -Channel $b[1] -Sequence $b[2]) `
                              -Ip $Connection.Ip -Port $Connection.Port
                $Connection.SeqRecv = $b[2]
                $sum.Infos++
                if ($b.Length -ge 6) {
                    $iv = [byte[]]@(if ($b.Length -gt 6) { $b[6..($b.Length - 1)] } else { @() })
                    $sum.InfoList += [pscustomobject]@{ FeatureId = $b[4]; Second = $b[5]; Value = $iv; Raw = $pkt.Bytes }
                }
            }
        }
    }
    $sum.Truncated = -not $quiet
    return $sum
}

function Invoke-V2FeatureService {
    <#
    .SYNOPSIS
        Sends a TUNNELLING_FEATURE_GET or _SET and collects the acknowledge and the response.
    .DESCRIPTION
        Implements both halves of 03_08_04 3.1 p.11 - "Tunnelling Feature services shall be confirmed
        by the receiver identically as the TUNNELLING_REQUEST service":

          * our frame carries the connection's own send sequence counter and the counter advances
            only on an acknowledge with a matching channel, matching sequence and status 00h, the
            same rule Send-KnxTunnelCemi follows;
          * everything the server sends on our channel while we wait is acknowledged - the
            TUNNELLING_FEATURE_RESPONSE and any TUNNELLING_FEATURE_INFO because 3.1 says so, and
            the L_Data.ind TUNNELLING_REQUESTs of a live bus because 2.6.1 p.9 makes the server
            repeat an unconfirmed frame once and then end the connection.

        Leaving that out is not a detail. Against the certified reference device an unacknowledged
        first RESPONSE blocked the server's send window for every later GET: eight features read as
        one implemented and seven missing, with the device behaving perfectly.

        Bus frames are parked with Add-KnxTunnelParked, so a later Receive-KnxTunnelCemi on the same
        connection still finds them in arrival order instead of them being silently dropped here.

        The one repeat that 2.6.1 p.9 requires IS sent - "shall", not may. It hides no finding: a
        device that confirms neither transmission still leaves AckSeq at -1 and still fails V-3.1.
        The only result it changes is for a device that confirms the second transmission, and per
        2.6.1 that device has behaved correctly.
    .OUTPUTS
        A fixed shape, always - under Set-StrictMode a missing property throws inside the case
        instead of producing a result:
          Acked / AckStatus / AckSeq / AckChannel   the acknowledge for OUR frame
          Responded / ReturnCode / FeatureId / Value / ValueLength / Raw   the RESPONSE
          Infos                                     every TUNNELLING_FEATURE_INFO seen meanwhile
          BusFrames                                 how many TUNNELLING_REQUESTs were acknowledged
          Foreign                                   frames for a channel that is not ours
          AckMs / ResponseMs                        ms from send to acknowledge, ms from
                                                    acknowledge to RESPONSE (3.2 p.11 allows 3 s)
          Sent                                      the datagram, for the evidence block
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][int]$Service,
        [Parameter(Mandatory)][int]$Feature,
        [byte[]]$Value = @(),
        [int]$Channel = -1,
        # Derived, not a magic number: 2.6.1 p.9 allows 1 s to the confirmation and 3.2 p.11 allows
        # 3 s from there, so a conform server may take 4000 ms. The 750 ms on top is the rig's own
        # latency. Editing either constant moves this default with it.
        [int]$TimeoutMs = ($script:V2_ACK_TIMEOUT_MS + $script:V2_RESPONSE_ALLOWANCE_MS + 750),
        [switch]$ExpectNoResponse,
        # -ExpectNoResponse meant two different things: "no answer is expected" (V-3.5b, the quiet
        # window) and "keep listening past the answer to collect INFOs". The second kind DOES expect a
        # response, so folding it into the first excluded it from the repeat 2.6.1 p.9 requires and
        # from the three-second allowance of 3.2 p.11 - one lost datagram then failed the device.
        [switch]$NoEarlyBreak
    )
    $res = [pscustomobject]@{
        Acked = $false; AckStatus = -1; AckSeq = -1; AckChannel = -1
        Responded = $false; ReturnCode = -1; FeatureId = -1
        Value = [byte[]]@(); ValueLength = -1; Raw = $null
        Infos = @(); BusFrames = 0; Foreign = 0
        AckMs = -1; ResponseMs = -1; Sent = $null; Sequence = -1
        Repeated = $false; Stale = $null
        # AckSeen latches the FACT that an acknowledge for $seq was seen; AckFailed remembers that it
        # carried an error status. Both must exist here: under Set-StrictMode reading an undeclared
        # property throws inside the case, and that throw looks exactly like a device defect.
        AckSeen = $false; AckFailed = $false
        # Mismatched collects TUNNELLING_FEATURE_RESPONSE frames whose Feature Identifier is not the
        # one this call asked for. Declared here for the same reason as above.
        Mismatched = @()
        # ChannelGone marks a result where nothing was put on the wire because the channel had
        # already ended. Without it a case cannot tell that apart from a silent device.
        ChannelGone = $false
    }
    if ($null -eq $Connection -or $null -eq $Connection.Socket) { return $res }

    # Two callers stay exempt from both the repeat below and the teardown at the end, or it would
    # destroy the very thing they measure: a frame deliberately addressed to another channel (V-3.5b)
    # is SUPPOSED to go unanswered, and -ExpectNoResponse callers are listening windows.
    $ownChannel = ($Channel -lt 0 -or $Channel -eq $Connection.Channel)
    $mayRepeat  = ($ownChannel -and -not $ExpectNoResponse)

    # Whatever is still queued belongs to an earlier case, not to the frame about to be sent. Only
    # the solicited answers are dropped; an unsolicited INFO has no request to be stale against, so
    # it joins this call's window instead of being lost - V-3.6.9d asserts on that count and a
    # swallowed INFO would turn a device defect into a pass. See Clear-V2Stale.
    $res.Stale = Clear-V2Stale -Connection $Connection
    if ($res.Stale.InfoList.Count -gt 0) { $res.Infos += $res.Stale.InfoList }
    if ($Connection.PendingInfos.Count -gt 0) { $res.Infos += $Connection.PendingInfos; $Connection.PendingInfos = @() }
    if (Test-KnxTunnelGone -Connection $Connection) {
        # Nothing was sent. Sent stays $null and Sequence stays -1, so a case that asserts about the
        # acknowledge would be judging a frame that never existed - and $res.Sequence -eq $res.AckSeq
        # would even pass as -1 -eq -1, hiding the cause. ChannelGone says so explicitly.
        $res.ChannelGone = $true
        return $res
    }

    $ch = if ($Channel -ge 0) { $Channel } else { $Connection.Channel }
    $seq = $Connection.SeqSend
    $res.Sequence = $seq
    $frame = New-V2FeatureFrame -Service $Service -Channel $ch -Sequence $seq -Feature $Feature -Value $Value
    $res.Sent = $frame

    $sw = [Diagnostics.Stopwatch]::StartNew()
    Send-KnxFrame -Socket $Connection.Socket -Frame $frame -Ip $Connection.Ip -Port $Connection.Port
    if ($null -ne $Connection.PSObject.Properties['LastSpoke']) { $Connection.LastSpoke = [DateTime]::UtcNow }

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    $ackAt = -1
    while ([DateTime]::UtcNow -lt $deadline) {
        # 03_08_04 2.6.1 p.9 gives the sender two INDEPENDENT triggers for the one repeat it owes:
        # no confirmation within TUNNELLING_REQUEST_TIMEOUT, "or the status of a received
        # TUNNELLING_ACK frame signals any kind of error condition" - the second with no waiting
        # period at all. Both are evaluated here, at the top of the loop, and deliberately NOT in
        # the receive-timeout branch: a router that streams L_Data.ind never lets the poll time out,
        # so a repeat hung off a null packet would never fire on exactly the device class it exists
        # for, and the teardown below would then report that device as never having confirmed.
        if ($mayRepeat -and -not $res.Repeated -and -not $res.Acked -and
            ($res.AckFailed -or $sw.ElapsedMilliseconds -ge $script:V2_ACK_TIMEOUT_MS)) {
            $res.Repeated = $true
            Send-KnxFrame -Socket $Connection.Socket -Frame $frame -Ip $Connection.Ip -Port $Connection.Port
            if ($null -ne $Connection.PSObject.Properties['LastSpoke']) { $Connection.LastSpoke = [DateTime]::UtcNow }
        }
        $left = [int][Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if ($mayRepeat -and -not $res.Repeated -and -not $res.Acked) {
            # Keep the slice short enough that the one-second mark is reached rather than slept
            # through, but never below 20 ms: a 1 ms timeout turns the rest of the window into a
            # busy poll for no gain.
            $toRepeat = $script:V2_ACK_TIMEOUT_MS - [int]$sw.ElapsedMilliseconds
            if ($toRepeat -lt $left) { $left = [int][Math]::Max(20, $toRepeat) }
        }
        $pkt = Receive-KnxFrame -Socket $Connection.Socket -TimeoutMs $left
        if ($null -eq $pkt) {
            # Not necessarily the end of the window: while the repeat is still owed the slice was
            # cut to the 1 s mark, so a timeout here means "go round and let the top send it".
            if ($mayRepeat -and -not $res.Repeated -and -not $res.Acked) { continue }
            break
        }
        $h = Read-KnxHeader -Frame $pkt.Bytes
        if ($null -eq $h -or $h.Body.Length -lt 2) { continue }
        $b = $h.Body

        if ($h.Service -eq 0x0209) {
            # The server ended the channel. 03_08_02 5.5 p.14 wants the response, and a case that
            # keeps waiting on a dead channel would report the device for going silent.
            if ($b.Length -ge 1 -and $b[0] -eq $Connection.Channel) {
                Send-KnxFrame -Socket $Connection.Socket -Frame (New-KnxDisconnectResponse -Channel $b[0] -Status 0) `
                              -Ip $Connection.Ip -Port $Connection.Port
                Set-KnxTunnelGone -Connection $Connection -By 'device' -Packet ([pscustomobject]@{ Header = $h; Packet = $pkt })
                break
            }
            continue
        }
        if ($h.Body.Length -lt 4) { continue }

        # Everything below is a connection-header service. A frame for somebody else's channel is
        # neither ours to acknowledge nor ours to judge.
        if ($b[1] -ne $Connection.Channel) { $res.Foreign++; continue }

        switch ($h.Service) {
            0x0421 {
                if ($b[2] -eq $seq -and -not $res.AckSeen) {
                    # Latch on having SEEN an acknowledge for THIS sequence counter, not on it having
                    # been a GOOD one. 2.6.1 p.9 makes the server answer an already-accepted counter
                    # with E_NO_ERROR, so after the repeat a SECOND acknowledge for $seq arrives.
                    # Latching on $res.Acked let that one overwrite the error status the device had
                    # really sent - and V-3.1 asserts 00h on AckStatus, so the rig turned a device
                    # that refused the frame into a pass. A rig fault must never produce a result.
                    $res.AckSeen = $true
                    $res.Acked = ($b[3] -eq 0x00)
                    $res.AckFailed = ($b[3] -ne 0x00)
                    $res.AckStatus = $b[3]
                    $res.AckSeq = $b[2]
                    $res.AckChannel = $b[1]
                    $ackAt = $sw.ElapsedMilliseconds
                    $res.AckMs = $ackAt
                    # 03_08_04 3.2 p.11 starts the three-second response allowance at the
                    # CONFIRMATION. A window measured from the send would expire while a device that
                    # confirmed late is still inside its allowance, and the case would report it as
                    # silent. The quarter second on top is the rig's own latency, not the device's.
                    if ($res.Acked -and -not $ExpectNoResponse) {
                        $ext = [DateTime]::UtcNow.AddMilliseconds($script:V2_RESPONSE_ALLOWANCE_MS + 250)
                        if ($ext -gt $deadline) { $deadline = $ext }
                    }
                }
                elseif (-not $res.AckSeen -and $res.AckSeq -lt 0) {
                    # An acknowledge for a different sequence number still belongs in the report:
                    # "the device acknowledged the wrong frame" is a finding, not noise. Recorded
                    # once, and AckSeen stays clear so a later acknowledge for the RIGHT counter can
                    # still take over - otherwise a stray wrong-sequence frame would hide the real one.
                    $res.AckSeq = $b[2]; $res.AckChannel = $b[1]; $res.AckStatus = $b[3]
                }
            }
            0x0420 {
                Send-KnxFrame -Socket $Connection.Socket -Frame (New-KnxTunnellingAck -Channel $b[1] -Sequence $b[2]) `
                              -Ip $Connection.Ip -Port $Connection.Port
                $Connection.SeqRecv = $b[2]
                $cemi = [byte[]]@(if ($b.Length -gt 4) { $b[4..($b.Length - 1)] } else { @() })
                [void](Add-KnxTunnelParked -Connection $Connection -Channel $b[1] -Sequence $b[2] -Cemi $cemi -Raw $pkt.Bytes)
                $res.BusFrames++
            }
            0x0425 {
                Send-KnxFrame -Socket $Connection.Socket -Frame (New-KnxTunnellingAck -Channel $b[1] -Sequence $b[2]) `
                              -Ip $Connection.Ip -Port $Connection.Port
                $Connection.SeqRecv = $b[2]
                # Only the 4 octet connection header is guaranteed above. A well-formed INFO body is
                # at least 6 octets (Feature Identifier + one reserved), and a truncated one would
                # make $b[4] throw "Index was outside the bounds of the array" - inside a case, where
                # it reads as a device defect. A conformance rig is pointed at malformed frames on
                # purpose, so the short frame is counted, not indexed. The sibling 0423h handler and
                # Clear-V2Stale already guard this way.
                if ($b.Length -ge 6) {
                    $iv = [byte[]]@(if ($b.Length -gt 6) { $b[6..($b.Length - 1)] } else { @() })
                    $res.Infos += [pscustomobject]@{ FeatureId = $b[4]; Second = $b[5]; Value = $iv; Raw = $pkt.Bytes }
                }
                else { $res.Foreign++ }
            }
            0x0423 {
                Send-KnxFrame -Socket $Connection.Socket -Frame (New-KnxTunnellingAck -Channel $b[1] -Sequence $b[2]) `
                              -Ip $Connection.Ip -Port $Connection.Port
                $Connection.SeqRecv = $b[2]
                # A RESPONSE is SOLICITED: 03_08_04 3.5 p.12 requires the Feature Identifier to be
                # copied from the request, so one naming another feature answers a DIFFERENT request -
                # on this shared tunnel, the previous case's. Matching on the channel alone let a case
                # adopt another case's answer, judge its value, and measure ResponseMs against the
                # wrong request; it also broke the loop early, so the real answer was never read.
                # Adopting only the matching identifier is deterministic. A non-matching one is kept
                # as evidence but NEVER promoted to the result: the rig must not decide whether it
                # was the device copying the wrong id or the rig hearing an older case.
                if ($b.Length -ge 6 -and $b[4] -ne $Feature) {
                    $res.Mismatched += [pscustomobject]@{ FeatureId = $b[4]; ReturnCode = $b[5]; Raw = $pkt.Bytes }
                }
                elseif (-not $res.Responded -and $b.Length -ge 6) {
                    $res.Responded = $true
                    $res.FeatureId = $b[4]
                    $res.ReturnCode = $b[5]
                    # [byte[]]@( ... ) is load-bearing, not decoration: a scriptblock that emits a
                    # ONE element array has it unrolled to a scalar, so a single octet feature value
                    # made $res.Value a [byte] and the next line threw "The property 'Length' cannot
                    # be found on this object" - inside the case, where it reads as a device defect.
                    # Most Interface Feature values are exactly one octet, which is why this took out
                    # most of the section at once. The same shape is fixed in four other places here.
                    $res.Value = [byte[]]@(if ($b.Length -gt 6) { $b[6..($b.Length - 1)] } else { @() })
                    $res.ValueLength = $res.Value.Length
                    $res.Raw = $pkt.Bytes
                    if ($ackAt -ge 0) { $res.ResponseMs = $sw.ElapsedMilliseconds - $ackAt }
                    else              { $res.ResponseMs = $sw.ElapsedMilliseconds }
                }
            }
        }
        if ($res.Responded -and -not $ExpectNoResponse -and -not $NoEarlyBreak) { break }
    }
    $sw.Stop()
    if ($res.Acked) { $Connection.SeqSend = (($seq + 1) -band 0xFF) }

    # A frame that was never positively acknowledged leaves the send counter where it was, which is
    # correct - the server never confirmed receipt, so moving on would put every later frame outside
    # its window. But on a connection the whole section SHARES that leaves a trap: 03_08_04 2.6.1 p.9
    # makes the server acknowledge and DISCARD a frame it has already seen, so the next case's
    # different frame arrives under a used sequence number, is acknowledged with E_NO_ERROR, and is
    # thrown away. Every case after that reports a silent device. The library's Send-KnxTunnelCemi
    # carries the same note and solves it the same way: end the channel, so the next
    # Get-V2SharedTunnel finds it dead and opens a clean one. The case that saw the failure has
    # already recorded its finding by then.
    #
    # $mayRepeat carries the two exemptions, and by the time this is reached the repeat that
    # 2.6.1 p.9 requires before terminating has already been sent and gone unconfirmed too.
    if (-not $res.Acked -and $mayRepeat -and -not (Test-KnxTunnelGone -Connection $Connection)) {
        try {
            $bye = New-KnxDisconnectRequest -Channel $Connection.Channel -ControlIp $Connection.LocalIp -ControlPort $Connection.LocalPort
            Send-KnxFrame -Socket $Connection.Socket -Frame $bye -Ip $Connection.Ip -Port $Connection.Port
        } catch { }
        Set-KnxTunnelGone -Connection $Connection -By 'client'
        try { $Connection.Socket.Dispose() } catch { }
        try { $Connection.Socket = $null } catch { }
    }
    return $res
}

function Test-V2Sent {
    <#
    .SYNOPSIS
        False - after marking the case N-A - when the frame never reached the wire.
    .DESCRIPTION
        Invoke-V2FeatureService returns ChannelGone when the drain found the server had already ended
        the channel. Nothing was sent then, so AckSeq stays -1 and Sequence stays -1: a case that
        asserts about the acknowledge would report a silent device for a frame that never existed,
        and "Sequence equals AckSeq" would even pass as -1 -eq -1 and hide the cause. A rig fault
        must never become a result, so the case ends as N-A instead.
    #>
    param($Result)
    if ($Result.ChannelGone) {
        Set-KnxTestNotApplicable 'the server had already ended the channel, so this frame was never sent - there is nothing here to judge'
        return $false
    }
    return $true
}

function Test-V2ChannelAlive {
    <#
    .SYNOPSIS
        True when the server still answers CONNECTIONSTATE_REQUEST for this channel with E_NO_ERROR.
    .DESCRIPTION
        03_08_02 7.8.4 Table 9 p.40. Half of every positive control: it proves the channel exists.
        The other half is Test-V2FeatureServed, which proves the Feature service is still being
        served on it - a channel can be alive while the feature layer is wedged behind an
        unconfirmed frame, and that is exactly the state that produced a false "not implemented".
    #>
    param($Connection)
    if ($null -eq $Connection -or $null -eq $Connection.Socket) { return $false }
    $f = New-KnxConnectionStateRequest -Channel $Connection.Channel -ControlIp $Connection.LocalIp -ControlPort $Connection.LocalPort
    $r = Invoke-KnxRequest -Socket $Connection.Socket -Frame $f -Ip $Connection.Ip -Port $Connection.Port `
                           -Expect @(0x0208) -TimeoutMs 2000
    if ($null -ne $Connection.PSObject.Properties['LastSpoke']) { $Connection.LastSpoke = [DateTime]::UtcNow }
    if ($r.TimedOut -or $r.Header.Body.Length -lt 2) { return $false }
    if ($r.Header.Body[0] -ne $Connection.Channel) { return $false }
    return ($r.Header.Body[1] -eq 0x00)
}

function Test-V2FeatureServed {
    <#
    .SYNOPSIS
        True when a TUNNELLING_FEATURE_GET on this channel is confirmed AND answered with a
        successful TUNNELLING_FEATURE_RESPONSE.
    .DESCRIPTION
        The positive control of every negative case in this section. Feature 08 is the default
        because 06 Profiles 5.8.3.3.4.2 p.69 makes G mandatory for it on a v2 server, so a device
        that refuses it is failing a clause of its own rather than lacking an optional feature.
    #>
    param($Connection, [int]$Feature = 0x08)
    if ($null -eq $Connection -or $null -eq $Connection.Socket) { return $false }
    $r = Invoke-V2FeatureService -Connection $Connection -Service 0x0422 -Feature $Feature
    return ($r.Acked -and $r.Responded -and $r.ReturnCode -eq $script:V2_RC_SUCCESS -and $r.FeatureId -eq $Feature)
}

# ── discovery helpers ───────────────────────────────────────────────────────────────────

function Invoke-V2SearchExtended {
    <#
    .SYNOPSIS
        Sends a SEARCH_REQUEST_EXTENDED to the server's CONTROL endpoint and collects the answers.
    .DESCRIPTION
        03_08_02 7.6.3.1 p.33 allows the request at the discovery endpoint OR at the control
        endpoint, and the control endpoint is the right choice here: it is unicast, so the result
        cannot be polluted by another KNXnet/IP server on the same wire, and a "must not respond"
        case then has exactly one device that could have answered.

        Every 020Ch that arrives inside the window is collected, not just the first. 7.6.4.1 p.35:
        "If the KNXnet/IP Server supports more than one KNX connection, the KNXnet/IP Server shall
        announce each of its own control endpoints in a single SEARCH_RESPONSE_EXTENDED Frame" -
        so more than one answer from one device is legal and a case that grabbed the first would
        mis-report the rest.

        A fresh socket per call, on purpose: the socket is the evidence. A negative case and its
        positive control must share ONE socket (see -Socket), because reusing a socket across
        unrelated cases is how a stale answer turns a silent device green.
    .PARAMETER Socket
        Reuse an existing socket instead of creating one. The negative-plus-control cases pass the
        same socket to both halves so the control proves the path, not just the device.
    .OUTPUTS
        Answered / Frames (raw) / Bodies / Other (anything that was not a 020Ch) / Srps (what was sent)
    #>
    param(
        [byte[]]$Srps = @(),
        [int]$TimeoutMs = 2500,
        $Socket = $null
    )
    $own = $false
    $sock = $Socket
    if ($null -eq $sock) { $sock = New-KnxSocket -TimeoutMs $TimeoutMs; $own = $true }
    $res = [pscustomobject]@{ Answered = $false; Frames = @(); Bodies = @(); Other = @(); Srps = $Srps; Sent = $null }
    try {
        $localIp = Get-LocalEndpointFor -DestinationIp $script:V2Ip -Port $script:V2Port
        $localPort = Get-SocketLocalPort -Socket $sock
        $frame = New-V2SearchRequestExtended -DiscoveryIp $localIp -DiscoveryPort $localPort -Srps $Srps
        $res.Sent = $frame
        Send-KnxFrame -Socket $sock -Frame $frame -Ip $script:V2Ip -Port $script:V2Port
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        while ([DateTime]::UtcNow -lt $deadline) {
            $left = [int][Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            $pkt = Receive-KnxFrame -Socket $sock -TimeoutMs $left
            if ($null -eq $pkt) { break }
            $h = Read-KnxHeader -Frame $pkt.Bytes
            if ($null -eq $h) { continue }
            if ($h.Service -eq 0x020C) {
                $res.Answered = $true
                # ,$bytes on both: += with a bare byte[] unrolls it into an Object[] of boxed
                # octets, and the DIB walk then runs over one octet at a time. The library's own
                # header says the same thing about every byte array it returns.
                $res.Frames += , $pkt.Bytes
                $res.Bodies += , $h.Body
            }
            else { $res.Other += $h.ServiceName }
        }
    }
    finally { if ($own) { $sock.Dispose() } }
    return $res
}

function Get-V2SrxDibs {
    <#
    .SYNOPSIS
        Walks the DIBs of a SEARCH_RESPONSE_EXTENDED body.
    .DESCRIPTION
        03_08_02 7.6.4.2 Figure 32 p.36 puts the server's control endpoint HPAI first, so the DIB
        walk starts at octet 8. Handing the whole body to Read-KnxDibs instead reads the HPAI as a
        DIB of type 01h (its first two octets are 08 01) and produces one plausible-looking wrong
        entry - which is the kind of parser error that makes a device look non-conformant.
    #>
    param([Parameter(Mandatory)][byte[]]$Body)
    # NO ,$array guard here, and that is deliberate. The guard exists to stop a BYTE array being
    # unrolled into boxed octets; on a collection of objects it does the opposite damage, because it
    # makes the function emit the whole list as ONE stream item and @(Get-V2SrxDibs ...) at the call
    # site then yields a single element that is itself the list. Measured: without the guard the
    # helper hands back 3 DIBs and @() keeps 3; with it, @() produced 1, Get-V2Dib matched an
    # Object[] of eight type codes against 06h, returned that array as "the DIB", and
    # Test-V2SecuredTunnelling answered True on a device whose Secured Service Families DIB names
    # only Device Management. Every cross-check downstream was reading garbage and none of it
    # looked wrong.
    if ($Body.Length -lt 9) { return @() }
    return (Read-KnxDibs -Body $Body -Offset 8)
}

function Get-V2Dib {
    <#
    .SYNOPSIS
        Returns the first DIB of a given type code out of a DIB list, or $null.
    #>
    param($Dibs, [Parameter(Mandatory)][int]$Type)
    foreach ($d in @($Dibs)) { if ($d.Type -eq $Type) { return $d } }
    return $null
}

function Get-V2TunnellingSlots {
    <#
    .SYNOPSIS
        Decodes the Tunnelling Information DIB into one record per Tunnelling Slot.
    .DESCRIPTION
        03_08_02 7.5.4.8 p.28 and Figure 21/22 p.29: two octets of APDU-length for bus access,
        then 4 octets per slot - the two-octet Individual Address and a two-octet status whose
        bit 0 is Free, bit 1 Authorised, bit 2 Usable, and whose bits 15..3 the server shall set
        to 1. Reserved is carried through so V-7.5.4.8 can check that instead of masking it away.
    #>
    param($Dib)
    $out = @()
    # Plain output, not ,$out - see the note in Get-V2SrxDibs. Callers wrap this in @().
    if ($null -eq $Dib -or $Dib.Payload.Length -lt 2) { return $out }
    $p = $Dib.Payload
    for ($i = 2; ($i + 3) -lt $p.Length; $i += 4) {
        $raw = Get-Uint16 -Bytes $p -Offset $i
        $st = Get-Uint16 -Bytes $p -Offset ($i + 2)
        $out += [pscustomobject]@{
            Raw        = $raw
            Address    = (ConvertFrom-KnxPa -Raw $raw)
            Status     = $st
            Free       = (($st -band 0x0001) -ne 0)
            Authorised = (($st -band 0x0002) -ne 0)
            Usable     = (($st -band 0x0004) -ne 0)
            Reserved   = ($st -shr 3)
        }
    }
    return $out
}

function Get-V2ApduLengthFromDib {
    <#
    .SYNOPSIS
        The "APDU-length for bus access" field of the Tunnelling Information DIB, or -1.
    #>
    param($Dib)
    if ($null -eq $Dib -or $Dib.Payload.Length -lt 2) { return -1 }
    return (Get-Uint16 -Bytes $Dib.Payload -Offset 0)
}

function Test-V2SecuredTunnelling {
    <#
    .SYNOPSIS
        True when the device declares KNXnet/IP Tunnelling to be a secured service family.
    .DESCRIPTION
        03_08_04 5.4.3.3.2 step 2 p.28 names the source: "the Tunnelling Server shall evaluate
        PID_SECURED_SERVICE_FAMILIES and check if the Security Version equals 00h or not". The
        Secured Service Families DIB (06h) in a SEARCH_RESPONSE_EXTENDED is the same information on
        the wire, so it can be read without a device-management connection. Tunnelling absent from
        that DIB, or present with Security Version 00h, means not secured.

        This decides whether E_AUTHORISATION_ERROR is reachable at all, so it is derived from the
        device rather than from the knowledge that Secure is switched off in this rig.
    #>
    param($Dibs)
    $d = Get-V2Dib -Dibs $Dibs -Type 0x06
    if ($null -eq $d) { return $false }
    $p = $d.Payload
    for ($i = 0; ($i + 1) -lt $p.Length; $i += 2) {
        if ($p[$i] -eq 0x04 -and $p[$i + 1] -ne 0x00) { return $true }
    }
    return $false
}

# ── the Interface Feature table ─────────────────────────────────────────────────────────
#
# Id          the case id, which is the clause of 03_08_04 that defines the feature
# Feature     the Interface Feature Identifier on the wire
# Name        as 06 Profiles 5.8.3.3.4.2 p.69 spells it
# GetSupport  'M' when the Profiles matrix shows G, 'O' when it shows (G)
# ValueOctets the value length in octets. Not called Length: PowerShell hands out a Length
#             property of its own on several types, and a key that shadows one is a bug waiting
#             for a refactor. 09_03 3.5.3.3.1 Figure 29 p.31 for features 01 to 05;
#         03_08_04 3.6.7 p.15 (an IA is two octets), 3.6.8 p.16 (PDT_UNSIGNED_INT, U16) and
#         3.6.9 p.16 (DPT_Enable 1.003) for 06, 07 and 08.
#         Features 06, 07 and 08 exist ONLY in 03_08_04. 09_03 v01.03.04, which 03_08_04 cites as
#         [10] for the "common definition", defines 01 to 05 and stops - so the length and encoding
#         of the three v2-only features are taken from 03_08_04 itself. Noted rather than glossed
#         over, because a reader chasing [10] for feature 07 will not find it.
$script:V2Features = @(
    @{ Id = 'V-3.6.2'; Feature = 0x01; Name = 'Supported EMI type';                   GetSupport = 'O'; ValueOctets = 2
       Clause = '03_08_04 3.6.2 p.12; 09_03 3.5.3.3.2 p.32; 06 Profiles 5.8.3.3.4.2 p.69' }
    @{ Id = 'V-3.6.3'; Feature = 0x02; Name = 'Device Descriptor Type 0';             GetSupport = 'M'; ValueOctets = 2
       Clause = '03_08_04 3.6.3 p.13; 09_03 3.5.3.3.3 p.32; 06 Profiles 5.8.3.3.4.2 p.69' }
    @{ Id = 'V-3.6.4'; Feature = 0x03; Name = 'Bus connection status';                GetSupport = 'M'; ValueOctets = 1
       Clause = '03_08_04 3.6.4 p.13; 09_03 3.5.3.4 p.33; 06 Profiles 5.8.3.3.4.2 p.69' }
    @{ Id = 'V-3.6.5'; Feature = 0x04; Name = 'KNX Manufacturer Code';                GetSupport = 'M'; ValueOctets = 2
       Clause = '03_08_04 3.6.5 p.14; 09_03 3.5.3.4.1 p.34; 06 Profiles 5.8.3.3.4.2 p.69' }
    @{ Id = 'V-3.6.6'; Feature = 0x05; Name = 'Active EMI type';                      GetSupport = 'O'; ValueOctets = 1
       Clause = '03_08_04 3.6.6 p.14; 09_03 3.5.3.4.2 p.34 and Figure 18 p.23; 06 Profiles 5.8.3.3.4.2 p.69' }
    @{ Id = 'V-3.6.7'; Feature = 0x06; Name = 'Interface Individual Address';         GetSupport = 'M'; ValueOctets = 2
       Clause = '03_08_04 3.6.7 p.15; 5.4.4 p.30; 06 Profiles 5.8.3.3.4.2 p.69' }
    @{ Id = 'V-3.6.8'; Feature = 0x07; Name = 'Max APDU Length';                      GetSupport = 'M'; ValueOctets = 2
       Clause = '03_08_04 3.6.8 p.16; 03_08_02 7.5.4.8 p.29; 06 Profiles 5.8.3.3.4.2 p.69' }
    @{ Id = 'V-3.6.9'; Feature = 0x08; Name = 'Interface Feature Info service Enable'; GetSupport = 'M'; ValueOctets = 1
       Clause = '03_08_04 3.6.9 p.16; 06 Profiles 5.8.3.3.4.2 p.69' }
)

function Test-V2FeatureValue {
    <#
    .SYNOPSIS
        Asserts the feature-specific constraints on a value a TUNNELLING_FEATURE_GET returned.
    .DESCRIPTION
        One place for the eight value contracts, so the GET cases stay uniform and the per-feature
        reasoning is readable in one block rather than scattered over eight near-identical bodies.

        Every constraint here is a cross-check against a SECOND statement the device makes about the
        same thing, not a hard-coded expectation - a feature value that merely looks plausible is
        the failure class this file is most exposed to. Observed on the certified reference device:
        01 = 00 04, 02 = 00 12, 03 = 01, 04 = 00 83, 05 = 03, 06 = 50 BF (its own CRD address),
        07 = 00 D2 (= the DIB's 210), 08 = 00.
    .PARAMETER Connection
        Needed by feature 06, which must equal the address of THIS connection.
    #>
    param(
        [Parameter(Mandatory)][int]$Feature,
        [Parameter(Mandatory)][byte[]]$Value,
        $Connection = $null
    )
    switch ($Feature) {
        0x01 {
            # 09_03 3.5.3.3.2 p.32: a 16 bit field, bit 0 EMI1, bit 1 EMI2, bit 2 cEMI, everything
            # else reserved and cleared. 03_08_04 3.6.2 p.12 narrows it for tunnelling: "only cEMI
            # is allowed for KNXnet/IP Tunnelling, so, only this value shall be reported."
            $bits = Get-Uint16 -Bytes $Value -Offset 0
            Add-KnxEvidence -Note ("supported EMI types 0x{0:X4} (bit0 EMI1, bit1 EMI2, bit2 cEMI)" -f $bits)
            Assert-KnxTrue (($bits -band 0x0004) -ne 0) 'cEMI is not among the supported EMI types, but tunnelling allows nothing else'
            Assert-KnxEqual 0x0004 $bits 'an EMI type other than cEMI is reported; 03_08_04 3.6.2 allows only cEMI for tunnelling'
        }
        0x02 {
            # 03_08_02 7.5.4.9 p.31: the Extended Device Information DIB carries the same Device
            # Descriptor Type 0, and both "shall be identical as ... PID_DEVICE_DESCRIPTOR (PID 83)".
            # Two statements about one device: if they differ, one of them is wrong.
            $dd0 = Get-Uint16 -Bytes $Value -Offset 0
            Add-KnxEvidence -Note ("Device Descriptor Type 0 = 0x{0:X4}" -f $dd0)
            Assert-KnxTrue ($dd0 -ne 0) 'Device Descriptor Type 0 reads 0000h, which is not a mask version'
            $ext = Get-V2Dib -Dibs $script:V2SrxDibs -Type 0x08
            if ($null -ne $ext -and $ext.Payload.Length -ge 6) {
                $fromDib = Get-Uint16 -Bytes $ext.Payload -Offset 4
                Assert-KnxEqual $fromDib $dd0 'feature 02 and the Extended Device Information DIB report different Device Descriptors'
            }
            else { Add-KnxEvidence -Note 'no Extended Device Information DIB available to cross-check against' }
        }
        0x03 {
            # 09_03 3.5.3.4 p.33: "encoded using DPT_State (DPT_ID = 1.011)", 0 = Inactive,
            # 1 = Active, and "The feature shall be a one-bit read-only value". Anything above 1 is
            # the "false response ... values larger than 1 bit" the same clause calls out.
            #
            # The value itself is NOT asserted. A device legitimately reads 0 with the line pulled,
            # so demanding Active would be a case that fails on a correct device - and demanding
            # Inactive is a case that can never pass. What IS asserted is agreement with the other
            # place the device states the same fact: 03_08_02 7.5.4.9 p.31 makes the Medium Status
            # octet of the Extended Device Information DIB identical to PID_MEDIUM_STATUS, whose
            # bit 0 is COMMUNICATION_IMPOSSIBLE. Active must mean bit 0 clear.
            $st = [int]$Value[0]
            $txt = if ($st -eq 1) { 'Active - there is a connection to the bus' } else { 'Inactive - there is no bus connection' }
            Add-KnxEvidence -Note ("bus connection status = $st ($txt)")
            Assert-KnxTrue ($st -le 1) "bus connection status reads $st; DPT_State is a one-bit value, so only 0 or 1 is valid"
            $ext = Get-V2Dib -Dibs $script:V2SrxDibs -Type 0x08
            if ($null -ne $ext -and $ext.Payload.Length -ge 1) {
                $impossible = (($ext.Payload[0] -band 0x01) -ne 0)
                Add-KnxEvidence -Note ("Extended Device Information DIB medium status 0x{0:X2}, COMMUNICATION_IMPOSSIBLE = {1}" -f $ext.Payload[0], $impossible)
                Assert-KnxEqual (-not $impossible) ($st -eq 1) `
                    'feature 03 and the Medium Status of the Extended Device Information DIB contradict each other about the bus connection'
            }
            else { Add-KnxEvidence -Note 'no Extended Device Information DIB available to cross-check the medium status against' }
        }
        0x04 {
            # 09_03 3.5.3.4.1 p.34: "the 2 octet KNX Association manufacturer code of the commercial
            # provider of the device", U16. 0000h is not an assigned code.
            $mfr = Get-Uint16 -Bytes $Value -Offset 0
            Add-KnxEvidence -Note ("KNX manufacturer code {0} (0x{0:X4})" -f $mfr)
            Assert-KnxTrue ($mfr -ne 0) 'KNX manufacturer code reads 0000h, which is not an assigned code'
            # 03_08_02 7.5.4.7 p.28: the Manufacturer Data DIB carries the same code. Cross-checked
            # when the device sends one; that DIB is optional, so its absence is not a finding.
            $mdib = Get-V2Dib -Dibs $script:V2SrxDibs -Type 0xFE
            if ($null -ne $mdib -and $mdib.Payload.Length -ge 2) {
                Assert-KnxEqual (Get-Uint16 -Bytes $mdib.Payload -Offset 0) $mfr `
                    'feature 04 and the Manufacturer Data DIB report different KNX manufacturer codes'
            }
            else { Add-KnxEvidence -Note 'no Manufacturer Data DIB available to cross-check against' }
        }
        0x05 {
            # 09_03 3.5.3.4.2 p.34 says the coding is the one of Figure 18 p.23, the EMI ID octet:
            # 01h EMI1, 02h EMI2, 03h common EMI. 03_08_04 3.6.6 p.14 repeats the tunnelling
            # restriction, so the only conformant answer here is 03h.
            Add-KnxEvidence -Note ("active EMI type 0x{0:X2} (01h EMI1, 02h EMI2, 03h cEMI)" -f $Value[0])
            Assert-KnxEqual 0x03 ([int]$Value[0]) 'the active EMI type is not cEMI (03h); 03_08_04 2.2.1 allows nothing else for tunnelling'
        }
        0x06 {
            # 03_08_04 3.6.7 p.15: "This Feature shall be the Individual Address that is used by
            # this Tunnelling Connection", and the same clause names where the client already knows
            # it from: "it is part of the CRD that is returned by the Tunnelling Server when the
            # connection is established". So the CRD of THIS connection is the reference, which is
            # why this check needs the connection and not a configured expectation.
            $ia = Get-Uint16 -Bytes $Value -Offset 0
            Add-KnxEvidence -Note ("interface individual address {0} (0x{1:X4})" -f (ConvertFrom-KnxPa -Raw $ia), $ia)
            Assert-KnxTrue ($ia -ne 0) 'the interface individual address reads 0.0.0, which no tunnelling connection can use'
            if ($null -ne $Connection -and $Connection.TunnelPaRaw -ge 0) {
                Assert-KnxEqual $Connection.TunnelPaRaw $ia `
                    ("feature 06 reports {0} but the CRD of this connection assigned {1}" -f (ConvertFrom-KnxPa -Raw $ia), $Connection.TunnelPa)
            }
        }
        0x07 {
            # 03_08_04 3.6.8 p.16: "identical as the value of PID_MAX_INTERFACE_APDU_LENGTH
            # (PID: 68) in the cEMI Server Object", and 03_08_02 7.5.4.8 p.29 says the Tunnelling
            # Information DIB's "APDU-length for bus access" equals the same property. The DIB is
            # therefore the on-the-wire cross-check, with no device-management connection needed.
            $apdu = Get-Uint16 -Bytes $Value -Offset 0
            Add-KnxEvidence -Note "max APDU length for bus access = $apdu octets"
            # 15 is the APDU length a standard frame carries and the floor every device supports;
            # a value below it cannot be a real interface limit.
            Assert-KnxTrue ($apdu -ge 15) "max APDU length reads $apdu, below the 15 octets a standard frame already needs"
            $tdib = Get-V2Dib -Dibs $script:V2SrxDibs -Type 0x07
            $fromDib = Get-V2ApduLengthFromDib -Dib $tdib
            if ($fromDib -ge 0) {
                Assert-KnxEqual $fromDib $apdu `
                    'feature 07 and the APDU-length field of the Tunnelling Information DIB disagree, although both must equal PID_MAX_INTERFACE_APDU_LENGTH'
            }
            else { Add-KnxEvidence -Note 'no Tunnelling Information DIB available to cross-check the APDU length against' }
        }
        0x08 {
            # 03_08_04 3.6.9 p.16: DPT_Enable (1.003), 0 = Disable, 1 = Enable, nothing else.
            # The default is checked by V-3.6.9d on a connection nobody has written to; here only
            # the encoding, because this connection is shared and an earlier case may have set it.
            Add-KnxEvidence -Note ("info service enable = {0}" -f $Value[0])
            Assert-KnxTrue ([int]$Value[0] -le 1) `
                ("info service enable reads {0}; DPT_Enable defines only 0 (Disable) and 1 (Enable)" -f $Value[0])
        }
    }
}

function Invoke-KnxSuiteTunnellingV2 {
    param([Parameter(Mandatory)]$Ctx, [string]$SuiteTitle = '11 Tunnelling v2')

    $script:V2Ip = $Ctx.BdutIp
    $script:V2Port = $Ctx.Port

    # ── one gate for the whole section ─────────────────────────────────────────────────
    # The family versions come from the DESCRIPTION_RESPONSE, which every KNXnet/IP server answers
    # regardless of version - asking with SEARCH_REQUEST_EXTENDED would be circular, because that
    # service is itself one of the things under test.
    $script:V2Desc = $null
    try { $script:V2Desc = Get-KnxDescription -Ip $script:V2Ip -Port $script:V2Port -TimeoutMs 2500 } catch { }
    $script:V2CoreVer = -1
    $script:V2TunVer = -1
    $script:V2HostIa = -1
    $script:V2Mac = $null
    $script:V2ProgMode = $false
    if ($null -ne $script:V2Desc) {
        foreach ($f in @($script:V2Desc.Families)) {
            if ($f.Id -eq 0x02) { $script:V2CoreVer = [int]$f.Version }
            if ($f.Id -eq 0x04) { $script:V2TunVer = [int]$f.Version }
        }
        $dev = Get-V2Dib -Dibs $script:V2Desc.Dibs -Type 0x01
        if ($null -ne $dev -and $dev.Payload.Length -ge 52) {
            $script:V2HostIa = Get-Uint16 -Bytes $dev.Payload -Offset 2
            $script:V2Mac = [byte[]]$dev.Payload[16..21]
            $script:V2ProgMode = (($dev.Payload[1] -band 0x01) -ne 0)
        }
    }
    $script:V2TunNa = if ($null -eq $script:V2Desc) {
        'the device did not answer a DESCRIPTION_REQUEST, so the Tunnelling service family version could not be read'
    } elseif ($script:V2TunVer -lt 0) {
        'the device does not advertise the KNXnet/IP Tunnelling service family at all; the v2 Tunnelling services do not apply'
    } else {
        "the device advertises KNXnet/IP Tunnelling service family version 0$($script:V2TunVer)h, not 02h; 06 Profiles 5.8.3.3.4 p.68 binds the Extended CRI, the Tunnelling Feature services and the Interface Features to version 02h"
    }
    $script:V2CoreNa = if ($null -eq $script:V2Desc) {
        'the device did not answer a DESCRIPTION_REQUEST, so the Core service family version could not be read'
    } else {
        "the device advertises KNXnet/IP Core service family version 0$($script:V2CoreVer)h, not 02h; SEARCH_REQUEST_EXTENDED and the SRPs were introduced with Core v2 (03_08_02 7.6.3 p.33)"
    }
    $tunV2 = ($script:V2TunVer -ge 2)
    $coreV2 = ($script:V2CoreVer -ge 2)

    # ── the DIBs every cross-check needs, fetched once ─────────────────────────────────
    # Only reachable on a Core v2 device. On a v1 device this stays empty and the cross-checks in
    # Test-V2FeatureValue say so in the evidence instead of failing a case for a missing DIB.
    $script:V2SrxDibs = @()
    $script:V2SrxOk = $false
    $script:V2Slots = @()
    if ($coreV2) {
        try {
            $srx = Invoke-V2SearchExtended -TimeoutMs 2500
            if ($srx.Answered -and $srx.Bodies.Count -gt 0) {
                $script:V2SrxDibs = @(Get-V2SrxDibs -Body ([byte[]]$srx.Bodies[0]))
                $script:V2SrxOk = $true
                $script:V2Slots = @(Get-V2TunnellingSlots -Dib (Get-V2Dib -Dibs $script:V2SrxDibs -Type 0x07))
            }
        } catch { }
    }

    # ── the shared tunnel ──────────────────────────────────────────────────────────────
    $script:V2Conn = $null
    $script:V2ConnNa = 'no tunnelling connection was opened'
    if ($tunV2) { [void](Get-V2SharedTunnel) }

    Write-Host ("  Core family version: {0}   Tunnelling family version: {1}   Tunnelling slots seen: {2}" -f `
                $script:V2CoreVer, $script:V2TunVer, $script:V2Slots.Count) -ForegroundColor DarkGray

    # ══ 06 Profiles 5.8.3.3.4 - the anchor case ════════════════════════════════════════
    # Always runs, on every device, and states in the report what the rest of the section was
    # gated on. An omitted section looks like an oversight; this one says what it decided and why.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-5.8.3.3.4' -Title 'Tunnelling Service Family version 02h is advertised' -Clause '06 Profiles 5.8.3.3.4 p.68; 03_08_02 7.5.4.3 p.26' -Body {
        Assert-KnxTrue ($null -ne $script:V2Desc) 'the device did not answer a DESCRIPTION_REQUEST'
        $txt = @()
        foreach ($f in @($script:V2Desc.Families)) { $txt += ("{0} v{1}" -f $f.Name, $f.Version) }
        Add-KnxEvidence -Received $script:V2Desc.Raw -Note ("advertised service families: " + ($txt -join ', '))
        if ($script:V2TunVer -lt 2) {
            # 5.8.3.3.4 p.68 marks version 01h with X for a v2 product and version 02h with X for a
            # v1 product: the two are alternatives, so a v1 server is conformant as a v1 server.
            # N-A with the observed version, not FAIL - the product decides which profile it claims.
            Set-KnxTestNotApplicable $script:V2TunNa
            return
        }
        Assert-KnxEqual 2 $script:V2TunVer 'Tunnelling service family version is not 02h'
    }

    # ══ 03_08_04 clause 3 - the Tunnelling Feature services ═══════════════════════════

    # ── V-3.1 : the service codes, and who confirms what ──────────────────────────────
    # Reference device: GET 0422h -> TUNNELLING_ACK 0421h channel 17 seq 0 status 00h, then
    # RESPONSE 0423h channel 17 seq 0 feature 01h return code 00h value 00 04.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-3.1' -Title 'A Tunnelling Feature service is confirmed like a TUNNELLING_REQUEST' -Clause '03_08_04 3.1 p.11; 5.4.1 Table 9 p.25' -Body {
        if (-not $tunV2) { Set-KnxTestNotApplicable $script:V2TunNa; return }
        $c = Get-V2SharedTunnel
        if ($null -eq $c) { Set-KnxTestNotApplicable $script:V2ConnNa; return }
        # Feature 08 because 06 Profiles 5.8.3.3.4.2 p.69 makes its GET mandatory for v2: a device
        # that answers nothing here is failing a clause, not declining an option.
        $r = Invoke-V2FeatureService -Connection $c -Service 0x0422 -Feature 0x08
        if (-not (Test-V2Sent $r)) { return }
        Add-KnxEvidence -Sent $r.Sent -Note ("acknowledge after {0} ms, channel {1}, sequence {2}, status 0x{3:X2}, repeated: {4}" -f $r.AckMs, $r.AckChannel, $r.AckSeq, $r.AckStatus, $r.Repeated)
        if ($null -ne $r.Raw) { Add-KnxEvidence -Received $r.Raw }
        Assert-KnxTrue ($r.AckSeq -ge 0) 'the TUNNELLING_FEATURE_GET was never confirmed; 3.1 p.11 requires the same confirmation as a TUNNELLING_REQUEST, which on UDP is a TUNNELLING_ACK'
        Assert-KnxEqual $c.Channel $r.AckChannel 'the TUNNELLING_ACK carries a different communication channel id'
        Assert-KnxEqual $r.Sequence $r.AckSeq 'the TUNNELLING_ACK carries a different sequence counter than the request it confirms'
        Assert-KnxEqual 0x00 $r.AckStatus 'the TUNNELLING_ACK for a well-formed TUNNELLING_FEATURE_GET carries an error status'
        Assert-KnxTrue $r.Responded 'no TUNNELLING_FEATURE_RESPONSE (0423h) followed the confirmed TUNNELLING_FEATURE_GET (0422h)'
        Assert-KnxEqual 0x08 $r.FeatureId 'the TUNNELLING_FEATURE_RESPONSE names a different Interface Feature than the request'
    }

    # ── V-3.2 : the response deadline ─────────────────────────────────────────────────
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-3.2' -Title 'TUNNELLING_FEATURE_RESPONSE arrives within 3 s of the confirmation' -Clause '03_08_04 3.2 p.11' -Body {
        if (-not $tunV2) { Set-KnxTestNotApplicable $script:V2TunNa; return }
        $c = Get-V2SharedTunnel
        if ($null -eq $c) { Set-KnxTestNotApplicable $script:V2ConnNa; return }
        # "The Tunnelling Server shall at the latest 3 s after confirming the
        # TUNNELLING_FEATURE_GET (see NOTE 1) respond with a TUNNELLING_FEATURE_RESPONSE" - the
        # clock starts at the CONFIRMATION, not at the request, which is why AckMs and ResponseMs
        # are measured separately. A window of 4 s is used so the case can report a device that is
        # merely late rather than timing out and reporting it as silent.
        $r = Invoke-V2FeatureService -Connection $c -Service 0x0422 -Feature 0x08 -TimeoutMs 5000
        if (-not (Test-V2Sent $r)) { return }
        Add-KnxEvidence -Note ("{0} ms to the acknowledge, {1} ms from the acknowledge to the response" -f $r.AckMs, $r.ResponseMs)
        if ($r.Repeated) {
            # 2.6.1 p.9 made the rig repeat the request. The acknowledge it timed may therefore be the
            # repeat's, while the server's three seconds ran from its confirmation of the ORIGINAL -
            # a server answering 500 ms late would be measured as comfortably inside. The reference
            # instant is unknown, so the interval cannot be held against the clause.
            Set-KnxTestNotApplicable 'the request had to be repeated, so the confirmation this interval is measured from cannot be attributed to one transmission'
            return
        }
        Assert-KnxTrue $r.Responded 'no TUNNELLING_FEATURE_RESPONSE at all within 5 s'
        Assert-KnxTrue ($r.ResponseMs -le 3000) `
            "the TUNNELLING_FEATURE_RESPONSE arrived $($r.ResponseMs) ms after the confirmation, beyond the 3 s the clause allows"
    }

    # ── V-3.6.2 .. V-3.6.9 : one GET per Interface Feature ────────────────────────────
    # Table driven, but the case body reads $script:V2Cur instead of closing over the loop
    # variable. Invoke-KnxTestCase runs the body synchronously, so the assignment right before the
    # call is what the body sees - and no .GetNewClosure() is involved, which would rebind the
    # scriptblock into a dynamic module where none of the script-scope helpers above exist. That
    # failure mode is silent: every case fails with the same message about a missing command.
    foreach ($feat in $script:V2Features) {
        $script:V2Cur = $feat
        $mand = if ($feat.GetSupport -eq 'M') { 'mandatory' } else { 'optional' }
        Invoke-KnxTestCase -Suite $SuiteTitle -Id $feat.Id `
            -Title ("Interface Feature {0:X2}h `"{1}`" is readable ({2} GET)" -f $feat.Feature, $feat.Name, $mand) `
            -Clause $feat.Clause -Body {

            $cur = $script:V2Cur
            if (-not $tunV2) { Set-KnxTestNotApplicable $script:V2TunNa; return }
            $c = Get-V2SharedTunnel
            if ($null -eq $c) { Set-KnxTestNotApplicable $script:V2ConnNa; return }

            $r = Invoke-V2FeatureService -Connection $c -Service 0x0422 -Feature $cur.Feature
            Add-KnxEvidence -Sent $r.Sent
            if ($null -ne $r.Raw) { Add-KnxEvidence -Received $r.Raw }
            if ($r.BusFrames -gt 0) { Add-KnxEvidence -Note "$($r.BusFrames) bus telegram(s) acknowledged and parked while waiting" }

            # An unconfirmed request is a finding of its own, and it must be reported before the
            # response is judged: 03_08_04 3.5 p.12 says a server WITHOUT the Feature services
            # "shall ignore this service request ... no TUNNELLING_ACK will be sent", so silence
            # here means the whole service group is missing, not this one feature.
            if ($r.AckSeq -lt 0) {
                if ($cur.GetSupport -eq 'M') {
                    Assert-KnxTrue $false ("the TUNNELLING_FEATURE_GET for feature {0:X2}h was not even acknowledged; 03_08_04 3.5 p.12 makes that the signature of a server without the Tunnelling Feature services, which 06 Profiles 5.8.3.3.4 p.68 requires for v2" -f $cur.Feature)
                }
                Set-KnxTestNotApplicable ("the device does not confirm the Tunnelling Feature services at all, and 06 Profiles 5.8.3.3.4.2 p.69 shows feature {0:X2}h as (G) - reading it is optional for v2" -f $cur.Feature)
                return
            }
            Assert-KnxEqual 0x00 $r.AckStatus 'the TUNNELLING_ACK for the TUNNELLING_FEATURE_GET carries an error status'

            if (-not $r.Responded) {
                if ($cur.GetSupport -eq 'M') {
                    Assert-KnxTrue $false ("no TUNNELLING_FEATURE_RESPONSE for feature {0:X2}h; 06 Profiles 5.8.3.3.4.2 p.69 shows G for it, so the GET shall work on a v2 server" -f $cur.Feature)
                }
                Set-KnxTestNotApplicable ("the device did not answer a GET for feature {0:X2}h; 06 Profiles 5.8.3.3.4.2 p.69 shows (G) for it, which makes reading it optional for v2" -f $cur.Feature)
                return
            }

            Assert-KnxEqual $cur.Feature $r.FeatureId 'the TUNNELLING_FEATURE_RESPONSE names a different Interface Feature than the request'
            if ($r.ReturnCode -eq $script:V2_RC_ADDRESS_VOID) {
                # 03_08_04 3.5 p.12: E_ADDRESS_VOID is the answer for "an unknown or not supported
                # Interface Feature". A server that answers it for one of the eight standard
                # features is saying it does not implement that feature.
                if ($cur.GetSupport -eq 'M') {
                    Assert-KnxTrue $false ("feature {0:X2}h answered E_ADDRESS_VOID (FDh) - not supported - although 06 Profiles 5.8.3.3.4.2 p.69 shows G for it" -f $cur.Feature)
                }
                Set-KnxTestNotApplicable ("feature {0:X2}h answered E_ADDRESS_VOID (FDh); the Profiles matrix shows (G), so not supporting it is allowed" -f $cur.Feature)
                return
            }
            Assert-KnxEqual $script:V2_RC_SUCCESS $r.ReturnCode ("the GET for feature {0:X2}h returned code 0x{1:X2} instead of E_SUCCESS" -f $cur.Feature, $r.ReturnCode)
            Assert-KnxEqual $cur.ValueOctets $r.ValueLength ("feature {0:X2}h returned {1} value octet(s) instead of {2}" -f $cur.Feature, $r.ValueLength, $cur.ValueOctets)
            Test-V2FeatureValue -Feature $cur.Feature -Value $r.Value -Connection $c
        }
    }

    # ── V-3.5a : an unknown Interface Feature ─────────────────────────────────────────
    # Reference device: feature ids 00h, 09h, 0Ah and FFh each answered 0423h with return code FDh
    # and an EMPTY value field, exactly as the clause prescribes.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-3.5a' -Title 'An unknown Interface Feature is answered E_ADDRESS_VOID with no value' -Clause '03_08_04 3.5 p.12; 03_03_07 3.4.5.5 p.78' -Body {
        if (-not $tunV2) { Set-KnxTestNotApplicable $script:V2TunNa; return }
        $c = Get-V2SharedTunnel
        if ($null -eq $c) { Set-KnxTestNotApplicable $script:V2ConnNa; return }
        # "If an unknown or not supported Interface Feature is addressed in the
        # TUNNELLING_FEATURE_SET or TUNNELLING_FEATURE_GET then the Tunnelling Server shall respond
        # with the Return Code E_ADDRESS_VOID and the field Feature Value shall be omitted."
        #
        # Two stimuli, not one: 09h is the first code past the eight defined features, and FFh is
        # the far end of the octet. A server that range-checks only upwards passes with one of them.
        foreach ($bad in @(0x09, 0xFF)) {
            $r = Invoke-V2FeatureService -Connection $c -Service 0x0422 -Feature $bad
            Add-KnxEvidence -Sent $r.Sent
            if ($null -ne $r.Raw) { Add-KnxEvidence -Received $r.Raw }
            Assert-KnxTrue $r.Responded ("no TUNNELLING_FEATURE_RESPONSE for the unknown feature id {0:X2}h; the clause requires one carrying E_ADDRESS_VOID" -f $bad)
            Assert-KnxEqual $bad $r.FeatureId ("the response to the unknown feature id {0:X2}h names a different Interface Feature" -f $bad)
            Assert-KnxEqual $script:V2_RC_ADDRESS_VOID $r.ReturnCode ("the unknown feature id {0:X2}h was answered with return code 0x{1:X2} instead of E_ADDRESS_VOID (FDh)" -f $bad, $r.ReturnCode)
            Assert-KnxEqual 0 $r.ValueLength ("the response to the unknown feature id {0:X2}h carries {1} value octet(s); the clause says the field shall be omitted" -f $bad, $r.ValueLength)
        }
    }

    # ── V-3.5b : an unknown communication channel id ──────────────────────────────────
    # Reference device: a GET on a channel that was never opened produced no acknowledge and no
    # response at all, while five bus telegrams arrived on the real channel in the same window -
    # which is exactly why this case counts SERVICES for the bogus channel and not datagrams.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-3.5b' -Title 'A Feature service on an unknown channel id is ignored, and the real channel keeps working' -Clause '03_08_04 3.5 p.12' -Body {
        if (-not $tunV2) { Set-KnxTestNotApplicable $script:V2TunNa; return }
        $c = Get-V2SharedTunnel
        if ($null -eq $c) { Set-KnxTestNotApplicable $script:V2ConnNa; return }
        # "If a Tunnelling Feature service is transported over an unknown communication channel ID,
        # then this shall be ignored."
        #
        # Invoke-V2FeatureService counts anything for a foreign channel in Foreign and never
        # acknowledges it, so Foreign is the measurement: zero means the server did not answer for
        # the bogus channel. -Channel puts the wrong id on the wire while the connection's own
        # channel stays the yardstick, and -ExpectNoResponse keeps it listening for the full window
        # instead of returning on the first frame.
        $bogus = ($c.Channel + 7) -band 0xFF
        if ($bogus -eq $c.Channel) { $bogus = ($c.Channel + 11) -band 0xFF }
        $r = Invoke-V2FeatureService -Connection $c -Service 0x0422 -Feature 0x08 -Channel $bogus -TimeoutMs 3000 -ExpectNoResponse
        Add-KnxEvidence -Sent $r.Sent -Note ("channel {0} was never opened; frames seen for it: {1}; bus telegrams on the real channel meanwhile: {2}" -f $bogus, $r.Foreign, $r.BusFrames)
        Assert-KnxEqual 0 $r.Foreign "the server answered on channel $bogus, which it never opened"
        Assert-KnxTrue (-not $r.Responded) 'the server answered a Feature service that carried an unknown communication channel id'
        Assert-KnxTrue ($r.AckSeq -lt 0) 'the server acknowledged a Feature service that carried an unknown communication channel id'

        # POSITIVE CONTROL, in this case and after the negative. Silence alone would also be
        # produced by a device that had died, by a firewall, or by a tunnel the server had already
        # dropped - and the two halves below tell those apart: the channel is alive AND the Feature
        # service is still served on it, which is more than "the socket is open".
        Assert-KnxTrue (Test-V2ChannelAlive -Connection $c) 'the tunnel was gone after the bogus-channel request, so its silence proves nothing'
        Assert-KnxTrue (Test-V2FeatureServed -Connection $c) 'the Feature service stopped working on the real channel after the bogus-channel request, so its silence proves nothing'
    }

    # ── V-3.5c : E_ACCESS_DENIED ──────────────────────────────────────────────────────
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-3.5c' -Title 'A Feature service that is not available for a feature is answered E_ACCESS_DENIED' -Clause '03_08_04 3.5 p.12; Tables 1-8 p.13-17' -Body {
        if (-not $tunV2) { Set-KnxTestNotApplicable $script:V2TunNa; return }
        # "If the requested Tunnelling Feature service is not available for the requested Interface
        # Feature then the Tunnelling Server shall respond with E_ACCESS_DENIED (FCh)."
        #
        # Walking the eight availability matrixes of 3.6.2 to 3.6.9 for Security Mode "disabled /
        # not present", which is this rig, leaves no combination that reaches this code:
        #   GET   is "available" for all eight features.
        #   SET   is "available" for 06 and 08, and for the other six the matrixes name
        #         E_ACCESS_READ_ONLY - a different code, tested by V-3.3a.
        #   INFO  is "not available" for 01, 02, 04, 05, 07 and 08, but INFO is server initiated;
        #         a Client cannot request it, so it cannot provoke a refusal.
        # With Security Mode enabled, SET on feature 06 becomes E_ACCESS_READ_ONLY too - still not
        # E_ACCESS_DENIED. The code is reachable through KNX Data Security authorisation, which this
        # suite does not establish.
        Set-KnxTestNotApplicable 'no reachable stimulus without KNX IP Secure: for Security Mode disabled the eight availability matrixes of 03_08_04 3.6.2-3.6.9 answer every client-initiable service with either "available" or E_ACCESS_READ_ONLY, and TUNNELLING_FEATURE_INFO cannot be requested by a Client'
    }

    # ══ 03_08_04 clause 3.3 - TUNNELLING_FEATURE_SET ══════════════════════════════════

    # ── V-3.3a : a read-only feature refuses the write ────────────────────────────────
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-3.3a' -Title 'Setting a read-only Interface Feature is answered E_ACCESS_READ_ONLY' -Clause '03_08_04 3.3 p.11; Table 3 p.13; 06 Profiles 5.8.3.3.4.2 EXAMPLE 1 p.69' -Body {
        if (-not $tunV2) { Set-KnxTestNotApplicable $script:V2TunNa; return }
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case attempts a TUNNELLING_FEATURE_SET'; return }
        $c = Get-V2SharedTunnel
        if ($null -eq $c) { Set-KnxTestNotApplicable $script:V2ConnNa; return }
        # Feature 03 is the canonical read-only feature, and 06 Profiles picks it out by name:
        # "For 'Bus Connection Status', 'S' (TUNNELLING_FEATURE_SET) is not indicated: it shall thus
        # not be possible to change the bus connection status with a TUNNELLING_FEATURE_SET."
        # 03_08_04 Table 3 p.13 names the code for both Security Modes: E_ACCESS_READ_ONLY.
        #
        # This write cannot take effect even if the device got it wrong - 09_03 3.5.3.4 p.33 says
        # the content "is fully controlled by the KNX USB Bus Access Server; it cannot be set by the
        # ... Client", and a bus connection is not something a value can create. The value sent is
        # the one the device already reports, so a device that wrongly accepts it changes nothing.
        $now = Invoke-V2FeatureService -Connection $c -Service 0x0422 -Feature 0x03
        $keep = if ($now.Responded -and $now.ValueLength -eq 1) { [byte[]]@($now.Value[0]) } else { [byte[]]@(0x01) }
        $r = Invoke-V2FeatureService -Connection $c -Service 0x0424 -Feature 0x03 -Value $keep
        Add-KnxEvidence -Sent $r.Sent -Note ("wrote back the value the device already reports (0x{0:X2})" -f $keep[0])
        if ($null -ne $r.Raw) { Add-KnxEvidence -Received $r.Raw }
        Assert-KnxTrue $r.Responded 'no TUNNELLING_FEATURE_RESPONSE to a TUNNELLING_FEATURE_SET on a read-only feature; 3.3 p.11 requires one carrying a Return Code'
        Assert-KnxEqual 0x03 $r.FeatureId 'the response to the refused SET names a different Interface Feature'
        Assert-KnxEqual $script:V2_RC_ACCESS_READ_ONLY $r.ReturnCode `
            ("setting feature 03h returned code 0x{0:X2} instead of E_ACCESS_READ_ONLY (FBh)" -f $r.ReturnCode)
    }

    # ── V-3.3b : a value of the wrong size ────────────────────────────────────────────
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-3.3b' -Title 'Setting a feature with a wrong value size is answered E_DATA_TYPE_CONFLICT' -Clause '03_08_04 3.3 p.11; 03_03_07 3.4.5.5 p.78' -Body {
        if (-not $tunV2) { Set-KnxTestNotApplicable $script:V2TunNa; return }
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case attempts a TUNNELLING_FEATURE_SET'; return }
        # "If the Tunnelling Client requests to set a Feature to a value with a wrong size, then the
        # Tunnelling Server shall respond with E_DATA_TYPE_CONFLICT."
        #
        # Feature 08 is the subject because it is one of the two features a v2 server must accept a
        # SET on, so a refusal here can only be about the size. Its value is one octet (DPT_Enable,
        # 3.6.9 p.16); two octets are therefore wrong by exactly the thing being tested.
        #
        # Its own connection, not the shared one: a server that wrongly ACCEPTS the malformed write
        # would leave the Info service enabled behind it, and the INFO cases further down measure
        # that exact state. Closing the connection puts it back to Disable per 3.6.9 p.17 whatever
        # happened.
        $c = Open-V2Tunnel -Ip $script:V2Ip -Port $script:V2Port
        try {
            if (-not $c.Ok) { Set-KnxTestNotApplicable "no tunnelling connection for this case (CONNECT_RESPONSE status $($c.StatusName))"; return }
            $r = Invoke-V2FeatureService -Connection $c -Service 0x0424 -Feature 0x08 -Value ([byte[]]@(0x00, 0x00))
            Add-KnxEvidence -Sent $r.Sent -Note 'two value octets for a feature whose datatype is one octet (DPT_Enable 1.003)'
            if ($null -ne $r.Raw) { Add-KnxEvidence -Received $r.Raw }
            Assert-KnxTrue $r.Responded 'no TUNNELLING_FEATURE_RESPONSE to a SET with a wrong value size'
            Assert-KnxEqual $script:V2_RC_DATA_TYPE_CONFLICT $r.ReturnCode `
                ("a two-octet value for the one-octet feature 08h returned code 0x{0:X2} instead of E_DATA_TYPE_CONFLICT (FEh)" -f $r.ReturnCode)
        }
        finally { Close-V2Tunnel $c }
    }

    # ── V-3.3c : a value that is not valid ────────────────────────────────────────────
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-3.3c' -Title 'Setting a feature to an invalid value is answered E_DATA_VOID and the value is echoed' -Clause '03_08_04 3.3 p.11' -Body {
        if (-not $tunV2) { Set-KnxTestNotApplicable $script:V2TunNa; return }
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case attempts a TUNNELLING_FEATURE_SET'; return }
        # "If the Tunnelling Client requests to set the Feature to a value that is not valid, then
        # the Tunnelling Server shall respond with E_DATA_VOID or alternatively with E_DATA_MAX or
        # E_DATA_MIN as appropriate. The field Feature Value shall repeat the Feature Value from the
        # request."
        #
        # 02h is invalid for DPT_Enable, which defines only 0 and 1 (3.6.9 p.16), and it is above
        # the range rather than below it - so E_DATA_MAX is the appropriate alternative and
        # E_DATA_MIN is not. All three are accepted because the clause offers the choice.
        #
        # Own connection for the same reason as V-3.3b: a server that accepts 02h must not leave the
        # Info service in an undefined state for the cases that follow.
        $c = Open-V2Tunnel -Ip $script:V2Ip -Port $script:V2Port
        try {
            if (-not $c.Ok) { Set-KnxTestNotApplicable "no tunnelling connection for this case (CONNECT_RESPONSE status $($c.StatusName))"; return }
            $r = Invoke-V2FeatureService -Connection $c -Service 0x0424 -Feature 0x08 -Value ([byte[]]@(0x02))
            Add-KnxEvidence -Sent $r.Sent -Note 'value 02h for DPT_Enable, which defines only 0 (Disable) and 1 (Enable)'
            if ($null -ne $r.Raw) { Add-KnxEvidence -Received $r.Raw }
            Assert-KnxTrue $r.Responded 'no TUNNELLING_FEATURE_RESPONSE to a SET with an invalid value'
            $ok = @($script:V2_RC_DATA_VOID, $script:V2_RC_DATA_MAX, $script:V2_RC_DATA_MIN)
            Assert-KnxTrue ($ok -contains $r.ReturnCode) `
                ("value 02h for feature 08h returned code 0x{0:X2}; the clause allows E_DATA_VOID (F8h), E_DATA_MAX (F7h) or E_DATA_MIN (F6h)" -f $r.ReturnCode)
            Assert-KnxEqual 1 $r.ValueLength 'the refused SET response does not repeat the one-octet Feature Value from the request'
            Assert-KnxEqual 0x02 ([int]$r.Value[0]) 'the refused SET response does not repeat the Feature Value from the request'
        }
        finally { Close-V2Tunnel $c }
    }

    # ══ 03_08_04 clause 3.6.9 - Interface Feature 08 ══════════════════════════════════

    # ── V-3.6.9d : the default after a connection opens ───────────────────────────────
    # Reference device: a GET on a freshly opened tunnel returned 00h. This case opens its own
    # connection because the shared one is written to by the cases below, and reading the default
    # off a connection somebody has already set would pass no matter what the device does.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-3.6.9d' -Title 'Interface Feature 08 is Disable on a freshly opened Tunnelling connection' -Clause '03_08_04 3.6.9 p.16 and p.17' -Body {
        if (-not $tunV2) { Set-KnxTestNotApplicable $script:V2TunNa; return }
        # "The default value shall be 'Disable'. This shall be the value after reset of the
        # interface." (p.16) and "If a Tunnelling Connection opens, the Tunnelling Server shall set
        # the value to 'Disable' for that Tunnelling Connection." (p.17)
        $c = Open-V2Tunnel -Ip $script:V2Ip -Port $script:V2Port
        try {
            if (-not $c.Ok) { Set-KnxTestNotApplicable "no tunnelling connection for this case (CONNECT_RESPONSE status $($c.StatusName))"; return }
            $r = Invoke-V2FeatureService -Connection $c -Service 0x0422 -Feature 0x08
            Add-KnxEvidence -Sent $r.Sent
            if ($null -ne $r.Raw) { Add-KnxEvidence -Received $r.Raw }
            Assert-KnxTrue $r.Responded 'a freshly opened connection did not answer a GET for feature 08h'
            Assert-KnxEqual $script:V2_RC_SUCCESS $r.ReturnCode ("the GET for feature 08h returned code 0x{0:X2}" -f $r.ReturnCode)
            Assert-KnxEqual 1 $r.ValueLength 'feature 08h did not return exactly one value octet'
            Assert-KnxEqual 0x00 ([int]$r.Value[0]) 'the Interface Feature Info service is Enabled on a connection that was just opened; the clause makes Disable the value a connection starts with'
        }
        finally { Close-V2Tunnel $c }
    }

    # ── V-3.6.9s : the SET is available and applies immediately ───────────────────────
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-3.6.9s' -Title 'Interface Feature 08 can be set to Enable and reads back Enabled' -Clause '03_08_04 3.3 p.11; 3.6.9 Table 8 p.17; 06 Profiles 5.8.3.3.4.2 p.69' -Body {
        if (-not $tunV2) { Set-KnxTestNotApplicable $script:V2TunNa; return }
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case attempts a TUNNELLING_FEATURE_SET'; return }
        # Table 8 p.17 shows SET "available" for both Security Modes, and 06 Profiles shows G/S for
        # feature 08 on v2 - so a refusal here is a failed clause. 3.3 p.11 also fixes WHEN the new
        # value takes effect: "apply the new value immediately, this is, before the
        # TUNNELLING_FEATURE_RESPONSE is sent", which is what the read-back checks.
        #
        # Own connection: leaving the shared tunnel with the Info service enabled would change what
        # the negative INFO case below measures.
        $c = Open-V2Tunnel -Ip $script:V2Ip -Port $script:V2Port
        try {
            if (-not $c.Ok) { Set-KnxTestNotApplicable "no tunnelling connection for this case (CONNECT_RESPONSE status $($c.StatusName))"; return }
            $w = Invoke-V2FeatureService -Connection $c -Service 0x0424 -Feature 0x08 -Value ([byte[]]@(0x01))
            Add-KnxEvidence -Sent $w.Sent
            if ($null -ne $w.Raw) { Add-KnxEvidence -Received $w.Raw }
            Assert-KnxTrue $w.Responded 'no TUNNELLING_FEATURE_RESPONSE to setting feature 08h to Enable'
            Assert-KnxEqual $script:V2_RC_SUCCESS $w.ReturnCode `
                ("setting feature 08h to Enable returned code 0x{0:X2}; Table 8 p.17 shows the SET as available" -f $w.ReturnCode)
            # 3.3 p.11: the response carries "the written value and a Return Code".
            Assert-KnxEqual 1 $w.ValueLength 'the response to the SET does not carry the written value'
            Assert-KnxEqual 0x01 ([int]$w.Value[0]) 'the response to the SET does not carry the value that was written'
            $r = Invoke-V2FeatureService -Connection $c -Service 0x0422 -Feature 0x08
            Assert-KnxTrue $r.Responded 'no answer to the GET that reads the new value back'
            Assert-KnxEqual 1 $r.ValueLength 'the read-back of feature 08h did not return exactly one value octet'
            Assert-KnxEqual 0x01 ([int]$r.Value[0]) 'feature 08h still reads Disable after a successful SET to Enable'
        }
        finally { Close-V2Tunnel $c }
    }

    # ── V-3.6.9p : the feature is per connection ──────────────────────────────────────
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-3.6.9p' -Title 'Interface Feature 08 is separate for each Tunnelling connection' -Clause '03_08_04 3.6.9 p.17' -Body {
        if (-not $tunV2) { Set-KnxTestNotApplicable $script:V2TunNa; return }
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case attempts a TUNNELLING_FEATURE_SET'; return }
        # "This Feature shall be implemented separately and independently for each possible
        # Tunnelling connection." A single global flag passes every other case in this group and
        # fails only this one, which is why it exists: enable it on A, and B must still read Disable.
        $a = Open-V2Tunnel -Ip $script:V2Ip -Port $script:V2Port
        $b = $null
        try {
            if (-not $a.Ok) { Set-KnxTestNotApplicable "no first tunnelling connection (CONNECT_RESPONSE status $($a.StatusName))"; return }
            $w = Invoke-V2FeatureService -Connection $a -Service 0x0424 -Feature 0x08 -Value ([byte[]]@(0x01))
            Add-KnxEvidence -Note ("connection A channel {0} address {1}: SET Enable returned 0x{2:X2}" -f $a.Channel, $a.TunnelPa, $w.ReturnCode)
            if (-not $w.Responded -or $w.ReturnCode -ne $script:V2_RC_SUCCESS) {
                Set-KnxTestNotRun -MissingInput 'a working SET on feature 08h' -Reason 'the Enable could not be set on the first connection, see V-3.6.9s'
                return
            }
            $b = Open-V2Tunnel -Ip $script:V2Ip -Port $script:V2Port
            if (-not $b.Ok) {
                Set-KnxTestNotRun -MissingInput 'a second free Tunnelling slot' -Reason "the device refused a second connection (CONNECT_RESPONSE status $($b.StatusName)), so the two connections cannot be compared"
                return
            }
            $r = Invoke-V2FeatureService -Connection $b -Service 0x0422 -Feature 0x08
            $readBack = 'nothing'
            if ($r.ValueLength -ge 1) { $readBack = "$($r.Value[0])" }
            Add-KnxEvidence -Note ("connection B channel {0} address {1}: feature 08h reads {2}" -f $b.Channel, $b.TunnelPa, $readBack)
            Assert-KnxTrue $r.Responded 'the second connection did not answer a GET for feature 08h'
            Assert-KnxEqual 1 $r.ValueLength 'the second connection did not return exactly one value octet for feature 08h'
            Assert-KnxEqual 0x00 ([int]$r.Value[0]) 'enabling the Info service on one Tunnelling connection enabled it on another; the clause requires the feature to be implemented separately per connection'
        }
        finally { Close-V2Tunnel $b; Close-V2Tunnel $a }
    }

    # ── V-3.6.9c : closing the connection resets it ───────────────────────────────────
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-3.6.9c' -Title 'Interface Feature 08 falls back to Disable when the connection closes' -Clause '03_08_04 3.6.9 p.17' -Body {
        if (-not $tunV2) { Set-KnxTestNotApplicable $script:V2TunNa; return }
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case attempts a TUNNELLING_FEATURE_SET'; return }
        # "If the Tunnelling closes, regardless of the condition, then the Tunnelling Server shall
        # set the value to 'Disable'." The teardown here is the ordinary DISCONNECT_REQUEST, which
        # is one of the conditions footnote 3 p.17 lists.
        #
        # The reopened connection must land on the SAME tunnelling address, or the case would only
        # prove that a different slot starts disabled - which V-3.6.9d already covers. An Extended
        # CRI makes that explicit instead of hoping the server reuses the slot.
        $a = Open-V2Tunnel -Ip $script:V2Ip -Port $script:V2Port
        $addr = -1
        try {
            if (-not $a.Ok) { Set-KnxTestNotApplicable "no tunnelling connection for this case (CONNECT_RESPONSE status $($a.StatusName))"; return }
            $addr = $a.TunnelPaRaw
            $w = Invoke-V2FeatureService -Connection $a -Service 0x0424 -Feature 0x08 -Value ([byte[]]@(0x01))
            if (-not $w.Responded -or $w.ReturnCode -ne $script:V2_RC_SUCCESS) {
                Set-KnxTestNotRun -MissingInput 'a working SET on feature 08h' -Reason 'the Enable could not be set before closing, see V-3.6.9s'
                return
            }
            Add-KnxEvidence -Note ("Info service enabled on channel {0}, address {1}, then the connection was closed" -f $a.Channel, $a.TunnelPa)
        }
        finally { Close-V2Tunnel $a }
        $b = Open-V2Tunnel -Ip $script:V2Ip -Port $script:V2Port -IndividualAddress $addr
        try {
            if (-not $b.Ok) {
                Set-KnxTestNotRun -MissingInput 'the same Tunnelling address again' -Reason "the device would not hand out $(ConvertFrom-KnxPa -Raw $addr) a second time (CONNECT_RESPONSE status $($b.StatusName))"
                return
            }
            $r = Invoke-V2FeatureService -Connection $b -Service 0x0422 -Feature 0x08
            Add-KnxEvidence -Note ("reopened on channel {0}, address {1}" -f $b.Channel, $b.TunnelPa)
            Assert-KnxTrue $r.Responded 'the reopened connection did not answer a GET for feature 08h'
            Assert-KnxEqual 1 $r.ValueLength 'the reopened connection did not return exactly one value octet for feature 08h'
            Assert-KnxEqual 0x00 ([int]$r.Value[0]) 'the Info service was still Enabled after the connection had been closed and reopened on the same address'
        }
        finally { Close-V2Tunnel $b }
    }

    # ══ 03_08_04 clause 3.4 / 3.6.4 - TUNNELLING_FEATURE_INFO ═════════════════════════

    # ── V-3.4 : nothing spontaneous while the Info service is Disabled ────────────────
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-3.4' -Title 'No TUNNELLING_FEATURE_INFO is sent while Interface Feature 08 is Disable' -Clause '03_08_04 3.4 p.11; 3.6.9 p.16' -Body {
        if (-not $tunV2) { Set-KnxTestNotApplicable $script:V2TunNa; return }
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - the positive control of this case writes feature 08h'; return }
        # "The Tunnelling Server shall only send the TUNNELLING_FEATURE_INFO if the Interface Feature
        # 'Interface Feature Info Service Enable' has the value 'Enable'." (3.4 p.11) and "If the
        # value has the value 'Disable' then the Interface shall not send or immediately stop sending
        # any TUNNELLING_FEATURE_INFO." (3.6.9 p.16)
        #
        # The negative half is a listening window on a connection that has never been written to, so
        # feature 08 is at its opening default. A live bus fills that window with TUNNELLING_REQUESTs
        # and those get acknowledged and parked, so what is measured is the number of 0425h frames
        # and nothing else.
        #
        # POSITIVE CONTROL, after the negative and in the same case: a window with nothing in it is
        # also what a dead device, a closed channel and a wedged feature layer produce. So the case
        # goes on to prove the channel is alive, that the feature layer still answers, and - the part
        # that makes the silence mean something - that the server DOES start sending INFO once
        # feature 08 is Enabled. Without that last step the case would pass against a server that
        # has no INFO service at all, which is precisely what 06 Profiles 5.8.3.3.4.2 p.69 forbids
        # for features 03 and 06.
        if (-not $script:V2SrxOk -or $script:V2Slots.Count -lt 2) {
            Set-KnxTestNotRun -MissingInput 'a Tunnelling Information DIB with a second free slot' `
                              -Reason 'the positive control needs a second free Tunnelling address of this device to provoke an INFO with; without it the quiet window would prove nothing'
            return
        }
        $c = Open-V2Tunnel -Ip $script:V2Ip -Port $script:V2Port
        try {
            if (-not $c.Ok) { Set-KnxTestNotApplicable "no tunnelling connection for this case (CONNECT_RESPONSE status $($c.StatusName))"; return }
            $probe = Invoke-V2FeatureService -Connection $c -Service 0x0422 -Feature 0x08
            if (-not $probe.Responded -or $probe.ValueLength -lt 1) {
                Set-KnxTestNotApplicable 'feature 08h cannot be read, so the state this case depends on is unknown - see V-3.6.9'
                return
            }
            Assert-KnxEqual 0x00 ([int]$probe.Value[0]) 'this connection does not start with the Info service Disabled, so the quiet window below would prove nothing - see V-3.6.9d'

            # A GET whose answer is not waited for, purely to keep the listening window long enough: the
            # window has to be long enough for an implementation that reports periodically rather
            # than on change. Three seconds is the same order as the 3 s response deadline of 3.2.
            $quiet = Invoke-V2FeatureService -Connection $c -Service 0x0422 -Feature 0x03 -TimeoutMs 3000 -ExpectNoResponse
            Add-KnxEvidence -Note ("3 s window with the Info service Disabled: {0} TUNNELLING_FEATURE_INFO, {1} bus telegram(s)" -f $quiet.Infos.Count, $quiet.BusFrames)
            Assert-KnxEqual 0 $quiet.Infos.Count 'the server sent a TUNNELLING_FEATURE_INFO although the Interface Feature Info service is Disabled on this connection'

            Assert-KnxTrue (Test-V2ChannelAlive -Connection $c) 'the channel was gone during the quiet window, so its silence proves nothing'
            Assert-KnxTrue (Test-V2FeatureServed -Connection $c) 'the Feature service stopped answering during the quiet window, so its silence proves nothing'

            # THE CONTROL THAT TURNS THE SILENCE INTO A STATEMENT ABOUT THE ENABLE FLAG.
            # Without it the case also passes against a server that has no INFO service at all -
            # which 06 Profiles 5.8.3.3.4.2 p.69 forbids for features 03 and 06 (both carry I).
            # So after the quiet window the flag is Enabled and the SAME kind of stimulus has to
            # produce what it did not produce before.
            #
            # The stimulus is a change of the Tunnelling address, because feature 06 is the only
            # evented feature a client can trigger at all - feature 03 needs the KNX line pulled
            # (V-3.6.4i). It has to be a DIFFERENT address: 3.6.7 p.15 conditions the E_DATA_VOID
            # check on "requests setting a different IA", so writing back the address the
            # connection already holds is a case the clause does not describe and a server may
            # legitimately treat as a no-op with nothing to event. The address comes from the
            # device's own Tunnelling Information DIB, free and usable bits included, so nothing
            # that belongs to a real device on the line is ever claimed.
            $target = -1
            foreach ($slot in $script:V2Slots) {
                if ($slot.Raw -ne $c.TunnelPaRaw -and $slot.Free -and $slot.Usable) { $target = $slot.Raw; break }
            }
            if ($target -lt 0) {
                Set-KnxTestNotRun -MissingInput 'a second free Tunnelling address' `
                                  -Reason 'the device publishes no second free Tunnelling Slot, so no INFO can be provoked and the quiet window cannot be attributed to the Info service being Disabled'
                return
            }
            $w = Invoke-V2FeatureService -Connection $c -Service 0x0424 -Feature 0x08 -Value ([byte[]]@(0x01))
            Assert-KnxTrue ($w.Responded -and $w.ReturnCode -eq $script:V2_RC_SUCCESS) `
                'the Info service could not be Enabled, so the quiet window cannot be attributed to it being Disabled - see V-3.6.9s'
            $move = Invoke-V2FeatureService -Connection $c -Service 0x0424 -Feature 0x06 `
                        -Value ([byte[]]@((($target -shr 8) -band 0xFF), ($target -band 0xFF))) -TimeoutMs 5000 -ExpectNoResponse
            $infos = @($move.Infos)
            Add-KnxEvidence -Note ("with the Info service Enabled, moving the connection from {0} to {1} produced {2} TUNNELLING_FEATURE_INFO" -f $c.TunnelPa, (ConvertFrom-KnxPa -Raw $target), $infos.Count)
            # Put the address back before anything else can fail. The slot is per connection and the
            # teardown resets it, but a server that persists the assignment would leave the rig
            # changed, and a restore that only runs on the happy path is not a restore.
            [void](Invoke-V2FeatureService -Connection $c -Service 0x0424 -Feature 0x06 `
                        -Value ([byte[]]@((($c.TunnelPaRaw -shr 8) -band 0xFF), ($c.TunnelPaRaw -band 0xFF))))
            if ($infos.Count -eq 0) {
                # NOT a FAIL of this case. The clause under test is "nothing while Disabled", and a
                # missing event while Enabled is V-3.6.7i's finding, not this one's. But the quiet
                # window is then unproven, so the case must not claim a pass either.
                Set-KnxTestNotRun -MissingInput 'an observable TUNNELLING_FEATURE_INFO' `
                                  -Reason 'the server sent no INFO even with feature 08h Enabled and the Tunnelling address changed, so the quiet window while Disabled cannot be attributed to the Enable flag - see V-3.6.7i'
                return
            }
        }
        finally { Close-V2Tunnel $c }
    }

    # ── V-3.6.7i : the Tunnelling address change is evented ───────────────────────────
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-3.6.7i' -Title 'A change of the Interface Individual Address is reported with TUNNELLING_FEATURE_INFO' -Clause '03_08_04 3.6.7 p.15; 06 Profiles 5.8.3.3.4.2 p.69' -Body {
        if (-not $tunV2) { Set-KnxTestNotApplicable $script:V2TunNa; return }
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case changes the Tunnelling address of a connection'; return }
        # 3.6.7 p.15, TUNNELLING_FEATURE_INFO: "The Tunnelling IA shall also be evented with the
        # TUNNELLING_FEATURE_INFO service, to allow for the following. ... It signals to the
        # Tunnelling Client the success of an own preceding change of the IA over a
        # TUNNELLING_FEATURE_SET, this is, the moment at which the new IA becomes effective."
        # 06 Profiles shows G/S/I for feature 06 on v2, so the INFO is mandatory, not optional.
        #
        # THE ADDRESS IS NOT INVENTED. 3.6.7 p.15 puts a duty on the client first: "Prior to changing
        # the IA of a Tunnelling connection, the Tunnelling Client shall check whether the intended
        # IA is free in the target KNX network. The Tunnelling Client shall not set an IA as
        # Tunnelling IA that is occupied in the KNX network." The Tunnelling Information DIB is the
        # device's own statement about which addresses it offers for tunnelling and which of them are
        # free (03_08_02 7.5.4.8 p.29, bits F and U), so the target is taken from there - never a
        # hand-picked address, which could collide with a real device on the line.
        if (-not $script:V2SrxOk -or $script:V2Slots.Count -lt 2) {
            Set-KnxTestNotRun -MissingInput 'a Tunnelling Information DIB with a second free slot' -Reason 'without the device''s own list of free Tunnelling addresses there is no address that is safe to write'
            return
        }
        $c = Open-V2Tunnel -Ip $script:V2Ip -Port $script:V2Port
        try {
            if (-not $c.Ok) { Set-KnxTestNotApplicable "no tunnelling connection for this case (CONNECT_RESPONSE status $($c.StatusName))"; return }
            $target = -1
            foreach ($s in $script:V2Slots) {
                if ($s.Raw -ne $c.TunnelPaRaw -and $s.Free -and $s.Usable) { $target = $s.Raw; break }
            }
            if ($target -lt 0) {
                Set-KnxTestNotRun -MissingInput 'a second free Tunnelling address' -Reason 'every other Tunnelling Slot of this device is in use or not usable right now'
                return
            }
            $w = Invoke-V2FeatureService -Connection $c -Service 0x0424 -Feature 0x08 -Value ([byte[]]@(0x01))
            if (-not $w.Responded -or $w.ReturnCode -ne $script:V2_RC_SUCCESS) {
                Set-KnxTestNotRun -MissingInput 'a working SET on feature 08h' -Reason 'the INFO service could not be Enabled, and 3.4 p.11 forbids the server to send INFO while it is Disabled - see V-3.6.9s'
                return
            }
            $val = [byte[]]@((($target -shr 8) -band 0xFF), ($target -band 0xFF))
            $r = Invoke-V2FeatureService -Connection $c -Service 0x0424 -Feature 0x06 -Value $val -TimeoutMs 5000 -NoEarlyBreak
            Add-KnxEvidence -Sent $r.Sent -Note ("moved the connection from {0} to {1}; {2} TUNNELLING_FEATURE_INFO seen" -f $c.TunnelPa, (ConvertFrom-KnxPa -Raw $target), ("{0} total, {1} for feature 06h" -f @($r.Infos).Count, @($r.Infos | Where-Object { $_.FeatureId -eq 0x06 }).Count))
            if ($null -ne $r.Raw) { Add-KnxEvidence -Received $r.Raw }
            Assert-KnxTrue $r.Responded 'no TUNNELLING_FEATURE_RESPONSE to the SET of feature 06h'
            Assert-KnxEqual $script:V2_RC_SUCCESS $r.ReturnCode `
                ("setting feature 06h to a free Tunnelling address of this device returned code 0x{0:X2}; Table 6 p.15 shows the SET as available with Security Mode disabled" -f $r.ReturnCode)
            $hit = @($r.Infos | Where-Object { $_.FeatureId -eq 0x06 })
            Assert-KnxTrue ($hit.Count -ge 1) 'the address change was accepted but not evented with a TUNNELLING_FEATURE_INFO for feature 06h'
            Assert-KnxEqual 2 $hit[0].Value.Length 'the TUNNELLING_FEATURE_INFO for feature 06h does not carry a two-octet Individual Address'
            Assert-KnxEqual $target (Get-Uint16 -Bytes $hit[0].Value -Offset 0) `
                'the TUNNELLING_FEATURE_INFO reports an address other than the one that was set'
            # Put it back. The slot is per connection and the teardown below resets it anyway, but a
            # server that persists the assignment would otherwise leave the rig changed.
            $back = [byte[]]@((($c.TunnelPaRaw -shr 8) -band 0xFF), ($c.TunnelPaRaw -band 0xFF))
            [void](Invoke-V2FeatureService -Connection $c -Service 0x0424 -Feature 0x06 -Value $back)
        }
        finally { Close-V2Tunnel $c }
    }

    # ── V-3.6.7e : an address the server already uses is refused ──────────────────────
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-3.6.7e' -Title 'Setting the Interface Individual Address to the host device address is answered E_DATA_VOID' -Clause '03_08_04 3.6.7 p.15' -Body {
        if (-not $tunV2) { Set-KnxTestNotApplicable $script:V2TunNa; return }
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case attempts a TUNNELLING_FEATURE_SET'; return }
        # "If the requested IA is contained in PID_ADDITIONAL_INDIVIDUAL_ADDRESSES or if the
        # requested IA equals the IA of the host device then the Return Code in the
        # TUNNELLING_FEATURE_RESPONSE shall be E_DATA_VOID; the Feature Identifier and the Feature
        # Value shall be copied from the request."
        #
        # The host device address comes from the Device Information DIB of this very device, so the
        # case cannot be pointed at the wrong address by a rig change. The write must be REFUSED, so
        # nothing is altered even on a device that answers the wrong code - but it is still a write
        # attempt and stays behind the ReadOnly gate.
        if ($script:V2HostIa -lt 0) {
            Set-KnxTestNotRun -MissingInput 'the Device Information DIB' -Reason 'the host device Individual Address could not be read, so there is no address that is known to be occupied'
            return
        }
        $c = Open-V2Tunnel -Ip $script:V2Ip -Port $script:V2Port
        try {
            if (-not $c.Ok) { Set-KnxTestNotApplicable "no tunnelling connection for this case (CONNECT_RESPONSE status $($c.StatusName))"; return }
            $val = [byte[]]@((($script:V2HostIa -shr 8) -band 0xFF), ($script:V2HostIa -band 0xFF))
            $r = Invoke-V2FeatureService -Connection $c -Service 0x0424 -Feature 0x06 -Value $val
            Add-KnxEvidence -Sent $r.Sent -Note ("requested the host device address {0}" -f (ConvertFrom-KnxPa -Raw $script:V2HostIa))
            if ($null -ne $r.Raw) { Add-KnxEvidence -Received $r.Raw }
            Assert-KnxTrue $r.Responded 'no TUNNELLING_FEATURE_RESPONSE to a SET of feature 06h to the host device address'
            Assert-KnxEqual $script:V2_RC_DATA_VOID $r.ReturnCode `
                ("setting feature 06h to the host device address returned code 0x{0:X2} instead of E_DATA_VOID (F8h)" -f $r.ReturnCode)
            Assert-KnxEqual 0x06 $r.FeatureId 'the refused response does not copy the Feature Identifier from the request'
            Assert-KnxEqual 2 $r.ValueLength 'the refused response does not copy the two-octet Feature Value from the request'
            Assert-KnxEqual $script:V2HostIa (Get-Uint16 -Bytes $r.Value -Offset 0) 'the refused response does not copy the Feature Value from the request'
        }
        finally { Close-V2Tunnel $c }
    }

    # ── V-3.6.4i : the bus connection status event ────────────────────────────────────
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-3.6.4i' -Title 'A change of the bus connection status is reported with TUNNELLING_FEATURE_INFO' -Clause '03_08_04 3.6.4 Table 3 p.13; 09_03 3.5.3.4 p.33; 06 Profiles 5.8.3.3.4.2 p.69' -Body {
        if (-not $tunV2) { Set-KnxTestNotApplicable $script:V2TunNa; return }
        # 09_03 3.5.3.4 p.33: "The KNX USB Bus Access Server shall send a Device Feature Info Frame
        # on every change of this value", Info = Mandatory p.34, and 06 Profiles shows G/I for
        # feature 03 on v2. 03_08_04 Table 3 p.13 confirms INFO is "available" for it.
        #
        # THE STIMULUS CANNOT BE PRODUCED OVER IP. The value only changes when the KNX line is
        # actually interrupted - 09_03 NOTE 1 p.33: "It is not possible for a KNX USB Bus Access
        # Client (software) to connect or disconnect from the KNX network over this property."
        # Reading 'Active' and calling that a pass would be a case that can never fail, so the case
        # reports the missing step by name instead. 06 Profiles 5.8.3.3.4.2 footnote a p.69 also
        # allows skipping it outright on a TP1-powered device, which loses power with the line.
        #
        # The automatable half of feature 03 - that it reads back a valid DPT_State and agrees with
        # the Medium Status the device publishes in its Extended Device Information DIB - is asserted
        # by V-3.6.4.
        Set-KnxTestNotRun -MissingInput 'an operator step that interrupts the KNX line while the suite listens' `
                          -Reason 'the bus connection status only changes when the KNX line is physically interrupted (09_03 3.5.3.4 NOTE 1 p.33); 06 Profiles 5.8.3.3.4.2 footnote a p.69 allows skipping this test on a TP1-powered device'
    }

    # ══ 03_08_04 clause 5.4.3 - the Extended CRI ══════════════════════════════════════

    # ── V-5.4.3.2 : the structure, and the address it asks for is the address it gets ──
    # Reference device: cri 06 04 02 00 50 BD -> CONNECT_RESPONSE status 00h, CRD 04 04 50 BD.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-5.4.3.2' -Title 'An Extended CRI requesting a free Tunnelling address is accepted and the CRD echoes it' -Clause '03_08_04 5.4.3.2 p.26; 5.4.4 p.30; 06 Profiles 5.8.3.3.4 p.68' -Body {
        if (-not $tunV2) { Set-KnxTestNotApplicable $script:V2TunNa; return }
        # 5.4.3.2 Figure 5 p.26: structure length 06h, TUNNEL_CONNECTION 04h, KNX layer, one
        # reserved octet, two octets of Individual Address. 06 Profiles 5.8.3.3.4 p.68 marks the
        # Extended CRI M for a v2 server, so a refusal of the whole form is a failed clause.
        #
        # The address is the device's own: taken from the Tunnelling Information DIB, which
        # 03_08_02 7.5.4.8 p.29 defines as the list of addresses assigned to the Tunnelling Slots
        # with a Free and a Usable bit each. Requesting anything else would test the error path,
        # which V-5.4.3.3.2-6 does on purpose.
        if (-not $script:V2SrxOk -or $script:V2Slots.Count -lt 1) {
            Set-KnxTestNotRun -MissingInput 'a Tunnelling Information DIB' -Reason 'without the device''s own list of Tunnelling addresses there is no address that is known to be a valid Tunnelling address'
            return
        }
        $free = -1
        foreach ($s in $script:V2Slots) { if ($s.Free -and $s.Usable) { $free = $s.Raw; break } }
        if ($free -lt 0) {
            Set-KnxTestNotRun -MissingInput 'a free Tunnelling Slot' -Reason 'every Tunnelling Slot the device publishes is currently occupied or not usable'
            return
        }
        $c = Open-V2Tunnel -Ip $script:V2Ip -Port $script:V2Port -IndividualAddress $free
        try {
            Add-KnxEvidence -Sent $c.Cri -Note ("Extended CRI for {0}" -f (ConvertFrom-KnxPa -Raw $free))
            if ($null -ne $c.Response) { Add-KnxEvidence -Received $c.Response }
            Assert-KnxTrue ($c.Status -ge 0) 'the device did not answer a CONNECT_REQUEST carrying an Extended CRI at all'
            Assert-KnxEqual 0x00 $c.Status ("a free Tunnelling address was refused with $($c.StatusName); 06 Profiles 5.8.3.3.4 p.68 makes the Extended CRI mandatory for a v2 server")
            # 5.4.4 Figure 7 p.30: the CRD carries the Individual Address assigned to this
            # connection. Requesting one and being given another is the failure this asserts.
            Assert-KnxTrue ($c.TunnelPaRaw -ge 0) 'the CONNECT_RESPONSE carries no Tunnelling CRD with an Individual Address'
            Assert-KnxEqual $free $c.TunnelPaRaw `
                ("the Extended CRI requested {0} but the CRD assigned {1}" -f (ConvertFrom-KnxPa -Raw $free), $c.TunnelPa)
        }
        finally { Close-V2Tunnel $c }
    }

    # ── V-5.4.3.3.2-6 : E_NO_TUNNELLING_ADDRESS ───────────────────────────────────────
    # Reference device: the host address 5.0.14 -> 2Dh, an unused 0.15.254 -> 2Dh, 0.0.0 -> 2Dh.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-5.4.3.3.2-6' -Title 'An Extended CRI for an address that is not a Tunnelling address is refused E_NO_TUNNELLING_ADDRESS' -Clause '03_08_04 5.4.3.3.2 step 6 p.28; 03_08_02 Table 8 p.39' -Body {
        if (-not $tunV2) { Set-KnxTestNotApplicable $script:V2TunNa; return }
        # Step 6 p.28: "It shall be evaluated if IArequest is explicitly defined to be a Tunnelling
        # Address." EXAMPLE 1 names the two ways the test fails, and both are driven here:
        #   A. "It is one of the Additional Individual Addresses of the Tunnelling host device, but
        #      is not a Tunnelling Address" - the host device address itself is the sharpest form of
        #      an address the device owns but does not offer for tunnelling.
        #   B. "The address is nowhere used in the device."
        # "E_NO_TUNNELLING_ADDRESS shall mean that the requested IA is no IA that has been assigned
        # for Tunnelling to the requested Client." Value 2Dh per 03_08_02 Table 8 p.39.
        #
        # Link layer throughout, deliberately. Step 4.a p.28 sits before step 6 in the flow chart of
        # Figure 6 p.27, so an unsupported layer would mask the address check - measured on the
        # reference device, which answered E_TUNNELLING_LAYER for a busmonitor request whose address
        # was in use. V-5.4.3.3.2-4 tests that path on its own.
        if ($script:V2HostIa -lt 0) {
            Set-KnxTestNotRun -MissingInput 'the Device Information DIB' -Reason 'the host device Individual Address could not be read, so case A of EXAMPLE 1 cannot be driven'
            return
        }
        # Case A always runs: the host device address is read from this device's own Device
        # Information DIB and step 6 is unambiguous about it.
        $stimuli = @(
            @{ Ia = $script:V2HostIa; What = 'the host device Individual Address (EXAMPLE 1 case A)' }
        )
        # Case B needs an address that is provably NOT one of this device's Tunnelling addresses,
        # and only the Tunnelling Information DIB can prove that. Without it, 0.15.254 is a guess -
        # and if the guess happened to be a Tunnelling address of the device, the device would
        # correctly answer E_NO_ERROR or E_CONNECTION_IN_USE and this case would report a
        # conformant server as broken. So case B is driven only when the list is in hand; the
        # evidence says which halves ran, rather than the report implying both did.
        if ($script:V2SrxOk -and $script:V2Slots.Count -gt 0) {
            $unused = 0x0FFE
            $taken = @()
            foreach ($s in $script:V2Slots) { $taken += $s.Raw }
            while (($taken -contains $unused) -or ($unused -eq $script:V2HostIa)) { $unused-- }
            $stimuli += @{ Ia = $unused; What = 'an address nowhere used in the device (EXAMPLE 1 case B)' }
        }
        else {
            Add-KnxEvidence -Note 'EXAMPLE 1 case B not driven: without a Tunnelling Information DIB no address can be shown to be absent from the device''s Tunnelling addresses'
        }
        foreach ($st in $stimuli) {
            $c = Open-V2Tunnel -Ip $script:V2Ip -Port $script:V2Port -IndividualAddress $st.Ia
            try {
                Add-KnxEvidence -Sent $c.Cri -Note ("{0}: {1} -> {2}" -f $st.What, (ConvertFrom-KnxPa -Raw $st.Ia), $c.StatusName)
                Assert-KnxTrue ($c.Status -ge 0) ("the device did not answer an Extended CRI for {0}" -f (ConvertFrom-KnxPa -Raw $st.Ia))
                Assert-KnxTrue ($c.Status -ne 0x00) `
                    ("the device ACCEPTED {0} as a Tunnelling address although it is {1}" -f (ConvertFrom-KnxPa -Raw $st.Ia), $st.What)
                Assert-KnxEqual $script:V2_E_NO_TUNNELLING_ADDRESS $c.Status `
                    ("{0} was refused with status 0x{1:X2} instead of E_NO_TUNNELLING_ADDRESS (2Dh)" -f $st.What, $c.Status)
            }
            finally { Close-V2Tunnel $c }
        }
    }

    # ── V-5.4.3.3.2-8 : E_CONNECTION_IN_USE ───────────────────────────────────────────
    # Reference device: holding 5.0.189 and asking for it again -> 2Eh, and the first connection
    # still answered CONNECTIONSTATE_REQUEST with 00h.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-5.4.3.3.2-8' -Title 'An Extended CRI for a Tunnelling address that is in use is refused E_CONNECTION_IN_USE' -Clause '03_08_04 5.4.3.3.2 step 8 p.29; 03_08_02 Table 8 p.39' -Body {
        if (-not $tunV2) { Set-KnxTestNotApplicable $script:V2TunNa; return }
        # Step 8 p.29: "If the requested IA is available and the Client is authorised to use it, but
        # it is in use for another Tunnelling connection, by another or by the same client, then the
        # Tunnelling server shall respond with E_CONNECTION_IN_USE." - "by the same client" is what
        # makes this testable from one host. Value 2Eh per 03_08_02 Table 8 p.39.
        if (-not $script:V2SrxOk -or $script:V2Slots.Count -lt 1) {
            Set-KnxTestNotRun -MissingInput 'a Tunnelling Information DIB' -Reason 'without the device''s own list of Tunnelling addresses there is no address that is known to be a valid Tunnelling address'
            return
        }
        $free = -1
        foreach ($s in $script:V2Slots) { if ($s.Free -and $s.Usable) { $free = $s.Raw; break } }
        if ($free -lt 0) {
            Set-KnxTestNotRun -MissingInput 'a free Tunnelling Slot' -Reason 'every Tunnelling Slot the device publishes is currently occupied or not usable'
            return
        }
        $first = Open-V2Tunnel -Ip $script:V2Ip -Port $script:V2Port -IndividualAddress $free
        try {
            if (-not $first.Ok) {
                Set-KnxTestNotRun -MissingInput 'a Tunnelling Slot that can be held' -Reason "the address the device publishes as free was refused with $($first.StatusName), so there is nothing to hold - see V-5.4.3.2"
                return
            }
            $second = Open-V2Tunnel -Ip $script:V2Ip -Port $script:V2Port -IndividualAddress $free
            try {
                Add-KnxEvidence -Sent $second.Cri -Note ("{0} held on channel {1}, requested again -> {2}" -f (ConvertFrom-KnxPa -Raw $free), $first.Channel, $second.StatusName)
                Assert-KnxTrue ($second.Status -ge 0) 'the device did not answer the second Extended CRI for an address it had just handed out'
                Assert-KnxTrue ($second.Status -ne 0x00) `
                    ("the device handed out {0} twice; step 8 p.29 requires a refusal when the address is in use, also for the same client" -f (ConvertFrom-KnxPa -Raw $free))
                Assert-KnxEqual $script:V2_E_CONNECTION_IN_USE $second.Status `
                    ("the second request for {0} was refused with status 0x{1:X2} instead of E_CONNECTION_IN_USE (2Eh)" -f (ConvertFrom-KnxPa -Raw $free), $second.Status)
            }
            finally { Close-V2Tunnel $second }

            # POSITIVE CONTROL, after the negative and in the same case. A device that had dropped
            # the first connection while answering the second would produce the same 2Eh for the
            # wrong reason, and a device that had died would produce no answer that could be
            # distinguished from a refusal by a parser that only looks at "not 00h". Both halves:
            # the first channel is still there, and the Feature service still runs on it.
            Assert-KnxTrue (Test-V2ChannelAlive -Connection $first) `
                'the connection that was supposed to be holding the address was gone, so the refusal cannot be attributed to the address being in use'
            Assert-KnxTrue (Test-V2FeatureServed -Connection $first) `
                'the held connection stopped being served, so it was not a working connection occupying the address'
        }
        finally { Close-V2Tunnel $first }
    }

    # ── V-5.4.3.3.2-4 : layer refusal on an Extended CRI ──────────────────────────────
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-5.4.3.3.2-4' -Title 'An Extended CRI with an unsupported Tunnelling layer is refused' -Clause '03_08_04 step 4.a: Figure 6 p.27 and text p.28' -Body {
        if (-not $tunV2) { Set-KnxTestNotApplicable $script:V2TunNa; return }
        # Step 4.a: Figure 6 p.27 leads to E_CONNECTION_OPTION (23h), the text p.28 to E_TUNNELLING_LAYER (29h, Table 11 p.26); both are accepted, the one used is recorded. Layer 03h is not defined in Table 10 p.26, so no device supports it and the case cannot turn into a missing-busmonitor finding, which would be a different one (TUNNEL_RAW and TUNNEL_BUSMONITOR are O in 03_08_04 7.2 p.35).
        # A FREE address is requested: steps 4.a and 6 both refuse and Figure 6 p.27 puts 4.a first, so an unusable address would assert an ordering rather than the clause; with a free address only the layer can refuse.
        if (-not $script:V2SrxOk -or $script:V2Slots.Count -lt 1) {
            Set-KnxTestNotRun -MissingInput 'a Tunnelling Information DIB' -Reason 'without a known-good Tunnelling address the refusal could not be attributed to the layer'
            return
        }
        $free = -1
        foreach ($s in $script:V2Slots) { if ($s.Free -and $s.Usable) { $free = $s.Raw; break } }
        if ($free -lt 0) {
            Set-KnxTestNotRun -MissingInput 'a free Tunnelling Slot' -Reason 'every Tunnelling Slot the device publishes is currently occupied or not usable'
            return
        }
        $c = Open-V2Tunnel -Ip $script:V2Ip -Port $script:V2Port -IndividualAddress $free -Layer 0x03
        try {
            Add-KnxEvidence -Sent $c.Cri -Note ("KNX layer 03h is not defined in Table 10 p.26; address {0} is published as free -> {1}" -f (ConvertFrom-KnxPa -Raw $free), $c.StatusName)
            Assert-KnxTrue ($c.Status -ge 0) 'the device did not answer an Extended CRI carrying an undefined KNX layer'
            Assert-KnxTrue ($c.Status -ne 0x00) 'the device accepted a KNX layer that 03_08_04 Table 10 p.26 does not define'
            Assert-KnxTrue (@($script:V2_E_CONNECTION_OPTION, $script:V2_E_TUNNELLING_LAYER) -contains $c.Status) `
                ("an undefined KNX layer was refused with status 0x{0:X2} instead of E_CONNECTION_OPTION (23h) or E_TUNNELLING_LAYER (29h)" -f $c.Status)
        }
        finally { Close-V2Tunnel $c }
    }

    # ── V-5.4.3.3.2-7 : E_AUTHORISATION_ERROR ─────────────────────────────────────────
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-5.4.3.3.2-7' -Title 'An Extended CRI for a Tunnelling address the Client may not use is refused E_AUTHORISATION_ERROR' -Clause '03_08_04 5.4.3.3.2 step 2 p.28 and step 7 p.29; 03_08_02 Table 8 p.39' -Body {
        if (-not $tunV2) { Set-KnxTestNotApplicable $script:V2TunNa; return }
        # Step 7 p.29 is a two-by-two table, and only ONE cell yields 28h: "Secured Service? Yes"
        # crossed with "Client Authorised to use IArequest? No". The footnote closes the other
        # dimension for a plain run: "Client authorised to use IArequest can only be evaluated in a
        # Secure Session. Outside a Secure Session, this shall be 'no'." So with Tunnelling a secured
        # service family and no Secure Session, every Extended CRI would be refused 28h - and with
        # Tunnelling NOT a secured service family the whole row reads "continue" and 28h is
        # unreachable, whatever the client does.
        #
        # Which of the two it is comes from the DEVICE, not from knowing that Secure is off in this
        # rig: step 2 p.28 names PID_SECURED_SERVICE_FAMILIES and the Security Version, and the
        # Secured Service Families DIB (06h) of a SEARCH_RESPONSE_EXTENDED is that same statement on
        # the wire. Reference device: the DIB listed only family 03h (Device Management) with
        # Security Version 1, so Tunnelling is not secured there and this case is N-A.
        if (-not $script:V2SrxOk) {
            Set-KnxTestNotRun -MissingInput 'a SEARCH_RESPONSE_EXTENDED' -Reason 'without the Secured Service Families DIB it cannot be decided whether E_AUTHORISATION_ERROR is reachable at all'
            return
        }
        $sdib = Get-V2Dib -Dibs $script:V2SrxDibs -Type 0x06
        $secured = Test-V2SecuredTunnelling -Dibs $script:V2SrxDibs
        if ($null -ne $sdib) { Add-KnxEvidence -Note ("Secured Service Families DIB: " + (ConvertTo-HexString -Bytes $sdib.Payload)) }
        else { Add-KnxEvidence -Note 'the device sends no Secured Service Families DIB' }
        if (-not $secured) {
            Set-KnxTestNotApplicable 'the device does not declare KNXnet/IP Tunnelling as a secured service family, and 03_08_04 5.4.3.3.2 step 7 p.29 then answers "continue" in both columns - E_AUTHORISATION_ERROR has no reachable stimulus'
            return
        }
        Set-KnxTestNotRun -MissingInput 'a KNX IP Secure session' `
                          -Reason 'the device declares Tunnelling as a secured service family, so this case needs a Secure Session with a User ID that is not linked to the requested Tunnelling Address; this suite establishes no Secure Session'
    }

    # ══ 03_08_02 clause 7.6.3 - SEARCH_REQUEST_EXTENDED and the SRPs ══════════════════

    # ── V-7.6.3.1 : the service works and the basic DIB set is there ──────────────────
    # Reference device: 020Bh with no SRP -> one 020Ch of 160 octets carrying DIBs
    # 01h, 02h, 08h, 03h, 04h, 05h, 06h and 07h.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-7.6.3.1' -Title 'SEARCH_REQUEST_EXTENDED at the control endpoint is answered with the basic DIB set' -Clause '03_08_02 7.6.3.1 p.33; 7.6.3.3.6 p.35' -Body {
        if (-not $coreV2) { Set-KnxTestNotApplicable $script:V2CoreNa; return }
        # 7.6.3.1 p.33: "The SEARCH_REQUEST_EXTENDED Frame shall be sent by a KNXnet/IP Client to
        # either the discovery endpoints of any listening KNXnet/IP Servers or to the control
        # endpoint of a specific KNXnet/IP Server." The control endpoint is used here so exactly one
        # device can answer.
        #
        # 7.6.3.3.6 p.35: "If no 'Request DIBs' SRP is present in the request, the KNXnet/IP Server
        # shall at least report the basic set of DIBs consisting of the 'Device Information DIB',
        # 'Extended Device Information DIB' and 'Supported Services DIB'."
        $r = Invoke-V2SearchExtended -TimeoutMs 2500
        Add-KnxEvidence -Sent $r.Sent
        Assert-KnxTrue $r.Answered 'no SEARCH_RESPONSE_EXTENDED (020Ch) to a SEARCH_REQUEST_EXTENDED (020Bh) without SRPs'
        Add-KnxEvidence -Received ([byte[]]$r.Frames[0])
        $dibs = @(Get-V2SrxDibs -Body ([byte[]]$r.Bodies[0]))
        $names = @()
        foreach ($d in $dibs) { $names += ("{0:X2}h {1}" -f $d.Type, $d.TypeName) }
        Add-KnxEvidence -Note ("DIBs in the response: " + ($names -join ', '))
        Assert-KnxTrue ($dibs.Count -gt 0) 'the SEARCH_RESPONSE_EXTENDED carries no parseable DIB; the DIB block starts after the 8 octet control endpoint HPAI'
        Assert-KnxTrue ($null -ne (Get-V2Dib -Dibs $dibs -Type 0x01)) 'the basic DIB set is incomplete: no Device Information DIB (01h)'
        Assert-KnxTrue ($null -ne (Get-V2Dib -Dibs $dibs -Type 0x02)) 'the basic DIB set is incomplete: no Supported Service Families DIB (02h)'
        Assert-KnxTrue ($null -ne (Get-V2Dib -Dibs $dibs -Type 0x08)) 'the basic DIB set is incomplete: no Extended Device Information DIB (08h)'
    }

    # ── V-7.6.3.3.1 : THE M BIT - the central case of this group ──────────────────────
    # Reference device: SRP 02 80 (type 00h, M set) -> silence; SRP 02 00 (same type, M clear) on
    # the SAME socket -> 020Ch. One bit, two behaviours, one device, one path.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-7.6.3.3.1' -Title 'An unsupported SRP with the M bit set makes the server keep silent, without it the server answers' -Clause '03_08_02 7.6.3.3.1 p.34; 7.6.3.3.2 p.34' -Body {
        if (-not $coreV2) { Set-KnxTestNotApplicable $script:V2CoreNa; return }
        # 7.6.3.3.1 p.34, for an SRP the server does not support:
        #   "If the M (Mandatory) bit is set, the server shall not respond to the search request."
        #   "If the M (Mandatory) bit is not set, the server shall ignore this SRP and react as if
        #    this SRP were not present."
        # 7.6.3.3.2 p.34 supplies a type code that is guaranteed to be unsupported and says so
        # outright: "The KNXnet/IP Server shall handle an SRP with the invalid code 00h as any other
        # unknown SRP code" and NOTE 4 "The invalid code 00h serves to test the behaviour of the
        # server for unknown SRPs."
        #
        # SILENCE IS NOT THE MEASUREMENT. Both halves run on ONE socket, the negative first, and the
        # only difference between the two frames is bit 7 of a single octet. That is what excludes
        # every other explanation for the silence: a device that is off, a device that never had the
        # service, a blocked path, an address the answer could not reach. If the control answers on
        # the same socket, the device was there and willing - it chose not to answer the first frame.
        $sock = New-KnxSocket -TimeoutMs 2500
        try {
            $srp = New-V2Srp -Type $script:V2_SRP_INVALID -Mandatory
            $neg = Invoke-V2SearchExtended -Srps $srp -TimeoutMs 2500 -Socket $sock
            Add-KnxEvidence -Sent $neg.Sent -Note ("SRP " + (ConvertTo-HexString -Bytes $srp) + " (type 00h, M set): " + $neg.Frames.Count + " SEARCH_RESPONSE_EXTENDED")
            if ($neg.Other.Count -gt 0) { Add-KnxEvidence -Note ("other services seen meanwhile: " + (($neg.Other | Select-Object -Unique) -join ', ')) }
            Assert-KnxTrue (-not $neg.Answered) 'the server answered a SEARCH_REQUEST_EXTENDED that carried an unsupported SRP with the M bit set'

            $srpCtl = New-V2Srp -Type $script:V2_SRP_INVALID
            $pos = Invoke-V2SearchExtended -Srps $srpCtl -TimeoutMs 2500 -Socket $sock
            Add-KnxEvidence -Note ("control, SRP " + (ConvertTo-HexString -Bytes $srpCtl) + " (same type, M clear): " + $pos.Frames.Count + " SEARCH_RESPONSE_EXTENDED")
            Assert-KnxTrue $pos.Answered `
                'the server did not answer the same SRP with the M bit cleared either, so the silence above says nothing about the M bit - the clause requires the SRP to be ignored and the request answered as if it were not present'
        }
        finally { $sock.Dispose() }
    }

    # ── V-7.6.3.3.2 : a reserved type code behaves the same way ───────────────────────
    # Reference device: SRP 02 FF (type 7Fh, M set) -> silence; with M clear -> 020Ch.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-7.6.3.3.2' -Title 'A reserved SRP type code is treated like any unknown SRP' -Clause '03_08_02 7.6.3.3.2 Table 6 p.34' -Body {
        if (-not $coreV2) { Set-KnxTestNotApplicable $script:V2CoreNa; return }
        # Table 6 p.34 reserves 05h to 7Fh. A server that special-cases only the invalid code 00h
        # passes V-7.6.3.3.1 and fails here, which is the whole reason for a second type code. 7Fh is
        # the top of the reserved range, so it also proves the type field is masked to seven bits
        # rather than compared against the whole octet - a server that compares the raw octet sees
        # FFh, matches nothing, and may take a different branch.
        $sock = New-KnxSocket -TimeoutMs 2500
        try {
            $srp = New-V2Srp -Type 0x7F -Mandatory
            $neg = Invoke-V2SearchExtended -Srps $srp -TimeoutMs 2500 -Socket $sock
            Add-KnxEvidence -Sent $neg.Sent -Note ("SRP " + (ConvertTo-HexString -Bytes $srp) + " (reserved type 7Fh, M set): " + $neg.Frames.Count + " answer(s)")
            Assert-KnxTrue (-not $neg.Answered) 'the server answered a SEARCH_REQUEST_EXTENDED carrying a reserved SRP type code with the M bit set'
            $pos = Invoke-V2SearchExtended -Srps (New-V2Srp -Type 0x7F) -TimeoutMs 2500 -Socket $sock
            Add-KnxEvidence -Note ("control, reserved type 7Fh with M clear: " + $pos.Frames.Count + " answer(s)")
            Assert-KnxTrue $pos.Answered 'the server did not answer a reserved SRP type code with the M bit cleared either, so the silence above proves nothing'
        }
        finally { $sock.Dispose() }
    }

    # ── V-7.6.3.3.3 : Select By Programming Mode ──────────────────────────────────────
    # Reference device, programming mode off: SRP 02 81 -> silence.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-7.6.3.3.3' -Title 'Select By Programming Mode SRP selects on the programming mode the device reports' -Clause '03_08_02 7.6.3.3.3 p.34' -Body {
        if (-not $coreV2) { Set-KnxTestNotApplicable $script:V2CoreNa; return }
        # 7.6.3.3.3 p.34: "If Programming Mode is not enabled in the KNXnet/IP Server then it shall
        # not respond to this search request."
        #
        # The expectation is taken from the device's own Device Information DIB (03_08_02 7.5.4.2
        # p.24, Device Status bit 0), so the case is meaningful in both states and neither state
        # needs to be forced. Programming mode is not switched on here on purpose: that is a write,
        # it is section 4's case, and a suite that leaves a device in programming mode is a hazard.
        if ($null -eq $script:V2Desc) { Set-KnxTestNotRun -MissingInput 'a DESCRIPTION_RESPONSE' -Reason 'the programming mode of the device could not be read, so there is no expectation to check against'; return }
        $sock = New-KnxSocket -TimeoutMs 2500
        try {
            $srp = New-V2Srp -Type $script:V2_SRP_PROGMODE -Mandatory
            $r = Invoke-V2SearchExtended -Srps $srp -TimeoutMs 2500 -Socket $sock
            Add-KnxEvidence -Sent $r.Sent -Note ("Device Information DIB reports programming mode " + $(if ($script:V2ProgMode) { 'ON' } else { 'OFF' }) + "; answers: " + $r.Frames.Count)
            if ($script:V2ProgMode) {
                Assert-KnxTrue $r.Answered 'the device reports programming mode enabled but did not answer a Select By Programming Mode SRP'
            }
            else {
                Assert-KnxTrue (-not $r.Answered) 'the device reports programming mode disabled but answered a Select By Programming Mode SRP anyway'
                # The control: without the SRP the same socket must get an answer, which is what
                # separates "programming mode is off" from "this device does not answer us".
                $pos = Invoke-V2SearchExtended -TimeoutMs 2500 -Socket $sock
                Add-KnxEvidence -Note ("control, no SRP at all: " + $pos.Frames.Count + " answer(s)")
                Assert-KnxTrue $pos.Answered 'the device did not answer a SEARCH_REQUEST_EXTENDED without any SRP either, so the silence above proves nothing about the programming mode'
            }
        }
        finally { $sock.Dispose() }
    }

    # ── V-7.6.3.3.4 : Select By MAC Address ───────────────────────────────────────────
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-7.6.3.3.4' -Title 'Select By MAC Address SRP answers for the own MAC and keeps silent for another' -Clause '03_08_02 7.6.3.3.4 p.34' -Body {
        if (-not $coreV2) { Set-KnxTestNotApplicable $script:V2CoreNa; return }
        # 7.6.3.3.4 p.34: "If the KNXnet/IP Server's MAC address is different from the given MAC
        # address then it shall not respond to this search request."
        #
        # Both MACs come from the device: its own out of the Device Information DIB, and the foreign
        # one by flipping the low bit of the last octet. That keeps the negative one bit away from
        # the positive - a random MAC would leave open whether the server rejected the address or
        # choked on the SRP.
        if ($null -eq $script:V2Mac) { Set-KnxTestNotRun -MissingInput 'the Device Information DIB' -Reason 'the MAC address of the device could not be read, so no SRP can be built from it'; return }
        $sock = New-KnxSocket -TimeoutMs 2500
        try {
            $mine = [byte[]]$script:V2Mac
            $pos = Invoke-V2SearchExtended -Srps (New-V2Srp -Type $script:V2_SRP_MAC -Data $mine -Mandatory) -TimeoutMs 2500 -Socket $sock
            Add-KnxEvidence -Note ("own MAC " + (ConvertTo-HexString -Bytes $mine) + ": " + $pos.Frames.Count + " answer(s)")
            Assert-KnxTrue $pos.Answered 'the server did not answer a Select By MAC Address SRP carrying its own MAC address'

            $other = [byte[]]@($mine[0], $mine[1], $mine[2], $mine[3], $mine[4], ($mine[5] -bxor 0x01))
            $neg = Invoke-V2SearchExtended -Srps (New-V2Srp -Type $script:V2_SRP_MAC -Data $other -Mandatory) -TimeoutMs 2500 -Socket $sock
            Add-KnxEvidence -Sent $neg.Sent -Note ("foreign MAC " + (ConvertTo-HexString -Bytes $other) + ": " + $neg.Frames.Count + " answer(s)")
            Assert-KnxTrue (-not $neg.Answered) 'the server answered a Select By MAC Address SRP that named a MAC address other than its own'

            # The positive half ran first here, so it already proves the path - but it ran BEFORE the
            # negative, and a device that dies in between would still pass. Repeated after, on the
            # same socket, the control covers the window the negative actually sat in.
            $again = Invoke-V2SearchExtended -Srps (New-V2Srp -Type $script:V2_SRP_MAC -Data $mine -Mandatory) -TimeoutMs 2500 -Socket $sock
            Add-KnxEvidence -Note ("control after the negative, own MAC again: " + $again.Frames.Count + " answer(s)")
            Assert-KnxTrue $again.Answered 'the server stopped answering its own MAC address after the foreign one, so the silence in between proves nothing'
        }
        finally { $sock.Dispose() }
    }

    # ── V-7.6.3.3.5 : Select By Service ───────────────────────────────────────────────
    # Reference device: (Tunnelling, min 2) -> 020Ch; (Tunnelling, min 99) -> silence.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-7.6.3.3.5' -Title 'Select By Service SRP answers for a supported family version and keeps silent for a higher one' -Clause '03_08_02 7.6.3.3.5 p.35' -Body {
        if (-not $coreV2) { Set-KnxTestNotApplicable $script:V2CoreNa; return }
        # 7.6.3.3.5 p.35: "If the KNXnet/IP Server does not support the given service family or
        # supports the given service family only in a lower version then it shall not respond to this
        # search request."
        #
        # The family asked for is Tunnelling and the minimum version is the one the device itself
        # advertises, so the positive half cannot fail for the wrong reason on a v1 tunnelling server
        # that happens to be Core v2. The negative half asks for FFh of the same family, which no
        # device can satisfy - only the version octet differs between the two frames.
        if ($script:V2TunVer -lt 1) { Set-KnxTestNotRun -MissingInput 'an advertised Tunnelling service family' -Reason 'the device advertises no Tunnelling family, so there is no version to select on'; return }
        $sock = New-KnxSocket -TimeoutMs 2500
        try {
            $pos = Invoke-V2SearchExtended -Srps (New-V2Srp -Type $script:V2_SRP_SERVICE -Data ([byte[]]@(0x04, $script:V2TunVer)) -Mandatory) -TimeoutMs 2500 -Socket $sock
            Add-KnxEvidence -Note ("Tunnelling family, minimum version {0}: {1} answer(s)" -f $script:V2TunVer, $pos.Frames.Count)
            Assert-KnxTrue $pos.Answered ("the server did not answer a Select By Service SRP for the Tunnelling family at the very version it advertises (0$($script:V2TunVer)h)")

            $neg = Invoke-V2SearchExtended -Srps (New-V2Srp -Type $script:V2_SRP_SERVICE -Data ([byte[]]@(0x04, 0xFF)) -Mandatory) -TimeoutMs 2500 -Socket $sock
            Add-KnxEvidence -Sent $neg.Sent -Note ("Tunnelling family, minimum version 255: " + $neg.Frames.Count + " answer(s)")
            Assert-KnxTrue (-not $neg.Answered) 'the server answered a Select By Service SRP that demanded a Tunnelling family version far above the one it advertises'

            $again = Invoke-V2SearchExtended -Srps (New-V2Srp -Type $script:V2_SRP_SERVICE -Data ([byte[]]@(0x04, $script:V2TunVer)) -Mandatory) -TimeoutMs 2500 -Socket $sock
            Add-KnxEvidence -Note ("control after the negative: " + $again.Frames.Count + " answer(s)")
            Assert-KnxTrue $again.Answered 'the server stopped answering the satisfiable version after the unsatisfiable one, so the silence in between proves nothing'
        }
        finally { $sock.Dispose() }
    }

    # ── V-7.6.3.3.6 : Request DIBs ────────────────────────────────────────────────────
    # Reference device: 04 84 07 00 (M set) -> 020Ch including DIB 07h; 04 04 63 00 (unknown
    # description type 63h) -> 020Ch as well.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-7.6.3.3.6' -Title 'Request DIBs SRP delivers the requested DIB and never suppresses the answer' -Clause '03_08_02 7.6.3.3.6 p.35' -Body {
        if (-not $coreV2) { Set-KnxTestNotApplicable $script:V2CoreNa; return }
        # 7.6.3.3.6 p.35 says three things and all three are checked:
        #   "This SRP shall not influence the decision of the KNXnet/IP Server whether or not to
        #    respond to the search request." - so even with the M bit set it must answer.
        #   "If a Request DIBs SRP is present ... shall at least report the set of DIBs that are
        #    listed in the SRP and that are supported by the server."
        #   "The server shall ignore Description types that are not recognized or not supported."
        #
        # The DIB asked for is the Tunnelling Information DIB (07h), because 03_08_02 Table 4 p.30
        # allows it only in a SEARCH_RESPONSE_EXTENDED - it is the one DIB that cannot be obtained
        # any other way. The odd count is padded with Description Type 0 as the clause requires.
        $sock = New-KnxSocket -TimeoutMs 2500
        try {
            $r = Invoke-V2SearchExtended -Srps (New-V2Srp -Type $script:V2_SRP_DIBS -Data ([byte[]]@(0x07, 0x00)) -Mandatory) -TimeoutMs 2500 -Socket $sock
            Add-KnxEvidence -Sent $r.Sent
            Assert-KnxTrue $r.Answered 'the server did not answer a Request DIBs SRP with the M bit set; the clause says this SRP shall not influence whether the server responds'
            $dibs = @(Get-V2SrxDibs -Body ([byte[]]$r.Bodies[0]))
            $tdib = Get-V2Dib -Dibs $dibs -Type 0x07
            Add-KnxEvidence -Received ([byte[]]$r.Frames[0]) -Note ("Tunnelling Information DIB present: " + ($null -ne $tdib))
            Assert-KnxTrue ($null -ne $tdib) 'the Tunnelling Information DIB (07h) was requested by an SRP and is not in the response, although a v2 Tunnelling server has Tunnelling Slots to report'

            # An unrecognised Description Type must be ignored, not turned into silence or an error.
            $u = Invoke-V2SearchExtended -Srps (New-V2Srp -Type $script:V2_SRP_DIBS -Data ([byte[]]@(0x63, 0x00))) -TimeoutMs 2500 -Socket $sock
            Add-KnxEvidence -Note ("Request DIBs for the unrecognised description type 63h: " + $u.Frames.Count + " answer(s)")
            Assert-KnxTrue $u.Answered 'the server did not answer a Request DIBs SRP that listed an unrecognised Description Type; the clause requires such types to be ignored'
        }
        finally { $sock.Dispose() }
    }

    # ── V-7.6.4.2 : the response itself ───────────────────────────────────────────────
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-7.6.4.2' -Title 'SEARCH_RESPONSE_EXTENDED carries each DIB once and a UDP control endpoint' -Clause '03_08_02 7.6.4.1 p.35 and p.36; 7.6.4.2 Figure 32 p.36' -Body {
        if (-not $coreV2) { Set-KnxTestNotApplicable $script:V2CoreNa; return }
        # p.36: "The KNXnet/IP Server may report the DIBs in the response in any order. Each DIB
        # shall be present only once in the response." and "KNXnet/IP Servers supporting TCP shall
        # only report the UDP address of their control endpoint in the SEARCH_RESPONSE_EXTENDED
        # Frame." The second sentence is unconditional in effect: the host protocol code of the
        # control endpoint HPAI must be IPV4_UDP (01h), whether the device serves TCP or not.
        $r = Invoke-V2SearchExtended -TimeoutMs 2500
        Add-KnxEvidence -Sent $r.Sent
        Assert-KnxTrue $r.Answered 'no SEARCH_RESPONSE_EXTENDED to judge'
        Add-KnxEvidence -Received ([byte[]]$r.Frames[0])
        $body = [byte[]]$r.Bodies[0]
        Assert-KnxTrue ($body.Length -ge 8) 'the SEARCH_RESPONSE_EXTENDED body is too short to hold the control endpoint HPAI'
        Assert-KnxEqual 0x08 ([int]$body[0]) 'the control endpoint HPAI of the SEARCH_RESPONSE_EXTENDED does not have the structure length 08h'
        Add-KnxEvidence -Note ("control endpoint HPAI: " + (ConvertTo-HexString -Bytes ([byte[]]$body[0..7])))
        Assert-KnxEqual 0x01 ([int]$body[1]) 'the control endpoint of the SEARCH_RESPONSE_EXTENDED is not reported as IPV4_UDP (01h)'

        $dibs = @(Get-V2SrxDibs -Body $body)
        $seen = @{}
        $dup = @()
        foreach ($d in $dibs) {
            $k = [string]$d.Type
            if ($seen.ContainsKey($k)) { $dup += ("{0:X2}h" -f $d.Type) } else { $seen[$k] = 1 }
        }
        Add-KnxEvidence -Note ("{0} DIB(s), {1} distinct type(s)" -f $dibs.Count, $seen.Count)
        Assert-KnxEqual 0 $dup.Count ("the SEARCH_RESPONSE_EXTENDED repeats DIB type(s) " + ($dup -join ', ') + "; each DIB shall be present only once")
    }

    # ══ 03_08_02 clause 7.5.4.8 / 7.5.4.9 - the two v2 DIBs ═══════════════════════════

    # ── V-7.5.4.8 : the Tunnelling Information DIB ────────────────────────────────────
    # Reference device: 00 D2 | 50 C0 FF FE | 50 BF FF FF | 50 BE FF FF | 50 BD FF FF - four slots,
    # reserved bits all 1, and the slot the suite was holding read F=0 while the other three read
    # F=1. That is the observation this case turns into an assertion.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-7.5.4.8' -Title 'Tunnelling Information DIB describes the Tunnelling Slots and tracks the one in use' -Clause '03_08_02 7.5.4.8 p.28; Figure 21 and 22 p.29; Table 4 p.30' -Body {
        if (-not $coreV2) { Set-KnxTestNotApplicable $script:V2CoreNa; return }
        if (-not $tunV2) { Set-KnxTestNotApplicable $script:V2TunNa; return }
        # A tunnel is opened FIRST and held for the duration of the case, so the Free bit has
        # something to be wrong about. Reading the DIB with nothing connected can only ever see all
        # slots free, which no implementation can fail.
        $c = Open-V2Tunnel -Ip $script:V2Ip -Port $script:V2Port
        try {
            if (-not $c.Ok) { Set-KnxTestNotApplicable "no tunnelling connection to occupy a slot with (CONNECT_RESPONSE status $($c.StatusName))"; return }
            $r = Invoke-V2SearchExtended -TimeoutMs 2500
            Assert-KnxTrue $r.Answered 'no SEARCH_RESPONSE_EXTENDED, so the Tunnelling Information DIB cannot be read - Table 4 p.30 forbids it in every other message'
            $dibs = @(Get-V2SrxDibs -Body ([byte[]]$r.Bodies[0]))
            $tdib = Get-V2Dib -Dibs $dibs -Type 0x07
            Assert-KnxTrue ($null -ne $tdib) 'the device advertises Tunnelling but sends no Tunnelling Information DIB (07h) in its SEARCH_RESPONSE_EXTENDED'
            Add-KnxEvidence -Received $tdib.Payload

            # 7.5.4.8 p.28: two octets of APDU-length, then a list of 4 octet elements. So the
            # payload length is 2 + 4n, and anything else is a malformed DIB rather than a slot list
            # that happens to parse.
            Assert-KnxTrue ($tdib.Payload.Length -ge 6) 'the Tunnelling Information DIB is too short for the APDU-length field and one Tunnelling Slot'
            Assert-KnxEqual 0 (($tdib.Payload.Length - 2) % 4) `
                ("the Tunnelling Information DIB payload is $($tdib.Payload.Length) octets; 7.5.4.8 p.28 requires two octets of APDU-length plus a whole number of 4 octet Tunnelling Slots")

            $apdu = Get-V2ApduLengthFromDib -Dib $tdib
            Add-KnxEvidence -Note "APDU-length for bus access = $apdu"
            Assert-KnxTrue ($apdu -ge 15) "the APDU-length for bus access reads $apdu, below the 15 octets a standard frame already needs"

            $slots = @(Get-V2TunnellingSlots -Dib $tdib)
            $held = $null
            foreach ($s in $slots) {
                Add-KnxEvidence -Note ("slot {0} status 0x{1:X4} free={2} authorised={3} usable={4}" -f $s.Address, $s.Status, $s.Free, $s.Authorised, $s.Usable)
                # Figure 22 p.29, bits 15 to 3: "These fields are reserved. The Server shall set
                # these fields to 1." NOTE 1 gives the reason - all bits set has to mean usable, so
                # a server that clears the reserved bits breaks the encoding's own invariant.
                Assert-KnxEqual 0x1FFF $s.Reserved `
                    ("slot {0} has reserved status bits 0x{1:X4}; 7.5.4.8 Figure 22 p.29 requires bits 15 to 3 to be set to 1" -f $s.Address, $s.Reserved)
                if ($s.Raw -eq $c.TunnelPaRaw) { $held = $s }
            }
            Assert-KnxTrue ($slots.Count -ge 1) 'the Tunnelling Information DIB lists no Tunnelling Slot at all'
            # The address this suite is holding must appear in the list - the CRD handed it out as a
            # Tunnelling address, so the DIB has to know it - and it must not be reported free.
            Assert-KnxTrue ($null -ne $held) `
                ("the connection was given {0} but no Tunnelling Slot of the DIB carries that address" -f $c.TunnelPa)
            Assert-KnxTrue (-not $held.Free) `
                ("Tunnelling Slot {0} is reported free while this suite holds a connection on it (channel {1})" -f $c.TunnelPa, $c.Channel)
        }
        finally { Close-V2Tunnel $c }

        # Table 4 p.30: the Tunnelling Information DIB is "Not allowed" in a SEARCH_RESPONSE and in
        # a DESCRIPTION_RESPONSE. The DESCRIPTION_RESPONSE is the one this suite already has in hand.
        if ($null -ne $script:V2Desc) {
            $wrong = Get-V2Dib -Dibs $script:V2Desc.Dibs -Type 0x07
            Assert-KnxTrue ($null -eq $wrong) 'the DESCRIPTION_RESPONSE carries a Tunnelling Information DIB; 03_08_02 Table 4 p.30 does not allow it there'
        }
    }

    # ── V-7.5.4.9 : the Extended Device Information DIB ───────────────────────────────
    # Reference device: 00 00 00 D2 00 12 - medium status 00h, reserved 00h, local APDU 210, DD0
    # 0012h, and its DESCRIPTION_RESPONSE carried no 08h DIB at all, as Table 5 p.31 requires.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'V-7.5.4.9' -Title 'Extended Device Information DIB is well formed and only appears where it is allowed' -Clause '03_08_02 7.5.4.9 p.30 and p.31; Table 5 p.31' -Body {
        if (-not $coreV2) { Set-KnxTestNotApplicable $script:V2CoreNa; return }
        $r = Invoke-V2SearchExtended -TimeoutMs 2500
        Assert-KnxTrue $r.Answered 'no SEARCH_RESPONSE_EXTENDED, so the Extended Device Information DIB cannot be read'
        $dibs = @(Get-V2SrxDibs -Body ([byte[]]$r.Bodies[0]))
        $ext = Get-V2Dib -Dibs $dibs -Type 0x08
        Assert-KnxTrue ($null -ne $ext) 'the SEARCH_RESPONSE_EXTENDED carries no Extended Device Information DIB (08h), which 7.6.3.3.6 p.35 counts in the basic set'
        Add-KnxEvidence -Received $ext.Payload
        # Figure 23 p.30: medium status, one reserved octet that "= 00h", two octets of Maximal
        # Local APDU length, two octets of Device Descriptor Type 0 - eight octets with the header.
        Assert-KnxEqual 8 $ext.Length 'the Extended Device Information DIB is not the 8 octets Figure 23 p.30 defines'
        Assert-KnxEqual 0x00 ([int]$ext.Payload[1]) 'the reserved octet of the Extended Device Information DIB is not 00h'
        $localApdu = Get-Uint16 -Bytes $ext.Payload -Offset 2
        $dd0 = Get-Uint16 -Bytes $ext.Payload -Offset 4
        Add-KnxEvidence -Note ("medium status 0x{0:X2}, maximal local APDU length {1}, Device Descriptor Type 0 0x{2:X4}" -f $ext.Payload[0], $localApdu, $dd0)
        # p.31: "This shall be the maximal APDU length that is supported by the KNXnet/IP device",
        # identical to PID_MAX_LOCAL_APDU_LENGTH. 15 is the floor a standard frame already needs.
        Assert-KnxTrue ($localApdu -ge 15) "the maximal local APDU length reads $localApdu, below the 15 octets a standard frame already needs"
        Assert-KnxTrue ($dd0 -ne 0) 'the Device Descriptor Type 0 of the Extended Device Information DIB reads 0000h, which is not a mask version'
        # p.31 ties the field to PID_DEVICE_DESCRIPTOR (PID 83). The runner has already read that
        # property into $Ctx.MaskVersion, so the two statements can be compared without a second
        # device-management connection.
        $maskText = '0x{0:X4}' -f $dd0
        if ($Ctx.MaskVersion -and $Ctx.MaskVersion -like '0x*') {
            Assert-KnxEqual $Ctx.MaskVersion $maskText `
                'the Device Descriptor of the Extended Device Information DIB and PID_DEVICE_DESCRIPTOR report different mask versions'
        }
        else { Add-KnxEvidence -Note "PID_DEVICE_DESCRIPTOR was not available to cross-check against (runner reported '$($Ctx.MaskVersion)')" }

        # Table 5 p.31: "Not allowed" in a DESCRIPTION_RESPONSE. Suite 8 relies on the same sentence
        # to justify reading the mask from PID 83 instead of from the DIB; this is the case that
        # actually checks it.
        if ($null -ne $script:V2Desc) {
            $wrong = Get-V2Dib -Dibs $script:V2Desc.Dibs -Type 0x08
            Assert-KnxTrue ($null -eq $wrong) 'the DESCRIPTION_RESPONSE carries an Extended Device Information DIB; 03_08_02 Table 5 p.31 does not allow it there'
        }
    }

    # ── the shared tunnel goes back ───────────────────────────────────────────────────
    # A section that leaves a channel open costs the next section a slot, and a tunnel pool does not
    # free one the moment a client stops talking.
    if ($null -ne $script:V2Conn) { Close-V2Tunnel $script:V2Conn; $script:V2Conn = $null }
}
