#!/usr/bin/env pwsh
# Open ■
# ┬────┴  9-Tcp.Tests
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/Suites/9-Tcp.Tests.ps1

<#
.SYNOPSIS
    KNXnet/IP over TCP - transport, frame synchronization and connection lifetime.

.DESCRIPTION
    Dot-sourced by Invoke-Conformance.ps1, which then calls Invoke-KnxSuiteTcp.

    The section number 9 continues the report ordering; the cases do NOT come from TSSH.
    TSSH v1.3 contains no TCP case at all - the word does not occur in its 164 pages. Every
    TCP case lives in 08_TSSK section 2.5 (31 cases, function ids 10701..10731), which is
    the KNXnet/IP SECURITY test specification. That is a fact worth stating in the report
    rather than hiding in a commit message: TCP has no coverage in the regular conformance
    test specification, so a device can be certified without a single TCP case being run.
    These cases therefore assert against the normative clauses in 03_08_02 Core 8.4.3
    directly, with the TSSK case they correspond to named for traceability.

    WHY A DEVICE WITHOUT TCP IS NOT A FAILURE
    03_08_02 Core 8.4.1 p.43: "KNXnet/IP devices shall support UDP. The reliability
    advantages of TCP may be supported in addition to UDP. TCP support in KNXnet/IP devices
    is optional." A device that refuses the TCP connect is conformant. The suite probes once
    and reports every case N-A with that reason instead of a wall of red - and the moment
    the product serves TCP, the same file starts demanding real behaviour. Same pattern as
    8-IpMedium.

    WHY THE ROUTE BACK HPAI IS BUILT, NOT PASSED IN
    03_08_02 Core 8.6.2.1 Table 10 p.49: "For the host protocol code IPV4_TCP only the
    special 'Route Back' encoding is allowed. All other encodings are invalid and result in
    discarding the containing KNXnet/IP Frame." There is nothing legitimate to vary, so
    New-KnxTcpRouteBackHpai takes no parameters. K-2.5.21 is the case that walks the
    invalid combinations on purpose.

    VERIFIED AGAINST A REFERENCE DEVICE
    The transport helpers and cases K-2.5.1, K-2.5.2 and K-2.5.9 were first run against a
    certified MDT SCN-IP000.03 (Core v2 / DeviceManagement v2 / Tunnelling v2, Secure
    disabled) before being pointed at an OpenKNX device. A case that is green on a
    certified device and red here describes a difference in the product, not a bug in the
    case. Any new case added to this file should earn its place the same way.

    NOT YET IMPLEMENTED (tranche 2, deliberately named rather than silently missing):
      K-2.5.13/15/23/25/27/28  inner KNX connection lifetime inside one TCP connection
      K-2.5.19/20              sequence counter ignored, no TUNNELLING_ACK on TCP
      K-2.5.22                 UDP side of the HPAI restrictions (needs the UDP helpers)
      K-2.5.29                 DeviceConfigurationRequest with invalid cEMI
      K-2.5.30/31              connections closed by restart (destructive)
    Secure-only and not applicable without KNX IP Secure: K-2.5.14, K-2.5.16, K-2.5.24,
    K-2.5.26.
#>

Set-StrictMode -Version Latest


# ── helpers at script scope ────────────────────────────────────────────────────────────
# Deliberately NOT nested inside Invoke-KnxSuiteTcp: a case body is a scriptblock, and a
# helper defined inside the suite function is not reliably visible from it. The suite file
# is dot-sourced by the runner, so script-scope functions are in scope everywhere.

$script:TcpIp = ''
$script:TcpPort = 3671
$script:TcpServed = $false
$script:TcpNa = ''

function New-TcpFrame([int]$Service, [byte[]]$Body) {
    $total = 6 + $Body.Length
    return [byte[]]@(0x06, 0x10, [byte](($Service -shr 8) -band 0xFF), [byte]($Service -band 0xFF),
                     [byte](($total -shr 8) -band 0xFF), [byte]($total -band 0xFF)) + $Body
}
function New-TcpConnectRequest {
    $rb = New-KnxTcpRouteBackHpai
    # CRI: length 4, TUNNEL_CONNECTION 04h, KNX layer 02h (Link Layer), reserved.
    # 03_08_04 Tunnelling 5.4.3.1 Fig.4 p.26.
    return New-TcpFrame 0x0205 ($rb + $rb + [byte[]]@(0x04, 0x04, 0x02, 0x00))
}
function New-TcpDescriptionRequest { return New-TcpFrame 0x0203 (New-KnxTcpRouteBackHpai) }
function New-TcpDisconnectRequest([byte]$Channel) {
    return New-TcpFrame 0x0209 ([byte[]]@($Channel, 0x00) + (New-KnxTcpRouteBackHpai))
}
function New-TcpSession { return New-KnxTcpSession -Ip $script:TcpIp -Port $script:TcpPort }
# "Still alive" probe: a DESCRIPTION_REQUEST must be answered and must not close the
# connection (03_08_02 Core 7.7.2 p.36). Used by every "shall not close" case, because an
# open socket alone does not prove the receiver resynchronized on the stream.
#
# The drain is not optional. Test-KnxTcpClosed pumps everything the socket offers into the
# session buffer while it waits for a FIN that never comes, so without it this probe reads
# the PREVIOUS answer and judges the device on it. A review reproduced both directions at
# the device: false red when the leftover was a SEARCH_RESPONSE_EXTENDED (0x020C != 0x0204
# although the stream was perfectly in sync), and false green when the leftover happened to
# be a DESCRIPTION_RESPONSE - resynchronization would never have been tested at all.
function Test-StillServing($Session) {
    [void](Clear-KnxTcpPending -Session $Session)
    Send-KnxTcpRaw -Session $Session -Bytes (New-TcpDescriptionRequest)
    $r = Receive-KnxTcpFrame -Session $Session -TimeoutMs 3000
    return ($null -ne $r -and $r.Service -eq 0x0204)
}
function Disconnect-Quietly($Session, $Channel) {
    try {
        Send-KnxTcpRaw -Session $Session -Bytes (New-TcpDisconnectRequest $Channel)
        [void](Receive-KnxTcpFrame -Session $Session -TimeoutMs 1500)
    } catch { }
}
# Every case opens with this. Returns $false when the section does not apply, having set
# the result already, so the body can simply return.
function Test-TcpApplicable {
    if (-not $script:TcpServed) { Set-KnxTestNotApplicable $script:TcpNa; return $false }
    return $true
}
# The three malformed-header cases differ only in the six octets they put on the wire.
#
# "Closed" alone is NOT the criterion. 08_TSSK 2.5.4/2.5.5/2.5.6 (p.205/206/207) say: "Wait
# for a DescriptionResponse or TCP close. ... On timeout or DescriptionResponse: Abort test
# and return Test Failed." A server that ANSWERS the malformed frame and only then closes
# must fail - and a review proved the earlier version passed exactly that, with fourteen
# answer octets sitting unread in the buffer. Hence the second assertion.
function Assert-TcpClosedAfter([byte[]]$Bytes, [string]$What) {
    $s = New-TcpSession
    try {
        Send-KnxTcpRaw -Session $s -Bytes $Bytes
        Add-KnxEvidence -Sent $Bytes -Note "malformed KNXnet/IP header: $What"
        $closed = Test-KnxTcpClosed -Session $s -TimeoutMs 4000
        $leftover = Clear-KnxTcpPending -Session $s
        if ($leftover -gt 0) { Add-KnxEvidence -Note "server sent $leftover octet(s) before closing" }
        Assert-KnxTrue $closed 'server kept the TCP connection open after a malformed header'
        Assert-KnxEqual 0 $leftover 'server answered the malformed frame instead of discarding it silently'
    } finally { Close-KnxTcpSession $s }
}

function Invoke-KnxSuiteTcp {
    param([Parameter(Mandatory)]$Ctx, [string]$SuiteTitle = '9 TCP Transport')

    # One import, and it throws if it fails. The earlier version tried a path that can never
    # exist (.../scripts/Test/Test/lib/...) with -ErrorAction SilentlyContinue and relied on
    # a fallback - dead code that hid its own failure.
    Import-Module (Join-Path (Split-Path $PSCommandPath -Parent) '../lib/KnxTcp.psm1') -Force -ErrorAction Stop

    $script:TcpIp = $Ctx.BdutIp
    $script:TcpPort = $Ctx.Port

    # ── availability probe ─────────────────────────────────────────────────────────────
    # One connect decides the result of the whole section. Done once, outside the cases,
    # so a device without TCP produces one reason instead of fifteen timeouts.
    $script:TcpServed = $false
    $probeError = ''
    try {
        $probe = New-KnxTcpSession -Ip $script:TcpIp -Port $script:TcpPort -ConnectTimeoutMs 3000
        $script:TcpServed = $true
        Close-KnxTcpSession $probe
    } catch {
        $probeError = $_.Exception.Message
    }
    $script:TcpNa = "device does not accept TCP on the control endpoint ($probeError); TCP is optional for a KNXnet/IP device (03_08_02 Core 8.4.1 p.43)"

    # ── K-2.5.1 ────────────────────────────────────────────────────────────────────────
    # NOTE on K-2.5.1/K-2.5.2: 08_TSSK 2.5.1 p.203 and 2.5.2 p.204 drive a DescriptionRequest.
    # These two send a CONNECT_REQUEST instead, which covers the same ground AND the Route Back
    # mirroring of Core 8.4.3.4.3 p.46 - stronger, but not the same stimulus, so the TSSK
    # reference is named as related rather than implemented.
    #
    # No $Ctx.ReadOnly gate on purpose: each opens exactly one tunnel and closes it again.
    # That is not a write, reconfigure, reset, exhaust or flood - the five things the ReadOnly
    # profile promises to skip - and gating them would remove the two most basic cases of the
    # section. The cases that could starve the pool (K-2.5.21, five connections in sequence)
    # use DEVICE MANAGEMENT instead, so the tunnel pool is never under pressure here.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'K-2.5.1' -Title 'TCP communication works' -Clause '03_08_02 8.4.3.4.3 p.46; related: 08_TSSK 2.5.1 (10701) p.203' -Body {
        if (-not (Test-TcpApplicable)) { return }
        $s = New-TcpSession
        try {
            Send-KnxTcpRaw -Session $s -Bytes (New-TcpConnectRequest)
            $r = Receive-KnxTcpFrame -Session $s -TimeoutMs 3000
            Assert-KnxTrue ($null -ne $r) 'no CONNECT_RESPONSE on the TCP connection'
            Add-KnxEvidence -Received $r.Bytes -Note 'CONNECT_RESPONSE over TCP'
            Assert-KnxEqual 0x0206 $r.Service 'answer is not a CONNECT_RESPONSE'
            Assert-KnxEqual 0x00 $r.Body[1] 'CONNECT_RESPONSE status is not E_NO_ERROR'
            # Core 8.4.3.4.3 p.46: "If Client requested Route Back Data Endpoint, Server
            # shall also select Route Back Data Endpoint of same type."
            Assert-KnxEqual 0x02 $r.Body[3] 'server did not mirror the TCP Route Back HPAI (host protocol code)'
            Assert-KnxTrue (($r.Body[4] -bor $r.Body[5] -bor $r.Body[6] -bor $r.Body[7] -bor $r.Body[8] -bor $r.Body[9]) -eq 0) `
                'mirrored HPAI is not the Route Back form (address/port not zero)'
            Disconnect-Quietly $s $r.Body[0]
        } finally { Close-KnxTcpSession $s }
    }

    # ── K-2.5.2 ────────────────────────────────────────────────────────────────────────
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'K-2.5.2' -Title 'Fragmented TCP frames are received OK' -Clause '03_08_02 8.4.3.3 p.45; 08_TSSK 2.5.2 (10702) p.204' -Body {
        if (-not (Test-TcpApplicable)) { return }
        $s = New-TcpSession
        try {
            # Core 8.4.3.3 NOTE 8 p.46: "a sender sending a frame as individual 1-octet chunks
            # is a valid sender." One octet every 20 ms, well inside the 10 s idle window.
            Send-KnxTcpChunked -Session $s -Bytes (New-TcpConnectRequest) -ChunkSize 1 -DelayMs 20
            $r = Receive-KnxTcpFrame -Session $s -TimeoutMs 3000
            Assert-KnxTrue ($null -ne $r) 'no answer after a frame delivered one octet at a time'
            Assert-KnxEqual 0x0206 $r.Service 'fragmented CONNECT_REQUEST was not reassembled'
            Add-KnxEvidence -Received $r.Bytes -Note 'answer after 1-octet fragmentation'
            Disconnect-Quietly $s $r.Body[0]
        } finally { Close-KnxTcpSession $s }
    }

    # ── K-2.5.3 ────────────────────────────────────────────────────────────────────────
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'K-2.5.3' -Title 'Merged TCP frames are received OK' -Clause '03_08_02 8.4.3.3 p.45; 08_TSSK 2.5.3 (10703) p.204' -Body {
        if (-not (Test-TcpApplicable)) { return }
        $s = New-TcpSession
        try {
            # Two complete frames in one write. Core 8.4.3.3 p.45: "One IP packet may contain
            # multiple KNXnet/IP frames."
            #
            # The two frames must be DIFFERENT, and that is not cosmetic. An earlier version
            # sent the same DESCRIPTION_REQUEST twice - and octets 15..28 of that blob are
            # themselves a valid 06 10 02 03 header, so a receiver that resynchronized on the
            # wrong boundary still produced two 0x0204 and passed. 08_TSSK 2.5.3 p.204 uses
            # DescriptionRequest + ConnectionStateRequest and demands two different answers;
            # then only correct framing can produce 0x0204 followed by 0x0208.
            #
            # Channel 0 is never open, so the CONNECTIONSTATE_RESPONSE carries an error
            # status - irrelevant here: the case is about frame boundaries, and an error
            # status is still an answer to the second frame and only to the second frame.
            $connState = New-TcpFrame 0x0207 ([byte[]]@(0x00, 0x00) + (New-KnxTcpRouteBackHpai))
            Send-KnxTcpRaw -Session $s -Bytes ((New-TcpDescriptionRequest) + $connState)
            $r1 = Receive-KnxTcpFrame -Session $s -TimeoutMs 3000
            $r2 = Receive-KnxTcpFrame -Session $s -TimeoutMs 3000
            Assert-KnxTrue ($null -ne $r1 -and $null -ne $r2) 'two merged requests did not produce two answers'
            Assert-KnxEqual 0x0204 $r1.Service 'first answer is not a DESCRIPTION_RESPONSE'
            Assert-KnxEqual 0x0208 $r2.Service 'second answer is not a CONNECTIONSTATE_RESPONSE - the frame boundary was not recovered'
            Add-KnxEvidence -Note 'merged DescriptionRequest + ConnectionStateRequest answered 0x0204 then 0x0208'
        } finally { Close-KnxTcpSession $s }
    }

    # ── K-2.5.4 / 2.5.5 / 2.5.6 : "shall close" ────────────────────────────────────────
    # "If the header is not a well-formed KNXnet/IP header, the receiver shall close the TCP
    # connection." (03_08_02 Core 8.4.3.3 p.45). Written out three times rather than looped:
    # a loop would have to carry each variant into a scriptblock, and a captured-scope bug
    # there is invisible in the report - every case just fails with the same message.

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'K-2.5.4' -Title 'TCP connection gets closed on wrong header length' -Clause '03_08_02 8.4.3.3 p.45; 08_TSSK 2.5.4 (10704) p.205' -Body {
        if (-not (Test-TcpApplicable)) { return }
        Assert-TcpClosedAfter ([byte[]]@(0x07, 0x10, 0x02, 0x03, 0x00, 0x0E)) 'header length octet is 7, not 6'
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'K-2.5.5' -Title 'TCP connection gets closed on wrong protocol version' -Clause '03_08_02 8.4.3.3 p.45; 08_TSSK 2.5.5 (10705) p.206' -Body {
        if (-not (Test-TcpApplicable)) { return }
        Assert-TcpClosedAfter ([byte[]]@(0x06, 0x11, 0x02, 0x03, 0x00, 0x0E)) 'protocol version is 0x11, not 0x10'
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'K-2.5.6' -Title 'TCP connection gets closed on total length field < 6' -Clause '03_08_02 8.4.3.3 p.45; 08_TSSK 2.5.6 (10706) p.207' -Body {
        if (-not (Test-TcpApplicable)) { return }
        Assert-TcpClosedAfter ([byte[]]@(0x06, 0x10, 0x02, 0x03, 0x00, 0x05)) 'total length is 5, below the 6 octet header'
    }

    # ── K-2.5.7 ────────────────────────────────────────────────────────────────────────
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'K-2.5.7' -Title 'TCP connection gets closed upon receiving insufficient data' -Clause '03_08_02 8.4.3.3 p.45; 08_TSSK 2.5.7 (10707) p.207' -Body {
        if (-not (Test-TcpApplicable)) { return }
        if ($Ctx.SkipSlow) { Set-KnxTestSkip 'slow case (idle timeout window); -SkipSlow is set'; return }
        $s = New-TcpSession
        try {
            # A well-formed header announcing 14 octets, then nothing. The receiver "shall
            # wait for the remaining data and shall close the TCP connection when running
            # into the following timeouts" - here the 10 s idle window (Core 8.4.3.2 p.44).
            $hdr = [byte[]]@(0x06, 0x10, 0x02, 0x03, 0x00, 0x0E)
            Send-KnxTcpRaw -Session $s -Bytes $hdr
            Add-KnxEvidence -Sent $hdr -Note 'header announces 14 octets, body never sent'
            $window = (Get-KnxTcpIdleTimeoutMs) + 4000
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $closed = Test-KnxTcpClosed -Session $s -TimeoutMs $window
            $sw.Stop()
            Add-KnxEvidence -Note "connection closed after $($sw.ElapsedMilliseconds) ms"
            Assert-KnxTrue $closed "server did not close the stalled connection within $window ms"
            # The clause has two halves and the first one was missing here: "the receiver shall
            # WAIT for the remaining data and shall close the TCP connection when running into
            # the following timeouts" (Core 8.4.3.3 p.45). Without a floor, a server that closes
            # instantly - never waiting at all - passes. Measured at the reference device over
            # five samples: 10014, 10098, 10098, 10099, 10098 ms, so the floor sits far below
            # anything a conformant device produces and only catches "did not wait".
            $floor = [int]((Get-KnxTcpIdleTimeoutMs) * 0.9)
            Assert-KnxTrue ($sw.ElapsedMilliseconds -ge $floor) `
                "server closed the stalled connection after only $($sw.ElapsedMilliseconds) ms - it did not wait for the remaining data (floor $floor ms)"
        } finally { Close-KnxTcpSession $s }
    }

    # ── K-2.5.8 ────────────────────────────────────────────────────────────────────────
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'K-2.5.8' -Title 'TCP connection does not get closed on long frame' -Clause '03_08_02 8.4.3.3 p.45; 08_TSSK 2.5.8 (10708) p.208' -Body {
        if (-not (Test-TcpApplicable)) { return }
        $s = New-TcpSession
        try {
            # "If the total length ... is longer than the available receive buffer space in
            # the receiving device, the receiver shall skip the body of the frame. ... The
            # receiver shall not close the TCP connection. All devices must support (i.e.
            # must be able to skip, not necessarily be able to store) frames with a total
            # length of up to 65535 octets." (Core 8.4.3.3 p.45)
            #
            # 65535 and an UNASSIGNED service type, both on purpose, both from 08_TSSK 2.5.8
            # p.208 (06 10 09 50 ff ff + 65529 null octets). An earlier version sent 4090
            # octets of a SUPPORTED service (0x0203), and a review showed why that proves
            # nothing: on a device whose buffer exceeds 4096 the frame takes the "receive the
            # body and handle it" branch and never reaches the skip path, and the identical
            # assertions were green at a total length the device demonstrably DID process.
            # Only the spec maximum reaches the skip branch on every device.
            $long = New-TcpFrame 0x0950 (New-Object byte[] 65529)
            Assert-KnxEqual 65535 $long.Length 'test frame is not the 65535 octet maximum'
            Send-KnxTcpRaw -Session $s -Bytes $long
            Assert-KnxTrue (-not (Test-KnxTcpClosed -Session $s -TimeoutMs 2000)) `
                'server closed the connection on an oversize frame instead of skipping it'
            Assert-KnxTrue (Test-StillServing $s) `
                'server stayed connected but lost frame synchronization after the oversize frame'
            Add-KnxEvidence -Note "oversize frame of $($long.Length) octets skipped, stream still in sync"
            # Belt and braces: a device that ANSWERED the oversize frame would have taken the
            # handle branch, not the skip branch - and Test-StillServing drains before asking,
            # so a leftover here is the device's own doing.
            Assert-KnxEqual 0 (Clear-KnxTcpPending -Session $s) 'server left unread octets after the oversize frame'
        } finally { Close-KnxTcpSession $s }
    }

    # ── K-2.5.9 ────────────────────────────────────────────────────────────────────────
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'K-2.5.9' -Title 'TCP connection does not get closed on unknown service type' -Clause '03_08_02 8.4.3.3 p.45; 08_TSSK 2.5.9 (10709) p.209' -Body {
        if (-not (Test-TcpApplicable)) { return }
        $s = New-TcpSession
        try {
            # "The receiver shall not close the TCP connection because of an unsupported or
            # unknown service type." (Core 8.4.3.3 p.45)
            $unknown = New-TcpFrame 0x0999 ([byte[]]@(0xAA, 0xBB, 0xCC, 0xDD))
            Send-KnxTcpRaw -Session $s -Bytes $unknown
            Add-KnxEvidence -Sent $unknown -Note 'service type 0x0999 is not assigned'
            Assert-KnxTrue (-not (Test-KnxTcpClosed -Session $s -TimeoutMs 2000)) `
                'server closed the connection on an unknown service type'
            Assert-KnxTrue (Test-StillServing $s) `
                'server stayed connected but did not skip the unknown frame cleanly'
        } finally { Close-KnxTcpSession $s }
    }

    # ── K-2.5.10 ───────────────────────────────────────────────────────────────────────
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'K-2.5.10' -Title 'Half-closing TCP connection results in closing the TCP connection' -Clause '03_08_02 8.4.3.3 p.45; 08_TSSK 2.5.10 (10710) p.210' -Body {
        if (-not (Test-TcpApplicable)) { return }
        $s = New-TcpSession
        try {
            # "If the receiver detects that the sender has closed his sending side
            # (half-closed TCP connection) the receiver shall discard any pending requests
            # and close the TCP connection immediately." (Core 8.4.3.3 p.45)
            $s.Client.Client.Shutdown([System.Net.Sockets.SocketShutdown]::Send)
            Assert-KnxTrue (Test-KnxTcpClosed -Session $s -TimeoutMs 4000) `
                'server did not close the connection after the client half-closed it'
        } finally { Close-KnxTcpSession $s }
    }

    # ── K-2.5.11 ───────────────────────────────────────────────────────────────────────
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'K-2.5.11' -Title 'KNXnet/IP frames with total length 508 are handled correctly' -Clause '03_08_02 6.2 p.15; 08_TSSK 2.5.11 (10711) p.212' -Body {
        if (-not (Test-TcpApplicable)) { return }
        $s = New-TcpSession
        try {
            # 508 is the floor every server must be able to PROCESS (Core 6.2 p.15) - not
            # merely consume. That distinction is the whole case: an earlier version sent an
            # unassigned service type and asserted "not closed, still in sync", and a review
            # showed it passed at total length 1024, which this device demonstrably cannot
            # process (measured receive buffer: 600 octets). Consumption and resynchronization
            # are what the SKIP branch does too, so that version could not tell the branches
            # apart and could never fail a device with a buffer below 508.
            #
            # 08_TSSK 2.5.11 p.212 solves it: a SEARCH_REQUEST_EXTENDED padded to exactly 508
            # with two "Invalid" SRPs whose mandatory bit is clear. Core 7.6.3.3.2 p.34 says that if the
            # M bit is not set, the SRP shall be ignored, so the
            # frame stays valid at any length - and the answer 0x020C is only possible if the
            # body was received and processed. Silence would mean it was skipped.
            $srpA = [byte[]]@(0xFA, 0x00) + (New-Object byte[] 248)   # 250 octets, type 00h = Invalid, M = 0
            $srpB = [byte[]]@(0xF4, 0x00) + (New-Object byte[] 242)   # 244 octets
            $f508 = New-TcpFrame 0x020B ((New-KnxTcpRouteBackHpai) + $srpA + $srpB)
            Assert-KnxEqual 508 $f508.Length 'test frame is not 508 octets'
            Send-KnxTcpRaw -Session $s -Bytes $f508
            $r = Receive-KnxTcpFrame -Session $s -TimeoutMs 3000
            Assert-KnxTrue ($null -ne $r) 'no answer to a 508 octet SEARCH_REQUEST_EXTENDED: the body was skipped, not processed'
            Assert-KnxEqual 0x020C $r.Service 'answer is not a SEARCH_RESPONSE_EXTENDED'
            Add-KnxEvidence -Received $r.Bytes -Note '508 octet request processed, not skipped'
            Assert-KnxTrue (-not (Test-KnxTcpClosed -Session $s -TimeoutMs 1500)) `
                'server closed the connection after a 508 octet frame'
        } finally { Close-KnxTcpSession $s }
    }

    # ── K-2.5.12 ───────────────────────────────────────────────────────────────────────
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'K-2.5.12' -Title 'TCP connection is not closed after DescriptionResponse' -Clause '03_08_02 7.7.2 p.36; 08_TSSK 2.5.12 (10712) p.213' -Body {
        if (-not (Test-TcpApplicable)) { return }
        $s = New-TcpSession
        try {
            Send-KnxTcpRaw -Session $s -Bytes (New-TcpDescriptionRequest)
            $r = Receive-KnxTcpFrame -Session $s -TimeoutMs 3000
            Assert-KnxTrue ($null -ne $r) 'no DESCRIPTION_RESPONSE over TCP'
            Assert-KnxEqual 0x0204 $r.Service 'answer is not a DESCRIPTION_RESPONSE'
            Add-KnxEvidence -Received $r.Bytes -Note 'DESCRIPTION_RESPONSE over TCP'
            Assert-KnxTrue (-not (Test-KnxTcpClosed -Session $s -TimeoutMs 2000)) `
                'server closed the TCP connection after answering a DESCRIPTION_REQUEST'
        } finally { Close-KnxTcpSession $s }
    }

    # ── K-2.5.17 ───────────────────────────────────────────────────────────────────────
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'K-2.5.17' -Title 'TCP idle timeout' -Clause '03_08_02 8.4.3.2 p.44; 08_TSSK 2.5.17 (10717) p.220' -Body {
        if (-not (Test-TcpApplicable)) { return }
        if ($Ctx.SkipSlow) { Set-KnxTestSkip 'slow case (idle timeout window); -SkipSlow is set'; return }
        $s = New-TcpSession
        try {
            # "If no KNXnet/IP connection or Session is active and no octets have been
            # received for 10 seconds" the server closes (Core 8.4.3.2 p.44). Nothing is
            # sent at all here, so the window starts with the connect.
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $closed = Test-KnxTcpClosed -Session $s -TimeoutMs ((Get-KnxTcpIdleTimeoutMs) + 5000)
            $sw.Stop()
            $lo = [int]((Get-KnxTcpIdleTimeoutMs) * 0.9)
            $hi = [int]((Get-KnxTcpIdleTimeoutMs) * 1.1)
            Add-KnxEvidence -Note "connection closed after $($sw.ElapsedMilliseconds) ms (band $lo..$hi ms)"
            Assert-KnxTrue $closed 'server never closed an idle TCP connection'
            # 0.9..1.1x as 08_TSSK 2.5.17 p.220 requires. An earlier version used 0.5..1.5x
            # and justified it with harness jitter - measurement killed that argument: five
            # samples landed in 10081..10097 ms, a spread of 16 ms, and the poll resolution
            # is 20 ms (Poll takes MICROseconds, 20000 = 20 ms, not 20 s). The wide band
            # accepted 5000..15000 ms for a value the spec pins to "10 seconds".
            Assert-KnxTrue ($sw.ElapsedMilliseconds -ge $lo) `
                "server closed the idle connection after only $($sw.ElapsedMilliseconds) ms, below the $lo ms floor"
            Assert-KnxTrue ($sw.ElapsedMilliseconds -le $hi) `
                "server held the idle connection for $($sw.ElapsedMilliseconds) ms, above the $hi ms ceiling"
        } finally { Close-KnxTcpSession $s }
    }

    # ── K-2.5.18 ───────────────────────────────────────────────────────────────────────
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'K-2.5.18' -Title 'TCP octets prevent idle timeout' -Clause '03_08_02 8.4.3.3 p.45; 08_TSSK 2.5.18 (10718) p.220' -Body {
        if (-not (Test-TcpApplicable)) { return }
        if ($Ctx.SkipSlow) { Set-KnxTestSkip 'slow case (idle timeout window); -SkipSlow is set'; return }
        $s = New-TcpSession
        try {
            # "This timeout is restarted with each received octet" (Core 8.4.3.3 p.46) - each
            # OCTET, and that word is the whole case. An earlier version sent complete frames
            # every 3 s, which a device that only restarts its timer on a finished frame
            # passes without implementing the clause at all.
            #
            # 08_TSSK 2.5.18 p.220 does it properly: single octets, spaced at half the idle
            # window, for longer than the window. Twelve octets at 5 s is 60 s against a 10 s
            # window - only a per-octet restart keeps the connection alive that long.
            #
            # Correcting an earlier comment here that was simply wrong: it claimed "the frame
            # never completes". It does - the total length field is 0x000C = 12 and exactly 12
            # octets are sent, so the last octet completes a frame carrying an unassigned
            # service type. The case still measures what it must, but that is a second reason
            # the connection stays open, and it was not named. Review caught it.
            $drip = [byte[]]@(0x06, 0x10, 0x09, 0xEE, 0x00, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
            $gap = [int]((Get-KnxTcpIdleTimeoutMs) / 2)
            $sw = [Diagnostics.Stopwatch]::StartNew()
            foreach ($b in $drip) {
                Start-Sleep -Milliseconds $gap
                if ($s.PeerClosed) { break }
                Send-KnxTcpRaw -Session $s -Bytes ([byte[]]@($b))
            }
            $sw.Stop()
            Add-KnxEvidence -Note "12 single octets, one every $gap ms, total $($sw.ElapsedMilliseconds) ms - well past the $(Get-KnxTcpIdleTimeoutMs) ms idle window"
            Assert-KnxTrue (-not (Test-KnxTcpClosed -Session $s -TimeoutMs 500)) `
                'server closed the connection although single octets kept arriving inside the idle window'
            # An open socket is not proof of a healthy receiver - the same rule every other
            # "shall not close" case here follows (K-2.5.8, K-2.5.9, K-2.5.11). It was missing
            # only here, which is the divergence a reviewer is meant to catch. Verified at the
            # reference device: after the twelfth octet it still answers 0x0204.
            Assert-KnxTrue (Test-StillServing $s) `
                'connection survived the idle window but the server no longer serves it'
        } finally { Close-KnxTcpSession $s }
    }

    # ── K-2.5.21 ───────────────────────────────────────────────────────────────────────
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'K-2.5.21' -Title 'TCP and KNX connections: HPAI restrictions' -Clause '03_08_02 8.6.2.1 p.49; 08_TSSK 2.5.21 (10721) p.224' -Body {
        if (-not (Test-TcpApplicable)) { return }
        # Table 10 p.49 allows only the Route Back encoding on TCP; "All other encodings are
        # invalid and result in discarding the containing KNXnet/IP Frame."
        #
        # SILENCE IS NOT THE CRITERION - that was the trap in the first version of this case.
        # A review passed it against a server that merely accepted the TCP connection and
        # closed it at once, because Receive-KnxTcpFrame returns $null on FIN and $null was
        # the success condition. It also measured this very device going silent on VALID
        # requests once seven connections were open. So each negative now proves two things:
        # nothing came back, AND the server is still serving that same connection.
        #
        # DEVIATION FROM TSSK, measured not assumed: 08_TSSK 2.5.21 p.224 prescribes a DEVICE
        # MANAGEMENT connection, and the first version followed that. Against the certified
        # reference device it produced CONNECT_RESPONSE channel 0, status 0x28
        # (E_AUTHORISATION_ERROR) - device management over TCP is refused there. That is
        # consistent: 08_TSSK is the SECURITY test specification and its cases run inside a
        # Secure Session, where device management over TCP is available. This suite tests
        # WITHOUT Secure, so the positive control has to use a connection type the device
        # actually serves, and a tunnel is answered 0x00 on the same transport.
        #
        # The negatives are unaffected either way: an invalid HPAI is discarded before the CRI
        # is ever looked at (Core 8.6.2.1 Table 10 p.49). They use the same CRI only so that a
        # device which DOES evaluate it cannot fail them for the wrong reason.
        #
        # Cost: the positive control occupies one tunnel slot for the length of one exchange.
        # The reference device has four; the five negatives occupy none, because a discarded
        # frame opens nothing.
        $cri = [byte[]]@(0x04, 0x04, 0x02, 0x00)   # 03_08_04 5.4.3.1 Fig.4 p.26: TUNNEL_CONNECTION, Link Layer

        foreach ($v in @(
            @{ Name = 'TCP HPAI with non-zero port'; Udp = $false; UseIp = $false; UsePort = $true }
            @{ Name = 'TCP HPAI with non-zero address'; Udp = $false; UseIp = $true; UsePort = $false }
            @{ Name = 'TCP HPAI with non-zero address and port'; Udp = $false; UseIp = $true; UsePort = $true }
            @{ Name = 'UDP Route Back HPAI on a TCP connection'; Udp = $true; UseIp = $false; UsePort = $false }
            @{ Name = 'full UDP HPAI on a TCP connection'; Udp = $true; UseIp = $true; UsePort = $true })) {

            $s = New-TcpSession
            try {
                # The address has to be OUR address for the case to mean what TSSK intends:
                # it is the endpoint a non-conformant server would answer to. Read from the
                # live socket instead of hard-coded, so the case keeps its meaning on any
                # test host - a foreign literal would test something else entirely.
                $oct  = $s.Client.Client.LocalEndPoint.Address.GetAddressBytes()
                $code = if ($v.Udp) { 0x01 } else { 0x02 }
                $addr = if ($v.UseIp) { $oct } else { [byte[]]@(0, 0, 0, 0) }
                $prt  = if ($v.UsePort) { [byte[]]@(0x0E, 0x57) } else { [byte[]]@(0, 0) }
                $hpai = [byte[]]@(0x08, [byte]$code) + $addr + $prt

                Send-KnxTcpRaw -Session $s -Bytes (New-TcpFrame 0x0205 ($hpai + $hpai + $cri))
                $r = Receive-KnxTcpFrame -Session $s -TimeoutMs 2000
                if ($null -ne $r) { Add-KnxEvidence -Received $r.Bytes -Note "answered a CONNECT_REQUEST carrying $($v.Name)" }
                Assert-KnxTrue ($null -eq $r) "server answered a CONNECT_REQUEST carrying $($v.Name) instead of discarding it"
                # This is what turns "no answer" into "correctly discarded".
                Assert-KnxTrue (Test-StillServing $s) `
                    "server went silent on $($v.Name) but stopped serving the connection - that is a dead connection, not a discard"
            } finally { Close-KnxTcpSession $s }
        }

        # Positive control, in the same case: without it a server that answers nothing at all
        # passes every negative. It checks the STATUS too - E_NO_MORE_CONNECTIONS (0x24) is an
        # answer, but it is not proof that the valid combination is accepted.
        $s = New-TcpSession
        try {
            Send-KnxTcpRaw -Session $s -Bytes (New-TcpFrame 0x0205 ((New-KnxTcpRouteBackHpai) + (New-KnxTcpRouteBackHpai) + $cri))
            $ok = Receive-KnxTcpFrame -Session $s -TimeoutMs 3000
            Assert-KnxTrue ($null -ne $ok) 'the valid TCP Route Back combination was not answered either'
            Assert-KnxEqual 0x0206 $ok.Service 'valid TCP Route Back combination did not produce a CONNECT_RESPONSE'
            Assert-KnxEqual 0x00 $ok.Body[1] 'valid TCP Route Back combination was answered, but not with E_NO_ERROR'
            Disconnect-Quietly $s $ok.Body[0]
        } finally { Close-KnxTcpSession $s }
    }
}
