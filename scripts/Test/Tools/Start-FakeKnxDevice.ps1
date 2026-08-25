#!/usr/bin/env pwsh
<#
Open ■
┬────┴  Start-FakeKnxDevice
■ KNX   2026 OpenKNX - Erkan Çolak

FILEPATH: scripts/Test/Tools/Start-FakeKnxDevice.ps1

.SYNOPSIS
    A minimal KNXnet/IP responder used to exercise the conformance suites without hardware.

.DESCRIPTION
    Answers SEARCH, DESCRIPTION, CONNECT, CONNECTIONSTATE, DISCONNECT and
    DEVICE_CONFIGURATION on a local UDP port, so Invoke-Conformance.ps1 can be run
    end-to-end while developing or reviewing a suite.

    It is a TEST HARNESS, not a device model. It deliberately implements only the
    behaviour the suites drive, and it can be told to misbehave (-Misbehave) so the
    suites can be shown to actually FAIL when a device is wrong - a suite that has never
    produced a red line has not been proven to be able to.

    What it does implement, and why:
      * Malformed frames (bad header size, bad version, declared length mismatch) are
        dropped silently - that is what the negative Core cases check.
      * A bounded number of tunnel and device-management channels, then E_NO_MORE_CONNECTIONS.
      * Tunnel addresses handed out as the FIRST FREE entry of a list, so H-5.3.3 has
        something meaningful to observe.
      * M_PropRead for the handful of properties the suites read, and an error
        confirmation for unknown ones.

.PARAMETER Port
    UDP port to listen on. Default 3671. Use a high port to avoid needing privileges.

.PARAMETER Role
    Interface (no ROUTING family, busmonitor allowed) or Router (ROUTING advertised).

.PARAMETER MaxTunnels
    Number of tunnel channels to grant. Default 4.

.PARAMETER Misbehave
    Comma separated list of deliberate faults, to prove the suites can fail:
      answer-invalid-version   answer a SEARCH_REQUEST that has a wrong protocol version
      wrong-connstate-status   report E_NO_ERROR for an unknown channel
      reuse-tunnel-address     hand out the same tunnel address twice
      accept-bad-layer         accept an undefined KNX layer code

.PARAMETER Seconds
    Stop automatically after this many seconds. 0 = run until Ctrl-C. Default 0.

.EXAMPLE
    ./Start-FakeKnxDevice.ps1 -Port 3671
.EXAMPLE
    ./Start-FakeKnxDevice.ps1 -Port 3672 -Role Router -Seconds 120
.EXAMPLE
    ./Start-FakeKnxDevice.ps1 -Misbehave wrong-connstate-status,reuse-tunnel-address
#>

[CmdletBinding()]
param(
    [int]$Port = 3671,
    [ValidateSet('Interface', 'Router')]
    [string]$Role = 'Interface',
    [int]$MaxTunnels = 4,
    [int]$MaxDevMgmt = 2,
    [string]$IndividualAddress = '1.1.1',
    [string[]]$Misbehave = @(),
    [int]$Seconds = 0,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $here 'lib/KnxTest.psm1') -Force

$K = Get-KnxConstants

function Write-Trace {
    param([string]$Text, [string]$Colour = 'DarkGray')
    if (-not $Quiet) { Write-Host "  [fake] $Text" -ForegroundColor $Colour }
}

# ─── Device state ───────────────────────────────────────────────────────────────

$state = [pscustomobject]@{
    Channels = @{}          # channel id -> connection record
    NextChannel = 1
    ProgMode = 0
    BusQueue = (New-Object System.Collections.ArrayList)   # loopback bus, drained by the main loop
    Endpoints = @{}         # channel id -> remote endpoint, for unsolicited delivery
    PendingChannel = -1     # channel just created, whose endpoint the main loop records
}

# Tunnel address pool. The first free entry is handed out - the property the assignment
# method case checks.
$tunnelAddresses = @()
for ($i = 0; $i -lt $MaxTunnels; $i++) { $tunnelAddresses += (ConvertFrom-KnxPa -Raw ((ConvertTo-KnxPa -Address '1.1.111') + $i)) }

$friendlyName = "OpenKNX Fake $Role"
$serial = [byte[]]@(0x00, 0xC5, 0x01, 0x02, 0x03, 0x04)
$mac = [byte[]]@(0x02, 0x00, 0x00, 0x11, 0x22, 0x33)
$multicast = [byte[]]@(224, 0, 23, 12)
$maskVersion = 0x07B0
if ($Role -eq 'Router') { $maskVersion = 0x091A }

function New-DeviceInfoDib {
    $name = New-Object byte[] 30
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($friendlyName)
    [Array]::Copy($bytes, $name, [Math]::Min(29, $bytes.Length))
    $ia = ConvertTo-KnxPa -Address $IndividualAddress
    $body = [byte[]]@(
        0x36, 0x01,
        0x02,                                   # KNX medium TP1
        [byte]$state.ProgMode,                  # device status: bit0 = programming mode
        (($ia -shr 8) -band 0xFF), ($ia -band 0xFF),
        0x00, 0x00                              # project installation id
    ) + $serial + $multicast + $mac + $name
    return , $body
}

function New-ServiceFamiliesDib {
    $fams = @(@($K.Family.CORE, 2), @($K.Family.DEVICE_MANAGEMENT, 2), @($K.Family.TUNNELLING, 2))
    if ($Role -eq 'Router') { $fams += , @($K.Family.ROUTING, 2) }
    $payload = [byte[]]@()
    foreach ($f in $fams) { $payload = [byte[]]($payload + [byte[]]@([byte]$f[0], [byte]$f[1])) }
    return , ([byte[]]@([byte](2 + $payload.Length), 0x02) + $payload)
}

function New-ExtendedDib {
    return , ([byte[]]@(0x08, 0x08, 0x00, 0x00, 0x00, 0xF0, (($maskVersion -shr 8) -band 0xFF), ($maskVersion -band 0xFF)))
}

function Get-FreeTunnelAddress {
    $used = @()
    # NOTE: not $k - PowerShell variable names are case-insensitive, so a loop variable
    # named $k would silently overwrite $K, the constants table.
    foreach ($chId in $state.Channels.Keys) {
        $c = $state.Channels[$chId]
        if ($c.Type -eq $K.ConnType.TUNNEL_CONNECTION -and $null -ne $c.Address) { $used += $c.Address }
    }
    if ($Misbehave -contains 'reuse-tunnel-address' -and $used.Count -gt 0) { return $tunnelAddresses[0] }
    foreach ($a in $tunnelAddresses) { if ($used -notcontains $a) { return $a } }
    return $null
}

# ─── Frame handling ─────────────────────────────────────────────────────────────

function New-ReplyList {
    <#
    .SYNOPSIS
        Creates a list that holds byte arrays as ELEMENTS.
    .DESCRIPTION
        @($byteArray) unrolls the array into individual bytes in PowerShell, so a plain
        array cannot be used to collect frames - a typed list is the only safe container.
    #>
    # The comma is load-bearing: returning a List directly makes PowerShell ENUMERATE
    # it on output, so a one-element list would arrive as a bare byte[].
    $l = New-Object 'System.Collections.Generic.List[byte[]]'
    return , $l
}

function New-SingleReply {
    <#
    .SYNOPSIS
        Wraps one frame in a reply list.
    #>
    param([Parameter(Mandatory)][byte[]]$Frame)
    $l = New-Object 'System.Collections.Generic.List[byte[]]'
    [void]$l.Add($Frame)
    return , $l
}

function Get-Reply {
    <#
    .SYNOPSIS
        Turns a received datagram into zero or more reply frames.
    .DESCRIPTION
        Always returns a List[byte[]]; the caller iterates it. Never an @() array - see
        New-ReplyList for why.
    #>
    param([byte[]]$Frame)

    # Malformed frames are dropped silently. The order matters: the header must be
    # validated before anything indexes into the body.
    if ($Frame.Length -lt 6) { return , (New-ReplyList) }
    if ($Frame[0] -ne 0x06) { Write-Trace 'drop: header size'; return , (New-ReplyList) }
    if ($Frame[1] -ne 0x10) {
        if ($Misbehave -contains 'answer-invalid-version') { Write-Trace 'MISBEHAVE: answering an invalid version' 'Yellow' }
        else { Write-Trace 'drop: protocol version'; return , (New-ReplyList) }
    }
    $declared = Get-Uint16 -Bytes $Frame -Offset 4
    if ($declared -ne $Frame.Length) { Write-Trace "drop: declared $declared, got $($Frame.Length)"; return , (New-ReplyList) }

    $svc = Get-Uint16 -Bytes $Frame -Offset 2
    $body = [byte[]]@()
    if ($Frame.Length -gt 6) { $body = [byte[]]$Frame[6..($Frame.Length - 1)] }

    # Any traffic on a channel keeps it alive; the reaper below drops the ones that go quiet.
    if ($body.Length -ge 2) {
        foreach ($cand in @($body[0], $body[1])) {
            $ci = [int]$cand
            if ($state.Channels.ContainsKey($ci)) { $state.Channels[$ci].LastSeen = [DateTime]::UtcNow }
        }
    }

    switch ($svc) {
        0x0201 {
            Write-Trace 'SEARCH_REQUEST'
            $hpai = New-KnxHpai -Ip '127.0.0.1' -Port $Port
            return , (New-SingleReply -Frame (New-KnxFrame -Service $K.Service.SEARCH_RESPONSE -Body ([byte[]]($hpai + (New-DeviceInfoDib) + (New-ServiceFamiliesDib)))))
        }
        0x0203 {
            Write-Trace 'DESCRIPTION_REQUEST'
            return , (New-SingleReply -Frame (New-KnxFrame -Service $K.Service.DESCRIPTION_RESPONSE -Body ([byte[]]((New-DeviceInfoDib) + (New-ServiceFamiliesDib) + (New-ExtendedDib)))))
        }
        0x0205 {
            # CONNECT_REQUEST: control HPAI (8) + data HPAI (8) + CRI.
            if ($body.Length -lt 18) { return , (New-ReplyList) }
            $cri = [byte[]]$body[16..($body.Length - 1)]
            $type = $cri[1]
            $layer = -1
            if ($cri.Length -ge 3) { $layer = $cri[2] }

            if ($type -ne $K.ConnType.TUNNEL_CONNECTION -and $type -ne $K.ConnType.DEVICE_MGMT_CONNECTION) {
                Write-Trace ("CONNECT_REQUEST type 0x{0:X2} -> E_CONNECTION_TYPE" -f $type)
                return , (New-SingleReply -Frame (New-KnxFrame -Service $K.Service.CONNECT_RESPONSE -Body ([byte[]]@(0x00, $K.Error.E_CONNECTION_TYPE))))
            }
            if ($type -eq $K.ConnType.TUNNEL_CONNECTION) {
                $known = @(0x02, 0x04, 0x80)
                if ($Role -eq 'Router') { $known = @(0x02, 0x04) }   # a router offers no busmonitor
                if ($known -notcontains $layer) {
                    if ($Misbehave -contains 'accept-bad-layer') { Write-Trace 'MISBEHAVE: accepting an undefined layer' 'Yellow' }
                    else {
                        Write-Trace ("CONNECT_REQUEST layer 0x{0:X2} -> E_CONNECTION_OPTION" -f $layer)
                        return , (New-SingleReply -Frame (New-KnxFrame -Service $K.Service.CONNECT_RESPONSE -Body ([byte[]]@(0x00, $K.Error.E_CONNECTION_OPTION))))
                    }
                }
            }

            $count = 0
            foreach ($chId in $state.Channels.Keys) { if ($state.Channels[$chId].Type -eq $type) { $count++ } }
            $limit = if ($type -eq $K.ConnType.TUNNEL_CONNECTION) { $MaxTunnels } else { $MaxDevMgmt }
            if ($count -ge $limit) {
                Write-Trace "CONNECT_REQUEST -> E_NO_MORE_CONNECTIONS ($count/$limit)"
                return , (New-SingleReply -Frame (New-KnxFrame -Service $K.Service.CONNECT_RESPONSE -Body ([byte[]]@(0x00, $K.Error.E_NO_MORE_CONNECTIONS))))
            }

            $addr = $null
            if ($type -eq $K.ConnType.TUNNEL_CONNECTION) {
                $addr = Get-FreeTunnelAddress
                if ($null -eq $addr) {
                    return , (New-SingleReply -Frame (New-KnxFrame -Service $K.Service.CONNECT_RESPONSE -Body ([byte[]]@(0x00, $K.Error.E_NO_MORE_CONNECTIONS))))
                }
            }

            $ch = $state.NextChannel
            $state.NextChannel = (($state.NextChannel % 254) + 1)
            $state.Channels[$ch] = [pscustomobject]@{ Type = $type; Address = $addr; Seq = 0; Layer = $layer; LastSeen = [DateTime]::UtcNow; Remote = $null }
            # The main loop records the endpoint. It must happen at CONNECT time: a tunnel
            # that only listens never sends anything, so waiting for its first frame would
            # leave it unreachable for exactly the indications it opened the tunnel for.
            $state.PendingChannel = $ch
            Write-Trace "CONNECT_REQUEST -> channel $ch$(if ($addr) { " address $addr" })" 'Green'

            $hpai = New-KnxHpai -Ip '127.0.0.1' -Port $Port
            if ($type -eq $K.ConnType.TUNNEL_CONNECTION) {
                $raw = ConvertTo-KnxPa -Address $addr
                $crd = [byte[]]@(0x04, 0x04, (($raw -shr 8) -band 0xFF), ($raw -band 0xFF))
            }
            else { $crd = [byte[]]@(0x02, 0x03) }
            return , (New-SingleReply -Frame (New-KnxFrame -Service $K.Service.CONNECT_RESPONSE -Body ([byte[]]@([byte]$ch, 0x00) + $hpai + $crd)))
        }
        0x0207 {
            if ($body.Length -lt 2) { return , (New-ReplyList) }
            $ch = $body[0]
            $status = $K.Error.E_CONNECTION_ID
            if ($state.Channels.ContainsKey([int]$ch)) { $status = $K.Error.E_NO_ERROR }
            if ($Misbehave -contains 'wrong-connstate-status') { Write-Trace 'MISBEHAVE: reporting E_NO_ERROR for any channel' 'Yellow'; $status = 0 }
            return , (New-SingleReply -Frame (New-KnxFrame -Service $K.Service.CONNECTIONSTATE_RESPONSE -Body ([byte[]]@($ch, [byte]$status))))
        }
        0x0209 {
            if ($body.Length -lt 2) { return , (New-ReplyList) }
            $ch = $body[0]
            $status = $K.Error.E_CONNECTION_ID
            if ($state.Channels.ContainsKey([int]$ch)) { $status = $K.Error.E_NO_ERROR; $state.Channels.Remove([int]$ch) }
            Write-Trace "DISCONNECT_REQUEST channel $ch -> $(Get-KnxErrorName -Status $status)"
            return , (New-SingleReply -Frame (New-KnxFrame -Service $K.Service.DISCONNECT_RESPONSE -Body ([byte[]]@($ch, [byte]$status))))
        }
        0x0310 {
            # DEVICE_CONFIGURATION_REQUEST: connection header (4) + cEMI.
            if ($body.Length -lt 5) { return , (New-ReplyList) }
            $ch = [int]$body[1]; $seq = $body[2]
            if (-not $state.Channels.ContainsKey($ch)) { Write-Trace "drop: config request on unknown channel $ch"; return , (New-ReplyList) }
            $cemi = [byte[]]$body[4..($body.Length - 1)]
            $out = New-ReplyList; [void]$out.Add((New-KnxDeviceConfigurationAck -Channel $ch -Sequence $seq))

            # Transport-layer frames are acknowledged; only the .req variants get an answer.
            if (@(0x94, 0x89) -contains $cemi[0]) { return , $out }
            if (@(0x4A, 0x41) -contains $cemi[0]) {
                $respMc = if ($cemi[0] -eq 0x4A) { 0x94 } else { 0x89 }
                $resp = New-CemiTransport -MessageCode $respMc -Tpdu (New-TpduPropertyValueResponse -Data ([byte[]]@(0x00, 0x00)))
                [void]$out.Add((New-KnxDeviceConfigurationRequest -Channel $ch -Sequence 0 -Cemi $resp))
                return , $out
            }

            if ($cemi[0] -eq 0xFC -and $cemi.Length -ge 7) {
                $ot = Get-Uint16 -Bytes $cemi -Offset 1
                $propId = $cemi[4]
                $data = Get-PropertyData -ObjectType $ot -PropertyId $propId
                if ($null -eq $data) {
                    # Error confirmation: element count 0, one error-code octet (Void DP).
                    $con = [byte[]]@(0xFB, $cemi[1], $cemi[2], $cemi[3], $cemi[4], 0x00, $cemi[6], 0x08)
                }
                else {
                    $con = [byte[]]@(0xFB, $cemi[1], $cemi[2], $cemi[3], $cemi[4], $cemi[5], $cemi[6]) + $data
                }
                [void]$out.Add((New-KnxDeviceConfigurationRequest -Channel $ch -Sequence 0 -Cemi $con))
                return , $out
            }
            if ($cemi[0] -eq 0xF6 -and $cemi.Length -ge 7) {
                $ot = Get-Uint16 -Bytes $cemi -Offset 1
                $propId = $cemi[4]
                # PID_CURRENT_IP_ADDRESS is read-only.
                if ($ot -eq $K.ObjType.KNXNETIP_PARAM -and $propId -eq 57) {
                    $con = [byte[]]@(0xF5, $cemi[1], $cemi[2], $cemi[3], $cemi[4], 0x00, $cemi[6], 0x03)
                }
                else {
                    if ($ot -eq $K.ObjType.KNXNETIP_PARAM -and $propId -eq 0x36 -and $cemi.Length -ge 8) { $state.ProgMode = $cemi[7] }
                    $con = [byte[]]@(0xF5, $cemi[1], $cemi[2], $cemi[3], $cemi[4], $cemi[5], $cemi[6])
                }
                [void]$out.Add((New-KnxDeviceConfigurationRequest -Channel $ch -Sequence 0 -Cemi $con))
                return , $out
            }
            return , $out
        }
        0x0420 {
            # TUNNELLING_REQUEST: acknowledge, then confirm with an L_Data.con.
            if ($body.Length -lt 5) { return , (New-ReplyList) }
            $ch = [int]$body[1]; $seq = $body[2]
            if (-not $state.Channels.ContainsKey($ch)) { return , (New-ReplyList) }
            $conn = $state.Channels[$ch]
            # A sequence one too large is not acknowledged at all.
            if ($seq -ne $conn.Seq -and $seq -ne ((($conn.Seq - 1) + 256) % 256)) {
                Write-Trace "drop: tunnel sequence $seq, expected $($conn.Seq)"
                return , (New-ReplyList)
            }
            $out = New-ReplyList; [void]$out.Add((New-KnxTunnellingAck -Channel $ch -Sequence $seq))
            if ($seq -eq $conn.Seq) {
                $conn.Seq = (($conn.Seq + 1) % 256)
                $cemi = [byte[]]$body[4..($body.Length - 1)]
                if ($cemi.Length -ge 1 -and $cemi[0] -eq 0x11) {
                    $con = [byte[]]$cemi.Clone()
                    $con[0] = 0x2E
                    [void]$out.Add((New-KnxTunnellingRequest -Channel $ch -Sequence 0 -Cemi $con))
                    # Loopback "bus": what one tunnel sends, every other tunnel sees as an
                    # indication. Without this the "from KNX" cases cannot be simulated at all.
                    [void]$state.BusQueue.Add([pscustomobject]@{ From = $ch; Cemi = $cemi })
                }
            }
            return , $out
        }
        0x0421 { return , (New-ReplyList) }
        0x0311 { return , (New-ReplyList) }
        default {
            Write-Trace ("ignore: service 0x{0:X4}" -f $svc)
            return , (New-ReplyList)
        }
    }
    return , (New-ReplyList)
}

function Get-BusDelivery {
    <#
    .SYNOPSIS
        Wraps a bus telegram as the indication the given channel expects.
    .DESCRIPTION
        A link-layer tunnel gets L_Data.ind, a busmonitor tunnel gets L_Busmon.ind with a
        status block and a real TP1 frame check octet, a raw tunnel gets L_Raw.ind.
    #>
    param([int]$Channel, [byte[]]$Cemi)
    $c = $state.Channels[$Channel]
    if ($null -eq $c) { return $null }
    switch ($c.Layer) {
        0x80 {
            $ld = Read-CemiLData -Cemi $Cemi
            if ($null -eq $ld) { return $null }
            # Rebuild a plausible TP1 LPDU and append the correct FCS.
            $lpdu = [byte[]]@($ld.Ctrl1,
                (($ld.Source -shr 8) -band 0xFF), ($ld.Source -band 0xFF),
                (($ld.Destination -shr 8) -band 0xFF), ($ld.Destination -band 0xFF),
                ((($ld.Ctrl2 -band 0xF0)) -bor ($ld.Length -band 0x0F))) + $ld.Tpdu
            $lpdu = [byte[]]($lpdu + (Get-Tp1Fcs -Bytes $lpdu))
            $bm = [byte[]]@(0x2B, 0x04, 0x03, 0x01, 0x00, 0x04) + $lpdu
            return (New-KnxTunnellingRequest -Channel $Channel -Sequence 0 -Cemi $bm)
        }
        0x04 {
            $raw = [byte[]]$Cemi.Clone()
            $raw[0] = 0x2D
            return (New-KnxTunnellingRequest -Channel $Channel -Sequence 0 -Cemi $raw)
        }
        default {
            $ind = [byte[]]$Cemi.Clone()
            $ind[0] = 0x29
            return (New-KnxTunnellingRequest -Channel $Channel -Sequence 0 -Cemi $ind)
        }
    }
}

function Get-PropertyData {
    param([int]$ObjectType, [int]$PropertyId)
    if ($ObjectType -eq $K.ObjType.KNXNETIP_PARAM) {
        switch ($PropertyId) {
            52 { $ia = ConvertTo-KnxPa -Address $IndividualAddress; return , ([byte[]]@((($ia -shr 8) -band 0xFF), ($ia -band 0xFF))) }
            64 { return , $mac }
            66 { return , $multicast }
            76 {
                $n = New-Object byte[] 30
                $b = [System.Text.Encoding]::ASCII.GetBytes($friendlyName)
                [Array]::Copy($b, $n, [Math]::Min(29, $b.Length))
                return , $n
            }
            0x36 { return , ([byte[]]@([byte]$state.ProgMode)) }
            55 {
                $d = [byte[]]@()
                foreach ($a in $tunnelAddresses) {
                    $raw = ConvertTo-KnxPa -Address $a
                    $d = [byte[]]($d + [byte[]]@((($raw -shr 8) -band 0xFF), ($raw -band 0xFF)))
                }
                return , $d
            }
            57 { return , ([byte[]]@(127, 0, 0, 1)) }
        }
        return $null
    }
    if ($ObjectType -eq $K.ObjType.DEVICE) {
        switch ($PropertyId) {
            1  { return , ([byte[]]@(0x00, 0x00)) }
            11 { return , $serial }
        }
        return $null
    }
    return $null
}

# ─── Listen ─────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '  Open ■' -ForegroundColor Green
Write-Host '  ┬────┴  Fake KNXnet/IP device' -ForegroundColor Green
Write-Host '  ■ KNX   2026 OpenKNX - Erkan Çolak' -ForegroundColor DarkGray
Write-Host ''
Write-Host "  Role          : $Role (mask 0x$('{0:X4}' -f $maskVersion))"
Write-Host "  Listening     : 0.0.0.0:$Port"
Write-Host "  Address       : $IndividualAddress"
Write-Host "  Tunnels       : $MaxTunnels  ($($tunnelAddresses -join ', '))"
Write-Host "  Device mgmt   : $MaxDevMgmt"
if ($Misbehave.Count -gt 0) { Write-Host "  Misbehave     : $($Misbehave -join ', ')" -ForegroundColor Yellow }
Write-Host ''

$sock = New-Object System.Net.Sockets.Socket([System.Net.Sockets.AddressFamily]::InterNetwork,
                                             [System.Net.Sockets.SocketType]::Dgram,
                                             [System.Net.Sockets.ProtocolType]::Udp)
$sock.ReceiveTimeout = 500
$sock.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $Port)))

$stop = $null
if ($Seconds -gt 0) { $stop = [DateTime]::UtcNow.AddSeconds($Seconds) }

try {
    while ($true) {
        if ($null -ne $stop -and [DateTime]::UtcNow -gt $stop) { break }

        # Reaper FIRST: a receive timeout continues the loop, so anything placed after the
        # receive would never run while the device is idle - which is precisely when an
        # idle connection has to be dropped (120 s, per the specification).
        $now = [DateTime]::UtcNow
        foreach ($chId in @($state.Channels.Keys)) {
            $c = $state.Channels[$chId]
            if (($now - $c.LastSeen).TotalSeconds -lt 120) { continue }
            Write-Trace "reaper: dropping idle channel $chId" 'Yellow'
            if ($state.Endpoints.ContainsKey($chId)) {
                $hpai = New-KnxHpai -Ip '127.0.0.1' -Port $Port
                $dis = New-KnxFrame -Service $K.Service.DISCONNECT_REQUEST -Body ([byte[]]@([byte]$chId, 0x00) + $hpai)
                [void]$sock.SendTo($dis, $state.Endpoints[$chId])
                $state.Endpoints.Remove($chId)
            }
            $state.Channels.Remove($chId)
        }

        $buf = New-Object byte[] 1024
        $remote = [System.Net.EndPoint](New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0))
        $n = 0
        try { $n = $sock.ReceiveFrom($buf, [ref]$remote) }
        catch [System.Net.Sockets.SocketException] { continue }
        if ($n -le 0) { continue }
        $frame = [byte[]]$buf[0..($n - 1)]
        # Remember which endpoint owns which channel, so unsolicited frames (bus
        # indications, reaper disconnects) can be delivered without a request to answer.
        if ($n -ge 8 -and $frame[0] -eq 0x06) {
            $svcPeek = Get-Uint16 -Bytes $frame -Offset 2
            if (@(0x0310, 0x0420, 0x0311, 0x0421) -contains $svcPeek) {
                $chPeek = [int]$frame[7]
                if ($state.Channels.ContainsKey($chPeek)) { $state.Endpoints[$chPeek] = $remote }
            }
            elseif (@(0x0207, 0x0209) -contains $svcPeek) {
                $chPeek = [int]$frame[6]
                if ($state.Channels.ContainsKey($chPeek)) { $state.Endpoints[$chPeek] = $remote }
            }
        }

        $replies = New-ReplyList
        try { $replies = Get-Reply -Frame $frame }
        catch {
            Write-Trace "handler error: $($_.Exception.Message)" 'Red'
            Write-Trace "  at $($_.ScriptStackTrace -replace "`n", ' | ')" 'Red'
        }
        foreach ($r in $replies) {
            if ($null -ne $r -and $r.Length -gt 0) { [void]$sock.SendTo($r, $remote) }
        }

        if ($state.PendingChannel -ge 0) {
            $state.Endpoints[$state.PendingChannel] = $remote
            $state.PendingChannel = -1
        }

        # Deliver the loopback bus to every OTHER tunnel.
        if ($state.BusQueue.Count -gt 0) {
            $pending = @($state.BusQueue.ToArray())
            $state.BusQueue.Clear()
            foreach ($item in $pending) {
                foreach ($chId in @($state.Channels.Keys)) {
                    if ($chId -eq $item.From) { continue }
                    $c = $state.Channels[$chId]
                    if ($c.Type -ne $K.ConnType.TUNNEL_CONNECTION) { continue }
                    if (-not $state.Endpoints.ContainsKey($chId)) { continue }
                    $ind = Get-BusDelivery -Channel $chId -Cemi $item.Cemi
                    if ($null -eq $ind) { continue }
                    [void]$sock.SendTo($ind, $state.Endpoints[$chId])
                }
            }
        }

    }
}
finally {
    $sock.Dispose()
    Write-Host ''
    Write-Host '  Fake device stopped.' -ForegroundColor DarkGray
    Write-Host ''
}
