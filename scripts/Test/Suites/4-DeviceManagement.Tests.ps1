#!/usr/bin/env pwsh
# Open ■
# ┬────┴  4-DeviceManagement.Tests
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/Suites/4-DeviceManagement.Tests.ps1

<#
.SYNOPSIS
    TSSH section 4 - Device Management: connection handling, device configuration
    requests, mandatory properties, and the twelve cEMI transport-layer cases.

.DESCRIPTION
    Dot-sourced by Invoke-Conformance.ps1, which then calls Invoke-KnxSuiteDevMgmt.

    Section 4.3 is the highest-risk block of the whole prufvorschrift: twelve cases that
    drive the device-management state machine with transport-layer frames it may never
    have seen. The distinction that decides each verdict is narrow - some expect an ACK
    AND a following request, some expect ONLY an ACK, some expect complete silence.
    Getting "only ACK" wrong by accepting any answer would pass a broken device.

    The cEMI encodings come verbatim from the frame tables (AN118) and are pinned by
    self-test vectors in KnxTest.psm1, so a wrong encoding fails offline, not here.
#>

Set-StrictMode -Version Latest

function Send-RawDeviceConfiguration {
    <#
    .SYNOPSIS
        Sends a DEVICE_CONFIGURATION_REQUEST without an open connection and collects
        everything that comes back (expected: nothing).
    #>
    param([string]$Ip, [int]$Port, [byte[]]$Cemi, [int]$Channel = 0, [int]$WindowMs = 1500)
    $s = New-KnxSocket -TimeoutMs $WindowMs
    try {
        $f = New-KnxDeviceConfigurationRequest -Channel $Channel -Sequence 0 -Cemi $Cemi
        Send-KnxFrame -Socket $s -Frame $f -Ip $Ip -Port $Port
        $got = @()
        $deadline = [DateTime]::UtcNow.AddMilliseconds($WindowMs)
        while ([DateTime]::UtcNow -lt $deadline) {
            $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
            $pkt = Receive-KnxFrame -Socket $s -TimeoutMs $left
            if ($null -eq $pkt) { break }
            $got += $pkt
        }
        return [pscustomobject]@{ Sent = $f; Received = @($got) }
    }
    finally { $s.Dispose() }
}

function Get-PropertyBytes {
    <#
    .SYNOPSIS
        Reads a property and returns its data, or $null when it could not be read.
    .DESCRIPTION
        The comma is load-bearing: without it PowerShell unrolls the array on output, and a
        single-octet property (PID_PROGMODE, for example) arrives as a bare [byte] whose
        .Length does not exist - which surfaces as an unrelated "property Length not found".
    #>
    param($Connection, [int]$ObjectType, [int]$PropertyId, [int]$ElementCount = 1, [int]$StartIndex = 1)
    $r = Read-KnxProperty -Connection $Connection -ObjectType $ObjectType -PropertyId $PropertyId -ElementCount $ElementCount -StartIndex $StartIndex
    if ($null -eq $r.Parsed) { return $null }
    if ($r.Parsed.IsError) { return $null }
    return , ([byte[]]$r.Parsed.Data)
}

function Invoke-KnxSuiteDevMgmt {
    param([Parameter(Mandatory)]$Ctx, [string]$SuiteTitle = '4 Device Management')

    $K = Get-KnxConstants
    # Set-StrictMode rejects reading a script variable that was never assigned, so the capability cache
    # is created here rather than on first use.
    $script:CemiTransportServed = $null
    $ip = $Ctx.BdutIp
    $port = $Ctx.Port
    $DMGMT = $K.ConnType.DEVICE_MGMT_CONNECTION

    # ── 4.1 Connection Handling ─────────────────────────────────────────────────

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-4.1.1' -Title 'Connection Handling - Multiplicity' -Clause 'TSSH 4.1.1, p.24 (fn 20101)' -Body {
        if ($Ctx.ReadOnly) { Set-KnxTestSkip 'profile ReadOnly - exhausting the connection pool disturbs other clients' }
        $open = @()
        $refusal = -1
        try {
            # Open until refused. The bound is a safety stop, not an expectation.
            for ($i = 0; $i -lt 32; $i++) {
                $c = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $DMGMT -Layer -1 -TimeoutMs 2500
                if ($c.Ok) { $open += $c; continue }
                $refusal = $c.Status
                if ($null -ne $c.Response) { Add-KnxEvidence -Received $c.Response }
                break
            }
            Add-KnxEvidence -Note "$($open.Count) device management connection(s) granted, then status $(Get-KnxErrorName -Status $refusal)"
            Assert-KnxTrue ($open.Count -gt 0) 'device granted no device management connection at all'
            Assert-KnxTrue ($refusal -ge 0) 'device never refused - it accepted 32 device management connections, which cannot be right'
            Assert-KnxStatus $K.Error.E_NO_MORE_CONNECTIONS $refusal 'wrong status when the connection pool is exhausted'
        }
        finally { foreach ($c in $open) { [void](Close-KnxConnection -Connection $c) } }
    }

    # ── 4.2 Device Configuration Request ────────────────────────────────────────

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-4.2.1' -Title 'Device Configuration Request - Standard Case' -Clause 'TSSH 4.2.1, p.25 (fn 20203)' -Body {
        $conn = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $DMGMT -Layer -1
        Assert-KnxTrue $conn.Ok "could not open a device management connection ($($conn.StatusName))"
        try {
            $cemi = New-CemiMPropRead -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.KNX_INDIVIDUAL_ADDRESS
            Add-KnxEvidence -Sent $cemi
            $r = Send-KnxDeviceConfiguration -Connection $conn -Cemi $cemi
            Assert-KnxTrue $r.Acked 'no DEVICE_CONFIGURATION_ACK'
            Assert-KnxTrue ($null -ne $r.Cemi) 'no DEVICE_CONFIGURATION_REQUEST with the confirmation'
            Add-KnxEvidence -Received $r.Cemi
            Assert-KnxEqual $K.Cemi.M_PROPREAD_CON $r.Parsed.MessageCode 'confirmation is not an M_PropRead.con'
            Assert-KnxTrue (-not $r.Parsed.IsError) "read of PID_KNX_INDIVIDUAL_ADDRESS failed with error code 0x$('{0:X2}' -f $r.Parsed.ErrorCode)"
            Assert-KnxEqual 2 $r.Parsed.Data.Length 'PID_KNX_INDIVIDUAL_ADDRESS must be 2 octets'
            Add-KnxEvidence -Note "individual address $(ConvertFrom-KnxPa -Raw (Get-Uint16 -Bytes $r.Parsed.Data -Offset 0))"
        }
        finally { [void](Close-KnxConnection -Connection $conn) }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-4.2.2' -Title 'Read mandatory device properties' -Clause 'TSSH 4.2.2, p.27 (fn 20204)' -Body {
        $desc = Get-KnxDescription -Ip $ip -Port $port
        Assert-KnxTrue ($null -ne $desc -and $null -ne $desc.Device) 'no DEVICE_INFO DIB to compare the properties against'

        $conn = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $DMGMT -Layer -1
        Assert-KnxTrue $conn.Ok "could not open a device management connection ($($conn.StatusName))"
        try {
            $problems = @()

            $ia = Get-PropertyBytes -Connection $conn -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.KNX_INDIVIDUAL_ADDRESS
            if ($null -eq $ia -or $ia.Length -lt 2) { $problems += 'PID_KNX_INDIVIDUAL_ADDRESS not readable' }
            else {
                $paProp = ConvertFrom-KnxPa -Raw (Get-Uint16 -Bytes $ia -Offset 0)
                if ($paProp -ne $desc.Device.IndividualAddr) { $problems += "individual address property $paProp differs from DIB $($desc.Device.IndividualAddr)" }
            }

            $mc = Get-PropertyBytes -Connection $conn -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.ROUTING_MULTICAST_ADDRESS
            if ($null -eq $mc -or $mc.Length -lt 4) { $problems += 'PID_ROUTING_MULTICAST_ADDRESS not readable' }
            else {
                $mcProp = ([System.Net.IPAddress]::new([byte[]]$mc[0..3])).ToString()
                if ($mcProp -ne $desc.Device.MulticastAddr) { $problems += "multicast property $mcProp differs from DIB $($desc.Device.MulticastAddr)" }
            }

            $mac = Get-PropertyBytes -Connection $conn -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.MAC_ADDRESS -ElementCount 1
            if ($null -eq $mac -or $mac.Length -lt 6) { $problems += 'PID_MAC_ADDRESS not readable' }
            else {
                $macProp = ConvertTo-HexString -Bytes ([byte[]]$mac[0..5])
                if ($macProp -ne $desc.Device.MacAddress) { $problems += "MAC property $macProp differs from DIB $($desc.Device.MacAddress)" }
            }

            # PID_FRIENDLY_NAME is 30 octets, but the element count field is only 4 bits
            # wide, so 15 is the most that can be asked for at once. A second read is only
            # needed when the first one actually returned less than the full 30 - some
            # stacks answer the whole property regardless of the requested count, and
            # concatenating blindly would produce a doubled name.
            $fn1 = Get-PropertyBytes -Connection $conn -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.FRIENDLY_NAME -ElementCount 15 -StartIndex 1
            if ($null -eq $fn1) { $problems += 'PID_FRIENDLY_NAME not readable' }
            else {
                $all = [byte[]]$fn1
                if ($all.Length -lt 30) {
                    $fn2 = Get-PropertyBytes -Connection $conn -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.FRIENDLY_NAME -ElementCount 15 -StartIndex 16
                    if ($null -ne $fn2) { $all = [byte[]]($all + $fn2) }
                }
                # The name ends at the first NUL, not at the end of the buffer.
                $nameProp = ([System.Text.Encoding]::ASCII.GetString($all)).Split([char]0)[0].TrimEnd(' ')
                if ($nameProp -ne $desc.Device.FriendlyName) { $problems += "friendly name property '$nameProp' differs from DIB '$($desc.Device.FriendlyName)'" }
            }

            $sn = Get-PropertyBytes -Connection $conn -ObjectType $K.ObjType.DEVICE -PropertyId $K.Pid.SERIAL_NUMBER
            if ($null -eq $sn -or $sn.Length -lt 6) { $problems += 'PID_SERIAL_NUMBER (device object) not readable' }
            else {
                $snProp = ConvertTo-HexString -Bytes ([byte[]]$sn[0..5])
                if ($snProp -ne $desc.Device.SerialNumber) { $problems += "serial number property $snProp differs from DIB $($desc.Device.SerialNumber)" }
            }

            # The five properties above are the ones TSSH 4.2.2 compares against the DIB. They are NOT the
            # whole test: its first sentence says "reads ALL mandatory properties from the KNXnet/IP
            # parameter object". Checking only the comparable ones is how this case stayed green while the
            # KNXA tool reported PID_IP_ADDRESS, PID_SUBNET_MASK, PID_DEFAULT_GATEWAY and
            # PID_KNXNETIP_DEVICE_STATE as missing. A property that answers Void_DP is indistinguishable
            # from an absent one to a management client, so "readable at all" is the assertion here - the
            # VALUE of the configured IP config is 0.0.0.0 while the address comes from DHCP, which is a
            # legal value and not an absent element (03_08_03 2.5.11-2.5.13 p.12).
            $alsoMandatory = @(
                @{ Pid = $K.Pid.IP_ADDRESS;            Name = 'PID_IP_ADDRESS';            Len = 4 },
                @{ Pid = $K.Pid.SUBNET_MASK;           Name = 'PID_SUBNET_MASK';           Len = 4 },
                @{ Pid = $K.Pid.DEFAULT_GATEWAY;       Name = 'PID_DEFAULT_GATEWAY';       Len = 4 },
                # 03_08_03 2.5.20 p.14: "shall be implemented by any KNXnet/IP Server".
                @{ Pid = $K.Pid.KNXNETIP_DEVICE_STATE; Name = 'PID_KNXNETIP_DEVICE_STATE'; Len = 1 }
            )
            foreach ($m in $alsoMandatory) {
                $v = Get-PropertyBytes -Connection $conn -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $m.Pid
                if ($null -eq $v -or $v.Length -lt $m.Len) { $problems += "$($m.Name) missing (read returned no element)" }
                else { Add-KnxEvidence -Note "$($m.Name) = $(ConvertTo-HexString -Bytes ([byte[]]$v))" }
            }

            foreach ($p in $problems) { Add-KnxEvidence -Note $p }
            Assert-KnxTrue ($problems.Count -eq 0) ("mandatory properties inconsistent or missing: " + ($problems -join '; '))
        }
        finally { [void](Close-KnxConnection -Connection $conn) }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-4.2.3' -Title 'Write to read-only device property' -Clause 'TSSH 4.2.3, p.30 (fn 20205)' -Body {
        if ($Ctx.ReadOnly) { Set-KnxTestSkip 'profile ReadOnly - this case attempts a property write' }
        $conn = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $DMGMT -Layer -1
        Assert-KnxTrue $conn.Ok "could not open a device management connection ($($conn.StatusName))"
        try {
            # PID_CURRENT_IP_ADDRESS is read-only; the write must be refused, not silently
            # accepted. An accepted write here would change the device's address.
            $cemi = New-CemiMPropWrite -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.CURRENT_IP_ADDRESS -Data ([byte[]]@(0x00, 0x00, 0x00, 0x00))
            Add-KnxEvidence -Sent $cemi
            $r = Send-KnxDeviceConfiguration -Connection $conn -Cemi $cemi
            Assert-KnxTrue $r.Acked 'no DEVICE_CONFIGURATION_ACK for the write attempt'
            Assert-KnxTrue ($null -ne $r.Cemi) 'no confirmation for the write attempt - the device must answer, not stay silent'
            Add-KnxEvidence -Received $r.Cemi
            Assert-KnxEqual $K.Cemi.M_PROPWRITE_CON $r.Parsed.MessageCode 'confirmation is not an M_PropWrite.con'
            # Accepted per the prufvorschrift: "Read-only" or "Unspecified Error". The numeric
            # values come from cEmiErrorCode (knx_types.h): Read_Only = 0x05,
            # Unspecified_Error = 0x00. An earlier version of this case expected 0x03, which is
            # Out_Of_Min_Range - it would have failed a device that answered correctly.
            Assert-KnxTrue $r.Parsed.IsError 'device ACCEPTED a write to the read-only PID_CURRENT_IP_ADDRESS'
            Add-KnxEvidence -Note "error code 0x$('{0:X2}' -f $r.Parsed.ErrorCode)"
            Assert-KnxTrue (@(0x05, 0x00) -contains $r.Parsed.ErrorCode) "error code 0x$('{0:X2}' -f $r.Parsed.ErrorCode) is neither Read_Only (0x05) nor Unspecified_Error (0x00)"
        }
        finally { [void](Close-KnxConnection -Connection $conn) }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-4.2.4' -Title 'Read nonexisting device property' -Clause 'TSSH 4.2.4, p.31 (fn 20206)' -Body {
        $conn = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $DMGMT -Layer -1
        Assert-KnxTrue $conn.Ok "could not open a device management connection ($($conn.StatusName))"
        try {
            # Default parameter: PID 0xF0.
            $cemi = New-CemiMPropRead -ObjectType $K.ObjType.DEVICE -PropertyId 0xF0
            Add-KnxEvidence -Sent $cemi
            $r = Send-KnxDeviceConfiguration -Connection $conn -Cemi $cemi
            Assert-KnxTrue $r.Acked 'no DEVICE_CONFIGURATION_ACK'
            Assert-KnxTrue ($null -ne $r.Cemi) 'no confirmation for the nonexisting property - the device must answer'
            Add-KnxEvidence -Received $r.Cemi
            Assert-KnxTrue $r.Parsed.IsError 'device returned data for a property that does not exist (element count is not 0)'
            Add-KnxEvidence -Note "error code 0x$('{0:X2}' -f $r.Parsed.ErrorCode)"
            # Accepted per the prufvorschrift: "Void DP" or "Unspecified Error". From
            # cEmiErrorCode: Void_DP = 0x07, Unspecified_Error = 0x00.
            Assert-KnxTrue (@(0x07, 0x00) -contains $r.Parsed.ErrorCode) "error code 0x$('{0:X2}' -f $r.Parsed.ErrorCode) is neither Void_DP (0x07) nor Unspecified_Error (0x00)"
        }
        finally { [void](Close-KnxConnection -Connection $conn) }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-4.2.5' -Title 'Get/set programming mode by device property' -Clause 'TSSH 4.2.5, p.33 (fn 20207)' -Body {
        if ($Ctx.ReadOnly) { Set-KnxTestSkip 'profile ReadOnly - this case toggles programming mode' }
        $conn = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $DMGMT -Layer -1
        Assert-KnxTrue $conn.Ok "could not open a device management connection ($($conn.StatusName))"
        $restore = $null
        try {
            # PID_PROG_MODE = 54 lives on the DEVICE object (OT 0). On the KNXnet/IP parameter
            # object (OT 11) property 54 is PID_CURRENT_IP_ASSIGNMENT_METHOD - writing there
            # would attempt to change how the device gets its IP address, which is why this
            # case addresses the object explicitly rather than trusting the clause number.
            $before = Get-PropertyBytes -Connection $conn -ObjectType $K.ObjType.DEVICE -PropertyId $K.Pid.PROG_MODE
            Assert-KnxTrue ($null -ne $before -and $before.Length -ge 1) 'PID_PROG_MODE not readable on the device object'
            $restore = $before[0]
            $target = [byte](($before[0] -bxor 0x01) -band 0x01)   # default parameter: toggle

            $cemi = New-CemiMPropWrite -ObjectType $K.ObjType.DEVICE -PropertyId $K.Pid.PROG_MODE -Data ([byte[]]@($target))
            Add-KnxEvidence -Sent $cemi
            $w = Send-KnxDeviceConfiguration -Connection $conn -Cemi $cemi
            Assert-KnxTrue $w.Acked 'no ACK for the programming-mode write'
            Assert-KnxTrue ($null -ne $w.Cemi) 'no confirmation for the programming-mode write'
            Assert-KnxTrue (-not $w.Parsed.IsError) "programming-mode write refused with error 0x$('{0:X2}' -f $w.Parsed.ErrorCode)"

            Start-Sleep -Milliseconds 500
            # The DIB device-status bit 0 must now mirror what was written.
            $d = Get-KnxDescription -Ip $ip -Port $port
            Assert-KnxTrue ($null -ne $d -and $null -ne $d.Device) 'no fresh DIB to verify the programming mode against'
            $dibProg = 0; if ($d.Device.ProgMode) { $dibProg = 1 }
            Add-KnxEvidence -Note "wrote $target, DIB device status reports programming mode $dibProg"
            Assert-KnxEqual $target $dibProg 'DIB device status does not reflect the written programming mode'
        }
        finally {
            if ($null -ne $restore -and $conn.Ok) {
                $back = New-CemiMPropWrite -ObjectType $K.ObjType.DEVICE -PropertyId $K.Pid.PROG_MODE -Data ([byte[]]@($restore))
                [void](Send-KnxDeviceConfiguration -Connection $conn -Cemi $back -TimeoutMs 2000)
            }
            [void](Close-KnxConnection -Connection $conn)
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-4.2.6' -Title 'Get/set programming mode by memory access' -Clause 'TSSH 4.2.6, p.35 (fn 20208)' -Body {
        if ($Ctx.ReadOnly) { Set-KnxTestSkip 'profile ReadOnly - this case writes device memory' }
        if (-not $Ctx.TrafficIp) { Set-KnxTestSkip 'needs a second interface (-TrafficIp): the memory access runs over the KNX bus, not over the management connection' }
        if (-not $Ctx.BdutPa) { Set-KnxTestSkip 'BDUT individual address unknown (-BdutPa)' }

        # Measured 2026-08-15 against BOTH certified references and our device: all three
        # fail this case identically. Three devices do not share one defect - the test does.
        #
        # The prufvorschrift drives this connection-oriented: T_Connect, then A_Memory_Read
        # with a NUMBERED TPDU, and the device answers only after the client T_ACKs each
        # frame with the matching sequence number. This case sends the read but never
        # maintains that sequence/T_Ack state machine, so the peer legitimately stops
        # talking. Implementing it needs a real transport-layer client, not a one-shot send.
        Set-KnxTestSkip 'needs a connection-oriented transport client (T_Connect / sequence numbers / T_Ack); the current one-shot read is not a valid probe - verified against two certified devices, all three fail identically'
        # The prufvorschrift drives this over the bus: T_Connect, A_Memory_Read 0x60,
        # A_Memory_Write, A_Memory_Read, T_Disconnect - connection-oriented, with T_Acks.
        $tun = Get-KnxTrafficConnection -Ip $Ctx.TrafficIp
        Assert-KnxTrue ($null -ne $tun) 'no tunnel available on the traffic interface'
        $dst = ConvertTo-KnxPa -Address $Ctx.BdutPa
        $connected = $false
        try {
            $c = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $dst -Tpdu (New-TpduConnect) -Priority 0
            $r = Send-KnxTunnelCemi -Connection $tun -Cemi $c
            Assert-KnxTrue ($r.Status -eq 0) 'tunnel refused the T_Connect'
            $connected = $true
            Start-Sleep -Milliseconds 300

            $rd = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $dst -Tpdu (New-TpduMemoryRead -Address 0x0060 -Count 1 -Sequence 0) -Priority 0
            Add-KnxEvidence -Sent $rd
            $r = Send-KnxTunnelCemi -Connection $tun -Cemi $rd
            Assert-KnxTrue ($r.Status -eq 0) 'tunnel refused the A_Memory_Read'

            # Collect what comes back: the memory response must arrive within a few seconds.
            $resp = $null
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            while ([DateTime]::UtcNow -lt $deadline) {
                $in = Receive-KnxTunnelCemi -Connection $tun -TimeoutMs 1500
                if ($null -eq $in) { continue }
                $ld = Read-CemiLData -Cemi $in.Cemi
                if ($null -eq $ld -or $ld.Tpdu.Length -lt 2) { continue }
                if ($ld.Source -ne $dst) { continue }
                $apci = Get-TpduApci -Tpdu $ld.Tpdu
                if (($apci -band 0x3C0) -eq $K.Apci.MEMORY_RESPONSE) { $resp = $ld; break }
            }
            Assert-KnxTrue ($null -ne $resp) 'no A_Memory_Response for memory cell 0x0060'
            Add-KnxEvidence -Received $resp.Tpdu
            Assert-KnxTrue ($resp.Tpdu.Length -ge 5) 'A_Memory_Response carries no data octet'
            Add-KnxEvidence -Note ("memory cell 0x0060 = 0x{0:X2}" -f $resp.Tpdu[4])
        }
        finally {
            if ($connected) {
                $d = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $dst -Tpdu (New-TpduDisconnect) -Priority 0
                [void](Send-KnxTunnelCemi -Connection $tun -Cemi $d -TimeoutMs 2000)
            }
        }
    }

    foreach ($case in @(
            @{ Id = 'H-4.2.7'; Title = 'Change individual address';               Clause = 'TSSH 4.2.7, p.36 (fn 20209)' },
            @{ Id = 'H-4.2.8'; Title = 'Change individual address by IP property'; Clause = 'TSSH 4.2.8, p.37 (fn 20210)' })) {
        Invoke-KnxTestCase -Suite $SuiteTitle -Id $case.Id -Title $case.Title -Clause $case.Clause -Body {
            if (-not $Ctx.AllowDestructive) {
                Set-KnxTestSkip 'changes the device individual address - needs -IncludeDestructive with profile Full'
            }
            $conn = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $DMGMT -Layer -1
            Assert-KnxTrue $conn.Ok "could not open a device management connection ($($conn.StatusName))"
            $original = $null
            try {
                $cur = Get-PropertyBytes -Connection $conn -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.KNX_INDIVIDUAL_ADDRESS
                Assert-KnxTrue ($null -ne $cur -and $cur.Length -ge 2) 'PID_KNX_INDIVIDUAL_ADDRESS not readable'
                $original = [byte[]]$cur[0..1]

                # The prufvorschrift uses 0x1200 (1.2.0).
                $target = [byte[]]@(0x12, 0x00)
                $cemi = New-CemiMPropWrite -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.KNX_INDIVIDUAL_ADDRESS -Data $target
                Add-KnxEvidence -Sent $cemi
                $w = Send-KnxDeviceConfiguration -Connection $conn -Cemi $cemi
                Assert-KnxTrue $w.Acked 'no ACK for the address write'
                Assert-KnxTrue ($null -ne $w.Cemi) 'no confirmation for the address write'
                Assert-KnxTrue (-not $w.Parsed.IsError) "address write refused with error 0x$('{0:X2}' -f $w.Parsed.ErrorCode)"

                Start-Sleep -Milliseconds 800
                $back = Get-PropertyBytes -Connection $conn -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.KNX_INDIVIDUAL_ADDRESS
                Assert-KnxTrue ($null -ne $back -and $back.Length -ge 2) 'address property not readable after the write'
                Assert-KnxBytes $target ([byte[]]$back[0..1]) 'KNXnet/IP address property does not reflect the written address'

                $d = Get-KnxDescription -Ip $ip -Port $port
                Assert-KnxTrue ($null -ne $d -and $null -ne $d.Device) 'no fresh DIB after the address change'
                Assert-KnxEqual '1.2.0' $d.Device.IndividualAddr 'DIB does not reflect the changed individual address'
            }
            finally {
                if ($null -ne $original -and $conn.Ok) {
                    $restore = New-CemiMPropWrite -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.KNX_INDIVIDUAL_ADDRESS -Data $original
                    [void](Send-KnxDeviceConfiguration -Connection $conn -Cemi $restore -TimeoutMs 3000)
                }
                [void](Close-KnxConnection -Connection $conn)
            }
        }
    }

    # Does this device serve the cEMI Transport Layer at all? 03_08_03 4.2.5 p.23 marks the T_Data_*
    # services X at Device Management v1 and M only at v2, and 2.6.1.2 p.18 tells a server without them to
    # acknowledge and stay silent. Probed once and cached, so a device that does not have them reports the
    # dependent cases N-A instead of failing them.
    function Test-KnxCemiTransportServed {
        param([string]$Ip, [int]$Port, [int]$ConnType)
        if ($null -ne $script:CemiTransportServed) { return $script:CemiTransportServed }
        $script:CemiTransportServed = $false
        $probe = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $ConnType -Layer -1
        if ($probe.Ok) {
            $cemi = New-CemiTransport -MessageCode 0x4A -Tpdu (New-TpduPropertyValueRead)
            $r = Send-KnxDeviceConfiguration -Connection $probe -Cemi $cemi -TimeoutMs 3000
            $script:CemiTransportServed = ($null -ne $r.Cemi)
            [void](Close-KnxConnection -Connection $probe)
            # With a single management slot (KNX_TUNNELING_DEVMGMT=1) the server needs a moment to reap the
            # channel; opening the next one too fast is answered E_NO_MORE_CONNECTIONS and the case that
            # follows fails for the probe's sake.
            Start-Sleep -Milliseconds 500
        }
        return $script:CemiTransportServed
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-4.2.13' -Title 'Device Object address properties report the device address' -Clause 'TSSH 4.2.7/4.2.8, p.36-37 (fn 20209/20210)' -Body {
        # Both tool cases set the individual address and then read, over a DEVICE MANAGEMENT connection,
        # OT 0 PID_SUBNET_ADDR and PID_DEVICE_ADDR expecting the two octets of the address they just set
        # (0x1200 -> 0x12 / 0x00). Changing the address is invasive, needs programming mode and a restart,
        # so this reads the CURRENT address instead and holds the two octets against it - the part that
        # actually failed, without touching the device.
        #
        # 03_06_03 4.2.2.2 Table 15 p.114 puts the address of the cEMI SERVER DEVICE on these two, and
        # Vol.6 Profiles A.3.2 fn.79 p.153 says they denote the address of the end device hosting the
        # interface; fn.77/78 make them mandatory for a cEMI server with its own address on TP1. The cEMI
        # CLIENT address lives on the cEMI Server Object instead (PID_CLIENT_SNA / PID_CLIENT_DEVICE_ADDRESS,
        # 03_06_03 Table 16 p.115). Handing the client address out here reads as 0x0000 to a tool.
        $desc = Get-KnxDescription -Ip $ip -Port $port
        Assert-KnxTrue ($null -ne $desc -and $null -ne $desc.Device) 'no DEVICE_INFO DIB to compare against'

        $conn = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $DMGMT -Layer -1
        Assert-KnxTrue $conn.Ok "could not open a device management connection ($($conn.StatusName))"
        try {
            $ia = Get-PropertyBytes -Connection $conn -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.KNX_INDIVIDUAL_ADDRESS
            Assert-KnxTrue ($null -ne $ia -and $ia.Length -ge 2) 'PID_KNX_INDIVIDUAL_ADDRESS not readable'
            $raw = Get-Uint16 -Bytes $ia -Offset 0

            $sub = Get-PropertyBytes -Connection $conn -ObjectType $K.ObjType.DEVICE -PropertyId $K.Pid.SUBNET_ADDR
            $dev = Get-PropertyBytes -Connection $conn -ObjectType $K.ObjType.DEVICE -PropertyId $K.Pid.DEVICE_ADDR
            Assert-KnxTrue ($null -ne $sub -and $sub.Length -ge 1) 'PID_SUBNET_ADDR (device object) not readable'
            Assert-KnxTrue ($null -ne $dev -and $dev.Length -ge 1) 'PID_DEVICE_ADDR (device object) not readable'

            $expSub = ($raw -shr 8) -band 0xFF
            $expDev = $raw -band 0xFF
            Add-KnxEvidence -Note ("individual address {0} -> expect subnet 0x{1:X2}, device 0x{2:X2}; read 0x{3:X2} / 0x{4:X2}" -f `
                                   (ConvertFrom-KnxPa -Raw $raw), $expSub, $expDev, $sub[0], $dev[0])
            Assert-KnxEqual $expSub $sub[0] 'PID_SUBNET_ADDR does not carry the high octet of the device individual address'
            Assert-KnxEqual $expDev $dev[0] 'PID_DEVICE_ADDR does not carry the low octet of the device individual address'
        }
        finally { [void](Close-KnxConnection -Connection $conn) }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-4.2.14' -Title 'cEMI Transport Layer mode - T_Connect refused while a DM connection is open' -Clause 'TSSH 8.3.2, p.158 (fn 60202); 03_08_03 2.6.1.2 p.18' -Body {
        # 03_08_03 2.6.1.2 p.18: an established device management connection switches the transport layer to
        # cEMI Transport Layer mode "for the duration of the connection", and 2.6.1.6 p.19 leaves it again on
        # close. What a peer sees is that a T_Connect is refused with T_Disconnect while the mode is active.
        #
        # Both halves are asserted, and the FIRST one is the important one: without an open device
        # management connection a T_Connect must still be accepted silently. That is the path ETS uses to
        # program this device, and a mode implemented as "hold the layer" would break it.
        if (-not $Ctx.BdutPa) { Set-KnxTestSkip 'BDUT individual address unknown (-BdutPa)' }
        if (-not (Test-KnxCemiTransportServed -Ip $ip -Port $port -ConnType $DMGMT)) {
            Set-KnxTestNotApplicable 'device does not serve the cEMI Transport Layer (03_08_03 4.2.5 p.23: X at Device Management v1), so there is no mode to enter'
        }
        $tun = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer 0x02
        Assert-KnxTrue $tun.Ok "could not open a tunnelling connection ($($tun.StatusName))"
        $dm = $null
        try {
            $target = ConvertTo-KnxPa -Address $Ctx.BdutPa
            $connectCemi    = New-CemiLData -MessageCode 0x11 -Source 0 -Destination $target -Tpdu (New-TpduConnect)    -Priority 0
            $disconnectCemi = New-CemiLData -MessageCode 0x11 -Source 0 -Destination $target -Tpdu (New-TpduDisconnect) -Priority 0

            # --- no device management connection: the connect must be accepted (no T_Disconnect back) ---
            [void](Send-KnxTunnelCemi -Connection $tun -Cemi $connectCemi)
            $refusedWhenIdle = Wait-KnxTpduFromTunnel -Connection $tun -Tpci 0x81 -TimeoutMs 2000
            [void](Send-KnxTunnelCemi -Connection $tun -Cemi $disconnectCemi)
            Add-KnxEvidence -Note "without a device management connection the T_Connect was $(if ($null -ne $refusedWhenIdle) { 'REFUSED' } else { 'accepted' })"
            Assert-KnxTrue ($null -eq $refusedWhenIdle) 'a T_Connect was refused although no device management connection was open - connection-oriented access to the device is broken'

            # --- device management connection open: the connect must be refused ---
            $dm = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $DMGMT -Layer -1
            Assert-KnxTrue $dm.Ok "could not open a device management connection ($($dm.StatusName))"
            Start-Sleep -Milliseconds 700   # the device picks the mode up in its next loop pass

            [void](Send-KnxTunnelCemi -Connection $tun -Cemi $connectCemi)
            $refusedInMode = Wait-KnxTpduFromTunnel -Connection $tun -Tpci 0x81 -TimeoutMs 3000
            Add-KnxEvidence -Note "with a device management connection open the T_Connect was $(if ($null -ne $refusedInMode) { 'refused with T_Disconnect' } else { 'ACCEPTED' })"
            Assert-KnxTrue ($null -ne $refusedInMode) 'no T_Disconnect while a device management connection holds the transport layer (03_08_03 2.6.1.2 p.18)'
        }
        finally {
            if ($null -ne $dm -and $dm.Ok) { [void](Close-KnxConnection -Connection $dm) }
            [void](Close-KnxConnection -Connection $tun)
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-4.2.15' -Title 'Device management refused while a transport connection is open' -Clause 'TSSH 8.3.2, p.158 (fn 60202) part 2; 03_08_03 2.6.1.2 p.18' -Body {
        # Part 2 of the same tool case: a transport connection is opened FIRST, then a device management
        # connection is requested. Opening one switches the Transport Layer into cEMI Transport Layer mode
        # (03_08_03 2.6.1.2 p.18), which a layer that already carries a connection cannot do, so the request
        # must be answered with E_NO_MORE_CONNECTIONS rather than silently serving two transport peers.
        if (-not $Ctx.BdutPa) { Set-KnxTestSkip 'BDUT individual address unknown (-BdutPa)' }
        if (-not (Test-KnxCemiTransportServed -Ip $ip -Port $port -ConnType $DMGMT)) {
            Set-KnxTestNotApplicable 'device does not serve the cEMI Transport Layer (03_08_03 4.2.5 p.23: X at Device Management v1), so a management connection never takes the transport layer'
        }

        # A management connection must be available to begin with, otherwise the case proves nothing.
        $probe = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $DMGMT -Layer -1
        Assert-KnxTrue $probe.Ok "no device management connection available before the test ($($probe.StatusName))"
        [void](Close-KnxConnection -Connection $probe)
        Start-Sleep -Milliseconds 300

        $tun = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer 0x02
        Assert-KnxTrue $tun.Ok "could not open a tunnelling connection ($($tun.StatusName))"
        $connected = $false
        try {
            $target = ConvertTo-KnxPa -Address $Ctx.BdutPa
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Source 0 -Destination $target -Tpdu (New-TpduConnect) -Priority 0
            [void](Send-KnxTunnelCemi -Connection $tun -Cemi $cemi)
            $connected = $true
            Start-Sleep -Milliseconds 400   # the device picks the state up in its next loop pass

            $dm = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $DMGMT -Layer -1
            if ($null -ne $dm.Response) { Add-KnxEvidence -Received $dm.Response }
            Add-KnxEvidence -Note "device management connect while a transport connection is open -> $(if ($dm.Ok) { "ACCEPTED on channel $($dm.Channel)" } else { $dm.StatusName })"
            if ($dm.Ok) { [void](Close-KnxConnection -Connection $dm) }
            Assert-KnxTrue (-not $dm.Ok) 'the device accepted a device management connection although its transport layer already carried a connection (08_TSSH 8.3.2 p.158)'
            Assert-KnxStatus $K.Error.E_NO_MORE_CONNECTIONS $dm.Status 'wrong status when the transport layer is occupied'
        }
        finally {
            if ($connected) {
                $d = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Source 0 -Destination (ConvertTo-KnxPa -Address $Ctx.BdutPa) -Tpdu (New-TpduDisconnect) -Priority 0
                [void](Send-KnxTunnelCemi -Connection $tun -Cemi $d -TimeoutMs 2000)
            }
            [void](Close-KnxConnection -Connection $tun)
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-4.2.9' -Title 'Device Configuration Request - Invalid Endpoint' -Clause 'TSSH 4.2.9, p.37 (fn 20201)' -Body {
        # Default parameter: port 1.
        $cemi = New-CemiMPropRead -ObjectType $K.ObjType.DEVICE -PropertyId $K.Pid.OBJECT_TYPE
        $r = Send-RawDeviceConfiguration -Ip $ip -Port 1 -Cemi $cemi
        Add-KnxEvidence -Sent $r.Sent
        if ($r.Received.Count -gt 0) { Add-KnxEvidence -Received $r.Received[0].Bytes }
        Assert-KnxTrue ($r.Received.Count -eq 0) "device answered a request sent to port 1 ($($r.Received.Count) frame(s))"
        Assert-KnxTrue (Test-KnxAlive -Ip $ip -Port $port) 'device stopped answering after the invalid-endpoint frame'
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-4.2.10' -Title 'Device Configuration Request - Unconnected Endpoint' -Clause 'TSSH 4.2.10, p.38 (fn 20202)' -Body {
        # Two shapes, because they can fail independently: channel 0 is never allocated and
        # may be special-cased, while a NON-ZERO channel that was simply never granted has to
        # be rejected by an actual lookup. A guard that only rejects 0 leaves that second door
        # open, and a test that only sends 0 would report success anyway.
        $cemi = New-CemiMPropRead -ObjectType $K.ObjType.DEVICE -PropertyId $K.Pid.OBJECT_TYPE
        foreach ($ch in @(0, 200)) {
            $r = Send-RawDeviceConfiguration -Ip $ip -Port $port -Cemi $cemi -Channel $ch
            Add-KnxEvidence -Sent $r.Sent -Note "channel $ch -> $($r.Received.Count) frame(s)"
            if ($r.Received.Count -gt 0) { Add-KnxEvidence -Received $r.Received[0].Bytes }
            Assert-KnxTrue ($r.Received.Count -eq 0) "device answered a device configuration request on unopened channel $ch ($($r.Received.Count) frame(s))"
        }
        Assert-KnxTrue (Test-KnxAlive -Ip $ip -Port $port) 'device stopped answering after the unconnected-endpoint frames'
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-4.2.11' -Title 'Repeat and timeout after missing ACK' -Clause 'TSSH 4.2.11, p.39 (fn 20211)' -Body {
        if ($Ctx.SkipSlow) { Set-KnxTestSkip 'measures a 3 x 10 s repetition sequence - excluded by -SkipSlow' }
        # Expected: the device repeats its confirmation 3 times, 10 s apart, then disconnects.
        $conn = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $DMGMT -Layer -1
        Assert-KnxTrue $conn.Ok "could not open a device management connection ($($conn.StatusName))"
        # Declared before the try so the cleanup can always read them, even if the body
        # throws on its first statement.
        $repeats = 0
        $disconnected = $false
        $stamps = @()
        try {
            $cemi = New-CemiMPropRead -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.KNX_INDIVIDUAL_ADDRESS
            $f = New-KnxDeviceConfigurationRequest -Channel $conn.Channel -Sequence 0 -Cemi $cemi
            Add-KnxEvidence -Sent $f
            Send-KnxFrame -Socket $conn.Socket -Frame $f -Ip $ip -Port $port

            # Deliberately never send DEVICE_CONFIGURATION_ACK for the device's confirmation.
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $deadline = [DateTime]::UtcNow.AddSeconds(60)
            while ([DateTime]::UtcNow -lt $deadline) {
                $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
                $r = Wait-KnxService -Socket $conn.Socket `
                                     -Service @($K.Service.DEVICE_CONFIGURATION_REQUEST, $K.Service.DEVICE_CONFIGURATION_ACK, $K.Service.DISCONNECT_REQUEST) `
                                     -TimeoutMs $left
                if ($r.TimedOut) { break }
                if ($r.Header.Service -eq $K.Service.DEVICE_CONFIGURATION_REQUEST) {
                    $repeats++
                    $stamps += [Math]::Round($sw.Elapsed.TotalSeconds, 1)
                    continue
                }
                if ($r.Header.Service -eq $K.Service.DISCONNECT_REQUEST) { $disconnected = $true; break }
            }
            $sw.Stop()
            Add-KnxEvidence -Note "confirmation seen $repeats time(s) at $($stamps -join ', ') s; disconnect $(if ($disconnected) { 'observed' } else { 'NOT observed' })"
            Assert-KnxTrue ($repeats -ge 1) 'device sent no confirmation at all'
            # 03_08_03 p.7 is the rule for DEVICE_CONFIGURATION_REQUEST: on a missing
            # DEVICE_CONFIGURATION_ACK the sender repeats the frame THREE times and then
            # terminates the connection - original plus three = 4 sendings. (03_08_04's
            # "repeated once" is the TUNNELLING_REQUEST rule and does not apply here; taking
            # it made this case pass our device and fail both certified references, which is
            # what exposed the mix-up.)
            Assert-KnxTrue ($repeats -eq 4) "device sent the unacknowledged confirmation $repeats time(s), expected 4 (original + three repetitions per 03_08_03 p.7)"
            Assert-KnxTrue $disconnected 'device never disconnected after the unacknowledged repetitions'
        }
        finally {
            # If the device did NOT drop the connection, this case would otherwise hold a
            # management slot until the 120 s reaper fires - starving every later case.
            # Releasing it explicitly costs nothing when the device already disconnected.
            if (-not $disconnected) { [void](Close-KnxConnection -Connection $conn -TimeoutMs 1000) }
            else { try { $conn.Socket.Dispose() } catch { } }
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-4.2.12' -Title 'Bus connection interrupted - device state indications' -Clause 'TSSH 4.2.12, p.40 (fn 20212)' -Body {
        if ($Ctx.ReadOnly) { Set-KnxTestSkip 'profile ReadOnly - the load switch writes to the bus' }
        if (-not $Ctx.LoadSwitchGa) { Set-KnxTestSkip 'this rig has no load switch - pass -LoadSwitchGa/-LoadSwitchPa when one is fitted (TSSH 1.2.2 specifies 1/1/50 on 1.1.50)' }
        if (-not $Ctx.LoadSwitchVia) { Set-KnxTestSkip 'no interface to drive the load switch (-TrafficIp / -LoadSwitchVia)' }

        $conn = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $DMGMT -Layer -1
        Assert-KnxTrue $conn.Ok "could not open a device management connection ($($conn.StatusName))"
        $opened = $false
        try {
            $off = Invoke-KnxLoadSwitch -Via $Ctx.LoadSwitchVia -On $false -GroupAddress $Ctx.LoadSwitchGa
            Assert-KnxTrue $off.Ok $off.Reason
            $opened = $true
            $indOff = Wait-KnxPropInfo -Connection $conn -Ip $ip -Port $port -TimeoutMs 8000

            $on = Invoke-KnxLoadSwitch -Via $Ctx.LoadSwitchVia -On $true -GroupAddress $Ctx.LoadSwitchGa
            $opened = $false
            Assert-KnxTrue $on.Ok $on.Reason
            $indOn = Wait-KnxPropInfo -Connection $conn -Ip $ip -Port $port -TimeoutMs 8000

            Add-KnxEvidence -Note "indication after bus loss: $(if ($null -ne $indOff) { 'yes' } else { 'no' }); after bus return: $(if ($null -ne $indOn) { 'yes' } else { 'no' })"
            if ($null -ne $indOff) { Add-KnxEvidence -Received $indOff }
            Assert-KnxTrue ($null -ne $indOff) 'no KNXNETIP_DEVICE_STATE property info indication after the bus was disconnected'
            Assert-KnxTrue ($null -ne $indOn) 'no KNXNETIP_DEVICE_STATE property info indication after the bus was reconnected'
        }
        finally {
            if ($opened) {
                $back = Invoke-KnxLoadSwitch -Via $Ctx.LoadSwitchVia -On $true -GroupAddress $Ctx.LoadSwitchGa
                if (-not $back.Ok) { Write-Host "    WARNING: could not re-close the load switch - $($back.Reason)" -ForegroundColor Red }
            }
            [void](Close-KnxConnection -Connection $conn)
        }
    }

    # ── 4.3 cEMI Transport Layer ────────────────────────────────────────────────

    # 4.3.1 - 4.3.4: sent WITHOUT a connection. The device must stay completely silent -
    # no ACK, and for the .req variants no responding request either.
    $unconnected = @(
        @{ Id = 'H-4.3.1'; Title = 'T_Data_Individual.req to unconnected BDUT'; Clause = 'TSSH 4.3.1, p.42 (fn 20301)'; Mc = 0x4A; Resp = $false },
        @{ Id = 'H-4.3.2'; Title = 'T_Data_Individual.ind to unconnected BDUT'; Clause = 'TSSH 4.3.2, p.43 (fn 20302)'; Mc = 0x94; Resp = $true },
        @{ Id = 'H-4.3.3'; Title = 'T_Data_Connected.req to unconnected BDUT';  Clause = 'TSSH 4.3.3, p.44 (fn 20303)'; Mc = 0x41; Resp = $false },
        @{ Id = 'H-4.3.4'; Title = 'T_Data_Connected.ind to unconnected BDUT';  Clause = 'TSSH 4.3.4, p.45 (fn 20304)'; Mc = 0x89; Resp = $true }
    )
    foreach ($c in $unconnected) {
        $mc = $c.Mc; $isResponse = $c.Resp
        Invoke-KnxTestCase -Suite $SuiteTitle -Id $c.Id -Title $c.Title -Clause $c.Clause -Body {
            Add-KnxExpectedLog 'nothing - an unconnected request must be dropped without a trace of an open channel'
            $tpdu = if ($isResponse) { New-TpduPropertyValueResponse } else { New-TpduPropertyValueRead }
            $cemi = New-CemiTransport -MessageCode $mc -Tpdu $tpdu
            # Channel 0 AND a never-granted non-zero channel - see the note in H-4.2.10.
            foreach ($ch in @(0, 200)) {
                $r = Send-RawDeviceConfiguration -Ip $ip -Port $port -Cemi $cemi -Channel $ch
                Add-KnxEvidence -Sent $r.Sent -Note "channel $ch -> $($r.Received.Count) frame(s)"
                if ($r.Received.Count -gt 0) {
                    Add-KnxEvidence -Received $r.Received[0].Bytes
                    $h = Read-KnxHeader -Frame $r.Received[0].Bytes
                    Add-KnxEvidence -Note "unexpected answer on channel $ch : $($h.ServiceName)"
                }
                Assert-KnxTrue ($r.Received.Count -eq 0) "device answered a transport-layer frame on unopened channel $ch ($($r.Received.Count) frame(s))"
            }
            Assert-KnxTrue (Test-KnxAlive -Ip $ip -Port $port) 'device stopped answering afterwards'
        }
    }

    # 4.3.5 - 4.3.8: over an open connection. The .req variants must be acknowledged AND
    # answered with an .ind; the .ind variants must be acknowledged and NOTHING more.
    $connected = @(
        @{ Id = 'H-4.3.5'; Title = 'T_Data_Individual.req to BDUT'; Clause = 'TSSH 4.3.5, p.46 (fn 20305)'; Mc = 0x4A; Resp = $false; Expect = 0x94; Svc = 'T_Data_Individual' },
        @{ Id = 'H-4.3.6'; Title = 'T_Data_Individual.ind to BDUT'; Clause = 'TSSH 4.3.6, p.48 (fn 20306)'; Mc = 0x94; Resp = $true;  Expect = -1;   Svc = 'T_Data_Individual' },
        @{ Id = 'H-4.3.7'; Title = 'T_Data_Connected.req to BDUT';  Clause = 'TSSH 4.3.7, p.49 (fn 20307)'; Mc = 0x41; Resp = $false; Expect = 0x89; Svc = 'T_Data_Connected' },
        @{ Id = 'H-4.3.8'; Title = 'T_Data_Connected.ind to BDUT';  Clause = 'TSSH 4.3.8, p.51 (fn 20308)'; Mc = 0x89; Resp = $true;  Expect = -1;   Svc = 'T_Data_Connected' }
    )
    # An ".ind" case only asserts that NOTHING comes back. A device that silently drops the
    # whole transport message code therefore passes it without implementing anything - a
    # vacuous pass that reports "2 of 4 green" for a service that is 0 of 4 implemented.
    # The ".req" case for the same service runs first and records whether the device answers
    # it at all; if it does not, the ".ind" case is reported N-A instead of green.
    $script:TransportServed = @{}
    foreach ($c in $connected) {
        $mc = $c.Mc; $isResponse = $c.Resp; $expectMc = $c.Expect; $svc = $c.Svc
        Invoke-KnxTestCase -Suite $SuiteTitle -Id $c.Id -Title $c.Title -Clause $c.Clause -Body {
            $conn = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $DMGMT -Layer -1
            Assert-KnxTrue $conn.Ok "could not open a device management connection ($($conn.StatusName))"
            try {
                $tpdu = if ($isResponse) { New-TpduPropertyValueResponse } else { New-TpduPropertyValueRead }
                $cemi = New-CemiTransport -MessageCode $mc -Tpdu $tpdu
                Add-KnxEvidence -Sent $cemi
                # A short window is enough: the "only ACK" cases must not be given time to
                # look like a pass just because nothing arrived yet.
                $r = Send-KnxDeviceConfiguration -Connection $conn -Cemi $cemi -TimeoutMs 3000
                Assert-KnxTrue $r.Acked 'no DEVICE_CONFIGURATION_ACK'
                # Record before asserting: an assertion throws, and the ".ind" sibling needs
                # this answer even when the ".req" case fails.
                if ($expectMc -ge 0) { $script:TransportServed[$svc] = ($null -ne $r.Cemi) }
                if ($expectMc -lt 0) {
                    if (-not $script:TransportServed[$svc]) {
                        Set-KnxTestNotApplicable "device does not process $svc at all (its .req sibling got no response) - passing this case would only mean nothing came back, which any device without the service does"
                    }
                    if ($null -ne $r.Cemi) { Add-KnxEvidence -Received $r.Cemi }
                    Assert-KnxTrue ($null -eq $r.Cemi) 'device answered an .ind with a further request - only the ACK is allowed'
                }
                else {
                    # 03_08_03 2.6.1.2 p.18, "General exception handling": a cEMI Server that does NOT
                    # support the cEMI Transport Layer mode shall ignore a T_Data_Individual.req /
                    # T_Data_Connected.req and confirm only with a DEVICE_CONFIGURATION_ACK. Acked but
                    # silent is therefore the conformant answer of a device without the service, not a
                    # defect - and it is indistinguishable on the wire from a broken implementation.
                    if ($null -eq $r.Cemi) {
                        Set-KnxTestNotApplicable "device acknowledged and stayed silent - the prescribed behaviour of a cEMI server without the cEMI Transport Layer mode (03_08_03 2.6.1.2 p.18). The service is optional at Device Management v1 (03_08_03 4.2.5 p.23)"
                    }
                    Add-KnxEvidence -Received $r.Cemi
                    Assert-KnxEqual ('0x{0:X2}' -f $expectMc) ('0x{0:X2}' -f $r.Cemi[0]) 'responding request carries the wrong cEMI message code'
                    $ld = Read-CemiLData -Cemi $r.Cemi
                    Assert-KnxTrue ($null -ne $ld -and $ld.Tpdu.Length -ge 2) 'responding request has no usable TPDU'
                    Assert-KnxEqual '0x3D6' ('0x{0:X3}' -f (Get-TpduApci -Tpdu $ld.Tpdu)) 'responding request is not an A_PropertyValue_Response'
                }
            }
            finally { [void](Close-KnxConnection -Connection $conn) }
        }
    }

    # 4.3.9 - 4.3.12: an M_PropRead.req must still work after each transport-layer frame.
    # This is the real point of the block: a transport frame must not wedge the state machine.
    $after = @(
        @{ Id = 'H-4.3.9';  Title = 'M_PropRead.req after T_Data_Individual.req'; Clause = 'TSSH 4.3.9, p.52 (fn 20309)';  Mc = 0x4A; Resp = $false },
        @{ Id = 'H-4.3.10'; Title = 'M_PropRead.req after T_Data_Individual.ind'; Clause = 'TSSH 4.3.10, p.55 (fn 20310)'; Mc = 0x94; Resp = $true },
        @{ Id = 'H-4.3.11'; Title = 'M_PropRead.req after T_Data_Connected.req';  Clause = 'TSSH 4.3.11, p.57 (fn 20311)'; Mc = 0x41; Resp = $false },
        @{ Id = 'H-4.3.12'; Title = 'M_PropRead.req after T_Data_Connected.ind';  Clause = 'TSSH 4.3.12, p.60 (fn 20312)'; Mc = 0x89; Resp = $true }
    )
    foreach ($c in $after) {
        $mc = $c.Mc; $isResponse = $c.Resp
        Invoke-KnxTestCase -Suite $SuiteTitle -Id $c.Id -Title $c.Title -Clause $c.Clause -Body {
            $conn = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $DMGMT -Layer -1
            Assert-KnxTrue $conn.Ok "could not open a device management connection ($($conn.StatusName))"
            try {
                $tpdu = if ($isResponse) { New-TpduPropertyValueResponse } else { New-TpduPropertyValueRead }
                $pre = New-CemiTransport -MessageCode $mc -Tpdu $tpdu
                Add-KnxEvidence -Sent $pre
                [void](Send-KnxDeviceConfiguration -Connection $conn -Cemi $pre -TimeoutMs 3000)

                $cemi = New-CemiMPropRead -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.KNX_INDIVIDUAL_ADDRESS
                $r = Send-KnxDeviceConfiguration -Connection $conn -Cemi $cemi -TimeoutMs 4000
                Assert-KnxTrue $r.Acked 'M_PropRead.req was not acknowledged after the transport-layer frame'
                Assert-KnxTrue ($null -ne $r.Cemi) 'no M_PropRead.con after the transport-layer frame - the state machine is stuck'
                Add-KnxEvidence -Received $r.Cemi
                Assert-KnxEqual $K.Cemi.M_PROPREAD_CON $r.Parsed.MessageCode 'answer is not an M_PropRead.con'
                Assert-KnxTrue (-not $r.Parsed.IsError) "property read failed with error 0x$('{0:X2}' -f $r.Parsed.ErrorCode) after the transport-layer frame"
            }
            finally { [void](Close-KnxConnection -Connection $conn) }
        }
    }
}
