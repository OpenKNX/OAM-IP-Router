#!/usr/bin/env pwsh
# Open ■
# ┬────┴  KnxDevice
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/lib/KnxDevice.psm1

<#
.SYNOPSIS
    The device layer: sessions, services and helpers for talking to a KNX device through a tunnel.

.DESCRIPTION
    KnxTest.psm1 builds and parses frames. This module sits one level up: it owns the connection to a
    DEVICE - the transport session, the service exchange, the property and memory reads, the
    busmonitor witness - and knows nothing about test cases.

    It used to live inside Suites/D-Device.Tests.ps1, which meant every helper was defined in a test
    file and nothing else could use it. Splitting it out is what makes a second device suite possible
    without copying code.

    Load order: KnxTest.psm1 first (this module calls into it), then this one, then the suites.
#>

Set-StrictMode -Version Latest

# Module-owned state and constants. After the split out of the suite file these could no longer be
# read from the caller's scope - a module sees its own, not the script's.
$script:tlBaselineCache = @{}
$script:KnxPidLoadState = 5   # PID_LOAD_STATE_CONTROL (03_05_01; lib/knx property.h)
$script:KnxPidRunState  = 6   # PID_RUN_STATE_CONTROL
# Rig power guard (Assert-KnxRigPower)
$script:KnxRigStatusTimeoutMs = 2000   # wait for one A_GroupValue_Response of a relay status
$script:KnxRigSwitchSettleMs  = 1000   # after the ON write, before the status is read again
$script:KnxRigDutBackSeconds  = 30     # poll window for the device under test after a restore
$script:KnxRigDutPollMs       = 1500   # one DeviceDescriptor_Read attempt during that window
# KNX-fault injection through the rig relays (Device state stage)
$script:KnxFaultPollMs        = 500    # CONNECTIONSTATE_REQUEST interval while a relay is cut
$script:KnxFaultConnStateMs   = 10000  # E_KNX_CONNECTION after the cut (TSSH 10503)
$script:KnxFaultPropInfoMs    = 20000  # M_PropInfo.ind PID 69 bit 0 = 1 after the cut (TSSH 20212)
$script:KnxFaultClearMs       = 5000   # bit 0 = 0 and CONNECTIONSTATE 0x00 after the restore write
$script:KnxFaultRestoreMs     = 10000  # retry window for the restore write, and again for its ON confirmation
$script:KnxFaultRetryMs       = 1000   # pause between two restore attempts
# ─── Device model ───────────────────────────────────────────────────────────────

function Get-KnxDeviceFamily {
    <#
    .SYNOPSIS
        Maps a mask version to the device family that decides which cases apply.
    .DESCRIPTION
        The ranges are the ones the firmware itself uses (OFM-FileTransferModule
        KnxDeviceMap.h), so a device classified here is classified the same way by oknx.
        Anything unknown is reported as such rather than guessed into a family - a wrong
        family silently turns applicable cases into N-A, which reads like a clean run.
    #>
    param([Parameter(Mandatory)][int]$Mask)
    if ($Mask -ge 0x0010 -and $Mask -le 0x0012) { return 'BCU1' }
    if ($Mask -ge 0x0020 -and $Mask -le 0x0025) { return 'BCU2' }
    if ($Mask -ge 0x0300 -and $Mask -le 0x0305) { return 'System300' }
    if ($Mask -ge 0x0700 -and $Mask -le 0x0705) { return 'System7' }
    if (($Mask -band 0x0FF0) -eq 0x07B0 -or $Mask -eq 0x091A) { return 'SystemB' }
    if (($Mask -band 0xF000) -eq 0x1000) { return 'RF' }
    return 'unknown'
}

function Test-KnxFamilyHasProperties {
    <#
    .SYNOPSIS
        True when interface-object property access is part of the family's device model.
    .DESCRIPTION
        BCU1 and BCU2 are memory-mapped; property services are not required of them, so a
        silent device there is a declaration, not a defect. System 7 and System B carry the
        interface-object layer and must answer.
    #>
    param([Parameter(Mandatory)][string]$Family)
    return ($Family -in @('System7', 'SystemB', 'System300'))
}

# ─── Wire helpers ───────────────────────────────────────────────────────────────

function New-TpduService {
    <#
    .SYNOPSIS
        Builds a TPDU for a 10-bit application service, numbered or unnumbered.
    .DESCRIPTION
        The APCI spans the low two bits of the TPCI octet and all eight bits of the next,
        so the service code cannot simply be appended - it has to be split across the
        transport control field. Sequence -1 builds T_Data_Individual (connectionless),
        anything else builds T_Data_Connected with that sequence number
        (03_03_04 clause 2, Figure 3).
    #>
    param([Parameter(Mandatory)][int]$Apci, [byte[]]$Data = @(), [int]$Sequence = -1)
    $tpci = 0x00
    if ($Sequence -ge 0) { $tpci = 0x40 -bor (($Sequence -band 0x0F) -shl 2) }
    $head = [byte[]]@( (($tpci -bor (($Apci -shr 8) -band 0x03)) -band 0xFF), ($Apci -band 0xFF) )
    if ($null -eq $Data -or $Data.Length -eq 0) { return , $head }
    return , ([byte[]]($head + $Data))
}

function Get-KnxTpduKind {
    <#
    .SYNOPSIS
        Classifies a received TPDU by its transport control field.
    .DESCRIPTION
        Returns Connect, Disconnect, Ack, Nak, Numbered, Unnumbered or Empty, plus the
        sequence number where the field carries one. The order of the tests matters: the
        control encodings (10xxxxxx / 11xxxxxx) must be recognised before the data ones,
        because a numbered data PDU and a T_ACK differ only in bits 6 and 7.
    #>
    param([byte[]]$Tpdu)
    if ($null -eq $Tpdu -or $Tpdu.Length -lt 1) { return [pscustomobject]@{ Kind = 'Empty'; Sequence = -1 } }
    $t = [int]$Tpdu[0]
    $seq = ($t -shr 2) -band 0x0F
    if ($t -eq 0x80) { return [pscustomobject]@{ Kind = 'Connect';    Sequence = -1 } }
    if ($t -eq 0x81) { return [pscustomobject]@{ Kind = 'Disconnect'; Sequence = -1 } }
    if (($t -band 0xC3) -eq 0xC2) { return [pscustomobject]@{ Kind = 'Ack'; Sequence = $seq } }
    if (($t -band 0xC3) -eq 0xC3) { return [pscustomobject]@{ Kind = 'Nak'; Sequence = $seq } }
    if (($t -band 0xC0) -eq 0x40) { return [pscustomobject]@{ Kind = 'Numbered';   Sequence = $seq } }
    return [pscustomobject]@{ Kind = 'Unnumbered'; Sequence = -1 }
}

function Test-KnxConPositive {
    <#
    .SYNOPSIS
        True when an L_Data.con reports the telegram as successfully transmitted.
    .DESCRIPTION
        In an L_Data.con the lowest bit of the first control field is the confirm flag:
        0 = transmitted, 1 = error (03_06_03 clause 4.1.5.3). This is the only signal that
        distinguishes "the device on the bus acknowledged" from "nothing was there" - the
        TUNNELLING_ACK only proves the interface accepted the request.
    #>
    param([Parameter(Mandatory)]$LData)
    return (([int]$LData.Ctrl1 -band 0x01) -eq 0)
}

# ─── Session over a tunnel ──────────────────────────────────────────────────────


function Get-KnxDeviceMemory {
    <#
    .SYNOPSIS
        Reads a block of device memory with A_Memory_Read, in chunks that fit one APDU.
    .DESCRIPTION
        The octet count rides in the low six bits of the APCI octet, and the answer echoes the
        address it read. The echo is verified on every chunk: a device that answers a DIFFERENT
        address would otherwise be assembled into a silently wrong block.
    #>
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][int]$Address, [Parameter(Mandatory)][int]$Length, [int]$Chunk = 12)
    $K = Get-KnxConstants
    $out = New-Object System.Collections.Generic.List[byte]
    $addr = $Address
    $left = $Length
    # A System B device answers the EXTENDED read (three address octets); the classic one is limited
    # to 64 KB and several devices do not serve it at all - measured: no answer at address 0, while
    # the extended read works. The classic service stays as the fallback for older devices.
    while ($left -gt 0) {
        $n = [Math]::Min($Chunk, $left)
        $got = 0
        $r = Invoke-KnxDeviceService -Session $Session -Apci $K.Apci.MEMORY_EXT_READ `
                                     -Data ([byte[]]@($n, (($addr -shr 16) -band 0xFF), (($addr -shr 8) -band 0xFF), ($addr -band 0xFF))) `
                                     -ExpectApci $K.Apci.MEMORY_EXT_READ_RESPONSE -TimeoutMs 6000
        if ($null -ne $r.Response -and $r.Response.Length -ge 6 -and [int]$r.Response[2] -eq 0) {
            $echo = ((([int]$r.Response[3]) -shl 16) -bor (([int]$r.Response[4]) -shl 8)) -bor [int]$r.Response[5]
            if ($echo -ne $addr) { return $null }
            for ($i = 6; $i -lt $r.Response.Length; $i++) { [void]$out.Add($r.Response[$i]) }
            $got = $r.Response.Length - 6
        }
        else {
            $r = Invoke-KnxDeviceService -Session $Session -Apci ($K.Apci.MEMORY_READ -bor $n) `
                                         -Data ([byte[]]@((($addr -shr 8) -band 0xFF), ($addr -band 0xFF))) `
                                         -ExpectApci $K.Apci.MEMORY_RESPONSE -TimeoutMs 6000
            if ($null -eq $r.Response -or $r.Response.Length -lt 5) { return $null }
            $echo = (([int]$r.Response[2]) -shl 8) -bor [int]$r.Response[3]
            if ($echo -ne ($addr -band 0xFFFF)) { return $null }
            for ($i = 4; $i -lt $r.Response.Length; $i++) { [void]$out.Add($r.Response[$i]) }
            $got = $r.Response.Length - 4
        }
        if ($got -le 0) { return $null }
        $addr += $got
        $left -= $got
    }
    return , $out.ToArray()
}

function Get-KnxDeviceGroupAddresses {
    <#
    .SYNOPSIS
        Returns the group addresses a device is configured for, read from its own address table.
    .DESCRIPTION
        Not guessed and not taken from a parameter: PID_TABLE_REFERENCE (7) on the address table
        object gives the memory address, and the table there is one count word followed by one word
        per entry (knx/src/knx/address_table_object.cpp). That is how ETS finds them too, and it
        means the GA cases test the addresses the device ACTUALLY has.
    #>
    param([Parameter(Mandatory)]$Session)
    $K = Get-KnxConstants
    $ref = Read-KnxDeviceProperty -Session $Session -ObjectIndex 1 -PropertyId 7
    if (-not $ref.Ok -or $ref.Data.Length -lt 2) { return @() }
    $addr = 0
    foreach ($b in $ref.Data) { $addr = ($addr -shl 8) -bor [int]$b }
    if ($addr -eq 0) { return @() }

    $head = Get-KnxDeviceMemory -Session $Session -Address $addr -Length 2
    if ($null -eq $head -or $head.Length -lt 2) { return @() }
    $count = (([int]$head[0]) -shl 8) -bor [int]$head[1]
    if ($count -le 0 -or $count -gt 500) { return @() }

    $body = Get-KnxDeviceMemory -Session $Session -Address ($addr + 2) -Length ($count * 2)
    if ($null -eq $body) { return @() }
    $list = @()
    for ($i = 0; ($i + 1) -lt $body.Length; $i += 2) {
        $raw = (([int]$body[$i]) -shl 8) -bor [int]$body[$i + 1]
        if ($raw -ne 0) { $list += (ConvertFrom-KnxGa -Raw $raw) }
    }
    # No comma: the caller collects with @(), and a comma here nests the whole list into one element.
    return $list
}

function Open-KnxBusWitness {
    <#
    .SYNOPSIS
        Opens a busmonitor on a SECOND interface, so the bus is observed by something other than
        the interface that sends.
    .DESCRIPTION
        Every other case here sends through a tunnel and reads the answer back through the SAME
        tunnel - the interface is then both actor and witness, and anything it drops or invents is
        invisible. A busmonitor on a different interface reports the raw LPDUs as they were on the
        line, which is the only way to say what really happened.

        Returns Ok=$false with a reason when no second interface was given or the busmonitor is
        taken - the caller then reports what it could and could not observe, instead of pretending.
    #>
    param([string]$WitnessIp, [int]$Port = 3671, [string]$TargetPa = '', [string]$BdutIp = '')
    if (-not $WitnessIp) { return [pscustomobject]@{ Ok = $false; Reason = 'no witness interface given (-WitnessIp)'; Conn = $null } }
    $wAddr = $null
    if (-not [System.Net.IPAddress]::TryParse($WitnessIp, [ref]$wAddr)) {
        return [pscustomobject]@{ Ok = $false; Reason = "witness '$WitnessIp' is not an IP address"; Conn = $null }
    }
    # The interface the case sends through cannot watch: a busmonitor there closes or refuses its tunnels.
    $bAddr = $null
    if ($BdutIp -and [System.Net.IPAddress]::TryParse($BdutIp, [ref]$bAddr) -and $wAddr.Equals($bAddr)) {
        return [pscustomobject]@{ Ok = $false; Reason = "witness $WitnessIp is the interface the case sends through"; Conn = $null }
    }
    # A busmonitor switches the witness's bus side to passive. When the witness IS the device under test,
    # that silences the very answers the case waits for. Compared as raw values, not as text.
    if ($TargetPa) {
        $desc = Get-KnxDescription -Ip $WitnessIp -Port $Port
        if ($null -ne $desc -and $null -ne $desc.Device -and
            (ConvertTo-KnxPa -Address $desc.Device.IndividualAddr) -eq (ConvertTo-KnxPa -Address $TargetPa)) {
            return [pscustomobject]@{ Ok = $false; Reason = "witness $WitnessIp is the device under test ($TargetPa); a busmonitor there would silence it"; Conn = $null }
        }
    }
    $K = Get-KnxConstants
    $bm = Open-KnxConnection -Ip $WitnessIp -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_BUSMONITOR
    if (-not $bm.Ok) { return [pscustomobject]@{ Ok = $false; Reason = "no busmonitor on $WitnessIp ($($bm.StatusName))"; Conn = $null } }
    [void](Clear-KnxTunnelTraffic -Connection $bm -QuietMs 400)
    return [pscustomobject]@{ Ok = $true; Reason = ''; Conn = $bm }
}

function Read-KnxBusWitness {
    <#
    .SYNOPSIS
        Drains what the busmonitor saw and returns the decoded LPDUs.
    #>
    param([Parameter(Mandatory)]$Witness, [int]$WindowMs = 2500)
    $K = Get-KnxConstants
    $frames = @()
    $deadline = [DateTime]::UtcNow.AddMilliseconds($WindowMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $in = Receive-KnxTunnelCemi -Connection $Witness.Conn -TimeoutMs 400
        if ($null -eq $in) { continue }
        if ($in.Cemi[0] -ne $K.Cemi.L_BUSMON_IND) { continue }
        $d = Read-CemiBusmon -Cemi $in.Cemi
        if ($null -ne $d) { $frames += $d }
    }
    return , @($frames)
}

function Open-KnxDeviceSession {
    <#
    .SYNOPSIS
        Opens a tunnel and, on it, a connection-oriented transport session to one device.
    .DESCRIPTION
        Returns a session object carrying its own SeqSend / SeqRecv, because the transport
        state machine keeps one counter per direction and mixing them up produces a T_NAK
        that looks like a device defect. Ok=$false with a Reason instead of throwing, so a
        caller can report SKIP with the real cause rather than a stack trace.
    .PARAMETER Connect
        Establish the connection-oriented session. Without it the session is opened for
        connectionless use only and no T_Connect is sent.
    #>
    param(
        [Parameter(Mandatory)][string]$Ip,
        [int]$Port = 3671,
        [Parameter(Mandatory)][string]$Pa,
        [switch]$Connect,
        [int]$TimeoutMs = 3000
    )
    $K = Get-KnxConstants
    $c = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION `
                            -Layer $K.Layer.TUNNEL_LINKLAYER -TimeoutMs $TimeoutMs
    if (-not $c.Ok) {
        return [pscustomobject]@{ Ok = $false; Reason = "no tunnel on $Ip ($($c.StatusName))"; Conn = $null }
    }
    $s = [pscustomobject]@{
        Ok        = $true
        Reason    = ''
        # Destination 0 is only a broadcast when the address type says "group". Sent with the
        # individual type the device discards it as malformed ("Invalid broadcast detected") and the
        # case then reports "service not supported" about a device that never saw the request.
        Broadcast = ($Pa -eq '0.0.0')
        Conn      = $c
        Pa        = $Pa
        Dst       = (ConvertTo-KnxPa -Address $Pa)
        SeqSend   = 0
        SeqRecv   = 0
        Connected = $false
        LastCon   = $null
    }
    if (-not $Connect) { return $s }

    $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $s.Dst -Tpdu (New-TpduConnect) -Priority 0
    $r = Send-KnxTunnelCemi -Connection $c -Cemi $cemi -TimeoutMs $TimeoutMs
    if (-not $r.Acked) {
        [void](Close-KnxConnection -Connection $c)
        return [pscustomobject]@{ Ok = $false; Reason = 'the interface did not acknowledge the T_Connect'; Conn = $null }
    }
    # The T_Connect itself is never answered on layer 7 - the proof that a device is there
    # is the confirmation: a negative one means nothing on the bus acknowledged the frame.
    $con = Wait-KnxDeviceConfirmation -Session $s -TimeoutMs 3000
    $s.LastCon = $con
    if ($null -ne $con -and -not (Test-KnxConPositive -LData $con)) {
        # One negative confirmation is not proof of an absent device: a device still busy
        # with the previous case answers BUSY on layer 2, and the confirmation then looks
        # exactly like "nobody is there". Pause and try once more - declaring the device
        # gone here made five cases SKIP against a device that was demonstrably alive in
        # the case before and the case after.
        [void](Wait-KnxTunnel -Connection $c -Ms 400)
        $r2 = Send-KnxTunnelCemi -Connection $c -Cemi $cemi -TimeoutMs $TimeoutMs
        $con = $null
        if ($r2.Acked) { $con = Wait-KnxDeviceConfirmation -Session $s -TimeoutMs 3000 }
        $s.LastCon = $con
        if ($null -eq $con -or -not (Test-KnxConPositive -LData $con)) {
            [void](Close-KnxConnection -Connection $c)
            return [pscustomobject]@{ Ok = $false; Reason = "no device answered at $Pa (negative L_Data.con twice)"; Conn = $null }
        }
    }
    $s.Connected = $true
    return $s
}

function Close-KnxDeviceSession {
    <#
    .SYNOPSIS
        Releases the transport session and the tunnel underneath it.
    .DESCRIPTION
        A session left open holds the device in OPEN_IDLE for its full six-second
        connection timeout, and the next case then meets a device that answers a fresh
        T_Connect from a different state. Always call this, including on the error paths.
    #>
    param($Session)
    if ($null -eq $Session -or -not $Session.Ok -or $null -eq $Session.Conn) { return }
    $K = Get-KnxConstants
    if ($Session.Connected) {
        try {
            $d = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $Session.Dst `
                               -Tpdu (New-TpduDisconnect) -Priority 0
            [void](Send-KnxTunnelCemi -Connection $Session.Conn -Cemi $d -TimeoutMs 2000)
        }
        catch { }
        $Session.Connected = $false
    }
    try { [void](Close-KnxConnection -Connection $Session.Conn) } catch { }
}

function Wait-KnxDeviceConfirmation {
    <#
    .SYNOPSIS
        Waits for the L_Data.con belonging to this session's destination.
    .DESCRIPTION
        Confirmations for other destinations can still be in flight from a preceding case,
        so the destination is matched rather than the first frame taken - taking the first
        one reported a foreign confirmation as this device's answer.
    #>
    param([Parameter(Mandatory)]$Session, [int]$TimeoutMs = 3000)
    $K = Get-KnxConstants
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
        $in = Receive-KnxTunnelCemi -Connection $Session.Conn -TimeoutMs $left
        if ($null -eq $in) { return $null }
        $ld = Read-CemiLData -Cemi $in.Cemi
        if ($null -eq $ld) { continue }
        if ($ld.MessageCode -ne $K.Cemi.L_DATA_CON) { continue }
        if ($ld.Destination -ne $Session.Dst) { continue }
        return $ld
    }
    return $null
}

function Send-KnxDeviceTpdu {
    <#
    .SYNOPSIS
        Puts one TPDU on the bus towards the session's device and returns the confirmation.
    #>
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][byte[]]$Tpdu, [int]$TimeoutMs = 3000,
          [int]$HopCount = 6)
    $K = Get-KnxConstants
    $bc = $false
    if ($Session.PSObject.Properties['Broadcast']) { $bc = [bool]$Session.Broadcast }
    $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $Session.Dst -Tpdu $Tpdu -Priority 0 -IsGroup:$bc -HopCount $HopCount
    $r = Send-KnxTunnelCemi -Connection $Session.Conn -Cemi $cemi -TimeoutMs $TimeoutMs
    return [pscustomobject]@{ Acked = $r.Acked; Status = $r.Status; Sent = $cemi }
}

function Test-KnxAddressedToSession {
    <#
    .SYNOPSIS
        True when an individual frame is addressed to this session's tunnel, or the tunnel address is unknown.
    .DESCRIPTION
        The tunnel forwards everything the target sends, including frames to other partners; a case that
        judges the target by its reply must only count the ones addressed to itself.
    #>
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$LData)
    if ($LData.IsGroup) { return $false }
    $tp = ''
    if ($null -ne $Session.Conn -and $Session.Conn.PSObject.Properties['TunnelPa']) { $tp = [string]$Session.Conn.TunnelPa }
    if (-not $tp -or $tp -eq '0.0.0') { return $true }
    return ($LData.Destination -eq (ConvertTo-KnxPa -Address $tp))
}

function Invoke-KnxDeviceService {
    <#
    .SYNOPSIS
        Runs one application service against the device and collects the whole exchange.
    .DESCRIPTION
        Connection-oriented, this is three telegrams, not one: our numbered request, the
        device's T_ACK, and the device's numbered answer - which WE then have to acknowledge
        or the device repeats it three times and drops the connection (03_03_04 clause 5.3,
        action A2). Everything that arrives inside the window is classified and kept, so a
        case can assert on what did NOT happen as precisely as on what did.

        The sequence counters advance here and only here: SeqSend after the device
        acknowledged our request, SeqRecv after we acknowledged the device's answer.
    .PARAMETER ForceSequence
        Send with this sequence number instead of the session's. For the cases that
        deliberately repeat or skip a number - the counters are then left untouched.
    .PARAMETER Connectionless
        Send as T_Data_Individual. No sequence numbers, no acknowledges, one answer.
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][int]$Apci,
        [byte[]]$Data = @(),
        [int]$ExpectApci = -1,
        [int]$TimeoutMs = 6000,
        [int]$ForceSequence = -1,
        [switch]$Connectionless,
        [switch]$NoAckResponse,
        [int]$ExpectSource = -1,  # broadcast sessions: only this raw address counts as the answer
        [int]$HopCount = 6        # 08_03_03: the routing counter the REQUEST carries
    )
    $K = Get-KnxConstants
    $seq = -1
    if (-not $Connectionless) {
        $seq = if ($ForceSequence -ge 0) { $ForceSequence } else { $Session.SeqSend }
    }
    $tpdu = New-TpduService -Apci $Apci -Data $Data -Sequence $seq
    $sent = Send-KnxDeviceTpdu -Session $Session -Tpdu $tpdu -TimeoutMs 3000 -HopCount $HopCount

    $bc = $false
    if ($Session.PSObject.Properties['Broadcast']) { $bc = [bool]$Session.Broadcast }
    $ownPa = -1
    if ($null -ne $Session.Conn -and $Session.Conn.PSObject.Properties['TunnelPa'] -and $Session.Conn.TunnelPa -and
        [string]$Session.Conn.TunnelPa -ne '0.0.0') {
        $ownPa = ConvertTo-KnxPa -Address ([string]$Session.Conn.TunnelPa)
    }

    $out = [pscustomobject]@{
        Sent         = $sent.Sent
        SentTpdu     = $tpdu
        TunnelAcked  = $sent.Acked
        Confirmed    = $null      # $true / $false / $null when no L_Data.con arrived
        Acked        = $false     # device sent T_ACK for our sequence
        AckSequence  = -1
        Nak          = $false
        NakSequence  = -1
        Disconnected = $false
        Response     = $null      # the response TPDU
        ResponseApci = -1
        ResponseSource = -1       # raw individual address of the device that answered
        Frames       = @()
        Others       = @()        # broadcast answers from a device other than -ExpectSource
        Strangers    = @()        # individual frames to this tunnel from a device other than the target
    }
    if (-not $sent.Acked) { return $out }

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
        $in = Receive-KnxTunnelCemi -Connection $Session.Conn -TimeoutMs $left
        if ($null -eq $in) { break }
        $ld = Read-CemiLData -Cemi $in.Cemi
        if ($null -eq $ld) { continue }

        if ($ld.MessageCode -eq $K.Cemi.L_DATA_CON -and $ld.Destination -eq $Session.Dst) {
            $out.Confirmed = (Test-KnxConPositive -LData $ld)
            continue
        }
        if ($ld.MessageCode -ne $K.Cemi.L_DATA_IND) { continue }
        if ($bc) {
            # A broadcast service is answered by broadcast from the answering device's own address, so
            # matching the source against destination 0 discarded every answer.
            if (-not ($ld.IsGroup -and $ld.Destination -eq 0)) { continue }
            if ($ExpectSource -ge 0 -and $ld.Source -ne $ExpectSource) {
                if ($ExpectApci -lt 0 -or ($ld.Tpdu.Length -ge 2 -and (Get-TpduApci -Tpdu $ld.Tpdu) -eq $ExpectApci)) { $out.Others += $ld }
                continue
            }
        }
        else {
            # An answer comes from the target and is addressed to this tunnel. The target's own group
            # telegrams are not one; taking one ended the wait before the T_ACK and desynced SeqSend.
            if ($ld.IsGroup) { continue }
            if ($ownPa -ge 0 -and $ld.Destination -ne $ownPa) { continue }
            # Without a known tunnel address every individual frame on the line would count as one to us.
            if ($ld.Source -ne $Session.Dst) { if ($ownPa -ge 0) { $out.Strangers += $ld }; continue }
        }
        $out.Frames += $ld

        $kind = Get-KnxTpduKind -Tpdu $ld.Tpdu
        switch ($kind.Kind) {
            'Ack' {
                $out.Acked = $true; $out.AckSequence = $kind.Sequence
                if ($seq -ge 0 -and $kind.Sequence -eq $seq -and $ForceSequence -lt 0) {
                    $Session.SeqSend = (($Session.SeqSend + 1) -band 0x0F)
                }
            }
            'Nak'        { $out.Nak = $true; $out.NakSequence = $kind.Sequence }
            'Disconnect' { $out.Disconnected = $true; $Session.Connected = $false }
            'Numbered' {
                if ($ld.Tpdu.Length -ge 2) {
                    $out.Response = $ld.Tpdu
                    $out.ResponseApci = (Get-TpduApci -Tpdu $ld.Tpdu)
                    $out.ResponseSource = $ld.Source
                }
                if (-not $NoAckResponse) {
                    # Acknowledging is not politeness: without it the device repeats the
                    # answer three times and then disconnects, and every following case in
                    # this session fails for a reason that started here.
                    $ack = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $Session.Dst `
                                         -Tpdu (New-TpduAck -Sequence $kind.Sequence) -Priority 0
                    [void](Send-KnxTunnelCemi -Connection $Session.Conn -Cemi $ack -TimeoutMs 2000)
                    $Session.SeqRecv = (($kind.Sequence + 1) -band 0x0F)
                }
            }
            'Unnumbered' {
                if ($ld.Tpdu.Length -ge 2) {
                    $out.Response = $ld.Tpdu
                    $out.ResponseApci = (Get-TpduApci -Tpdu $ld.Tpdu)
                    $out.ResponseSource = $ld.Source
                }
            }
        }
        if ($null -ne $out.Response) {
            if ($ExpectApci -lt 0 -or $out.ResponseApci -eq $ExpectApci) { break }
            # Not the service we asked for - keep listening, it may still arrive.
            $out.Response = $null; $out.ResponseApci = -1; $out.ResponseSource = -1
        }
        if ($out.Nak -or $out.Disconnected) { break }
    }
    return $out
}

function Read-KnxDeviceProperty {
    <#
    .SYNOPSIS
        Reads one interface-object property from the device and returns its data octets.
    .DESCRIPTION
        The prescribed error answer is an A_PropertyValue_Response with nr_of_elem = 0 and
        no data (03_03_07 clause 3.4.4.1, p.63), so "answered" and "answered successfully"
        are different questions and both are reported. Count and StartIndex are echoed back
        by the device; they are returned so a caller can verify the echo instead of
        assuming it.
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [int]$ObjectIndex = 0,
        [Parameter(Mandatory)][int]$PropertyId,
        [int]$ElementCount = 1,
        [int]$StartIndex = 1,
        [int]$TimeoutMs = 6000
    )
    $K = Get-KnxConstants
    $payload = [byte[]]@(
        ($ObjectIndex -band 0xFF),
        ($PropertyId -band 0xFF),
        (((($ElementCount -band 0x0F) -shl 4)) -bor (($StartIndex -shr 8) -band 0x0F)),
        ($StartIndex -band 0xFF)
    )
    $r = Invoke-KnxDeviceService -Session $Session -Apci $K.Apci.PROPERTY_VALUE_READ -Data $payload `
                                 -ExpectApci $K.Apci.PROPERTY_VALUE_RESPONSE -TimeoutMs $TimeoutMs
    $res = [pscustomobject]@{
        Answered     = ($null -ne $r.Response)
        Ok           = $false
        ObjectIndex  = -1
        PropertyId   = -1
        ElementCount = -1
        StartIndex   = -1
        Data         = [byte[]]@()
        Exchange     = $r
    }
    if ($null -ne $r.Response -and $r.Response.Length -ge 6) {
        $res.ObjectIndex  = [int]$r.Response[2]
        $res.PropertyId   = [int]$r.Response[3]
        $res.ElementCount = (([int]$r.Response[4]) -shr 4) -band 0x0F
        $res.StartIndex   = (((([int]$r.Response[4]) -band 0x0F) -shl 8) -bor [int]$r.Response[5])
        if ($r.Response.Length -gt 6) { $res.Data = [byte[]]$r.Response[6..($r.Response.Length - 1)] }
        $res.Ok = ($res.ElementCount -gt 0 -and $res.Data.Length -gt 0)
    }
    return $res
}

# ─── The suite ──────────────────────────────────────────────────────────────────

function Set-KnxDeviceProgMode {
    <#
    .SYNOPSIS
        Puts a device into programming mode, or takes it out, and proves the result on the bus.
    .DESCRIPTION
        PID_PROG_MODE is writable over the bus - that is how ETS does it, and how the restore at the end
        of G-1.1 already switched it off. So the case does not need a finger on the programming button
        and does not need a console: it writes the bit, reads it back, and only asks for a human when
        the device refuses the write.

        The console route was tried first and is recorded here as a warning: the OpenKNX console has
        'p' for the same purpose, and a TP device is reachable with 'ftc <pa> con'. But the tunnel is
        interactive, and a line sent right after it went to the LOCAL console instead - measured on this
        rig, that put the ROUTER into programming mode while the intended target stayed untouched. Do not
        drive that tunnel line by line.
    .OUTPUTS
        '' when the device now holds the wanted state, otherwise the reason it does not.
    #>
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][bool]$On,
        [Parameter(Mandatory)][string]$Ip,
        [int]$Port = 3671
    )
    $K = Get-KnxConstants
    $ses = Open-KnxDeviceSession -Ip $Ip -Port $Port -Pa $Target -Connect
    if (-not $ses.Ok) { return "no session to $Target - $($ses.Reason)" }
    try {
        $value = if ($On) { 0x01 } else { 0x00 }
        [void](Invoke-KnxDeviceService -Session $ses -Apci $K.Apci.PROPERTY_VALUE_WRITE `
                                       -Data ([byte[]]@(0x00, $K.Pid.PROG_MODE, 0x10, 0x01, $value)) `
                                       -ExpectApci $K.Apci.PROPERTY_VALUE_RESPONSE -TimeoutMs 3000)
        # The answer to the write is not the proof; the value the device then reports is.
        $pm = Read-KnxDeviceProperty -Session $ses -ObjectIndex 0 -PropertyId $K.Pid.PROG_MODE
        if (-not $pm.Ok -or $pm.Data.Length -lt 1) { return "PID_PROG_MODE of $Target is not readable, so the write cannot be verified" }
        $now = ((([int]$pm.Data[0]) -band 0x01) -eq 1)
        if ($now -ne $On) { return "the device did not take the write: programming mode is still $(if ($now) { 'on' } else { 'off' })" }
        return ''
    }
    finally { Close-KnxDeviceSession -Session $ses }
}

# ─── Shared device-layer helpers ────────────────────────────────────────────────
# These used to sit INSIDE Invoke-KnxSuiteDevice, which redefined them on every call and hid
# them from every other suite. At file scope they are reusable and testable like the rest.

function Get-KnxAnswerFrame {
    param($Result, [int]$Apci)
    if ($null -eq $Result -or $null -eq $Result.Frames) { return $null }
    foreach ($f in @($Result.Frames)) {
        if ($null -eq $f.Tpdu -or $f.Tpdu.Length -lt 2) { continue }
        if ((Get-TpduApci -Tpdu $f.Tpdu) -eq $Apci) { return $f }
    }
    return $null
}

function New-TpduRawTpci {
    param([Parameter(Mandatory)][int]$Tpci, [Parameter(Mandatory)][int]$Apci, [byte[]]$Data = @())
    $head = [byte[]]@( (($Tpci -bor (($Apci -shr 8) -band 0x03)) -band 0xFF), ($Apci -band 0xFF) )
    if ($null -eq $Data -or $Data.Length -eq 0) { return , $head }
    return , ([byte[]]($head + $Data))
}

function Get-KnxFramesFrom {
    <# .SYNOPSIS Everything the target sent back inside the window. #>
    param($Session, [byte[]]$Tpdu, [int]$Ms = 3000, [int]$FromAddress = -1)
    $K = Get-KnxConstants
    [void](Send-KnxDeviceTpdu -Session $Session -Tpdu $Tpdu -TimeoutMs 3000)
    $out = @()
    $deadline = [DateTime]::UtcNow.AddMilliseconds($Ms)
    while ([DateTime]::UtcNow -lt $deadline) {
        $in = Receive-KnxTunnelCemi -Connection $Session.Conn -TimeoutMs 600
        if ($null -eq $in) { continue }
        $ld = Read-CemiLData -Cemi $in.Cemi
        if ($null -eq $ld) { continue }
        if ($ld.MessageCode -ne $K.Cemi.L_DATA_IND) { continue }
        $want = if ($FromAddress -ge 0) { $FromAddress } else { $Session.Dst }
        if ($ld.Source -ne $want) { continue }
        # Source alone is not "it answered US": the tunnel forwards everything the target puts on the
        # line, including its cyclic group telegrams. A chatty sensor would have made the negative TPCI
        # cases red and the positive control green without a single reply. An application PDU is NOT
        # required here - for a transport-layer case a bare T_ACK is the reaction being judged.
        # On a broadcast session the reply is itself a broadcast (destination 0, address type set), e.g.
        # A_IndividualAddress_Response, so it counts there; cyclic group telegrams never go to 0.
        $broadcastReply = ($Session.Dst -eq 0 -and $ld.IsGroup -and $ld.Destination -eq 0)
        if (-not $broadcastReply -and -not (Test-KnxAddressedToSession -Session $Session -LData $ld)) { continue }
        $out += $ld
    }
    return , $out
}

function Read-KnxLoadState {
    param($Session, [int]$ObjectIndex)
    $K = Get-KnxConstants
    $r = Invoke-KnxDeviceService -Session $Session -Apci $K.Apci.PROPERTY_VALUE_READ `
                                 -Data ([byte[]]@([byte]$ObjectIndex, [byte]$script:KnxPidLoadState, 0x10, 0x01)) `
                                 -ExpectApci $K.Apci.PROPERTY_VALUE_RESPONSE -TimeoutMs 5000
    if ($null -eq $r.Response -or $r.Response.Length -lt 7) { return -1 }
    return [int]$r.Response[6]
}

function Write-KnxLoadEvent {
    param($Session, [int]$ObjectIndex, [int]$Event)
    $K = Get-KnxConstants
    # The clause writes ten octets: the event in the first, the rest zero.
    $payload = [byte[]]@([byte]$ObjectIndex, [byte]$script:KnxPidLoadState, 0x10, 0x01, [byte]$Event) + [byte[]](, 0 * 9)
    $r = Invoke-KnxDeviceService -Session $Session -Apci $K.Apci.PROPERTY_VALUE_WRITE -Data $payload `
                                 -ExpectApci $K.Apci.PROPERTY_VALUE_RESPONSE -TimeoutMs 5000
    if ($null -eq $r.Response -or $r.Response.Length -lt 7) { return -1 }
    return [int]$r.Response[6]
}

function Get-KnxBusAckAfter {
    <#
    .SYNOPSIS
        Sends one frame and reports whether a standalone L2 acknowledge followed it on the line.
    #>
    param($Witness, $Conn, [int]$Destination, [switch]$IsGroup, [byte[]]$Tpdu, [int]$Ms = 2500)
    $K = Get-KnxConstants
    $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $Destination -IsGroup:$IsGroup -Tpdu $Tpdu -Priority 3
    [void](Send-KnxTunnelCemi -Connection $Conn -Cemi $cemi -TimeoutMs 2000)
    $sawFrame = $false
    $sawAck = $false
    $justSawOurs = $false      # only the frame DIRECTLY after ours can be its acknowledge
    $deadline = [DateTime]::UtcNow.AddMilliseconds($Ms)
    while ([DateTime]::UtcNow -lt $deadline) {
        $bm = Receive-KnxTunnelCemi -Connection $Witness -TimeoutMs 250
        if ($null -eq $bm -or $bm.Cemi[0] -ne $K.Cemi.L_BUSMON_IND) { continue }
        $d = Read-CemiBusmon -Cemi $bm.Cemi
        if ($null -eq $d) { continue }
        # The acknowledge is its own one-octet frame and follows its telegram IMMEDIATELY - roughly
        # 1.5 ms on TP1, before anything else can transmit. Counting "the next acknowledge after our
        # frame" credited a foreign telegram's acknowledge whenever bus traffic interleaved.
        if ($d.IsAck) {
            if ($sawFrame -and $justSawOurs) { $sawAck = $true; break }
            $justSawOurs = $false
            continue
        }
        # 03_02_02 2.2.2 p.26, standard frame: CTRL(0) SA(1,2) DA(3,4). Reading the destination at 4/5
        # shifted it one octet, so the witness never recognised our own frame at all.
        $justSawOurs = $false
        if ($null -ne $d.Lpdu -and $d.Lpdu.Length -ge 6) {
            $dst = ([int]$d.Lpdu[3] -shl 8) -bor [int]$d.Lpdu[4]
            if ($dst -eq $Destination) { $sawFrame = $true; $justSawOurs = $true }
        }
    }
    return [pscustomobject]@{ FrameSeen = $sawFrame; AckSeen = $sawAck }
}

function Get-KnxApciFamily {
    <#
    .SYNOPSIS
        The service an APCI belongs to, with the payload bits masked off.
    .DESCRIPTION
        03_03_07 encodes the short services in the top four bits and uses the low six as payload - for
        A_Memory_Read that payload is the number of octets to read, so 0x201 and 0x220 are the same
        service as 0x200. lib/knx applies exactly this rule in apdu.cpp:
        "if ((apci >> 6) < 11 && (apci >> 6) != 7) apci &= 0x3c0".
        Treating the payload as part of the service made an APCI sweep report seven phantom defects.
    #>
    param([Parameter(Mandatory)][int]$Apci)
    $v = $Apci -band 0x3FF
    if ((($v -shr 6) -lt 11) -and (($v -shr 6) -ne 7)) { return ($v -band 0x3C0) }
    return $v
}

function Get-KnxGroupValue {
    <#
    .SYNOPSIS
        Reads one group object value and returns its payload octets, or $null when nobody answers.
    .DESCRIPTION
        A_GroupValue_Read to the address, then the first A_GroupValue_Response that comes back FROM the
        expected source. Small values ride in the low six bits of the APCI octet (03_03_07), larger ones
        follow it, and both shapes are returned as the octets a caller can compare.
    #>
    param(
        [Parameter(Mandatory)]$Conn,
        [Parameter(Mandatory)][int]$Destination,
        [int]$Source = -1,
        [int]$TimeoutMs = 2500
    )
    $K = Get-KnxConstants
    $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $Destination -IsGroup -Tpdu (New-TpduGroupValueRead) -Priority 3
    [void](Send-KnxTunnelCemi -Connection $Conn -Cemi $cemi -TimeoutMs 2000)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $in = Receive-KnxTunnelCemi -Connection $Conn -TimeoutMs 300
        if ($null -eq $in) { continue }
        $ld = Read-CemiLData -Cemi $in.Cemi
        if ($null -eq $ld -or $ld.MessageCode -ne $K.Cemi.L_DATA_IND) { continue }
        if (-not $ld.IsGroup -or $ld.Destination -ne $Destination) { continue }
        if ($null -eq $ld.Tpdu -or $ld.Tpdu.Length -lt 2) { continue }
        if (($ld.Tpdu[1] -band 0xC0) -ne 0x40) { continue }          # A_GroupValue_Response
        if ($Source -ge 0 -and $ld.Source -ne $Source) { continue }
        if ($ld.Tpdu.Length -gt 2) { return , ([byte[]]$ld.Tpdu[2..($ld.Tpdu.Length - 1)]) }
        return , ([byte[]]@(($ld.Tpdu[1] -band 0x3F)))               # small value, carried in the APCI octet
    }
    return $null
}

function Get-KnxObjectIndexByType {
    <#
    .SYNOPSIS
        The object INDEX that carries a given interface object TYPE, or -1.
    .DESCRIPTION
        Object indices are per device, not per standard. Measured 2026-09-27 on 5.0.3 and 5.0.8: index 3
        is the group object table (type 0009) and the application program (type 0003) sits at index 4 -
        so a hard-coded 3 asks the wrong object and gets "property not present" for a property that is
        there. PID 1 (PID_OBJECT_TYPE) is the only reliable way to find it.
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][int]$ObjectType,
        [int]$MaxIndex = 12
    )
    $K = Get-KnxConstants
    for ($i = 0; $i -le $MaxIndex; $i++) {
        $r = Invoke-KnxDeviceService -Session $Session -Apci $K.Apci.PROPERTY_VALUE_READ `
                                     -Data ([byte[]]@([byte]$i, [byte]$K.Pid.OBJECT_TYPE, 0x10, 0x01)) `
                                     -ExpectApci $K.Apci.PROPERTY_VALUE_RESPONSE -TimeoutMs 4000
        if ($null -eq $r.Response -or $r.Response.Length -lt 8) { continue }
        $t = (([int]$r.Response[6]) -shl 8) -bor [int]$r.Response[7]
        if ($t -eq $ObjectType) { return $i }
    }
    return -1
}

function Test-KnxTargetSustainsConnection {
    <#
    .SYNOPSIS
        True when the target really carries connection-oriented exchanges, twice in a row.
    .DESCRIPTION
        08_03_04 clause 6 judges a transport state machine. A target that does not sustain an ordinary
        connection-oriented exchange cannot be judged by it, and every sequence would come back red for
        the wrong reason. Measured 2026-09-27: the MDT SCN-IP000.03 (5.0.14) answers connectionless
        property reads but reports mask 0xFFFF and does not survive two connected exchanges, and the
        Siemens N148 (5.0.50) does not answer as a TP device at all - both are KNXnet/IP interfaces, not
        bus devices. Used as references they produced six phantom failures.
    #>
    param([Parameter(Mandatory)][string]$Ip, [int]$Port = 3671, [Parameter(Mandatory)][string]$Pa)
    # Cached per target: the probe costs two connections and every case in the group asks for it.
    if ($script:tlBaselineCache.ContainsKey($Pa)) { return $script:tlBaselineCache[$Pa] }
    $K = Get-KnxConstants
    $ok = $true
    foreach ($round in 1..2) {
        $p = Open-KnxDeviceSession -Ip $Ip -Port $Port -Pa $Pa -Connect
        if (-not $p.Ok) { $ok = $false; break }
        try {
            $r = Invoke-KnxDeviceService -Session $p -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@(0x00)) `
                                         -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 6000
            if ($null -eq $r.Response) { $ok = $false }
        }
        finally { Close-KnxDeviceSession -Session $p }
        if (-not $ok) { break }
    }
    $script:tlBaselineCache[$Pa] = $ok
    return $ok
}

function Test-KnxDeviceStillUsable {
    <#
    .SYNOPSIS
        Proves the DEVICE still works, on a connection of its own.
    .DESCRIPTION
        After a deliberately malformed transport frame our own session's sequence counters are stale -
        the next request looks like a repeat to the device, it re-acknowledges without executing, and a
        case that reuses the session reads that as "the device broke". Measured 2026-09-27: three cases
        failed that way on 5.0.3, 5.0.8 AND the certified MDT, which is what exposed it. The clause asks
        about the device's state machine, so the check belongs on a fresh connection.
    #>
    param([Parameter(Mandatory)][string]$Ip, [int]$Port = 3671, [Parameter(Mandatory)][string]$Pa, [int]$TimeoutMs = 6000)
    $K = Get-KnxConstants
    # Three outcomes, not two. A fresh connection that cannot even be OPENED says the instrument ran
    # out of tunnel channels - these cases hold two open already - and that is a statement about the
    # rig, never about the device. Collapsing it into "false" made the certified MDT look like it
    # failed six of eight transport sequences.
    $p = $null
    foreach ($attempt in 1..3) {
        $p = Open-KnxDeviceSession -Ip $Ip -Port $Port -Pa $Pa -Connect
        if ($p.Ok) { break }
        Start-Sleep -Seconds 2
    }
    if ($null -eq $p -or -not $p.Ok) {
        return [pscustomobject]@{ Ok = $false; RigFault = $true; Reason = "no fresh connection could be opened ($(if ($null -ne $p) { $p.Reason } else { 'unknown' })) - the interface has no free tunnel channel, so the device cannot be judged" }
    }
    try {
        $r = Invoke-KnxDeviceService -Session $p -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@(0x00)) `
                                     -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs $TimeoutMs
        return [pscustomobject]@{ Ok = ($null -ne $r.Response); RigFault = $false; Reason = '' }
    }
    finally { Close-KnxDeviceSession -Session $p }
}

# -- IP SBC control over the bus (03_05_01 4.5.16.1 PID_IP_SBC_CONTROL, p.107-109) ----------------

function Get-KnxRouterObjectIndex {
    <#
    .SYNOPSIS
        Index of the first router object (type 6), read with A_PropertyValue_Read PID_OBJECT_TYPE; -1 when none answers.
    #>
    param([Parameter(Mandatory)]$Session)
    $K = Get-KnxConstants
    foreach ($i in 0..15) {
        $r = Invoke-KnxDeviceService -Session $Session -Apci $K.Apci.PROPERTY_VALUE_READ -Data ([byte[]]@($i, 1, 0x10, 0x01)) `
                                     -ExpectApci $K.Apci.PROPERTY_VALUE_RESPONSE -TimeoutMs 2000 -Connectionless
        # The answer must name the index asked for: a late answer to an earlier index would shift the result.
        if ($null -ne $r.Response -and $r.Response.Length -ge 8 -and $r.Response[2] -eq $i -and $r.Response[6] -eq 0 -and $r.Response[7] -eq 6) { return $i }
    }
    return -1
}

function Invoke-KnxSbcControl {
    <#
    .SYNOPSIS
        Writes (Mode 0/1) or reads (Mode -1) PID_IP_SBC_CONTROL with the classic or the extended function property service.
    .DESCRIPTION
        Request [reserved 00][ServiceID 00][IP SBC Mode] (Figure 17 p.108); write answer [return code][ServiceID]
        (Figure 18 p.108), read answer adds the mode (p.109). Returns return code, service ID and mode, -1 where absent.
        Connectionless unless -Connected (the session must then hold a T_Connect).
    #>
    param([Parameter(Mandatory)]$Session, [ValidateSet('Classic', 'Ext')][string]$Form = 'Classic', [int]$ObjectIndex = -1, [int]$Mode = -1, [switch]$Connected)
    $K = Get-KnxConstants
    $svc = if ($Mode -ge 0) { [byte[]]@(0x00, 0x00, ($Mode -band 0xFF)) } else { [byte[]]@(0x00, 0x00) }
    if ($Form -eq 'Classic' -and $ObjectIndex -lt 0) { throw 'Invoke-KnxSbcControl: the classic form needs -ObjectIndex (Get-KnxRouterObjectIndex)' }
    if ($Form -eq 'Classic') {
        $head = [byte[]]@(($ObjectIndex -band 0xFF), 120)
        $apci = if ($Mode -ge 0) { $K.Apci.FUNCTION_PROPERTY_COMMAND } else { $K.Apci.FUNCTION_PROPERTY_STATE }
        $expect = $K.Apci.FUNCTION_PROPERTY_STATE_RESPONSE
    }
    else {
        $head = [byte[]]@(0x00, 0x06, 0x00, 0x10, 0x78)   # object type 6, instance 1, PID 120
        $apci = if ($Mode -ge 0) { $K.Apci.FUNCTION_PROPERTY_EXT_COMMAND } else { $K.Apci.FUNCTION_PROPERTY_EXT_STATE }
        $expect = $K.Apci.FUNCTION_PROPERTY_EXT_STATE_RESPONSE
    }
    $cl = @{}; if (-not $Connected) { $cl.Connectionless = $true }
    $r = Invoke-KnxDeviceService -Session $Session -Apci $apci -Data ([byte[]]($head + $svc)) -ExpectApci $expect -TimeoutMs 3000 @cl
    $b = $r.Response
    $at = 2 + $head.Length   # TPCI/APCI octets, then the echoed header
    $echo = ($null -ne $b -and $b.Length -ge $at -and (@(Compare-Object ([byte[]]$b[2..($at - 1)]) $head -SyncWindow 0).Count -eq 0))
    [pscustomobject]@{
        Response   = $b
        HeaderEcho = $echo
        ReturnCode = if ($null -ne $b -and $b.Length -gt $at) { [int]$b[$at] } else { -1 }
        ServiceId  = if ($null -ne $b -and $b.Length -gt $at + 1) { [int]$b[$at + 1] } else { -1 }
        Mode       = if ($null -ne $b -and $b.Length -gt $at + 2) { [int]$b[$at + 2] } else { -1 }
    }
}

function Assert-KnxSbcAnswer {
    <#
    .SYNOPSIS
        Fails unless a PID_IP_SBC_CONTROL answer arrived with return code 00h (and, for a read, carries a mode).
    #>
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)][string]$What, [switch]$Read)
    Assert-KnxTrue ($null -ne $Result.Response) "no A_FunctionPropertyState_Response to the $What"
    Assert-KnxTrue ($Result.ReturnCode -eq 0) ("the $What was answered with return code 0x{0:X2}" -f $Result.ReturnCode)
    if ($Read) { Assert-KnxTrue ($Result.Mode -ge 0) "the answer to the $What carries no mode" }
}

# -- Rig power guard ------------------------------------------------------------------------------

function Split-KnxRigList {
    <#
    .SYNOPSIS
        Splits a comma / semicolon / blank separated list (string or array) into trimmed, non-empty items.
    #>
    param($Value)
    $out = @()
    foreach ($v in @($Value)) {
        if ($null -eq $v) { continue }
        foreach ($p in ("$v" -split '[,;\s]+')) { if ($p.Trim()) { $out += $p.Trim() } }
    }
    return , $out
}

function Test-KnxGaText {
    <#
    .SYNOPSIS
        True for a three-level group address in range: main 0-31, middle 0-7, sub 0-255.
    #>
    param([string]$Text)
    if ($Text -notmatch '^(\d{1,2})/(\d)/(\d{1,3})$') { return $false }
    return ([int]$Matches[1] -le 31 -and [int]$Matches[2] -le 7 -and [int]$Matches[3] -le 255)
}

function Assert-KnxRigPower {
    <#
    .SYNOPSIS
        Checks the rig power relays and switches an OFF relay back on.
    .DESCRIPTION
        Reads every status GA through the control interface -Via, never through the device under test.
        A status of 0 or no answer (two reads) gets an A_GroupValue_Write 1 on the paired write GA and a
        second status read. When a relay was switched on, the device under test is polled with
        DeviceDescriptor_Read on -DutPa through -Via until it answers. No relays configured = OK, nothing sent.
    .OUTPUTS
        Ok, Checked, Restored, Seconds (switch-on until the device under test answered), Detail.
    #>
    param(
        [string]$Via = '',
        [int]$Port = 3671,
        $WriteGa = @(),
        $StatusGa = @(),
        [string]$DutPa = '',
        [int]$StatusTimeoutMs = $script:KnxRigStatusTimeoutMs,
        [int]$DutBackSeconds = $script:KnxRigDutBackSeconds
    )
    $writes = Split-KnxRigList $WriteGa
    $states = Split-KnxRigList $StatusGa
    $res = [pscustomobject]@{ Ok = $true; Checked = $false; Restored = $false; Seconds = 0.0; Detail = '' }
    if ($writes.Count -eq 0 -and $states.Count -eq 0) { $res.Detail = 'no relays configured'; return $res }
    if ($writes.Count -ne $states.Count) {
        $res.Ok = $false
        $res.Detail = "not checked - $($writes.Count) relay write GA(s) but $($states.Count) status GA(s)"
        return $res
    }
    if (-not $Via) { $res.Ok = $false; $res.Detail = 'not checked - no control interface (-PowerRelayVia) given'; return $res }
    # ConvertTo-KnxGa masks out-of-range parts, so 0/8/100 would write to 0/0/100.
    $badGa = @(($writes + $states) | Where-Object { -not (Test-KnxGaText $_) })
    if ($badGa.Count -gt 0) { $res.Ok = $false; $res.Detail = "not checked - not a group address in range: $($badGa -join ', ')"; return $res }

    $K = Get-KnxConstants
    $c = $null
    try {
        $c = Open-KnxConnection -Ip $Via -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION `
                                -Layer $K.Layer.TUNNEL_LINKLAYER -TimeoutMs 3000
    }
    catch { $c = $null }
    if ($null -eq $c -or -not $c.Ok) {
        $why = if ($null -ne $c) { $c.StatusName } else { 'no answer' }
        $res.Ok = $false
        $res.Detail = "not checked - no tunnel on $Via ($why)"
        return $res
    }

    $notes = @()
    $switched = @()
    $failed = @()
    $sw = $null
    $isOn = { param($v) ($null -ne $v -and @($v | Where-Object { $_ -ne 0 }).Count -gt 0) }
    try {
        $res.Checked = $true
        for ($i = 0; $i -lt $states.Count; $i++) {
            $sGa = $states[$i]; $wGa = $writes[$i]
            $sRaw = ConvertTo-KnxGa -Address $sGa
            $v = Get-KnxGroupValue -Conn $c -Destination $sRaw -TimeoutMs $StatusTimeoutMs
            # One lost answer must not switch anything.
            if ($null -eq $v) { $v = Get-KnxGroupValue -Conn $c -Destination $sRaw -TimeoutMs $StatusTimeoutMs }
            if (& $isOn $v) { $notes += "$sGa=on"; continue }
            $was = if ($null -eq $v) { 'no answer' } else { 'off' }
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination (ConvertTo-KnxGa -Address $wGa) -IsGroup `
                                  -Tpdu (New-TpduGroupValueWrite -Value 1) -Priority 3
            $w = Send-KnxTunnelCemi -Connection $c -Cemi $cemi -TimeoutMs 2000
            if ($null -eq $sw) { $sw = [System.Diagnostics.Stopwatch]::StartNew() }
            [void](Wait-KnxTunnel -Connection $c -Ms $script:KnxRigSwitchSettleMs)
            $v2 = Get-KnxGroupValue -Conn $c -Destination $sRaw -TimeoutMs $StatusTimeoutMs
            if (& $isOn $v2) { $switched += $wGa; $notes += "$sGa $was -> $wGa=1 -> on" }
            else {
                $failed += $wGa
                $now = if ($null -eq $v2) { 'no answer' } else { 'off' }
                $notes += "$sGa $was -> $wGa=1 (tunnel ack $($w.Acked)) -> still $now"
            }
        }
    }
    finally { try { [void](Close-KnxConnection -Connection $c) } catch { } }

    $res.Restored = ($switched.Count -gt 0)
    if ($failed.Count -gt 0) { $res.Ok = $false }
    if ($res.Restored -and $DutPa) {
        $back = $false
        $deadline = [DateTime]::UtcNow.AddSeconds($DutBackSeconds)
        $ses = $null
        while (-not $back -and [DateTime]::UtcNow -lt $deadline) {
            try {
                if ($null -eq $ses) {
                    $ses = Open-KnxDeviceSession -Ip $Via -Port $Port -Pa $DutPa
                    if (-not $ses.Ok) { $ses = $null; Start-Sleep -Milliseconds $script:KnxRigDutPollMs; continue }
                }
                $r = Invoke-KnxDeviceService -Session $ses -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@(0x00)) `
                                             -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs $script:KnxRigDutPollMs -Connectionless
                if ($null -ne $r.Response) { $back = $true }
                elseif (-not $r.TunnelAcked) { Close-KnxDeviceSession -Session $ses; $ses = $null }
            }
            catch { if ($null -ne $ses) { try { Close-KnxDeviceSession -Session $ses } catch { } }; $ses = $null }
        }
        if ($null -ne $ses) { Close-KnxDeviceSession -Session $ses }
        $res.Seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
        if ($back) { $notes += "device under test $DutPa answered after $($res.Seconds) s" }
        else { $res.Ok = $false; $notes += "device under test $DutPa did not answer within $DutBackSeconds s" }
    }
    elseif ($res.Restored) { $res.Seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1) }
    $res.Detail = (($notes -join ', ') + " (via $Via)")
    return $res
}

# -- KNX-fault injection through the rig relays ---------------------------------------------------

function Get-KnxRigFaultTiming {
    <#
    .SYNOPSIS
        The KNX-fault injection budgets and intervals in ms, from the module constants.
    #>
    return [pscustomobject]@{
        PollMs          = $script:KnxFaultPollMs
        ConnStateMs     = $script:KnxFaultConnStateMs
        PropInfoMs      = $script:KnxFaultPropInfoMs
        ClearMs         = $script:KnxFaultClearMs
        RestoreMs       = $script:KnxFaultRestoreMs
        RetryMs         = $script:KnxFaultRetryMs
        SwitchSettleMs  = $script:KnxRigSwitchSettleMs
        StatusTimeoutMs = $script:KnxRigStatusTimeoutMs
    }
}

function Get-KnxRigRelayState {
    <#
    .SYNOPSIS
        Reads relay status GAs through -Via over a tunnel of its own: on, off or 'no answer' per GA.
    .DESCRIPTION
        A missing answer is read a second time before it counts, as in Assert-KnxRigPower.
    .OUTPUTS
        Ok (the tunnel opened), States (Ga, State), Detail.
    #>
    param(
        [Parameter(Mandatory)][string]$Via,
        [int]$Port = 3671,
        $StatusGa = @(),
        [int]$StatusTimeoutMs = $script:KnxRigStatusTimeoutMs
    )
    $K = Get-KnxConstants
    $res = [pscustomobject]@{ Ok = $false; States = @(); Detail = '' }
    $c = $null
    try {
        $c = Open-KnxConnection -Ip $Via -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION `
                                -Layer $K.Layer.TUNNEL_LINKLAYER -TimeoutMs 3000
    }
    catch { $c = $null }
    if ($null -eq $c -or -not $c.Ok) {
        $why = if ($null -ne $c) { $c.StatusName } else { 'no answer' }
        $res.Detail = "no tunnel on $Via ($why)"
        return $res
    }
    $out = @()
    try {
        foreach ($ga in (Split-KnxRigList $StatusGa)) {
            $raw = ConvertTo-KnxGa -Address $ga
            $v = Get-KnxGroupValue -Conn $c -Destination $raw -TimeoutMs $StatusTimeoutMs
            if ($null -eq $v) { $v = Get-KnxGroupValue -Conn $c -Destination $raw -TimeoutMs $StatusTimeoutMs }
            $st = 'no answer'
            if ($null -ne $v) { $st = if (@($v | Where-Object { $_ -ne 0 }).Count -gt 0) { 'on' } else { 'off' } }
            $out += [pscustomobject]@{ Ga = $ga; State = $st }
        }
        $res.Ok = $true
    }
    finally { try { [void](Close-KnxConnection -Connection $c) } catch { } }
    $res.States = $out
    $res.Detail = ((@($out | ForEach-Object { "$($_.Ga)=$($_.State)" }) -join ', ') + " (via $Via)")
    return $res
}

function Set-KnxRigRelay {
    <#
    .SYNOPSIS
        Sends A_GroupValue_Write -Value to one relay switch GA through -Via over a tunnel of its own.
    .OUTPUTS
        Attempted (the send was started), Acked (tunnel ack), SentAt (UTC, taken just before the send), Detail.
    #>
    param(
        [Parameter(Mandatory)][string]$Via,
        [int]$Port = 3671,
        [Parameter(Mandatory)][string]$WriteGa,
        [Parameter(Mandatory)][ValidateRange(0, 1)][int]$Value
    )
    $K = Get-KnxConstants
    $res = [pscustomobject]@{ Attempted = $false; Acked = $false; SentAt = [DateTime]::UtcNow; Detail = '' }
    $c = $null
    try {
        $c = Open-KnxConnection -Ip $Via -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION `
                                -Layer $K.Layer.TUNNEL_LINKLAYER -TimeoutMs 3000
    }
    catch { $c = $null }
    if ($null -eq $c -or -not $c.Ok) {
        $why = if ($null -ne $c) { $c.StatusName } else { 'no answer' }
        $res.Detail = "$WriteGa=$Value not sent - no tunnel on $Via ($why)"
        return $res
    }
    try {
        $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination (ConvertTo-KnxGa -Address $WriteGa) -IsGroup `
                              -Tpdu (New-TpduGroupValueWrite -Value $Value) -Priority 3
        $res.SentAt = [DateTime]::UtcNow
        $res.Attempted = $true
        $w = Send-KnxTunnelCemi -Connection $c -Cemi $cemi -TimeoutMs 2000
        $res.Acked = [bool]$w.Acked
        $res.Detail = "$WriteGa=$Value via $Via (tunnel ack $($res.Acked))"
    }
    finally { try { [void](Close-KnxConnection -Connection $c) } catch { } }
    return $res
}

function New-KnxDeviceStateLog {
    <#
    .SYNOPSIS
        Empty record for Watch-KnxDeviceState.
    .DESCRIPTION
        States: At, Earliest, Status of every CONNECTIONSTATE_RESPONSE. Indications: At, Earliest, Value, Cemi of every
        M_PropInfo.ind on PID_KNXNETIP_DEVICE_STATE. Earliest = the socket was last seen empty, so the datagram arrived
        between Earliest and At. PollTimes: every CONNECTIONSTATE_REQUEST sent. EmptyAt: last time the socket was seen
        empty. CutAt / RestoreAt are set by the caller. All times UTC.
    #>
    return [pscustomobject]@{
        States       = New-Object System.Collections.ArrayList
        Indications  = New-Object System.Collections.ArrayList
        PollTimes    = New-Object System.Collections.ArrayList
        Polls        = 0
        EmptyAt      = $null
        Disconnected = $false
        CutAt        = $null
        RestoreAt    = $null
    }
}

function Watch-KnxDeviceState {
    <#
    .SYNOPSIS
        Polls CONNECTIONSTATE on an open connection and records the answers and the PID 69 indications.
    .DESCRIPTION
        One CONNECTIONSTATE_REQUEST every -PollMs; every DEVICE_CONFIGURATION_REQUEST is acknowledged. Ends when
        -Until returns true for the log, the device disconnects, or -TimeoutMs passes.
    .OUTPUTS
        $true when -Until held.
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)]$Log,
        [Parameter(Mandatory)][int]$TimeoutMs,
        [scriptblock]$Until = $null,
        [int]$PollMs = $script:KnxFaultPollMs
    )
    $K = Get-KnxConstants
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    $nextPoll = [DateTime]::UtcNow
    while ($true) {
        if ($null -ne $Until -and (& $Until $Log)) { return $true }
        if ($Log.Disconnected) { return $false }
        $now = [DateTime]::UtcNow
        if ($now -ge $deadline) { return $false }
        if ($now -ge $nextPoll) {
            $f = New-KnxConnectionStateRequest -Channel $Connection.Channel -ControlIp $Connection.LocalIp -ControlPort $Connection.LocalPort
            Send-KnxFrame -Socket $Connection.Socket -Frame $f -Ip $Connection.Ip -Port $Connection.Port
            $Log.Polls++
            [void]$Log.PollTimes.Add($now)
            $nextPoll = $now.AddMilliseconds($PollMs)
        }
        $wait = [Math]::Min(($nextPoll - $now).TotalMilliseconds, ($deadline - $now).TotalMilliseconds)
        $t0 = [DateTime]::UtcNow
        $pkt = Receive-KnxFrame -Socket $Connection.Socket -TimeoutMs ([int][Math]::Max(1, $wait))
        $at = [DateTime]::UtcNow
        if ($null -eq $pkt) { $Log.EmptyAt = $at; continue }
        # A receive that blocked woke on this datagram; one that returned at once read it from the queue.
        $earliest = $Log.EmptyAt
        if (($at - $t0).TotalMilliseconds -gt 5) { $earliest = $at; $Log.EmptyAt = $t0 }
        $h = Read-KnxHeader -Frame $pkt.Bytes
        if ($null -eq $h) { continue }
        $b = $h.Body
        if ($h.Service -eq $K.Service.CONNECTIONSTATE_RESPONSE) {
            if ($b.Length -ge 2 -and [int]$b[0] -eq [int]$Connection.Channel) {
                [void]$Log.States.Add([pscustomobject]@{ At = $at; Earliest = $earliest; Status = [int]$b[1] })
            }
        }
        elseif ($h.Service -eq $K.Service.DEVICE_CONFIGURATION_REQUEST) {
            if ($b.Length -lt 5) { continue }
            Send-KnxFrame -Socket $Connection.Socket -Frame (New-KnxDeviceConfigurationAck -Channel $b[1] -Sequence $b[2]) `
                          -Ip $Connection.Ip -Port $Connection.Port
            $cemi = [byte[]]$b[4..($b.Length - 1)]
            if ($cemi.Length -ge 8 -and $cemi[0] -eq $K.Cemi.M_PROPINFO_IND -and
                (Get-Uint16 -Bytes $cemi -Offset 1) -eq $K.ObjType.KNXNETIP_PARAM -and $cemi[4] -eq $K.Pid.KNXNETIP_DEVICE_STATE) {
                [void]$Log.Indications.Add([pscustomobject]@{ At = $at; Earliest = $earliest; Value = [int]$cemi[7]; Cemi = $cemi })
            }
        }
        elseif ($h.Service -eq $K.Service.DISCONNECT_REQUEST) {
            if ($b.Length -ge 1 -and [int]$b[0] -eq [int]$Connection.Channel) {
                Send-KnxFrame -Socket $Connection.Socket -Frame (New-KnxDisconnectResponse -Channel $Connection.Channel) `
                              -Ip $Connection.Ip -Port $Connection.Port
                $Log.Disconnected = $true
            }
        }
    }
}

function Read-KnxDeviceStateValue {
    <#
    .SYNOPSIS
        Reads PID_KNXNETIP_DEVICE_STATE with M_PropRead.req; an M_PropInfo.ind caught in place of the .con goes to -Log.
    .OUTPUTS
        Value (-1 when not read), Cemi (the .con), Detail.
    #>
    param([Parameter(Mandatory)]$Connection, $Log = $null)
    $K = Get-KnxConstants
    $res = [pscustomobject]@{ Value = -1; Cemi = $null; Detail = '' }
    for ($i = 0; $i -lt 2; $i++) {
        $r = Read-KnxProperty -Connection $Connection -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.KNXNETIP_DEVICE_STATE
        $c = $r.Cemi
        if ($null -eq $c) { $res.Detail = "no M_PropRead.con (ack status $($r.AckStatus))"; return $res }
        # Send-KnxDeviceConfiguration takes the first DEVICE_CONFIGURATION_REQUEST as the .con.
        if ($c[0] -eq $K.Cemi.M_PROPINFO_IND) {
            if ($null -ne $Log -and $c.Length -ge 8 -and $c[4] -eq $K.Pid.KNXNETIP_DEVICE_STATE) {
                $earliest = $Log.EmptyAt
                [void]$Log.Indications.Add([pscustomobject]@{ At = [DateTime]::UtcNow; Earliest = $earliest; Value = [int]$c[7]; Cemi = $c })
            }
            continue
        }
        $res.Cemi = $c
        $p = $r.Parsed
        if ($c[0] -ne $K.Cemi.M_PROPREAD_CON -or $null -eq $p) { $res.Detail = ('unexpected message code 0x{0:X2}' -f $c[0]); return $res }
        if ($p.ObjectType -ne $K.ObjType.KNXNETIP_PARAM -or $p.ObjectInstance -ne 1 -or $p.PropertyId -ne $K.Pid.KNXNETIP_DEVICE_STATE) {
            $res.Detail = ('M_PropRead.con for object type {0} instance {1} PID {2}, expected 11/1/69' -f $p.ObjectType, $p.ObjectInstance, $p.PropertyId)
            return $res
        }
        if ($p.IsError -or $p.Data.Length -lt 1) { $res.Detail = ('negative M_PropRead.con, error 0x{0:X2}' -f $p.ErrorCode); return $res }
        $res.Value = [int]$p.Data[0]
        $res.Detail = ('PID 69 = 0x{0:X2}' -f $res.Value)
        return $res
    }
    $res.Detail = 'only M_PropInfo.ind came back, no M_PropRead.con'
    return $res
}

# Everything here is part of the device layer's surface; the suites call it by name.
Export-ModuleMember -Function *-* -Variable @()
