#!/usr/bin/env pwsh
# Open ■
# ┬────┴  10-Properties.Tests
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/Suites/10-Properties.Tests.ps1

<#
.SYNOPSIS
    Interface object properties a KNXnet/IP device must carry, and whether it really does.

.DESCRIPTION
    Dot-sourced by Invoke-Conformance.ps1, which then calls Invoke-KnxSuiteProperties.

    WHAT THIS SECTION ADDS
    An earlier version of this header claimed TSSH does not walk the property tables. That
    was wrong: 08_TSSH 4.2.2 p.27 is literally titled "Read mandatory device properties" and
    lists PID 51, 52, 53, 55, 57-62, 64, 65, 66, 67, 68, 69 and 76 of the KNXnet/IP parameter
    object plus PID 11 of the device object. Those are covered there and not repeated here.

    What TSSH does NOT cover, and what this section is for: PID 70, 72-75, 78, 79 of the
    KNXnet/IP parameter object, PID 51 of the Router object, and PID 68/69 of the cEMI Server
    object. Of these only MSG_TRANSMIT appears in TSSH at all (6.1.5 p.105 / 6.1.6 p.107) and
    there explicitly as "Optional test".

    THREE RULES THIS FILE FOLLOWS, EACH BOUGHT WITH A DEFECT
    1. An answer is only an answer when it belongs to the question. Send-KnxDeviceConfiguration
       returns the first DEVICE_CONFIGURATION_REQUEST that arrives and checks nothing about it.
       A review proved the consequence at the device: after one abandoned confirmation, reading
       PID 70 returned PID 74's counter, and the case reported the property as present. Worse,
       03_08_03 2.5.20 p.14 REQUIRES PID_KNXNETIP_DEVICE_STATE to be evented via M_PropInfo.ind,
       which is the same frame type - so a conformant device sending a state change during this
       section would have been read as a property answer. Every read here is matched on message
       code, object type, object instance and PID.
    2. "Could not be read" is not one outcome but four, and only one of them is about the
       device. A device that answers "no such property" said something; a timeout, a torn
       connection or a mismatched frame said nothing about the device at all. They are kept
       apart, and only the first can produce FAIL.
    3. A property is only demanded where a clause demands it. Several cases here previously
       cited a clause that describes a property's CONTENT and treated it as an obligation to
       IMPLEMENT it. Those are reported as observations now, with the value, and cannot fail.

    ARRAY PROPERTIES ARE PROBED AT INDEX 0
    Start index 0 returns the element count and is the only read that cannot fail for range
    reasons; index 1 of an implemented-but-empty array is refused exactly like a missing
    property. The library learned this once already - see Get-KnxTunnelPool in KnxTest.psm1,
    whose comment records a pool that read as EMPTY because the refusal was swallowed.

    THE ROLE IS A COMMAND-LINE ARGUMENT, NOT A MEASUREMENT
    $Ctx.IsRouter comes from the Supported Service Families DIB (Invoke-Conformance.ps1:431)
    and is then OVERWRITTEN by -Product (:436-437); with -SkipRigCheck the flag is the only
    source. A mistyped -Product therefore silences the router-only cases. This suite fetches
    the DIB itself and reports a disagreement rather than trusting either side silently.
#>

Set-StrictMode -Version Latest

# Interface object types: 03_05_01 section 4.5 = Router (6), 4.7 = cEMI Server (8);
# 03_08_03 2.2 = KNXnet/IP Parameter (11).
$script:OT_ROUTER   = 6
$script:OT_CEMI_SRV = 8
$script:OT_IP_PARAM = 11

# M_PropRead.req is 0xFC (New-CemiMPropRead), so its confirmation is 0xFB. M_PropInfo.ind is
# 0xF7 and must never be mistaken for one - see rule 1 in the header.
$script:MC_PROPREAD_CON = 0xFB

$script:PropConn = $null
$script:PropNa   = ''
$script:Chk      = $null
$script:RoutingCaps = $null

function Read-PropOutcome {
    <#
    .SYNOPSIS
        Reads one property and says WHICH of the four possible outcomes occurred.
    .DESCRIPTION
        Outcome is one of:
          Present     - a matching confirmation with at least one element; Data carries it
          Absent      - a matching confirmation with element count 0; ErrorCode carries the reason
          NoAnswer    - nothing came back
          Mismatch    - a frame came back that answers a different question
        Only 'Absent' is a statement about the device. 'NoAnswer' and 'Mismatch' are statements
        about the rig or the stream and must never be reported as a missing property.
    #>
    param($Connection, [int]$ObjectType, [int]$PropertyId, [int]$ObjectInstance = 1,
          [int]$ElementCount = 1, [int]$StartIndex = -1)

    # No default index. Index 0 returns the ELEMENT COUNT, index 1 the first value, and a case that
    # wanted a value and inherited 0 judged the count instead - C-68 and C-70 both did. Not a
    # Mandatory parameter: that would prompt and hang an unattended run instead of failing it.
    if ($StartIndex -lt 0) { throw 'Read-PropOutcome needs an explicit -StartIndex: 0 asks for the element count, 1 for the first value.' }

    $mk = { param($o, $d, $e, $n) [pscustomobject]@{ Outcome = $o; Data = $d; ErrorCode = $e; Note = $n } }

    $cemi = New-CemiMPropRead -ObjectType $ObjectType -ObjectInstance $ObjectInstance `
                              -PropertyId $PropertyId -ElementCount $ElementCount -StartIndex $StartIndex
    try {
        $r = Send-KnxDeviceConfiguration -Connection $Connection -Cemi $cemi -TimeoutMs 3000
    } catch {
        # A torn connection throws here; the library has no null-socket guard on this path.
        return & $mk 'NoAnswer' $null -1 "request threw: $($_.Exception.Message)"
    }
    if ($null -eq $r -or $null -eq $r.Parsed) { return & $mk 'NoAnswer' $null -1 'no confirmation within 3000 ms' }

    $p = $r.Parsed
    if ($p.MessageCode -ne $script:MC_PROPREAD_CON) {
        return & $mk 'Mismatch' $null -1 ("frame is message code 0x{0:X2}, not an M_PropRead.con" -f $p.MessageCode)
    }
    if ($p.ObjectType -ne $ObjectType -or $p.PropertyId -ne $PropertyId -or $p.ObjectInstance -ne $ObjectInstance) {
        return & $mk 'Mismatch' $null -1 ("confirmation answers OT {0}/inst {1}/PID {2}, asked OT {3}/inst {4}/PID {5}" -f `
                     $p.ObjectType, $p.ObjectInstance, $p.PropertyId, $ObjectType, $ObjectInstance, $PropertyId)
    }
    if ($p.IsError) { return & $mk 'Absent' $null $p.ErrorCode ("device refused with code 0x{0:X2}" -f $p.ErrorCode) }
    if ($p.Data.Length -eq 0) { return & $mk 'Absent' $null -1 'positive confirmation carried no data' }
    return & $mk 'Present' ([byte[]]$p.Data) -1 ''
}

function Test-PropApplicable {
    if ($null -eq $script:PropConn) { Set-KnxTestNotApplicable $script:PropNa; return $false }
    return $true
}

function Format-Octets([byte[]]$b) { return (($b | ForEach-Object { '{0:X2}' -f $_ }) -join ' ') }

# The body every property case runs. Reads $script:Chk, which the caller sets immediately
# before invoking the case - deliberately NOT a closure: .GetNewClosure() binds the body to a
# new dynamic module where $script: resolves to that module and not to this file, which in an
# earlier version silently turned all twelve cases into "unhandled error" FAILs against a
# device that had the properties.
function Invoke-PropCase {
    if (-not (Test-PropApplicable)) { return }
    $c = $script:Chk

    if ($c.RouterOnly -and -not $script:IsRouterRole) {
        Set-KnxTestNotApplicable "$($c.Clause) binds this property to devices providing KNXnet/IP Routing; this device does not advertise the Routing service family"
        return
    }
    # Conditional properties: the capability bit decides whether the device claims the feature
    # at all. Without PID 70 we cannot know, and guessing would fail a conformant device.
    if ($c.ContainsKey('NeedsCapBit')) {
        if ($null -eq $script:RoutingCaps) {
            Set-KnxTestNotRun -MissingInput 'PID_KNXNETIP_ROUTING_CAPABILITIES' `
                              -Reason '03_08_03 2.5.21 p.15 makes these statistics optional and ties them to the capability bits; without PID 70 the requirement is undecidable'
            return
        }
        if ((($script:RoutingCaps -band $c.NeedsCapBit) -eq 0)) {
            Set-KnxTestNotApplicable ("device reports routing capabilities 0x{0:X2}, so bit {1} is clear - 03_08_03 2.5.21 p.15: 'These are optional features'" -f $script:RoutingCaps, $c.CapBitNo)
            return
        }
    }

    # Index 0 on purpose: this case asks whether the property exists, and the element count is an
    # answer to that. The value cases read index 1.
    $o = Read-PropOutcome $script:PropConn $c.Ot $c.Pid -StartIndex 0
    switch ($o.Outcome) {
        'Present' {
            # Index 0 answered the ELEMENT COUNT, which is what decides "implemented". It is not the
            # value, and printing it as one is how three cases came to report "= 00 01" for
            # properties holding 254 and a device state. The value is fetched separately, and when
            # the device refuses index 1 the count is still shown - labelled as the count.
            $v = Read-PropOutcome $script:PropConn $c.Ot $c.Pid -StartIndex 1
            if ($v.Outcome -eq 'Present') {
                Add-KnxEvidence -Note ("$($c.Name) = " + (Format-Octets $v.Data))
            }
            else {
                Add-KnxEvidence -Note ("$($c.Name): implemented, element count " + (Format-Octets $o.Data) + " - value not readable: $($v.Note)")
            }
        }
        'Absent' {
            Add-KnxEvidence -Note "$($c.Name): $($o.Note)"
        }
        default {
            Set-KnxTestNotApplicable "rig: $($o.Note) - this says nothing about whether $($c.Name) is implemented"
            return
        }
    }
    # Only 'Present' and 'Absent' reach here, and only they can carry a result about the device.
    if ($c.Mandate -eq 'Required') {
        Assert-KnxTrue ($o.Outcome -eq 'Present') `
            "$($c.Name) (object type $($c.Ot), PID $($c.Pid)) is not implemented - $($c.Why)"
    }
    else {
        # Informational: the cited clause describes the property, it does not oblige a device to
        # carry it - so there is nothing here that could be failed, and therefore nothing that may
        # be passed either. The case records the reading and makes NO assertion, which the harness
        # turns into NO-PROOF: counted, but not a result about the device.
        #
        # It used to assert ($o.Outcome -in @('Present','Absent')). That could never fail: only those
        # two outcomes reach this point, the others were turned into N-A above. Against the reference
        # interface the report then read "PID_TUNNELLING_ADDRESSES is implemented - PASS" while the
        # evidence on the same line said "device refused with code 0x07". A green result for a
        # property the device had explicitly refused.
        Add-KnxEvidence -Note "reported only: $($c.Clause) describes this property but does not require it to be implemented - no result is derived"
    }
}

function Invoke-KnxSuiteProperties {
    param([Parameter(Mandatory)]$Ctx, [string]$SuiteTitle = '10 Properties')

    $K = Get-KnxConstants
    $ip = $Ctx.BdutIp
    $port = $Ctx.Port

    # The role, from the device rather than from the switch - see the header.
    $desc = $null
    try { $desc = Get-KnxDescription -Ip $ip -Port $port } catch { }
    $dibRouter = $null
    $dibTunnel = $null
    $dibDevMgmt = $null
    if ($null -ne $desc -and $null -ne $desc.Families) {
        # Service family identifiers, 03_08_02 7.5.4.3: 03h Device Management, 04h Tunnelling,
        # 05h Routing. C-68 holds the device to its own advertisement instead of to a build flag.
        $dibRouter  = (@($desc.Families | Where-Object { $_.Id -eq 0x05 }).Count -gt 0)
        $dibTunnel  = (@($desc.Families | Where-Object { $_.Id -eq 0x04 }).Count -gt 0)
        $dibDevMgmt = (@($desc.Families | Where-Object { $_.Id -eq 0x03 }).Count -gt 0)
    }
    $script:IsRouterRole = if ($null -ne $dibRouter) { $dibRouter } else { $Ctx.IsRouter }

    $conn = $null; $connError = ''
    try {
        $c = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1 -TimeoutMs 3000
        if ($c.Ok) { $conn = $c } else { $connError = ("CONNECT_RESPONSE status 0x{0:X2}" -f $c.Status) }
    } catch { $connError = $_.Exception.Message }
    $script:PropConn = $conn
    $script:PropNa = "no device-management connection ($connError) - no property can be read, and nothing here is a statement about the device"

    # Role disagreement is worth a case of its own: it is the single switch that can silence
    # five mandatory properties without anyone noticing.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'C-ROLE' -Title 'The device role used for this section matches what the device advertises' -Clause '03_08_02 7.5.4.3 p.26' -Body {
        if ($null -eq $dibRouter) {
            Set-KnxTestNotRun -MissingInput 'DESCRIPTION_RESPONSE' -Reason 'the Supported Service Families DIB could not be read, so the role could not be taken from the device'
            return
        }
        Add-KnxEvidence -Note ("DIB advertises Routing: $dibRouter; -Product/rig says IsRouter: $($Ctx.IsRouter)")
        Assert-KnxEqual $dibRouter $Ctx.IsRouter `
            'the role this run was given does not match the service families the device advertises - the router-only cases below are being judged under the wrong role'
    }

    # C-68 asks about the VALUE, not the existence. PID 68 IS implemented in the stack, so an
    # existence case would prove nothing - while the value was measured as 0001h on both OpenKNX
    # devices, i.e. only bit 0. The yardstick is the device's own DESCRIPTION_RESPONSE: a service
    # family it advertises must have its capability bit set. No build flag is consulted, so the case
    # cannot be excused by a wrong -Product.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'C-68' -Title 'PID_KNXNETIP_DEVICE_CAPABILITIES agrees with the advertised service families' -Clause '03_08_03 2.5.19 Table 2 p.13' -Body {
        if (-not (Test-PropApplicable)) { return }
        if ($null -eq $dibTunnel) {
            Set-KnxTestNotRun -MissingInput 'DESCRIPTION_RESPONSE' `
                -Reason 'the Supported Service Families DIB could not be read, so there is nothing to hold the capabilities against'
            return
        }
        # StartIndex 1: index 0 answers the ELEMENT COUNT, not the value. Read at 0 this compared
        # the count against the service families - 00 01 reads as "Device Management yes, Tunnelling
        # no" and failed a device that answers 00 03 correctly.
        $o = Read-PropOutcome $script:PropConn $script:OT_IP_PARAM 68 -StartIndex 1
        if ($o.Outcome -in @('NoAnswer', 'Mismatch')) { Set-KnxTestNotApplicable "rig: $($o.Note)"; return }
        if ($o.Outcome -ne 'Present') {
            Assert-KnxTrue $false "PID_KNXNETIP_DEVICE_CAPABILITIES could not be read ($($o.Note)); 2.5.19 p.13 defines it for the KNXnet/IP Parameter Object"
            return
        }
        # PDT_BITSET16, two octets, most significant first.
        $caps = if ($o.Data.Count -ge 2) { ([int]$o.Data[0] -shl 8) -bor [int]$o.Data[1] } else { [int]$o.Data[0] }
        Add-KnxEvidence -Received ([byte[]]$o.Data) `
            -Note ("capabilities 0x{0:X4}; the DIB advertises Device Management: {1}, Tunnelling: {2}, Routing: {3}" -f $caps, $dibDevMgmt, $dibTunnel, $dibRouter)
        # Table 2 p.13: bit 0 Device Management, bit 1 Tunnelling, bit 2 Routing, bit 6 Security.
        # "A value of '1' shall always mean available" - so an advertised family with a clear bit is
        # the device contradicting itself. Bits beyond these are not judged here.
        if ($dibDevMgmt) { Assert-KnxTrue (($caps -band 0x0001) -ne 0) 'bit 0 Device Management is clear although the device advertises the Device Management service family' }
        if ($dibTunnel)  { Assert-KnxTrue (($caps -band 0x0002) -ne 0) 'bit 1 Tunnelling is clear although the device advertises the Tunnelling service family' }
        if ($dibRouter)  { Assert-KnxTrue (($caps -band 0x0004) -ne 0) 'bit 2 Routing is clear although the device advertises the Routing service family' }
    }

    # PID 70 first: the conditional cases below need it, and it is itself mandatory on a router.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'C-70' -Title 'PID_KNXNETIP_ROUTING_CAPABILITIES is implemented' -Clause '03_08_03 2.5.21 p.14' -Body {
        if (-not (Test-PropApplicable)) { return }
        if (-not $script:IsRouterRole) { Set-KnxTestNotApplicable '2.5.21 p.14 binds this to devices providing KNXnet/IP Routing'; return }
        # StartIndex 1 for the same reason. It went unnoticed here because the element count (1) and
        # this router's real value (0x01) are the same number - a right answer for a wrong reason.
        $o = Read-PropOutcome $script:PropConn $script:OT_IP_PARAM 70 -StartIndex 1
        if ($o.Outcome -in @('NoAnswer', 'Mismatch')) { Set-KnxTestNotApplicable "rig: $($o.Note)"; return }
        if ($o.Outcome -eq 'Present') {
            $script:RoutingCaps = [int]$o.Data[0]
            Add-KnxEvidence -Note ("routing capabilities = 0x{0:X2} (bit0 queue-overflow stats, bit1 transmitted-telegram stats, bit2 priority/FIFO)" -f $script:RoutingCaps)
        } else {
            Add-KnxEvidence -Note "PID 70: $($o.Note)"
        }
        Assert-KnxTrue ($o.Outcome -eq 'Present') `
            'PID_KNXNETIP_ROUTING_CAPABILITIES is not implemented - 2.5.21 p.14: "shall be implemented by devices providing KNXnet/IP Routing"'
    }

    $checks = @(
        @{ Id = 'C-69'; Ot = $script:OT_IP_PARAM; Pid = 69; Name = 'PID_KNXNETIP_DEVICE_STATE'
           Clause = '03_08_03 2.5.20 p.14'; RouterOnly = $false; Mandate = 'Required'
           Why = '2.5.20 p.14: "shall be implemented by any KNXnet/IP Server"' }
        @{ Id = 'C-78'; Ot = $script:OT_IP_PARAM; Pid = 78; Name = 'PID_ROUTING_BUSY_WAIT_TIME'
           Clause = '03_08_03 2.5.28 p.16'; RouterOnly = $true; Mandate = 'Required'
           Why = '2.5.28 p.16: "mandatory for devices implementing KNXnet/IP or KNX IP". NOTE: the same clause also scopes it to "a KNXnet/IP Router or KNX IP device", and 03_08_05 p.11 puts ROUTING_BUSY only on those - so it is demanded here of routers only, and the conflict is stated rather than resolved silently' }
        @{ Id = 'C-72'; Ot = $script:OT_IP_PARAM; Pid = 72; Name = 'PID_QUEUE_OVERFLOW_TO_IP'
           Clause = '03_08_03 2.5.23 p.15; 2.5.21 p.15'; RouterOnly = $true; Mandate = 'Required'
           NeedsCapBit = 0x01; CapBitNo = 0
           Why = 'the device sets routing-capabilities bit 0, so it claims queue-overflow statistics' }
        @{ Id = 'C-73'; Ot = $script:OT_IP_PARAM; Pid = 73; Name = 'PID_QUEUE_OVERFLOW_TO_KNX'
           Clause = '03_08_03 2.5.24 p.15; 2.5.21 p.15'; RouterOnly = $true; Mandate = 'Required'
           NeedsCapBit = 0x01; CapBitNo = 0
           Why = 'the device sets routing-capabilities bit 0, so it claims queue-overflow statistics' }
        @{ Id = 'C-74'; Ot = $script:OT_IP_PARAM; Pid = 74; Name = 'PID_MSG_TRANSMIT_TO_IP'
           Clause = '03_08_03 2.5.25 p.15; 2.5.21 p.15'; RouterOnly = $true; Mandate = 'Required'
           NeedsCapBit = 0x02; CapBitNo = 1
           Why = 'the device sets routing-capabilities bit 1, so it claims transmitted-telegram statistics' }
        @{ Id = 'C-75'; Ot = $script:OT_IP_PARAM; Pid = 75; Name = 'PID_MSG_TRANSMIT_TO_KNX'
           Clause = '03_08_03 2.5.26 p.16; 2.5.21 p.15'; RouterOnly = $true; Mandate = 'Required'
           NeedsCapBit = 0x02; CapBitNo = 1
           Why = 'the device sets routing-capabilities bit 1, so it claims transmitted-telegram statistics' }
        @{ Id = 'C-M68'; Ot = $script:OT_CEMI_SRV; Pid = 68; Name = 'PID_MAX_INTERFACE_APDU_LENGTH'
           Clause = '03_05_01 4.7.16 p.123'; RouterOnly = $false; Mandate = 'Required'
           Why = '4.7.16 p.123 places it in the cEMI Server Object, and 03_08_02 7.5.4.8 p.29 names it as the source of the Tunnelling Information DIB APDU length' }
        @{ Id = 'C-M69'; Ot = $script:OT_CEMI_SRV; Pid = 69; Name = 'PID_MAX_LOCAL_APDU_LENGTH'
           Clause = '03_05_01 4.7.17 p.124'; RouterOnly = $false; Mandate = 'Required'
           Why = '4.7.17 p.124 places it in the cEMI Server Object, and 03_08_02 7.5.4.9 p.31 names it as the source of the Extended Device Information DIB local APDU length' }
        # Informational: the cited clause describes the property; none of them says a device
        # shall implement it. Reported with the value, cannot fail on absence.
        @{ Id = 'C-63'; Ot = $script:OT_IP_PARAM; Pid = 63; Name = 'PID_DHCP_BOOTP_SERVER'
           Clause = '03_08_03 2.5.14 p.12'; RouterOnly = $false; Mandate = 'Informational'
           Why = '2.5.14 p.12 describes the content and read-only access; 08_TSSH 4.2.2 p.27 skips PID 63 in its mandatory table' }
        @{ Id = 'C-79'; Ot = $script:OT_IP_PARAM; Pid = 79; Name = 'PID_TUNNELLING_ADDRESSES'
           Clause = '03_08_03 2.5.29 p.16'; RouterOnly = $false; Mandate = 'Informational'
           Why = '2.5.29 describes format and access policy; it is a Tunnelling v2 resource and this suite does not gate on the tunnelling family version' }
        @{ Id = 'C-R51'; Ot = $script:OT_ROUTER; Pid = 51; Name = 'PID_MEDIUM_STATUS (Router Object)'
           Clause = '03_05_01 4.5.4 p.91'; RouterOnly = $true; Mandate = 'Informational'
           Why = '4.5.4 p.91 describes the content ("shall include the status of the communication medium"), not an obligation to implement. NOTE: 03_08_02 p.31 pins the meaning to the SECONDARY side, and this read cannot distinguish the instances' }
    )

    foreach ($chk in $checks) {
        $script:Chk = $chk
        # The title must not out-claim the case. "is implemented" belongs only to the Required
        # cases; an Informational one derives no result, and titling it that way put the line
        # "PID_TUNNELLING_ADDRESSES is implemented - PASS" next to the evidence "device refused
        # with code 0x07" in the same report row.
        $title = if ($chk.Mandate -eq 'Required') { "$($chk.Name) is implemented" }
                 else { "$($chk.Name) - read and reported, not required by the cited clause" }
        Invoke-KnxTestCase -Suite $SuiteTitle -Id $chk.Id -Title $title -Clause $chk.Clause -Body { Invoke-PropCase }
    }

    if ($null -ne $conn) { try { [void](Close-KnxConnection -Connection $conn) } catch { } }
}
