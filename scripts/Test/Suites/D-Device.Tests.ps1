#!/usr/bin/env pwsh
<#
Open ■
┬────┴  D-Device.Tests
■ KNX   2026 OpenKNX - Erkan Çolak

FILEPATH: scripts/Test/Suites/D-Device.Tests.ps1

.SYNOPSIS
    Conformance of a normal KNX DEVICE on the TP line, seen through a KNXnet/IP interface.

.DESCRIPTION
    Everything else under Suites/ judges a KNXnet/IP device against Volume 8. This file
    judges something different: an ordinary bus device - a dimmer, a NeoPixel controller,
    a Nuki bridge - against Volume 3. The interface is not the object under test here, it
    is the window we look through.

    That distinction decides what a failure means. A red case here says "the DEVICE at
    that individual address does not behave as Volume 3 requires", and it says it only
    after the same tunnel has already proven itself in the KNXnet/IP suites. Run those
    first; a broken window makes every device look broken.

    Case groups:
      D-1  identification      who is this device, and does it say the same thing twice
      D-2  transport layer     the connection-oriented state machine ETS depends on
      D-3  application layer   property services and their prescribed error answer
      D-4  robustness          malformed and oversized requests, and resource leaks
      D-5  addressing          does it answer for its own address and only for that one

    WHAT IS DELIBERATELY NOT HERE: the application. Whether the NeoPixel shows the right
    colour is not in any specification, so no test can call it conform. What is testable
    is the KNX layer underneath it - and that is exactly the layer a firmware change can
    break without anyone noticing.

    Every case adapts to the device's own mask version. A BCU1 has no interface objects,
    so the property cases report N-A with the mask as the reason instead of a wall of red
    for a device that was never required to implement them.
#>

Set-StrictMode -Version Latest

# ─── Device model ───────────────────────────────────────────────────────────────

function Get-KnxDeviceFamily {
    <#
    .SYNOPSIS
        Maps a mask version to the device family that decides which cases apply.
    .DESCRIPTION
        The ranges are the ones the firmware itself uses (OFM-FileTransferModule
        KnxDeviceMap.h), so a device classified here is classified the same way by ftc.
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
        Start-Sleep -Milliseconds 400
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
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][byte[]]$Tpdu, [int]$TimeoutMs = 3000)
    $K = Get-KnxConstants
    $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $Session.Dst -Tpdu $Tpdu -Priority 0
    $r = Send-KnxTunnelCemi -Connection $Session.Conn -Cemi $cemi -TimeoutMs $TimeoutMs
    return [pscustomobject]@{ Acked = $r.Acked; Status = $r.Status; Sent = $cemi }
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
        [switch]$NoAckResponse
    )
    $K = Get-KnxConstants
    $seq = -1
    if (-not $Connectionless) {
        $seq = if ($ForceSequence -ge 0) { $ForceSequence } else { $Session.SeqSend }
    }
    $tpdu = New-TpduService -Apci $Apci -Data $Data -Sequence $seq
    $sent = Send-KnxDeviceTpdu -Session $Session -Tpdu $tpdu -TimeoutMs 3000

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
        Frames       = @()
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
        if ($ld.Source -ne $Session.Dst) { continue }
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
                }
            }
        }
        if ($null -ne $out.Response) {
            if ($ExpectApci -lt 0 -or $out.ResponseApci -eq $ExpectApci) { break }
            # Not the service we asked for - keep listening, it may still arrive.
            $out.Response = $null; $out.ResponseApci = -1
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

function Invoke-KnxSuiteDevice {
    <#
    .SYNOPSIS
        Runs the device conformance cases against ONE individual address.
    .PARAMETER Ctx
        Run context: BdutIp and Port name the INTERFACE used as the window, SkipSlow drops
        the six-second timeout case, ReadOnly is honoured by every case that puts a
        telegram on the bus towards a third party.
    .PARAMETER Target
        The individual address of the device under test, e.g. 5.0.3.
    #>
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)][string]$Target,
        [string]$SuiteTitle = 'D Device on TP'
    )

    $K = Get-KnxConstants
    $ip = $Ctx.BdutIp
    $port = $Ctx.Port
    $tag = $Target

    # The profile is read ONCE, before the cases, and every later case reads it. Deriving
    # it inside a test body would leave it undefined whenever that body skips or fails, and
    # the following cases would then silently judge a device model nobody established.
    $profile = [pscustomobject]@{
        Alive      = $false
        Descriptor = [byte[]]@()
        Mask       = -1
        Family     = 'unknown'
        HasProps   = $false
        MaxApdu    = -1
        Reason     = ''
    }

    # ── D-1 Identification ──────────────────────────────────────────────────────

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-1.1 $tag" -Title 'Device Descriptor Type 0 - the device identifies itself' `
                       -Clause '03_03_07 clause 3.4.2.1, p.48; 03_05_01 mask versions' -Body {
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@()) `
                                         -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 5000 -Connectionless
            Add-KnxEvidence -Sent $r.Sent
            if ($null -ne $r.Response) { Add-KnxEvidence -Received $r.Response }
            if ($r.Confirmed -eq $false) {
                $profile.Reason = "nothing on the bus acknowledged a telegram to $Target"
                Set-KnxTestSkip $profile.Reason
            }
            Assert-KnxTrue ($null -ne $r.Response) "no A_DeviceDescriptor_Response from $Target"
            Assert-KnxTrue ($r.Response.Length -ge 4) 'the descriptor response carries no descriptor'

            $profile.Alive = $true
            $profile.Descriptor = [byte[]]$r.Response[2..3]
            $profile.Mask = ((([int]$r.Response[2]) -shl 8) -bor ([int]$r.Response[3]))
            $profile.Family = Get-KnxDeviceFamily -Mask $profile.Mask
            $profile.HasProps = Test-KnxFamilyHasProperties -Family $profile.Family
            Add-KnxEvidence -Note ("mask 0x{0:X4} -> family {1}" -f $profile.Mask, $profile.Family)
            # An unknown mask is not a defect - it is a device model this suite does not
            # know, and saying so is worth more than guessing it into the nearest family.
            if ($profile.Family -eq 'unknown') {
                Add-KnxEvidence -Note 'mask not in any family this suite knows - the property cases will report N-A'
            }
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    # From here on every property case needs the same three decisions, so they are made
    # once in a helper rather than copied five times - a copied gate is a gate that drifts.
    $propGate = {
        param([string]$What)
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        if (-not $profile.HasProps) {
            Set-KnxTestNotApplicable ("mask 0x{0:X4} ({1}) has no interface-object property layer - {2} is not required of it" -f $profile.Mask, $profile.Family, $What)
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-1.2 $tag" -Title 'PID_DEVICE_DESCRIPTOR agrees with the descriptor service' `
                       -Clause '03_05_01 PID_DEVICE_DESCRIPTOR (83); 03_03_07 clause 3.4.4.1, p.63' -Body {
        & $propGate 'PID_DEVICE_DESCRIPTOR'
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            $p = Read-KnxDeviceProperty -Session $s -ObjectIndex 0 -PropertyId 83
            Add-KnxEvidence -Sent $p.Exchange.Sent
            if ($p.Answered) { Add-KnxEvidence -Received $p.Exchange.Response }
            Assert-KnxTrue $p.Answered 'no A_PropertyValue_Response for PID_DEVICE_DESCRIPTOR'
            if (-not $p.Ok) { Set-KnxTestSkip 'device answered with nr_of_elem = 0 - it does not expose PID_DEVICE_DESCRIPTOR' }
            Add-KnxEvidence -Expected $profile.Descriptor -Received $p.Data
            # Two independent paths to the same fact. They disagreeing is a real defect:
            # ETS reads one of them and the device claims to be something it is not.
            Assert-KnxBytes -Expected $profile.Descriptor -Actual ([byte[]]$p.Data[0..1]) `
                            'PID_DEVICE_DESCRIPTOR and A_DeviceDescriptor_Read report different mask versions'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-1.3 $tag" -Title 'Device Object is object type 0' `
                       -Clause '03_05_01 PID_OBJECT_TYPE (1), Device Object' -Body {
        & $propGate 'PID_OBJECT_TYPE'
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            $p = Read-KnxDeviceProperty -Session $s -ObjectIndex 0 -PropertyId $K.Pid.OBJECT_TYPE
            Add-KnxEvidence -Sent $p.Exchange.Sent
            if ($p.Answered) { Add-KnxEvidence -Received $p.Exchange.Response }
            Assert-KnxTrue $p.Answered 'no answer for PID_OBJECT_TYPE on object index 0'
            Assert-KnxTrue $p.Ok 'device answered PID_OBJECT_TYPE with nr_of_elem = 0 - object index 0 is not the Device Object'
            Assert-KnxTrue ($p.Data.Length -ge 2) 'PID_OBJECT_TYPE is a two-octet value'
            $type = ((([int]$p.Data[0]) -shl 8) -bor ([int]$p.Data[1]))
            Add-KnxEvidence -Note "object index 0 reports object type $type"
            Assert-KnxEqual 0 $type 'object index 0 is not the Device Object'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-1.4 $tag" -Title 'Serial number present and not empty' `
                       -Clause '03_05_01 PID_SERIAL_NUMBER (11)' -Body {
        & $propGate 'PID_SERIAL_NUMBER'
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            $p = Read-KnxDeviceProperty -Session $s -ObjectIndex 0 -PropertyId $K.Pid.SERIAL_NUMBER
            Add-KnxEvidence -Sent $p.Exchange.Sent
            if ($p.Answered) { Add-KnxEvidence -Received $p.Exchange.Response }
            Assert-KnxTrue $p.Answered 'no answer for PID_SERIAL_NUMBER'
            Assert-KnxTrue $p.Ok 'device answered PID_SERIAL_NUMBER with nr_of_elem = 0'
            Assert-KnxEqual 6 $p.Data.Length 'PID_SERIAL_NUMBER is a six-octet value'
            $nonZero = $false
            foreach ($b in $p.Data) { if ($b -ne 0) { $nonZero = $true; break } }
            Add-KnxEvidence -Note ("serial number " + (ConvertTo-HexString -Bytes $p.Data))
            # An all-zero serial number is what an unconfigured or cloned device reports,
            # and it breaks every ETS procedure that selects a device by serial number.
            Assert-KnxTrue $nonZero 'PID_SERIAL_NUMBER is all zero'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-1.5 $tag" -Title 'Manufacturer identifier present' `
                       -Clause '03_05_01 PID_MANUFACTURER_ID (12)' -Body {
        & $propGate 'PID_MANUFACTURER_ID'
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            $p = Read-KnxDeviceProperty -Session $s -ObjectIndex 0 -PropertyId $K.Pid.MANUFACTURER_ID
            Add-KnxEvidence -Sent $p.Exchange.Sent
            if ($p.Answered) { Add-KnxEvidence -Received $p.Exchange.Response }
            Assert-KnxTrue $p.Answered 'no answer for PID_MANUFACTURER_ID'
            Assert-KnxTrue $p.Ok 'device answered PID_MANUFACTURER_ID with nr_of_elem = 0'
            Assert-KnxTrue ($p.Data.Length -ge 2) 'PID_MANUFACTURER_ID is a two-octet value'
            $mid = ((([int]$p.Data[0]) -shl 8) -bor ([int]$p.Data[1]))
            Add-KnxEvidence -Note ("manufacturer id {0} (0x{0:X4})" -f $mid)
            Assert-KnxTrue ($mid -ne 0) 'PID_MANUFACTURER_ID is 0 - not an assigned manufacturer'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-1.6 $tag" -Title 'Maximum APDU length is declared and usable' `
                       -Clause '03_05_01 PID_MAX_APDU_LENGTH (56)' -Body {
        & $propGate 'PID_MAX_APDU_LENGTH'
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            $p = Read-KnxDeviceProperty -Session $s -ObjectIndex 0 -PropertyId $K.Pid.MAX_APDU_LENGTH
            Add-KnxEvidence -Sent $p.Exchange.Sent
            if ($p.Answered) { Add-KnxEvidence -Received $p.Exchange.Response }
            Assert-KnxTrue $p.Answered 'no answer for PID_MAX_APDU_LENGTH'
            if (-not $p.Ok) { Set-KnxTestSkip 'device answered with nr_of_elem = 0 - it does not expose PID_MAX_APDU_LENGTH' }
            $max = if ($p.Data.Length -ge 2) { ((([int]$p.Data[0]) -shl 8) -bor ([int]$p.Data[1])) } else { [int]$p.Data[0] }
            $profile.MaxApdu = $max
            Add-KnxEvidence -Note "declared maximum APDU length $max octets"
            # 15 is the smallest APDU a device can work with at all; anything below it
            # cannot carry the property services this device just answered.
            Assert-KnxTrue ($max -ge 15) "declared maximum APDU length $max is below the 15 octet minimum"
            Assert-KnxTrue ($max -le 254) "declared maximum APDU length $max exceeds what a TP1 frame can carry"
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-1.7 $tag" -Title 'Product inventory - order info, hardware type, version' `
                       -Clause '03_05_01 PID_ORDER_INFO (15), PID_HARDWARE_TYPE (78), PID_VERSION (25)' -Body {
        & $propGate 'the product inventory properties'
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # These are recorded, not judged. Which of them a device must carry depends on
            # its profile and its certification scope, and a suite that turns "absent" into
            # FAIL here would report every uncertified prototype as broken. What the report
            # needs is the values - so an auditor can see them next to the datasheet.
            $any = $false
            foreach ($item in @(
                    @{ Pid = $K.Pid.ORDER_INFO; Name = 'PID_ORDER_INFO' },
                    @{ Pid = 78;               Name = 'PID_HARDWARE_TYPE' },
                    @{ Pid = $K.Pid.VERSION;   Name = 'PID_VERSION' })) {
                $p = Read-KnxDeviceProperty -Session $s -ObjectIndex 0 -PropertyId $item.Pid -TimeoutMs 4000
                if ($p.Ok) {
                    $any = $true
                    Add-KnxEvidence -Note ("{0} = {1}" -f $item.Name, (ConvertTo-HexString -Bytes $p.Data))
                }
                elseif ($p.Answered) { Add-KnxEvidence -Note ("{0}: nr_of_elem = 0 (not exposed)" -f $item.Name) }
                else { Add-KnxEvidence -Note ("{0}: no answer" -f $item.Name) }
            }
            Assert-KnxTrue $any 'the device exposed none of the three product identification properties'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    # ── D-2 Transport layer, connection-oriented ────────────────────────────────

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-2.1 $tag" -Title 'Connect, numbered request, acknowledge, answer, disconnect' `
                       -Clause '03_03_04 clause 5.3 action A2, clause 5.4 event E04' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@()) `
                                         -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 6000
            Add-KnxEvidence -Sent $r.Sent
            if ($null -ne $r.Response) { Add-KnxEvidence -Received $r.Response }
            Add-KnxEvidence -Note ("received {0} frame(s) from {1}" -f $r.Frames.Count, $Target)
            # A2 is one action with two halves. A device that answers but never acknowledges
            # works with a forgiving client and fails with ETS, so both are asserted.
            Assert-KnxTrue $r.Acked 'device did not acknowledge the numbered request (T_ACK missing, action A2)'
            Assert-KnxEqual 0 $r.AckSequence 'the T_ACK carries the wrong sequence number for the first request'
            Assert-KnxTrue ($null -ne $r.Response) 'device acknowledged but never answered the request'
            Assert-KnxTrue (-not $r.Disconnected) 'device dropped the connection during a valid exchange'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-2.2 $tag" -Title 'Repeated sequence number is acknowledged again, not rejected' `
                       -Clause '03_03_04 clause 5.4 event E05, action A3' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # E05 is defined as "one behind what I expect", so there has to be a completed
            # exchange first - sending the repeat as the very first telegram would be E06
            # and would correctly earn a T_NAK. The precondition is asserted, not assumed.
            $first = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@()) `
                                             -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 6000
            Assert-KnxTrue $first.Acked 'the device did not acknowledge the first request - E05 cannot be reached'
            Assert-KnxEqual 1 $s.SeqSend 'the send counter did not advance after a successful exchange'

            $repeat = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@()) `
                                              -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -ForceSequence 0 -TimeoutMs 5000
            Add-KnxEvidence -Sent $repeat.Sent
            Add-KnxEvidence -Note ("acked={0} seq={1} nak={2} disconnected={3}" -f $repeat.Acked, $repeat.AckSequence, $repeat.Nak, $repeat.Disconnected)
            Assert-KnxTrue $repeat.Acked 'device did not acknowledge a repeated sequence number (action A3)'
            Assert-KnxEqual 0 $repeat.AckSequence 'the acknowledge must carry the sequence number of the received message'
            Assert-KnxTrue (-not $repeat.Nak) 'device answered a repeated sequence number with T_NAK instead of T_ACK'
            Assert-KnxTrue (-not $repeat.Disconnected) 'device dropped the connection on a repeated sequence number'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-2.3 $tag" -Title 'Out-of-window sequence number is answered with T_NAK' `
                       -Clause '03_03_04 clause 5.4 event E06, action A4' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # Sequence 5 is neither what the device expects (0) nor the one before it (15),
            # so it is E06 in every one of the three transition-table styles - the verdict
            # does not depend on which style the manufacturer implemented.
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@()) `
                                         -ForceSequence 5 -TimeoutMs 5000
            Add-KnxEvidence -Sent $r.Sent
            Add-KnxEvidence -Note ("acked={0} nak={1} nakSeq={2} disconnected={3} frames={4}" -f $r.Acked, $r.Nak, $r.NakSequence, $r.Disconnected, $r.Frames.Count)
            if ($r.Frames.Count -eq 0) { Assert-KnxTrue $false 'device stayed silent on an out-of-window sequence number - A4 requires a T_NAK' }
            Assert-KnxTrue $r.Nak 'device did not answer an out-of-window sequence number with T_NAK (action A4)'
            Assert-KnxEqual 5 $r.NakSequence 'the T_NAK must carry the sequence number of the received message'
            Assert-KnxTrue (-not $r.Acked) 'device acknowledged an out-of-window sequence number instead of rejecting it'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-2.4 $tag" -Title 'Reserved transport control field is ignored' `
                       -Clause '03_03_04 clause 2 NOTE 1 (BFh reserved), clause 5.4 event E27, action A0' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # BFh is the encoding the specification reserves and forbids. E27 maps it to
            # A0 - do nothing - in all three styles, so it must neither be answered nor
            # allowed to break the open connection.
            $sent = Send-KnxDeviceTpdu -Session $s -Tpdu ([byte[]]@(0xBF)) -TimeoutMs 3000
            Add-KnxEvidence -Sent $sent.Sent
            Assert-KnxTrue $sent.Acked 'the interface did not accept the reserved-TPCI telegram'
            $reply = $null
            $deadline = [DateTime]::UtcNow.AddSeconds(2)
            while ([DateTime]::UtcNow -lt $deadline) {
                $in = Receive-KnxTunnelCemi -Connection $s.Conn -TimeoutMs 800
                if ($null -eq $in) { continue }
                $ld = Read-CemiLData -Cemi $in.Cemi
                if ($null -eq $ld -or $ld.MessageCode -ne $K.Cemi.L_DATA_IND) { continue }
                if ($ld.Source -eq $s.Dst) { $reply = $ld; break }
            }
            if ($null -ne $reply) { Add-KnxEvidence -Received $reply.Tpdu }
            Assert-KnxTrue ($null -eq $reply) 'device answered a reserved transport control field'

            # Two different questions, asked in the order that makes the answer readable.
            # First: is the DEVICE still there? Asked connectionless, so no sequence number
            # and no session state can colour the result. Then: is the CONNECTION still
            # there? Asking only the second question reports "device dead" for a device that
            # is perfectly alive and merely closed the session it should have kept.
            $alive = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@()) `
                                             -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 6000 -Connectionless
            Add-KnxEvidence -Note ("device alive after the reserved field: {0}" -f ($null -ne $alive.Response))
            Assert-KnxTrue ($null -ne $alive.Response) 'device stopped answering entirely after a reserved transport control field'

            $after = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@()) `
                                             -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 6000
            Add-KnxEvidence -Note ("connection after the reserved field: acked={0} answered={1} disconnected={2}" -f $after.Acked, ($null -ne $after.Response), $after.Disconnected)
            Assert-KnxTrue ($after.Acked -or $null -ne $after.Response) 'device stayed alive but silently dropped the connection - the reserved encoding BFh was acted on instead of ignored'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-2.5 $tag" -Title 'Idle connection is released after the six second timeout' `
                       -Clause '03_03_04 clause 4 (connection timeout 6 s), clause 5.4 event E16, action A6' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        if ($Ctx.SkipSlow) { Set-KnxTestSkip 'measures the six second connection timeout - excluded by -SkipSlow' }
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            $first = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@()) `
                                             -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 6000
            Assert-KnxTrue $first.Acked 'the device did not acknowledge the first request - the timer never started'

            # A6 sends a T_Disconnect to the remote partner, so this is observable from
            # outside: keep quiet and watch. Ten seconds is the 6 s timer plus room for a
            # device that restarts it on our own outgoing frames.
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $disc = $null
            while ($sw.Elapsed.TotalSeconds -lt 10 -and $null -eq $disc) {
                $in = Receive-KnxTunnelCemi -Connection $s.Conn -TimeoutMs 1000
                if ($null -eq $in) { continue }
                $ld = Read-CemiLData -Cemi $in.Cemi
                if ($null -eq $ld -or $ld.MessageCode -ne $K.Cemi.L_DATA_IND) { continue }
                if ($ld.Source -ne $s.Dst) { continue }
                if ((Get-KnxTpduKind -Tpdu $ld.Tpdu).Kind -eq 'Disconnect') { $disc = $ld }
            }
            $sw.Stop()
            if ($null -ne $disc) {
                $s.Connected = $false
                Add-KnxEvidence -Received $disc.Tpdu -Note ("T_Disconnect after {0:N1} s" -f $sw.Elapsed.TotalSeconds)
            }
            else { Add-KnxEvidence -Note 'no T_Disconnect within 10 s of silence' }
            Assert-KnxTrue ($null -ne $disc) 'device kept an idle connection open past its six second timeout (action A6 not performed)'
            Assert-KnxTrue ($sw.Elapsed.TotalSeconds -ge 5.0) ("connection released after only {0:N1} s - earlier than the six second timeout" -f $sw.Elapsed.TotalSeconds)
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    # ── D-3 Application layer ───────────────────────────────────────────────────

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-3.1 $tag" -Title 'Unknown property is refused with nr_of_elem = 0' `
                       -Clause '03_03_07 clause 3.4.4.1, p.63' -Body {
        & $propGate 'the property services'
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # 254 is inside the property-id range and assigned to nothing, so a device that
            # answers with data here is inventing a property. The specification prescribes
            # exactly one answer for "does not exist": a response with no elements.
            $p = Read-KnxDeviceProperty -Session $s -ObjectIndex 0 -PropertyId 254
            Add-KnxEvidence -Sent $p.Exchange.Sent
            if ($p.Answered) { Add-KnxEvidence -Received $p.Exchange.Response }
            Add-KnxEvidence -Note ("answered={0} nr_of_elem={1} data={2} octet(s)" -f $p.Answered, $p.ElementCount, $p.Data.Length)
            # Silence is the common wrong answer here: it leaves ETS waiting for a timeout
            # instead of moving on, which is why the specification demands a response.
            Assert-KnxTrue $p.Answered 'device stayed silent on an unknown property instead of answering with nr_of_elem = 0'
            Assert-KnxEqual 0 $p.ElementCount 'device answered an unknown property with a non-zero element count'
            Assert-KnxEqual 0 $p.Data.Length 'device returned data for an unknown property'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-3.2 $tag" -Title 'Unknown object index is refused with nr_of_elem = 0' `
                       -Clause '03_03_07 clause 3.4.4.1, p.63' -Body {
        & $propGate 'the property services'
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # Same prescribed answer, different input shape: the object is missing rather
            # than the property. A device that guards only one of the two indexes passes the
            # case above and fails here - which is the whole point of running both.
            $p = Read-KnxDeviceProperty -Session $s -ObjectIndex 200 -PropertyId $K.Pid.OBJECT_TYPE
            Add-KnxEvidence -Sent $p.Exchange.Sent
            if ($p.Answered) { Add-KnxEvidence -Received $p.Exchange.Response }
            Add-KnxEvidence -Note ("answered={0} nr_of_elem={1} data={2} octet(s)" -f $p.Answered, $p.ElementCount, $p.Data.Length)
            Assert-KnxTrue $p.Answered 'device stayed silent on an unknown object index instead of answering with nr_of_elem = 0'
            Assert-KnxEqual 0 $p.ElementCount 'device answered an unknown object index with a non-zero element count'
            Assert-KnxEqual 0 $p.Data.Length 'device returned data for an unknown object index'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-3.3 $tag" -Title 'Property response echoes what was asked for' `
                       -Clause '03_03_07 clause 3.4.4.1, p.63, Figure 46/47' -Body {
        & $propGate 'the property services'
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # The response carries object_index, property_id and start_index back. A client
            # that has two reads in flight tells them apart by exactly these fields, so an
            # echo that does not match is a correlation bug waiting to happen - the frame
            # is well formed and still wrong, which no length or syntax check would catch.
            $p = Read-KnxDeviceProperty -Session $s -ObjectIndex 0 -PropertyId $K.Pid.OBJECT_TYPE -ElementCount 1 -StartIndex 1
            Add-KnxEvidence -Sent $p.Exchange.Sent
            if ($p.Answered) { Add-KnxEvidence -Received $p.Exchange.Response }
            Assert-KnxTrue $p.Answered 'no answer for PID_OBJECT_TYPE'
            Add-KnxEvidence -Note ("echo: objectIndex={0} propertyId={1} startIndex={2}" -f $p.ObjectIndex, $p.PropertyId, $p.StartIndex)
            Assert-KnxEqual 0 $p.ObjectIndex 'the response does not echo the requested object index'
            Assert-KnxEqual $K.Pid.OBJECT_TYPE $p.PropertyId 'the response does not echo the requested property id'
            Assert-KnxEqual 1 $p.StartIndex 'the response does not echo the requested start index'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    # ── D-4 Robustness ──────────────────────────────────────────────────────────

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-4.1 $tag" -Title 'Truncated APDU is ignored and does not break the connection' `
                       -Clause '03_03_04 clause 5 (invalid PDUs are ignored)' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # A numbered data PDU whose APCI octet is missing. The transport control field
            # is valid, so the frame gets past the first check and only the application
            # layer can notice - the exact shape that finds an unguarded read.
            $sent = Send-KnxDeviceTpdu -Session $s -Tpdu ([byte[]]@(0x40)) -TimeoutMs 3000
            Add-KnxEvidence -Sent $sent.Sent
            Assert-KnxTrue $sent.Acked 'the interface did not accept the truncated telegram'
            Start-Sleep -Milliseconds 800
            # Drain whatever the device chose to answer - a T_ACK is acceptable here, the
            # transport layer received a syntactically valid numbered PDU. What must not
            # happen is a device that stops working.
            while ($true) {
                $in = Receive-KnxTunnelCemi -Connection $s.Conn -TimeoutMs 400
                if ($null -eq $in) { break }
            }
            # Whether the device counted the truncated PDU as received decides which
            # sequence number it now expects, and nobody outside the device knows which.
            # Asking connectionless removes that question from the assertion - this case is
            # about survival, not about sequence bookkeeping. Guessing the number here
            # reported a live device as dead.
            #
            # And "does it answer" is the wrong question on its own: a device that needs a
            # moment and a device that is gone both look identical in a single probe. What
            # an implementer can act on is HOW LONG it was away, so that is what is measured
            # - up to four attempts over roughly twenty seconds.
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $alive = $null
            $tunnelDead = $false
            for ($try = 1; $try -le 4; $try++) {
                $probe = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@()) `
                                                 -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 5000 -Connectionless
                if ($null -ne $probe.Response) { $alive = $probe; break }
                # "The device is silent" and "the interface stopped taking our requests"
                # produce the same empty result and mean opposite things - one is a device
                # verdict, the other is the window failing. The TUNNELLING_ACK separates
                # them, so it is recorded instead of averaged into one word.
                if ($probe.PSObject.Properties['Disconnected'] -and $probe.Disconnected) { $tunnelDead = $true }
                elseif (-not $probe.TunnelAcked) { $tunnelDead = $true }
                Add-KnxEvidence -Note ("attempt {0}: no answer after {1:N1} s (tunnel acknowledged our request: {2})" -f $try, $sw.Elapsed.TotalSeconds, $probe.TunnelAcked)
            }
            $sw.Stop()
            if ($null -eq $alive -and $tunnelDead) {
                Set-KnxTestSkip 'the interface ended the tunnel while this case ran (03_08_04 clause 2.6.1 - it repeats once, then disconnects) - the window closed, so this says nothing about the device'
            }
            if ($null -ne $alive) {
                Add-KnxEvidence -Received $alive.Response -Note ("device answered again after {0:N1} s" -f $sw.Elapsed.TotalSeconds)
            }
            Assert-KnxTrue ($null -ne $alive) ("device never answered again within {0:N0} s of a truncated APDU" -f $sw.Elapsed.TotalSeconds)
            # Coming back is not the same as never having gone. A device that needs seconds
            # to serve a request again dropped everything else on the bus meanwhile.
            Assert-KnxTrue ($sw.Elapsed.TotalSeconds -lt 3.0) ("device needed {0:N1} s to answer again after a truncated APDU" -f $sw.Elapsed.TotalSeconds)
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-4.2 $tag" -Title 'Oversized APDU does not take the device down' `
                       -Clause '03_05_01 PID_MAX_APDU_LENGTH (56); 03_03_04 clause 5' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # Longer than the device said it can take, and connectionless so the frame is
            # judged on its own without a session state to blame. The verdict is not about
            # the answer - it is about the device still being there afterwards.
            $len = if ($profile.MaxApdu -gt 0) { [Math]::Min(240, $profile.MaxApdu + 20) } else { 200 }
            $pad = New-Object byte[] $len
            for ($i = 0; $i -lt $len; $i++) { $pad[$i] = [byte](0x41 + ($i % 26)) }
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.PROPERTY_VALUE_READ -Data $pad -TimeoutMs 3000 -Connectionless
            Add-KnxEvidence -Sent $r.Sent -Note "sent an APDU of $($len + 2) octets against a declared maximum of $($profile.MaxApdu)"
            Start-Sleep -Milliseconds 500

            $check = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@()) `
                                             -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 6000 -Connectionless
            if ($null -ne $check.Response) { Add-KnxEvidence -Received $check.Response }
            Assert-KnxTrue ($null -ne $check.Response) 'device no longer answers a device descriptor read after an oversized APDU'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-4.3 $tag" -Title 'Repeated connect and disconnect leaks no connection slot' `
                       -Clause '03_03_04 clause 5.4 events E00/E02, actions A1/A5' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # A device holds ONE connection-oriented session. If a T_Disconnect does not
            # really release it, the second or third cycle finds a device that still thinks
            # it is talking to someone else - and the failure only appears after a while,
            # which is why this runs ten cycles and not one.
            $cycles = 10
            for ($i = 0; $i -lt $cycles; $i++) {
                $cn = Send-KnxDeviceTpdu -Session $s -Tpdu (New-TpduConnect) -TimeoutMs 2000
                Assert-KnxTrue $cn.Acked "the interface stopped accepting telegrams at cycle $($i + 1)"
                Start-Sleep -Milliseconds 120
                $dc = Send-KnxDeviceTpdu -Session $s -Tpdu (New-TpduDisconnect) -TimeoutMs 2000
                Assert-KnxTrue $dc.Acked "the interface stopped accepting telegrams at cycle $($i + 1)"
                Start-Sleep -Milliseconds 120
                while ($true) { $in = Receive-KnxTunnelCemi -Connection $s.Conn -TimeoutMs 200; if ($null -eq $in) { break } }
            }
            Add-KnxEvidence -Note "$cycles connect/disconnect cycles completed"

            $s.SeqSend = 0
            $cn = Send-KnxDeviceTpdu -Session $s -Tpdu (New-TpduConnect) -TimeoutMs 2000
            Assert-KnxTrue $cn.Acked 'the interface did not accept the final T_Connect'
            $s.Connected = $true
            $after = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@()) `
                                             -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 6000
            Add-KnxEvidence -Note ("after {0} cycles: acked={1} answered={2}" -f $cycles, $after.Acked, ($null -ne $after.Response))
            Assert-KnxTrue $after.Acked "device no longer acknowledges a new connection after $cycles connect/disconnect cycles"
            Assert-KnxTrue ($null -ne $after.Response) "device no longer answers on a new connection after $cycles connect/disconnect cycles"
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    # ── D-5 Addressing ──────────────────────────────────────────────────────────

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-5.1 $tag" -Title 'Answers carry the addressed individual address as source' `
                       -Clause '03_03_03 Network Layer; 03_05_02 Management Procedures' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@()) `
                                         -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 6000 -Connectionless
            Assert-KnxTrue ($null -ne $r.Response) "no answer from $Target"
            Assert-KnxTrue ($r.Frames.Count -gt 0) 'no frame was recorded for the answer'
            $src = ConvertFrom-KnxPa -Raw $r.Frames[0].Source
            Add-KnxEvidence -Received $r.Response -Note "answer came from $src"
            Assert-KnxEqual $Target $src 'the answer does not carry the addressed device as source address'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-5.2 $tag" -Title 'No device answers for a provably free address on the same line' `
                       -Clause '03_05_02 Management Procedures; 03_03_03 Network Layer' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # A free address is not assumed, it is proven: a telegram to it gets a NEGATIVE
            # L_Data.con because nothing on the line acknowledged it on layer 2. Only then
            # does silence on layer 7 mean anything - without that proof this case would
            # pass just as happily against an address that is simply switched off.
            $parts = $Target -split '\.'
            Assert-KnxTrue ($parts.Count -eq 3) "cannot derive a neighbour address from $Target"
            $free = ''
            foreach ($dev in @(250, 251, 249, 248, 247)) {
                $cand = "$($parts[0]).$($parts[1]).$dev"
                if ($cand -eq $Target) { continue }
                $probe = [pscustomobject]@{ Ok = $true; Conn = $s.Conn; Pa = $cand; Dst = (ConvertTo-KnxPa -Address $cand); SeqSend = 0; SeqRecv = 0; Connected = $false; LastCon = $null; Reason = '' }
                [void](Send-KnxDeviceTpdu -Session $probe -Tpdu (New-TpduService -Apci $K.Apci.DEVICE_DESCRIPTOR_READ) -TimeoutMs 3000)
                $con = Wait-KnxDeviceConfirmation -Session $probe -TimeoutMs 3000
                if ($null -ne $con -and -not (Test-KnxConPositive -LData $con)) { $free = $cand; break }
            }
            if (-not $free) { Set-KnxTestSkip 'found no provably free address on this line - every candidate was acknowledged on the bus' }
            Add-KnxEvidence -Note "$free is free (negative L_Data.con - nothing on the line acknowledged it)"

            $probe = [pscustomobject]@{ Ok = $true; Conn = $s.Conn; Pa = $free; Dst = (ConvertTo-KnxPa -Address $free); SeqSend = 0; SeqRecv = 0; Connected = $false; LastCon = $null; Reason = '' }
            $r = Invoke-KnxDeviceService -Session $probe -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@()) -TimeoutMs 3000 -Connectionless
            if ($null -ne $r.Response) { Add-KnxEvidence -Received $r.Response }
            Assert-KnxTrue ($null -eq $r.Response) "a device answered for $free, which nothing on the bus acknowledged - two devices disagree about who owns that address"
        }
        finally { Close-KnxDeviceSession -Session $s }
    }
}
