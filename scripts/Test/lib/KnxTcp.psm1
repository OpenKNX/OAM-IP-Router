#!/usr/bin/env pwsh
# Open ■
# ┬────┴  KnxTcp
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/lib/KnxTcp.psm1

<#
.SYNOPSIS
    The TCP side of the test suite: open a KNXnet/IP connection over TCP, put octets on it
    exactly as a test case wants them on the wire, and read frames back out of the stream.

.DESCRIPTION
    KnxTest.psm1 is datagram based throughout - New-KnxSocket, Clear-KnxSocket and
    Wait-KnxService all assume one send is one frame. TCP breaks that assumption in both
    directions, and 03_08_02 Core 8.4.3.3 p.45 says so in as many words: "there is no 1:1
    relation between IP packets and KNXnet/IP frames: One IP packet may contain multiple
    KNXnet/IP frames and one KNXnet/IP frame may span over multiple IP packets."

    A receiver therefore has to recover frames from an octet stream, and the cases that
    prove it does are exactly the ones that need a sender able to misalign on purpose:
    one frame delivered as single octets, two frames delivered in one segment. That is
    what Send-KnxTcpChunked is for, and it is why this module exists instead of another
    parameter on the UDP helpers.

    Frame construction is NOT duplicated here. New-KnxFrame, New-KnxHpai, New-KnxCri and
    the New-Knx*Request builders in KnxTest.psm1 produce the same octets regardless of
    transport; only the carrying differs. Import both modules and build as usual.

    One rule this module enforces for the caller, because it is easy to get wrong and the
    server answers with silence: on TCP a HPAI may only be the "Route Back" form.
    03_08_02 Core 8.6.2.1 Table 10 p.49: "For the host protocol code IPV4_TCP only the
    special 'Route Back' encoding is allowed. All other encodings are invalid and result in
    discarding the containing KNXnet/IP Frame." Use New-KnxTcpRouteBackHpai and the shape
    is right by construction.

    Verified against a certified reference device (MDT SCN-IP000.03, Core v2 /
    DeviceManagement v2 / Tunnelling v2, Secure disabled): CONNECT_REQUEST carrying two
    TCP Route Back HPAIs is answered E_NO_ERROR with a TCP Route Back HPAI mirrored back,
    which is what Core 8.4.3.4.3 p.46 requires.

.NOTES
    PowerShell 5.1 compatible. No classes, no ternaries, no PS6+ operators.
    Import next to KnxTest.psm1; it depends on nothing else.
#>

Set-StrictMode -Version Latest

# KNXnet/IP header: octet 0 = header length (6), 1 = protocol version (0x10),
# 2..3 = service type, 4..5 = total length. 03_08_02 Core 7.1 "Frame structures" p.20.
$script:KnxIpHeaderLen = 6
$script:KnxIpVersion   = 0x10

# 03_08_02 Core 8.4.3.2 p.44: a server closes an idle TCP connection after 10 s when no
# KNXnet/IP connection and no Secure Session is active. Tests that wait for that need a
# little slack on top, not a different number.
$script:KnxTcpIdleTimeoutMs = 10000

function New-KnxTcpSession
{
    <#
    .SYNOPSIS
        Opens a TCP connection to a KNXnet/IP server and returns a session to work with.
    .DESCRIPTION
        The session carries the pending octet buffer, so a frame that arrives split over
        several segments survives between Receive-KnxTcpFrame calls, and a second frame
        that arrived in the same segment is still there for the next call.

        03_08_02 Core 8.4.3.1 p.44: the TCP connection is always opened by the client, and
        a server shall support at least one. A server that cannot serve another one shows
        it by not establishing the connection - there is no KNXnet/IP error code for it,
        so a refused connect here is a result, not a harness failure.
    .PARAMETER Ip
        Server address. The control endpoint is used; a TCP capable server does not
        advertise a separate TCP port (Core 7.6.2 p.32).
    .PARAMETER Port
        Defaults to 3671.
    .PARAMETER ConnectTimeoutMs
        How long to wait for the TCP handshake.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Ip,
        [int] $Port = 3671,
        [int] $ConnectTimeoutMs = 3000
    )

    $client = New-Object System.Net.Sockets.TcpClient
    $client.NoDelay = $true   # a test must control segmentation, Nagle must not coalesce for us

    $async = $client.BeginConnect($Ip, $Port, $null, $null)
    if (-not $async.AsyncWaitHandle.WaitOne($ConnectTimeoutMs, $false))
    {
        $client.Close()
        throw "TCP connect to ${Ip}:${Port} timed out after ${ConnectTimeoutMs} ms"
    }
    try
    {
        $client.EndConnect($async)
    }
    catch
    {
        $client.Close()
        throw "TCP connect to ${Ip}:${Port} refused: $($_.Exception.Message)"
    }

    $session = New-Object PSObject -Property @{
        Client    = $client
        Stream    = $client.GetStream()
        Pending   = (New-Object 'System.Collections.Generic.List[byte]')
        Ip        = $Ip
        Port      = $Port
        PeerClosed = $false
    }
    return $session
}

function Close-KnxTcpSession
{
    <#
    .SYNOPSIS
        Closes the session. Safe to call twice.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Session)

    if ($null -eq $Session) { return }
    try { if ($null -ne $Session.Stream) { $Session.Stream.Close() } } catch { }
    try { if ($null -ne $Session.Client) { $Session.Client.Close() } } catch { }
}

function Send-KnxTcpRaw
{
    <#
    .SYNOPSIS
        Writes octets to the stream exactly as given - no framing, no padding, no checks.
    .DESCRIPTION
        Deliberately dumb: the malformed-header and short-frame cases need to put octets on
        the wire that no frame builder would produce.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Session,
        [Parameter(Mandatory = $true)][byte[]] $Bytes
    )

    $Session.Stream.Write($Bytes, 0, $Bytes.Length)
    $Session.Stream.Flush()
}

function Send-KnxTcpChunked
{
    <#
    .SYNOPSIS
        Writes octets in fixed-size pieces with a pause between them.
    .DESCRIPTION
        The sender half of the frame-synchronization cases. 03_08_02 Core 8.4.3.3, NOTE 8
        p.46: "a sender sending a frame as individual 1-octet chunks is a valid sender. A
        sender sending data chunks of 4096, generally misaligned with any frame boundary,
        is a valid sender." Both shapes are produced from here.

        Pass two concatenated frames with a ChunkSize larger than both to produce the
        merged-frames case; pass one frame with ChunkSize 1 to produce the fragmented case.
    .PARAMETER ChunkSize
        Octets per write. 1 is the interesting one.
    .PARAMETER DelayMs
        Pause between writes. Keep it well under the 10 s idle timeout (Core 8.4.3.2 p.44),
        otherwise the server is entitled to close mid-frame and the case proves nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Session,
        [Parameter(Mandatory = $true)][byte[]] $Bytes,
        [int] $ChunkSize = 1,
        [int] $DelayMs = 20
    )

    if ($ChunkSize -lt 1) { throw "ChunkSize must be >= 1" }

    $offset = 0
    while ($offset -lt $Bytes.Length)
    {
        $take = [Math]::Min($ChunkSize, $Bytes.Length - $offset)
        $Session.Stream.Write($Bytes, $offset, $take)
        $Session.Stream.Flush()
        $offset += $take
        if ($offset -lt $Bytes.Length -and $DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
    }
}

function Read-KnxTcpInto
{
    <#
    .SYNOPSIS
        Internal: moves whatever is available on the socket into the session buffer.
    .DESCRIPTION
        Returns $true if the peer closed its sending side. A zero-length read on a
        readable socket is the FIN; 03_08_02 Core 8.4.3.3 p.45 tells the receiver to treat
        a half-closed connection as "discard pending requests and close immediately", so
        the caller has to be able to see it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Session,
        [int] $TimeoutMs = 1000
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    $buffer = New-Object byte[] 4096

    while ([DateTime]::UtcNow -lt $deadline)
    {
        # Everything the socket can do is inside the try: on macOS/pwsh a reset connection
        # reports Available = 0 and the read returns 0, but Windows PowerShell 5.1 - which
        # is what the repo targets - throws SocketException/IOException instead. Without
        # this, a device that closes with RST would turn a correct PASS into an "unhandled
        # error" FAIL on the platform the suite has to run on. Every such throw means the
        # same thing the clean path means: the peer is gone.
        try
        {
            $sock = $Session.Client.Client
            # Poll takes MICROseconds: 20000 = 20 ms, not 20 s. It says "a read would not
            # block"; with nothing available that means FIN.
            if ($sock.Poll(20000, [System.Net.Sockets.SelectMode]::SelectRead))
            {
                if ($sock.Available -eq 0)
                {
                    $Session.PeerClosed = $true
                    return $true
                }
                $read = $Session.Stream.Read($buffer, 0, $buffer.Length)
                if ($read -le 0)
                {
                    $Session.PeerClosed = $true
                    return $true
                }
                for ($i = 0; $i -lt $read; $i++) { [void]$Session.Pending.Add($buffer[$i]) }
                return $false
            }
        }
        catch
        {
            $Session.PeerClosed = $true
            return $true
        }
    }
    return $false
}

function Receive-KnxTcpFrame
{
    <#
    .SYNOPSIS
        Pulls one complete KNXnet/IP frame out of the octet stream, or $null on timeout.
    .DESCRIPTION
        Recovers the frame structure from the header exactly as 03_08_02 Core 8.4.3.3 p.45
        prescribes for a receiver: wait for enough octets to interpret the header, then for
        the body length the header announces. Leftover octets stay in the session buffer,
        so two frames delivered in one segment come back from two calls.

        The returned object carries Bytes (the whole frame), Service, TotalLength and Body,
        so a case can assert on the service type the way the UDP cases do.

        This helper does NOT implement the receiver's error handling (close on malformed
        header, skip on oversize or unknown service) - that is the behaviour under test on
        the device side, not something the harness should imitate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Session,
        [int] $TimeoutMs = 3000
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)

    while ($true)
    {
        if ($Session.Pending.Count -ge $script:KnxIpHeaderLen)
        {
            $hdrLen = $Session.Pending[0]
            $total  = ([int]$Session.Pending[4] -shl 8) -bor [int]$Session.Pending[5]

            # A total length below the header size can never complete; hand it to the
            # caller as a malformed frame instead of waiting forever for octets that the
            # header itself says are not coming.
            #
            # Only the six header octets are consumed. An earlier version returned the whole
            # buffer and cleared it, which swallowed any well-formed frame that arrived in
            # the same segment: a review reproduced it with a total=3 header followed by a
            # complete DESCRIPTION_RESPONSE - the response vanished and the next call
            # returned $null. The cases here never hit it, but 2.5.19/2.5.20 read several
            # frames per connection and would have.
            if ($total -lt $script:KnxIpHeaderLen -or $hdrLen -lt $script:KnxIpHeaderLen)
            {
                $raw = New-Object byte[] $script:KnxIpHeaderLen
                $Session.Pending.CopyTo(0, $raw, 0, $script:KnxIpHeaderLen)
                $Session.Pending.RemoveRange(0, $script:KnxIpHeaderLen)
                return (New-Object PSObject -Property @{
                    Bytes       = $raw
                    Service     = -1
                    TotalLength = $total
                    Body        = @()
                    Malformed   = $true
                })
            }

            if ($Session.Pending.Count -ge $total)
            {
                $frame = New-Object byte[] $total
                $Session.Pending.CopyTo(0, $frame, 0, $total)
                $Session.Pending.RemoveRange(0, $total)
                $svc = ([int]$frame[2] -shl 8) -bor [int]$frame[3]
                $body = @()
                if ($total -gt $hdrLen)
                {
                    $body = New-Object byte[] ($total - $hdrLen)
                    [Array]::Copy($frame, $hdrLen, $body, 0, $total - $hdrLen)
                }
                return (New-Object PSObject -Property @{
                    Bytes       = $frame
                    Service     = $svc
                    TotalLength = $total
                    Body        = $body
                    Malformed   = $false
                })
            }
        }

        $left = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($left -le 0) { return $null }
        if (Read-KnxTcpInto -Session $Session -TimeoutMs ([Math]::Min($left, 500))) { return $null }
    }
}

function Test-KnxTcpClosed
{
    <#
    .SYNOPSIS
        Waits up to TimeoutMs for the server to close the connection. $true if it did.
    .DESCRIPTION
        The acceptance criterion for every "shall close the TCP connection" clause in
        03_08_02 Core 8.4.3.3 p.45 - malformed header, wrong protocol version, stalled
        reception - and the counter-criterion for the two clauses that say the receiver
        shall NOT close (oversize frame, unsupported service type).

        Use a TimeoutMs above 10 s when the case is about the idle timeout itself
        (Core 8.4.3.2 p.44), and well below it when the case is about NOT closing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Session,
        [int] $TimeoutMs = 2000
    )

    if ($Session.PeerClosed) { return $true }

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline)
    {
        # Max(1, ...): a $left that rounds to 0 makes Read-KnxTcpInto return at once and
        # spins this loop over the last sub-millisecond.
        $left = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
        [void](Read-KnxTcpInto -Session $Session -TimeoutMs ([Math]::Max(1, [Math]::Min($left, 500))))
        if ($Session.PeerClosed) { return $true }
    }
    return $false
}

function Clear-KnxTcpPending
{
    <#
    .SYNOPSIS
        Drops whatever is sitting in the session buffer and reports how much that was.
    .DESCRIPTION
        Test-KnxTcpClosed pumps everything the socket offers into the buffer while it waits
        for a FIN that does not come. A case that afterwards wants to ask the device a fresh
        question has to drop that first, or it reads the PREVIOUS answer and judges the
        device on it. A review caught exactly that: after an oversize frame the device's
        160-octet answer sat in the buffer, and the "is it still serving" probe read that
        instead of its own DESCRIPTION_RESPONSE and declared the stream broken.

        The count is returned because "how many octets were left over" is itself evidence:
        for the cases where the device must stay silent, anything but 0 is the finding.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Session)

    $n = $Session.Pending.Count
    $Session.Pending.Clear()
    return $n
}

function New-KnxTcpRouteBackHpai
{
    <#
    .SYNOPSIS
        The only HPAI form a TCP frame may carry: IPV4_TCP, address 0.0.0.0, port 0.
    .DESCRIPTION
        03_08_02 Core 8.6.2.1 Table 10 p.49 allows no other encoding on TCP, and Figure 34
        p.50 gives the octets. A half-zeroed variant is invalid as well, which is why this
        builder takes no parameters: there is nothing legitimate to vary.

        Core 8.4.3.4.3 p.46 additionally requires both endpoints to use it together -
        "If Control Endpoint is Route Back, Data Endpoint must also be Route Back" - so a
        request carries this same structure twice.
    #>
    [CmdletBinding()]
    param()

    return [byte[]] @(0x08, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
}

function Get-KnxTcpIdleTimeoutMs
{
    <#
    .SYNOPSIS
        The 10 s server-side idle timeout for a TCP connection with nothing active on it.
    .DESCRIPTION
        03_08_02 Core 8.4.3.2 p.44. Exposed so cases cite one number instead of each
        carrying its own literal.
    #>
    [CmdletBinding()]
    param()

    return $script:KnxTcpIdleTimeoutMs
}

Export-ModuleMember -Function `
    New-KnxTcpSession, Close-KnxTcpSession, `
    Send-KnxTcpRaw, Send-KnxTcpChunked, `
    Receive-KnxTcpFrame, Test-KnxTcpClosed, Clear-KnxTcpPending, `
    New-KnxTcpRouteBackHpai, Get-KnxTcpIdleTimeoutMs
