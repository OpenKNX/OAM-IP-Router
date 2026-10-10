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
    have seen. The distinction that decides each result is narrow - some expect an ACK
    AND a following request, some expect ONLY an ACK, some expect complete silence.
    Getting "only ACK" wrong by accepting any answer would pass a broken device.

    The cEMI encodings come verbatim from the frame tables (AN118) and are pinned by
    self-test vectors in KnxTest.psm1, so a wrong encoding fails offline, not here.
#>

Set-StrictMode -Version Latest
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/KnxDevice.psm1') -Force -DisableNameChecking

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

function Invoke-KnxMReset {
    <#
    .SYNOPSIS
        Sends M_Reset.req on a device-management connection; collects the ACK, an M_Reset.ind and a server DISCONNECT_REQUEST.
    .DESCRIPTION
        M_Reset is a Basic Restart (03_06_03 4.1.7.5.1 p.111). M_Reset.ind is optional for a KNXnet/IP server (p.112);
        the restart closes every KNXnet/IP connection (03_05_02 3.7.1.1.1 p.78) by t1 = 1 s (p.79). The socket stays
        open so the caller can check the old channel once the device is back (Test-KnxChannelGone).
    #>
    param([Parameter(Mandatory)]$Connection, [int]$WaitMs = 1200)
    $K = Get-KnxConstants
    $frame = New-KnxDeviceConfigurationRequest -Channel $Connection.Channel -Sequence $Connection.SeqSend -Cemi (New-CemiMReset)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Send-KnxFrame -Socket $Connection.Socket -Frame $frame -Ip $Connection.Ip -Port $Connection.Port
    $acked = $false; $ind = $false; $closedBy = 'none'
    while ($sw.ElapsedMilliseconds -lt $WaitMs -and $closedBy -eq 'none') {
        $r = Wait-KnxService -Socket $Connection.Socket -TimeoutMs ([int]([Math]::Max(1, $WaitMs - $sw.ElapsedMilliseconds))) `
                             -Service @($K.Service.DEVICE_CONFIGURATION_ACK, $K.Service.DEVICE_CONFIGURATION_REQUEST, $K.Service.DISCONNECT_REQUEST)
        if ($r.TimedOut) { break }
        $b = $r.Header.Body
        if ($r.Header.Service -eq $K.Service.DEVICE_CONFIGURATION_ACK) { $acked = ($b.Length -ge 4 -and $b[3] -eq 0) }
        elseif ($r.Header.Service -eq $K.Service.DEVICE_CONFIGURATION_REQUEST) {
            # Any server request is acknowledged; only an F0h cEMI is the indication (an M_PropInfo.ind may come first).
            if ($b.Length -ge 4) { Send-KnxFrame -Socket $Connection.Socket -Frame (New-KnxDeviceConfigurationAck -Channel $b[1] -Sequence $b[2]) -Ip $Connection.Ip -Port $Connection.Port }
            if ($b.Length -ge 5 -and $b[4] -eq $K.Cemi.M_RESET_IND) { $ind = $true }
        }
        else {
            if ($b.Length -ge 1) { Send-KnxFrame -Socket $Connection.Socket -Frame (New-KnxDisconnectResponse -Channel $b[0] -Status 0) -Ip $Connection.Ip -Port $Connection.Port }
            $closedBy = 'DISCONNECT_REQUEST'
        }
    }
    [pscustomobject]@{ Acked = $acked; Indication = $ind; ClosedBy = $closedBy; Watch = $sw }
}

function Test-KnxChannelGone {
    <#
    .SYNOPSIS
        True when the server ended a channel: it sent DISCONNECT_REQUEST, or a CONNECTIONSTATE for it answers E_CONNECTION_ID.
    .DESCRIPTION
        Call once the device answers again. Only 21h proves the channel is gone; 27h (no KNX connection) is sent for a live one.
    #>
    param([Parameter(Mandatory)]$Connection, [string]$ClosedBy = 'none')
    if ($ClosedBy -eq 'DISCONNECT_REQUEST') { return $true }
    $K = Get-KnxConstants
    try {
        $csr = New-KnxConnectionStateRequest -Channel $Connection.Channel -ControlIp $Connection.LocalIp -ControlPort $Connection.LocalPort
        $st = Invoke-KnxRequest -Socket $Connection.Socket -Frame $csr -Ip $Connection.Ip -Port $Connection.Port -Expect @($K.Service.CONNECTIONSTATE_RESPONSE) -TimeoutMs 2000
        return (-not $st.TimedOut -and $st.Header.Body.Length -ge 2 -and $st.Header.Body[1] -eq $K.Error.E_CONNECTION_ID)
    }
    catch { return $false }
}

function Close-KnxResetConnection {
    <#
    .SYNOPSIS
        Frees a connection after an M_Reset: a DISCONNECT_REQUEST when the server kept it, then the socket.
    #>
    param($Connection, [bool]$Gone)
    if ($null -eq $Connection -or $null -eq $Connection.Socket) { return }
    if (-not $Gone) { try { [void](Close-KnxConnection -Connection $Connection -TimeoutMs 1000) } catch { } }
    try { $Connection.Socket.Dispose() } catch { }
}

function Wait-KnxDeviceBack {
    <#
    .SYNOPSIS
        Waits until the device answers DESCRIPTION_REQUEST again; returns the seconds waited, or -1 after the limit.
    #>
    param([Parameter(Mandatory)][string]$Ip, [int]$Port = 3671, [int]$LimitS = 30)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $LimitS) {
        $d = $null
        try { $d = Get-KnxDescription -Ip $Ip -Port $Port -TimeoutMs 200 } catch { }   # a rebooting host can make SendTo throw
        if ($null -ne $d) { return [Math]::Round($sw.Elapsed.TotalSeconds, 1) }
        Start-Sleep -Milliseconds 50
    }
    return -1
}

function Open-KnxDmRetry {
    <#
    .SYNOPSIS
        Opens a device-management connection, retrying while the single slot may still be held by a closing one.
    #>
    param([Parameter(Mandatory)][string]$Ip, [int]$Port = 3671, [int]$Tries = 4)
    $K = Get-KnxConstants
    for ($i = 1; $i -le $Tries; $i++) {
        $c = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
        if ($c.Ok) { return $c }
        Start-Sleep -Seconds 2
    }
    return $c
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
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - exhausting the connection pool disturbs other clients' }
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
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case attempts a property write' }
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
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case toggles programming mode' }
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
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case writes device memory' }
        if (-not $Ctx.TrafficIp) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason 'needs a second interface (-TrafficIp): the memory access runs over the KNX bus, not over the management connection' }
        if (-not $Ctx.BdutPa) { Set-KnxTestNotRun -MissingInput '-BdutPa' -Reason 'BDUT individual address unknown (-BdutPa)' }

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
                Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'changes the device individual address - needs -IncludeDestructive with profile Full'
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
        if (-not $Ctx.BdutPa) { Set-KnxTestNotRun -MissingInput '-BdutPa' -Reason 'BDUT individual address unknown (-BdutPa)' }
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
            # -Source, like the sibling cases: without it a third party's transport connection running
            # into the six second timeout of 03_03_04 5.1 is read as this device refusing - and on the
            # second call below, as this device refusing when it did not.
            $refusedWhenIdle = Wait-KnxTpduFromTunnel -Connection $tun -Tpci 0x81 -Source $target -TimeoutMs 2000
            [void](Send-KnxTunnelCemi -Connection $tun -Cemi $disconnectCemi)
            Add-KnxEvidence -Note "without a device management connection the T_Connect was $(if ($null -ne $refusedWhenIdle) { 'REFUSED' } else { 'accepted' })"
            Assert-KnxTrue ($null -eq $refusedWhenIdle) 'a T_Connect was refused although no device management connection was open - connection-oriented access to the device is broken'

            # --- device management connection open: the connect must be refused ---
            $dm = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $DMGMT -Layer -1
            Assert-KnxTrue $dm.Ok "could not open a device management connection ($($dm.StatusName))"
            [void](Wait-KnxTunnel -Connection $tun -Ms 700)   # the device picks the mode up in its next loop pass

            [void](Send-KnxTunnelCemi -Connection $tun -Cemi $connectCemi)
            $refusedInMode = Wait-KnxTpduFromTunnel -Connection $tun -Tpci 0x81 -Source $target -TimeoutMs 3000
            Add-KnxEvidence -Note "with a device management connection open the T_Connect was $(if ($null -ne $refusedInMode) { 'refused with T_Disconnect' } else { 'ACCEPTED' })"
            Assert-KnxTrue ($null -ne $refusedInMode) 'no T_Disconnect while a device management connection holds the transport layer (03_08_03 2.6.1.2 p.18)'
        }
        finally {
            if ($null -ne $dm -and $dm.Ok) { [void](Close-KnxConnection -Connection $dm) }
            [void](Close-KnxConnection -Connection $tun)
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'P-4.2.15' -Title 'Device management accepted while the REQUESTING client holds the transport connection' -Clause '03_08_03 2.6.1.2 p.18; product decision, see config.h KNX_CEMI_TRANSPORT_STRICT' -Body {
        # The counterpart to H-4.2.15, and the reason this product does not refuse unconditionally.
        # 2.6.1.2 p.18 prescribes no refusal at all - it only describes the implicit mode switch. The
        # refusal comes from the tool case, whose stimulus is a FOREIGN peer. Counting the client's own
        # connection locks ETS out of its own device: ETS reads the group address tables over a T_Connect
        # through its tunnel and then asks for device management, which would be refused until the six
        # second connection timeout of 03_03_04 5.1 releases a connection it never closed.
        # KNX_CEMI_TRANSPORT_STRICT restores the unconditional refusal for a certification run.
        if (-not $Ctx.BdutPa) { Set-KnxTestNotRun -MissingInput '-BdutPa' -Reason 'BDUT individual address unknown (-BdutPa)' }
        if (-not (Test-KnxCemiTransportServed -Ip $ip -Port $port -ConnType $DMGMT)) {
            Set-KnxTestNotApplicable 'device does not serve the cEMI Transport Layer'
        }

        $own = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer 0x02
        Assert-KnxTrue $own.Ok "could not open a tunnelling connection ($($own.StatusName))"
        $held = $false
        try {
            $target = ConvertTo-KnxPa -Address $Ctx.BdutPa
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Source 0 -Destination $target -Tpdu (New-TpduConnect) -Priority 0
            [void](Send-KnxTunnelCemi -Connection $own -Cemi $cemi)
            $held = $true

            # Prove the transport connection before concluding anything from the next answer - the same
            # flaw this case carried and H-4.2.15 below already had removed: a T_Connect is not
            # acknowledged at transport level, so firing it and sleeping proves nothing, and the case
            # would report "accepted while THIS client holds the connection" while holding none.
            # 43 00 is A_DeviceDescriptor_Read at sequence 0, answered with T_ACK.
            $proof = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Source 0 -Destination $target -Tpdu ([byte[]]@(0x43, 0x00)) -Priority 0
            [void](Send-KnxTunnelCemi -Connection $own -Cemi $proof)
            $ack = Wait-KnxTpduFromTunnel -Connection $own -Tpci 0xC2 -Source $target -TimeoutMs 4000
            Add-KnxEvidence -Note "transport connection proven: $(if ($null -ne $ack) { 'device sent T_ACK' } else { 'NO T_ACK - the connection never came up' })"
            if ($null -eq $ack) {
                Set-KnxTestSkip 'the transport connection could not be proven (no T_ACK); without it there is no stimulus and no result about the device'
            }
            [void](Wait-KnxTunnel -Connection $own -Ms 300)

            $dm = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $DMGMT -Layer -1
            if ($null -ne $dm.Response) { Add-KnxEvidence -Received $dm.Response }
            Add-KnxEvidence -Note "device management while THIS client holds the transport connection -> $(if ($dm.Ok) { "accepted on channel $($dm.Channel)" } else { $dm.StatusName })"
            # KNX_TUNNELING_DEVMGMT is 1, so there is exactly ONE management slot. Releasing it and
            # giving the device a moment to reap it keeps the next case from meeting a busy server -
            # a leftover here reads as E_NO_MORE_CONNECTIONS three cases later.
            if ($dm.Ok) { [void](Close-KnxConnection -Connection $dm); [void](Wait-KnxTunnel -Connection $own -Ms 600) }
            Assert-KnxTrue $dm.Ok 'the device refused device management to the very client that holds the transport connection - that is the state which locks ETS out of its own device'
        }
        finally {
            if ($held) {
                $d = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Source 0 -Destination (ConvertTo-KnxPa -Address $Ctx.BdutPa) -Tpdu (New-TpduDisconnect) -Priority 0
                [void](Send-KnxTunnelCemi -Connection $own -Cemi $d -TimeoutMs 2000)
            }
            [void](Close-KnxConnection -Connection $own)

            # The transport connection outlives the tunnel that carried it. Once the tunnel is gone the
            # device no longer recognises that peer as this client's own, so it refuses device management
            # to EVERYONE until the six second connection timeout of 03_03_04 5.1 releases it - which the
            # next cases then report as E_NO_MORE_CONNECTIONS. Wait for the server to be free again rather
            # than guessing a delay, and leave the slot closed.
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            while ([DateTime]::UtcNow -lt $deadline) {
                $probe = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $DMGMT -Layer -1
                if ($probe.Ok) { [void](Close-KnxConnection -Connection $probe); Start-Sleep -Milliseconds 400; break }
                Start-Sleep -Milliseconds 500
            }
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-4.2.15' -Title 'Device management refused while a transport connection is open' -Clause 'TSSH 8.3.2, p.158 (fn 60202) part 2; 03_08_03 2.6.1.2 p.18' -Body {
        # Part 2 of the same tool case: a transport connection is opened FIRST, then a device management
        # connection is requested. Opening one switches the Transport Layer into cEMI Transport Layer mode
        # (03_08_03 2.6.1.2 p.18), which a layer that already carries a connection cannot do, so the request
        # must be answered with E_NO_MORE_CONNECTIONS rather than silently serving two transport peers.
        #
        # WHOSE connection it is decides the answer, and the prufvorschrift is explicit: on p.158 the test
        # controller sends the T_Connect in as a ROUTING_INDICATION from 1.1.255, so the peer holding the
        # layer is NOT the client that afterwards asks for device management. The T_Connect is therefore
        # driven through the TRAFFIC interface - it reaches the BDUT over the bus, from an address the
        # requesting client does not own. The opposite situation is P-4.2.15 and must be ACCEPTED.
        if (-not $Ctx.BdutPa) { Set-KnxTestNotRun -MissingInput '-BdutPa' -Reason 'BDUT individual address unknown (-BdutPa)' }
        if (-not (Test-KnxCemiTransportServed -Ip $ip -Port $port -ConnType $DMGMT)) {
            Set-KnxTestNotApplicable 'device does not serve the cEMI Transport Layer (03_08_03 4.2.5 p.23: X at Device Management v1), so a management connection never takes the transport layer'
        }

        # A management connection must be available to begin with, otherwise the case proves nothing.
        $probe = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $DMGMT -Layer -1
        Assert-KnxTrue $probe.Ok "no device management connection available before the test ($($probe.StatusName))"
        [void](Close-KnxConnection -Connection $probe)
        Start-Sleep -Milliseconds 300

        if (-not $Ctx.TrafficIp) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason 'needs a second interface to hold the transport connection (-TrafficIp); otherwise the peer IS the requesting client' }
        # The shared traffic connection, and it is LEFT OPEN. Two wrong ways were tried here: closing it
        # in the finally took the channel away from every later case in suites 5 and 6, and opening a
        # second, independent tunnel instead simply fails - the traffic interface grants one channel and
        # does not free it at once, so the case then skipped on every run. What this case needs from the
        # peer is only that the transport connection is held by somebody ELSE than the requesting client,
        # and the T_Disconnect in the finally is what releases that.
        $tun = Get-KnxTrafficConnection -Ip $Ctx.TrafficIp -Port $port
        if ($null -eq $tun) { Set-KnxTestSkip 'no tunnel available on the traffic interface' }
        $connected = $false
        try {
            $target = ConvertTo-KnxPa -Address $Ctx.BdutPa
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Source 0 -Destination $target -Tpdu (New-TpduConnect) -Priority 0
            [void](Send-KnxTunnelCemi -Connection $tun -Cemi $cemi)
            $connected = $true

            # Prove the connection is really up before drawing any conclusion from the next answer.
            # A T_Connect is not acknowledged at transport level, so firing it and hoping was the flaw
            # here: the case then reported "device management accepted while a connection was open"
            # when in truth no connection had been established. One numbered service settles it -
            # 43 00 is A_DeviceDescriptor_Read at sequence 0, exactly as ETS sends it - and the device
            # answers with T_ACK and a DeviceDescriptorResponse.
            $probe = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Source 0 -Destination $target -Tpdu ([byte[]]@(0x43, 0x00)) -Priority 0
            [void](Send-KnxTunnelCemi -Connection $tun -Cemi $probe)
            $ack = Wait-KnxTpduFromTunnel -Connection $tun -Tpci 0xC2 -Source $target -TimeoutMs 4000
            Add-KnxEvidence -Note "transport connection proven: $(if ($null -ne $ack) { 'device sent T_ACK' } else { 'NO T_ACK - the connection never came up' })"
            if ($null -eq $ack) {
                # SKIP, not FAIL: without a proven transport connection the case has no stimulus, and
                # reporting the device as accepting "while a connection was open" would be a false result.
                # The shared traffic connection can carry transport state from an earlier case, so the
                # sequence this case starts at is not always 0 - it is drained in the finally below. Verified separately on a FRESH tunnel:
                # T_Connect -> A_DeviceDescriptor_Read answered (T_ACK + 0x340) -> device management
                # refused with E_NO_MORE_CONNECTIONS, which is what this case is meant to establish.
                Set-KnxTestSkip 'the transport connection could not be proven on the shared traffic connection (no T_ACK); the stimulus is missing, so no result about the device is drawn here'
            }
            [void](Wait-KnxTunnel -Connection $tun -Ms 300)

            $dm = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $DMGMT -Layer -1
            if ($null -ne $dm.Response) { Add-KnxEvidence -Received $dm.Response }
            Add-KnxEvidence -Note "device management connect while a transport connection is open -> $(if ($dm.Ok) { "ACCEPTED on channel $($dm.Channel)" } else { $dm.StatusName })"
            if ($dm.Ok) { [void](Close-KnxConnection -Connection $dm); [void](Wait-KnxTunnel -Connection $tun -Ms 600) }
            Assert-KnxTrue (-not $dm.Ok) 'the device accepted a device management connection although its transport layer already carried a connection (08_TSSH 8.3.2 p.158)'
            Assert-KnxStatus $K.Error.E_NO_MORE_CONNECTIONS $dm.Status 'wrong status when the transport layer is occupied'
        }
        finally {
            if ($connected) {
                $d = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Source 0 -Destination (ConvertTo-KnxPa -Address $Ctx.BdutPa) -Tpdu (New-TpduDisconnect) -Priority 0
                [void](Send-KnxTunnelCemi -Connection $tun -Cemi $d -TimeoutMs 2000)
            }
            # Left open on purpose - see above. What this case took from the connection is the transport
            # state, and the T_Disconnect above gives that back; the parked leftovers go too, so the
            # next case starts from nothing. The drain is generous because the device repeats its
            # unacknowledged DeviceDescriptor_Response on the ~3 s layer-4 timer.
            [void](Clear-KnxTunnelTraffic -Connection $tun -QuietMs 400 -MaxMs 6000)

            # The T_Disconnect above is fire-and-forget. If it was lost, the device's transport layer
            # stays busy for the six second connection timeout of 03_03_04 5.1 and refuses device
            # management to EVERYONE - which the next case then reports as a defect. Wait for the device
            # to be free again rather than guessing, exactly as P-4.2.15 does.
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            while ([DateTime]::UtcNow -lt $deadline) {
                $probe2 = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $DMGMT -Layer -1
                if ($probe2.Ok) { [void](Close-KnxConnection -Connection $probe2); Start-Sleep -Milliseconds 400; break }
                Start-Sleep -Milliseconds 500
            }
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
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - the load switch writes to the bus' }
        if (-not $Ctx.LoadSwitchGa) { Set-KnxTestNotRun -MissingInput '-LoadSwitchGa/-LoadSwitchPa' -Reason 'this rig has no load switch - pass -LoadSwitchGa/-LoadSwitchPa when one is fitted (TSSH 1.2.2 specifies 1/1/50 on 1.1.50)' }
        if (-not $Ctx.LoadSwitchVia) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason 'no interface to drive the load switch (-TrafficIp / -LoadSwitchVia)' }

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

    # ── M_Reset: a Basic Restart (03_06_03 4.1.7.5 p.111-112; 03_05_02 3.7.1.1 p.78-79) ──────────────────
    # t1 = 1 s: no pre-reset reaction any more (connections gone, programming mode off); t2 = 5 s: responsive again.

    $mrGate = {
        if (-not $Ctx.AllowDestructive) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason "M_Reset restarts the device and ends every client's connection - needs -IncludeDestructive with profile Full" }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'P-4.MR.1' -Title 'M_Reset.req ends every KNXnet/IP connection, switches programming mode off, device back within 5 s' `
                       -Clause '03_06_03 4.1.7.5.1-4.1.7.5.2 p.111-112; 03_05_02 3.7.1.1.1-3.7.1.1.2 p.78-79' -Body {
        & $mrGate
        # DM first: its retries could otherwise leave the watched tunnel unacknowledged long enough to be dropped.
        $dm = Open-KnxDmRetry -Ip $ip -Port $port
        $tun = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_LINKLAYER
        $dmGone = $false; $tunGone = $false
        try {
            Assert-KnxTrue $dm.Ok "could not open a device management connection ($($dm.StatusName))"
            Assert-KnxTrue $tun.Ok "could not open a link-layer tunnel to watch ($($tun.StatusName))"
            [void](Send-KnxDeviceConfiguration -Connection $dm -Cemi (New-CemiMPropWrite -ObjectType $K.ObjType.DEVICE -PropertyId $K.Pid.PROG_MODE -Data ([byte[]]@(1))))
            $pre = Get-KnxDescription -Ip $ip -Port $port
            if ($null -eq $pre -or $null -eq $pre.Device -or -not $pre.Device.ProgMode) { Set-KnxTestNotRun -MissingInput 'programming mode via PID_PROG_MODE' -Reason 'programming mode could not be switched on before the reset (see H-4.2.5), so switching it off would prove nothing' }
            $pre2 = Sync-KnxTunnel -Connection $tun -Ms 200   # nothing left unacknowledged before the reset
            if ($pre2.Disconnected) { Set-KnxTestSkip 'the watched tunnel was gone before the reset, so its end cannot be attributed to the M_Reset' }
            $m = Invoke-KnxMReset -Connection $dm
            $t = Sync-KnxTunnel -Connection $tun -Ms 1500      # acknowledges, and catches the server's DISCONNECT_REQUEST
            # t2 counts from the M_Reset.req (03_05_02 p.79 t0), not from the end of the waits above.
            $back = if ((Wait-KnxDeviceBack -Ip $ip -Port $port) -ge 0) { [Math]::Round($m.Watch.Elapsed.TotalSeconds, 1) } else { -1 }
            $dmGone = Test-KnxChannelGone -Connection $dm -ClosedBy $m.ClosedBy
            $tunGone = [bool]$t.Disconnected -or (Test-KnxChannelGone -Connection $tun)
            Add-KnxEvidence -Note ("ACK {0}; M_Reset.ind {1} (optional for a KNXnet/IP server); DM closed by {2}, gone {3}; tunnel gone {4}; DESCRIPTION after {5} s" -f $m.Acked, $m.Indication, $m.ClosedBy, $dmGone, $tunGone, $back)
            Assert-KnxTrue $m.Acked 'no DEVICE_CONFIGURATION_ACK for M_Reset.req'
            Assert-KnxTrue ($back -ge 0 -and $back -le 5) "the device was not responsive again within t2 = 5 s ($back s)"
            Assert-KnxTrue $dmGone 'the device management connection the M_Reset came on survived it'
            Assert-KnxTrue $tunGone 'the link-layer tunnel survived the M_Reset'
            $d = Get-KnxDescription -Ip $ip -Port $port
            Assert-KnxTrue ($null -ne $d -and $null -ne $d.Device) 'no DIB to read the programming mode from'
            Assert-KnxTrue (-not $d.Device.ProgMode) 'programming mode is still on after the M_Reset'
        }
        finally {
            Close-KnxResetConnection -Connection $tun -Gone $tunGone
            Close-KnxResetConnection -Connection $dm -Gone $dmGone
            $d = $null; try { $d = Get-KnxDescription -Ip $ip -Port $port } catch { }
            if ($null -ne $d -and $null -ne $d.Device -and $d.Device.ProgMode) {
                $c = Open-KnxDmRetry -Ip $ip -Port $port
                if ($c.Ok) {
                    [void](Send-KnxDeviceConfiguration -Connection $c -Cemi (New-CemiMPropWrite -ObjectType $K.ObjType.DEVICE -PropertyId $K.Pid.PROG_MODE -Data ([byte[]]@(0))))
                    [void](Close-KnxConnection -Connection $c)
                }
            }
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'P-4.MR.2' -Title 'Five M_Reset rounds in a row: each connection ended, device back within 5 s each time' `
                       -Clause '03_06_03 4.1.7.5.1 p.111; 03_05_02 3.7.1.1.1-3.7.1.1.2 p.78-79' -Body {
        & $mrGate
        foreach ($round in 1..5) {
            $dm = Open-KnxDmRetry -Ip $ip -Port $port
            Assert-KnxTrue $dm.Ok "round ${round}: could not open a device management connection ($($dm.StatusName))"
            $gone = $false
            try {
                $m = Invoke-KnxMReset -Connection $dm
                $back = if ((Wait-KnxDeviceBack -Ip $ip -Port $port) -ge 0) { [Math]::Round($m.Watch.Elapsed.TotalSeconds, 1) } else { -1 }
                $gone = Test-KnxChannelGone -Connection $dm -ClosedBy $m.ClosedBy
                Add-KnxEvidence -Note "round ${round}: ACK $($m.Acked), ind $($m.Indication), closed by $($m.ClosedBy), gone $gone, DESCRIPTION after $back s"
                Assert-KnxTrue $m.Acked "round ${round}: no DEVICE_CONFIGURATION_ACK"
                Assert-KnxTrue ($back -ge 0 -and $back -le 5) "round ${round}: not responsive again within t2 = 5 s ($back s)"
                Assert-KnxTrue $gone "round ${round}: the device management connection survived the M_Reset"
            }
            finally { Close-KnxResetConnection -Connection $dm -Gone $gone }
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'P-4.MR.3' -Title 'A new routing multicast address takes effect after M_Reset' `
                       -Clause '03_05_02 3.7.1.1.1 p.78 (within 30 s after the restart), EXAMPLE 5 p.79; 03_08_03 2.5.1, 2.5.17' -Body {
        if (-not $Ctx.IsRouter) { Set-KnxTestNotApplicable 'PID_ROUTING_MULTICAST_ADDRESS is used by a router; an interface does not route' }
        & $mrGate
        if (-not $Ctx.AllowDestructive) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'rewrites PID_ROUTING_MULTICAST_ADDRESS - needs -IncludeDestructive with profile Full' }
        if (-not $Ctx.TrafficIp) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason 'the group is checked over the bus; needs -TrafficIp' }
        if (-not $Ctx.BdutPa) { Set-KnxTestNotRun -MissingInput '-BdutPa' -Reason 'the router individual address is unknown (-BdutPa)' }
        $isolated = ($null -ne $Ctx.PSObject.Properties['IsolatedNetwork'] -and [bool]$Ctx.IsolatedNetwork)
        # The probe switches the SBC mode on (the router then relays TP system broadcasts to 224.0.23.12) and the
        # control probe may send on the production group: isolated rig only.
        if (-not $isolated) { Set-KnxTestNotRun -MissingInput '-IsolatedNetwork' -Reason 'the probe switches the IP System Broadcast Routing Mode on and may send on 224.0.23.12 - only on an isolated rig' }

        # Probe: an SBC enable sent as routing indication to $Group must switch the mode within $LimitS (read over TP).
        $probe = {
            param($Session, [string]$Group, [int]$LimitS)
            Assert-KnxSbcAnswer -Result (Invoke-KnxSbcControl -Session $Session -Form 'Ext' -Mode 0) -What 'disable before the probe'
            $tpdu = New-TpduService -Apci $K.Apci.FUNCTION_PROPERTY_EXT_COMMAND -Data ([byte[]]@(0x00, 0x06, 0x00, 0x10, 0x78, 0x00, 0x00, 0x01)) -Sequence -1
            $cemi = New-CemiLData -MessageCode 0x29 -Source (ConvertTo-KnxPa -Address '0.0.250') -Destination (ConvertTo-KnxPa -Address $Ctx.BdutPa) -Tpdu $tpdu -Priority 0
            $frame = New-KnxRoutingIndication -Cemi $cemi
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while ($sw.Elapsed.TotalSeconds -lt $LimitS) {
                $u = New-KnxSocket -TimeoutMs 500
                try { Send-KnxFrame -Socket $u -Frame $frame -Ip $Group -Port $port } finally { $u.Dispose() }
                [void](Wait-KnxTunnel -Connection $Session.Conn -Ms 500)
                if ((Invoke-KnxSbcControl -Session $Session -Form 'Ext').Mode -eq 1) { return [Math]::Round($sw.Elapsed.TotalSeconds, 1) }
            }
            return -1
        }

        $dm = Open-KnxDmRetry -Ip $ip -Port $port
        Assert-KnxTrue $dm.Ok "could not open a device management connection ($($dm.StatusName))"
        $orig = Get-PropertyBytes -Connection $dm -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.ROUTING_MULTICAST_ADDRESS
        if ($null -eq $orig -or $orig.Length -lt 4) { [void](Close-KnxConnection -Connection $dm); Set-KnxTestSkip 'PID_ROUTING_MULTICAST_ADDRESS could not be read' }
        $origIp = $orig[0..3] -join '.'
        $targetIp = if ($origIp -eq '225.0.23.12') { '225.0.23.13' } else { '225.0.23.12' }
        # An open device management connection puts the transport layer in cEMI Transport Layer mode, which ignores the probe's requests from the bus (TSSH 8.3.6).
        $closed = Close-KnxConnection -Connection $dm; $dm = $null
        if (-not $closed) { Set-KnxTestNotRun -MissingInput 'a confirmed DISCONNECT of the device management connection' -Reason 'with the connection possibly open the probe requests would be ignored' }
        Start-Sleep -Milliseconds 700   # the mode ends in the device's next loop pass
        $restore = 'pending'; $s = $null; $dmGone = $false; $written = $false
        try {
            $s = Open-KnxDeviceSession -Ip $Ctx.TrafficIp -Port $port -Pa $Ctx.BdutPa
            if (-not $s.Ok) { Set-KnxTestSkip "no tunnel on the traffic interface: $($s.Reason)" }
            # Control: the same probe on the present group, so a broken probe path is not blamed on the new group.
            $c0 = & $probe $s $origIp 5
            Add-KnxEvidence -Note "control probe on $origIp took effect after $c0 s"
            if ($c0 -lt 0) { Set-KnxTestSkip "the probe does not work on the present group $origIp either, so the new group cannot be judged" }
            $dm = Open-KnxDmRetry -Ip $ip -Port $port
            Assert-KnxTrue $dm.Ok "could not open a device management connection for the write ($($dm.StatusName))"
            $w = Send-KnxDeviceConfiguration -Connection $dm -Cemi (New-CemiMPropWrite -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.ROUTING_MULTICAST_ADDRESS -Data ([byte[]]($targetIp.Split('.') | ForEach-Object { [byte]$_ })))
            $written = $true   # a lost .con may still have landed: restore in any case
            Assert-KnxTrue ($null -ne $w.Parsed -and -not $w.Parsed.IsError) 'PID_ROUTING_MULTICAST_ADDRESS write was refused'
            Add-KnxEvidence -Note "PID 66 $origIp -> $targetIp"
            $m = Invoke-KnxMReset -Connection $dm
            $back = Wait-KnxDeviceBack -Ip $ip -Port $port
            $dmGone = Test-KnxChannelGone -Connection $dm -ClosedBy $m.ClosedBy
            Assert-KnxTrue ($back -ge 0) 'the device did not come back after the M_Reset'
            # A connection that outlived the reset shows no restart (judged by P-4.MR.1) and would keep the probe ignored.
            if (-not $dmGone) { Set-KnxTestNotRun -MissingInput 'a restart after the M_Reset' -Reason 'the device management connection outlived the M_Reset, so the restart that applies the new group did not happen (P-4.MR.1 judges that)' }
            $dm = $null
            $seen = & $probe $s $targetIp 30
            Add-KnxEvidence -Note $(if ($seen -ge 0) { "an enable sent to $targetIp took effect $seen s after the device was back" } else { "no enable sent to $targetIp took effect within 30 s after the device was back" })
            Assert-KnxTrue ($seen -ge 0) "the router did not act on a routing indication to the new group $targetIp within 30 s after the restart"
        }
        finally {
            if ($null -ne $dm) { Close-KnxResetConnection -Connection $dm -Gone $dmGone }
            if ($null -ne $s) {
                try { [void](Invoke-KnxSbcControl -Session $s -Form 'Ext' -Mode 0) } catch { }
                Close-KnxDeviceSession -Session $s
            }
            if ($written) {
                try {
                    [void](Wait-KnxDeviceBack -Ip $ip -Port $port)
                    $c = Open-KnxDmRetry -Ip $ip -Port $port
                    if ($c.Ok) {
                        [void](Send-KnxDeviceConfiguration -Connection $c -Cemi (New-CemiMPropWrite -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.ROUTING_MULTICAST_ADDRESS -Data ([byte[]]$orig[0..3])))
                        $mr = Invoke-KnxMReset -Connection $c
                        [void](Wait-KnxDeviceBack -Ip $ip -Port $port)
                        Close-KnxResetConnection -Connection $c -Gone (Test-KnxChannelGone -Connection $c -ClosedBy $mr.ClosedBy)
                        $c2 = Open-KnxDmRetry -Ip $ip -Port $port
                        if ($c2.Ok) {
                            $now = Get-PropertyBytes -Connection $c2 -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.ROUTING_MULTICAST_ADDRESS
                            $restore = if ($null -ne $now -and $now.Length -ge 4 -and ($now[0..3] -join '.') -eq $origIp) { 'ok' } else { 'failed' }
                            [void](Close-KnxConnection -Connection $c2)
                        }
                        else { $restore = 'failed' }
                    }
                    else { $restore = 'failed' }
                }
                catch { $restore = 'failed' }
                if ($restore -ne 'ok') {
                    Write-Host "    WARNING: PID_ROUTING_MULTICAST_ADDRESS was not restored to $origIp" -ForegroundColor Red
                    throw "KNXTEST_FAIL::PID_ROUTING_MULTICAST_ADDRESS could not be restored to $origIp"
                }
            }
        }
    }
}
