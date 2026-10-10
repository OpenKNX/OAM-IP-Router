#!/usr/bin/env pwsh
# Open ■
# ┬────┴  D-Device.Tests
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/Suites/D-Device.Tests.ps1

<#
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


# The device layer lives in its own module now - sessions, services, witness, helpers. This file
# holds test CASES only.
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/KnxDevice.psm1') -Force -DisableNameChecking

function Invoke-KnxSuiteDevice {
    <#
    .SYNOPSIS
        Runs the device conformance cases against ONE individual address.
    .PARAMETER Ctx
        Run context: BdutIp and Port name the INTERFACE used as the window, SkipSlow drops
        the six-second timeout case, ReadOnly is honoured by every case that puts a
        telegram on the bus towards a third party.
    .PARAMETER Target
        The individual address of the device under test, e.g. 1.1.7.
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
        GroupAddresses = @()
        MaxApdu    = -1
        Reason     = ''
        # Read once and reused: every case that re-derives one of these pays a bus round trip, and
        # D-22.3 / D-22.4 re-derived them twelve times per target.
        Serial     = $null     # PID_SERIAL_NUMBER, 6 octets
        SerialProbed = $false  # the device answered the read, with the serial or without
        AnswerGa   = ''        # the group address this device was observed to answer a read on
        FreeAddress = ''       # an address on this line that nothing acknowledges on layer 2
        FreeAddressProbed = $false
        FreeAddressNote = ''   # why FreeAddress is empty
    }

    # A connectionless probe to the target on a session that was opened for another address. The
    # tunnel is shared, only the destination differs, so no second tunnel channel is taken.
    $probeOn = {
        param($Session, [string]$Pa)
        [pscustomobject]@{
            Ok = $true; Reason = ''; Broadcast = $false; Conn = $Session.Conn
            Pa = $Pa; Dst = (ConvertTo-KnxPa -Address $Pa)
            SeqSend = 0; SeqRecv = 0; Connected = $false; LastCon = $null
        }
    }

    # Silence is only evidence when something was there to break it. A rig whose tunnel pool is
    # exhausted answers nothing at all - measured on an MDT with four slots, where the fifth connect
    # got 0x24 and every request past the seventh went unanswered - and every "must not answer" case
    # then passes without having tested anything.
    # The question is asked on the CHANNEL THAT CARRIED THE STIMULUS first, connectionless so no
    # sequence counter of the case can colour it. That is the stronger statement - it proves this very
    # tunnel still carries a request to the device and an answer back - and it takes no second tunnel
    # channel. Opening one here is what exhausted the pool the gate exists to detect: seven of the nine
    # call sites run with the case's own session still open, and on a four-slot interface the gate's
    # extra connect was the one that got refused.
    # Only when the same channel goes quiet is a fresh connection opened, to separate a rig fault from
    # a device fault. Called ONCE per case and only when the case actually saw silence.
    $liveGate = {
        param([string]$What, $Session)
        $onSame = $false
        $haveSession = ($null -ne $Session -and $Session.Ok -and $null -ne $Session.Conn)
        if ($haveSession) {
            # Two attempts: one missed answer on a busy line would otherwise turn a conformant
            # silence into "the channel died". A device that is really gone stays quiet for both.
            $probe = & $probeOn $Session $Target
            foreach ($attempt in 1, 2) {
                if ($attempt -gt 1) { [void](Wait-KnxTunnel -Connection $Session.Conn -Ms 500) }
                $q = Invoke-KnxDeviceService -Session $probe -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@(0x00)) `
                                             -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 2500 -Connectionless
                $onSame = ($null -ne $q.Response)
                if ($onSame) { break }
            }
            Add-KnxEvidence -Note ("device answers a valid request on the same channel afterwards: {0}" -f $onSame)
            if ($onSame) { return }
            # The fresh probe connects, and a device that still holds this case's connection answers a
            # T_Connect from another source with T_Disconnect (03_03_04 E01/A10 in Style 1, 3 and 1 Rationalised, p.21/24/26) - so release it first.
            if ($Session.Connected) {
                try { [void](Send-KnxDeviceTpdu -Session $Session -Tpdu (New-TpduDisconnect) -TimeoutMs 2000) } catch { }
                $Session.Connected = $false
            }
        }
        $u = Test-KnxDeviceStillUsable -Ip $ip -Port $port -Pa $Target
        Add-KnxEvidence -Note ("device answers a valid request on a fresh connection afterwards: {0}" -f $u.Ok)
        if ($u.RigFault) { Set-KnxTestNotApplicable ("rig fault, not a device finding: {0}" -f $u.Reason) }
        if (-not $u.Ok) { Set-KnxTestNotApplicable "$Target does not answer a valid request on a fresh connection either, so $What proves nothing" }
        if ($haveSession) {
            Set-KnxTestNotApplicable "the channel that carried the stimulus stopped answering while $Target still answers on a fresh connection, so $What cannot be attributed to the device"
        }
    }

    # PID_SERIAL_NUMBER, read at most once per target. Eight D-22.4 cases read it on a connection of
    # their own, twice per case; the serial does not change between them. Returns $null when it is not
    # readable, including when the read throws - a missing serial is a missing input, not a case failure.
    # A device answer without the serial is kept as well; no session or no answer is asked again.
    $serialOf = {
        if ($null -ne $profile.Serial -or $profile.SerialProbed) { return $profile.Serial }
        $ss = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $ss.Ok) { return $null }
        try {
            $p = Read-KnxDeviceProperty -Session $ss -ObjectIndex 0 -PropertyId $K.Pid.SERIAL_NUMBER
            if ($p.Ok -and $p.Data.Length -eq 6) { $profile.Serial = $p.Data }
            if ($p.Answered) { $profile.SerialProbed = $true }
        }
        catch { }
        finally { try { Close-KnxDeviceSession -Session $ss } catch { } }
        return $profile.Serial
    }

    # An address on this line that nothing answers for, PROVEN by a negative L_Data.con - nothing
    # acknowledged the frame on layer 2. Used by D-5.2; kept per target. D-30.2 cannot use it: an
    # acknowledge-based "free" excludes exactly the device that acknowledges foreign traffic.
    # The high device numbers are where an IP interface parks its tunnel addresses: the sending
    # interface confirms a frame to one of its own tunnel addresses itself, with no bus acknowledge in
    # play, so the candidate looks occupied. Lower numbers go first so a tunnel pool cannot use up the
    # whole list. No confirmation at all is the channel not reporting, not an occupied address, and it
    # ends the probe without marking the line as having none.
    $freeAddressOn = {
        param($Session)
        if ($profile.FreeAddressProbed) { return $profile.FreeAddress }
        $parts = $Target -split '\.'
        if ($parts.Count -ne 3) { $profile.FreeAddressProbed = $true; $profile.FreeAddressNote = "$Target is not a three-part individual address"; return '' }
        $complete = $true
        foreach ($dev in @(200, 201, 202, 203, 204, 250, 251, 249, 248, 247)) {
            $cand = "$($parts[0]).$($parts[1]).$dev"
            if ($cand -eq $Target) { continue }
            $probe = & $probeOn $Session $cand
            [void](Send-KnxDeviceTpdu -Session $probe -Tpdu (New-TpduService -Apci $K.Apci.DEVICE_DESCRIPTOR_READ) -TimeoutMs 3000)
            $con = Wait-KnxDeviceConfirmation -Session $probe -TimeoutMs 3000
            if ($null -eq $con) {
                $complete = $false
                $profile.FreeAddressNote = "the sending interface reported no L_Data.con for $cand, so the probe ended without a result"
                break
            }
            if (-not (Test-KnxConPositive -LData $con)) { $profile.FreeAddress = $cand; break }
        }
        if ($complete -and -not $profile.FreeAddress) { $profile.FreeAddressNote = 'every candidate was acknowledged on the bus' }
        if ($complete -or $profile.FreeAddress) { $profile.FreeAddressProbed = $true }
        return $profile.FreeAddress
    }

    # Shared restore for every case that changes a device property. The value is written back and READ
    # BACK - "the write was sent" is not proof - and the result is RETURNED, never thrown: an exception
    # out of a finally replaces the result the case body carries.
    # A write the tunnel no longer accepts ends it at once: charging on would spend the read timeout as
    # well and report a property finding for what was a lost channel.
    # Accept is the set of read-back values that count as restored; Settle re-reads while a device is
    # still moving between states (03_05_01 clause 4.24.2.1 p.298 allows up to 30 s for a transition).
    $restoreProperty = {
        param($Ses, [int]$ObjectIndex, [int]$PropertyId, [int]$Value, [int[]]$Accept, [bool]$Changed, [int]$Settle = 0)
        if (-not $Changed) { return [pscustomobject]@{ Ok = $true; Note = 'nothing was changed, so nothing had to be restored' } }
        if ($null -eq $Ses -or -not $Ses.Ok -or $null -eq $Ses.Conn) {
            return [pscustomobject]@{ Ok = $false; Note = 'no session left to write the original value back with' }
        }
        try {
            $tries = 1 + [Math]::Max(0, $Settle)
            $v = -1
            for ($i = 0; $i -lt $tries; $i++) {
                # Read and acknowledge while waiting: Start-Sleep on an open tunnel loses it as soon
                # as the bus carries traffic (03_08_04 2.6.1 p.9).
                if ($i -gt 0) { [void](Wait-KnxTunnel -Connection $Ses.Conn -Ms 1000) }
                $w = Invoke-KnxDeviceService -Session $Ses -Apci $K.Apci.PROPERTY_VALUE_WRITE `
                         -Data ([byte[]]@([byte]$ObjectIndex, [byte]$PropertyId, 0x10, 0x01, [byte]$Value)) `
                         -ExpectApci $K.Apci.PROPERTY_VALUE_RESPONSE -TimeoutMs 4000
                if (-not $w.TunnelAcked) {
                    return [pscustomobject]@{ Ok = $false; Note = "the tunnel no longer accepted the write of object $ObjectIndex PID $PropertyId, so the original value could not be written back" }
                }
                $rb = Invoke-KnxDeviceService -Session $Ses -Apci $K.Apci.PROPERTY_VALUE_READ `
                          -Data ([byte[]]@([byte]$ObjectIndex, [byte]$PropertyId, 0x10, 0x01)) `
                          -ExpectApci $K.Apci.PROPERTY_VALUE_RESPONSE -TimeoutMs 4000
                if ($null -eq $rb.Response -or $rb.Response.Length -lt 7) {
                    return [pscustomobject]@{ Ok = $false; Note = "object $ObjectIndex PID $PropertyId could not be read back after the restore" }
                }
                $v = [int]$rb.Response[6]
                if ($Accept -contains $v) { break }
            }
            return [pscustomobject]@{ Ok = ($Accept -contains $v); Note = ("object {0} PID {1} reads {2} after the restore; accepted: {3}" -f $ObjectIndex, $PropertyId, $v, ($Accept -join '/')) }
        }
        catch { return [pscustomobject]@{ Ok = $false; Note = "writing object $ObjectIndex PID $PropertyId back threw: $($_.Exception.Message)" } }
    }

    # -- Rig power guard ------------------------------------------------------------
    # Read from the context once; a context without the fields (other callers) leaves the guard off.
    $ctxValue = { param([string]$Name, $Default) if ($Ctx.PSObject.Properties[$Name]) { $Ctx.$Name } else { $Default } }
    $pg = [pscustomobject]@{
        On        = [bool](& $ctxValue 'PowerGuard' $false)
        Write     = [string](& $ctxValue 'PowerRelayWrite' '')
        Status    = [string](& $ctxValue 'PowerRelayStatus' '')
        Via       = [string](& $ctxValue 'PowerRelayVia' '')
        DutPa     = [string](& $ctxValue 'DutPa' '')
        TrafficIp = [string](& $ctxValue 'TrafficIp' '')
        Protected = @(& $ctxValue 'ProtectedTargets' @())
    }

    # Protected target: nothing that restarts or writes it is sent.
    $protectGate = {
        if ($pg.On -and $pg.Protected -contains $Target) { Set-KnxTestSkip "target $Target powers the rig (protected) - not sent" }
    }

    # Before a restart or "gone" result: a relay that had to be switched back on voids it.
    $powerVoid = {
        if (-not $pg.On) { return }
        $g = Assert-KnxRigPower -Via $pg.Via -Port $port -WriteGa $pg.Write -StatusGa $pg.Status -DutPa $pg.DutPa
        Add-KnxEvidence -Note ("rig power: {0}" -f $g.Detail)
        if ($g.Restored -and $g.Ok) { Set-KnxTestSkip ("rig power was off (relays), restored after {0} s - result on {1} void" -f $g.Seconds, $Target) }
        if ($g.Restored) { Set-KnxTestSkip ("rig power was off (relays), switched on, device under test not back after {0} s - result on {1} void" -f $g.Seconds, $Target) }
    }

    # DeviceDescriptor_Read to the target via one interface, two attempts: 'answers'; 'silent' (layer-2 ack, no answer); 'blind'
    # (no tunnel or no positive L_Data.con: target absent or interface off the bus, not told apart here).
    $askTargetVia = {
        param([string]$ViaIp)
        $sx = Open-KnxDeviceSession -Ip $ViaIp -Port $port -Pa $Target
        if (-not $sx.Ok) { return 'blind' }
        $onBus = $false
        try {
            foreach ($attempt in 1, 2) {
                $q = Invoke-KnxDeviceService -Session $sx -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@(0x00)) `
                                             -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 2500 -Connectionless
                if ($null -ne $q.Response) { return 'answers' }
                if ($q.TunnelAcked -and $q.Confirmed -eq $true) { $onBus = $true }
            }
        }
        catch { }
        finally { Close-KnxDeviceSession -Session $sx }
        if ($onBus) { return 'silent' }
        return 'blind'
    }

    # Assert for "the target is gone". On a failure: rig power first (unless -Guarded), then the target once more via the
    # device under test, then via the traffic interface (the control interface only when traffic is blind).
    $goneResult = {
        param([bool]$Condition, [string]$Message, [bool]$Guarded = $false)
        if ($Condition) { Assert-KnxTrue $true $Message; return }
        if (-not $Guarded) { & $powerVoid }
        $viaDut = & $askTargetVia $ip
        Add-KnxEvidence -Note ("{0} through the device under test {1} now: {2}" -f $Target, $ip, $viaDut)
        if ($viaDut -ne 'answers') {
            $paths = @()
            if ($pg.TrafficIp -and $pg.TrafficIp -ne $ip) { $paths += @{ Ip = $pg.TrafficIp; Name = 'traffic interface' } }
            if ($pg.On -and $pg.Via -and $pg.Via -ne $ip -and $pg.Via -ne $pg.TrafficIp) { $paths += @{ Ip = $pg.Via; Name = 'control interface' } }
            foreach ($path in $paths) {
                $st = & $askTargetVia $path.Ip
                Add-KnxEvidence -Note ("{0} through the {1} {2}: {3}" -f $Target, $path.Name, $path.Ip, $st)
                if ($st -eq 'answers') {
                    # A target that came back during the check is the target's finding, not the window's.
                    $again = & $askTargetVia $ip
                    Add-KnxEvidence -Note ("{0} through the device under test {1} after that: {2}" -f $Target, $ip, $again)
                    if ($again -eq 'answers') { break }
                    Assert-KnxTrue $false "$Target answers through the $($path.Name); the device under test lost its bus access"
                }
                if ($st -ne 'blind') { break }
            }
        }
        Assert-KnxTrue $false $Message
    }

    # ── D-1 Identification ──────────────────────────────────────────────────────

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-1.1 $tag" -Title 'Device Descriptor Type 0 - the device identifies itself' `
                       -Clause '03_03_07 clause 3.4.2.1, p.48; 03_05_01 mask versions' -Body {
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # Three attempts, not one. This case gates EVERY other case for this device, so a single
            # missed acknowledge - a busy line, a tunnel slot just reaped, one lost datagram - used to
            # void the whole device run as "not on the bus". Measured: the device answered again on the
            # very next attempt. A device that is really absent stays silent through all three.
            $r = $null
            $attempts = 0
            while ($attempts -lt 3) {
                $attempts++
                $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@()) `
                                             -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 5000 -Connectionless
                if ($r.Confirmed -ne $false -and $null -ne $r.Response) { break }
                if ($attempts -lt 3) { [void](Wait-KnxTunnel -Connection $s.Conn -Ms 700) }
            }
            Add-KnxEvidence -Sent $r.Sent
            if ($null -ne $r.Response) { Add-KnxEvidence -Received $r.Response }
            if ($attempts -gt 1) { Add-KnxEvidence -Note ("answered on attempt {0} of 3" -f $attempts) }
            if ($r.Confirmed -eq $false) {
                $profile.Reason = "nothing on the bus acknowledged a telegram to $Target in $attempts attempts"
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
            # Slicing [0..1] on a one-octet answer throws under Set-StrictMode -Version Latest, which
            # would report "unhandled error" instead of the short answer the device actually gave.
            Assert-KnxTrue ($p.Data.Length -ge 2) "PID_DEVICE_DESCRIPTOR answered $($p.Data.Length) octet(s); the mask version needs two"
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
            # so it is E06 in every one of the three transition-table styles - the result
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
                # An ANSWER is individually addressed to us and carries an application PDU. Matching on
                # the source alone counted the device's own group telegrams - a sensor device sends them
                # constantly - as a reply to the reserved field, and reported a conformant device as
                # defective. Same defect as D-20.1 carried.
                if ($ld.Source -eq $s.Dst -and (Test-KnxAddressedToSession -Session $s -LData $ld) -and $ld.Tpdu.Length -ge 1 -and
                    (@('Numbered', 'Unnumbered', 'Disconnect', 'Ack', 'Nak') -contains (Get-KnxTpduKind -Tpdu $ld.Tpdu).Kind)) { $reply = $ld; break }
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
            & $goneResult ($null -ne $alive.Response) 'device stopped answering entirely after a reserved transport control field'

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
                if ($ld.Source -ne $s.Dst -or -not (Test-KnxAddressedToSession -Session $s -LData $ld)) { continue }
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
            # Reading instead of sleeping: a silent client loses its tunnel once the bus carries traffic
            # (03_08_04 2.6.1 p.9), and the case then reports the device for the window it closed itself.
            [void](Wait-KnxTunnel -Connection $s.Conn -Ms 800)
            # Drain whatever the device chose to answer - a T_ACK is acceptable here, the
            # transport layer received a syntactically valid numbered PDU. What must not
            # happen is a device that stops working.
            # Bounded: on a loaded bus the tunnel carries a group telegram more often than the
            # window is long, so "drain until empty" never ends, and while it runs the client
            # sends nothing of its own - which ends its tunnel at 120 s (03_08_02 5.4 p.14) and
            # reports the device for it.
            $drain = [System.Diagnostics.Stopwatch]::StartNew()
            while ($drain.ElapsedMilliseconds -lt 5000) {
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
            $anyDelivered = $false
            for ($try = 1; $try -le 4; $try++) {
                $probe = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@()) `
                                                 -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 5000 -Connectionless
                if ($null -ne $probe.Response) { $alive = $probe; break }
                # "The device is silent" and "the interface stopped taking our requests"
                # produce the same empty result and mean opposite things - one is a device
                # result, the other is the window failing. The TUNNELLING_ACK separates
                # them, so it is recorded instead of averaged into one word. .Disconnected is the
                # DEVICE's T_Disconnect, a device result - it says nothing about the tunnel.
                if ($probe.TunnelAcked) { $anyDelivered = $true }
                Add-KnxEvidence -Note ("attempt {0}: no answer after {1:N1} s (tunnel acknowledged our request: {2})" -f $try, $sw.Elapsed.TotalSeconds, $probe.TunnelAcked)
            }
            $sw.Stop()
            if ($null -eq $alive -and -not $anyDelivered) {
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
            # judged on its own without a session state to blame. The result is not about
            # the answer - it is about the device still being there afterwards.
            $len = if ($profile.MaxApdu -gt 0) { [Math]::Min(240, $profile.MaxApdu + 20) } else { 200 }
            $pad = New-Object byte[] $len
            for ($i = 0; $i -lt $len; $i++) { $pad[$i] = [byte](0x41 + ($i % 26)) }
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.PROPERTY_VALUE_READ -Data $pad -TimeoutMs 3000 -Connectionless
            Add-KnxEvidence -Sent $r.Sent -Note "sent an APDU of $($len + 2) octets against a declared maximum of $($profile.MaxApdu)"
            [void](Wait-KnxTunnel -Connection $s.Conn -Ms 500)

            $check = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@()) `
                                             -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 6000 -Connectionless
            if ($null -ne $check.Response) { Add-KnxEvidence -Received $check.Response }
            & $goneResult ($null -ne $check.Response) 'device no longer answers a device descriptor read after an oversized APDU'
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
                [void](Wait-KnxTunnel -Connection $s.Conn -Ms 120)
                $dc = Send-KnxDeviceTpdu -Session $s -Tpdu (New-TpduDisconnect) -TimeoutMs 2000
                Assert-KnxTrue $dc.Acked "the interface stopped accepting telegrams at cycle $($i + 1)"
                [void](Wait-KnxTunnel -Connection $s.Conn -Ms 120)
                # Bounded for the same reason as in D-4.1: on a loaded bus this never runs dry, and a
                # client that only acknowledges loses its tunnel at 120 s (03_08_02 5.4 p.14).
                $drain = [System.Diagnostics.Stopwatch]::StartNew()
                while ($drain.ElapsedMilliseconds -lt 2000) {
                    $in = Receive-KnxTunnelCemi -Connection $s.Conn -TimeoutMs 200
                    if ($null -eq $in) { break }
                }
            }
            Add-KnxEvidence -Note "$cycles connect/disconnect cycles completed"

            $s.SeqSend = 0
            $cn = Send-KnxDeviceTpdu -Session $s -Tpdu (New-TpduConnect) -TimeoutMs 2000
            Assert-KnxTrue $cn.Acked 'the interface did not accept the final T_Connect'
            $s.Connected = $true
            $after = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@()) `
                                             -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 6000
            Add-KnxEvidence -Note ("after {0} cycles: acked={1} answered={2}" -f $cycles, $after.Acked, ($null -ne $after.Response))
            & $goneResult $after.Acked "device no longer acknowledges a new connection after $cycles connect/disconnect cycles"
            & $goneResult ($null -ne $after.Response) "device no longer answers on a new connection after $cycles connect/disconnect cycles"
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
            # The helper only takes the answer from the target; an answer under any other source lands in
            # Strangers. That is the defect this case exists for, so it is checked before "no answer".
            $wrong = @($r.Strangers | Where-Object { $_.Tpdu.Length -ge 2 -and (Get-TpduApci -Tpdu $_.Tpdu) -eq $K.Apci.DEVICE_DESCRIPTOR_RESPONSE })
            if ($wrong.Count -gt 0) {
                Add-KnxEvidence -Received $wrong[0].Tpdu
                Assert-KnxTrue $false ("the answer to a read of {0} came from {1}" -f $Target, (ConvertFrom-KnxPa -Raw $wrong[0].Source))
            }
            Assert-KnxTrue ($null -ne $r.Response) "no answer from $Target"
            Add-KnxEvidence -Received $r.Response -Note ("answer came from {0}" -f (ConvertFrom-KnxPa -Raw $r.ResponseSource))
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
            # A target address that is not a three-part individual address is a rig input, not a
            # device finding - D-5.2 called it a FAIL and D-30.2 an N-A for the same condition.
            if (($Target -split '\.').Count -ne 3) { Set-KnxTestNotApplicable "cannot derive a neighbour address from $Target" }
            $free = & $freeAddressOn $s
            if (-not $free) { Set-KnxTestNotApplicable "found no provably free address on this line - $($profile.FreeAddressNote)" }
            Add-KnxEvidence -Note "$free is free (negative L_Data.con - nothing on the line acknowledged it)"

            $probe = & $probeOn $s $free
            $r = Invoke-KnxDeviceService -Session $probe -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@()) -TimeoutMs 3000 -Connectionless
            if ($null -ne $r.Response) { Add-KnxEvidence -Received $r.Response }
            Assert-KnxTrue ($null -eq $r.Response) "a device answered for $free, which nothing on the bus acknowledged - two devices disagree about who owns that address"
            $other = @($r.Strangers | Where-Object { $_.Tpdu.Length -ge 2 -and (Get-TpduApci -Tpdu $_.Tpdu) -eq $K.Apci.DEVICE_DESCRIPTOR_RESPONSE })
            if ($other.Count -gt 0) { Add-KnxEvidence -Received $other[0].Tpdu }
            Assert-KnxTrue ($other.Count -eq 0) ("{0} answered a read addressed to the free address {1}" -f $(if ($other.Count) { ConvertFrom-KnxPa -Raw $other[0].Source } else { '' }), $free)
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    # -- D-6 Extended property services (System B) --------------------------------
    #
    # Layout per 03_03_07: objectType(2) | objInstance+propertyId(3) | count(1) | startIndex(2), then
    # the data; the response mirrors that header and appends one return code octet.
    # NOT from this stack: it does not implement A_PropertyExtValue_* at all (knx_types.h carries only
    # the Ext DESCRIPTION and FunctionPropertyExt services), so against an OpenKNX device every case
    # below reports N-A. They exist for third-party System B devices that do serve them.

    $extHeader = {
        param([int]$ObjectType, [int]$ObjectInstance, [int]$PropertyId, [int]$Count, [int]$StartIndex)
        [byte[]]@(
            (($ObjectType -shr 8) -band 0xFF),
            ($ObjectType -band 0xFF),
            (($ObjectInstance -shr 4) -band 0xFF),
            ((($ObjectInstance -band 0x0F) -shl 4) -bor (($PropertyId -shr 8) -band 0x0F)),
            ($PropertyId -band 0xFF),
            ($Count -band 0xFF),
            (($StartIndex -shr 8) -band 0x0F),
            ($StartIndex -band 0xFF)
        )
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-6.1 $tag" -Title 'Extended property read returns what the classic read returns' `
                       -Clause '03_03_07 A_PropertyValue_ExtRead; AN118' -Body {
        & $propGate 'the extended property services'
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            $classic = Read-KnxDeviceProperty -Session $s -ObjectIndex 0 -PropertyId $K.Pid.SERIAL_NUMBER
            if (-not $classic.Ok) { Set-KnxTestSkip 'the classic read of PID_SERIAL_NUMBER gave nothing to compare against' }
            $payload = & $extHeader 0 1 $K.Pid.SERIAL_NUMBER 1 1
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.PROPERTY_EXT_VALUE_READ -Data $payload `
                                         -ExpectApci $K.Apci.PROPERTY_EXT_VALUE_RESPONSE -TimeoutMs 6000
            Add-KnxEvidence -Sent $payload
            if ($null -eq $r.Response) {
                Set-KnxTestNotApplicable 'device does not answer the extended property services (optional for System B)'
            }
            Add-KnxEvidence -Received $r.Response
            Assert-KnxTrue ($r.Response.Length -ge 11) 'extended property response is too short to carry a serial number'
            $extData = [byte[]]$r.Response[10..($r.Response.Length - 1)]
            Add-KnxEvidence -Note ("classic={0} extended={1}" -f (ConvertTo-HexString -Bytes $classic.Data), (ConvertTo-HexString -Bytes $extData))
            Assert-KnxEqual (ConvertTo-HexString -Bytes $classic.Data) (ConvertTo-HexString -Bytes $extData) 'the extended and the classic read of the same property disagree'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-6.2 $tag" -Title 'Extended write of a read-only property is not reported as success' `
                       -Clause '03_03_07 clause 3.4.4.2, p.66; return codes 03_05_01' -Body {
        & $propGate 'the extended property services'
        & $protectGate
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # The property's OWN current value is written back, never a made-up one. The first version
            # of this case sent zeroes on the assumption that a read-only property would refuse them -
            # a device accepted them and its serial number was gone. A test whose FAILURE damages the
            # device under test is a broken test, however correct its result is. Writing the value
            # that is already there is harmless whatever the device decides, and the question under
            # test is unchanged: a write that cannot have happened must not be confirmed as Success.
            $current = Read-KnxDeviceProperty -Session $s -ObjectIndex 0 -PropertyId $K.Pid.SERIAL_NUMBER
            if (-not $current.Ok -or $current.Data.Length -ne 6) { Set-KnxTestSkip 'could not read PID_SERIAL_NUMBER, so there is no safe value to write back' }
            $payload = (& $extHeader 0 1 $K.Pid.SERIAL_NUMBER 1 1) + $current.Data
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.PROPERTY_EXT_VALUE_WRITE_CON -Data ([byte[]]$payload) `
                                         -ExpectApci $K.Apci.PROPERTY_EXT_VALUE_WRITE_CON_RES -TimeoutMs 6000
            Add-KnxEvidence -Sent ([byte[]]$payload)
            if ($null -eq $r.Response) {
                Set-KnxTestNotApplicable 'device does not answer the extended property services (optional for System B)'
            }
            Add-KnxEvidence -Received $r.Response
            Assert-KnxTrue ($r.Response.Length -ge 11) 'extended write response carries no return code'
            $count = [int]$r.Response[7]
            $rc = [int]$r.Response[10]
            Add-KnxEvidence -Note ("nr_of_elem={0} return code=0x{1:X2}" -f $count, $rc)
            Assert-KnxTrue ($rc -ne 0x00) 'device answered Success (0x00) for a write to the read-only PID_SERIAL_NUMBER - it accepts writes to a property the specification marks read-only'
            Assert-KnxEqual 0 $count 'a refused write must report zero elements'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-6.3 $tag" -Title 'Extended write at element index 0 with non-zero data is refused' `
                       -Clause '03_03_07 clause 3.4.4.1, p.64 - index 0 carries the element count' -Body {
        # Gated although it is meant to be harmless: a CORRECT device refuses an index-0 write and
        # changes nothing, but this case exists precisely because not every device does. On a device
        # that mishandles it, the extended write reaches the property behind index 0 - PID_PROG_MODE here -
        # and would switch the device into programming mode. A test must not be able to do that
        # behind the operator's back.
        $allowWrite = $false
        if ($Ctx.PSObject.Properties['AllowDestructive']) { $allowWrite = [bool]$Ctx.AllowDestructive }
        if (-not $allowWrite) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'writes to element index 0 - needs -IncludeDestructive' }
        & $propGate 'the extended property services'
        & $protectGate
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # Element index 0 is the element count. The only defined write there is the reset to zero;
            # anything else must be refused. Non-zero data is used on purpose so the property is NOT
            # cleared whatever the device decides - this case must never change the device.
            $payload = (& $extHeader 0 1 $K.Pid.PROG_MODE 1 0) + [byte[]]@(0x01, 0x02)
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.PROPERTY_EXT_VALUE_WRITE_CON -Data ([byte[]]$payload) `
                                         -ExpectApci $K.Apci.PROPERTY_EXT_VALUE_WRITE_CON_RES -TimeoutMs 6000
            Add-KnxEvidence -Sent ([byte[]]$payload)
            if ($null -eq $r.Response) {
                Set-KnxTestNotApplicable 'device does not answer the extended property services (optional for System B)'
            }
            Add-KnxEvidence -Received $r.Response
            Assert-KnxTrue ($r.Response.Length -ge 11) 'extended write response carries no return code'
            $rc = [int]$r.Response[10]
            Add-KnxEvidence -Note ("return code=0x{0:X2}" -f $rc)
            Assert-KnxTrue ($rc -ne 0x00) 'device reported Success for a write to element index 0 that it cannot have performed'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    # -- D-7 Extended memory services ---------------------------------------------

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-7.1 $tag" -Title 'Extended memory read beyond the APDU limit is refused, not silently shortened' `
                       -Clause '03_03_07 A_MemoryExtended_Read; max APDU 03_05_01 PID_MAX_APDULENGTH' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # 255 octets cannot fit any APDU. A device that answers Success with a SHORTER block has
            # told the client "here are 255 octets from that address" while sending fewer - the client
            # then reads past what it got. Refusing is the only correct answer.
            $payload = [byte[]]@(0xFF, 0x00, 0x00, 0x00)
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.MEMORY_EXT_READ -Data $payload `
                                         -ExpectApci $K.Apci.MEMORY_EXT_READ_RESPONSE -TimeoutMs 6000
            Add-KnxEvidence -Sent $payload
            if ($null -eq $r.Response) {
                Set-KnxTestNotApplicable 'device does not answer the extended memory services (optional for System B)'
            }
            Add-KnxEvidence -Received $r.Response
            # The shortest legal response carries the return code; a shorter one is malformed and must be
            # reported as that, not as an index error out of the case.
            Assert-KnxTrue ($r.Response.Length -ge 3) "the extended memory response is $($r.Response.Length) octets, too short to carry a return code"
            $rc = [int]$r.Response[2]
            $octets = [Math]::Max(0, $r.Response.Length - 6)
            Add-KnxEvidence -Note ("return code=0x{0:X2}, {1} data octet(s)" -f $rc, $octets)
            if ($rc -eq 0x00) {
                Assert-KnxEqual 255 $octets 'device reported Success for a 255-octet read but returned fewer octets'
            }
            else {
                # The refusal is the expected answer here, and it is the only path this stack takes -
                # leaving it unasserted meant the case reported PASS having judged nothing at all.
                # 03_03_07 Table 3 p.99-100 defines the read return codes: 00h success, and the negatives
                # F1h, F4h, F9h, FAh, FCh, FDh, FFh. The ranges 01h-1Fh, 20h-5Fh and A0h-DFh are listed
                # as "None proposed". The earlier list had it backwards - it accepted the undefined
                # ranges and rejected five codes the clause defines - and cited the wrong table.
                $known = @(0xF1, 0xF4, 0xF9, 0xFA, 0xFC, 0xFD, 0xFF)
                Assert-KnxTrue ($known -contains $rc) ("device refused the over-long read with 0x{0:X2}, which is not a defined return code" -f $rc)
                Assert-KnxEqual 0 $octets 'device refused the read and still returned data octets'
            }
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    # -- D-8 Classic property write semantics --------------------------------------

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-8.1 $tag" -Title 'Property write at element index 0 with non-zero data is refused' `
                       -Clause '03_03_07 clause 3.4.4.1, p.64; clause 3.4.4.2, p.65' -Body {
        # Gated although it is meant to be harmless: a CORRECT device refuses an index-0 write and
        # changes nothing, but this case exists precisely because not every device does. On a device
        # that mishandles it, the classic write reaches the property behind index 0 - PID_PROG_MODE here -
        # and would switch the device into programming mode. A test must not be able to do that
        # behind the operator's back.
        $allowWrite = $false
        if ($Ctx.PSObject.Properties['AllowDestructive']) { $allowWrite = [bool]$Ctx.AllowDestructive }
        if (-not $allowWrite) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'writes to element index 0 - needs -IncludeDestructive' }
        & $propGate 'the property services'
        & $protectGate
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # Same reasoning as D-6.3 on the classic service, and equally non-destructive: index 0
            # with non-zero data is not the defined reset, so a correct device changes nothing and
            # answers with nr_of_elem = 0.
            $payload = [byte[]]@(0x00, $K.Pid.PROG_MODE, 0x10, 0x00, 0x01, 0x02)
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.PROPERTY_VALUE_WRITE -Data $payload `
                                         -ExpectApci $K.Apci.PROPERTY_VALUE_RESPONSE -TimeoutMs 6000
            Add-KnxEvidence -Sent $payload
            Assert-KnxTrue ($null -ne $r.Response) 'device stayed silent on a property write instead of answering'
            Add-KnxEvidence -Received $r.Response
            Assert-KnxTrue ($r.Response.Length -ge 5) "the property response is $($r.Response.Length) octets, too short to carry nr_of_elem"
            $count = (([int]$r.Response[4]) -shr 4) -band 0x0F
            Add-KnxEvidence -Note ("nr_of_elem={0}" -f $count)
            Assert-KnxEqual 0 $count 'device confirmed a write to element index 0 that it cannot have performed'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    # -- D-9 User services ----------------------------------------------------------

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-9.1 $tag" -Title 'A_UserManufacturerInfo_Read is answered with its own response service' `
                       -Clause '03_03_07 A_UserManufacturerInfo_Read/Response' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # The service is optional, so silence is allowed. What is not allowed is an answer that
            # carries a DIFFERENT service code - a client matching on the response APCI then either
            # drops it or, worse, decodes it as the service the code names.
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.USER_MANUFACTURER_INFO_READ -Data ([byte[]]@()) `
                                         -ExpectApci $K.Apci.USER_MANUFACTURER_INFO_RESPONSE -TimeoutMs 4000
            if ($null -eq $r.Response) {
                # Nothing came back at all, or something came back that was not the expected service.
                $other = @($r.Frames | Where-Object { $null -ne $_ })
                Add-KnxEvidence -Note ("no A_UserManufacturerInfo_Response; {0} other frame(s) seen" -f $other.Count)
                Set-KnxTestNotApplicable 'device does not answer A_UserManufacturerInfo_Read (the service is optional)'
            }
            Add-KnxEvidence -Received $r.Response
            Assert-KnxTrue ($r.Response.Length -ge 5) 'A_UserManufacturerInfo_Response is shorter than its three data octets'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    # -- G Guided: steps that need a hand at the device or ETS ----------------------

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "G-1.1 $tag" -Title 'Programming mode makes the device answer the broadcast address read' `
                       -Clause '03_05_02 clause 2.2 NM_IndividualAddress_Read, p.12 (only devices in programming mode answer)' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        # Programming mode is set over the bus, the way ETS sets it - no hand at the device. Only a
        # device that REFUSES the write still needs a human, and then the case says so instead of
        # quietly not running: it used to be NOT-RUN on every unattended run.
        & $protectGate
        $entered = Set-KnxDeviceProgMode -Target $Target -On $true -Ip $ip -Port $port
        if ($entered) {
            Add-KnxEvidence -Note "programming mode could not be set over the bus: $entered"
            $guided = $false
            if ($Ctx.PSObject.Properties['Guided']) { $guided = [bool]$Ctx.Guided }
            [void](Request-KnxOperatorAction -Guided:$guided `
                   -Instruction "Programmiertaste an $Target druecken, LED muss leuchten" `
                   -Detail 'Das Geraet nimmt den Schreibzugriff auf PID_PROG_MODE nicht an, also von Hand.')
        }
        else {
            Add-KnxEvidence -Note 'programming mode set over the bus (PID_PROG_MODE), confirmed by reading it back'
        }

        $answered = $false
        $progOff = $false
        $progNote = 'the switch-off never ran'
        try {
            # A property read needs a transport connection; unconnected it goes out numbered and is not answered.
            $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
            if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
            try {
                $prog = Read-KnxDeviceProperty -Session $s -ObjectIndex 0 -PropertyId $K.Pid.PROG_MODE
                Assert-KnxTrue ($prog.Ok -and $prog.Data.Length -ge 1) 'PID_PROG_MODE is not readable'
                Add-KnxEvidence -Note ("PID_PROG_MODE reads 0x{0:X2}" -f $prog.Data[0])
                Assert-KnxTrue (($prog.Data[0] -band 0x01) -eq 1) 'the device does not report programming mode although the button was pressed'
            }
            finally { Close-KnxDeviceSession -Session $s }

            $b = Open-KnxDeviceSession -Ip $ip -Port $port -Pa '0.0.0'
            if (-not $b.Ok) { Set-KnxTestSkip $b.Reason }
            try {
                $r = Invoke-KnxDeviceService -Session $b -Apci $K.Apci.INDIVIDUAL_ADDR_READ -Data ([byte[]]@()) `
                                             -ExpectApci $K.Apci.INDIVIDUAL_ADDR_RESPONSE -TimeoutMs 3000 -Connectionless `
                                             -ExpectSource (ConvertTo-KnxPa -Address $Target)
                foreach ($o in $r.Others) { Add-KnxEvidence -Note ("{0} is in programming mode too" -f (ConvertFrom-KnxPa -Raw $o.Source)) }
                $answered = ($null -ne $r.Response)
                if ($answered) { Add-KnxEvidence -Received $r.Response }
            }
            finally { Close-KnxDeviceSession -Session $b }
        }
        finally {
            # Programming mode off again on EVERY exit, so D-13.2 and D-21.3 do not meet a device in
            # programming mode. A failed assertion or a skip above left it on when this was straight-line code.
            # Everything here is caught: an exception thrown from a finally REPLACES the result the body
            # was carrying, so a socket that dies while switching the mode back would hide the real result.
            try {
                $back = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
                if ($back.Ok) {
                    try {
                        [void](Invoke-KnxDeviceService -Session $back -Apci $K.Apci.PROPERTY_VALUE_WRITE `
                                                       -Data ([byte[]]@(0x00, $K.Pid.PROG_MODE, 0x10, 0x01, 0x00)) `
                                                       -ExpectApci $K.Apci.PROPERTY_VALUE_RESPONSE -TimeoutMs 3000)
                        $off = Read-KnxDeviceProperty -Session $back -ObjectIndex 0 -PropertyId $K.Pid.PROG_MODE
                        if ($off.Ok -and $off.Data.Length -ge 1) {
                            $progOff = (([int]$off.Data[0] -band 0x01) -eq 0)
                            $progNote = "PID_PROG_MODE reads 0x{0:X2} after switching it off" -f $off.Data[0]
                        }
                        else { $progNote = 'PID_PROG_MODE could not be read back after switching it off' }
                        Add-KnxEvidence -Note $progNote
                    }
                    finally { Close-KnxDeviceSession -Session $back }
                }
                else { $progNote = "no session to switch programming mode off: $($back.Reason)" }
            }
            catch { $progNote = "switching programming mode off threw: $($_.Exception.Message)" }
        }
        # Outside the finally: an assertion thrown from inside it would replace the case's own result.
        # A device left in programming mode answers every broadcast address read for the rest of the run
        # and makes D-13.2 meaningless, so this is a result to assert, not a note to file.
        Assert-KnxTrue $answered "$Target is in programming mode but did not answer the broadcast address read"
        Assert-KnxTrue $progOff "programming mode was NOT switched off again - $progNote. $Target is left in programming mode"
    }

    # -- D-10 Memory services -------------------------------------------------------

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-10.1 $tag" -Title 'Memory read echoes the address it was asked for' `
                       -Clause '03_03_07 A_Memory_Read/Response, count in the APCI octet' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # The octet count rides in the low six bits of the APCI octet, so it is part of the
            # service code and not of the payload.
            $r = Invoke-KnxDeviceService -Session $s -Apci ($K.Apci.MEMORY_READ -bor 1) -Data ([byte[]]@(0x00, 0x00)) `
                                         -ExpectApci $K.Apci.MEMORY_RESPONSE -TimeoutMs 6000
            if ($null -eq $r.Response) { Set-KnxTestNotApplicable 'device does not answer A_Memory_Read at address 0 (optional on System B)' }
            Add-KnxEvidence -Received $r.Response
            Assert-KnxTrue ($r.Response.Length -ge 4) 'A_Memory_Response carries no address'
            $addr = (([int]$r.Response[2]) -shl 8) -bor [int]$r.Response[3]
            Add-KnxEvidence -Note ("address echoed: 0x{0:X4}" -f $addr)
            Assert-KnxEqual 0 $addr 'the response does not echo the address that was read'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-10.2 $tag" -Title 'User memory read is answered or ignored, never mis-answered' `
                       -Clause '03_03_07 A_UserMemory_Read/Response' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.USER_MEMORY_READ -Data ([byte[]]@(0x01, 0x00, 0x00)) `
                                         -ExpectApci $K.Apci.USER_MEMORY_RESPONSE -TimeoutMs 4000
            if ($null -eq $r.Response) { Set-KnxTestNotApplicable 'device does not answer A_UserMemory_Read (optional)' }
            Add-KnxEvidence -Received $r.Response
            Assert-KnxTrue ($r.Response.Length -ge 5) 'A_UserMemory_Response is shorter than its address field'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    # -- D-11 Property descriptions -------------------------------------------------

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-11.1 $tag" -Title 'Property description reports type and element count' `
                       -Clause '03_03_07 clause 3.4.3.3, A_PropertyDescription_Read' -Body {
        & $propGate 'the property description service'
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.PROPERTY_DESCRIPTION_READ `
                                         -Data ([byte[]]@(0x00, $K.Pid.SERIAL_NUMBER, 0x00)) `
                                         -ExpectApci $K.Apci.PROPERTY_DESCRIPTION_RESPONSE -TimeoutMs 6000
            Assert-KnxTrue ($null -ne $r.Response) 'device stayed silent on A_PropertyDescription_Read'
            Add-KnxEvidence -Received $r.Response
            Assert-KnxTrue ($r.Response.Length -ge 9) 'property description response is too short'
            $propId = [int]$r.Response[3]
            $type = [int]$r.Response[5]
            $max = (([int]$r.Response[6]) -shl 8) -bor [int]$r.Response[7]
            Add-KnxEvidence -Note ("pid={0} type=0x{1:X2} max_nr_of_elem={2} access=0x{3:X2}" -f $propId, $type, $max, [int]$r.Response[8])
            Assert-KnxEqual $K.Pid.SERIAL_NUMBER $propId 'the description does not describe the property that was asked for'
            Assert-KnxTrue ($max -ge 1) 'a property that exists must report at least one element'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-11.2 $tag" -Title 'Extended and classic property description agree' `
                       -Clause '03_03_07 Figure 43 p.56, Figure 45 p.60; AN118' -Body {
        & $propGate 'the property description service'
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            $classic = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.PROPERTY_DESCRIPTION_READ `
                                               -Data ([byte[]]@(0x00, $K.Pid.SERIAL_NUMBER, 0x00)) `
                                               -ExpectApci $K.Apci.PROPERTY_DESCRIPTION_RESPONSE -TimeoutMs 6000
            if ($null -eq $classic.Response -or $classic.Response.Length -lt 9) { Set-KnxTestSkip 'no classic description to compare against' }
            # Figure 43 p.56, from octet 6: octet 11 write_enable|r|type, octets 12-13 4 reserved bits + max_nr_of_elem, octet 14 access.
            $cWrite = ([int]$classic.Response[5] -band 0x80) -ne 0
            $cType  = [int]$classic.Response[5] -band 0x3F
            $cMax   = ((([int]$classic.Response[6]) -shl 8) -bor [int]$classic.Response[7]) -band 0x0FFF
            $cAcc   = [int]$classic.Response[8]

            # objType(2) | objInstance+propertyId(3) | descriptionType+propertyIndex(2) = 7 octets, not the VALUE header.
            # The instance is 1: instances start with 1 (03_04_01 p.12).
            $payload = [byte[]]@(0x00, 0x00, 0x00, 0x10, $K.Pid.SERIAL_NUMBER, 0x00, 0x00)
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.PROPERTY_EXT_DESCRIPTION_READ -Data ([byte[]]$payload) `
                                         -ExpectApci $K.Apci.PROPERTY_EXT_DESCRIPTION_RESPONSE -TimeoutMs 6000
            if ($null -eq $r.Response) { Set-KnxTestNotApplicable 'device does not answer the extended description service (optional)' }
            Add-KnxEvidence -Received $r.Response
            Assert-KnxTrue ($r.Response.Length -ge 17) ("the extended description response has {0} octets, Figure 45 p.60 needs 17 from the APCI on" -f $r.Response.Length)
            # Figure 45 p.60, from octet 6: octets 8-9 object type, 10-12 instance + property_id,
            # octet 19 writeable|r|PDT, octets 20-21 max_nr_of_elem, octet 22 access.
            $eObj = (([int]$r.Response[2]) -shl 8) -bor [int]$r.Response[3]
            $ePid = ((([int]$r.Response[5]) -band 0x0F) -shl 8) -bor [int]$r.Response[6]
            Assert-KnxEqual 0 $eObj 'the extended description response names another object type'
            Assert-KnxEqual ([int]$K.Pid.SERIAL_NUMBER) $ePid 'the extended description response names another property'
            $eWrite = ([int]$r.Response[13] -band 0x80) -ne 0
            $eType  = [int]$r.Response[13] -band 0x3F
            $eMax   = ((([int]$r.Response[14]) -shl 8) -bor [int]$r.Response[15]) -band 0x0FFF
            $eAcc   = [int]$r.Response[16]
            Add-KnxEvidence -Note ("classic: write={0} PDT=0x{1:X2} max={2} access=0x{3:X2}; extended: write={4} PDT=0x{5:X2} max={6} access=0x{7:X2}" -f $cWrite, $cType, $cMax, $cAcc, $eWrite, $eType, $eMax, $eAcc)
            Assert-KnxEqual $cWrite $eWrite 'classic and extended description disagree on write_enable'
            Assert-KnxEqual $cType $eType 'classic and extended description disagree on the property datatype'
            Assert-KnxEqual $cMax $eMax 'classic and extended description disagree on max_nr_of_elem'
            Assert-KnxEqual $cAcc $eAcc 'classic and extended description disagree on the access levels'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    # -- D-12 Function properties ---------------------------------------------------

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-12.1 $tag" -Title 'Function property state of a property that is not a function carries no return code' `
                       -Clause '03_03_07 A_FunctionPropertyState_Read/Response; error handling 3.4.7.3 p.88' -Body {
        & $propGate 'the function property services'
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # Object 0, PID 1 (PID_OBJECT_TYPE): PDT_UNSIGNED_INT, "always mandatory" (03_05_01 4.2.1), so not PDT_Function.
            # PID 254 is not usable here: 201-255 are manufacturer specific (03_07_03 p.11) and may be a function.
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.FUNCTION_PROPERTY_STATE -Data ([byte[]]@(0x00, 0x01, 0x00)) `
                                         -ExpectApci $K.Apci.FUNCTION_PROPERTY_STATE_RESPONSE -TimeoutMs 4000
            if ($null -eq $r.Response) {
                # Silence here is the device saying it does not serve the function property services,
                # which is allowed - so there is nothing to judge, and the case says so instead of
                # returning early and reporting a result it never earned.
                Add-KnxEvidence -Note ("no answer; the device acknowledged the request at the transport layer: {0}" -f $r.Acked)
                Set-KnxTestNotApplicable 'device does not answer A_FunctionPropertyState_Read (optional)'
            }
            Add-KnxEvidence -Received $r.Response
            # 03_03_07 3.4.7.3 p.88: a property that is not PDT_Function is answered WITHOUT return_code and
            # WITHOUT data, i.e. APCI, object_index and property_id only (Figure 61 p.86: return_code would be
            # octet 10, TPDU index 4).
            Assert-KnxTrue ($r.Response.Length -ge 4) 'function property state response is too short to carry object_index and property_id'
            Assert-KnxBytes ([byte[]]@(0x00, 0x01)) ([byte[]]$r.Response[2..3]) 'the response names a different object or property than the request'
            if ($r.Response.Length -gt 4) { Add-KnxEvidence -Note ("return code=0x{0:X2}" -f [int]$r.Response[4]) }
            Assert-KnxEqual 4 $r.Response.Length '03_03_07 3.4.7.3 p.88: the answer for a property that is not PDT_Function carries neither return_code nor data'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    # -- D-13 Broadcast and serial number services ----------------------------------

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-13.1 $tag" -Title 'Address read by serial number answers only for its own serial' `
                       -Clause '03_03_07 A_IndividualAddress_SerialNumber_Read, Figure 13 p.22' -Body {
        & $propGate 'the serial number services'
        $serial = & $serialOf
        if ($null -eq $serial) { Set-KnxTestSkip 'could not read the serial number to address the device with' }

        # Broadcast, connectionless: this service is answered by the ONE device that owns the serial.
        $targetRaw = ConvertTo-KnxPa -Address $Target
        $b = Open-KnxDeviceSession -Ip $ip -Port $port -Pa '0.0.0'
        if (-not $b.Ok) { Set-KnxTestSkip $b.Reason }
        try {
            # Only the target's answer is judged here; another device answering is recorded, not blamed on it.
            $r = Invoke-KnxDeviceService -Session $b -Apci $K.Apci.IND_ADDR_SERIAL_READ -Data $serial `
                                         -ExpectApci $K.Apci.IND_ADDR_SERIAL_RESPONSE -TimeoutMs 5000 -Connectionless -ExpectSource $targetRaw
            Add-KnxEvidence -Sent $serial
            foreach ($o in $r.Others) { Add-KnxEvidence -Note ("also answered by {0}: {1}" -f (ConvertFrom-KnxPa -Raw $o.Source), (ConvertTo-HexString -Bytes $o.Tpdu)) }
            if ($null -eq $r.Response) { Set-KnxTestNotApplicable 'device does not answer the serial number address read (optional)' }
            Add-KnxEvidence -Received $r.Response
            # 03_03_07 Figure 13 p.22 and the expected frame in 08_03_07 2.17.3 p.71: TPCI/APCI, APCI, serial (6),
            # domain address (2), reserved (2) = 12 TPDU octets.
            Add-KnxEvidence -Note ("{0} octet(s) in the response" -f $r.Response.Length)
            Assert-KnxTrue ($r.Response.Length -ge 12) 'the response is shorter than serial number, domain address and reserved field'
            Assert-KnxEqual (ConvertTo-HexString -Bytes $serial) (ConvertTo-HexString -Bytes ([byte[]]$r.Response[2..7])) 'the response echoes a different serial number'
        }
        finally { Close-KnxDeviceSession -Session $b }

        # A fresh session, so an answer left over from the read above cannot be taken for this one.
        $b2 = Open-KnxDeviceSession -Ip $ip -Port $port -Pa '0.0.0'
        if (-not $b2.Ok) { Set-KnxTestSkip $b2.Reason }
        try {
            $foreign = [byte[]]@(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE)
            $r2 = Invoke-KnxDeviceService -Session $b2 -Apci $K.Apci.IND_ADDR_SERIAL_READ -Data $foreign `
                                          -ExpectApci $K.Apci.IND_ADDR_SERIAL_RESPONSE -TimeoutMs 3000 -Connectionless -ExpectSource $targetRaw
            foreach ($o in $r2.Others) { Add-KnxEvidence -Note ("another device answered the foreign serial: {0}" -f (ConvertFrom-KnxPa -Raw $o.Source)) }
            if ($null -ne $r2.Response) { Add-KnxEvidence -Received $r2.Response }
            Assert-KnxTrue ($null -eq $r2.Response) "$Target answered a serial number read for a serial number that is not its own"
        }
        finally { Close-KnxDeviceSession -Session $b2 }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-13.2 $tag" -Title 'Address read on broadcast stays silent outside programming mode' `
                       -Clause '03_05_02 clause 2.2 NM_IndividualAddress_Read, p.12; A_IndividualAddress_Read' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $b = Open-KnxDeviceSession -Ip $ip -Port $port -Pa '0.0.0'
        if (-not $b.Ok) { Set-KnxTestSkip $b.Reason }
        $answered = $false
        try {
            # Only a device in programming mode may answer this. The answer carries the answering device's
            # address, so the target's own answer is judged and another device's is reported as a line finding.
            $r = Invoke-KnxDeviceService -Session $b -Apci $K.Apci.INDIVIDUAL_ADDR_READ -Data ([byte[]]@()) `
                                         -ExpectApci $K.Apci.INDIVIDUAL_ADDR_RESPONSE -TimeoutMs 3000 -Connectionless `
                                         -ExpectSource (ConvertTo-KnxPa -Address $Target)
            foreach ($o in $r.Others) { Add-KnxEvidence -Note ("{0} is in programming mode" -f (ConvertFrom-KnxPa -Raw $o.Source)) }
            $answered = ($null -ne $r.Response)
            if ($answered) { Add-KnxEvidence -Received $r.Response }
            else {
                # Silence counts only once the stimulus is known to have gone out and the device is
                # known to be answering. Asked while the broadcast tunnel is still open, so the gate
                # rides on it instead of taking a channel of its own.
                if (-not $r.TunnelAcked) {
                    Set-KnxTestSkip 'the interface did not accept the broadcast address read, so nothing was asked - this says nothing about the device'
                }
                & $liveGate 'the silence on the broadcast address read' $b
            }
        }
        finally { Close-KnxDeviceSession -Session $b }

        if ($answered) {
            # An answer is correct if the target IS in programming mode; ask the device itself.
            $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
            if (-not $s.Ok) { Set-KnxTestSkip "$Target answered, and its programming mode could not be read: $($s.Reason)" }
            try { $prog = Read-KnxDeviceProperty -Session $s -ObjectIndex 0 -PropertyId $K.Pid.PROG_MODE }
            finally { Close-KnxDeviceSession -Session $s }
            if (-not $prog.Ok -or $prog.Data.Length -lt 1) { Set-KnxTestSkip "$Target answered, and PID_PROG_MODE is not readable" }
            Add-KnxEvidence -Note ("PID_PROG_MODE of {0} reads 0x{1:X2}" -f $Target, $prog.Data[0])
            if (($prog.Data[0] -band 0x01) -eq 1) { Set-KnxTestSkip "$Target is in programming mode - its answer is correct, the case needs it out of programming mode" }
        }
        else { Add-KnxEvidence -Note "no answer from $Target, as required outside programming mode" }
        Assert-KnxTrue (-not $answered) "$Target answered a broadcast address read although it is not in programming mode"
    }

    # -- D-14 System network parameter ----------------------------------------------

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-14.1 $tag" -Title 'System network parameter read is answered or ignored consistently' `
                       -Clause '03_03_07 clause 3.3.8, A_SystemNetworkParameter_Read' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $b = Open-KnxDeviceSession -Ip $ip -Port $port -Pa '0.0.0'
        if (-not $b.Ok) { Set-KnxTestSkip $b.Reason }
        try {
            # object type 0 (device), PID 1, one operand octet - the shortest well-formed request.
            # The four octets after the APCI are the parameter type: object_type (2) and the PID in
            # bits 15..4 of the next word, which is why PID 1 is sent as 0010h.
            $ask = [byte[]]@(0x00, 0x00, 0x00, 0x10, 0x00)
            $r = Invoke-KnxDeviceService -Session $b -Apci $K.Apci.SYSTEM_NETWORK_PARAM_READ `
                                         -Data $ask `
                                         -ExpectApci $K.Apci.SYSTEM_NETWORK_PARAM_RESPONSE -TimeoutMs 3000 -Connectionless `
                                         -ExpectSource (ConvertTo-KnxPa -Address $Target)
            foreach ($o in $r.Others) { Add-KnxEvidence -Note ("answered by {0}, not the device under test" -f (ConvertFrom-KnxPa -Raw $o.Source)) }
            if ($null -eq $r.Response) {
                Set-KnxTestNotApplicable 'device does not answer A_SystemNetworkParameter_Read (optional)'
            }
            Add-KnxEvidence -Received $r.Response
            # "Consistently" is what the title claims and what was never checked: the answer has to be
            # about the parameter that was asked about. The response mirrors the request's parameter
            # type in the same four octets, so this is an echo comparison and needs no reading of the
            # PID packing. An answer about a different object type or PID is a wrong answer, not silence.
            Assert-KnxTrue ($r.Response.Length -ge 6) 'the response is too short to carry the parameter type it answers about'
            Add-KnxEvidence -Note ("asked {0}, answered {1}" -f (ConvertTo-HexString -Bytes ([byte[]]$ask[0..3])), (ConvertTo-HexString -Bytes ([byte[]]$r.Response[2..5])))
            Assert-KnxBytes ([byte[]]$ask[0..3]) ([byte[]]$r.Response[2..5]) 'the response names a different object type or property than the request'
        }
        finally { Close-KnxDeviceSession -Session $b }
    }

    # -- D-15 Access control --------------------------------------------------------

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-15.1 $tag" -Title 'Authorize request returns an access level' `
                       -Clause '03_03_07 A_Authorize_Request/Response' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # reserved octet + a four octet key of zeroes, which is what ETS sends when no key is set.
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.AUTHORIZE_REQUEST -Data ([byte[]]@(0x00, 0x00, 0x00, 0x00, 0x00)) `
                                         -ExpectApci $K.Apci.AUTHORIZE_RESPONSE -TimeoutMs 4000
            if ($null -eq $r.Response) { Set-KnxTestNotApplicable 'device does not answer A_Authorize_Request (optional)' }
            Add-KnxEvidence -Received $r.Response
            Assert-KnxTrue ($r.Response.Length -ge 3) 'A_Authorize_Response carries no access level'
            Add-KnxEvidence -Note ("access level {0}" -f [int]$r.Response[2])
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    # -- D-16 ADC -------------------------------------------------------------------

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-16.1 $tag" -Title 'ADC read is answered or ignored, never mis-answered' `
                       -Clause '03_03_07 A_ADC_Read/Response' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # channel 1 in the APCI octet, one conversion.
            $r = Invoke-KnxDeviceService -Session $s -Apci ($K.Apci.ADC_READ -bor 1) -Data ([byte[]]@(0x01)) `
                                         -ExpectApci $K.Apci.ADC_RESPONSE -TimeoutMs 4000
            if ($null -eq $r.Response) { Set-KnxTestNotApplicable 'device does not answer A_ADC_Read (optional)' }
            Add-KnxEvidence -Received $r.Response
            Assert-KnxTrue ($r.Response.Length -ge 5) 'A_ADC_Response is shorter than channel, count and value'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    # -- D-17 Restart and master reset (changes the device) -------------------------

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-17.1 $tag" -Title 'Master reset with a reserved erase code is refused, not carried out' `
                       -Clause '03_05_02 clause 3.7.2, p.88, Table 4 p.83' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $allow = $false
        if ($Ctx.PSObject.Properties['AllowDestructive']) { $allow = [bool]$Ctx.AllowDestructive }
        if (-not $allow) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'sends a master reset request - needs -IncludeDestructive' }
        & $protectGate
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # Erase code 00h is reserved (Table 4 p.83). A conformant device answers error 02h and
            # does NOT reset. That is why this case is safe on a correct device and gated anyway.
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.RESTART_MASTER_RESET -Data ([byte[]]@(0x00, 0x00)) `
                                         -ExpectApci $K.Apci.RESTART_RESPONSE -TimeoutMs 6000
            & $powerVoid
            if ($null -eq $r.Response) { Set-KnxTestNotApplicable 'device does not answer A_Restart with a response (master reset optional)' }
            Add-KnxEvidence -Received $r.Response
            Assert-KnxTrue ($r.Response.Length -ge 3) 'A_Restart_Response carries no error code'
            # TPDU: [tpci|apci_hi][apci_lo][error code][process time hi][process time lo]
            $err = [int]$r.Response[2]
            Add-KnxEvidence -Note ("error code 0x{0:X2}" -f $err)
            Assert-KnxTrue ($err -ne 0x00) 'device accepted a reserved erase code'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-17.2 $tag" -Title 'A reserved erase code answers "unsupported erase code", not "invalid channel"' `
                       -Clause '03_05_02 Table 4 p.82-83 (reserved code: channel not defined -> 02h); Table 5 p.83-84' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $allow = $false
        if ($Ctx.PSObject.Properties['AllowDestructive']) { $allow = [bool]$Ctx.AllowDestructive }
        if (-not $allow) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'sends a master reset request - needs -IncludeDestructive' }
        & $protectGate
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # Erase code 00h is reserved (Void), so its channel is "not defined" (Table 4 p.82-83) and the
            # answer must be 02h "unsupported erase code" whatever the channel carries. A non-zero channel
            # here separates the two error codes: checking the channel first wrongly answers 03h. The reset
            # is refused either way, so nothing changes on the device.
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.RESTART_MASTER_RESET -Data ([byte[]]@(0x00, 0x05)) `
                                         -ExpectApci $K.Apci.RESTART_RESPONSE -TimeoutMs 6000
            & $powerVoid
            if ($null -eq $r.Response) { Set-KnxTestNotApplicable 'device does not answer A_Restart with a response (master reset optional)' }
            Add-KnxEvidence -Received $r.Response
            Assert-KnxTrue ($r.Response.Length -ge 3) 'A_Restart_Response carries no error code'
            $err = [int]$r.Response[2]
            Add-KnxEvidence -Note ("error code 0x{0:X2} (expected 0x02, not 0x03)" -f $err)
            Assert-KnxTrue ($err -ne 0x00) 'device accepted a reserved erase code with a non-zero channel'
            Assert-KnxEqual 0x02 $err 'reserved erase code answered invalid-channel (03h) instead of unsupported-erase-code (02h) - the channel was checked before the erase code'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-17.3 $tag" -Title 'Confirmed restart with a channel other than 00h answers "invalid channel" and does not restart' `
                       -Clause '03_05_02 Table 4 p.82 (01h: channel fixed 00h); clause 3.7.3 p.88, exceptions p.90; Table 5 p.84' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $allow = $false
        if ($Ctx.PSObject.Properties['AllowDestructive']) { $allow = [bool]$Ctx.AllowDestructive }
        if (-not $allow) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'a device without the channel check carries this out as a restart - needs -IncludeDestructive' }
        & $protectGate
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # Erase code 01h (confirmed restart) fixes the channel to 00h, so channel 05h makes the request
            # invalid on every device, with channels or without: the answer is 03h and nothing restarts.
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.RESTART_MASTER_RESET -Data ([byte[]]@(0x01, 0x05)) `
                                         -ExpectApci $K.Apci.RESTART_RESPONSE -TimeoutMs 6000
            if ($null -eq $r.Response) { Set-KnxTestNotApplicable 'device does not answer A_Restart with a response (master reset optional)' }
            Add-KnxEvidence -Received $r.Response
            Assert-KnxTrue ($r.Response.Length -ge 3) 'A_Restart_Response carries no error code'
            $err = [int]$r.Response[2]
            # p.88 priority (3): an erase code the device does not support is answered 02h before the channel
            # is looked at; such a device has nothing to say about the channel rule.
            if ($err -eq 0x02) { Set-KnxTestNotApplicable 'device answers 02h: it does not support erase code 01h (confirmed restart)' }
            # Access Denied comes before the erase code and the channel (p.90): a protected master reset says 01h.
            if ($err -eq 0x01) { Set-KnxTestNotApplicable 'device answers 01h: the master reset is protected by an access level' }
            # A restart drops the transport connection, so a numbered request on the same one tells - once
            # right away and once after the restart would have run.
            $probe = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@()) `
                                             -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 4000
            # Probed every 2 s rather than after one long pause: 6 s of silence ends the connection by the
            # transport timeout (03_03_04), which would read as a restart that never happened.
            $lateOk = ($probe.Acked -and $null -ne $probe.Response)
            for ($i = 0; $i -lt 3 -and $lateOk; $i++) {
                [void](Wait-KnxTunnel -Connection $s.Conn -Ms 2000)
                $late = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@()) `
                                                -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 4000
                $lateOk = ($late.Acked -and $null -ne $late.Response)
            }
            & $powerVoid
            Add-KnxEvidence -Note ("error code 0x{0:X2} (expected 0x03); same connection right after: acked={1} answered={2}; still answering over the next 6 s: {3}" -f $err, $probe.Acked, ($null -ne $probe.Response), $lateOk)
            Assert-KnxEqual 0x03 $err 'a channel other than 00h with erase code 01h was not answered with 03h'
            Assert-KnxTrue ($probe.Acked -and $null -ne $probe.Response) 'the transport connection did not survive - the device restarted although it refused the request'
            Assert-KnxTrue $lateOk 'the connection broke within 6 s - the device restarted after refusing the request'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-17.5 $tag" -Title 'The announced restart process time covers the restart' `
                       -Clause '03_05_02 clause 3.7.3 p.89: the client takes the process time as the time-out after which contact counts as failed' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $allow = $false
        if ($Ctx.PSObject.Properties['AllowDestructive']) { $allow = [bool]$Ctx.AllowDestructive }
        if (-not $allow) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'restarts the device - needs -IncludeDestructive' }
        # One standing session for the polling: reopening a tunnel costs about a second and hides a short
        # outage. Measured 2026-09-20: a TP-only device is away 0.6 s, an IP device 6.5 to 7.5 s.
        & $protectGate
        $poll = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target
        if (-not $poll.Ok) { Set-KnxTestSkip $poll.Reason }
        $alive = {
            $r = Invoke-KnxDeviceService -Session $poll -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@()) `
                                         -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 500 -Connectionless
            return ($null -ne $r.Response)
        }
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Close-KnxDeviceSession -Session $poll; Set-KnxTestSkip $s.Reason }
        try {
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.RESTART_MASTER_RESET -Data ([byte[]]@(0x01, 0x00)) `
                                         -ExpectApci $K.Apci.RESTART_RESPONSE -TimeoutMs 5000
            if ($null -eq $r.Response -or $r.Response.Length -lt 5) {
                Add-KnxEvidence -Received $r.Response
                Set-KnxTestNotApplicable 'no A_Restart_Response with a process time - nothing to judge (see D-17.4)'
            }
            Add-KnxEvidence -Received $r.Response
            $err = [int]$r.Response[2]
            $announced = ((([int]$r.Response[3]) -shl 8) -bor [int]$r.Response[4])
            Assert-KnxEqual 0 $err 'the confirmed restart was refused'
            Assert-KnxTrue ($announced -gt 0) 'the device announced a process time of 0 s'
        }
        finally { try { Close-KnxDeviceSession -Session $s } catch { } }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $down = -1.0
        while ($sw.Elapsed.TotalSeconds -lt 20) { if (-not (& $alive)) { $down = $sw.Elapsed.TotalSeconds; break } }
        try {
            if ($down -lt 0) {
                & $powerVoid
                Add-KnxEvidence -Note 'the device never stopped answering within 20 s - it did not restart'
                Assert-KnxTrue $false 'the device did not restart although it confirmed the request'
            }
            $back = -1.0
            while ($sw.Elapsed.TotalSeconds -lt 90) { if (& $alive) { $back = $sw.Elapsed.TotalSeconds; break } }
            Add-KnxEvidence -Note ("announced {0} s; stopped answering after {1:N2} s, answers again after {2:N2} s (away {3:N2} s)" -f $announced, $down, $back, ($back - $down))
            & $powerVoid
            & $goneResult ($back -ge 0) "the device did not answer again within 90 s" $true
            Assert-KnxTrue ($back -le $announced) "the device needed $([Math]::Round($back, 1)) s but announced $announced s, so a client that honours the process time gives up too early"
        }
        finally { Close-KnxDeviceSession -Session $poll }
    }

    # -- D-18 Router-only services on a device that is not a router -----------------

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-18.1 $tag" -Title 'A non-router does not serve the routing table services' `
                       -Clause '03_05_01 Router Object; 03_03_07 A_RoutingTable_Read' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.ROUTING_TABLE_READ -Data ([byte[]]@(0x00, 0x00)) `
                                         -ExpectApci $K.Apci.ROUTING_TABLE_READ_RESPONSE -TimeoutMs 3000
            # A coupler mask MAY serve these: the case is about a device that is not one, and that
            # decides the result in BOTH directions, so it is asked before either branch.
            # 03_05_01 Table 7 p.25: 0910h, 0911h, 0912h, 091Ah, 1900h; 0920h (06_02_01 p.10) and 2920h (06_02_42) are Coupler 2.0.
            $isCoupler = $profile.Mask -in @(0x0910, 0x0911, 0x0912, 0x091A, 0x0920, 0x1900, 0x2920)
            $answered = ($null -ne $r.Response)
            if ($answered) { Add-KnxEvidence -Received $r.Response }
            if ($isCoupler) {
                Add-KnxEvidence -Note ("mask 0x{0:X4} is a coupler, answered={1}" -f $profile.Mask, $answered)
                Set-KnxTestNotApplicable ("mask 0x{0:X4} is a coupler - the routing table services belong to it" -f $profile.Mask)
            }
            if (-not $answered) {
                # The silence branch reported PASS with nothing asserted: a dead device, a dropped
                # tunnel and a wrong address are all silent too. The device's own T_ACK proves it
                # received the request, and the gate proves it is still answering.
                Add-KnxEvidence -Note ("transport acknowledge for the request: {0}, L_Data.con: {1}" -f $r.Acked, $r.Confirmed)
                if (-not $r.Acked) {
                    Set-KnxTestNotApplicable "$Target did not acknowledge the request at the transport layer, so its silence on A_RoutingTable_Read cannot be attributed to the application layer"
                }
                & $liveGate 'the silence on A_RoutingTable_Read' $s
                Add-KnxEvidence -Note 'no answer, as expected from a device without a router object'
            }
            Assert-KnxTrue (-not $answered) ("mask 0x{0:X4} carries no router object, yet the device answered A_RoutingTable_Read" -f $profile.Mask)
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    # -- D-19 Group addresses, cross-checked on the bus -----------------------------
    #
    # The addresses are read from the device's own address table, never guessed, and where a second
    # interface is available the bus is observed by THAT interface: the one we send through cannot
    # be trusted to report what it itself did or dropped.

    $witnessIp = ''
    if ($Ctx.PSObject.Properties['WitnessIp']) { $witnessIp = [string]$Ctx.WitnessIp }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-19.1 $tag" -Title 'The device names its own group addresses' `
                       -Clause '03_05_01 Address Table Object, PID_TABLE_REFERENCE' -Body {
        & $propGate 'the address table'
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            $gas = @(Get-KnxDeviceGroupAddresses -Session $s)
            $profile.GroupAddresses = $gas
            Add-KnxEvidence -Note ("{0} group address(es): {1}" -f $gas.Count, (($gas | Select-Object -First 16) -join ', '))
            if ($gas.Count -eq 0) {
                Set-KnxTestNotApplicable 'the device has no group addresses configured - nothing to exercise on the group layer'
            }
            # The table content is written by the management client, so it is reported and not judged:
            # 03_05_01 4.16.8.2.4 p.238 (System B) asks for ascending order and says nothing on duplicates.
            $dupes = @($gas | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
            if ($dupes.Count) { Add-KnxEvidence -Note ("the address table names the same group address more than once: " + ($dupes -join ', ')) }
            $raws = @($gas | ForEach-Object { ConvertTo-KnxGa -Address $_ })
            for ($i = 1; $i -lt $raws.Count; $i++) {
                if ($raws[$i] -lt $raws[$i - 1]) {
                    Add-KnxEvidence -Note ("the address table is not in ascending order: {0} follows {1}, 03_05_01 4.16.8.2.4 p.238" -f $gas[$i], $gas[$i - 1])
                    break
                }
            }
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-19.2 $tag" -Title 'A group value read on a configured address is answered by the device, and the answer is on the bus' `
                       -Clause '03_03_07 A_GroupValue_Read/Response; 03_06_03 L_Busmon.ind' -Body {
        & $propGate 'the group layer'
        $gas = @()
        if ($profile.PSObject.Properties['GroupAddresses']) { $gas = @($profile.GroupAddresses) }
        if ($gas.Count -eq 0) { Set-KnxTestSkip 'no group address was discovered in D-19.1' }

        $witness = Open-KnxBusWitness -WitnessIp $witnessIp -Port $port -TargetPa $Target -BdutIp $ip
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target
        if (-not $s.Ok) { if ($witness.Ok) { [void](Close-KnxConnection -Connection $witness.Conn) }; Set-KnxTestSkip $s.Reason }
        try {
            # Addresses are tried in table order until THIS device answers: the first one may belong to a
            # write-only object, and an answer from another device on the same address says nothing about
            # the device under test.
            $answer = $null
            $answerGa = ''
            $foreign = @()
            $busFrames = @()
            $readCon = $null
            foreach ($ga in @($gas | Select-Object -Unique | Select-Object -First 8)) {
                $dst = ConvertTo-KnxGa -Address $ga
                $readCon = $null
                $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $dst -IsGroup -Tpdu (New-TpduGroupValueRead) -Priority 3
                Add-KnxEvidence -Sent $cemi
                [void](Send-KnxTunnelCemi -Connection $s.Conn -Cemi $cemi -TimeoutMs 3000)

                # Both sides are drained in ONE loop. A busmonitor tunnel delivers its frames as
                # TUNNELING_REQUESTs that have to be acknowledged; leaving that socket unread while waiting
                # on the other one lets the device repeat and then drop the connection (03_08_04 2.6.1), and
                # the witness then reports an empty bus for traffic that was plainly there.
                $deadline = [DateTime]::UtcNow.AddMilliseconds(2500)
                while ([DateTime]::UtcNow -lt $deadline -and $null -eq $answer) {
                    if ($witness.Ok) {
                        $bm = Receive-KnxTunnelCemi -Connection $witness.Conn -TimeoutMs 200
                        if ($null -ne $bm -and $bm.Cemi[0] -eq $K.Cemi.L_BUSMON_IND) {
                            $d = Read-CemiBusmon -Cemi $bm.Cemi
                            if ($null -ne $d) { $busFrames += $d }
                        }
                    }
                    $in = Receive-KnxTunnelCemi -Connection $s.Conn -TimeoutMs 300
                    if ($null -eq $in) { continue }
                    $ld = Read-CemiLData -Cemi $in.Cemi
                    if ($null -eq $ld) { continue }
                    # The confirmation for our own read says whether anything on the line acknowledged
                    # it on layer 2. It used to be discarded, and without it an answer could be
                    # credited to a read that never reached the line at all.
                    if ($ld.MessageCode -eq $K.Cemi.L_DATA_CON -and $ld.Destination -eq $dst) {
                        $readCon = (Test-KnxConPositive -LData $ld)
                        continue
                    }
                    if ($ld.MessageCode -ne $K.Cemi.L_DATA_IND) { continue }
                    if (-not ($ld.IsGroup -and $ld.Destination -eq $dst -and $ld.Tpdu.Length -ge 2 -and (($ld.Tpdu[1] -band 0xC0) -eq 0x40))) { continue }
                    if ($ld.Source -eq $s.Dst) { $answer = $ld; $answerGa = $ga; Add-KnxEvidence -Note "read on $ga" }
                    else { $foreign += ("{0} on {1}" -f (ConvertFrom-KnxPa -Raw $ld.Source), $ga) }
                }
                if ($null -ne $answer) { break }
            }
            # Kept for D-22.3, which asked the same question eight more times and started from the
            # top of the table each time.
            if ($null -ne $answer) { $profile.AnswerGa = $answerGa }

            # The loop stops at the answer, which can arrive before the busmonitor has handed over the
            # request and the answer; keep draining so the witness result is not taken on an empty queue.
            $until = [DateTime]::UtcNow.AddMilliseconds(1500)
            while ($witness.Ok -and [DateTime]::UtcNow -lt $until) {
                $bm = Receive-KnxTunnelCemi -Connection $witness.Conn -TimeoutMs 200
                if ($null -ne $bm -and $bm.Cemi[0] -eq $K.Cemi.L_BUSMON_IND) {
                    $d = Read-CemiBusmon -Cemi $bm.Cemi
                    if ($null -ne $d) { $busFrames += $d }
                }
            }

            # 03_02_02 clause 2.2.2 p.26, standard frame: CTRL(0) SA(1,2) DA(3,4). The source decides
            # whose telegram the witness saw.
            $srcOf = { param($F) if ($null -ne $F.Lpdu -and $F.Lpdu.Length -ge 6) { ((([int]$F.Lpdu[1]) -shl 8) -bor [int]$F.Lpdu[2]) } else { -1 } }
            $ownRaw = -1
            if ($null -ne $s.Conn -and $s.Conn.PSObject.Properties['TunnelPa'] -and $s.Conn.TunnelPa -and [string]$s.Conn.TunnelPa -ne '0.0.0') {
                $ownRaw = ConvertTo-KnxPa -Address ([string]$s.Conn.TunnelPa)
            }
            $fromDut = 0
            if ($witness.Ok) {
                $hits = @($busFrames | Where-Object { -not $_.IsAck })
                $fromUs = @($hits | Where-Object { (& $srcOf $_) -eq $ownRaw })
                $fromDut = @($hits | Where-Object { (& $srcOf $_) -eq $s.Dst }).Count
                Add-KnxEvidence -Note ("bus witness on {0}: {1} telegram(s) and {2} acknowledge(s) observed on the line, {3} of them from {4}" -f $witnessIp, $hits.Count, @($busFrames | Where-Object { $_.IsAck }).Count, $fromDut, $Target)
                # An empty line after reads that the SENDING interface ($ip) accepted is a statement
                # about that interface and about the witness, not about $Target - the device under test
                # never got the chance to answer. Judged as a FAIL it condemned a device for a rig fault.
                if ($hits.Count -eq 0) {
                    Set-KnxTestNotApplicable ("rig fault, not a device finding: the witness on {0} saw nothing at all on the line although the sending interface {1} accepted the group reads - {2} was never reached, so neither its answer nor its silence can be judged" -f $witnessIp, $ip, $Target)
                }
                # Our own reads are what proves the witness was listening to this exchange. Without
                # them a missing answer on the line says the witness missed it, not that the device
                # never sent it, and the check below would be a coin toss.
                if ($ownRaw -ge 0 -and $fromUs.Count -eq 0) {
                    Set-KnxTestNotApplicable ("the witness on {0} never saw the group reads this case sent, so what it did or did not see from {1} cannot be judged" -f $witnessIp, $Target)
                }
            }

            if ($null -eq $answer) {
                $who = if ($foreign.Count) { "answered only by other devices: $($foreign -join ', ')" } else { 'nothing answered' }
                Set-KnxTestNotApplicable "no read on this device's addresses was answered by $Target ($who) - its objects on them are not readable"
            }
            Add-KnxEvidence -Received $answer.Tpdu -Note ("answered by {0}, L_Data.con for the read: {1}" -f (ConvertFrom-KnxPa -Raw $answer.Source), $(if ($null -eq $readCon) { 'none observed' } else { $readCon }))
            # No -WitnessIp is a missing input; a witness that was given and is not usable is a rig fault.
            $needWitness = {
                param([string]$What)
                if (-not $witnessIp) { Set-KnxTestNotRun -MissingInput '-WitnessIp' -Reason "$What needs the independent witness" }
                if (-not $witness.Ok) { Set-KnxTestSkip ("$What cannot be told: the witness on {0} is not usable - {1}" -f $witnessIp, $witness.Reason) }
                if ($ownRaw -lt 0) { Set-KnxTestSkip "$What cannot be told: the tunnel address of the sending session is unknown, so the witness cannot find our frames" }
            }
            # A negative confirmation (03_02_02 2.4 p.40) follows NAKs, BUSYs or corrupted acks beyond the retries (any member, 0 dominates:
            # 1.1.5 p.11; Figure 37 p.32) or no ack at all; only the last counts against the device, which holds the address and must ack (p.39).
            if ($readCon -eq $false) {
                & $needWitness ("L_Data.con for the read on {0} was negative; whether {1} acknowledged it" -f $answerGa, $Target)
                $gaRaw = ConvertTo-KnxGa -Address $answerGa
                $ackSeen = @()
                for ($i = 0; ($i + 1) -lt $busFrames.Count; $i++) {
                    $bf = $busFrames[$i]
                    if ($bf.IsAck -or $null -eq $bf.Lpdu -or $bf.Lpdu.Length -lt 6 -or (& $srcOf $bf) -ne $ownRaw) { continue }
                    if (((([int]$bf.Lpdu[3]) -shl 8) -bor [int]$bf.Lpdu[4]) -ne $gaRaw) { continue }
                    $nx = $busFrames[$i + 1]
                    $ackSeen += $(if ($nx.IsAck) { '{0:X2}' -f [int]$nx.Lpdu[0] } else { 'none' })
                }
                if ($ackSeen.Count -eq 0) { Set-KnxTestNotApplicable ("the witness on {0} did not see the read on {1}, so its acknowledge cannot be judged" -f $witnessIp, $answerGa) }
                if (@($busFrames | Where-Object { $_.IsAck }).Count -eq 0) { Set-KnxTestNotApplicable ("the witness on {0} delivered no acknowledge frame at all, so a missing one cannot be judged" -f $witnessIp) }
                Add-KnxEvidence -Note ("L_Data.con for the read on {0} was negative; acknowledge after each transmission: {1}" -f $answerGa, ($ackSeen -join ' '))
                Assert-KnxTrue (@($ackSeen | Where-Object { $_ -ne 'none' }).Count -gt 0) ("nothing acknowledged the read on {0} on layer 2, although {1} holds that address and answered it (03_02_02 2.4 p.39)" -f $answerGa, $Target)
            }
            & $needWitness ("{0} answered on {1}; whether the answer was on the line" -f $Target, $answerGa)
            # The second half of the title. The tunnel reported an answer; the independent witness has
            # to have seen it on the line, or the interface reported something the bus never carried.
            Assert-KnxTrue ($fromDut -gt 0) ("the sending interface {0} reported an answer from {1} that the witness on {2} never saw on the line" -f $ip, $Target, $witnessIp)
        }
        finally {
            if ($witness.Ok) { try { [void](Close-KnxConnection -Connection $witness.Conn) } catch { } }
            Close-KnxDeviceSession -Session $s
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-19.3 $tag" -Title 'A group value read on an address the device does not have stays unanswered' `
                       -Clause '03_03_07 A_GroupValue_Read; 03_05_01 Address Table Object' -Body {
        & $propGate 'the group layer'
        $gas = @()
        if ($profile.PSObject.Properties['GroupAddresses']) { $gas = @($profile.GroupAddresses) }
        if ($gas.Count -eq 0) { Set-KnxTestSkip 'no group address was discovered in D-19.1' }

        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # An address that is provably NOT in the table this case just read. Without that proof the
            # case would only show that some arbitrary address is quiet, which says nothing.
            $free = ''
            foreach ($cand in @('7/7/7', '7/7/6', '7/7/5', '6/6/6')) {
                if ($gas -notcontains $cand) { $free = $cand; break }
            }
            if (-not $free) { Set-KnxTestSkip 'every candidate address is in the device table' }
            $dst = ConvertTo-KnxGa -Address $free
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $dst -IsGroup -Tpdu (New-TpduGroupValueRead) -Priority 3
            Add-KnxEvidence -Sent $cemi -Note "reading $free, which is not in the device's address table"
            [void](Send-KnxTunnelCemi -Connection $s.Conn -Cemi $cemi -TimeoutMs 3000)

            $answer = $null
            $deadline = [DateTime]::UtcNow.AddSeconds(3)
            while ([DateTime]::UtcNow -lt $deadline) {
                $in = Receive-KnxTunnelCemi -Connection $s.Conn -TimeoutMs 800
                if ($null -eq $in) { continue }
                $ld = Read-CemiLData -Cemi $in.Cemi
                if ($null -eq $ld -or $ld.MessageCode -ne $K.Cemi.L_DATA_IND) { continue }
                if ($ld.IsGroup -and $ld.Destination -eq $dst -and (ConvertFrom-KnxPa -Raw $ld.Source) -eq $Target) { $answer = $ld; break }
            }
            if ($null -ne $answer) { Add-KnxEvidence -Received $answer.Tpdu }
            else { & $liveGate "the silence on $free" $s }
            Assert-KnxTrue ($null -eq $answer) "the device answered on $free although that address is not in its address table"
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    # -- D-20 Services a device must NOT serve, and services it must not mis-answer ---
    #
    # Sending these is safe by construction: a plain TP device has no router object and no RF
    # medium, so a conformant one stays silent. The case is there to prove the silence, because a
    # device that answers them is offering a capability it does not have.

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-20.1 $tag" -Title 'Router-only services stay unanswered on a device without a router object' `
                       -Clause '03_05_01 Router Object; 03_03_07 A_RoutingTable_Open/Write, A_MemoryRouter_Write' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        & $protectGate
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            $answered = @()
            foreach ($svc in @(
                @{ N = 'A_RoutingTable_Open';  A = $K.Apci.ROUTING_TABLE_OPEN;  D = @() },
                @{ N = 'A_RoutingTable_Write'; A = $K.Apci.ROUTING_TABLE_WRITE; D = @(0x00, 0x00, 0x00) },
                @{ N = 'A_MemoryRouter_Write'; A = $K.Apci.MEMORY_ROUTER_WRITE; D = @(0x00, 0x00) }
            )) {
                $r = Invoke-KnxDeviceService -Session $s -Apci $svc.A -Data ([byte[]]$svc.D) -TimeoutMs 2500
                # Only APPLICATION answers count. Every connection-oriented request is acknowledged at
                # the transport layer, and counting that T_ACK as an answer reported both devices as
                # serving router services they do not have.
                # From the TARGET, and an application PDU. Without the source filter every telegram
                # another device happened to put on the shared line was counted as this device
                # answering - which is how a NeoPixel's group traffic became "the RaumController
                # serves router services".
                $got = @($r.Frames | Where-Object {
                    $null -ne $_ -and $null -ne $_.Tpdu -and $_.Tpdu.Length -ge 2 -and
                    (ConvertFrom-KnxPa -Raw $_.Source) -eq $Target -and
                    -not $_.IsGroup -and
                    (@('Numbered', 'Unnumbered') -contains (Get-KnxTpduKind -Tpdu $_.Tpdu).Kind)
                })
                if ($got.Count -gt 0) { $answered += $svc.N }
            }
            Add-KnxEvidence -Note ("answered: {0}" -f $(if ($answered.Count) { $answered -join ', ' } else { 'none, as expected' }))
            if ($answered.Count -eq 0) { & $liveGate 'the silence on all three router-only services' $s }
            Assert-KnxEqual 0 $answered.Count "the device answered router-only services although it carries no router object: $($answered -join ', ')"
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-20.2 $tag" -Title 'RF domain services stay unanswered on a TP device' `
                       -Clause '03_03_07 A_DomainAddress_SerialNumber_Read/Write (RF medium)' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $b = Open-KnxDeviceSession -Ip $ip -Port $port -Pa '0.0.0'
        if (-not $b.Ok) { Set-KnxTestSkip $b.Reason }
        try {
            $serial = [byte[]]@(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFD)
            $r = Invoke-KnxDeviceService -Session $b -Apci $K.Apci.DOMAIN_ADDR_SERIAL_READ -Data $serial `
                                         -ExpectApci $K.Apci.DOMAIN_ADDR_SERIAL_RESPONSE -TimeoutMs 2500 -Connectionless `
                                         -ExpectSource (ConvertTo-KnxPa -Address $Target)
            foreach ($o in $r.Others) { Add-KnxEvidence -Note ("another device answered: {0}" -f (ConvertFrom-KnxPa -Raw $o.Source)) }
            if ($null -ne $r.Response) { Add-KnxEvidence -Received $r.Response }
            else { & $liveGate 'the silence on the RF domain address read' $b }
            Assert-KnxTrue ($null -eq $r.Response) "$Target answered an RF domain address read"
            # The write is sent to a serial number that belongs to nobody, so it cannot change a device
            # even if one were listening.
            $w = Invoke-KnxDeviceService -Session $b -Apci $K.Apci.DOMAIN_ADDR_SERIAL_WRITE -Data ([byte[]]($serial + @(0x00, 0x00, 0x00, 0x00, 0x00, 0x00))) -TimeoutMs 2000 -Connectionless
            Add-KnxEvidence -Note 'RF domain write to a serial number no device owns - nothing may react'
        }
        finally { Close-KnxDeviceSession -Session $b }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-20.3 $tag" -Title 'Function property command and its extended forms answer consistently' `
                       -Clause '03_03_07 A_FunctionProperty_Command; A_FunctionPropertyExt_Command/State' -Body {
        & $propGate 'the function property services'
        & $protectGate
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # Object 0, PID 1 (PID_OBJECT_TYPE) is not PDT_Function, so the command cannot execute anything.
            # A device without these services may stay silent; one that answers follows 3.4.7.3.
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.FUNCTION_PROPERTY_COMMAND -Data ([byte[]]@(0x00, 0x01, 0x00)) `
                                         -ExpectApci $K.Apci.FUNCTION_PROPERTY_STATE_RESPONSE -TimeoutMs 3000
            if ($null -ne $r.Response) {
                Add-KnxEvidence -Received $r.Response
                # 03_03_07 3.4.7.3 p.88: PID_OBJECT_TYPE is not PDT_Function, so the answer carries APCI,
                # object_index and property_id only - no return_code (octet 10, TPDU index 4) and no data.
                Assert-KnxTrue ($r.Response.Length -ge 4) 'function property response is too short to carry object_index and property_id'
                Assert-KnxBytes ([byte[]]@(0x00, 0x01)) ([byte[]]$r.Response[2..3]) 'the response names a different object or property than the request'
                if ($r.Response.Length -gt 4) { Add-KnxEvidence -Note ("return code=0x{0:X2}" -f [int]$r.Response[4]) }
                Assert-KnxEqual 4 $r.Response.Length '03_03_07 3.4.7.3 p.88: the answer for a property that is not PDT_Function carries neither return_code nor data'
            }
            else { Add-KnxEvidence -Note 'no answer to the classic function property command - allowed' }

            # PID_OBJECT_TYPE again: a PID in 201-255 is manufacturer specific (03_07_03 p.11) and may run a function.
            $extPayload = (& $extHeader 0 1 1 1 1)
            $r2 = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.FUNCTION_PROPERTY_EXT_COMMAND -Data ([byte[]]$extPayload) `
                                          -ExpectApci $K.Apci.FUNCTION_PROPERTY_EXT_STATE_RESPONSE -TimeoutMs 3000
            if ($null -ne $r2.Response) { Add-KnxEvidence -Received $r2.Response }
            $r3 = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.FUNCTION_PROPERTY_EXT_STATE -Data ([byte[]]$extPayload) `
                                          -ExpectApci $K.Apci.FUNCTION_PROPERTY_EXT_STATE_RESPONSE -TimeoutMs 3000
            if ($null -ne $r3.Response) { Add-KnxEvidence -Received $r3.Response }
            $extCmd = ($null -ne $r2.Response)
            $extState = ($null -ne $r3.Response)
            Add-KnxEvidence -Note ("classic answered={0}, extended command answered={1}, extended state answered={2}" -f ($null -ne $r.Response), $extCmd, $extState)

            # The title claims the forms answer CONSISTENTLY, and nothing here judged that: with all
            # three silent the body reached its end having asserted nothing at all, so the case could
            # not fail on any device. Silence from all three is a device without these services - N-A,
            # which is a statement about the device; the pair answering only half way is the
            # inconsistency the title is about, and that is a finding.
            if ($null -eq $r.Response -and -not $extCmd -and -not $extState) {
                Set-KnxTestNotApplicable 'the device answers neither the classic nor the extended function property services, so there is no consistency to judge'
            }
            Assert-KnxTrue ($extCmd -eq $extState) ("the extended pair answers only half way: command answered={0}, state answered={1} - a device serving A_FunctionPropertyExt_Command must also serve A_FunctionPropertyExt_State" -f $extCmd, $extState)
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-20.4 $tag" -Title 'Key write is not confirmed by a device without access keys' `
                       -Clause '03_03_07 A_Key_Write/Response; 03_05_01 access levels' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        & $protectGate
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # Level 15 is the LOWEST privilege, and FFFFFFFFh deletes a key and is its ex-factory value
            # (03_03_07 3.5.8 p.129; 03_05_02 p.85 NOTE 15), so a device that implements keys keeps its state.
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.KEY_WRITE -Data ([byte[]]@(0x0F, 0xFF, 0xFF, 0xFF, 0xFF)) `
                                         -ExpectApci $K.Apci.KEY_RESPONSE -TimeoutMs 3000
            if ($null -eq $r.Response) {
                Add-KnxEvidence -Note 'no A_Key_Response - the device does not implement access keys'
                Set-KnxTestNotApplicable 'device does not implement the key services (optional)'
            }
            Add-KnxEvidence -Received $r.Response
            Assert-KnxTrue ($r.Response.Length -ge 3) 'A_Key_Response carries no level'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-20.5 $tag" -Title 'Unconfirmed extended property write changes nothing it may not change' `
                       -Clause '03_03_07 A_PropertyValue_ExtWriteUnCon' -Body {
        & $propGate 'the extended property services'
        & $protectGate
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # The device's OWN serial number is written back, exactly as in D-6.2: the unconfirmed form
            # gives no answer to judge, so the only thing this case can establish is that the device is
            # still alive and unchanged afterwards - and it must not be able to damage it while doing so.
            $before = Read-KnxDeviceProperty -Session $s -ObjectIndex 0 -PropertyId $K.Pid.SERIAL_NUMBER
            if (-not $before.Ok -or $before.Data.Length -ne 6) { Set-KnxTestSkip 'could not read PID_SERIAL_NUMBER, so there is no safe value to write' }
            $payload = (& $extHeader 0 1 $K.Pid.SERIAL_NUMBER 1 1) + $before.Data
            [void](Invoke-KnxDeviceService -Session $s -Apci $K.Apci.PROPERTY_EXT_VALUE_WRITE_UNCON -Data ([byte[]]$payload) -TimeoutMs 2500)
            [void](Wait-KnxTunnel -Connection $s.Conn -Ms 300)
            # Read back on a FRESH session. The unconfirmed form sends no answer, so the sequence
            # counters of the session that carried it cannot be reconciled - continuing on it made a
            # perfectly healthy device look as if it had stopped answering.
            Close-KnxDeviceSession -Session $s
            $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
            if (-not $s.Ok) { Set-KnxTestSkip "the device could not be reconnected after the unconfirmed write: $($s.Reason)" }
            $after = Read-KnxDeviceProperty -Session $s -ObjectIndex 0 -PropertyId $K.Pid.SERIAL_NUMBER
            Add-KnxEvidence -Note ("before={0} after={1}" -f (ConvertTo-HexString -Bytes $before.Data), (ConvertTo-HexString -Bytes $after.Data))
            & $goneResult $after.Ok 'the device stopped answering property reads after an unconfirmed extended write'
            Assert-KnxEqual (ConvertTo-HexString -Bytes $before.Data) (ConvertTo-HexString -Bytes $after.Data) 'the serial number changed across an unconfirmed write of its own value'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    # -- D-21 Services that change the device (gated, and every one restores what it touched) --

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-21.1 $tag" -Title 'Group value write reaches the bus and the device keeps its value' `
                       -Clause '03_03_07 A_GroupValue_Write; 03_06_03 L_Busmon.ind' -Body {
        & $propGate 'the group layer'
        $allow = $false
        if ($Ctx.PSObject.Properties['AllowDestructive']) { $allow = [bool]$Ctx.AllowDestructive }
        if (-not $allow) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'writes a group telegram that an actuator may act on - needs -IncludeDestructive' }
        $gas = @()
        if ($profile.PSObject.Properties['GroupAddresses']) { $gas = @($profile.GroupAddresses) }
        if ($gas.Count -eq 0) { Set-KnxTestSkip 'no group address was discovered in D-19.1' }
        # Writing a read value back is only harmless for a state value: a time, a scene or a dimming step
        # acts again on every listener, and which devices listen is not visible from the bus. So the
        # operator names the address (-TestGa, comma list) and it has to be in this device's table.
        $testGas = @()
        if ($Ctx.PSObject.Properties['TestGa'] -and $Ctx.TestGa) { $testGas = @(([string]$Ctx.TestGa) -split ',' | ForEach-Object { $_.Trim() }) }
        if ($testGas.Count -eq 0) { Set-KnxTestNotRun -MissingInput '-TestGa' -Reason 'needs -TestGa: a group address of this device that nothing else acts on' }
        $ga = @($testGas | Where-Object { $gas -contains $_ }) | Select-Object -First 1
        if (-not $ga) { Set-KnxTestNotRun -MissingInput '-TestGa' -Reason "none of -TestGa ($($testGas -join ', ')) is in the address table of $Target" }

        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        $witness = [pscustomobject]@{ Ok = $false; Reason = 'not opened'; Conn = $null }
        try {
            $witness = Open-KnxBusWitness -WitnessIp $witnessIp -Port $port -TargetPa $Target -BdutIp $ip
            $dst = ConvertTo-KnxGa -Address $ga
            # Busmonitor frames arrive as TUNNELLING_REQUESTs that must be read and acknowledged, or the
            # witness repeats and then drops the connection (03_08_04 2.6.1) - so it is drained in every wait.
            $drainWitness = {
                param([int]$Ms)
                $seen = @()
                $until = [DateTime]::UtcNow.AddMilliseconds($Ms)
                while ($witness.Ok -and [DateTime]::UtcNow -lt $until) {
                    $bm = Receive-KnxTunnelCemi -Connection $witness.Conn -TimeoutMs 100
                    if ($null -ne $bm -and $bm.Cemi[0] -eq $K.Cemi.L_BUSMON_IND) {
                        $d = Read-CemiBusmon -Cemi $bm.Cemi
                        if ($null -ne $d) { $seen += $d }
                    }
                }
                return , $seen
            }
            # The value the target holds: its own answer only, another device's value is not what it holds.
            $readValue = {
                $c = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $dst -IsGroup -Tpdu (New-TpduGroupValueRead) -Priority 3
                [void](Send-KnxTunnelCemi -Connection $s.Conn -Cemi $c -TimeoutMs 3000)
                $until = [DateTime]::UtcNow.AddSeconds(3)
                while ([DateTime]::UtcNow -lt $until) {
                    [void](& $drainWitness 50)
                    $in = Receive-KnxTunnelCemi -Connection $s.Conn -TimeoutMs 300
                    if ($null -eq $in) { continue }
                    $ld = Read-CemiLData -Cemi $in.Cemi
                    if ($null -ne $ld -and $ld.MessageCode -eq $K.Cemi.L_DATA_IND -and $ld.IsGroup -and $ld.Source -eq $s.Dst -and
                        $ld.Destination -eq $dst -and $ld.Tpdu.Length -ge 2 -and (($ld.Tpdu[1] -band 0xC0) -eq 0x40)) { return , $ld.Tpdu }
                }
                return $null
            }

            # Read the current value first and write exactly that back, so the telegram is real and the
            # value the device holds does not change. -TestGa is what keeps other listeners out of it.
            $value = & $readValue
            if ($null -eq $value) { Set-KnxTestSkip "$Target did not answer a read on $ga, so there is no value to write back unchanged" }

            # A value the device updates by itself cannot be written back "unchanged": it moves between the
            # two reads and the case fails a device that did nothing wrong. Measured on 5.0.7, whose
            # temperature on 0/7/0 went from 40 02 B3 to 40 03 0F within seconds. Read twice and leave the
            # address alone when it moves on its own.
            [void](Wait-KnxTunnel -Connection $s.Conn -Ms 1500)
            $second = & $readValue
            if ($null -ne $second -and (ConvertTo-HexString -Bytes $second) -ne (ConvertTo-HexString -Bytes $value)) {
                Add-KnxEvidence -Note ("read twice: {0} then {1}" -f (ConvertTo-HexString -Bytes $value), (ConvertTo-HexString -Bytes $second))
                Set-KnxTestNotRun -MissingInput '-TestGa' -Reason "$Target changes the value on $ga by itself, so a write-back cannot be judged - name a -TestGa the device does not publish"
            }

            # Rebuilt through the service constant rather than by patching bits in the answer: the
            # coverage tool counts what the suite demonstrably sends, and a hand-patched octet would
            # make the figure claim a service that nothing in the source names.
            $wr = New-TpduService -Apci ($K.Apci.GROUP_VALUE_WRITE -bor ($value[1] -band 0x3F))
            if ($value.Length -gt 2) { $wr = [byte[]]($wr + $value[2..($value.Length - 1)]) }
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $dst -IsGroup -Tpdu $wr -Priority 3
            [void](& $drainWitness 300) # what the read left on the witness is not evidence of the write
            Add-KnxEvidence -Sent $cemi -Note "writing the value $Target just reported, unchanged"
            [void](Send-KnxTunnelCemi -Connection $s.Conn -Cemi $cemi -TimeoutMs 3000)

            # The interface confirms with L_Data.con once the medium acknowledged the frame (03_06_03).
            $con = $null
            $until = [DateTime]::UtcNow.AddSeconds(3)
            $busFrames = @()
            while ([DateTime]::UtcNow -lt $until -and $null -eq $con) {
                $busFrames += & $drainWitness 50
                $in = Receive-KnxTunnelCemi -Connection $s.Conn -TimeoutMs 200
                if ($null -eq $in) { continue }
                $ld = Read-CemiLData -Cemi $in.Cemi
                # The write's own confirmation: the read's L_Data.con can still be queued and carries APCI 00h.
                if ($null -ne $ld -and $ld.MessageCode -eq $K.Cemi.L_DATA_CON -and $ld.IsGroup -and $ld.Destination -eq $dst -and
                    $ld.Tpdu.Length -ge 2 -and (($ld.Tpdu[1] -band 0xC0) -eq 0x80)) { $con = $ld }
            }
            $busFrames += & $drainWitness 800
            Assert-KnxTrue ($null -ne $con) 'no L_Data.con for the group write'
            Assert-KnxTrue (Test-KnxConPositive -LData $con) 'the interface confirmed the group write negatively'

            if ($witness.Ok) {
                # Only this write counts: standard frame from this tunnel to the address, group flag,
                # A_GroupValue_Write. Another device writing the same address is not our telegram.
                $myPa = -1
                if ($s.Conn.PSObject.Properties['TunnelPa'] -and $s.Conn.TunnelPa -and [string]$s.Conn.TunnelPa -ne '0.0.0') { $myPa = ConvertTo-KnxPa -Address ([string]$s.Conn.TunnelPa) }
                $mine = @($busFrames | Where-Object {
                    -not $_.IsAck -and $_.Lpdu.Length -ge 8 -and ($_.Lpdu[0] -band 0x80) -and ($_.Lpdu[5] -band 0x80) -and
                    ($myPa -lt 0 -or ((([int]$_.Lpdu[1]) -shl 8) -bor [int]$_.Lpdu[2]) -eq $myPa) -and
                    ((([int]$_.Lpdu[3]) -shl 8) -bor [int]$_.Lpdu[4]) -eq $dst -and (($_.Lpdu[7] -band 0xC0) -eq 0x80)
                })
                Add-KnxEvidence -Note ("bus witness on {0}: {1} copy/copies of the write on the line" -f $witnessIp, $mine.Count)
                Assert-KnxTrue ($mine.Count -gt 0) 'the group write never reached the line although the interface confirmed it'
            }
            else { Add-KnxEvidence -Note ("no independent bus witness: {0}" -f $witness.Reason) }

            $after = & $readValue
            & $goneResult ($null -ne $after) "$Target no longer answers a read on $ga after the write"
            Add-KnxEvidence -Received $after -Note 'value read back after the write'
            Assert-KnxEqual (ConvertTo-HexString -Bytes ([byte[]]$value[1..($value.Length - 1)])) (ConvertTo-HexString -Bytes ([byte[]]$after[1..($after.Length - 1)])) 'the device holds a different value after its own value was written back'
        }
        finally {
            if ($witness.Ok) { try { [void](Close-KnxConnection -Connection $witness.Conn) } catch { } }
            Close-KnxDeviceSession -Session $s
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-21.2 $tag" -Title 'Memory write is refused or round-trips the bytes it was given' `
                       -Clause '03_03_07 A_Memory_Write, A_UserMemory_Write, A_MemoryExtended_Write' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $allow = $false
        if ($Ctx.PSObject.Properties['AllowDestructive']) { $allow = [bool]$Ctx.AllowDestructive }
        if (-not $allow) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'writes device memory - needs -IncludeDestructive' }
        & $protectGate
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # Read first, write the SAME bytes back, read again. Whatever the device does with the
            # write, the content it holds is unchanged - the case cannot corrupt the device even if
            # the write is accepted where it should not be.
            $addr = 0x0060
            $orig = Get-KnxDeviceMemory -Session $s -Address $addr -Length 4
            if ($null -eq $orig -or $orig.Length -lt 4) { Set-KnxTestNotApplicable 'device does not serve a memory read at this address, so a write cannot be checked safely' }
            Add-KnxEvidence -Note ("original at 0x{0:X4}: {1}" -f $addr, (ConvertTo-HexString -Bytes $orig))

            [void](Invoke-KnxDeviceService -Session $s -Apci $K.Apci.MEMORY_EXT_WRITE `
                                           -Data ([byte[]]@(4, 0x00, (($addr -shr 8) -band 0xFF), ($addr -band 0xFF)) + $orig) -TimeoutMs 4000)
            [void](Invoke-KnxDeviceService -Session $s -Apci ($K.Apci.MEMORY_WRITE -bor 4) `
                                           -Data ([byte[]]@((($addr -shr 8) -band 0xFF), ($addr -band 0xFF)) + $orig) -TimeoutMs 4000)
            # 03_03_07 Figure 79 p.117: address extension and count share octet 8, then address high and
            # address low. Passing the high byte twice addressed 0x00000 and wrote these octets there.
            # The user services address the Application Device Management's own logical space, whose
            # mapping to physical memory is device-defined (3.5.6.1 p.117) - so what A_Memory_Read
            # returned must not be written there. This leg reads its own bytes and writes those back,
            # and it is left out when the device does not answer the user-memory read.
            $ur = Invoke-KnxDeviceService -Session $s -Apci ($K.Apci.USER_MEMORY_READ) `
                                          -Data ([byte[]]@(0x04, (($addr -shr 8) -band 0xFF), ($addr -band 0xFF))) `
                                          -ExpectApci $K.Apci.USER_MEMORY_RESPONSE -TimeoutMs 4000
            if ($null -ne $ur.Response -and $ur.Response.Length -ge 9 -and ([int]$ur.Response[2] -band 0x0F) -eq 4) {
                $uorig = [byte[]]$ur.Response[5..8]
                Add-KnxEvidence -Note ("user memory at 0x{0:X4}: {1}" -f $addr, (ConvertTo-HexString -Bytes $uorig))
                [void](Invoke-KnxDeviceService -Session $s -Apci $K.Apci.USER_MEMORY_WRITE `
                                               -Data ([byte[]]@(0x04, (($addr -shr 8) -band 0xFF), ($addr -band 0xFF)) + $uorig) -TimeoutMs 4000)
                $ua = Invoke-KnxDeviceService -Session $s -Apci ($K.Apci.USER_MEMORY_READ) `
                                              -Data ([byte[]]@(0x04, (($addr -shr 8) -band 0xFF), ($addr -band 0xFF))) `
                                              -ExpectApci $K.Apci.USER_MEMORY_RESPONSE -TimeoutMs 4000
                # Checked as strictly as the first read: same count, same echoed address, then the data.
                # A device that answered before the write and not after has changed under the case's
                # hands, and the physical read further down cannot see it - the user services address
                # the Application Device Management's own space. So this is a result, not a note.
                & $goneResult ($null -ne $ua.Response) 'the device stopped answering A_UserMemory_Read after its own bytes were written back'
                Assert-KnxTrue ($ua.Response.Length -ge 9) "the answer after the write is $($ua.Response.Length) octets, too short to compare"
                Assert-KnxEqual 4 ([int]$ua.Response[2] -band 0x0F) 'the answer after the write reports a different octet count'
                Assert-KnxEqual ('{0:X4}' -f $addr) ('{0:X4}' -f ((([int]$ua.Response[3]) * 256) + [int]$ua.Response[4])) `
                                'the answer after the write echoes a different address'
                Assert-KnxEqual (ConvertTo-HexString -Bytes $uorig) (ConvertTo-HexString -Bytes ([byte[]]$ua.Response[5..8])) `
                                'user memory changed although only its own bytes were written back'
            }
            elseif ($null -eq $ur.Response) {
                Add-KnxEvidence -Note 'device does not answer A_UserMemory_Read here, so the user-memory write is not exercised'
            }
            elseif ($ur.Response.Length -lt 3) {
                Add-KnxEvidence -Note ("A_UserMemory_Read answered with {0} octets, too short to carry a count, so the user-memory write is not exercised" -f $ur.Response.Length)
            }
            else {
                Add-KnxEvidence -Note ("A_UserMemory_Read reports {0} octets in a {1} octet answer for a request of 4, so the user-memory write is not exercised" -f ([int]$ur.Response[2] -band 0x0F), $ur.Response.Length)
            }

            $after = Get-KnxDeviceMemory -Session $s -Address $addr -Length 4
            Add-KnxEvidence -Note ("after: {0}" -f $(if ($null -ne $after) { ConvertTo-HexString -Bytes $after } else { 'not readable' }))
            & $goneResult ($null -ne $after) 'the device stopped answering memory reads after the writes'
            Assert-KnxEqual (ConvertTo-HexString -Bytes $orig) (ConvertTo-HexString -Bytes $after) 'the memory content changed although only its own bytes were written back'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-21.3 $tag" -Title 'Individual address write is only accepted in programming mode' `
                       -Clause '03_05_02 clause 2.3 NM_IndividualAddress_Write, p.13 and clause 2.5 NM_IndividualAddress_SerialNumber_Write, p.16' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $allow = $false
        if ($Ctx.PSObject.Properties['AllowDestructive']) { $allow = [bool]$Ctx.AllowDestructive }
        if (-not $allow) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'sends an individual address write - needs -IncludeDestructive' }
        $b = Open-KnxDeviceSession -Ip $ip -Port $port -Pa '0.0.0'
        if (-not $b.Ok) { Set-KnxTestSkip $b.Reason }
        try {
            # SAFETY INTERLOCK, checked here and not inherited from D-13.2: earlier destructive cases in
            # this same run write to element index 0 of PID_PROG_MODE, and a device that mishandles that
            # write ends up IN programming mode. Sending a broadcast address write then would actually
            # reassign it. So the absence of programming mode is re-established immediately before the
            # write, every time.
            $r0 = Invoke-KnxDeviceService -Session $b -Apci $K.Apci.INDIVIDUAL_ADDR_READ -Data ([byte[]]@()) `
                                          -ExpectApci $K.Apci.INDIVIDUAL_ADDR_RESPONSE -TimeoutMs 3000 -Connectionless
            if ($null -ne $r0.Response) {
                Add-KnxEvidence -Received $r0.Response
                Set-KnxTestSkip 'a device on this line IS in programming mode - a broadcast address write would reassign it, so it is not sent'
            }
            Add-KnxEvidence -Note 'verified immediately beforehand: no device is in programming mode, so the write must be ignored by all'
            # Whoever answers on the probe address holds it. Also asked through the traffic and control interfaces:
            # a coupler under test need not pass a frame to 15.15.254 onto its line. Returns Path and Serial, or $null.
            $whoHolds = {
                $paths = @($ip)
                foreach ($x in @($pg.TrafficIp, $(if ($pg.On) { $pg.Via } else { '' }))) { if ($x -and $paths -notcontains $x) { $paths += $x } }
                foreach ($tp in $paths) {
                    $taker = if ($tp -eq $ip) { & $probeOn $b '15.15.254' } else { Open-KnxDeviceSession -Ip $tp -Port $port -Pa '15.15.254' }
                    if (-not $taker.Ok) { Add-KnxEvidence -Note "no tunnel on $tp to ask 15.15.254: $($taker.Reason)"; continue }
                    try {
                        $tk = Invoke-KnxDeviceService -Session $taker -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@(0x00)) `
                                                      -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 3000 -Connectionless
                        Add-KnxEvidence -Note ("a device answers on 15.15.254 through {0}: {1}" -f $tp, ($null -ne $tk.Response))
                        if ($null -ne $tk.Response) {
                            Add-KnxEvidence -Received $tk.Response
                            $sr = Invoke-KnxDeviceService -Session $taker -Apci $K.Apci.PROPERTY_VALUE_READ -Data ([byte[]]@(0x00, $K.Pid.SERIAL_NUMBER, 0x10, 0x01)) `
                                                          -ExpectApci $K.Apci.PROPERTY_VALUE_RESPONSE -TimeoutMs 3000 -Connectionless
                            $hex = 'unknown'
                            if ($null -ne $sr.Response -and $sr.Response.Length -ge 12) { $hex = (($sr.Response[6..11] | ForEach-Object { '{0:x2}' -f $_ }) -join '') }
                            return [pscustomobject]@{ Path = $tp; Serial = $hex }
                        }
                    }
                    finally { if ($tp -ne $ip) { Close-KnxDeviceSession -Session $taker } }
                }
                return $null
            }
            # A device left on 15.15.254 by an earlier run would be taken for one that took this write.
            $before = & $whoHolds
            if ($null -ne $before) {
                Set-KnxTestSkip "a device (serial $($before.Serial)) already answers on 15.15.254 - restore it (ETS or A_IndividualAddress_SerialNumber_Write); the write is not sent"
            }
            $probe = ConvertTo-KnxPa -Address '15.15.254'
            [void](Invoke-KnxDeviceService -Session $b -Apci $K.Apci.INDIVIDUAL_ADDR_WRITE `
                                           -Data ([byte[]]@((($probe -shr 8) -band 0xFF), ($probe -band 0xFF))) -TimeoutMs 2500 -Connectionless)
            [void](Wait-KnxTunnel -Connection $b.Conn -Ms 800)

            # The serial-number form needs no programming mode, so it is aimed at a serial number that
            # belongs to nothing: no device may react, and the one under test must be untouched.
            $noSuchSerial = [byte[]]@(0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFC)
            [void](Invoke-KnxDeviceService -Session $b -Apci $K.Apci.IND_ADDR_SERIAL_WRITE `
                                           -Data ([byte[]]($noSuchSerial + @((($probe -shr 8) -band 0xFF), ($probe -band 0xFF), 0x00, 0x00, 0x00, 0x00))) -TimeoutMs 2500 -Connectionless)
            [void](Wait-KnxTunnel -Connection $b.Conn -Ms 500)

            $holder = & $whoHolds
            if ($null -ne $holder) {
                $who = if ($null -ne $profile.Serial -and $holder.Serial -eq (($profile.Serial | ForEach-Object { '{0:x2}' -f $_ }) -join '')) { " - it is $Target itself" } else { '' }
                Assert-KnxTrue $false "a device (serial $($holder.Serial)) took the broadcast address write without programming mode - restore it (ETS or A_IndividualAddress_SerialNumber_Write)$who"
            }

            $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target
            if (-not $s.Ok) { Set-KnxTestSkip "no tunnel to check $Target afterwards: $($s.Reason)" }
            try {
                $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@()) `
                                             -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 4000 -Connectionless
                Add-KnxEvidence -Note ("device still answers on {0}: {1}" -f $Target, ($null -ne $r.Response))
            }
            finally { Close-KnxDeviceSession -Session $s }
            & $goneResult ($null -ne $r.Response) "the device no longer answers on $Target - it accepted a broadcast address write while not in programming mode"
        }
        finally { Close-KnxDeviceSession -Session $b }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-21.4 $tag" -Title 'Basic restart returns the device to service' `
                       -Clause '03_05_02 clause 3.7, A_Restart (basic)' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $allow = $false
        if ($Ctx.PSObject.Properties['AllowDestructive']) { $allow = [bool]$Ctx.AllowDestructive }
        if (-not $allow) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'restarts the device - needs -IncludeDestructive' }
        & $protectGate
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # The basic restart carries no erase code and destroys no configuration: the device reboots
            # and must come back on the same address. It is gated all the same, because a reboot
            # interrupts whatever the installation was doing.
            Add-KnxEvidence -Sent (New-TpduService -Apci $K.Apci.RESTART -Sequence $s.SeqSend) -Note 'A_Restart, basic form'
            [void](Send-KnxDeviceTpdu -Session $s -Tpdu (New-TpduService -Apci $K.Apci.RESTART -Sequence $s.SeqSend) -TimeoutMs 3000)
        }
        finally { Close-KnxDeviceSession -Session $s }

        $back = $false
        $deadline = [DateTime]::UtcNow.AddSeconds(45)
        while (-not $back -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Seconds 3
            $p = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target
            if ($p.Ok) {
                try {
                    $r = Invoke-KnxDeviceService -Session $p -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@()) `
                                                 -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 3000 -Connectionless
                    if ($null -ne $r.Response) { $back = $true }
                }
                finally { Close-KnxDeviceSession -Session $p }
            }
        }
        Add-KnxEvidence -Note ("device answered again after the restart: {0}" -f $back)
        & $powerVoid
        & $goneResult $back "the device did not come back on $Target within 45 s after a basic restart" $true
    }
    # The routing counter lives on the LINK frame, not in the service result, so the answer has to be
    # picked out of the frames the exchange collected. Invoke-KnxDeviceService returns Frames (plural)
    # - every L_Data.ind it classified - plus ResponseApci for the one that was the answer.

    # ── D-22 Routing counter (08_03_03 Network Layer) ───────────────────────────
    # The whole document was untested. 08_03_03 asks one question in four shapes: whatever routing
    # counter a request carries - 6 down to 0, and the special value 7 - the ANSWER must leave the
    # device with counter 6. A device that echoes the received value makes itself unreachable behind
    # a coupler as soon as the counter runs out, and that never shows up in a single-line rig.

    foreach ($rc in @(6, 5, 4, 3, 2, 1, 0, 7)) {
        Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-22.1 rc$rc $tag" `
                           -Title "Answer to a connection-oriented request carries routing counter 6 (request had $rc)" `
                           -Clause '08_03_03 clause 3.2, p.6-7' -Body {
            if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
            $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
            if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
            try {
                $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@(0x00)) `
                                             -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 6000 -HopCount $rc
                $f = Get-KnxAnswerFrame -Result $r -Apci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE
                if ($null -eq $f) { Set-KnxTestNotApplicable "no DeviceDescriptor_Response with routing counter $rc - nothing to judge" }
                Add-KnxEvidence -Note ("request rc {0} -> answer rc {1}" -f $rc, $f.HopCount)
                Assert-KnxEqual 6 ([int]$f.HopCount) "the answer carries routing counter $($f.HopCount), not 6 (08_03_03 clause 3.2)"
            }
            finally { Close-KnxDeviceSession -Session $s }
        }
    }

    foreach ($rc in @(6, 3, 0, 7)) {
        Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-22.2 rc$rc $tag" `
                           -Title "Answer to a connectionless request carries routing counter 6 (request had $rc)" `
                           -Clause '08_03_03 clause 3.3, p.7-8' -Body {
            if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
            $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target
            if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
            try {
                # PropertyValue_Read on the device object, the same shape 08_03_03 clause 3.3 uses.
                $data = [byte[]]@(0x00, [byte]$K.Pid.SERIAL_NUMBER, 0x10, 0x01)
                $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.PROPERTY_VALUE_READ -Data $data `
                                             -ExpectApci $K.Apci.PROPERTY_VALUE_RESPONSE -TimeoutMs 6000 `
                                             -Connectionless -HopCount $rc
                $f = Get-KnxAnswerFrame -Result $r -Apci $K.Apci.PROPERTY_VALUE_RESPONSE
                if ($null -eq $f) { Set-KnxTestNotApplicable "no PropertyValue_Response with routing counter $rc - nothing to judge" }
                Add-KnxEvidence -Note ("request rc {0} -> answer rc {1}" -f $rc, $f.HopCount)
                Assert-KnxEqual 6 ([int]$f.HopCount) "the answer carries routing counter $($f.HopCount), not 6 (08_03_03 clause 3.3)"
            }
            finally { Close-KnxDeviceSession -Session $s }
        }
    }

    # 08_03_03 clause 3.1, p.5: "A Group object (GO) shall be present in the BDUT that is read- and
    # transmit enabled. [...] Send telegrams with Routing Count 6, 5, 4, 3, 2, 1, 0 to the BDUT.
    # Acceptance: The BDUT shall answer with Routing Count 6 in all cases." and, for count 7,
    # "Acceptance: The BDUT shall answer with Routing Count 6." The group-oriented shape reaches the
    # network layer through N_Data_Group, which is a different split than 3.2 and 3.3 exercise.
    foreach ($rc in @(6, 5, 4, 3, 2, 1, 0, 7)) {
        Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-22.3 rc$rc $tag" `
                           -Title "Answer to a group read carries routing counter 6 (request had $rc)" `
                           -Clause '08_03_03 clause 3.1, p.5' -Body {
            if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
            $gas = @()
            if ($profile.PSObject.Properties['GroupAddresses']) { $gas = @($profile.GroupAddresses) }
            if ($gas.Count -eq 0) { Set-KnxTestSkip 'no group address was discovered in D-19.1' }
            $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target
            if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
            try {
                # The read- and transmit-enabled object is not assumed: the addresses come from the
                # device's own address table and are tried until THIS device answers. The address that
                # already answered goes first - each of the eight cases used to start at the top of the
                # table and pay a dead 2000 ms window for every entry before it.
                $tryGas = @()
                if ($profile.AnswerGa) { $tryGas += $profile.AnswerGa }
                $tryGas += @($gas | Where-Object { $_ -ne $profile.AnswerGa } | Select-Object -First 3)
                $answer = $null
                $answerGa = ''
                foreach ($ga in @($tryGas)) {
                    $dst = ConvertTo-KnxGa -Address $ga
                    $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $dst -IsGroup `
                                          -Tpdu (New-TpduGroupValueRead) -Priority 3 -HopCount $rc
                    Add-KnxEvidence -Sent $cemi
                    [void](Send-KnxTunnelCemi -Connection $s.Conn -Cemi $cemi -TimeoutMs 3000)
                    $deadline = [DateTime]::UtcNow.AddMilliseconds(2000)
                    while ([DateTime]::UtcNow -lt $deadline -and $null -eq $answer) {
                        $in = Receive-KnxTunnelCemi -Connection $s.Conn -TimeoutMs 300
                        if ($null -eq $in) { continue }
                        $ld = Read-CemiLData -Cemi $in.Cemi
                        if ($null -eq $ld -or $ld.MessageCode -ne $K.Cemi.L_DATA_IND) { continue }
                        if (-not ($ld.IsGroup -and $ld.Destination -eq $dst)) { continue }
                        if ($null -eq $ld.Tpdu -or $ld.Tpdu.Length -lt 2 -or ($ld.Tpdu[1] -band 0xC0) -ne 0x40) { continue }
                        # Another device on the same group address answers with its own routing counter
                        # and would decide this case for the device under test.
                        if ($ld.Source -ne $s.Dst) { continue }
                        $answer = $ld
                        $answerGa = $ga
                    }
                    if ($null -ne $answer) { break }
                }
                # Kept for the seven sibling cases, and for the run where D-19.2 never established it.
                if ($null -ne $answer -and -not $profile.AnswerGa) { $profile.AnswerGa = $answerGa }
                if ($null -eq $answer) { Set-KnxTestNotApplicable "no A_GroupValue_Response from $Target for a read with routing counter $rc - nothing to judge" }
                Add-KnxEvidence -Received $answer.Tpdu -Note ("request rc {0} -> answer rc {1}" -f $rc, $answer.HopCount)
                Assert-KnxEqual 6 ([int]$answer.HopCount) "the answer carries routing counter $($answer.HopCount), not 6 (08_03_03 clause 3.1, p.5)"
            }
            finally { Close-KnxDeviceSession -Session $s }
        }
    }

    # 08_03_03 clause 3.4, p.8: "Send telegrams with Routing Count 6, 5, 4, 3, 2, 1, 0 to the BDUT.
    # Acceptance: The BDUT shall answer with Routing Count 6 in all cases", and for count 7 again
    # "Acceptance: The BDUT shall answer with Routing Count 6." N_Data_Broadcast is the fourth split
    # of the receiving direction and was the one shape D-22 never asked about.
    # DEVIATION, declared: the clause drives it with A_IndividualAddress_Read, which by 03_05_02
    # clause 2.2 p.12 is answered only while the device is in programming mode - unattended that case can
    # never be judged. A_IndividualAddress_SerialNumber_Read is the broadcast service the device
    # answers without a hand at it, and the network-layer question is the same one.
    foreach ($rc in @(6, 5, 4, 3, 2, 1, 0, 7)) {
        Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-22.4 rc$rc $tag" `
                           -Title "Answer to a broadcast read carries routing counter 6 (request had $rc)" `
                           -Clause '08_03_03 clause 3.4, p.8' -Body {
            if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
            # Read at most once per target instead of once per case on a connection of its own: the
            # serial does not change between the eight cases, and a read that throws is a missing
            # input, not an unhandled error in a routing-counter case.
            $serial = & $serialOf
            if ($null -eq $serial) { Set-KnxTestNotApplicable 'the serial number is not readable, so no broadcast service can be addressed to this device alone' }

            $targetRaw = ConvertTo-KnxPa -Address $Target
            $b = Open-KnxDeviceSession -Ip $ip -Port $port -Pa '0.0.0'
            if (-not $b.Ok) { Set-KnxTestSkip $b.Reason }
            try {
                Add-KnxEvidence -Note 'driven with A_IndividualAddress_SerialNumber_Read: the clause uses A_IndividualAddress_Read, which only devices in programming mode answer (03_05_02 clause 2.2, p.12)'
                $r = Invoke-KnxDeviceService -Session $b -Apci $K.Apci.IND_ADDR_SERIAL_READ -Data $serial `
                                             -ExpectApci $K.Apci.IND_ADDR_SERIAL_RESPONSE -TimeoutMs 5000 `
                                             -Connectionless -ExpectSource $targetRaw -HopCount $rc
                foreach ($o in $r.Others) { Add-KnxEvidence -Note ("also answered by {0}" -f (ConvertFrom-KnxPa -Raw $o.Source)) }
                $f = Get-KnxAnswerFrame -Result $r -Apci $K.Apci.IND_ADDR_SERIAL_RESPONSE
                if ($null -eq $f) { Set-KnxTestNotApplicable "no broadcast answer from $Target with routing counter $rc - nothing to judge" }
                Add-KnxEvidence -Received $f.Tpdu -Note ("request rc {0} -> answer rc {1}" -f $rc, $f.HopCount)
                Assert-KnxEqual 6 ([int]$f.HopCount) "the answer carries routing counter $($f.HopCount), not 6 (08_03_03 clause 3.4, p.8)"
            }
            finally { Close-KnxDeviceSession -Session $b }
        }
    }
    # ── D-23 Transport control field, negative cases (08_03_04 clause 2) ────────
    # The transport layer must refuse a frame whose TPCI does not fit the addressing mode it arrived
    # in. This is a parser test with no state behind it, and it is exactly the place where a switch
    # that is one case too generous lets a stray frame reach the application layer.

    # Raw TPCI: New-TpduService derives the control field from a sequence number, so a deliberately
    # wrong one has to be assembled here.


    # Positive control. Every case below asserts SILENCE, and a test that expects silence also passes
    # when it sends nothing at all or watches the wrong address. This one drives the identical path
    # with the CORRECT control field and demands an answer: if it fails, the silence below means
    # nothing and the group is not to be believed.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-23.0 $tag" `
                       -Title 'Control: the same service with a correct control field IS answered' `
                       -Clause '08_03_04 clause 2.4 a), p.11 - positive case' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            $data = [byte[]]@(0x00, [byte]$K.Pid.SERIAL_NUMBER, 0x10, 0x01)
            $tpdu = New-TpduRawTpci -Tpci 0x00 -Apci $K.Apci.PROPERTY_VALUE_READ -Data $data
            $frames = Get-KnxFramesFrom -Session $s -Tpdu $tpdu -Ms 3000
            Add-KnxEvidence -Note ("{0} frame(s) came back" -f @($frames).Count)
            Assert-KnxTrue (@($frames).Count -gt 0) 'the control did not get an answer either - the negative cases in this group prove nothing'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    foreach ($case in @(
            @{ Id = 'D-23.1'; Tpci = 0x40; What = 'T_Data_Connected (40h)' },
            @{ Id = 'D-23.2'; Tpci = 0xC0; What = 'an undefined control field (C0h)' })) {
        $tpci = $case.Tpci; $what = $case.What
        Invoke-KnxTestCase -Suite $SuiteTitle -Id "$($case.Id) $tag" `
                           -Title "A connectionless service with $what is not answered" `
                           -Clause '08_03_04 clause 2.4 b), p.11' -Body {
            if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
            $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target
            if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
            try {
                # The same PropertyValueRead that D-22.2 gets a clean answer to - only the control
                # field is wrong, so a difference here is the transport layer and nothing else.
                $data = [byte[]]@(0x00, [byte]$K.Pid.SERIAL_NUMBER, 0x10, 0x01)
                $tpdu = New-TpduRawTpci -Tpci $tpci -Apci $K.Apci.PROPERTY_VALUE_READ -Data $data
                $frames = Get-KnxFramesFrom -Session $s -Tpdu $tpdu -Ms 3000
                foreach ($f in @($frames)) { Add-KnxEvidence -Received $f.Tpdu }
                Add-KnxEvidence -Note ("{0} frame(s) came back" -f @($frames).Count)
                if (@($frames).Count -eq 0) { & $liveGate "the silence after a control field that says $what" $s }
                Assert-KnxEqual 0 @($frames).Count "the device answered a service whose control field says $what"
            }
            finally { Close-KnxDeviceSession -Session $s }
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-23.3 $tag" `
                       -Title 'A broadcast read with an undefined control field is not answered' `
                       -Clause '08_03_04 clause 2.2 b), p.9 (precondition programming mode, telegrams 7-9)' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        # 08_03_04 2.2 b) p.9: "Test Precondition: Activate Programming Mode". Outside it the device
        # ignores A_IndividualAddress_Read whatever the control field says, and silence proves nothing.
        # A throw while switching it on may still have left the device in programming mode, so it is
        # caught here and handled like a refused write.
        & $protectGate
        try { $entered = Set-KnxDeviceProgMode -Target $Target -On $true -Ip $ip -Port $port }
        catch { $entered = "switching programming mode on threw: $($_.Exception.Message)" }
        if ($entered) {
            # The write may have landed even when the read-back failed, so switch it off before leaving.
            $offNote = ''
            try { $offNote = Set-KnxDeviceProgMode -Target $Target -On $false -Ip $ip -Port $port }
            catch { $offNote = "switching programming mode off threw: $($_.Exception.Message)" }
            # FAIL only when the device itself reports it is still on; an unreadable or unreachable device
            # may never have taken the write, and that is no statement about it.
            if ($offNote) { Add-KnxEvidence -Note "programming mode may be left on: $offNote" }
            Assert-KnxTrue ($offNote -notlike '*programming mode is still on*') "$Target reports it is still in programming mode after switching it off - $offNote"
            Set-KnxTestNotApplicable "programming mode could not be set over the bus, so the clause's precondition is not met: $entered"
        }
        Add-KnxEvidence -Note 'programming mode set over the bus (PID_PROG_MODE), confirmed by reading it back'
        $targetRaw = ConvertTo-KnxPa -Address $Target
        $bodyError = $null
        try {
            $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa '0.0.0'
            if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
            try {
                # Telegrams 7/8: the same read with the defined control field is answered. Without that the
                # silence below could be a device that does not answer broadcast reads at all.
                $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.INDIVIDUAL_ADDR_READ -Data ([byte[]]@()) `
                                             -ExpectApci $K.Apci.INDIVIDUAL_ADDR_RESPONSE -TimeoutMs 3000 -Connectionless `
                                             -ExpectSource $targetRaw
                foreach ($o in $r.Others) { Add-KnxEvidence -Note ("{0} is in programming mode too" -f (ConvertFrom-KnxPa -Raw $o.Source)) }
                if ($null -eq $r.Response) {
                    Set-KnxTestNotApplicable "$Target is in programming mode but did not answer the valid broadcast address read (telegrams 7/8), so the stimulus path is not proven"
                }
                Add-KnxEvidence -Received $r.Response -Note 'telegrams 7/8: valid broadcast address read answered'
                [void](Wait-KnxTunnel -Connection $s.Conn -Ms 300)
                # Telegram 9: C1h is the undefined control field the clause uses for this shape.
                $tpdu = New-TpduRawTpci -Tpci 0xC1 -Apci $K.Apci.INDIVIDUAL_ADDR_READ
                $frames = Get-KnxFramesFrom -Session $s -Tpdu $tpdu -Ms 3000 -FromAddress $targetRaw
                foreach ($f in @($frames)) { Add-KnxEvidence -Received $f.Tpdu }
                Add-KnxEvidence -Note ("telegram 9: {0} frame(s) came back" -f @($frames).Count)
                if (@($frames).Count -eq 0) { & $liveGate 'the silence after a broadcast read with an undefined control field' $s }
                Assert-KnxEqual 0 @($frames).Count 'the device answered a broadcast read whose control field is undefined'
            }
            finally { Close-KnxDeviceSession -Session $s }
        }
        catch { $bodyError = $_ }
        finally {
            # Off on every exit: a device left in programming mode answers every broadcast address read
            # for the rest of the run. Caught, so a failure here cannot replace the body's result.
            $offNote = ''
            try { $offNote = Set-KnxDeviceProgMode -Target $Target -On $false -Ip $ip -Port $port }
            catch { $offNote = "switching programming mode off threw: $($_.Exception.Message)" }
            try { Add-KnxEvidence -Note $(if ($offNote) { "programming mode NOT switched off: $offNote" } else { 'programming mode switched off, confirmed by reading it back' }) } catch { }
        }
        if ($offNote) {
            $extra = if ($null -ne $bodyError) { " The case itself ended with: $($bodyError.Exception.Message)" } else { '' }
            Assert-KnxTrue $false "$Target was not proven to be out of programming mode again - $offNote.$extra"
        }
        if ($null -ne $bodyError) { throw $bodyError }
    }
    # ── D-24 Illegal APCI in point-to-point connectionless (08_03_07 clause 2.20) ──
    # The clause lists 42 stimuli, 39 distinct (the row with low octet 08 appears twice). p.72 wants no reaction, but footnote 12 lets a device answer a listed APCI it supports as valid; 03_03_07 Table 1 p.9 allows only A_Memory_Read (O; A_ADC_Read X) in T_Data_Individual. 02 80/02 88 (A_Memory_Write to 0000h) run in D-24.3.

    # Sends each APCI as hi lo 00 00 (p.72); answers are sorted by FAMILY (top four bits, the low six are payload, apdu.cpp).
    # $Supported maps a stimulus family to @(name, response family); only that service's own response counts as documented.
    $illegalApciSweep = {
        param($Session, [int[]]$Apcis, [hashtable]$Supported)
        $res = [pscustomobject]@{ Allowed = @(); Unexpected = @() }
        foreach ($apci in $Apcis) {
            $tpdu = [byte[]]@(($apci -shr 8), ($apci -band 0xFF), 0x00, 0x00)
            $frames = Get-KnxFramesFrom -Session $Session -Tpdu $tpdu -Ms 900
            if (@($frames).Count -eq 0) { continue }
            $f = @($frames)[0]
            $ra = ((([int]$f.Tpdu[0] -shl 8) -bor [int]$f.Tpdu[1]) -band 0x3FF)
            $fam = Get-KnxApciFamily -Apci $apci
            if ($Supported.ContainsKey($fam) -and ($ra -band 0x3C0) -eq $Supported[$fam][1]) { $res.Allowed += ('0x{0:X3} ({1}) -> 0x{2:X3}' -f $apci, $Supported[$fam][0], $ra) }
            else { $res.Unexpected += ('0x{0:X3} -> 0x{1:X3}' -f $apci, $ra) }
        }
        if ($res.Allowed.Count -gt 0) { Add-KnxEvidence -Note ('answered, and documented as supported: ' + ($res.Allowed -join ' , ')) }
        if ($res.Unexpected.Count -gt 0) { Add-KnxEvidence -Note ('answered but NOT a documented service: ' + ($res.Unexpected -join ' , ')) }
        Add-KnxEvidence -Note ('{0} APCIs sent, {1} answered ({2} of them documented)' -f $Apcis.Count, ($res.Allowed.Count + $res.Unexpected.Count), $res.Allowed.Count)
        return $res
    }
    # p.72: high octets 0..2 over thirteen distinct low octets; with high octet 0, the low octets 0x22, 0x44 and 0x88
    # hit the group-value families in point-to-point connectionless.
    $illegalApcis = @(foreach ($hi in 0, 1, 2) { foreach ($lo in 0x00, 0x01, 0x02, 0x04, 0x08, 0x10, 0x11, 0x20, 0x22, 0x40, 0x44, 0x80, 0x88) { ($hi -shl 8) -bor $lo } })

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-24.1 $tag" `
                       -Title 'Illegal APCIs in point-to-point connectionless draw no reaction' `
                       -Clause '08_03_07 clause 2.20, p.72 (acceptance + footnote 12); 03_03_07 Table 1 p.9' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        # Services this device is documented to support in this mode. An answer from one of these is
        # what footnote 12 permits; the case still records it.
        # 03_03_07 Table 1 p.9: A_Memory_Read is O in T_Data_Individual; A_ADC_Read is X there (connected only).
        $supported = @{ 0x200 = @('A_Memory_Read', 0x240) }
        $apcis = @($illegalApcis | Where-Object { (Get-KnxApciFamily -Apci $_) -ne 0x280 })
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            $res = & $illegalApciSweep $s $apcis $supported
            # Once after the sweep, not once per stimulus: if NOTHING answered, the channel may have
            # been dead for the whole loop and the clean sheet would say nothing about the device.
            if (($res.Allowed.Count + $res.Unexpected.Count) -eq 0) { & $liveGate 'a sweep in which no stimulus at all drew a reaction' $s }
            Assert-KnxEqual 0 $res.Unexpected.Count ("the device reacted to APCIs it does not document as supported: " + ($res.Unexpected -join ', '))
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-24.2 $tag" `
                       -Title 'An invalid APCI in group communication leaves the object value alone' `
                       -Clause '08_03_07 clause 1.4.1.7, p.23' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        # Needs a group address this device acts on, and a way to read the value back afterwards.
        # Not implemented, so the -TestGa probe above it only risked a StrictMode error on a context
        # that carries no TestGa - the result is the same either way.
        Set-KnxTestNotRun -MissingInput '-TestGa' -Reason 'needs a group address of this device to write a value, sweep invalid APCIs and read the value back'
    }
    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-24.3 $tag" `
                       -Title 'The A_Memory_Write stimuli of the illegal-APCI sweep draw no reaction but A_Memory_Response' `
                       -Clause '08_03_07 clause 2.20, p.72 (acceptance + footnote 12)' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        if (-not $Ctx.AllowDestructive) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason '02 80 and 02 88 are A_Memory_Write to address 0000h' }
        # A_Memory_Write is a genuine service (footnote 12); a device in verify mode answers it with A_Memory_Response.
        $supported = @{ 0x280 = @('A_Memory_Write', 0x240) }
        $apcis = @($illegalApcis | Where-Object { (Get-KnxApciFamily -Apci $_) -eq 0x280 })
        & $protectGate
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            $res = & $illegalApciSweep $s $apcis $supported
            if (($res.Allowed.Count + $res.Unexpected.Count) -eq 0) { & $liveGate 'the silence on the A_Memory_Write stimuli' $s }
            Assert-KnxEqual 0 $res.Unexpected.Count ("the device reacted to the A_Memory_Write stimuli with something other than A_Memory_Response: " + ($res.Unexpected -join ', '))
        }
        finally { Close-KnxDeviceSession -Session $s }
    }
    # ── D-25 Load State Machine (08_TSSG) ───────────────────────────────────────
    # 08_01 clause 3.3 Fig. 5 p.10 makes TSS G mandatory for our test class (non-certified PhL +
    # non-certified stack), and it was completely untested. The machine runs over the bus alone:
    # A_PropertyValue_Write on PID 5 (PID_LOAD_STATE_CONTROL) of object 01 address table,
    # 02 association table, 03 application, 04 PEI (08_TSSG clause 2.1, p.5-6).
    # States: 0 unloaded, 1 loaded, 2 loading, 3 error. Events: 0 NoOperation, 1 StartLoading,
    # 2 LoadCompleted, 3 AdditionalLoadControls, 4 Unload.
    # Only the transitions that CANNOT destroy the configuration run by default - see D-25.4.

    
    foreach ($obj in @(@{ I = 1; N = 'address table' }, @{ I = 2; N = 'association table' }, @{ I = 3; N = 'application' })) {
        $oi = $obj.I; $on = $obj.N

        Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-25.1 obj$oi $tag" `
                           -Title "Load state of the $on is readable" `
                           -Clause '08_TSSG clause 2.1, p.5-6; 03_05_01 PID_LOAD_STATE_CONTROL' -Body {
            if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
            $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
            if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
            try {
                $st = Read-KnxLoadState -Session $s -ObjectIndex $oi
                if ($st -lt 0) { Set-KnxTestNotApplicable "object $oi does not answer PID_LOAD_STATE_CONTROL - the device may not carry this object" }
                Add-KnxEvidence -Note ("load state of object {0} ({1}) = {2}" -f $oi, $on, $st)
                Assert-KnxTrue ($st -ge 0 -and $st -le 3) "load state $st is outside the defined range 0..3"
            }
            finally { Close-KnxDeviceSession -Session $s }
        }

        Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-25.2 obj$oi $tag" `
                           -Title "NO_OPERATION leaves the load state of the $on unchanged" `
                           -Clause '08_TSSG clause 2.2.1, p.6-7' -Body {
            if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
            if (-not $Ctx.AllowDestructive) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'writes PID_LOAD_STATE_CONTROL, even though NO_OPERATION changes nothing' }
            & $protectGate
            $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
            if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
            try {
                $before = Read-KnxLoadState -Session $s -ObjectIndex $oi
                if ($before -lt 0) { Set-KnxTestNotApplicable "object $oi does not answer PID_LOAD_STATE_CONTROL" }
                $after = Write-KnxLoadEvent -Session $s -ObjectIndex $oi -Event 0
                Add-KnxEvidence -Note ("state {0} -> NO_OPERATION -> {1}" -f $before, $after)
                Assert-KnxEqual $before $after "NO_OPERATION moved the load state from $before to $after"
            }
            finally { Close-KnxDeviceSession -Session $s }
        }

        Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-25.3 obj$oi $tag" `
                           -Title "An unknown load event on the $on is ignored, not treated as an error" `
                           -Clause '08_TSSG clause 1.1 Note 3, p.4 - mandatory for implementations from 2012' -Body {
            if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
            if (-not $Ctx.AllowDestructive) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'writes PID_LOAD_STATE_CONTROL with an unknown event' }
            & $protectGate
            $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
            if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
            try {
                $before = Read-KnxLoadState -Session $s -ObjectIndex $oi
                if ($before -lt 0) { Set-KnxTestNotApplicable "object $oi does not answer PID_LOAD_STATE_CONTROL" }
                # 0x0F is not a defined load event.
                $after = Write-KnxLoadEvent -Session $s -ObjectIndex $oi -Event 0x0F
                Add-KnxEvidence -Note ("state {0} -> unknown event 0x0F -> {1}" -f $before, $after)
                Assert-KnxTrue ($after -ne 3) "an unknown load event drove the object into ERROR (state 3); Note 3 makes ignoring it mandatory for new implementations"
                Assert-KnxEqual $before $after "an unknown load event moved the load state from $before to $after"
            }
            finally { Close-KnxDeviceSession -Session $s }
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-25.4 $tag" `
                       -Title 'The load-state transitions that unload a table' `
                       -Clause '08_TSSG clause 2.2-2.6, p.6-43' -Body {
        if (-not $Ctx.PSObject.Properties['AllowTableUnload'] -or -not $Ctx.AllowTableUnload) {
            Set-KnxTestNotRun -MissingInput '-IncludeTableUnload' `
                              -Reason 'UNLOAD / START_LOADING / LOAD_COMPLETED wipe the address, association and application tables - the device then needs an ETS download before it works again. Deliberately not covered by -IncludeDestructive, which every profile sets.'
        }
        Set-KnxTestNotRun -MissingInput '-IncludeTableUnload' -Reason 'not implemented yet - the destructive half of 08_TSSG'
    }
    # ── D-26 Run State Machine (08_TSSI) ────────────────────────────────────────
    # Mandatory for this test class alongside TSS G (08_01 clause 3.3 Fig. 5, p.10) and equally
    # untested. Driven over the bus through PID 6 (PID_RUN_STATE_CONTROL) of object 03, the
    # application object (08_TSSI clause 2.2.1, p.5). It decides whether the application runs at all
    # after a download or a restart.

    
    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-26.1 $tag" `
                       -Title 'Run state of the application object is readable' `
                       -Clause '08_TSSI clause 2.2.1, p.5; 03_05_01 PID_RUN_STATE_CONTROL' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # OT_APPLICATION_PROG = 3; its INDEX is device specific (index 3 may hold the group object table), so it is
            # looked up by type. Inside the try, so its N-A closes the session.
            $appIdx = Get-KnxObjectIndexByType -Session $s -ObjectType 3
            if ($appIdx -lt 0) { Set-KnxTestNotApplicable 'the device carries no application program object (type 3)' }
            Add-KnxEvidence -Note ("application program object is at index {0}" -f $appIdx)
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.PROPERTY_VALUE_READ `
                                         -Data ([byte[]]@([byte]$appIdx, 6, 0x10, 0x01)) `
                                         -ExpectApci $K.Apci.PROPERTY_VALUE_RESPONSE -TimeoutMs 5000
            # No value means a missing property or a read level above this session (03_03_07 p.63), no answer a lost frame.
            # Neither is judged: whether PID 6 is mandatory depends on the mask (Volume 6 A.2.6 p.146, 4.2 p.37).
            if ($null -eq $r.Response -or $r.Response.Length -lt 7) {
                if ($null -ne $r.Response) { Add-KnxEvidence -Received $r.Response -Note 'answered without a value' } else { Add-KnxEvidence -Note 'no answer to the read' }
                Set-KnxTestNotApplicable 'PID_RUN_STATE_CONTROL (PID 6) returned no value on the application object, so 08_TSSI cannot be judged'
            }
            $st = [int]$r.Response[6]
            Add-KnxEvidence -Received $r.Response -Note ("run state = {0}" -f $st)
            # Table 95 p.299 defines 0..5; 5 (Shutting down) is mandatory above 2 s, so 5 is a valid state too.
            Assert-KnxTrue ($st -le 5) "run state $st is outside the defined range (Table 95 p.299 defines 0..5)"
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    # Run-state helpers of D-26.2 and D-26.3; they use $s and $appIdx of the case that calls them.
    # A socket error (EHOSTDOWN while the device is off) counts as no answer, here and in $rsEvent.
    $rsRead = {
        $r = $null
        try { $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.PROPERTY_VALUE_READ `
                       -Data ([byte[]]@([byte]$appIdx, 6, 0x10, 0x01)) `
                       -ExpectApci $K.Apci.PROPERTY_VALUE_RESPONSE -TimeoutMs 5000 } catch { Add-KnxEvidence -Note "run-state read failed: $($_.Exception.Message)" }
        if ($null -eq $r) { return -1 }
        # Only an answer for this object and PID counts (03_03_07 p.63); a parked answer to another read does not.
        if ($null -ne $r.Response -and $r.Response.Length -ge 7 -and [int]$r.Response[2] -eq $appIdx -and [int]$r.Response[3] -eq 6) { [int]$r.Response[6] } else { -1 }
    }
    # Kind: 'none' without an answer for this object and PID, 'refused' on nr_of_elem 0 (03_03_07 3.4.4.2 p.66), else
    # 'ok' with the state the answer carries. PDT_CONTROL is written with 10 octets (03_07_03 Table 6 p.18).
    $rsEvent = {
        param([int]$RunEvent)
        $w = $null
        try { $w = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.PROPERTY_VALUE_WRITE `
                       -Data ([byte[]]@([byte]$appIdx, 6, 0x10, 0x01, [byte]$RunEvent, 0, 0, 0, 0, 0, 0, 0, 0, 0)) `
                       -ExpectApci $K.Apci.PROPERTY_VALUE_RESPONSE -TimeoutMs 5000 } catch { Add-KnxEvidence -Note ("run-state event 0x{0:X2} could not be sent: {1}" -f $RunEvent, $_.Exception.Message) }
        $r = if ($null -ne $w) { $w.Response } else { $null }
        if ($null -eq $r -or $r.Length -lt 5 -or [int]$r[2] -ne $appIdx -or [int]$r[3] -ne 6) { [pscustomobject]@{ Kind = 'none'; Value = -1; Bytes = $r } }
        elseif (([int]$r[4] -shr 4) -eq 0) { [pscustomobject]@{ Kind = 'refused'; Value = -1; Bytes = $r } }
        elseif ($r.Length -ge 7) { [pscustomobject]@{ Kind = 'ok'; Value = [int]$r[6]; Bytes = $r } }
        else { [pscustomobject]@{ Kind = 'ok'; Value = -1; Bytes = $r } }
    }
    # Refused event: a finding if accepted before, or unknown (ignored, 03_05_01 p.301) once events were accepted; before any
    # acceptance the machine is read-only or protected (4.24.2.1 p.298); a known event refused when writable is optional (Table 96 p.299).
    $rsRefused = {
        param([string]$Clause, [int]$RunEvent, [hashtable]$Accepted)
        if ($Accepted.ContainsKey($RunEvent)) { Assert-KnxTrue $false ("{0}: event 0x{1:X2} was refused (nr_of_elem 0) after the device had accepted it" -f $Clause, $RunEvent) }
        if ($RunEvent -notin @(0, 1, 2) -and $Accepted.Count -gt 0) { Assert-KnxTrue $false ("{0}: the unknown event 0x{1:X2} was refused (nr_of_elem 0) by a run state machine that accepted events before; an unknown event is ignored (03_05_01 p.301) and 08_TSSI expects the run state in the answer" -f $Clause, $RunEvent) }
        if ($Accepted.Count -eq 0) { Set-KnxTestNotApplicable ("{0}: the first run-state event 0x{1:X2} was refused (nr_of_elem 0): the machine is read-only or not writable at this access level (03_05_01 4.24.2.1 p.298, 03_03_07 p.66)" -f $Clause, $RunEvent) }
        Set-KnxTestNotApplicable ("{0}: event 0x{1:X2} was refused (nr_of_elem 0); 03_05_01 p.299 says both 'It shall be possible to start ... and stop' and 'All events ... are optional', and 08_TSSI assumes support - not judged" -f $Clause, $RunEvent)
    }
    # After an event without an answer: notes whether the device answers on the same connection, only a new one, or none, and
    # returns the session to use. A lost frame, tunnel or restart cannot be told apart, so such an event is not judged.
    $rsLost = {
        if ((& $rsObserve -1 @()).Value -ge 0) { return [pscustomobject]@{ Note = 'the device still answers on the same connection'; Session = $s } }
        $s = & $rsReconnect
        $note = if ($null -ne $s) { 'the device answers again only on a new connection' } else { 'the device answers on no connection' }
        [pscustomobject]@{ Note = $note; Session = $s }
    }
    # Judges the state an event led to (08_TSSI): the answer's state or a read; a state in $Interim is re-read until left (30 s per
    # transition, 4.24.2.1 p.298). Starting and Shutting down (intermediate, 03_05_01 p.301-302) and an unreadable state are N-A.
    $rsJudge = {
        param([string]$Clause, [int]$RunEvent, [int]$Answer, [int[]]$Interim)
        $v = if ($Answer -ge 0) { $Answer } else { & $rsRead }
        $seconds = 0
        if ($v -in $Interim) { $o = & $rsObserve $v $Interim; $v = $o.Value; $seconds = $o.Seconds }
        Add-KnxEvidence -Note ("{0}: event 0x{1:X2} answered state {2}, judged {3} after {4:N1} s" -f $Clause, $RunEvent, $Answer, $v, $seconds)
        if ($v -eq 5) { Set-KnxTestNotApplicable ("{0}: the device showed Shutting down (state 5), which ends in a restart or power off (03_05_01 p.302), so no final state can be judged" -f $Clause) }
        if ($v -eq 4) { Set-KnxTestNotApplicable ("{0}: the device showed Starting (state 4), an intermediate state that may never appear (03_05_01 p.301) and is not a row of 08_TSSI 2.3 or 2.5, so it is not judged" -f $Clause) }
        if ($v -lt 0) { Set-KnxTestNotApplicable ("{0}: the run state could not be read after event 0x{1:X2}" -f $Clause, $RunEvent) }
        $v
    }
    # From $Value (or a read) re-reads while the state is in $Wait and changed < 35 s ago (30 s per transition, p.298, + one read);
    # 30 s per $Wait state (at least one) + 5 s in total, two unread values in a row tolerated, a late-seen change counted from then.
    $rsObserve = {
        param([int]$Value, [int[]]$Wait)
        if ($Value -lt 0) { $Value = & $rsRead }
        $total = [Diagnostics.Stopwatch]::StartNew()
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $limit = 30 * [Math]::Max(1, $Wait.Count) + 5
        $last = $Value
        $miss = 0
        while ($total.Elapsed.TotalSeconds -lt $limit) {
            if ($Value -lt 0) { if ($miss -ge 2) { break }; $miss++ }
            # 30 s per state plus one read (5 s), since a read that answers late shows an earlier state.
            elseif (-not ($Value -in $Wait -and $sw.Elapsed.TotalSeconds -lt 35)) { break }
            else { $miss = 0 }
            try { [void](Wait-KnxTunnel -Connection $s.Conn -Ms 1000) } catch { }
            $Value = & $rsRead
            # An unread value is no change; only a valid state other than the last one restarts the transition clock.
            if ($Value -ge 0 -and $Value -ne $last) { if ($last -ge 0) { $sw.Restart() }; $last = $Value }
        }
        [pscustomobject]@{ Value = $Value; Seconds = $total.Elapsed.TotalSeconds }
    }

    # Closes the old session and opens new ones until the device answers a PID 6 read; new attempts start for 45 s.
    $rsReconnect = {
        if ($null -ne $s) { try { Close-KnxDeviceSession -Session $s } catch { } }
        Start-Sleep -Seconds 3
        $deadline = (Get-Date).AddSeconds(45)
        while ((Get-Date) -lt $deadline) {
            try {
                $p = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
                if ($p.Ok) {
                    $r = $null
                    try { $r = Invoke-KnxDeviceService -Session $p -Apci $K.Apci.PROPERTY_VALUE_READ -Data ([byte[]]@([byte]$appIdx, 6, 0x10, 0x01)) `
                                   -ExpectApci $K.Apci.PROPERTY_VALUE_RESPONSE -TimeoutMs 4000 } catch { }
                    if ($null -ne $r -and $null -ne $r.Response) { return $p }
                    Close-KnxDeviceSession -Session $p
                }
            }
            # A socket error while the device is off (EHOSTDOWN) is the same as no answer: try again.
            catch { }
            Start-Sleep -Seconds 3
        }
        $null
    }

    # Brings the application back to Running; returns the final state and the session. Terminated takes a Restart, any other state
    # not reaching Running a device restart (Table 97 p.301); Halted may not leave on Restart (08_TSSI 2.2.2).
    $rsRestore = {
        try {
        $v = if ($null -ne $s) { (& $rsObserve -1 @(0, 2, 4, 5)).Value } else { -1 }
        # No answer on the old connection: the device may have restarted, so ask on a new one.
        if ($v -lt 0) { $s = & $rsReconnect; $v = if ($null -ne $s) { (& $rsObserve -1 @(0, 2, 4, 5)).Value } else { -1 } }
        if ($v -eq 3) {
            [void](& $rsEvent 1)
            $v = (& $rsObserve -1 @(0, 2, 4, 5)).Value
            # No answer after the Restart: ask on a new connection before deciding on a device restart.
            if ($v -lt 0) { $s = & $rsReconnect; $v = if ($null -ne $s) { (& $rsObserve -1 @(0, 2, 4, 5)).Value } else { -1 } }
        }
        if ($v -ge 0 -and $v -ne 1) {
            # A_Restart, connectionless on the open tunnel, so no second tunnel channel is needed.
            $err = ''
            try { [void](Invoke-KnxDeviceService -Session $s -Apci $K.Apci.RESTART -Data ([byte[]]@()) -TimeoutMs 2000 -Connectionless) }
            # The restart may or may not have gone out, so the state is read again below either way.
            catch { $err = "the device restart threw: $($_.Exception.Message)" }
            Add-KnxEvidence -Note ("restore: run state {0}, device restart sent" -f $v)
            $s = & $rsReconnect
            $v = if ($null -ne $s) { (& $rsObserve -1 @(0, 2, 4)).Value } else { -1 }
            return [pscustomobject]@{ Value = $v; Session = $s; Error = $err }
        }
        [pscustomobject]@{ Value = $v; Session = $s; Error = '' }
        }
        # The session is handed back even then, so the caller closes the one that is open.
        catch { [pscustomobject]@{ Value = -1; Session = $s; Error = $_.Exception.Message } }
    }
    # The run-state cases need a running application with the executable part loaded (08_TSSI 2.3.1; note c
    # p.300: Stop only when Loaded). Returns the reason they cannot run, or '' when they can.
    $rsPrecondition = {
        $before = (& $rsObserve -1 @(2, 4, 5)).Value
        Add-KnxEvidence -Note ("run state before: {0}" -f $before)
        if ($before -lt 0) { return 'PID_RUN_STATE_CONTROL (PID 6) returned no value - see D-26.1' }
        if ($before -ne 1) { return "08_TSSI 2.3 starts from RUNSTATE_RUNNING and the application reads $before" }
        $ls = Read-KnxLoadState -Session $s -ObjectIndex $appIdx
        Add-KnxEvidence -Note ("load state of the application object: {0} (1 = Loaded)" -f $ls)
        if ($ls -ne 1) { return "08_TSSI 2.3.1 needs the executable part loaded, and its load state reads $ls" }
        ''
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-26.2 $tag" `
                       -Title 'An invalid run-state event and a no-operation leave the application running' `
                       -Clause '08_TSSI 2.3.2, p.11-12; 03_05_01 p.301' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        if (-not $Ctx.AllowDestructive) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'writes PID_RUN_STATE_CONTROL, even though the events change nothing' }
        & $protectGate
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        $appIdx = -1
        $sent = $false
        $restoreNote = ''
        $bodyError = $null
        try {
            # OT_APPLICATION_PROG = 3. Its INDEX is device specific: on some devices it is 4, while
            # index 3 holds the group object table. Inside the try, so its N-A closes the session.
            $appIdx = Get-KnxObjectIndexByType -Session $s -ObjectType 3
            if ($appIdx -lt 0) { Set-KnxTestNotApplicable 'the device carries no application program object (type 3)' }
            Add-KnxEvidence -Note ("application program object is at index {0}" -f $appIdx)
            $why = & $rsPrecondition
            if ($why) { Set-KnxTestNotApplicable $why }
            # NOP first: it leaves Running as is (Table 97 p.301), so its refusal means a read-only or protected machine (4.24.2.1
            # p.298). Then 08_TSSI 2.3.2 p.11-12: FFh and NOP, each answered with Running; an unknown event is ignored (p.301).
            $accepted = @{}
            foreach ($e in @(0x00, 0xFF, 0x00)) {
                $sent = $true
                $a = & $rsEvent $e
                if ($null -ne $a.Bytes) { Add-KnxEvidence -Received $a.Bytes }
                if ($a.Kind -eq 'refused') { & $rsRefused '08_TSSI 2.3.2' $e $accepted }
                if ($a.Kind -eq 'none') {
                    $l = & $rsLost
                    $s = $l.Session
                    Set-KnxTestNotApplicable ("event 0x{0:X2} got no answer and {1}; a lost frame, a lost tunnel and a restart look the same from here" -f $e, $l.Note)
                }
                $accepted[$e] = $true
                # The answer carries the state 08_TSSI judges; it is read again only when it carries none.
                $v = & $rsJudge '08_TSSI 2.3.2' $e $a.Value @()
                Assert-KnxEqual 1 $v ("08_TSSI 2.3.2: event 0x{0:X2} led to run state {1}, expected Running (1)" -f $e, $v)
            }
        }
        catch { $bodyError = $_ }
        finally {
            # The events must change nothing; should one have stopped the application, it is brought back.
            if ($sent -and $appIdx -ge 0) {
                $rr = & $rsRestore
                $s = $rr.Session
                # Only a device that answers and is not running is a finding; one that answers on no connection is unknown.
                if ($rr.Value -ge 0 -and $rr.Value -ne 1) { $restoreNote = "run state after the restore: $($rr.Value) (1 = Running) $($rr.Error)".Trim() }
                elseif ($rr.Value -lt 0) { try { Add-KnxEvidence -Note "the device answered on no connection after the case, so its run state is unknown $($rr.Error)".Trim() } catch { } }
            }
            if ($restoreNote) { try { Add-KnxEvidence -Note $restoreNote } catch { } }
            if ($null -ne $s) { try { Close-KnxDeviceSession -Session $s } catch { } }
        }
        # A device left stopped decides the headline, with the body's own message carried along.
        if ($restoreNote) {
            $extra = if ($null -ne $bodyError) { " The case itself ended with: $($bodyError.Exception.Message -replace '^KNXTEST_[A-Z]+::', '')" } else { '' }
            Assert-KnxTrue $false "the application was not proven to be running again - $restoreNote.$extra"
        }
        if ($null -ne $bodyError) { throw $bodyError }
    }

    # 08_TSSI 2.3 starts from Running; the state in the A_PropertyValue_Response to the write is judged, intermediate states are
    # re-read as $rsObserve allows (30 s per transition, 03_05_01 4.24.2.1 p.298). The branch after Stop follows what Stop led to.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-26.3 $tag" `
                       -Title 'Run state machine from Running: Restart, Stop, and the events in the state Stop leads to' `
                       -Clause '08_TSSI 2.3.3, 2.3.5, 2.5.1, 2.5.2, 2.5.4, 2.2.1, 2.2.2; 03_05_01 Tables 95-97 p.299-301' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        if (-not $Ctx.AllowDestructive) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'stops the application for the duration of the case' }
        & $protectGate
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        $changed = $false
        $touched = $false
        $restored = $false
        $restoreNote = 'the restore never ran'
        $appIdx = -1
        $bodyError = $null
        try {
            # OT_APPLICATION_PROG = 3. Its INDEX is device specific: on some devices it is 4, while
            # index 3 holds the group object table.
            $appIdx = Get-KnxObjectIndexByType -Session $s -ObjectType 3
            if ($appIdx -lt 0) { Set-KnxTestNotApplicable 'the device carries no application program object (type 3)' }
            Add-KnxEvidence -Note ("application program object is at index {0}" -f $appIdx)
            # One row of 08_TSSI. The NOP probe before the rows decides writability; refusals are judged by $rsRefused,
            # an event without answer is reported by $rsLost. Returns the state judged by $rsJudge.
            $accepted = @{}
            $row = {
                param([string]$Clause, [int]$RunEvent, [int[]]$Interim = @())
                $a = & $rsEvent $RunEvent
                if ($null -ne $a.Bytes) { Add-KnxEvidence -Received $a.Bytes }
                if ($a.Kind -eq 'refused') { & $rsRefused $Clause $RunEvent $accepted }
                if ($a.Kind -eq 'none') {
                    $l = & $rsLost
                    # The body's session, not a copy local to this row.
                    Set-Variable -Name s -Value $l.Session -Scope 1
                    Set-KnxTestNotApplicable ("{0}: event 0x{1:X2} got no answer and {2}; a lost frame, a lost tunnel and a restart look the same from here" -f $Clause, $RunEvent, $l.Note)
                }
                $accepted[$RunEvent] = $true
                & $rsJudge $Clause $RunEvent $a.Value $Interim
            }

            $why = & $rsPrecondition
            if ($why) { Set-KnxTestNotApplicable $why }
            # The writability probe, 08_TSSI 2.3.2: NOP leaves Running as it is (Table 97 p.301).
            $touched = $true
            $changed = $true
            $v = & $row '08_TSSI 2.3.2' 0
            Assert-KnxEqual 1 $v "08_TSSI 2.3.2: no-operation in Running led to run state $v, expected Running (1)"
            $changed = $false

            # 2.3.3 p.12: Restart from Running ends in Running; Ready may come first (08_TSSI), Halted too (Table 97 p.301),
            # and Starting, which is mandatory for a start-up above 2 s (Table 95 p.299).
            $changed = $true
            $v = & $row '08_TSSI 2.3.3' 1 @(0, 2, 4)
            Assert-KnxEqual 1 $v "08_TSSI 2.3.3: Restart from Running led to run state $v, expected Running (1)"
            $changed = $false

            # 2.3.5 p.13: Stop from Running gives Terminated, optionally Halted (Table 97 footnote a p.301).
            $changed = $true
            $v = & $row '08_TSSI 2.3.5' 2
            Assert-KnxTrue ($v -in @(3, 0)) "08_TSSI 2.3.5: Stop from Running led to run state $v, expected Terminated (3) or Halted (0)"

            if ($v -eq 3) {
                $v = & $row '08_TSSI 2.5.4' 2
                Assert-KnxEqual 3 $v "08_TSSI 2.5.4: Stop in Terminated led to run state $v, expected Terminated (3)"
                $v = & $row '08_TSSI 2.5.1' 0xFF
                Assert-KnxEqual 3 $v "08_TSSI 2.5.1: an invalid event in Terminated led to run state $v, expected Terminated (3)"
                $v = & $row '08_TSSI 2.5.1' 0
                Assert-KnxEqual 3 $v "08_TSSI 2.5.1: no-operation in Terminated led to run state $v, expected Terminated (3)"
                # 2.5.2 p.25: Ready may come first (08_TSSI), Halted too (Table 97 p.301), Starting above 2 s (Table 95 p.299).
                $v = & $row '08_TSSI 2.5.2' 1 @(0, 2, 4)
                Assert-KnxEqual 1 $v "08_TSSI 2.5.2: Restart from Terminated led to run state $v, expected Running (1)"
                $changed = $false
            }
            else {
                # 2.2.1 prepares Halted with the program unloaded; here it is loaded, the expected state is the same.
                $v = & $row '08_TSSI 2.2.1' 0xFF
                Assert-KnxEqual 0 $v "08_TSSI 2.2.1: an invalid event in Halted led to run state $v, expected Halted (0)"
                $v = & $row '08_TSSI 2.2.1' 0
                Assert-KnxEqual 0 $v "08_TSSI 2.2.1: no-operation in Halted led to run state $v, expected Halted (0)"
                # Halted after Restart may be Table 97's intermediate step, so it is read again until it holds or is left.
                $v = & $row '08_TSSI 2.2.2' 1 @(0, 2)
                if ($v -eq 1) {
                    $changed = $false
                    Set-KnxTestNotApplicable '08_TSSI 2.2.2 p.6 expects Restart in Halted to stay Halted, Table 97 p.301 leads it to Running, and the device ran - the spec conflicts, so the row is not judged'
                }
                Assert-KnxEqual 0 $v "08_TSSI 2.2.2: Restart in Halted led to run state $v, expected Halted (0)"
            }
        }
        catch { $bodyError = $_ }
        finally {
            # A stopped application answers management but ignores every group telegram. Terminated takes a Restart; Halted (no
            # leave on Restart, 08_TSSI 2.2.2) or a state not reaching Running takes a device restart (Table 97, Device Restart: Running).
            if (-not $changed) { $restored = $true; $restoreNote = if ($touched) { 'the application was left running' } else { 'no run-state event was sent' } }
            else {
                try {
                    $rr = & $rsRestore
                    $s = $rr.Session
                    $v = $rr.Value
                    # Only a device that answers and is not running is a finding; one that answers on no connection is unknown.
                    $restored = ($v -eq 1 -or $v -lt 0)
                    $restoreNote = if ($v -lt 0) { "the device answered on no connection after the case, so its run state is unknown $($rr.Error)".Trim() } else { "run state after the restore: $v (1 = Running) $($rr.Error)".Trim() }
                }
                catch { $restoreNote = "the restore threw: $($_.Exception.Message)" }
            }
            try { Add-KnxEvidence -Note $restoreNote } catch { }
            if ($null -ne $s) { try { Close-KnxDeviceSession -Session $s } catch { } }
        }
        # A restore that failed left a device somebody has to go and fix, so it decides the headline
        # even when the body failed too - and the body's own message is carried along, not dropped.
        if (-not $restored) {
            $extra = if ($null -ne $bodyError) { " The case itself ended with: $($bodyError.Exception.Message -replace '^KNXTEST_[A-Z]+::', '')" } else { '' }
            Assert-KnxTrue $false "the application was not proven to be running again - $restoreNote. While it is stopped, $Target answers management and ignores every group telegram.$extra"
        }
        if ($null -ne $bodyError) { throw $bodyError }
    }

    # ── D-27 Restart, the shapes 08_03_07 does not yet cover here ───────────────

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-27.1 $tag" `
                       -Title 'A basic restart sent connectionless restarts the device' `
                       -Clause '08_03_07 clause 2.9.2, p.41' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        if (-not $Ctx.AllowDestructive) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'restarts the device' }
        & $protectGate
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # A_Restart with no data, connectionless. Nothing is expected back; the proof is that the
            # device goes away and comes back.
            [void](Invoke-KnxDeviceService -Session $s -Apci $K.Apci.RESTART -Data ([byte[]]@()) -TimeoutMs 2000 -Connectionless)
        }
        finally { Close-KnxDeviceSession -Session $s }
        Start-Sleep -Seconds 3
        $back = $false
        $deadline = (Get-Date).AddSeconds(45)
        while ((Get-Date) -lt $deadline) {
            $p = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
            if ($p.Ok) {
                $r = Invoke-KnxDeviceService -Session $p -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@(0x00)) `
                                             -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 4000
                Close-KnxDeviceSession -Session $p
                if ($null -ne $r.Response) { $back = $true; break }
            }
            Start-Sleep -Seconds 3
        }
        Add-KnxEvidence -Note ("device answered again after a connectionless restart: {0}" -f $back)
        & $powerVoid
        & $goneResult $back "the device did not come back within 45 s after a connectionless basic restart" $true
    }
    # ── D-28 Property access, the negative shapes ───────────────────────────────
    # 08_03_07 clause 2.13 sweeps what a property read must do with arguments that are out of range.
    # Two of these carry real weight: start index 0 returns the CURRENT ARRAY LENGTH (clause 2.13.8,
    # p.54) - that is how ETS learns how long the address and association tables are - and an illegal
    # argument must come back as a response with nr_of_elem = 0, never as silence or as data.

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-28.1 $tag" `
                       -Title 'Start index 0 answers with the current number of array elements' `
                       -Clause '08_03_07 clause 2.13.8, p.54' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # An unknown PID is ALSO answered with nr_of_elem = 0 (clause 2.13.3, p.52), so a device that
            # simply does not carry PID_TABLE on object 1 would look like a failure. Ask the description
            # first and only judge the length read where the property actually exists. Both 5.0.8 and the
            # certified MDT answered 0 here, which is what exposed the earlier version of this case.
            $d = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.PROPERTY_DESCRIPTION_READ `
                                         -Data ([byte[]]@(0x01, [byte]$K.Pid.TABLE, 0x00)) `
                                         -ExpectApci $K.Apci.PROPERTY_DESCRIPTION_RESPONSE -TimeoutMs 6000
            $hasTable = $false
            if ($null -ne $d.Response -and $d.Response.Length -ge 8) {
                # A description for a property that does not exist comes back with type 0 and length 0.
                $hasTable = (([int]$d.Response[5] -ne 0) -or ([int]$d.Response[6] -ne 0))
                Add-KnxEvidence -Received $d.Response -Note 'PropertyDescription of PID_TABLE on object 1'
            }
            if (-not $hasTable) { Set-KnxTestNotApplicable 'object 1 does not carry PID_TABLE, so there is no array length to read here (an unknown PID is answered with nr_of_elem = 0 by clause 2.13.3)' }

            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.PROPERTY_VALUE_READ `
                                         -Data ([byte[]]@(0x01, [byte]$K.Pid.TABLE, 0x10, 0x00)) `
                                         -ExpectApci $K.Apci.PROPERTY_VALUE_RESPONSE -TimeoutMs 5000
            if ($null -eq $r.Response) { Set-KnxTestNotApplicable 'no answer to a start-index-0 read although the property is described' }
            Add-KnxEvidence -Received $r.Response
            $nrElem = ([int]$r.Response[4]) -shr 4
            Assert-KnxTrue ($nrElem -gt 0) 'the property exists, yet start index 0 came back with nr_of_elem = 0 - ETS reads the table length here'
            Assert-KnxTrue ($r.Response.Length -ge 8) 'the answer to start index 0 carries no length value'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-28.2 $tag" `
                       -Title 'A start index past the end is answered with nr_of_elem = 0, not with data' `
                       -Clause '08_03_07 clause 2.13.4, p.52' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # Start index 0xFFF cannot exist on any object.
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.PROPERTY_VALUE_READ `
                                         -Data ([byte[]]@(0x00, [byte]$K.Pid.SERIAL_NUMBER, 0x1F, 0xFF)) `
                                         -ExpectApci $K.Apci.PROPERTY_VALUE_RESPONSE -TimeoutMs 5000
            if ($null -eq $r.Response) { Set-KnxTestNotApplicable 'the device stayed silent - clause 2.13.4 expects a response with nr_of_elem = 0' }
            Add-KnxEvidence -Received $r.Response
            $nrElem = ([int]$r.Response[4]) -shr 4
            Add-KnxEvidence -Note ("nr_of_elem = {0}, payload {1} octet(s)" -f $nrElem, [Math]::Max(0, $r.Response.Length - 6))
            Assert-KnxEqual 0 $nrElem 'an impossible start index was answered with data instead of nr_of_elem = 0'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-28.3 $tag" `
                       -Title 'An element count of zero is answered, not ignored' `
                       -Clause '08_03_07 clause 2.13.6, p.53' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.PROPERTY_VALUE_READ `
                                         -Data ([byte[]]@(0x00, [byte]$K.Pid.SERIAL_NUMBER, 0x00, 0x01)) `
                                         -ExpectApci $K.Apci.PROPERTY_VALUE_RESPONSE -TimeoutMs 5000
            if ($null -eq $r.Response) { Set-KnxTestNotApplicable 'the device stayed silent on an element count of zero' }
            Add-KnxEvidence -Received $r.Response
            $nrElem = ([int]$r.Response[4]) -shr 4
            Assert-KnxEqual 0 $nrElem "a read with element count 0 was answered with nr_of_elem = $nrElem"
        }
        finally { Close-KnxDeviceSession -Session $s }
    }
    # ── D-29 Transport layer: acknowledge timeout and a second connection ───────
    # 08_03_04 clause 4.2 p.14 and sequence 11 p.60-61: when OUR acknowledge for the device's answer
    # does not arrive, the device repeats the answer every 3 s and gives up after the third repeat
    # with a T_Disconnect. This runs through TPUart's transmitter and the CON/echo path, which is
    # where the known drop-on-busy and CON-rescue risks live.

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-29.1 $tag" `
                       -Title 'An unacknowledged answer is repeated three times, then the connection is dropped' `
                       -Clause '08_03_04 clause 4.2, p.14; clause 6.2.6.1 sequence 11, p.60-61' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # Deliberately withhold our T_Ack for the answer and watch what the device does.
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@(0x00)) `
                                         -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 5000 -NoAckResponse
            if ($null -eq $r.Response) { Set-KnxTestNotApplicable 'no first answer to acknowledge - nothing to time out' }

            $repeats = 0
            $disconnect = $false
            $first = [DateTime]::UtcNow
            $gaps = @()
            $last = $first
            $deadline = [DateTime]::UtcNow.AddSeconds(16)
            while ([DateTime]::UtcNow -lt $deadline) {
                $in = Receive-KnxTunnelCemi -Connection $s.Conn -TimeoutMs 800
                if ($null -eq $in) { continue }
                $ld = Read-CemiLData -Cemi $in.Cemi
                if ($null -eq $ld -or $ld.MessageCode -ne $K.Cemi.L_DATA_IND -or $ld.Source -ne $s.Dst) { continue }
                if ($null -eq $ld.Tpdu -or $ld.Tpdu.Length -lt 1) { continue }
                $tpci = [int]$ld.Tpdu[0]
                if (($tpci -band 0xC0) -eq 0x40) {
                    $repeats++
                    $now = [DateTime]::UtcNow
                    $gaps += [int]($now - $last).TotalMilliseconds
                    $last = $now
                }
                elseif ($tpci -eq 0x81) { $disconnect = $true; break }
            }
            Add-KnxEvidence -Note ("repeats {0}, gaps {1} ms, disconnect {2}" -f $repeats, ($gaps -join '/'), $disconnect)
            Assert-KnxTrue ($repeats -ge 1) 'the device never repeated an answer we deliberately left unacknowledged'
            Assert-KnxTrue $disconnect 'the device kept the connection open after the repeats instead of sending T_Disconnect'
            Assert-KnxEqual 3 $repeats "the answer was repeated $repeats time(s); clause 4.2 asks for three"
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-29.2 $tag" `
                       -Title 'A second client is refused while a connection is open, and the first survives' `
                       -Clause '08_03_04 clause 6.2.2 sequences 3 and 4, p.56-58' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        # Two sessions mean two tunnels, so two different individual addresses talk to the same device.
        $a = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $a.Ok) { Set-KnxTestSkip $a.Reason }
        $b = $null
        try {
            $b = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
            if (-not $b.Ok) { Set-KnxTestNotApplicable "a second tunnel could not be opened ($($b.Reason)) - the rig cannot pose as two clients" }
            # Sequences 3 and 4 are about a connect from a DIFFERENT source. If the interface hands both
            # tunnels the same individual address this is sequence 1/2 instead - a second connect from
            # the same source, where the state legitimately stays as it is. Without this check the case
            # judged the wrong clause: the certified MDT "failed" it until this was added.
            $paA = if ($a.Conn.PSObject.Properties['TunnelPa']) { [string]$a.Conn.TunnelPa } else { '' }
            $paB = if ($b.Conn.PSObject.Properties['TunnelPa']) { [string]$b.Conn.TunnelPa } else { '' }
            Add-KnxEvidence -Note ("client A = {0}, client B = {1}" -f $paA, $paB)
            if (-not $paA -or -not $paB) { Set-KnxTestNotApplicable 'the tunnel individual addresses are unknown, so the two sessions cannot be proven to be two different sources' }
            if ($paA -eq $paB) { Set-KnxTestNotApplicable "both tunnels got the same individual address ($paA) - that is a second connect from the SAME source (sequences 1 and 2), not the case under test" }
            # The device keeps ONE connection. The first must still work after the second tried.
            $r = Invoke-KnxDeviceService -Session $a -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@(0x00)) `
                                         -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 6000
            if ($null -eq $r.Response) {
                # One retry before judging: a device that needs a moment to shed the refused second
                # connection is not the same as one that dropped the first. Without this the case
                # cannot tell impatience from a defect.
                Start-Sleep -Seconds 3
                $r = Invoke-KnxDeviceService -Session $a -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@(0x00)) `
                                             -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 6000
                Add-KnxEvidence -Note ("first attempt silent, retry after 3 s: {0}" -f ($null -ne $r.Response))
            }
            Add-KnxEvidence -Note ("first connection still answers after a second connect: {0}" -f ($null -ne $r.Response))
            Assert-KnxTrue ($null -ne $r.Response) 'the first connection stopped working when a second client connected - an ETS download would break here'
        }
        finally {
            if ($null -ne $b -and $b.Ok) { Close-KnxDeviceSession -Session $b }
            Close-KnxDeviceSession -Session $a
        }
    }

    # ── D-30 Link layer acknowledge (08_02_02 clause 10.2.3) ────────────────────
    # The L2 acknowledge is produced by the TPUart driver, microseconds after the destination octets
    # are parsed - not by the stack. Whether it fires for the right frames is invisible from the
    # sending side and can only be seen by a second interface in busmonitor mode. A device that
    # acknowledges traffic addressed to somebody else is a fault source on a busy line.


    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-30.1 $tag" `
                       -Title 'Control: a frame to the device itself IS acknowledged on the line' `
                       -Clause '08_02_02 clause 10.2.3.1, p.44' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        if (-not $witnessIp) { Set-KnxTestNotRun -MissingInput '-WitnessIp' -Reason 'the L2 acknowledge is only visible to a second interface in busmonitor mode' }
        $w = Open-KnxBusWitness -WitnessIp $witnessIp -Port $port -TargetPa $Target -BdutIp $ip
        if (-not $w.Ok) { Set-KnxTestSkip "no busmonitor witness: $($w.Reason)" }
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target
        if (-not $s.Ok) { [void](Close-KnxConnection -Connection $w.Conn); Set-KnxTestSkip $s.Reason }
        try {
            $r = Get-KnxBusAckAfter -Witness $w.Conn -Conn $s.Conn -Destination $s.Dst `
                                    -Tpdu (New-TpduService -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@(0x00)))
            Add-KnxEvidence -Note ("frame seen on the line: {0}, acknowledge seen: {1}" -f $r.FrameSeen, $r.AckSeen)
            if (-not $r.FrameSeen) { Set-KnxTestNotApplicable 'the witness never saw our own frame, so it cannot judge acknowledges either' }
            # D-30.2 reads this: absent = the control did not complete its check, $false = the device did not acknowledge.
            $profile | Add-Member -NotePropertyName AckControl -NotePropertyValue $false -Force
            Assert-KnxTrue $r.AckSeen 'the device did not acknowledge a frame addressed to itself - without this control the negative case below proves nothing'
            # D-30.2 judges silence on the same witness; it relies on this proof.
            $profile | Add-Member -NotePropertyName AckControl -NotePropertyValue $true -Force
        }
        finally { Close-KnxDeviceSession -Session $s; [void](Close-KnxConnection -Connection $w.Conn) }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-30.2 $tag" `
                       -Title 'No acknowledge for a frame addressed to another individual address' `
                       -Clause '08_02_02 clause 10.2.3.2, p.44' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        if (-not $witnessIp) { Set-KnxTestNotRun -MissingInput '-WitnessIp' -Reason 'the L2 acknowledge is only visible to a second interface in busmonitor mode' }
        # 08_02_02 10.2.3.2 p.44 sends a frame to the BDUT's neighbour address and accepts "BDUT does not
        # accept the frame (sends no ACK)". That is only attributable with the BDUT alone on the line: on a
        # shared line any other device may own the address, a tunnelling server acknowledges its additional
        # addresses on layer 2 (03_08_04 2.2.2 p.7), and BCU1/BCU2/System 1/2 devices need not answer a
        # connectionless A_DeviceDescriptor_Read at all (06 Profiles Table 4.3 p.42) - so no probe can prove
        # an address unowned. The run has to declare the line isolated.
        $isolated = $false
        if ($Ctx.PSObject.Properties['IsolatedLine']) { $isolated = [bool]$Ctx.IsolatedLine }
        if (-not $isolated) { Set-KnxTestNotRun -MissingInput '-IsolatedLine' -Reason 'needs a line on which only the device under test acknowledges (08_02_02 test setup); on a shared line an acknowledge cannot be attributed to it' }
        $targetCount = 1
        if ($Ctx.PSObject.Properties['TargetCount']) { $targetCount = [int]$Ctx.TargetCount }
        if ($targetCount -gt 1) { Set-KnxTestNotRun -MissingInput '-Targets with one device' -Reason "the isolated-line set-up allows one device under test, this run has $targetCount - the neighbour may be another target" }
        if (-not $profile.PSObject.Properties['AckControl']) { Set-KnxTestNotRun -MissingInput 'D-30.1 in the same run' -Reason 'the acknowledge control D-30.1 did not complete its check in this run (not selected, skipped, its frame not seen, or it ended with an error), so an absent acknowledge here would prove nothing' }
        if (-not $profile.AckControl) { Set-KnxTestNotApplicable 'D-30.1 did not show the witness an acknowledge from this device, so no acknowledge seen here would prove anything either' }
        # A coupler acknowledges addresses beyond its own (03_02_02 p.38). Everything else the run declares:
        # -IsolatedLine says the target holds no further addresses (no tunnelling server) and that the
        # neighbour belongs to none of the rig's interfaces, as the EITT set-up of 08_02_02 does.
        $couplerMasks = @(0x0910, 0x0911, 0x0912, 0x091A, 0x0920, 0x1900, 0x2920)
        if ($profile.Mask -in $couplerMasks) { Set-KnxTestNotApplicable ("mask 0x{0:X4} is a coupler; it acknowledges addresses beyond its own" -f $profile.Mask) }
        $parts = $Target -split '\.'
        if ($parts.Count -ne 3) { Set-KnxTestNotApplicable "cannot derive a neighbour address from $Target" }
        # The clause's neighbour: BDUT 1001 -> 1002. One below when the target sits at the top of the range.
        $dev = [int]$parts[2] + 1
        if ($dev -gt 255) { $dev = [int]$parts[2] - 1 }
        $other = "$($parts[0]).$($parts[1]).$dev"
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        $w = $null
        try {
            # Our own interface sits on the line too and acknowledges its tunnel address (03_08_04 2.2.2 p.7).
            if ($s.Conn.PSObject.Properties['TunnelPa'] -and [string]$s.Conn.TunnelPa -eq $other) {
                Set-KnxTestNotApplicable "$other is the tunnel address of the sending interface, which acknowledges it itself"
            }
            $w = Open-KnxBusWitness -WitnessIp $witnessIp -Port $port -TargetPa $Target -BdutIp $ip
            if (-not $w.Ok) { Set-KnxTestSkip "no busmonitor witness: $($w.Reason)" }
            $r = Get-KnxBusAckAfter -Witness $w.Conn -Conn $s.Conn -Destination (ConvertTo-KnxPa -Address $other) `
                                    -Tpdu (New-TpduService -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@(0x00)))
            Add-KnxEvidence -Note ("line declared isolated (-IsolatedLine: only {0} and the rig's interfaces, {1} owned by none of them); frame to {1} seen: {2}, acknowledge seen: {3}" -f $Target, $other, $r.FrameSeen, $r.AckSeen)
            if (-not $r.FrameSeen) { Set-KnxTestNotApplicable 'the witness never saw the frame, so an absent acknowledge proves nothing' }
            Assert-KnxTrue (-not $r.AckSeen) "an acknowledge was seen for $other on a line declared to hold only $Target - the device under test acknowledged a frame not addressed to it (08_02_02 10.2.3.2 p.44)"
        }
        finally {
            Close-KnxDeviceSession -Session $s
            if ($null -ne $w -and $w.Ok) { [void](Close-KnxConnection -Connection $w.Conn) }
        }
    }

    # ── D-31 Group object semantics (08_03_07 clause 1.4.1) ─────────────────────
    # No -TestGa needed: D-19.1 already reads the device's own address table, and a value is written
    # back only after the original has been read, so nothing is left changed.

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-31.1 $tag" `
                       -Title 'A value longer than the group object is not taken over' `
                       -Clause '08_03_07 clause 1.4.1.4, p.21' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        if (-not $Ctx.AllowDestructive) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'writes a group telegram that an actuator may act on' }
        $gas = @()
        if ($profile.PSObject.Properties['GroupAddresses']) { $gas = @($profile.GroupAddresses) }
        if ($gas.Count -eq 0) { Set-KnxTestSkip 'no group address was discovered in D-19.1' }
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # Find an address this device actually answers, so "unchanged" can be proven by reading back.
            $ga = $null; $before = $null
            foreach ($cand in @($gas | Select-Object -First 8)) {
                $dst = ConvertTo-KnxGa -Address $cand
                $v = Get-KnxGroupValue -Conn $s.Conn -Destination $dst -Source $s.Dst -TimeoutMs 2500
                if ($null -ne $v) { $ga = $cand; $before = $v; break }
            }
            if ($null -eq $ga) { Set-KnxTestNotApplicable 'none of the configured group addresses answered a read, so a value change cannot be observed' }
            $dst = ConvertTo-KnxGa -Address $ga
            Add-KnxEvidence -Note ("group address {0}, value before: {1}" -f $ga, ((($before | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')))

            # Four octets of payload into whatever object sits there. Clause 1.4.1.4 p.21: a value that
            # does not fit the object must not be taken over.
            $tpdu = [byte[]]@(0x00, 0x80, 0xDE, 0xAD, 0xBE, 0xEF)
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $dst -IsGroup -Tpdu $tpdu -Priority 3
            Add-KnxEvidence -Sent $cemi
            [void](Send-KnxTunnelCemi -Connection $s.Conn -Cemi $cemi -TimeoutMs 2500)
            Start-Sleep -Milliseconds 800

            $after = Get-KnxGroupValue -Conn $s.Conn -Destination $dst -Source $s.Dst -TimeoutMs 2500
            if ($null -eq $after) { Set-KnxTestNotApplicable 'the object stopped answering after the oversized write, so the value cannot be compared' }
            Add-KnxEvidence -Note ("value after: {0}" -f ((($after | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')))
            $same = ((($before | ForEach-Object { '{0:X2}' -f $_ }) -join '') -eq (($after | ForEach-Object { '{0:X2}' -f $_ }) -join ''))
            if (-not $same) {
                # Put it back before judging - the case must not leave the installation changed.
                $restore = [byte[]]@(0x00, 0x80) + $before
                [void](Send-KnxTunnelCemi -Connection $s.Conn -Cemi (New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $dst -IsGroup -Tpdu $restore -Priority 3) -TimeoutMs 2500)
                Add-KnxEvidence -Note 'original value written back'
            }
            Assert-KnxTrue $same 'a four-octet value was taken over by an object that cannot hold it (clause 1.4.1.4)'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }
    # ── D-32 Transport layer state machine (08_03_04 clause 6, sequences 1-32) ──
    # Of the 32 sequences only four were covered. These use the shared helpers: raw control fields via
    # New-TpduRawTpci, collected answers via Get-KnxFramesFrom. Control fields per 03_03_04 Figure 3:
    # 80h T_Connect, 81h T_Disconnect, C2h|seq<<2 T_ACK, C3h|seq<<2 T_NAK, 40h|seq<<2 numbered data.

    # One precondition for the whole group: a target that cannot hold an ordinary connection twice
    # cannot be judged on its transport state machine.
    $tlBaseline = $null
    $tlGate = {
        param([string]$What)
        # The module caches this per target; the suite just asks.
        if (-not (Test-KnxTargetSustainsConnection -Ip $ip -Port $port -Pa $Target)) {
            Set-KnxTestNotApplicable "$Target does not sustain two ordinary connection-oriented exchanges, so its transport state machine cannot be judged - this is what a KNXnet/IP interface looks like when it is used as a device target"
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-32.1 $tag" `
                       -Title 'T_Disconnect in state CLOSED draws no reaction' `
                       -Clause '08_03_04 clause 6.2.3 sequence 5, p.58' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        & $tlGate
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target   # no -Connect: the device is CLOSED
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            $frames = Get-KnxFramesFrom -Session $s -Tpdu ([byte[]]@(0x81)) -Ms 3000
            foreach ($f in @($frames)) { Add-KnxEvidence -Received $f.Tpdu }
            Add-KnxEvidence -Note ("{0} frame(s) came back" -f @($frames).Count)
            if (@($frames).Count -eq 0) { & $liveGate 'the silence after a T_Disconnect in state CLOSED' $s }
            Assert-KnxEqual 0 @($frames).Count 'the device answered a T_Disconnect while no connection was open'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-32.2 $tag" `
                       -Title 'A second T_Connect from the same source leaves the connection usable' `
                       -Clause '08_03_04 clause 6.2.1 sequences 1 and 2, p.56' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        & $tlGate
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        try {
            # Same source, second connect: the state must not move, and the link must still work.
            [void](Send-KnxDeviceTpdu -Session $s -Tpdu ([byte[]]@(0x80)) -TimeoutMs 2000)
            Start-Sleep -Milliseconds 500
            $r = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@(0x00)) `
                                         -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 6000
            Add-KnxEvidence -Note ("connection still answers after a repeated T_Connect: {0}" -f ($null -ne $r.Response))
            Assert-KnxTrue ($null -ne $r.Response) 'a second T_Connect from the same source broke the open connection'
        }
        finally { Close-KnxDeviceSession -Session $s }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-32.3 $tag" `
                       -Title 'A T_Disconnect from another source does not close our connection' `
                       -Clause '08_03_04 clause 6.2.4 sequences 8 and 9, p.59-60' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        & $tlGate
        $a = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $a.Ok) { Set-KnxTestSkip $a.Reason }
        $b = $null
        try {
            $b = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target
            if (-not $b.Ok) { Set-KnxTestNotApplicable "a second tunnel could not be opened ($($b.Reason))" }
            $paA = if ($a.Conn.PSObject.Properties['TunnelPa']) { [string]$a.Conn.TunnelPa } else { '' }
            $paB = if ($b.Conn.PSObject.Properties['TunnelPa']) { [string]$b.Conn.TunnelPa } else { '' }
            Add-KnxEvidence -Note ("our source {0}, foreign source {1}" -f $paA, $paB)
            if (-not $paA -or -not $paB -or $paA -eq $paB) { Set-KnxTestNotApplicable 'both tunnels share one individual address, so there is no foreign source to send from' }

            # The foreign client tears down a connection it does not own.
            [void](Send-KnxDeviceTpdu -Session $b -Tpdu ([byte[]]@(0x81)) -TimeoutMs 2000)
            Start-Sleep -Milliseconds 600
            $r = Invoke-KnxDeviceService -Session $a -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@(0x00)) `
                                         -ExpectApci $K.Apci.DEVICE_DESCRIPTOR_RESPONSE -TimeoutMs 6000
            Add-KnxEvidence -Note ("our connection still answers: {0}" -f ($null -ne $r.Response))
            Assert-KnxTrue ($null -ne $r.Response) 'a T_Disconnect from a foreign source closed our connection - any client could abort a running ETS download'
        }
        finally {
            if ($null -ne $b -and $b.Ok) { Close-KnxDeviceSession -Session $b }
            Close-KnxDeviceSession -Session $a
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-32.4 $tag" `
                       -Title 'Numbered data from another source is ignored' `
                       -Clause '08_03_04 clause 6.3.5 sequences 18 and 19, p.66-67' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        & $tlGate
        $a = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $a.Ok) { Set-KnxTestSkip $a.Reason }
        $b = $null
        try {
            $b = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target
            if (-not $b.Ok) { Set-KnxTestNotApplicable "a second tunnel could not be opened ($($b.Reason))" }
            $paA = if ($a.Conn.PSObject.Properties['TunnelPa']) { [string]$a.Conn.TunnelPa } else { '' }
            $paB = if ($b.Conn.PSObject.Properties['TunnelPa']) { [string]$b.Conn.TunnelPa } else { '' }
            if (-not $paA -or -not $paB -or $paA -eq $paB) { Set-KnxTestNotApplicable 'both tunnels share one individual address, so there is no foreign source to send from' }

            # Numbered data on a connection the sender never opened: no T_Ack, no answer.
            $tpdu = New-TpduRawTpci -Tpci 0x40 -Apci $K.Apci.DEVICE_DESCRIPTOR_READ -Data ([byte[]]@(0x00))
            $frames = Get-KnxFramesFrom -Session $b -Tpdu $tpdu -Ms 3000
            foreach ($f in @($frames)) { Add-KnxEvidence -Received $f.Tpdu }
            Add-KnxEvidence -Note ("{0} frame(s) came back to the foreign source" -f @($frames).Count)
            Assert-KnxEqual 0 @($frames).Count 'the device answered numbered data from a source that never connected'

            $u = Test-KnxDeviceStillUsable -Ip $ip -Port $port -Pa $Target
            Add-KnxEvidence -Note ("device usable on a fresh connection afterwards: {0}" -f $u.Ok)
            if ($u.RigFault) { Set-KnxTestNotApplicable $u.Reason }
            Assert-KnxTrue $u.Ok 'the device is wedged after numbered data from a source that never connected'
        }
        finally {
            if ($null -ne $b -and $b.Ok) { Close-KnxDeviceSession -Session $b }
            Close-KnxDeviceSession -Session $a
        }
    }

    foreach ($case in @(
            @{ Id = 'D-32.5'; Tpci = 0xC2; What = 'a T_ACK for a sequence nobody is waiting on'; Clause = '08_03_04 clause 6.4.1 sequence 20, p.67' },
            @{ Id = 'D-32.6'; Tpci = 0xC6; What = 'a T_ACK with the wrong sequence number'; Clause = '08_03_04 clause 6.4.2 sequences 21 and 22, p.67-68' },
            @{ Id = 'D-32.7'; Tpci = 0xC3; What = 'a T_NAK with the wrong sequence number'; Clause = '08_03_04 clause 6.4.5 sequences 25 and 26, p.69-70' })) {
        $tp = $case.Tpci; $wt = $case.What; $cl = $case.Clause
        Invoke-KnxTestCase -Suite $SuiteTitle -Id "$($case.Id) $tag" `
                           -Title "An open connection survives $wt" -Clause $cl -Body {
            if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        & $tlGate
            $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
            if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
            try {
                # Whatever the injected control field does to OUR bookkeeping, the device's own state
                # machine must survive it - so the proof runs on a connection opened afterwards.
                $frames = Get-KnxFramesFrom -Session $s -Tpdu ([byte[]]@([byte]$tp)) -Ms 2000
                foreach ($f in @($frames)) { Add-KnxEvidence -Received $f.Tpdu }
                Close-KnxDeviceSession -Session $s
                $u = Test-KnxDeviceStillUsable -Ip $ip -Port $port -Pa $Target
                Add-KnxEvidence -Note ("{0} frame(s) answered; device usable afterwards: {1}" -f @($frames).Count, $u.Ok)
                if ($u.RigFault) { Set-KnxTestNotApplicable $u.Reason }
                Assert-KnxTrue $u.Ok "the device is wedged after $wt"
            }
            finally { if ($null -ne $s -and $s.Ok) { Close-KnxDeviceSession -Session $s } }
        }
    }
    # ── D-33 Load state machine, the full transition matrix (08_TSSG 2.2-2.5) ───
    # Every expected state below is quoted from the acceptance lines of the clause, not inferred:
    #   UNLOADED x {NoOp 0, StartLoading 2, LoadCompleted 0|3, LoadSegment 0|3, Unload 0} p.6-10
    #   LOADED   x {NoOp 1, StartLoading 2, LoadCompleted 1|3, LoadSegment 3, Unload 0}   p.12-21
    #   LOADING  x {NoOp 2, StartLoading 2, LoadCompleted 1, LoadSegment 2, Unload 0}     p.25-30
    #   ERROR    x {NoOp 3, StartLoading 3, LoadCompleted 3, LoadSegment 3, Unload 0}     p.33-39
    # The DEVICE RESTART column is left out: each of those cases needs a real restart and the clause
    # accepts "connection breaks down" as the observation, which this harness cannot separate from a
    # lost tunnel. Named in D-33.0 rather than silently dropped.
    # Object 2, the association table, is the subject - the least harmful of the four.

    $LOAD_OBJ = 2
    $stateName = @{ 0 = 'UNLOADED'; 1 = 'LOADED'; 2 = 'LOADING'; 3 = 'ERROR' }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-33.0 $tag" `
                       -Title 'The DEVICE RESTART column of the load state matrix' `
                       -Clause '08_TSSG clauses 2.2.6, 2.3.6, 2.4.6, 2.5.6' -Body {
        Set-KnxTestNotRun -MissingInput 'a restart-capable rig' `
                          -Reason 'the acceptance is "connection breaks down, load state remains X"; a lost tunnel and a restarted device look the same from here, so the column would be judged on an observation this harness cannot make'
    }

    foreach ($row in @(
            @{ From = 0; Drive = @(4);       Ev = 0;  Want = @(0);    Cl = '08_TSSG 2.2.1, p.6-7' },
            @{ From = 0; Drive = @(4);       Ev = 1;  Want = @(2);    Cl = '08_TSSG 2.2.2, p.7' },
            @{ From = 0; Drive = @(4);       Ev = 2;  Want = @(0, 3); Cl = '08_TSSG 2.2.3, p.9' },
            @{ From = 0; Drive = @(4);       Ev = 3;  Want = @(0, 3); Cl = '08_TSSG 2.2.4, p.9' },
            @{ From = 0; Drive = @(4);       Ev = 4;  Want = @(0);    Cl = '08_TSSG 2.2.5, p.10' },
            @{ From = 1; Drive = @(4,1,2);   Ev = 0;  Want = @(1);    Cl = '08_TSSG 2.3.1, p.12' },
            @{ From = 1; Drive = @(4,1,2);   Ev = 1;  Want = @(2);    Cl = '08_TSSG 2.3.2, p.14' },
            @{ From = 1; Drive = @(4,1,2);   Ev = 2;  Want = @(1, 3); Cl = '08_TSSG 2.3.3, p.18' },
            @{ From = 1; Drive = @(4,1,2);   Ev = 3;  Want = @(3);    Cl = '08_TSSG 2.3.4, p.19' },
            @{ From = 1; Drive = @(4,1,2);   Ev = 4;  Want = @(0);    Cl = '08_TSSG 2.3.5, p.21' },
            @{ From = 2; Drive = @(4,1);     Ev = 0;  Want = @(2);    Cl = '08_TSSG 2.4.1, p.25' },
            @{ From = 2; Drive = @(4,1);     Ev = 1;  Want = @(2);    Cl = '08_TSSG 2.4.2, p.27' },
            @{ From = 2; Drive = @(4,1);     Ev = 2;  Want = @(1);    Cl = '08_TSSG 2.4.3, p.29' },
            @{ From = 2; Drive = @(4,1);     Ev = 3;  Want = @(2);    Cl = '08_TSSG 2.4.4, p.29' },
            @{ From = 2; Drive = @(4,1);     Ev = 4;  Want = @(0);    Cl = '08_TSSG 2.4.5, p.30' },
            @{ From = 3; Drive = @(4,1,2,3); Ev = 0;  Want = @(3);    Cl = '08_TSSG 2.5.1, p.33' },
            @{ From = 3; Drive = @(4,1,2,3); Ev = 1;  Want = @(3);    Cl = '08_TSSG 2.5.2, p.34' },
            @{ From = 3; Drive = @(4,1,2,3); Ev = 2;  Want = @(3);    Cl = '08_TSSG 2.5.3, p.36' },
            @{ From = 3; Drive = @(4,1,2,3); Ev = 3;  Want = @(3);    Cl = '08_TSSG 2.5.4, p.38' },
            @{ From = 3; Drive = @(4,1,2,3); Ev = 4;  Want = @(0);    Cl = '08_TSSG 2.5.5, p.39' })) {

        $fr = $row.From; $drive = $row.Drive; $ev = $row.Ev; $want = $row.Want; $cl = $row.Cl
        $evName = @{ 0 = 'NO_OPERATION'; 1 = 'START_LOADING'; 2 = 'LOAD_COMPLETED'; 3 = 'LOAD_SEGMENT'; 4 = 'UNLOAD' }[$ev]

        Invoke-KnxTestCase -Suite $SuiteTitle -Id ("D-33.{0}{1} {2}" -f ($fr + 1), $ev, $tag) `
                           -Title ("From {0}, event {1} leads to {2}" -f $stateName[$fr], $evName, (($want | ForEach-Object { $stateName[$_] }) -join ' or ')) `
                           -Clause $cl -Body {
            if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
            if (-not $Ctx.PSObject.Properties['AllowTableUnload'] -or -not $Ctx.AllowTableUnload) {
                Set-KnxTestNotRun -MissingInput '-IncludeTableUnload' `
                                  -Reason 'drives the association table through UNLOAD and LOADING; the device needs an ETS download afterwards'
            }
            & $protectGate
            $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
            if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
            try {
                # Drive the object into the initial state the clause starts from.
                $st = -1
                foreach ($d in $drive) { $st = Write-KnxLoadEvent -Session $s -ObjectIndex $LOAD_OBJ -Event $d }
                if ($st -lt 0) { Set-KnxTestNotApplicable "object $LOAD_OBJ does not answer PID_LOAD_STATE_CONTROL" }
                Add-KnxEvidence -Note ("driven to state {0} ({1})" -f $st, $stateName[$st])
                if ($st -ne $fr) { Set-KnxTestNotApplicable ("could not reach the initial state {0}; the object is in {1}, so this transition cannot be judged" -f $stateName[$fr], $stateName[$st]) }

                $got = Write-KnxLoadEvent -Session $s -ObjectIndex $LOAD_OBJ -Event $ev
                Add-KnxEvidence -Note ("{0} + {1} -> {2} ({3})" -f $stateName[$fr], $evName, $got, $stateName[$got])
                Assert-KnxTrue ($want -contains $got) ("expected {0}, the device reports {1}" -f (($want | ForEach-Object { $stateName[$_] }) -join ' or '), $stateName[$got])
            }
            finally { Close-KnxDeviceSession -Session $s }
        }
    }
    # ── D-34 Verify mode (08_03_07 clause 2.7, footnote 7 p.25) ─────────────────
    # Verify mode is bit 2 of PID_DEVICE_CONTROL (lib/knx device_object.cpp: VERIFY_MODE 0x4). With it
    # on, a memory write is answered with a Memory_Response carrying the accepted data - that is the
    # premise of roughly twenty-five "with Verify" variants in clauses 2.7, 2.10, 2.23, 2.24 and 2.32,
    # and the stack implements it (bau_systemB.cpp:147/182/193/311) while no test ever switched it on.
    # Nothing is changed on the device: the value read at 0x0060 is written straight back.

    $VERIFY_BIT = 0x04

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-34.1 $tag" `
                       -Title 'Verify mode can be switched on and reads back' `
                       -Clause '08_03_07 clause 2.7 footnote 7, p.25; 03_05_01 PID_DEVICE_CONTROL' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        if (-not $Ctx.AllowDestructive) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'writes PID_DEVICE_CONTROL' }
        & $protectGate
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        $orig = -1
        $verifySet = $false
        $restored = $false
        $restoreNote = 'the restore never ran'
        $bodyError = $null
        try {
            $r0 = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.PROPERTY_VALUE_READ `
                                          -Data ([byte[]]@(0x00, [byte]$K.Pid.DEVICE_CONTROL, 0x10, 0x01)) `
                                          -ExpectApci $K.Apci.PROPERTY_VALUE_RESPONSE -TimeoutMs 5000
            if ($null -eq $r0.Response -or $r0.Response.Length -lt 7) { Set-KnxTestNotApplicable 'PID_DEVICE_CONTROL is not readable on this device' }
            $orig = [int]$r0.Response[6]
            Add-KnxEvidence -Note ("device control before: 0x{0:X2}" -f $orig)

            $verifySet = $true
            [void](Invoke-KnxDeviceService -Session $s -Apci $K.Apci.PROPERTY_VALUE_WRITE `
                       -Data ([byte[]]@(0x00, [byte]$K.Pid.DEVICE_CONTROL, 0x10, 0x01, [byte]($orig -bor $VERIFY_BIT))) `
                       -ExpectApci $K.Apci.PROPERTY_VALUE_RESPONSE -TimeoutMs 5000)
            $r1 = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.PROPERTY_VALUE_READ `
                                          -Data ([byte[]]@(0x00, [byte]$K.Pid.DEVICE_CONTROL, 0x10, 0x01)) `
                                          -ExpectApci $K.Apci.PROPERTY_VALUE_RESPONSE -TimeoutMs 5000
            $now = if ($null -ne $r1.Response -and $r1.Response.Length -ge 7) { [int]$r1.Response[6] } else { -1 }
            Add-KnxEvidence -Note ("device control after: 0x{0:X2}" -f $now)
            Assert-KnxTrue (($now -band $VERIFY_BIT) -ne 0) 'the device accepted the write but verify mode did not come back set'
        }
        catch { $bodyError = $_ }
        finally {
            $rr = & $restoreProperty $s 0 $K.Pid.DEVICE_CONTROL $orig @($orig) $verifySet 0
            $restored = $rr.Ok
            $restoreNote = $rr.Note
            try { Add-KnxEvidence -Note $restoreNote } catch { }
            try { Close-KnxDeviceSession -Session $s } catch { }
        }
        # Verify mode left on changes every later memory write on this device and on the installation,
        # so a failed restore decides the headline even when the body failed too, and the body's own
        # message is carried along. Asserting only after the finally skipped this whenever the body threw.
        if (-not $restored) {
            $extra = if ($null -ne $bodyError) { " The case itself ended with: $($bodyError.Exception.Message)" } else { '' }
            Assert-KnxTrue $false "PID_DEVICE_CONTROL was not proven to be back at its original value - $restoreNote. While verify mode stays on, every later memory write on $Target and on the installation is answered differently.$extra"
        }
        if ($null -ne $bodyError) { throw $bodyError }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id "D-34.2 $tag" `
                       -Title 'With verify mode on, a memory write is answered with the accepted data' `
                       -Clause '08_03_07 clause 2.7.2, p.33 (the "with Verify" variant)' -Body {
        if (-not $profile.Alive) { Set-KnxTestSkip "device did not answer in D-1.1 - $($profile.Reason)" }
        if (-not $Ctx.AllowDestructive) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'writes device memory, even though the value written is the one already there' }
        & $protectGate
        $s = Open-KnxDeviceSession -Ip $ip -Port $port -Pa $Target -Connect
        if (-not $s.Ok) { Set-KnxTestSkip $s.Reason }
        $orig = -1
        $verifySet = $false
        $restored = $false
        $restoreNote = 'the restore never ran'
        $bodyError = $null
        try {
            $r0 = Invoke-KnxDeviceService -Session $s -Apci $K.Apci.PROPERTY_VALUE_READ `
                                          -Data ([byte[]]@(0x00, [byte]$K.Pid.DEVICE_CONTROL, 0x10, 0x01)) `
                                          -ExpectApci $K.Apci.PROPERTY_VALUE_RESPONSE -TimeoutMs 5000
            if ($null -eq $r0.Response -or $r0.Response.Length -lt 7) { Set-KnxTestNotApplicable 'PID_DEVICE_CONTROL is not readable on this device' }
            $orig = [int]$r0.Response[6]

            $addr = 0x0060
            $cur = Get-KnxDeviceMemory -Session $s -Address $addr -Length 4
            if ($null -eq $cur -or $cur.Length -lt 4) { Set-KnxTestNotApplicable 'the device does not serve a memory read at 0x0060, so the verify answer cannot be compared' }

            $verifySet = $true
            [void](Invoke-KnxDeviceService -Session $s -Apci $K.Apci.PROPERTY_VALUE_WRITE `
                       -Data ([byte[]]@(0x00, [byte]$K.Pid.DEVICE_CONTROL, 0x10, 0x01, [byte]($orig -bor $VERIFY_BIT))) `
                       -ExpectApci $K.Apci.PROPERTY_VALUE_RESPONSE -TimeoutMs 5000)

            # The same four octets back into the same address: nothing changes, but verify mode owes
            # us a Memory_Response carrying them.
            $w = Invoke-KnxDeviceService -Session $s -Apci ($K.Apci.MEMORY_WRITE -bor 4) `
                                         -Data ([byte[]]@((($addr -shr 8) -band 0xFF), ($addr -band 0xFF)) + $cur) `
                                         -ExpectApci ($K.Apci.MEMORY_RESPONSE -bor 4) -TimeoutMs 5000
            if ($null -eq $w.Response) { Set-KnxTestNotApplicable 'no Memory_Response with verify mode on - the device may not implement the verify answer at all' }
            Add-KnxEvidence -Received $w.Response -Note ("wrote back {0}" -f (ConvertTo-HexString -Bytes $cur))
            $echo = if ($w.Response.Length -ge 8) { [byte[]]$w.Response[4..7] } else { [byte[]]@() }
            Assert-KnxBytes $cur $echo 'the verify answer does not carry the data that was accepted'
        }
        catch { $bodyError = $_ }
        finally {
            $rr = & $restoreProperty $s 0 $K.Pid.DEVICE_CONTROL $orig @($orig) $verifySet 0
            $restored = $rr.Ok
            $restoreNote = $rr.Note
            try { Add-KnxEvidence -Note $restoreNote } catch { }
            try { Close-KnxDeviceSession -Session $s } catch { }
        }
        # Verify mode left on changes every later memory write on this device and on the installation,
        # so a failed restore decides the headline even when the body failed too, and the body's own
        # message is carried along. Asserting only after the finally skipped this whenever the body threw.
        if (-not $restored) {
            $extra = if ($null -ne $bodyError) { " The case itself ended with: $($bodyError.Exception.Message)" } else { '' }
            Assert-KnxTrue $false "PID_DEVICE_CONTROL was not proven to be back at its original value - $restoreNote. While verify mode stays on, every later memory write on $Target and on the installation is answered differently.$extra"
        }
        if ($null -ne $bodyError) { throw $bodyError }
    }
}



