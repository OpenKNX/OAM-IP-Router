#!/usr/bin/env pwsh
<#
Open ■
┬────┴  KnxTest
■ KNX   2026 OpenKNX - Erkan Çolak

FILEPATH: scripts/Test/KnxTest.psm1

.SYNOPSIS
    Shared KNXnet/IP conformance-test library for the OpenKNX IP-Interface and IP-Router.

.DESCRIPTION
    Everything the conformance suites need and nothing product specific:

      * KNXnet/IP frame builders (Core, Device Management, Tunnelling, Routing,
        Remote Diagnosis) and cEMI builders (L_Data, M_Prop, M_Reset).
      * Parsers for the KNXnet/IP header, the DIB block of a SEARCH/DESCRIPTION
        response, the CRD of a CONNECT response and cEMI frames.
      * A UDP transport with deterministic timeouts plus multicast support.
      * Connection objects for a tunnelling and a device-management connection.
      * A verdict engine: PASS / FAIL / SKIP / N-A, byte-level evidence on failure,
        and a Markdown + JSON report.
      * Rig helpers: reachability probe and the TSSH load switch.
      * Self-test vectors so the library proves its own frames before it judges a device.

    A test suite never builds raw bytes on its own - if a frame is missing here, it
    belongs here. That keeps the self-test meaningful: every byte a suite sends has
    been verified offline against a known-good vector.

.NOTES
    Runs on PowerShell 7 (macOS/Linux/Windows) and Windows PowerShell 5.1.
    Byte arrays are returned with the comma operator (,$bytes) so PowerShell does
    not unroll them into an Object[] of boxed bytes.

    This file exists as an identical copy in OAM-IP-Interface and OAM-IP-Router.
    Use Sync-TestLib.ps1 to compare and propagate changes - never edit only one side.
#>

Set-StrictMode -Version Latest

# ─── Protocol constants ─────────────────────────────────────────────────────────

# KNXnet/IP service type identifiers (03_08_01 Overview, service type ID table).
$script:KnxService = @{
    SEARCH_REQUEST                    = 0x0201
    SEARCH_RESPONSE                   = 0x0202
    DESCRIPTION_REQUEST               = 0x0203
    DESCRIPTION_RESPONSE              = 0x0204
    CONNECT_REQUEST                   = 0x0205
    CONNECT_RESPONSE                  = 0x0206
    CONNECTIONSTATE_REQUEST           = 0x0207
    CONNECTIONSTATE_RESPONSE          = 0x0208
    DISCONNECT_REQUEST                = 0x0209
    DISCONNECT_RESPONSE               = 0x020A
    SEARCH_REQUEST_EXTENDED           = 0x020B
    SEARCH_RESPONSE_EXTENDED          = 0x020C
    DEVICE_CONFIGURATION_REQUEST      = 0x0310
    DEVICE_CONFIGURATION_ACK          = 0x0311
    TUNNELLING_REQUEST                = 0x0420
    TUNNELLING_ACK                    = 0x0421
    TUNNELLING_FEATURE_GET            = 0x0422
    TUNNELLING_FEATURE_RESPONSE       = 0x0423
    TUNNELLING_FEATURE_SET            = 0x0424
    TUNNELLING_FEATURE_INFO           = 0x0425
    ROUTING_INDICATION                = 0x0530
    ROUTING_LOST_MESSAGE              = 0x0531
    ROUTING_BUSY                      = 0x0532
    REMOTE_DIAGNOSTIC_REQUEST         = 0x0740
    REMOTE_DIAGNOSTIC_RESPONSE        = 0x0741
    REMOTE_BASIC_CONFIGURATION_REQUEST = 0x0742
    REMOTE_RESET_REQUEST              = 0x0743
}

# CONNECT_REQUEST connection types (03_08_02 Core, CRI).
$script:KnxConnType = @{
    DEVICE_MGMT_CONNECTION = 0x03
    TUNNEL_CONNECTION      = 0x04
    REMLOG_CONNECTION      = 0x06
    REMCONF_CONNECTION     = 0x07
    OBJSVR_CONNECTION      = 0x08
}

# Tunnelling KNX layer codes (03_08_04 Tunnelling, CRI).
$script:KnxLayer = @{
    TUNNEL_LINKLAYER  = 0x02
    TUNNEL_RAW        = 0x04
    TUNNEL_BUSMONITOR = 0x80
}

# CONNECT_RESPONSE / CONNECTIONSTATE_RESPONSE status codes (03_08_02 Core, error code table).
$script:KnxError = @{
    E_NO_ERROR                    = 0x00
    E_HOST_PROTOCOL_TYPE          = 0x01
    E_VERSION_NOT_SUPPORTED       = 0x02
    E_SEQUENCE_NUMBER             = 0x04
    E_CONNECTION_ID               = 0x21
    E_CONNECTION_TYPE             = 0x22
    E_CONNECTION_OPTION           = 0x23
    E_NO_MORE_CONNECTIONS         = 0x24
    E_NO_MORE_UNIQUE_CONNECTIONS  = 0x25
    E_DATA_CONNECTION             = 0x26
    E_KNX_CONNECTION              = 0x27
    E_TUNNELING_LAYER             = 0x29
}

# DIB type codes (03_08_02 Core, DIB structures).
$script:KnxDib = @{
    DEVICE_INFO           = 0x01
    SUPP_SVC_FAMILIES     = 0x02
    IP_CONFIG             = 0x03
    IP_CUR_CONFIG         = 0x04
    KNX_ADDRESSES         = 0x05
    SECURED_SERVICE_FAMILIES = 0x06
    TUNNELING_INFO        = 0x07
    EXTENDED_DEVICE_INFO  = 0x08
    MFR_DATA              = 0xFE
}

# Service family identifiers (03_08_02 Core, Supported Service Families DIB).
$script:KnxFamily = @{
    CORE               = 0x02
    DEVICE_MANAGEMENT  = 0x03
    TUNNELLING         = 0x04
    ROUTING            = 0x05
    REMOTE_LOGGING     = 0x06
    REMOTE_CONF_DIAG   = 0x07
    OBJECT_SERVER      = 0x08
    SECURITY           = 0x09
}

# cEMI message codes (03_06_03 EMI_IMI).
$script:Cemi = @{
    L_RAW_REQ        = 0x10
    L_DATA_REQ       = 0x11
    L_RAW_IND        = 0x2D
    L_DATA_IND       = 0x29
    L_BUSMON_IND     = 0x2B
    L_RAW_CON        = 0x2F
    L_DATA_CON       = 0x2E
    M_PROPREAD_REQ   = 0xFC
    M_PROPREAD_CON   = 0xFB
    M_PROPWRITE_REQ  = 0xF6
    M_PROPWRITE_CON  = 0xF5
    M_PROPINFO_IND   = 0xF7
    M_FUNCPROP_CMD   = 0xF8
    M_FUNCPROP_READ  = 0xF9
    M_FUNCPROP_CON   = 0xFA
    M_RESET_REQ      = 0xF1
    M_RESET_IND      = 0xF0
    # cEMI transport-layer services on a device-management connection (AN118),
    # message codes taken from the TSSH section 4.3 frame tables.
    T_DATA_CONNECTED_REQ  = 0x41
    T_DATA_INDIVIDUAL_REQ = 0x4A
    T_DATA_CONNECTED_IND  = 0x89
    T_DATA_INDIVIDUAL_IND = 0x94
}

# Application layer service identifiers (03_03_07 Application Layer).
$script:Apci = @{
    GROUP_VALUE_READ       = 0x000
    GROUP_VALUE_RESPONSE   = 0x040
    GROUP_VALUE_WRITE      = 0x080
    INDIVIDUAL_ADDR_WRITE  = 0x0C0
    MEMORY_READ            = 0x200
    MEMORY_RESPONSE        = 0x240
    MEMORY_WRITE           = 0x280
    DEVICE_DESCRIPTOR_READ = 0x300
    # Values taken from the stack's own ApduType enum (knx/src/knx/knx_types.h), not from
    # a test specification - a service code read out of a prufvorschrift produced twenty
    # false findings once, and the source of truth is the implementation both sides share.
    DEVICE_DESCRIPTOR_RESPONSE = 0x340
    INDIVIDUAL_ADDR_READ     = 0x100
    INDIVIDUAL_ADDR_RESPONSE = 0x140
    RESTART                  = 0x380
    PROPERTY_VALUE_READ    = 0x3D5
    PROPERTY_VALUE_RESPONSE = 0x3D6
    PROPERTY_VALUE_WRITE   = 0x3D7
    PROPERTY_DESCRIPTION_READ     = 0x3D8
    PROPERTY_DESCRIPTION_RESPONSE = 0x3D9
}

# Interface object types (03_05_01 Resources).
$script:ObjType = @{
    DEVICE           = 0
    ADDRESS_TABLE    = 1
    ASSOC_TABLE      = 2
    APPLICATION      = 3
    INTERFACE_PROG   = 4
    ROUTER           = 6
    CEMI_SERVER      = 8
    KNXNETIP_PARAM   = 11
}

# Property identifiers used by the suites (03_05_01 Resources).
# Named KnxPid, not Pid - $PID is a PowerShell automatic variable.
$script:KnxPid = @{
    OBJECT_TYPE                    = 1
    SERIAL_NUMBER                  = 11
    MANUFACTURER_ID                = 12
    DEVICE_CONTROL                 = 14
    PROG_MODE                      = 54   # device object (OT 0); on OT 11 the same number is CURRENT_IP_ASSIGNMENT_METHOD
    ORDER_INFO                     = 15
    VERSION                        = 25
    ROUTING_COUNT                  = 51
    MAX_APDU_LENGTH                = 56
    SUBNET_ADDR                    = 57
    DEVICE_ADDR                    = 58
    PROJECT_INSTALLATION_ID        = 51
    KNX_INDIVIDUAL_ADDRESS         = 52
    # 53, verified against knx/src/knx/property.h - 55 is PID_IP_ASSIGNMENT_METHOD.
    ADDITIONAL_INDIVIDUAL_ADDRESSES = 53
    CURRENT_IP_ASSIGNMENT_METHOD   = 54
    IP_ASSIGNMENT_METHOD           = 55
    IP_CAPABILITIES                = 56
    CURRENT_IP_ADDRESS             = 57
    CURRENT_SUBNET_MASK            = 58
    CURRENT_DEFAULT_GATEWAY        = 59
    IP_ADDRESS                     = 60
    SUBNET_MASK                    = 61
    DEFAULT_GATEWAY                = 62
    DHCP_BOOTP_SERVER              = 63
    MAC_ADDRESS                    = 64
    SYSTEM_SETUP_MULTICAST_ADDRESS = 65
    ROUTING_MULTICAST_ADDRESS      = 66
    TTL                            = 67
    KNXNETIP_DEVICE_CAPABILITIES   = 68
    FRIENDLY_NAME                  = 76
    # 74/75, verified against property.h. 71 is PID_IO_LIST and 72 is
    # PID_QUEUE_OVERFLOW_TO_IP - the earlier values addressed unrelated properties.
    MSG_TRANSMIT_TO_IP             = 74
    MSG_TRANSMIT_TO_KNX            = 75
    QUEUE_OVERFLOW_TO_IP           = 72
    QUEUE_OVERFLOW_TO_KNX          = 73
}

$script:KnxDefaultPort      = 3671
$script:KnxSystemMulticast  = '224.0.23.12'

function Get-KnxConstants {
    <#
    .SYNOPSIS
        Returns every protocol constant table in one object, for use inside suites.
    #>
    return [pscustomobject]@{
        Service   = $script:KnxService
        ConnType  = $script:KnxConnType
        Layer     = $script:KnxLayer
        Error     = $script:KnxError
        Dib       = $script:KnxDib
        Family    = $script:KnxFamily
        Cemi      = $script:Cemi
        Apci      = $script:Apci
        ObjType   = $script:ObjType
        Pid       = $script:KnxPid
        Port      = $script:KnxDefaultPort
        Multicast = $script:KnxSystemMulticast
    }
}

# ─── Formatting helpers ─────────────────────────────────────────────────────────

function Get-Uint16 {
    <#
    .SYNOPSIS
        Reads a big-endian 16-bit value out of a byte array.
    .DESCRIPTION
        PowerShell's -shl keeps the width of its left operand, so [byte]0x0A -shl 8 is 0,
        not 0x0A00. Every multi-octet field must therefore widen to [int] BEFORE shifting -
        this helper exists so no parser can forget it again.
    #>
    param([Parameter(Mandatory)][byte[]]$Bytes, [int]$Offset = 0)
    if (($Offset + 1) -ge $Bytes.Length) { return -1 }
    return ((([int]$Bytes[$Offset]) -shl 8) -bor ([int]$Bytes[$Offset + 1]))
}

function ConvertTo-HexString {
    <#
    .SYNOPSIS
        Renders a byte array as an uppercase hex string, space separated per octet.
    #>
    param([byte[]]$Bytes, [int]$MaxBytes = 0)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '<empty>' }
    $take = $Bytes.Length
    $trail = ''
    if ($MaxBytes -gt 0 -and $take -gt $MaxBytes) { $take = $MaxBytes; $trail = " ... (+$($Bytes.Length - $MaxBytes) B)" }
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $take; $i++) {
        if ($i -gt 0) { [void]$sb.Append(' ') }
        [void]$sb.Append($Bytes[$i].ToString('X2'))
    }
    return $sb.ToString() + $trail
}

function Get-KnxServiceName {
    <#
    .SYNOPSIS
        Maps a service type id back to its name; returns a hex literal when unknown.
    #>
    param([int]$Service)
    foreach ($k in $script:KnxService.Keys) {
        if ($script:KnxService[$k] -eq $Service) { return $k }
    }
    return ('0x{0:X4}' -f $Service)
}

function Get-KnxErrorName {
    <#
    .SYNOPSIS
        Maps a KNXnet/IP status byte back to its E_* name.
    #>
    param([int]$Status)
    foreach ($k in $script:KnxError.Keys) {
        if ($script:KnxError[$k] -eq $Status) { return $k }
    }
    return ('0x{0:X2}' -f $Status)
}

# ─── Address conversion ─────────────────────────────────────────────────────────

function ConvertTo-KnxGa {
    <#
    .SYNOPSIS
        Converts a group address "m/s/g" or "m/g" to its 16-bit raw value.
    #>
    param([Parameter(Mandatory)][string]$Address)
    $p = $Address.Split('/')
    switch ($p.Count) {
        3 { return ((([int]$p[0] -band 0x1F) -shl 11) -bor (([int]$p[1] -band 0x07) -shl 8) -bor ([int]$p[2] -band 0xFF)) }
        2 { return ((([int]$p[0] -band 0x1F) -shl 11) -bor ([int]$p[1] -band 0x7FF)) }
        1 { return ([int]$p[0] -band 0xFFFF) }
        default { throw "Not a group address: '$Address'" }
    }
}

function ConvertFrom-KnxGa {
    <#
    .SYNOPSIS
        Converts a raw 16-bit group address to "m/s/g" notation.
    #>
    param([Parameter(Mandatory)][int]$Raw)
    return ('{0}/{1}/{2}' -f (($Raw -shr 11) -band 0x1F), (($Raw -shr 8) -band 0x07), ($Raw -band 0xFF))
}

function ConvertTo-KnxPa {
    <#
    .SYNOPSIS
        Converts an individual address "a.l.d" to its 16-bit raw value.
    #>
    param([Parameter(Mandatory)][string]$Address)
    $p = $Address.Split('.')
    if ($p.Count -ne 3) { throw "Not an individual address: '$Address'" }
    return ((([int]$p[0] -band 0x0F) -shl 12) -bor (([int]$p[1] -band 0x0F) -shl 8) -bor ([int]$p[2] -band 0xFF))
}

function ConvertFrom-KnxPa {
    <#
    .SYNOPSIS
        Converts a raw 16-bit individual address to "a.l.d" notation.
    #>
    param([Parameter(Mandatory)][int]$Raw)
    return ('{0}.{1}.{2}' -f (($Raw -shr 12) -band 0x0F), (($Raw -shr 8) -band 0x0F), ($Raw -band 0xFF))
}

# ─── KNXnet/IP frame builders ───────────────────────────────────────────────────

function New-KnxFrame {
    <#
    .SYNOPSIS
        Wraps a body in the KNXnet/IP header: 06 10 <service> <total length>.
    .PARAMETER HeaderSize
        Override the header size octet - only a malformed-frame test should do that.
    .PARAMETER Version
        Override the protocol version octet - only a malformed-frame test should do that.
    .PARAMETER TotalLength
        Override the declared total length - only a malformed-frame test should do that.
    #>
    param(
        [Parameter(Mandatory)][int]$Service,
        [byte[]]$Body = @(),
        [int]$HeaderSize = 0x06,
        [int]$Version = 0x10,
        [int]$TotalLength = -1
    )
    $len = if ($TotalLength -ge 0) { $TotalLength } else { 6 + $Body.Length }
    $hdr = [byte[]]@(
        ($HeaderSize -band 0xFF),
        ($Version -band 0xFF),
        (($Service -shr 8) -band 0xFF), ($Service -band 0xFF),
        (($len -shr 8) -band 0xFF), ($len -band 0xFF)
    )
    return , ([byte[]]($hdr + $Body))
}

function New-KnxHpai {
    <#
    .SYNOPSIS
        Builds a Host Protocol Address Information block (IPv4 UDP).
    .DESCRIPTION
        Passing 0.0.0.0:0 produces the NAT-compatible ("route back") HPAI required by
        TSSH section 5.4 - the server must then answer to the UDP source endpoint.
    #>
    param([string]$Ip = '0.0.0.0', [int]$Port = 0, [int]$Protocol = 0x01)
    $o = ([System.Net.IPAddress]::Parse($Ip)).GetAddressBytes()
    return , ([byte[]]@(0x08, ($Protocol -band 0xFF), $o[0], $o[1], $o[2], $o[3], (($Port -shr 8) -band 0xFF), ($Port -band 0xFF)))
}

function New-KnxCri {
    <#
    .SYNOPSIS
        Builds the Connection Request Information block of a CONNECT_REQUEST.
    .DESCRIPTION
        Tunnel connections carry the KNX layer octet plus one reserved octet; device
        management and every other type is a bare two-octet header.
    #>
    param([Parameter(Mandatory)][int]$ConnectionType, [int]$Layer = -1)
    if ($Layer -ge 0) {
        return , ([byte[]]@(0x04, ($ConnectionType -band 0xFF), ($Layer -band 0xFF), 0x00))
    }
    return , ([byte[]]@(0x02, ($ConnectionType -band 0xFF)))
}

function New-KnxSearchRequest {
    <#
    .SYNOPSIS
        Builds a SEARCH_REQUEST (03_08_02 Core).
    #>
    param([string]$DiscoveryIp = '0.0.0.0', [int]$DiscoveryPort = 0, [int]$Version = 0x10, [int]$HeaderSize = 0x06)
    $hpai = New-KnxHpai -Ip $DiscoveryIp -Port $DiscoveryPort
    return , (New-KnxFrame -Service $script:KnxService.SEARCH_REQUEST -Body $hpai -Version $Version -HeaderSize $HeaderSize)
}

function New-KnxDescriptionRequest {
    <#
    .SYNOPSIS
        Builds a DESCRIPTION_REQUEST (03_08_02 Core).
    #>
    param([string]$ControlIp = '0.0.0.0', [int]$ControlPort = 0)
    $hpai = New-KnxHpai -Ip $ControlIp -Port $ControlPort
    return , (New-KnxFrame -Service $script:KnxService.DESCRIPTION_REQUEST -Body $hpai)
}

function New-KnxConnectRequest {
    <#
    .SYNOPSIS
        Builds a CONNECT_REQUEST for a tunnelling or device-management connection.
    #>
    param(
        [string]$ControlIp = '0.0.0.0', [int]$ControlPort = 0,
        [string]$DataIp = '0.0.0.0',    [int]$DataPort = 0,
        [int]$ConnectionType = 0x04,
        [int]$Layer = 0x02
    )
    $ctrl = New-KnxHpai -Ip $ControlIp -Port $ControlPort
    $data = New-KnxHpai -Ip $DataIp -Port $DataPort
    $cri  = New-KnxCri -ConnectionType $ConnectionType -Layer $Layer
    return , (New-KnxFrame -Service $script:KnxService.CONNECT_REQUEST -Body ([byte[]]($ctrl + $data + $cri)))
}

function New-KnxConnectionStateRequest {
    <#
    .SYNOPSIS
        Builds a CONNECTIONSTATE_REQUEST for a channel.
    #>
    param([Parameter(Mandatory)][int]$Channel, [string]$ControlIp = '0.0.0.0', [int]$ControlPort = 0)
    $hpai = New-KnxHpai -Ip $ControlIp -Port $ControlPort
    return , (New-KnxFrame -Service $script:KnxService.CONNECTIONSTATE_REQUEST -Body ([byte[]]@(($Channel -band 0xFF), 0x00) + $hpai))
}

function New-KnxDisconnectRequest {
    <#
    .SYNOPSIS
        Builds a DISCONNECT_REQUEST for a channel.
    #>
    param([Parameter(Mandatory)][int]$Channel, [string]$ControlIp = '0.0.0.0', [int]$ControlPort = 0)
    $hpai = New-KnxHpai -Ip $ControlIp -Port $ControlPort
    return , (New-KnxFrame -Service $script:KnxService.DISCONNECT_REQUEST -Body ([byte[]]@(($Channel -band 0xFF), 0x00) + $hpai))
}

function New-KnxDisconnectResponse {
    <#
    .SYNOPSIS
        Builds a DISCONNECT_RESPONSE for a channel.
    .DESCRIPTION
        Two octets of body: channel id and status. A client that leaves a server's
        DISCONNECT_REQUEST unanswered makes the server repeat it, which looks like traffic
        the test did not expect.
    #>
    param([Parameter(Mandatory)][int]$Channel, [int]$Status = 0)
    return , (New-KnxFrame -Service $script:KnxService.DISCONNECT_RESPONSE `
                           -Body ([byte[]]@(($Channel -band 0xFF), ($Status -band 0xFF))))
}

function New-KnxTunnellingRequest {
    <#
    .SYNOPSIS
        Builds a TUNNELLING_REQUEST: connection header (04 ch seq 00) plus a cEMI frame.
    #>
    param([Parameter(Mandatory)][int]$Channel, [Parameter(Mandatory)][int]$Sequence, [Parameter(Mandatory)][byte[]]$Cemi)
    $ch = [byte[]]@(0x04, ($Channel -band 0xFF), ($Sequence -band 0xFF), 0x00)
    return , (New-KnxFrame -Service $script:KnxService.TUNNELLING_REQUEST -Body ([byte[]]($ch + $Cemi)))
}

function New-KnxTunnellingAck {
    <#
    .SYNOPSIS
        Builds a TUNNELLING_ACK for a received TUNNELLING_REQUEST.
    #>
    param([Parameter(Mandatory)][int]$Channel, [Parameter(Mandatory)][int]$Sequence, [int]$Status = 0x00)
    return , (New-KnxFrame -Service $script:KnxService.TUNNELLING_ACK -Body ([byte[]]@(0x04, ($Channel -band 0xFF), ($Sequence -band 0xFF), ($Status -band 0xFF))))
}

function New-KnxDeviceConfigurationRequest {
    <#
    .SYNOPSIS
        Builds a DEVICE_CONFIGURATION_REQUEST carrying a cEMI M_* frame.
    #>
    param([Parameter(Mandatory)][int]$Channel, [Parameter(Mandatory)][int]$Sequence, [Parameter(Mandatory)][byte[]]$Cemi)
    $ch = [byte[]]@(0x04, ($Channel -band 0xFF), ($Sequence -band 0xFF), 0x00)
    return , (New-KnxFrame -Service $script:KnxService.DEVICE_CONFIGURATION_REQUEST -Body ([byte[]]($ch + $Cemi)))
}

function New-KnxDeviceConfigurationAck {
    <#
    .SYNOPSIS
        Builds a DEVICE_CONFIGURATION_ACK.
    #>
    param([Parameter(Mandatory)][int]$Channel, [Parameter(Mandatory)][int]$Sequence, [int]$Status = 0x00)
    return , (New-KnxFrame -Service $script:KnxService.DEVICE_CONFIGURATION_ACK -Body ([byte[]]@(0x04, ($Channel -band 0xFF), ($Sequence -band 0xFF), ($Status -band 0xFF))))
}

function New-KnxRoutingIndication {
    <#
    .SYNOPSIS
        Builds a ROUTING_INDICATION carrying a cEMI frame.
    #>
    param([Parameter(Mandatory)][byte[]]$Cemi)
    return , (New-KnxFrame -Service $script:KnxService.ROUTING_INDICATION -Body $Cemi)
}

function New-KnxRemoteDiagnosticRequest {
    <#
    .SYNOPSIS
        Builds a REMOTE_DIAGNOSTIC_REQUEST (03_08_02 Core, remote diagnosis).
    .PARAMETER Selector
        Selector block; omit for the "missing selector" negative test.
    #>
    param([string]$DiscoveryIp = '0.0.0.0', [int]$DiscoveryPort = 0, [byte[]]$Selector = $null)
    $hpai = New-KnxHpai -Ip $DiscoveryIp -Port $DiscoveryPort
    $body = if ($null -ne $Selector) { [byte[]]($hpai + $Selector) } else { [byte[]]$hpai }
    return , (New-KnxFrame -Service $script:KnxService.REMOTE_DIAGNOSTIC_REQUEST -Body $body)
}

function New-KnxProgModeSelector {
    <#
    .SYNOPSIS
        Builds the "selection by programming mode" selector (structure length 2, code 01).
    #>
    return , ([byte[]]@(0x02, 0x01))
}

function New-KnxMacSelector {
    <#
    .SYNOPSIS
        Builds the "selection by MAC address" selector (structure length 8, code 02).
    #>
    param([Parameter(Mandatory)][byte[]]$Mac)
    if ($Mac.Length -ne 6) { throw 'MAC selector needs exactly 6 octets' }
    return , ([byte[]]@(0x08, 0x02) + $Mac)
}

# ─── cEMI builders ──────────────────────────────────────────────────────────────

function New-CemiLData {
    <#
    .SYNOPSIS
        Builds an L_Data cEMI frame (standard frame format, no additional information).
    .DESCRIPTION
        Ctrl1 bit7 = standard frame, bit5 = do-not-repeat, bits3..2 = priority.
        Ctrl2 bit7 = destination is a group address, bits6..4 = hop count.
        The length octet counts the TPDU minus its first octet, exactly as on TP1.
    .PARAMETER MessageCode
        L_Data.req (0x11), .ind (0x29) or .con (0x2E).
    .PARAMETER Priority
        0 system, 1 normal, 2 urgent, 3 low. Low is the ETS default for group comm.
    #>
    param(
        [int]$MessageCode = 0x11,
        [int]$Source = 0,
        [Parameter(Mandatory)][int]$Destination,
        [switch]$IsGroup,
        [Parameter(Mandatory)][byte[]]$Tpdu,
        [int]$Priority = 3,
        [int]$HopCount = 6,
        [switch]$Repeat,
        [byte[]]$AdditionalInfo = @()
    )
    $ctrl1 = 0x80                                    # bit7 = standard frame
    if (-not $Repeat) { $ctrl1 = $ctrl1 -bor 0x20 }  # bit5 set = NOT repeated
    $ctrl1 = $ctrl1 -bor 0x10                        # bit4 = normal broadcast (not system)
    $ctrl1 = $ctrl1 -bor (($Priority -band 0x03) -shl 2)
    $ctrl2 = (($HopCount -band 0x07) -shl 4)
    if ($IsGroup) { $ctrl2 = $ctrl2 -bor 0x80 }
    $addIl = [byte]$AdditionalInfo.Length
    $body = [byte[]]@(
        ($MessageCode -band 0xFF), $addIl
    ) + $AdditionalInfo + [byte[]]@(
        ($ctrl1 -band 0xFF), ($ctrl2 -band 0xFF),
        (($Source -shr 8) -band 0xFF), ($Source -band 0xFF),
        (($Destination -shr 8) -band 0xFF), ($Destination -band 0xFF),
        (($Tpdu.Length - 1) -band 0xFF)
    ) + $Tpdu
    return , ([byte[]]$body)
}

function New-TpduGroupValueWrite {
    <#
    .SYNOPSIS
        Builds the TPDU of an A_GroupValue_Write with a small (<= 6 bit) payload.
    #>
    param([int]$Value = 0)
    return , ([byte[]]@(0x00, (0x80 -bor ($Value -band 0x3F))))
}

function New-TpduGroupValueRead {
    <#
    .SYNOPSIS
        Builds the TPDU of an A_GroupValue_Read.
    #>
    return , ([byte[]]@(0x00, 0x00))
}

function New-TpduDeviceDescriptorRead {
    <#
    .SYNOPSIS
        Builds the TPDU of an A_DeviceDescriptor_Read.
    .DESCRIPTION
        APCI 0x300 | descriptor type, carried as an unnumbered T_Data_Individual (TPCI 0x00).
        The 10-bit APCI splits across the two TPDU octets: the high 2 bits join the TPCI
        octet, the low 8 bits carry the descriptor type.
    #>
    param([int]$Descriptor = 0)
    return , ([byte[]]@((0x00 -bor 0x03), ($Descriptor -band 0xFF)))
}

function New-TpduConnect {
    <#
    .SYNOPSIS
        Builds a T_Connect TPDU (transport-layer connect, TPCI 0x80).
    #>
    return , ([byte[]]@(0x80))
}

function New-TpduDisconnect {
    <#
    .SYNOPSIS
        Builds a T_Disconnect TPDU (TPCI 0x81).
    #>
    return , ([byte[]]@(0x81))
}

function New-TpduAck {
    <#
    .SYNOPSIS
        Builds a T_ACK TPDU for a sequence number (TPCI 0xC2 | seq<<2).
    #>
    param([int]$Sequence = 0)
    return , ([byte[]]@((0xC2 -bor (($Sequence -band 0x0F) -shl 2))))
}

function New-CemiTransport {
    <#
    .SYNOPSIS
        Builds a cEMI transport-layer frame (T_Data_Individual / T_Data_Connected) for a
        device-management connection, per AN118.
    .DESCRIPTION
        Layout: MC | AddIL(0) | six zero octets (ctrl1 ctrl2 SA SA DA DA) | length | TPDU.
        The addresses are zero because the frame never leaves the local device - it is the
        device's own transport layer being addressed through the management connection.
    #>
    param(
        [Parameter(Mandatory)][int]$MessageCode,
        [Parameter(Mandatory)][byte[]]$Tpdu
    )
    return , ([byte[]]@(
        ($MessageCode -band 0xFF), 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        (($Tpdu.Length - 1) -band 0xFF)
    ) + $Tpdu)
}

function New-TpduPropertyValueRead {
    <#
    .SYNOPSIS
        Builds an A_PropertyValue_Read TPDU (APCI 0x3D5).
    .PARAMETER ObjectIndex
        Interface object INDEX, not the object type - property access by index here.
    #>
    param([int]$ObjectIndex = 0, [int]$PropertyId = 1, [int]$ElementCount = 1, [int]$StartIndex = 1)
    return , ([byte[]]@(
        0x03, 0xD5,
        ($ObjectIndex -band 0xFF),
        ($PropertyId -band 0xFF),
        (((($ElementCount -band 0x0F) -shl 4)) -bor (($StartIndex -shr 8) -band 0x0F)),
        ($StartIndex -band 0xFF)
    ))
}

function New-TpduPropertyValueResponse {
    <#
    .SYNOPSIS
        Builds an A_PropertyValue_Response TPDU (APCI 0x3D6).
    #>
    param([int]$ObjectIndex = 0, [int]$PropertyId = 1, [int]$ElementCount = 1, [int]$StartIndex = 1, [byte[]]$Data = @(0x00, 0x00))
    return , ([byte[]]@(
        0x03, 0xD6,
        ($ObjectIndex -band 0xFF),
        ($PropertyId -band 0xFF),
        (((($ElementCount -band 0x0F) -shl 4)) -bor (($StartIndex -shr 8) -band 0x0F)),
        ($StartIndex -band 0xFF)
    ) + $Data)
}

function New-TpduMemoryRead {
    <#
    .SYNOPSIS
        Builds an A_Memory_Read TPDU (APCI 0x200) for a number of octets at an address.
    #>
    param([int]$Address = 0x0060, [int]$Count = 1, [int]$Sequence = -1)
    $tpci = 0x00
    if ($Sequence -ge 0) { $tpci = 0x40 -bor (($Sequence -band 0x0F) -shl 2) }
    return , ([byte[]]@(
        ($tpci -bor 0x02),
        (($Count -band 0x3F)),
        (($Address -shr 8) -band 0xFF), ($Address -band 0xFF)
    ))
}

function New-TpduMemoryWrite {
    <#
    .SYNOPSIS
        Builds an A_Memory_Write TPDU (APCI 0x280).
    #>
    param([int]$Address = 0x0060, [Parameter(Mandatory)][byte[]]$Data, [int]$Sequence = -1)
    $tpci = 0x00
    if ($Sequence -ge 0) { $tpci = 0x40 -bor (($Sequence -band 0x0F) -shl 2) }
    return , ([byte[]]@(
        ($tpci -bor 0x02),
        (0x80 -bor ($Data.Length -band 0x3F)),
        (($Address -shr 8) -band 0xFF), ($Address -band 0xFF)
    ) + $Data)
}

function Get-TpduApci {
    <#
    .SYNOPSIS
        Extracts the 10-bit APCI from a TPDU, or -1 when the TPDU is too short.
    .DESCRIPTION
        The APCI spans the low 2 bits of the TPCI octet and all 8 bits of the next one.
        Short-form services (group value read/write) only use the upper 4 bits of the
        second octet, so compare against a masked value for those.
    #>
    param([Parameter(Mandatory)][byte[]]$Tpdu)
    if ($Tpdu.Length -lt 2) { return -1 }
    return ((((([int]$Tpdu[0]) -band 0x03) -shl 8) -bor ([int]$Tpdu[1])))
}

function New-CemiMPropRead {
    <#
    .SYNOPSIS
        Builds an M_PropRead.req cEMI frame (local device management).
    .DESCRIPTION
        Layout: FC | objType(2) | objInstance | PID | (nrOfElem<<4 | startIdx high) | startIdx low.
        The element count is only 4 bits, so 15 is the maximum per request and 0 means
        "error" in a confirmation - reading all 16 tunnel addresses needs two requests.
    #>
    param(
        [Parameter(Mandatory)][int]$ObjectType,
        [int]$ObjectInstance = 1,
        [Parameter(Mandatory)][int]$PropertyId,
        [int]$ElementCount = 1,
        [int]$StartIndex = 1,
        [int]$MessageCode = 0xFC
    )
    return , ([byte[]]@(
        ($MessageCode -band 0xFF),
        (($ObjectType -shr 8) -band 0xFF), ($ObjectType -band 0xFF),
        ($ObjectInstance -band 0xFF),
        ($PropertyId -band 0xFF),
        (((($ElementCount -band 0x0F) -shl 4)) -bor (($StartIndex -shr 8) -band 0x0F)),
        ($StartIndex -band 0xFF)
    ))
}

function New-CemiMPropWrite {
    <#
    .SYNOPSIS
        Builds an M_PropWrite.req cEMI frame.
    #>
    param(
        [Parameter(Mandatory)][int]$ObjectType,
        [int]$ObjectInstance = 1,
        [Parameter(Mandatory)][int]$PropertyId,
        [int]$ElementCount = 1,
        [int]$StartIndex = 1,
        [Parameter(Mandatory)][byte[]]$Data
    )
    $hdr = New-CemiMPropRead -ObjectType $ObjectType -ObjectInstance $ObjectInstance -PropertyId $PropertyId `
                             -ElementCount $ElementCount -StartIndex $StartIndex -MessageCode 0xF6
    return , ([byte[]]($hdr + $Data))
}

function New-CemiMReset {
    <#
    .SYNOPSIS
        Builds an M_Reset.req cEMI frame.
    #>
    return , ([byte[]]@(0xF1))
}

function Read-CemiMPropCon {
    <#
    .SYNOPSIS
        Parses an M_PropRead.con / M_PropWrite.con and returns header fields plus data.
    .DESCRIPTION
        On an error confirmation the element count is 0 and the single data octet is the
        error code - the caller must check ElementCount before trusting Data.
    #>
    param([Parameter(Mandatory)][byte[]]$Cemi)
    if ($Cemi.Length -lt 7) { return $null }
    $elem = (([int]$Cemi[5]) -shr 4) -band 0x0F
    $start = (((([int]$Cemi[5]) -band 0x0F) -shl 8) -bor ([int]$Cemi[6]))
    $data = [byte[]]@()
    if ($Cemi.Length -gt 7) { $data = [byte[]]$Cemi[7..($Cemi.Length - 1)] }
    # An error confirmation carries element count 0 and a single error-code octet.
    $errCode = -1
    if ($elem -eq 0 -and $data.Length -ge 1) { $errCode = $data[0] }
    return [pscustomobject]@{
        MessageCode    = $Cemi[0]
        ObjectType     = (Get-Uint16 -Bytes $Cemi -Offset 1)
        ObjectInstance = $Cemi[3]
        PropertyId     = $Cemi[4]
        ElementCount   = $elem
        StartIndex     = $start
        Data           = $data
        IsError        = ($elem -eq 0)
        ErrorCode      = $errCode
    }
}

function Read-CemiLData {
    <#
    .SYNOPSIS
        Parses an L_Data cEMI frame into its address, control and TPDU fields.
    #>
    param([Parameter(Mandatory)][byte[]]$Cemi)
    if ($Cemi.Length -lt 2) { return $null }
    $addIl = $Cemi[1]
    $o = 2 + $addIl
    if ($Cemi.Length -lt ($o + 7)) { return $null }
    $len = $Cemi[$o + 6]
    $tpduStart = $o + 7
    $tpduLen = $len + 1
    if (($tpduStart + $tpduLen) -gt $Cemi.Length) { $tpduLen = $Cemi.Length - $tpduStart }
    $addInfo = [byte[]]@()
    if ($addIl -gt 0) { $addInfo = [byte[]]$Cemi[2..(1 + $addIl)] }
    $tpdu = [byte[]]@()
    if ($tpduLen -gt 0) { $tpdu = [byte[]]$Cemi[$tpduStart..($tpduStart + $tpduLen - 1)] }
    return [pscustomobject]@{
        MessageCode    = $Cemi[0]
        AdditionalInfo = $addInfo
        Ctrl1          = $Cemi[$o]
        Ctrl2          = $Cemi[$o + 1]
        Source         = (Get-Uint16 -Bytes $Cemi -Offset ($o + 2))
        Destination    = (Get-Uint16 -Bytes $Cemi -Offset ($o + 4))
        IsGroup        = (($Cemi[$o + 1] -band 0x80) -ne 0)
        HopCount       = ((([int]$Cemi[$o + 1]) -shr 4) -band 0x07)
        Priority       = ((([int]$Cemi[$o]) -shr 2) -band 0x03)
        IsRepeated     = (($Cemi[$o] -band 0x20) -eq 0)
        IsStandard     = (($Cemi[$o] -band 0x80) -ne 0)
        Length         = $len
        Tpdu           = $tpdu
    }
}

function Read-CemiBusmon {
    <#
    .SYNOPSIS
        Parses an L_Busmon.ind and returns the raw LPDU plus the 03h status octet fields.
    .DESCRIPTION
        The raw LPDU starts at offset 2+AddIL and its last octet is the TP1 FCS as received.
        AddIL is vendor variable - never assume a fixed offset (03_06_03 section 4.1.4.1).
    #>
    param([Parameter(Mandatory)][byte[]]$Cemi)
    if ($Cemi.Length -lt 3) { return $null }
    $addIl = $Cemi[1]
    $o = 2 + $addIl
    if ($Cemi.Length -le $o) { return $null }
    $lpdu = [byte[]]$Cemi[$o..($Cemi.Length - 1)]

    # Walk the additional-information blocks looking for the 03h busmonitor status octet.
    $status = -1
    $i = 2
    while ($i -lt (2 + $addIl) -and ($i + 1) -lt $Cemi.Length) {
        $typeId = $Cemi[$i]; $len = $Cemi[$i + 1]
        if ($typeId -eq 0x03 -and $len -ge 1 -and ($i + 2) -lt $Cemi.Length) { $status = $Cemi[$i + 2] }
        $i += 2 + $len
    }
    # Status bits F B P x L s s s (03_06_03 section 4.1.5.8.1). Absent block -> unknown, not "clean".
    # A TP1 acknowledge frame is a SINGLE octet (03_02_02 section 2.2.7 p.31, pattern
    # xx00 xx00: ACK 0xCC, NAK 0x0C, BUSY 0xC0) and carries NO frame check octet at all.
    # Running the FCS over it computes 0xFF from zero preceding octets and compares that
    # against the acknowledge itself, which never matches - that reported a correctly
    # working busmonitor as delivering corrupt data. Acknowledges are valid by definition.
    $isAck = ($lpdu.Length -eq 1)
    $lost = $null; $seq = -1; $fErr = $null; $bErr = $null; $pErr = $null
    if ($status -ge 0) {
        $lost = (($status -band 0x08) -ne 0)
        $seq  = ($status -band 0x07)
        $fErr = (($status -band 0x80) -ne 0)
        $bErr = (($status -band 0x40) -ne 0)
        $pErr = (($status -band 0x20) -ne 0)
    }
    return [pscustomobject]@{
        AddIL       = $addIl
        Lpdu        = $lpdu
        Status      = $status
        Lost        = $lost
        Sequence    = $seq
        FrameError  = $fErr
        BitError    = $bErr
        ParityError = $pErr
        Fcs         = $(if ($isAck) { $null } else { $lpdu[$lpdu.Length - 1] })
        IsAck       = $isAck
        FcsOk       = $(if ($isAck) { $true } else { (Test-Tp1Fcs -Lpdu $lpdu) })
    }
}

function Get-Tp1Fcs {
    <#
    .SYNOPSIS
        Computes the TP1 frame check octet over all preceding octets.
    .DESCRIPTION
        FCS = 0xFF XOR (b0 ^ b1 ^ ... ^ b[n-2])  (03_02_02 section 2.2.4.6).
    #>
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $crc = 0xFF
    foreach ($b in $Bytes) { $crc = $crc -bxor $b }
    return [byte]($crc -band 0xFF)
}

function Test-Tp1Fcs {
    <#
    .SYNOPSIS
        Verifies that the last octet of an LPDU is the correct FCS over the rest.
    #>
    param([Parameter(Mandatory)][byte[]]$Lpdu)
    if ($Lpdu.Length -lt 2) { return $false }
    $body = [byte[]]$Lpdu[0..($Lpdu.Length - 2)]
    return ((Get-Tp1Fcs -Bytes $body) -eq $Lpdu[$Lpdu.Length - 1])
}

function Get-Tp1FrameLength {
    <#
    .SYNOPSIS
        Returns the total TP1 telegram length from its header, or -1 when undecidable.
    .DESCRIPTION
        Standard frame (ctrl bit7 = 1): total = 8 + (octet5 low nibble).
        Extended frame (ctrl bit7 = 0): total = 9 + octet6.  (03_02_02 sections 2.2.2/2.2.5)
    #>
    param([Parameter(Mandatory)][byte[]]$Bytes)
    if ($Bytes.Length -lt 1) { return -1 }
    if (($Bytes[0] -band 0x80) -ne 0) {
        if ($Bytes.Length -lt 6) { return -1 }
        return 8 + ($Bytes[5] -band 0x0F)
    }
    if ($Bytes.Length -lt 7) { return -1 }
    return 9 + $Bytes[6]
}

# ─── Response parsing ───────────────────────────────────────────────────────────

function Read-KnxHeader {
    <#
    .SYNOPSIS
        Parses the six-octet KNXnet/IP header and reports whether it is well formed.
    #>
    param([Parameter(Mandatory)][byte[]]$Frame)
    if ($Frame.Length -lt 6) { return $null }
    $total = Get-Uint16 -Bytes $Frame -Offset 4
    $svc = Get-Uint16 -Bytes $Frame -Offset 2
    $body = [byte[]]@()
    if ($Frame.Length -gt 6) { $body = [byte[]]$Frame[6..($Frame.Length - 1)] }
    return [pscustomobject]@{
        HeaderSize  = $Frame[0]
        Version     = $Frame[1]
        Service     = $svc
        ServiceName = (Get-KnxServiceName -Service $svc)
        TotalLength = $total
        Body        = $body
        WellFormed  = ($Frame[0] -eq 0x06 -and $Frame[1] -eq 0x10 -and $total -eq $Frame.Length)
    }
}

function Read-KnxDibs {
    <#
    .SYNOPSIS
        Walks the DIB blocks of a SEARCH_RESPONSE or DESCRIPTION_RESPONSE body.
    .DESCRIPTION
        Returns one object per DIB plus decoded convenience fields for the two DIBs the
        suites care about most: Device Information and Supported Service Families.
        A zero or over-long structure length terminates the walk instead of looping.
    #>
    param([Parameter(Mandatory)][byte[]]$Body, [int]$Offset = 0)
    $dibs = @()
    $i = $Offset
    while ($i -lt $Body.Length) {
        $len = $Body[$i]
        if ($len -lt 2 -or ($i + $len) -gt $Body.Length) { break }
        $type = $Body[$i + 1]
        $payload = if ($len -gt 2) { [byte[]]$Body[($i + 2)..($i + $len - 1)] } else { [byte[]]@() }
        $dib = [pscustomobject]@{
            Length   = $len
            Type     = $type
            TypeName = (Get-KnxDibName -Type $type)
            Payload  = $payload
            Decoded  = $null
        }
        switch ($type) {
            0x01 {
                if ($payload.Length -ge 52) {
                    $dib.Decoded = [pscustomobject]@{
                        MediumCode     = $payload[0]
                        DeviceStatus   = $payload[1]
                        ProgMode       = (($payload[1] -band 0x01) -ne 0)
                        IndividualAddr = (ConvertFrom-KnxPa -Raw (Get-Uint16 -Bytes $payload -Offset 2))
                        ProjectInstId  = (Get-Uint16 -Bytes $payload -Offset 4)
                        SerialNumber   = (ConvertTo-HexString -Bytes ([byte[]]$payload[6..11]))
                        MulticastAddr  = ([System.Net.IPAddress]::new([byte[]]$payload[12..15])).ToString()
                        MacAddress     = (ConvertTo-HexString -Bytes ([byte[]]$payload[16..21]))
                        FriendlyName   = ([System.Text.Encoding]::ASCII.GetString([byte[]]$payload[22..51])).TrimEnd([char]0, ' ')
                    }
                }
            }
            0x02 {
                $fams = @()
                for ($f = 0; ($f + 1) -lt $payload.Length; $f += 2) {
                    $fams += [pscustomobject]@{ Id = $payload[$f]; Name = (Get-KnxFamilyName -Id $payload[$f]); Version = $payload[$f + 1] }
                }
                $dib.Decoded = $fams
            }
            0x08 {
                if ($payload.Length -ge 6) {
                    $dib.Decoded = [pscustomobject]@{
                        MediumStatus  = $payload[0]
                        MaxApduLength = (Get-Uint16 -Bytes $payload -Offset 2)
                        MaskVersion   = ('0x{0:X4}' -f (Get-Uint16 -Bytes $payload -Offset 4))
                    }
                }
            }
        }
        $dibs += $dib
        $i += $len
    }
    return , $dibs
}

function Get-KnxDibName {
    param([int]$Type)
    foreach ($k in $script:KnxDib.Keys) { if ($script:KnxDib[$k] -eq $Type) { return $k } }
    return ('0x{0:X2}' -f $Type)
}

function Get-KnxFamilyName {
    param([int]$Id)
    foreach ($k in $script:KnxFamily.Keys) { if ($script:KnxFamily[$k] -eq $Id) { return $k } }
    return ('0x{0:X2}' -f $Id)
}

function Get-KnxServiceFamilies {
    <#
    .SYNOPSIS
        Extracts the Supported Service Families DIB from a response body.
    .DESCRIPTION
        Returns an array of {Id, Name, Version}; an empty array when the DIB is absent.
        This is the single most load-bearing check of the whole suite: it decides whether
        a device is an interface or a routing device (03_08_02 Core).
    #>
    param([Parameter(Mandatory)][byte[]]$Body)
    $dibs = Read-KnxDibs -Body $Body
    foreach ($d in $dibs) {
        if ($d.Type -eq $script:KnxDib.SUPP_SVC_FAMILIES -and $null -ne $d.Decoded) { return , @($d.Decoded) }
    }
    return , @()
}

function Test-KnxFamilySupported {
    <#
    .SYNOPSIS
        True when the response body advertises the given service family.
    #>
    param([Parameter(Mandatory)][byte[]]$Body, [Parameter(Mandatory)][int]$Family)
    foreach ($f in (Get-KnxServiceFamilies -Body $Body)) { if ($f.Id -eq $Family) { return $true } }
    return $false
}

function Read-KnxConnectResponse {
    <#
    .SYNOPSIS
        Parses a CONNECT_RESPONSE: channel, status, data HPAI and the CRD.
    .DESCRIPTION
        An error response is short - only channel and status are present. The parser must
        therefore never index into the HPAI before checking the status (a length guard
        placed ahead of the status check would shadow exactly the error frames we test for).
    #>
    param([Parameter(Mandatory)][byte[]]$Body)
    if ($Body.Length -lt 2) { return $null }
    $res = [pscustomobject]@{
        Channel     = $Body[0]
        Status      = $Body[1]
        StatusName  = (Get-KnxErrorName -Status $Body[1])
        IsError     = ($Body[1] -ne 0x00)
        Crd         = [byte[]]@()
        TunnelPa    = $null
    }
    if ($res.IsError -or $Body.Length -lt 12) { return $res }
    # 2 octets header + 8 octets data HPAI, then the CRD.
    $res.Crd = [byte[]]$Body[10..($Body.Length - 1)]
    if ($res.Crd.Length -ge 4 -and $res.Crd[1] -eq $script:KnxConnType.TUNNEL_CONNECTION) {
        $res.TunnelPa = ConvertFrom-KnxPa -Raw (Get-Uint16 -Bytes $res.Crd -Offset 2)
    }
    return $res
}

# ─── UDP transport ──────────────────────────────────────────────────────────────

function New-KnxSocket {
    <#
    .SYNOPSIS
        Creates a bound UDP socket with a receive timeout.
    .PARAMETER LocalPort
        0 lets the OS pick. Pass a fixed port when a test needs a predictable HPAI.
    #>
    param([int]$TimeoutMs = 1500, [int]$LocalPort = 0, [switch]$Broadcast)
    $s = New-Object System.Net.Sockets.Socket([System.Net.Sockets.AddressFamily]::InterNetwork,
                                              [System.Net.Sockets.SocketType]::Dgram,
                                              [System.Net.Sockets.ProtocolType]::Udp)
    $s.ReceiveTimeout = $TimeoutMs
    $s.SendTimeout = 2000
    if ($Broadcast) { $s.EnableBroadcast = $true }
    $s.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $LocalPort)))
    return $s
}

function New-KnxMulticastSocket {
    <#
    .SYNOPSIS
        Creates a UDP socket joined to a KNXnet/IP routing multicast group.
    #>
    param([string]$Group = '224.0.23.12', [int]$Port = 3671, [int]$TimeoutMs = 1500)
    $s = New-Object System.Net.Sockets.Socket([System.Net.Sockets.AddressFamily]::InterNetwork,
                                              [System.Net.Sockets.SocketType]::Dgram,
                                              [System.Net.Sockets.ProtocolType]::Udp)
    $s.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
    $s.ReceiveTimeout = $TimeoutMs
    $s.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $Port)))
    $mreq = New-Object System.Net.Sockets.MulticastOption([System.Net.IPAddress]::Parse($Group))
    $s.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::IP, [System.Net.Sockets.SocketOptionName]::AddMembership, $mreq)
    $s.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::IP, [System.Net.Sockets.SocketOptionName]::MulticastTimeToLive, 16)
    return $s
}

function Get-LocalEndpointFor {
    <#
    .SYNOPSIS
        Determines the local IP the OS would use to reach a destination.
    .DESCRIPTION
        Needed for a non-NAT HPAI: connecting a UDP socket performs no traffic but binds
        the local endpoint, which is exactly the address the server must answer to.
    #>
    param([Parameter(Mandatory)][string]$DestinationIp, [int]$Port = 3671)
    $probe = New-Object System.Net.Sockets.Socket([System.Net.Sockets.AddressFamily]::InterNetwork,
                                                  [System.Net.Sockets.SocketType]::Dgram,
                                                  [System.Net.Sockets.ProtocolType]::Udp)
    try {
        $probe.Connect((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($DestinationIp), $Port)))
        return ($probe.LocalEndPoint).Address.ToString()
    }
    catch { return '0.0.0.0' }
    finally { $probe.Dispose() }
}

function Get-SocketLocalPort {
    <#
    .SYNOPSIS
        Returns the port a socket is actually bound to.
    #>
    param([Parameter(Mandatory)]$Socket)
    return ($Socket.LocalEndPoint).Port
}

function Send-KnxFrame {
    <#
    .SYNOPSIS
        Sends a raw datagram to a KNXnet/IP endpoint.
    #>
    param(
        [Parameter(Mandatory)]$Socket,
        [Parameter(Mandatory)][byte[]]$Frame,
        [Parameter(Mandatory)][string]$Ip,
        [int]$Port = 3671
    )
    $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($Ip), $Port)
    [void]$Socket.SendTo($Frame, $ep)
}

function Receive-KnxFrame {
    <#
    .SYNOPSIS
        Waits for one datagram and returns it with its sender, or $null on timeout.
    #>
    param([Parameter(Mandatory)]$Socket, [int]$TimeoutMs = -1)
    $saved = $Socket.ReceiveTimeout
    if ($TimeoutMs -ge 0) { $Socket.ReceiveTimeout = $TimeoutMs }
    try {
        $buf = New-Object byte[] 1024
        $remote = [System.Net.EndPoint](New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0))
        $n = $Socket.ReceiveFrom($buf, [ref]$remote)
        if ($n -le 0) { return $null }
        return [pscustomobject]@{
            Bytes  = [byte[]]$buf[0..($n - 1)]
            Length = $n
            From   = $remote.ToString()
        }
    }
    catch [System.Net.Sockets.SocketException] { return $null }
    finally { $Socket.ReceiveTimeout = $saved }
}

function Wait-KnxService {
    <#
    .SYNOPSIS
        Receives until a frame with one of the wanted service types arrives, or the deadline passes.
    .DESCRIPTION
        Other services seen while waiting are collected in Ignored, so a test can prove
        that nothing unexpected was emitted rather than silently discarding it.
    #>
    param(
        [Parameter(Mandatory)]$Socket,
        [Parameter(Mandatory)][int[]]$Service,
        [int]$TimeoutMs = 2000
    )
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    $ignored = @()
    while ([DateTime]::UtcNow -lt $deadline) {
        $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
        $pkt = Receive-KnxFrame -Socket $Socket -TimeoutMs $left
        if ($null -eq $pkt) { break }
        $h = Read-KnxHeader -Frame $pkt.Bytes
        if ($null -eq $h) { $ignored += $pkt; continue }
        if ($Service -contains $h.Service) {
            return [pscustomobject]@{ Header = $h; Packet = $pkt; Ignored = $ignored; TimedOut = $false }
        }
        $ignored += $pkt
    }
    return [pscustomobject]@{ Header = $null; Packet = $null; Ignored = $ignored; TimedOut = $true }
}

function Invoke-KnxRequest {
    <#
    .SYNOPSIS
        Sends a frame and waits for the expected response service in one call.
    #>
    param(
        [Parameter(Mandatory)]$Socket,
        [Parameter(Mandatory)][byte[]]$Frame,
        [Parameter(Mandatory)][string]$Ip,
        [int]$Port = 3671,
        [int[]]$Expect = @(),
        [int]$TimeoutMs = 2000
    )
    Send-KnxFrame -Socket $Socket -Frame $Frame -Ip $Ip -Port $Port
    if ($Expect.Count -eq 0) { return $null }
    return Wait-KnxService -Socket $Socket -Service $Expect -TimeoutMs $TimeoutMs
}

function Clear-KnxSocket {
    <#
    .SYNOPSIS
        Drains any queued datagrams so a following test starts from a clean state.
    #>
    param([Parameter(Mandatory)]$Socket, [int]$QuietMs = 120)
    while ($true) {
        $pkt = Receive-KnxFrame -Socket $Socket -TimeoutMs $QuietMs
        if ($null -eq $pkt) { break }
    }
}

# ─── Connections ────────────────────────────────────────────────────────────────

function Open-KnxConnection {
    <#
    .SYNOPSIS
        Opens a tunnelling or device-management connection and returns a connection object.
    .DESCRIPTION
        Uses one socket for control and data, which is what every real client does and
        what the NAT tests then vary deliberately. Returns an object even on refusal, so a
        negative test can assert the exact status code instead of just "it failed".
    #>
    param(
        [Parameter(Mandatory)][string]$Ip,
        [int]$Port = 3671,
        [int]$ConnectionType = 0x04,
        [int]$Layer = 0x02,
        [int]$TimeoutMs = 3000,
        [switch]$Nat
    )
    $sock = New-KnxSocket -TimeoutMs $TimeoutMs
    $localIp = if ($Nat) { '0.0.0.0' } else { Get-LocalEndpointFor -DestinationIp $Ip -Port $Port }
    $localPort = if ($Nat) { 0 } else { Get-SocketLocalPort -Socket $sock }
    if ($ConnectionType -eq $script:KnxConnType.TUNNEL_CONNECTION) {
        $frame = New-KnxConnectRequest -ControlIp $localIp -ControlPort $localPort -DataIp $localIp -DataPort $localPort -ConnectionType $ConnectionType -Layer $Layer
    }
    else {
        $frame = New-KnxConnectRequest -ControlIp $localIp -ControlPort $localPort -DataIp $localIp -DataPort $localPort -ConnectionType $ConnectionType -Layer -1
    }
    $rsp = Invoke-KnxRequest -Socket $sock -Frame $frame -Ip $Ip -Port $Port -Expect @($script:KnxService.CONNECT_RESPONSE) -TimeoutMs $TimeoutMs
    if ($rsp.TimedOut) {
        $sock.Dispose()
        return [pscustomobject]@{ Ok = $false; Status = -1; StatusName = 'NO_ANSWER'; Channel = -1; Socket = $null; Ip = $Ip; Port = $Port; SeqSend = 0; SeqRecv = 0; TunnelPa = $null; Request = $frame; Response = $null }
    }
    $cr = Read-KnxConnectResponse -Body $rsp.Header.Body
    if ($cr.IsError) {
        $sock.Dispose()
        return [pscustomobject]@{ Ok = $false; Status = $cr.Status; StatusName = $cr.StatusName; Channel = -1; Socket = $null; Ip = $Ip; Port = $Port; SeqSend = 0; SeqRecv = 0; TunnelPa = $null; Request = $frame; Response = $rsp.Packet.Bytes }
    }
    return [pscustomobject]@{
        Ok         = $true
        Status     = $cr.Status
        StatusName = $cr.StatusName
        Channel    = $cr.Channel
        Socket     = $sock
        Ip         = $Ip
        Port       = $Port
        SeqSend    = 0
        SeqRecv    = 0
        TunnelPa   = $cr.TunnelPa
        LocalIp    = $localIp
        LocalPort  = (Get-SocketLocalPort -Socket $sock)
        Request    = $frame
        Response   = $rsp.Packet.Bytes
    }
}

function Close-KnxConnection {
    <#
    .SYNOPSIS
        Sends a DISCONNECT_REQUEST and releases the socket. Safe to call on a dead connection.
    #>
    param([Parameter(Mandatory)]$Connection, [int]$TimeoutMs = 1500)
    if ($null -eq $Connection -or $null -eq $Connection.Socket) { return $false }
    $ok = $false
    try {
        $f = New-KnxDisconnectRequest -Channel $Connection.Channel -ControlIp $Connection.LocalIp -ControlPort $Connection.LocalPort
        $r = Invoke-KnxRequest -Socket $Connection.Socket -Frame $f -Ip $Connection.Ip -Port $Connection.Port -Expect @($script:KnxService.DISCONNECT_RESPONSE) -TimeoutMs $TimeoutMs
        $ok = (-not $r.TimedOut)
    }
    catch { $ok = $false }
    finally { try { $Connection.Socket.Dispose() } catch { } }
    return $ok
}

function Send-KnxTunnelCemi {
    <#
    .SYNOPSIS
        Sends a cEMI frame over a tunnel connection and waits for the TUNNELLING_ACK.
    .DESCRIPTION
        Advances the send sequence only on an accepted ack, so a test that deliberately
        repeats or skips a sequence number stays in control of the counter.
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][byte[]]$Cemi,
        [int]$Sequence = -1,
        [int]$TimeoutMs = 2000,
        [switch]$NoAdvance
    )
    $seq = if ($Sequence -ge 0) { $Sequence } else { $Connection.SeqSend }
    $frame = New-KnxTunnellingRequest -Channel $Connection.Channel -Sequence $seq -Cemi $Cemi
    Send-KnxFrame -Socket $Connection.Socket -Frame $frame -Ip $Connection.Ip -Port $Connection.Port

    # While waiting for our own ack the device may already be sending us frames - the
    # L_Data.con for this very request, and any indication that arrives meanwhile. Waiting
    # only for TUNNELLING_ACK discards them unacked; the device then keeps them queued,
    # runs into its outstanding-frame limit and drops the connection, which looks exactly
    # like "the device never answered". Take them here, ack them, and park them so the
    # next Receive-KnxTunnelCemi hands them out in arrival order.
    if ($null -eq $Connection.PSObject.Properties['Pending']) {
        Add-Member -InputObject $Connection -NotePropertyName 'Pending' `
                   -NotePropertyValue (New-Object 'System.Collections.Generic.List[object]') -Force
    }
    $status = -1; $ackSeq = -1; $ackCh = -1
    $ack = $null
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
        $r = Wait-KnxService -Socket $Connection.Socket `
                             -Service @($script:KnxService.TUNNELLING_ACK, $script:KnxService.TUNNELLING_REQUEST,
                                        $script:KnxService.DISCONNECT_REQUEST) `
                             -TimeoutMs $left
        if ($r.TimedOut) { $ack = $r; break }
        # A server that cannot get its own frames acknowledged repeats once and then ENDS
        # the connection with a DISCONNECT_REQUEST (03_08_04 clause 2.6.1). Listening only
        # for ACK and REQUEST made that invisible: the channel was gone, every following
        # request was correctly ignored as an unknown channel id (03_08_02 clause 5.5), and
        # the silence read as "the device stopped acknowledging". It had said so, once.
        if ($r.Header.Service -eq $script:KnxService.DISCONNECT_REQUEST) {
            $db = $r.Header.Body
            if ($db.Length -ge 2) {
                Send-KnxFrame -Socket $Connection.Socket -Frame (New-KnxDisconnectResponse -Channel $db[0] -Status 0) `
                              -Ip $Connection.Ip -Port $Connection.Port
            }
            Add-Member -InputObject $Connection -NotePropertyName 'Disconnected' -NotePropertyValue $true -Force
            $ack = [pscustomobject]@{ TimedOut = $true; Ignored = $r.Ignored }
            break
        }
        if ($r.Header.Service -eq $script:KnxService.TUNNELLING_ACK) { $ack = $r; break }
        $b = $r.Header.Body
        if ($b.Length -ge 4) {
            Send-KnxFrame -Socket $Connection.Socket -Frame (New-KnxTunnellingAck -Channel $b[1] -Sequence $b[2]) `
                          -Ip $Connection.Ip -Port $Connection.Port
            $inCemi = if ($b.Length -gt 4) { [byte[]]$b[4..($b.Length - 1)] } else { [byte[]]@() }
            $Connection.SeqRecv = $b[2]
            [void]$Connection.Pending.Add([pscustomobject]@{
                    Channel = $b[1]; Sequence = $b[2]; Cemi = $inCemi; Raw = $r.Packet.Bytes; Ignored = $r.Ignored
                })
        }
    }
    if ($null -eq $ack) { $ack = [pscustomobject]@{ TimedOut = $true; Ignored = @() } }
    if (-not $ack.TimedOut -and $ack.Header.Body.Length -ge 4) {
        $ackCh = $ack.Header.Body[1]; $ackSeq = $ack.Header.Body[2]; $status = $ack.Header.Body[3]
    }
    if (-not $NoAdvance -and $status -eq 0) { $Connection.SeqSend = (($seq + 1) -band 0xFF) }
    $gone = $false
    if ($null -ne $Connection.PSObject.Properties['Disconnected']) { $gone = [bool]$Connection.Disconnected }
    return [pscustomobject]@{
        Sent         = $frame
        Disconnected = $gone
        Sequence   = $seq
        Acked      = (-not $ack.TimedOut)
        AckChannel = $ackCh
        AckSeq     = $ackSeq
        Status     = $status
        Ignored    = $ack.Ignored
    }
}

function Receive-KnxTunnelCemi {
    <#
    .SYNOPSIS
        Waits for a TUNNELLING_REQUEST from the device, acks it, and returns its cEMI.
    .PARAMETER NoAck
        Do not answer - for the "repeat and timeout after missing ACK" test cases.
    #>
    param([Parameter(Mandatory)]$Connection, [int]$TimeoutMs = 3000, [switch]$NoAck)
    # Frames that arrived while Send-KnxTunnelCemi was waiting for its ack are parked on the
    # connection. Hand them out first so the caller sees arrival order. Not for -NoAck: those
    # cases test what happens when we do NOT ack, and a parked frame was already acked.
    if (-not $NoAck -and $null -ne $Connection.PSObject.Properties['Pending'] -and $Connection.Pending.Count -gt 0) {
        $first = $Connection.Pending[0]
        $Connection.Pending.RemoveAt(0)
        return $first
    }
    # A listen-only connection - the busmonitor is the whole reason this path exists - never
    # calls Send-KnxTunnelCemi, so the DISCONNECT_REQUEST handling added there does not cover
    # it. Without this a server that ends the connection is indistinguishable from a quiet
    # bus: the caller waits out its window and reports "captured nothing".
    $r = Wait-KnxService -Socket $Connection.Socket `
                         -Service @($script:KnxService.TUNNELLING_REQUEST, $script:KnxService.DISCONNECT_REQUEST) `
                         -TimeoutMs $TimeoutMs
    if ($r.TimedOut) { return $null }
    if ($r.Header.Service -eq $script:KnxService.DISCONNECT_REQUEST) {
        $db = $r.Header.Body
        if ($db.Length -ge 2) {
            Send-KnxFrame -Socket $Connection.Socket -Frame (New-KnxDisconnectResponse -Channel $db[0] -Status 0) `
                          -Ip $Connection.Ip -Port $Connection.Port
        }
        Add-Member -InputObject $Connection -NotePropertyName 'Disconnected' -NotePropertyValue $true -Force
        return $null
    }
    $b = $r.Header.Body
    if ($b.Length -lt 4) { return $null }
    $ch = $b[1]; $seq = $b[2]
    $cemi = if ($b.Length -gt 4) { [byte[]]$b[4..($b.Length - 1)] } else { [byte[]]@() }
    if (-not $NoAck) {
        $ack = New-KnxTunnellingAck -Channel $ch -Sequence $seq
        Send-KnxFrame -Socket $Connection.Socket -Frame $ack -Ip $Connection.Ip -Port $Connection.Port
    }
    $Connection.SeqRecv = $seq
    return [pscustomobject]@{ Channel = $ch; Sequence = $seq; Cemi = $cemi; Raw = $r.Packet.Bytes; Ignored = $r.Ignored }
}

function Send-KnxDeviceConfiguration {
    <#
    .SYNOPSIS
        Sends a cEMI M_* frame over a device-management connection and returns the confirmation.
    .DESCRIPTION
        The device answers with DEVICE_CONFIGURATION_ACK first and then with its own
        DEVICE_CONFIGURATION_REQUEST carrying the .con - both are collected here, and the
        .con is acked, because leaving it unacked poisons every following test.
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][byte[]]$Cemi,
        [int]$Sequence = -1,
        [int]$TimeoutMs = 3000,
        [switch]$NoAdvance
    )
    $seq = if ($Sequence -ge 0) { $Sequence } else { $Connection.SeqSend }
    $frame = New-KnxDeviceConfigurationRequest -Channel $Connection.Channel -Sequence $seq -Cemi $Cemi
    Send-KnxFrame -Socket $Connection.Socket -Frame $frame -Ip $Connection.Ip -Port $Connection.Port

    $ackStatus = -1
    $conCemi = $null
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
        $r = Wait-KnxService -Socket $Connection.Socket `
                             -Service @($script:KnxService.DEVICE_CONFIGURATION_ACK, $script:KnxService.DEVICE_CONFIGURATION_REQUEST) `
                             -TimeoutMs $left
        if ($r.TimedOut) { break }
        if ($r.Header.Service -eq $script:KnxService.DEVICE_CONFIGURATION_ACK) {
            if ($r.Header.Body.Length -ge 4) { $ackStatus = $r.Header.Body[3] }
            continue
        }
        # DEVICE_CONFIGURATION_REQUEST from the device: this is the confirmation.
        $b = $r.Header.Body
        if ($b.Length -ge 4) {
            $ackBack = New-KnxDeviceConfigurationAck -Channel $b[1] -Sequence $b[2]
            Send-KnxFrame -Socket $Connection.Socket -Frame $ackBack -Ip $Connection.Ip -Port $Connection.Port
            if ($b.Length -gt 4) { $conCemi = [byte[]]$b[4..($b.Length - 1)] }
        }
        break
    }
    if (-not $NoAdvance -and $ackStatus -eq 0) { $Connection.SeqSend = (($seq + 1) -band 0xFF) }
    $parsed = $null
    if ($null -ne $conCemi) { $parsed = Read-CemiMPropCon -Cemi $conCemi }
    return [pscustomobject]@{
        Sent      = $frame
        Sequence  = $seq
        AckStatus = $ackStatus
        Acked     = ($ackStatus -eq 0)
        Cemi      = $conCemi
        Parsed    = $parsed
    }
}

function Wait-KnxPropInfo {
    <#
    .SYNOPSIS
        Waits for an unsolicited M_PropInfo.ind on a device-management connection.
    .DESCRIPTION
        The device reports state changes (e.g. KNXNETIP_DEVICE_STATE when the bus goes
        away) by sending a DEVICE_CONFIGURATION_REQUEST carrying M_PropInfo.ind. It must
        be acknowledged - an unacknowledged indication is repeated and eventually drops
        the connection, which would poison every following test case.
        Returns the cEMI frame, or $null on timeout.
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Ip,
        [int]$Port = 3671,
        [int]$TimeoutMs = 8000,
        [int]$PropertyId = -1
    )
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
        $r = Wait-KnxService -Socket $Connection.Socket -Service @($script:KnxService.DEVICE_CONFIGURATION_REQUEST) -TimeoutMs $left
        if ($r.TimedOut) { return $null }
        $b = $r.Header.Body
        if ($b.Length -lt 5) { continue }
        $ackBack = New-KnxDeviceConfigurationAck -Channel $b[1] -Sequence $b[2]
        Send-KnxFrame -Socket $Connection.Socket -Frame $ackBack -Ip $Ip -Port $Port
        $cemi = [byte[]]$b[4..($b.Length - 1)]
        if ($cemi[0] -ne $script:Cemi.M_PROPINFO_IND) { continue }
        if ($PropertyId -ge 0 -and $cemi.Length -ge 5 -and $cemi[4] -ne $PropertyId) { continue }
        return $cemi
    }
    return $null
}

function Read-KnxProperty {
    <#
    .SYNOPSIS
        Convenience wrapper: M_PropRead over a device-management connection.
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][int]$ObjectType,
        [Parameter(Mandatory)][int]$PropertyId,
        [int]$ObjectInstance = 1,
        [int]$ElementCount = 1,
        [int]$StartIndex = 1,
        [int]$TimeoutMs = 3000
    )
    $cemi = New-CemiMPropRead -ObjectType $ObjectType -ObjectInstance $ObjectInstance -PropertyId $PropertyId -ElementCount $ElementCount -StartIndex $StartIndex
    return Send-KnxDeviceConfiguration -Connection $Connection -Cemi $cemi -TimeoutMs $TimeoutMs
}

function Get-KnxTunnelPool {
    <#
    .SYNOPSIS
        Reads PID_ADDITIONAL_INDIVIDUAL_ADDRESSES and returns the configured entries.
    .DESCRIPTION
        Whether E_NO_MORE_CONNECTIONS or E_NO_MORE_UNIQUE_CONNECTIONS is the correct answer
        to an exhausted pool depends on the POOL, not on the addresses that were handed out:
        those are distinct by construction, since the server never opens two tunnels with the
        same address. Reading the granted set instead of the pool makes the check confirm its
        own premise, which is how a spec-conform device was reported as defective.

        An ETS entry left without an address shows up here as a duplicate of its neighbour,
        and that duplicate is exactly the 03_08_04 (p.6) condition for 0x25.

        The element count field is four bits wide, so 16 wraps to 0 - read 15 + 1.
    #>
    param([Parameter(Mandatory)][string]$Ip, [int]$Port = 3671, [int]$Count = 16)
    $entries = @()
    $conn = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $script:KnxConnType.DEVICE_MGMT_CONNECTION -Layer -1
    if (-not $conn.Ok) { return , $entries }
    try {
        $first = [Math]::Min(15, $Count)
        $blocks = @(@{ s = 1; n = $first })
        if ($Count -gt 15) { $blocks += @{ s = 16; n = ($Count - 15) } }
        foreach ($b in $blocks) {
            $r = Read-KnxProperty -Connection $conn -ObjectType $script:ObjType.KNXNETIP_PARAM `
                                  -PropertyId $script:KnxPid.ADDITIONAL_INDIVIDUAL_ADDRESSES -ElementCount $b.n -StartIndex $b.s
            if ($null -eq $r.Parsed -or $r.Parsed.IsError) { continue }
            $d = $r.Parsed.Data
            for ($o = 0; ($o + 1) -lt $d.Length; $o += 2) {
                $raw = Get-Uint16 -Bytes $d -Offset $o
                if ($raw -gt 0) { $entries += (ConvertFrom-KnxPa -Raw $raw) }
            }
        }
    }
    finally { [void](Close-KnxConnection -Connection $conn) }
    return , $entries
}


# ─── Rig helpers ────────────────────────────────────────────────────────────────

function Test-KnxAlive {
    <#
    .SYNOPSIS
        True when the endpoint answers a DESCRIPTION_REQUEST.
    .DESCRIPTION
        DESCRIPTION is the right liveness probe: it needs no connection, so it still
        answers when every tunnel slot is taken - only a real outage silences it.
    #>
    param([Parameter(Mandatory)][string]$Ip, [int]$Port = 3671, [int]$TimeoutMs = 1500)
    $s = New-KnxSocket -TimeoutMs $TimeoutMs
    try {
        $local = Get-LocalEndpointFor -DestinationIp $Ip -Port $Port
        $f = New-KnxDescriptionRequest -ControlIp $local -ControlPort (Get-SocketLocalPort -Socket $s)
        $r = Invoke-KnxRequest -Socket $s -Frame $f -Ip $Ip -Port $Port -Expect @($script:KnxService.DESCRIPTION_RESPONSE) -TimeoutMs $TimeoutMs
        return (-not $r.TimedOut)
    }
    finally { $s.Dispose() }
}

function Get-KnxDescription {
    <#
    .SYNOPSIS
        Fetches and decodes a DESCRIPTION_RESPONSE.
    #>
    param([Parameter(Mandatory)][string]$Ip, [int]$Port = 3671, [int]$TimeoutMs = 2000)
    $s = New-KnxSocket -TimeoutMs $TimeoutMs
    try {
        $local = Get-LocalEndpointFor -DestinationIp $Ip -Port $Port
        $f = New-KnxDescriptionRequest -ControlIp $local -ControlPort (Get-SocketLocalPort -Socket $s)
        $r = Invoke-KnxRequest -Socket $s -Frame $f -Ip $Ip -Port $Port -Expect @($script:KnxService.DESCRIPTION_RESPONSE) -TimeoutMs $TimeoutMs
        if ($r.TimedOut) { return $null }
        $dibs = Read-KnxDibs -Body $r.Header.Body
        $devInfo = $null; $fams = @(); $ext = $null
        foreach ($d in $dibs) {
            if ($d.Type -eq 0x01) { $devInfo = $d.Decoded }
            if ($d.Type -eq 0x02) { $fams = @($d.Decoded) }
            if ($d.Type -eq 0x08) { $ext = $d.Decoded }
        }
        return [pscustomobject]@{ Raw = $r.Packet.Bytes; Body = $r.Header.Body; Dibs = $dibs; Device = $devInfo; Families = $fams; Extended = $ext }
    }
    finally { $s.Dispose() }
}

$script:TrafficConnection = $null

function Get-KnxTrafficConnection {
    <#
    .SYNOPSIS
        Returns ONE shared tunnel on the traffic interface, opening it on first use.
    .DESCRIPTION
        Opening and closing a tunnel on the traffic interface once per test case exhausts it:
        a real interface does not free a channel the instant the client disconnects, so after
        a dozen cases every further open is answered E_NO_MORE_CONNECTIONS - and a dozen test
        cases fail for a reason that has nothing to do with the device under test.
        One connection, reused for the whole run, and closed by Close-KnxTrafficConnection.
        Returns $null when the interface cannot serve one.
    #>
    param([Parameter(Mandatory)][string]$Ip, [int]$Port = 3671, [int]$TimeoutMs = 3000)
    if ($null -ne $script:TrafficConnection) {
        $c = $script:TrafficConnection
        if ($null -ne $c.Socket -and $c.Ip -eq $Ip) {
            # Holding a socket is not proof the DEVICE still knows the channel: after its
            # 120 s reaper fires we would keep sending into a dead channel and every
            # "from KNX" case would fail for a reason that has nothing to do with the BDUT.
            # Ask the device, and only reuse what it still acknowledges.
            $probe = New-KnxConnectionStateRequest -Channel $c.Channel -ControlIp $c.LocalIp -ControlPort $c.LocalPort
            $r = Invoke-KnxRequest -Socket $c.Socket -Frame $probe -Ip $c.Ip -Port $c.Port `
                                   -Expect @($script:KnxService.CONNECTIONSTATE_RESPONSE) -TimeoutMs 1500
            if (-not $r.TimedOut -and $r.Header.Body.Length -ge 2 -and $r.Header.Body[1] -eq 0x00) {
                Clear-KnxSocket -Socket $c.Socket -QuietMs 50
                return $c
            }
            try { $c.Socket.Dispose() } catch { }
        }
        $script:TrafficConnection = $null
    }
    $conn = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $script:KnxConnType.TUNNEL_CONNECTION `
                               -Layer $script:KnxLayer.TUNNEL_LINKLAYER -TimeoutMs $TimeoutMs
    if (-not $conn.Ok) { return $null }
    $script:TrafficConnection = $conn
    return $conn
}

function Close-KnxTrafficConnection {
    <#
    .SYNOPSIS
        Releases the shared traffic connection at the end of a run.
    #>
    if ($null -eq $script:TrafficConnection) { return }
    [void](Close-KnxConnection -Connection $script:TrafficConnection)
    $script:TrafficConnection = $null
}

function Invoke-KnxLoadSwitch {
    <#
    .SYNOPSIS
        Drives the TSSH load switch: writes 1/0 to its group address over a tunnel.
    .DESCRIPTION
        TSSH section 1.2.2 requires a two-channel switch on GA 1/1/50 that disconnects both
        TP wires of the BDUT. The connecting interface must NOT be the BDUT - otherwise the
        test cuts its own path. The caller passes the traffic interface as -Via.
    .PARAMETER On
        $true reconnects the BDUT, $false disconnects it.
    #>
    param(
        [Parameter(Mandatory)][string]$Via,
        [Parameter(Mandatory)][bool]$On,
        [string]$GroupAddress = '1/1/50',
        [int]$Port = 3671,
        [int]$TimeoutMs = 3000
    )
    $conn = Get-KnxTrafficConnection -Ip $Via -Port $Port -TimeoutMs $TimeoutMs
    if ($null -eq $conn) { return [pscustomobject]@{ Ok = $false; Reason = "load switch: no tunnel available on $Via" } }
    try {
        $tpdu = New-TpduGroupValueWrite -Value ([int]$On)
        $cemi = New-CemiLData -MessageCode $script:Cemi.L_DATA_REQ -Destination (ConvertTo-KnxGa -Address $GroupAddress) -IsGroup -Tpdu $tpdu
        $r = Send-KnxTunnelCemi -Connection $conn -Cemi $cemi -TimeoutMs $TimeoutMs
        $reason = ''
        if ($r.Status -ne 0) { $reason = "load switch: tunnel ack status $($r.Status)" }
        return [pscustomobject]@{ Ok = ($r.Status -eq 0); Reason = $reason }
    }
    finally { }   # the shared connection stays open for the rest of the run
}

function Wait-KnxGone {
    <#
    .SYNOPSIS
        Waits until the endpoint stops answering, or reports failure after the timeout.
    #>
    param([Parameter(Mandatory)][string]$Ip, [int]$TimeoutMs = 15000, [int]$PollMs = 500)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Test-KnxAlive -Ip $Ip -TimeoutMs $PollMs)) { return $true }
        Start-Sleep -Milliseconds $PollMs
    }
    return $false
}

function Wait-KnxBack {
    <#
    .SYNOPSIS
        Waits until the endpoint answers again.
    #>
    param([Parameter(Mandatory)][string]$Ip, [int]$TimeoutMs = 60000, [int]$PollMs = 1000)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-KnxAlive -Ip $Ip -TimeoutMs $PollMs) { return $true }
        Start-Sleep -Milliseconds $PollMs
    }
    return $false
}

# ─── Result engine ──────────────────────────────────────────────────────────────

$script:Run = $null
$script:Evidence = $null

function Start-KnxTestRun {
    <#
    .SYNOPSIS
        Begins a test run and returns the run context that Export-KnxTestReport consumes.
    #>
    param(
        [Parameter(Mandatory)][string]$Product,
        [Parameter(Mandatory)][string]$BdutIp,
        [hashtable]$Environment = @{},
        [string]$RunProfile = 'Full'
    )
    $script:Run = [pscustomobject]@{
        Product     = $Product
        BdutIp      = $BdutIp
        Profile     = $RunProfile
        Environment = $Environment
        Started     = [DateTime]::Now
        Finished    = $null
        Results     = New-Object System.Collections.ArrayList
    }
    return $script:Run
}

function Add-KnxEvidence {
    <#
    .SYNOPSIS
        Attaches byte-level evidence to the running test case.
    .DESCRIPTION
        Call it before the assertion, not after - a throwing assert never returns, and
        evidence recorded afterwards would be lost exactly when it matters.
    #>
    param([byte[]]$Sent, [byte[]]$Expected, [byte[]]$Received, [string]$Note)
    if ($null -eq $script:Evidence) { return }
    if ($PSBoundParameters.ContainsKey('Sent'))     { $script:Evidence.Sent     = $Sent }
    if ($PSBoundParameters.ContainsKey('Expected')) { $script:Evidence.Expected = $Expected }
    if ($PSBoundParameters.ContainsKey('Received')) { $script:Evidence.Received = $Received }
    if ($PSBoundParameters.ContainsKey('Note') -and $Note) { [void]$script:Evidence.Notes.Add($Note) }
}

function Add-KnxExpectedLog {
    <#
    .SYNOPSIS
        Records what the DEVICE's own console is expected to print during this case.
    .DESCRIPTION
        The negative cases deliberately provoke log output: an ignored service, a rejected
        cEMI frame, a refused connection. Seeing that in the device console while a test is
        green is confusing unless the test says it is supposed to happen - so it says so,
        on the console and in the report.
    #>
    param([Parameter(Mandatory)][string]$Text)
    if ($null -eq $script:Evidence) { return }
    [void]$script:Evidence.Notes.Add("expected device log: $Text")
    Write-Host ("             device log expected: {0}" -f $Text) -ForegroundColor DarkGray
}

function Assert-KnxTrue {
    <#
    .SYNOPSIS
        Fails the current test case unless the condition holds.
    #>
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw "KNXTEST_FAIL::$Message" }
}

function Assert-KnxEqual {
    <#
    .SYNOPSIS
        Fails unless two scalars are equal, recording both values as evidence.
    #>
    param($Expected, $Actual, [Parameter(Mandatory)][string]$Message)
    if ($Expected -ne $Actual) {
        Add-KnxEvidence -Note "expected '$Expected', got '$Actual'"
        throw "KNXTEST_FAIL::$Message (expected '$Expected', got '$Actual')"
    }
}

function Assert-KnxBytes {
    <#
    .SYNOPSIS
        Fails unless two byte arrays are identical, recording both as evidence.
    #>
    param([byte[]]$Expected, [byte[]]$Actual, [Parameter(Mandatory)][string]$Message)
    $same = ($null -ne $Expected -and $null -ne $Actual -and $Expected.Length -eq $Actual.Length)
    if ($same) {
        for ($i = 0; $i -lt $Expected.Length; $i++) { if ($Expected[$i] -ne $Actual[$i]) { $same = $false; break } }
    }
    if (-not $same) {
        Add-KnxEvidence -Expected $Expected -Received $Actual
        throw "KNXTEST_FAIL::$Message"
    }
}

function Assert-KnxStatus {
    <#
    .SYNOPSIS
        Fails unless a KNXnet/IP status byte has the expected value, naming both codes.
    #>
    param([Parameter(Mandatory)][int]$Expected, [Parameter(Mandatory)][int]$Actual, [string]$Message = 'unexpected status code')
    if ($Expected -ne $Actual) {
        $e = Get-KnxErrorName -Status $Expected
        $a = Get-KnxErrorName -Status $Actual
        Add-KnxEvidence -Note "expected $e (0x$($Expected.ToString('X2'))), got $a (0x$($Actual.ToString('X2')))"
        throw "KNXTEST_FAIL::$Message - expected $e, got $a"
    }
}

function Set-KnxTestSkip {
    <#
    .SYNOPSIS
        Ends the current test case as SKIP with a mandatory reason.
    #>
    param([Parameter(Mandatory)][string]$Reason)
    throw "KNXTEST_SKIP::$Reason"
}

function Set-KnxTestNotApplicable {
    <#
    .SYNOPSIS
        Ends the current test case as N-A with a mandatory reason.
    #>
    param([Parameter(Mandatory)][string]$Reason)
    throw "KNXTEST_NA::$Reason"
}

function Invoke-KnxTestCase {
    <#
    .SYNOPSIS
        Runs one test case, captures its verdict and evidence, and records it in the run.
    .DESCRIPTION
        The body decides the verdict by what it throws: nothing = PASS, an Assert-* failure
        = FAIL, Set-KnxTestSkip = SKIP, Set-KnxTestNotApplicable = N-A. An unexpected
        exception is a FAIL with the exception text - a test harness must never swallow one.
    .PARAMETER Clause
        Spec reference, e.g. 'TSSH 5.3.5, p.88'. Mandatory: a test that cannot cite what it
        checks cannot be argued about, and an unarguable FAIL is worthless.
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Clause,
        [Parameter(Mandatory)][scriptblock]$Body,
        [string]$Suite = ''
    )
    if ($null -eq $script:Run) { throw 'Start-KnxTestRun must be called before Invoke-KnxTestCase' }

    $script:Evidence = [pscustomobject]@{
        Sent = $null; Expected = $null; Received = $null
        Notes = (New-Object System.Collections.ArrayList)
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $verdict = 'PASS'; $reason = ''
    try {
        & $Body
    }
    catch {
        $msg = "$($_.Exception.Message)"
        if     ($msg -like 'KNXTEST_SKIP::*') { $verdict = 'SKIP'; $reason = $msg.Substring(14) }
        elseif ($msg -like 'KNXTEST_NA::*')   { $verdict = 'N-A';  $reason = $msg.Substring(12) }
        elseif ($msg -like 'KNXTEST_FAIL::*') { $verdict = 'FAIL'; $reason = $msg.Substring(14) }
        else                                  { $verdict = 'FAIL'; $reason = "unhandled error: $msg" }
    }
    $sw.Stop()

    $evSent = ''; $evExpected = ''; $evReceived = ''
    if ($null -ne $script:Evidence.Sent)     { $evSent     = ConvertTo-HexString -Bytes $script:Evidence.Sent -MaxBytes 64 }
    if ($null -ne $script:Evidence.Expected) { $evExpected = ConvertTo-HexString -Bytes $script:Evidence.Expected -MaxBytes 64 }
    if ($null -ne $script:Evidence.Received) { $evReceived = ConvertTo-HexString -Bytes $script:Evidence.Received -MaxBytes 64 }

    $res = [pscustomobject]@{
        Id       = $Id
        Suite    = $Suite
        Title    = $Title
        Clause   = $Clause
        Result   = $verdict
        Reason   = $reason
        Ms       = [int]$sw.ElapsedMilliseconds
        Sent     = $evSent
        Expected = $evExpected
        Received = $evReceived
        Notes    = @($script:Evidence.Notes)
    }
    [void]$script:Run.Results.Add($res)
    Write-KnxResultLine -Case $res
    $script:Evidence = $null
    # Deliberately no return value: a suite calls this as a statement, and an emitted
    # object would be formatted onto the console after every single verdict line.
}

function Write-KnxResultLine {
    <#
    .SYNOPSIS
        Prints one aligned, colour-coded verdict line.
    #>
    param([Parameter(Mandatory)]$Case)
    $col = switch ($Case.Result) {
        'PASS' { 'Green' }
        'FAIL' { 'Red' }
        'SKIP' { 'Yellow' }
        'N-A'  { 'DarkGray' }
        default { 'Gray' }
    }
    $id = $Case.Id.PadRight(10)
    $vd = $Case.Result.PadRight(4)
    Write-Host ("  {0} {1} " -f $id, $vd) -ForegroundColor $col -NoNewline
    Write-Host $Case.Title -ForegroundColor Gray -NoNewline
    if ($Case.Reason) { Write-Host ("  -- " + $Case.Reason) -ForegroundColor $col } else { Write-Host '' }
}

function Get-KnxRunSummary {
    <#
    .SYNOPSIS
        Counts verdicts of the current run.
    #>
    param($Run = $null)
    if ($null -eq $Run) { $Run = $script:Run }
    $c = @{ PASS = 0; FAIL = 0; SKIP = 0; 'N-A' = 0 }
    foreach ($r in $Run.Results) { $c[$r.Result] = $c[$r.Result] + 1 }
    return [pscustomobject]@{
        Total = $Run.Results.Count
        Pass  = $c.PASS
        Fail  = $c.FAIL
        Skip  = $c.SKIP
        NA    = $c.'N-A'
    }
}

function Export-KnxTestReport {
    <#
    .SYNOPSIS
        Writes the Markdown and JSON report of a run and returns both paths.
    .DESCRIPTION
        The JSON is what makes run-over-run regression comparison possible; the Markdown
        is what a certification reviewer reads. Both carry the clause reference per case.
    #>
    param($Run = $null, [Parameter(Mandatory)][string]$Directory)
    if ($null -eq $Run) { $Run = $script:Run }
    if ($null -eq $Run) { throw 'no run to export' }
    $Run.Finished = [DateTime]::Now
    if (-not (Test-Path $Directory)) { [void](New-Item -ItemType Directory -Path $Directory -Force) }

    $stamp = $Run.Started.ToString('yyyyMMdd-HHmmss')
    $base = Join-Path $Directory ("{0}_{1}" -f $Run.Product, $stamp)
    $sum = Get-KnxRunSummary -Run $Run

    $md = New-Object System.Text.StringBuilder
    [void]$md.AppendLine("# Test report - $($Run.Product)")
    [void]$md.AppendLine('')
    [void]$md.AppendLine("Run started: $($Run.Started.ToString('yyyy-MM-dd HH:mm:ss'))  ")
    [void]$md.AppendLine("Run finished: $($Run.Finished.ToString('yyyy-MM-dd HH:mm:ss'))  ")
    [void]$md.AppendLine("Device under test: $($Run.BdutIp)  |  profile: $($Run.Profile)")
    [void]$md.AppendLine('')
    [void]$md.AppendLine('## Test setup')
    [void]$md.AppendLine('')
    [void]$md.AppendLine('| Key | Value |')
    [void]$md.AppendLine('|---|---|')
    foreach ($k in ($Run.Environment.Keys | Sort-Object)) {
        [void]$md.AppendLine("| $k | $($Run.Environment[$k]) |")
    }
    [void]$md.AppendLine('')
    [void]$md.AppendLine('## Summary')
    [void]$md.AppendLine('')
    [void]$md.AppendLine('| Total | PASS | FAIL | SKIP | N-A |')
    [void]$md.AppendLine('|---|---|---|---|---|')
    [void]$md.AppendLine("| $($sum.Total) | $($sum.Pass) | $($sum.Fail) | $($sum.Skip) | $($sum.NA) |")
    [void]$md.AppendLine('')
    # Anyone reading this report for the first time needs to know what the four words mean
    # before the tables make sense - above all that SKIP and N-A are not softer failures.
    [void]$md.AppendLine('PASS - the device did what the specification requires.  ')
    [void]$md.AppendLine('FAIL - it did not. The reason and the bytes are further down.  ')
    [void]$md.AppendLine('SKIP - the test did not run, and why. Says nothing about the device.  ')
    [void]$md.AppendLine('N-A - the requirement does not apply to this device, and why.')
    [void]$md.AppendLine('')

    $suites = $Run.Results | Group-Object -Property Suite
    foreach ($s in $suites) {
        [void]$md.AppendLine("## $($s.Name)")
        [void]$md.AppendLine('')
        [void]$md.AppendLine('| ID | Result | Test case | Specification | Reason | ms |')
        [void]$md.AppendLine('|---|---|---|---|---|---|')
        foreach ($r in $s.Group) {
            $reason = ($r.Reason -replace '\|', '\|')
            [void]$md.AppendLine("| ``$($r.Id)`` | **$($r.Result)** | $($r.Title) | $($r.Clause) | $reason | $($r.Ms) |")
        }
        [void]$md.AppendLine('')
    }

    $fails = @($Run.Results | Where-Object { $_.Result -eq 'FAIL' })
    if ($fails.Count -gt 0) {
        [void]$md.AppendLine('## What failed, and the evidence for it')
        [void]$md.AppendLine('')
        foreach ($r in $fails) {
            [void]$md.AppendLine("### $($r.Id) - $($r.Title)")
            [void]$md.AppendLine('')
            [void]$md.AppendLine("* Specification: $($r.Clause)")
            [void]$md.AppendLine("* Reason: $($r.Reason)")
            if ($r.Sent)     { [void]$md.AppendLine("* Sent: ``$($r.Sent)``") }
            if ($r.Expected) { [void]$md.AppendLine("* Expected: ``$($r.Expected)``") }
            if ($r.Received) { [void]$md.AppendLine("* Received: ``$($r.Received)``") }
            foreach ($n in $r.Notes) { [void]$md.AppendLine("* Note: $n") }
            [void]$md.AppendLine('')
        }
    }

    $mdPath = "$base.md"
    $jsonPath = "$base.json"
    [System.IO.File]::WriteAllText($mdPath, $md.ToString())

    $payload = [pscustomobject]@{
        product     = $Run.Product
        bdut        = $Run.BdutIp
        profile     = $Run.Profile
        started     = $Run.Started.ToString('o')
        finished    = $Run.Finished.ToString('o')
        environment = $Run.Environment
        summary     = $sum
        results     = @($Run.Results)
    }
    $payload | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonPath -Encoding UTF8

    return [pscustomobject]@{ Markdown = $mdPath; Json = $jsonPath; Summary = $sum }
}

# ─── Self-test ──────────────────────────────────────────────────────────────────

function Test-KnxPropertyIdsAgainstSource {
    <#
    .SYNOPSIS
        Verifies every property id in this library against the knx stack's property.h.
    .DESCRIPTION
        This exists because of a measured failure mode, not a hypothetical one: on
        2026-08-15 four property ids in this file were taken from the KNX prufvorschrift
        instead of from the implementation, and each produced a false device finding -
        one of them nearly rewrote the device's IP assignment method. PID_PROG_MODE is on
        the DEVICE object, not the KNXnet/IP one; ADDITIONAL_INDIVIDUAL_ADDRESSES is 53 not
        55; MSG_TRANSMIT_TO_IP/KNX are 74/75 not 71/72.

        The specification numbers a property inside a clause; the implementation numbers it
        inside an enum. Where they differ, the implementation is what the device answers to.
        So this check reads property.h and reports any constant here that no PID of the same
        name carries. Returns the mismatches; empty means the tables agree.
    #>
    param([string]$PropertyHeaderPath = '')
    if (-not $PropertyHeaderPath) {
        # lib/knx is a symlink into the shared knx repo; walk up from this module.
        $here = Split-Path -Parent $PSCommandPath
        foreach ($cand in @(
                (Join-Path $here '../../../lib/knx/src/knx/property.h'),
                (Join-Path $here '../../../../knx/src/knx/property.h'),
                (Join-Path $here '../../lib/knx/src/knx/property.h'),
                (Join-Path $here '../../../knx/src/knx/property.h'))) {
            if (Test-Path $cand) { $PropertyHeaderPath = (Resolve-Path $cand).Path; break }
        }
    }
    if (-not $PropertyHeaderPath -or -not (Test-Path $PropertyHeaderPath)) {
        return , @([pscustomobject]@{ Name = '(property.h)'; Mine = -1; Note = 'not found - cannot verify property ids against the implementation' })
    }

    $byName = @{}
    foreach ($line in (Get-Content -Path $PropertyHeaderPath)) {
        if ($line -match '^\s*(PID_\w+)\s*=\s*(\d+)') { 
            $n = $Matches[1] -replace '^PID_', ''
            if (-not $byName.ContainsKey($n)) { $byName[$n] = @() }
            $byName[$n] += [int]$Matches[2]
        }
    }

    $bad = @()
    foreach ($k in $script:KnxPid.Keys) {
        $mine = $script:KnxPid[$k]
        if (-not $byName.ContainsKey($k)) { continue }   # local alias, no PID of that name
        if ($byName[$k] -notcontains $mine) {
            $bad += [pscustomobject]@{ Name = $k; Mine = $mine; Note = "property.h says $($byName[$k] -join '/')" }
        }
    }
    return , $bad
}

function Invoke-KnxSelfTest {
    <#
    .SYNOPSIS
        Verifies every frame builder against known-good byte vectors, without hardware.
    .DESCRIPTION
        A suite that builds wrong frames produces wrong verdicts, and a wrong PASS is worse
        than no test at all. This must be green before any device result counts.
        Includes a negative control proving the comparison can actually fail.
    #>
    param([switch]$Quiet)
    $cases = New-Object System.Collections.ArrayList
    function Add-Vector([string]$name, [byte[]]$actual, [string]$expectedHex) {
        $exp = ($expectedHex -replace '\s', '')
        $act = (ConvertTo-HexString -Bytes $actual) -replace ' ', ''
        [void]$cases.Add([pscustomobject]@{ Name = $name; Ok = ($act -eq $exp); Expected = $exp; Actual = $act })
    }

    # Core -------------------------------------------------------------------
    Add-Vector 'SEARCH_REQUEST 192.168.1.10:3671' `
        (New-KnxSearchRequest -DiscoveryIp '192.168.1.10' -DiscoveryPort 3671) `
        '06100201000E 0801C0A8010A0E57'

    Add-Vector 'DESCRIPTION_REQUEST 192.168.1.10:3671' `
        (New-KnxDescriptionRequest -ControlIp '192.168.1.10' -ControlPort 3671) `
        '06100203000E 0801C0A8010A0E57'

    Add-Vector 'CONNECT_REQUEST tunnel link layer' `
        (New-KnxConnectRequest -ControlIp '192.168.1.10' -ControlPort 3671 -DataIp '192.168.1.10' -DataPort 3671 -ConnectionType 0x04 -Layer 0x02) `
        '06100205001A 0801C0A8010A0E57 0801C0A8010A0E57 04040200'

    Add-Vector 'CONNECT_REQUEST tunnel busmonitor' `
        (New-KnxConnectRequest -ControlIp '192.168.1.10' -ControlPort 3671 -DataIp '192.168.1.10' -DataPort 3671 -ConnectionType 0x04 -Layer 0x80) `
        '06100205001A 0801C0A8010A0E57 0801C0A8010A0E57 04048000'

    Add-Vector 'CONNECT_REQUEST device management' `
        (New-KnxConnectRequest -ControlIp '192.168.1.10' -ControlPort 3671 -DataIp '192.168.1.10' -DataPort 3671 -ConnectionType 0x03 -Layer -1) `
        '061002050018 0801C0A8010A0E57 0801C0A8010A0E57 0203'

    Add-Vector 'CONNECT_REQUEST NAT (route back)' `
        (New-KnxConnectRequest -ControlIp '0.0.0.0' -ControlPort 0 -DataIp '0.0.0.0' -DataPort 0 -ConnectionType 0x04 -Layer 0x02) `
        '06100205001A 080100000000 0000 0801000000000000 04040200'

    Add-Vector 'CONNECTIONSTATE_REQUEST channel 0x15' `
        (New-KnxConnectionStateRequest -Channel 0x15 -ControlIp '192.168.1.10' -ControlPort 3671) `
        '061002070010 1500 0801C0A8010A0E57'

    Add-Vector 'DISCONNECT_REQUEST channel 0x15' `
        (New-KnxDisconnectRequest -Channel 0x15 -ControlIp '192.168.1.10' -ControlPort 3671) `
        '061002090010 1500 0801C0A8010A0E57'

    # Malformed-frame overrides ----------------------------------------------
    Add-Vector 'SEARCH_REQUEST invalid version 0x11' `
        (New-KnxSearchRequest -DiscoveryIp '192.168.1.10' -DiscoveryPort 3671 -Version 0x11) `
        '06110201000E 0801C0A8010A0E57'

    Add-Vector 'SEARCH_REQUEST invalid header size 0x07' `
        (New-KnxSearchRequest -DiscoveryIp '192.168.1.10' -DiscoveryPort 3671 -HeaderSize 0x07) `
        '07100201000E 0801C0A8010A0E57'

    Add-Vector 'frame with declared length override' `
        (New-KnxFrame -Service 0x0201 -Body ([byte[]]@(0x01, 0x02)) -TotalLength 0x00FF) `
        '0610020100FF 0102'

    # Tunnelling --------------------------------------------------------------
    $cemiWrite = New-CemiLData -MessageCode 0x11 -Destination (ConvertTo-KnxGa -Address '1/2/3') -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)
    Add-Vector 'cEMI L_Data.req GroupValueWrite 1/2/3 = 1' `
        $cemiWrite `
        '1100 BCE0 0000 0A03 01 0081'

    Add-Vector 'TUNNELLING_REQUEST ch 0x15 seq 0' `
        (New-KnxTunnellingRequest -Channel 0x15 -Sequence 0 -Cemi $cemiWrite) `
        '061004200015 04150000 1100BCE000000A03010081'

    Add-Vector 'TUNNELLING_ACK ch 0x15 seq 3' `
        (New-KnxTunnellingAck -Channel 0x15 -Sequence 3) `
        '06100421000A 04150300'

    Add-Vector 'cEMI L_Data.req to individual address 1.1.50' `
        (New-CemiLData -MessageCode 0x11 -Destination (ConvertTo-KnxPa -Address '1.1.50') -Tpdu (New-TpduConnect)) `
        '1100 BC60 0000 1132 00 80'

    # Device management -------------------------------------------------------
    Add-Vector 'cEMI M_PropRead.req OT 0 PID 1' `
        (New-CemiMPropRead -ObjectType 0 -ObjectInstance 1 -PropertyId 1) `
        'FC 0000 01 01 10 01'

    # Element count is 4 bits: 15 is the maximum, so the 16 tunnel addresses need two reads.
    Add-Vector 'cEMI M_PropRead.req OT 11 PID 55 elem 15 start 1' `
        (New-CemiMPropRead -ObjectType 11 -ObjectInstance 1 -PropertyId 55 -ElementCount 15 -StartIndex 1) `
        'FC 000B 01 37 F0 01'

    Add-Vector 'cEMI M_PropRead.req OT 11 PID 55 elem 1 start 16' `
        (New-CemiMPropRead -ObjectType 11 -ObjectInstance 1 -PropertyId 55 -ElementCount 1 -StartIndex 16) `
        'FC 000B 01 37 10 10'

    Add-Vector 'cEMI M_PropWrite.req OT 0 PID 14 data 00' `
        (New-CemiMPropWrite -ObjectType 0 -ObjectInstance 1 -PropertyId 14 -Data ([byte[]]@(0x00))) `
        'F6 0000 01 0E 10 01 00'

    Add-Vector 'DEVICE_CONFIGURATION_REQUEST ch 0x15 seq 0' `
        (New-KnxDeviceConfigurationRequest -Channel 0x15 -Sequence 0 -Cemi (New-CemiMPropRead -ObjectType 0 -PropertyId 1)) `
        '061003100011 04150000 FC000001011001'

    Add-Vector 'DEVICE_CONFIGURATION_ACK ch 0x15 seq 0' `
        (New-KnxDeviceConfigurationAck -Channel 0x15 -Sequence 0) `
        '06100311000A 04150000'

    Add-Vector 'cEMI M_Reset.req' (New-CemiMReset) 'F1'

    # cEMI transport layer - the four vectors are copied verbatim from the TSSH
    # section 4.3 frame tables (pages 42-51), so a wrong encoding cannot slip through.
    Add-Vector 'cEMI T_Data_Individual.req A_PropertyValue_Read (TSSH 4.3.1)' `
        (New-CemiTransport -MessageCode 0x4A -Tpdu (New-TpduPropertyValueRead -ObjectIndex 0 -PropertyId 1 -ElementCount 1 -StartIndex 1)) `
        '4A 00 000000000000 05 03D5 00 01 10 01'

    Add-Vector 'cEMI T_Data_Individual.ind A_PropertyValue_Response (TSSH 4.3.2)' `
        (New-CemiTransport -MessageCode 0x94 -Tpdu (New-TpduPropertyValueResponse -ObjectIndex 0 -PropertyId 1 -ElementCount 1 -StartIndex 1 -Data ([byte[]]@(0x00, 0x00)))) `
        '94 00 000000000000 07 03D6 00 01 10 01 0000'

    Add-Vector 'cEMI T_Data_Connected.req A_PropertyValue_Read (TSSH 4.3.3)' `
        (New-CemiTransport -MessageCode 0x41 -Tpdu (New-TpduPropertyValueRead -ObjectIndex 0 -PropertyId 1 -ElementCount 1 -StartIndex 1)) `
        '41 00 000000000000 05 03D5 00 01 10 01'

    Add-Vector 'cEMI T_Data_Connected.ind A_PropertyValue_Response (TSSH 4.3.4)' `
        (New-CemiTransport -MessageCode 0x89 -Tpdu (New-TpduPropertyValueResponse -ObjectIndex 0 -PropertyId 1 -ElementCount 1 -StartIndex 1 -Data ([byte[]]@(0x00, 0x00)))) `
        '89 00 000000000000 07 03D6 00 01 10 01 0000'

    # Full DEVICE_CONFIGURATION_REQUEST lengths from the same tables: 0x0019 and 0x001B.
    $dc1 = New-KnxDeviceConfigurationRequest -Channel 0 -Sequence 0 -Cemi (New-CemiTransport -MessageCode 0x4A -Tpdu (New-TpduPropertyValueRead))
    [void]$cases.Add([pscustomobject]@{ Name = 'DEVICE_CONFIGURATION_REQUEST T_Data_Individual.req total length 0x0019'; Ok = ($dc1.Length -eq 0x19); Expected = '25'; Actual = "$($dc1.Length)" })
    $dc2 = New-KnxDeviceConfigurationRequest -Channel 0 -Sequence 0 -Cemi (New-CemiTransport -MessageCode 0x94 -Tpdu (New-TpduPropertyValueResponse))
    [void]$cases.Add([pscustomobject]@{ Name = 'DEVICE_CONFIGURATION_REQUEST T_Data_Individual.ind total length 0x001B'; Ok = ($dc2.Length -eq 0x1B); Expected = '27'; Actual = "$($dc2.Length)" })

    # A_Memory_Read/Write, matching the TSSH 4.2.6 bus trace (46 01 00 60 / 4A 81 00 60 00).
    Add-Vector 'TPDU A_Memory_Read 1 octet at 0x0060, seq 1' `
        (New-TpduMemoryRead -Address 0x0060 -Count 1 -Sequence 1) `
        '46 01 0060'

    Add-Vector 'TPDU A_Memory_Write 1 octet at 0x0060, seq 2' `
        (New-TpduMemoryWrite -Address 0x0060 -Data ([byte[]]@(0x00)) -Sequence 2) `
        '4A 81 0060 00'

    [void]$cases.Add([pscustomobject]@{ Name = 'APCI extractor reads A_PropertyValue_Read (0x3D5)'; Ok = ((Get-TpduApci -Tpdu (New-TpduPropertyValueRead)) -eq 0x3D5); Expected = '3D5'; Actual = ('{0:X3}' -f (Get-TpduApci -Tpdu (New-TpduPropertyValueRead))) })
    [void]$cases.Add([pscustomobject]@{ Name = 'APCI extractor reads A_PropertyValue_Response (0x3D6)'; Ok = ((Get-TpduApci -Tpdu (New-TpduPropertyValueResponse)) -eq 0x3D6); Expected = '3D6'; Actual = ('{0:X3}' -f (Get-TpduApci -Tpdu (New-TpduPropertyValueResponse))) })

    # Routing -----------------------------------------------------------------
    Add-Vector 'ROUTING_INDICATION GroupValueWrite 1/2/3 = 1' `
        (New-KnxRoutingIndication -Cemi $cemiWrite) `
        '061005300011 1100BCE000000A03010081'

    # Remote diagnosis --------------------------------------------------------
    Add-Vector 'REMOTE_DIAGNOSTIC_REQUEST progmode selector' `
        (New-KnxRemoteDiagnosticRequest -DiscoveryIp '192.168.1.10' -DiscoveryPort 3671 -Selector (New-KnxProgModeSelector)) `
        '061007400010 0801C0A8010A0E57 0201'

    Add-Vector 'REMOTE_DIAGNOSTIC_REQUEST MAC selector' `
        (New-KnxRemoteDiagnosticRequest -DiscoveryIp '192.168.1.10' -DiscoveryPort 3671 -Selector (New-KnxMacSelector -Mac ([byte[]]@(0x00,0x11,0x22,0x33,0x44,0x55)))) `
        '061007400016 0801C0A8010A0E57 0802 001122334455'

    # Address conversion ------------------------------------------------------
    [void]$cases.Add([pscustomobject]@{ Name = 'GA 1/2/3 -> 0x0A03'; Ok = ((ConvertTo-KnxGa -Address '1/2/3') -eq 0x0A03); Expected = '0A03'; Actual = ('{0:X4}' -f (ConvertTo-KnxGa -Address '1/2/3')) })
    [void]$cases.Add([pscustomobject]@{ Name = 'GA 31/7/255 -> 0xFFFF'; Ok = ((ConvertTo-KnxGa -Address '31/7/255') -eq 0xFFFF); Expected = 'FFFF'; Actual = ('{0:X4}' -f (ConvertTo-KnxGa -Address '31/7/255')) })
    [void]$cases.Add([pscustomobject]@{ Name = 'PA 1.1.50 -> 0x1132'; Ok = ((ConvertTo-KnxPa -Address '1.1.50') -eq 0x1132); Expected = '1132'; Actual = ('{0:X4}' -f (ConvertTo-KnxPa -Address '1.1.50')) })
    [void]$cases.Add([pscustomobject]@{ Name = 'PA 5.0.9 round trip'; Ok = ((ConvertFrom-KnxPa -Raw (ConvertTo-KnxPa -Address '5.0.9')) -eq '5.0.9'); Expected = '5.0.9'; Actual = (ConvertFrom-KnxPa -Raw (ConvertTo-KnxPa -Address '5.0.9')) })
    [void]$cases.Add([pscustomobject]@{ Name = 'GA 1/2/3 round trip'; Ok = ((ConvertFrom-KnxGa -Raw (ConvertTo-KnxGa -Address '1/2/3')) -eq '1/2/3'); Expected = '1/2/3'; Actual = (ConvertFrom-KnxGa -Raw (ConvertTo-KnxGa -Address '1/2/3')) })

    # TP1 FCS ------------------------------------------------------------------
    # FCS = 0xFF XOR (XOR of all preceding octets) - 03_02_02 section 2.2.4.6.
    $lp = [byte[]]@(0xBC, 0x11, 0x32, 0x0A, 0x03, 0xE1, 0x00, 0x81)
    $fcs = Get-Tp1Fcs -Bytes $lp
    $full = [byte[]]($lp + $fcs)
    [void]$cases.Add([pscustomobject]@{ Name = 'TP1 FCS recomputes and validates'; Ok = (Test-Tp1Fcs -Lpdu $full); Expected = 'valid'; Actual = ('{0:X2}' -f $fcs) })
    $bad = [byte[]]($lp + ([byte](($fcs + 1) -band 0xFF)))
    [void]$cases.Add([pscustomobject]@{ Name = 'TP1 FCS rejects a wrong check octet'; Ok = (-not (Test-Tp1Fcs -Lpdu $bad)); Expected = 'rejected'; Actual = 'rejected' })
    [void]$cases.Add([pscustomobject]@{ Name = 'TP1 standard frame length = 8 + LG'; Ok = ((Get-Tp1FrameLength -Bytes $full) -eq 9); Expected = '9'; Actual = "$(Get-Tp1FrameLength -Bytes $full)" })

    # Parsers ------------------------------------------------------------------
    $hdr = Read-KnxHeader -Frame (New-KnxSearchRequest -DiscoveryIp '192.168.1.10' -DiscoveryPort 3671)
    [void]$cases.Add([pscustomobject]@{ Name = 'header parser accepts a well-formed frame'; Ok = ($hdr.WellFormed -and $hdr.Service -eq 0x0201); Expected = 'well formed'; Actual = "$($hdr.WellFormed)/$('{0:X4}' -f $hdr.Service)" })
    $badHdr = Read-KnxHeader -Frame ([byte[]]@(0x06, 0x10, 0x02, 0x01, 0x00, 0xFF))
    [void]$cases.Add([pscustomobject]@{ Name = 'header parser flags a length mismatch'; Ok = (-not $badHdr.WellFormed); Expected = 'not well formed'; Actual = "$($badHdr.WellFormed)" })

    # Supported Service Families DIB: CORE 2, DEVMGMT 2, TUNNELLING 2 (no ROUTING).
    $svcDib = [byte[]]@(0x08, 0x02, 0x02, 0x02, 0x03, 0x02, 0x04, 0x02)
    [void]$cases.Add([pscustomobject]@{ Name = 'service family DIB decodes TUNNELLING'; Ok = (Test-KnxFamilySupported -Body $svcDib -Family 0x04); Expected = 'true'; Actual = "$(Test-KnxFamilySupported -Body $svcDib -Family 0x04)" })
    [void]$cases.Add([pscustomobject]@{ Name = 'service family DIB reports no ROUTING'; Ok = (-not (Test-KnxFamilySupported -Body $svcDib -Family 0x05)); Expected = 'false'; Actual = "$(Test-KnxFamilySupported -Body $svcDib -Family 0x05)" })

    # A CONNECT_RESPONSE error frame is only 2 octets - the parser must not index past it.
    $errRsp = Read-KnxConnectResponse -Body ([byte[]]@(0x00, 0x24))
    [void]$cases.Add([pscustomobject]@{ Name = 'short CONNECT_RESPONSE error parses without over-read'; Ok = ($errRsp.IsError -and $errRsp.Status -eq 0x24 -and $errRsp.StatusName -eq 'E_NO_MORE_CONNECTIONS'); Expected = 'E_NO_MORE_CONNECTIONS'; Actual = "$($errRsp.StatusName)" })

    $okRsp = Read-KnxConnectResponse -Body ([byte[]]@(0x15, 0x00, 0x08, 0x01, 0xC0, 0xA8, 0x01, 0x64, 0x0E, 0x57, 0x04, 0x04, 0x11, 0x33))
    [void]$cases.Add([pscustomobject]@{ Name = 'CONNECT_RESPONSE yields the tunnel individual address'; Ok = ($okRsp.TunnelPa -eq '1.1.51'); Expected = '1.1.51'; Actual = "$($okRsp.TunnelPa)" })

    $ld = Read-CemiLData -Cemi $cemiWrite
    [void]$cases.Add([pscustomobject]@{ Name = 'L_Data parser round-trips destination + TPDU'; Ok = ($ld.Destination -eq 0x0A03 -and $ld.IsGroup -and $ld.Tpdu.Length -eq 2); Expected = '0A03/group/2'; Actual = "$('{0:X4}' -f $ld.Destination)/$($ld.IsGroup)/$($ld.Tpdu.Length)" })

    # L_Busmon.ind with AddIL 7: 03h status block + 04h timestamp block, then the LPDU.
    $bm = [byte[]]@(0x2B, 0x07, 0x03, 0x01, 0x05, 0x04, 0x02, 0x12, 0x34) + $full
    $bmp = Read-CemiBusmon -Cemi $bm
    [void]$cases.Add([pscustomobject]@{ Name = 'L_Busmon parser honours a variable AddIL'; Ok = ($bmp.AddIL -eq 7 -and $bmp.Lpdu.Length -eq $full.Length -and $bmp.Sequence -eq 5 -and -not $bmp.Lost -and $bmp.FcsOk); Expected = 'AddIL 7, seq 5, FCS ok'; Actual = "AddIL $($bmp.AddIL), seq $($bmp.Sequence), FCS $($bmp.FcsOk)" })

    $pc = Read-CemiMPropCon -Cemi ([byte[]]@(0xFB, 0x00, 0x00, 0x01, 0x01, 0x00, 0x01, 0x07))
    [void]$cases.Add([pscustomobject]@{ Name = 'M_PropRead.con error (element count 0) is detected'; Ok = ($pc.IsError -and $pc.ErrorCode -eq 0x07); Expected = 'error 0x07'; Actual = "error $($pc.IsError)/0x$('{0:X2}' -f $pc.ErrorCode)" })

    # Property ids against the implementation - see Test-KnxPropertyIdsAgainstSource for why.
    $propBad = Test-KnxPropertyIdsAgainstSource
    if ($propBad.Count -eq 0) {
        [void]$cases.Add([pscustomobject]@{ Name = 'property ids match knx/src/knx/property.h'; Ok = $true; Expected = 'no drift'; Actual = 'no drift' })
    }
    else {
        foreach ($b in $propBad) {
            [void]$cases.Add([pscustomobject]@{ Name = "property id drift: $($b.Name)"; Ok = $false; Expected = $b.Note; Actual = "this library uses $($b.Mine)" })
        }
    }

    # Negative control: the comparison must be able to fail.
    [void]$cases.Add([pscustomobject]@{ Name = 'negative control (deliberate mismatch is detected)'; Ok = ((ConvertTo-HexString -Bytes ([byte[]]@(0x01))) -ne (ConvertTo-HexString -Bytes ([byte[]]@(0x02)))); Expected = 'mismatch detected'; Actual = 'mismatch detected' })

    # The serial helpers ship their own offline checks. Run them here so one -SelfTest
    # covers everything a run depends on - they caught a wrapped array and a strict-mode
    # crash on Windows PowerShell that no amount of reading had.
    try {
        $serialModule = Join-Path (Split-Path -Parent $PSCommandPath) 'KnxSerial.psm1'
        if (Test-Path $serialModule) {
            Import-Module $serialModule -Force -ErrorAction Stop
            foreach ($c in (Invoke-KnxSerialSelfTest -Quiet).Cases) {
                [void]$cases.Add([pscustomobject]@{ Name = "serial: $($c.Name)"; Ok = $c.Ok; Expected = 'ok'; Actual = $(if ($c.Ok) { 'ok' } else { $c.Detail }) })
            }
        }
    }
    catch {
        [void]$cases.Add([pscustomobject]@{ Name = 'serial helpers load'; Ok = $false; Expected = 'module loads'; Actual = "$($_.Exception.Message)" })
    }

    $failed = @($cases | Where-Object { -not $_.Ok })
    if (-not $Quiet) {
        Write-Host ''
        Write-Host '  Self-test - offline frame vectors' -ForegroundColor Cyan
        foreach ($c in $cases) {
            if ($c.Ok) {
                Write-Host ('    PASS  ' + $c.Name) -ForegroundColor Green
            }
            else {
                Write-Host ('    FAIL  ' + $c.Name) -ForegroundColor Red
                Write-Host ('          expected ' + $c.Expected) -ForegroundColor DarkGray
                Write-Host ('          actual   ' + $c.Actual) -ForegroundColor DarkGray
            }
        }
        Write-Host ''
        $col = if ($failed.Count -eq 0) { 'Green' } else { 'Red' }
        Write-Host ("  {0}/{1} checks passed" -f ($cases.Count - $failed.Count), $cases.Count) -ForegroundColor $col
        Write-Host ''
    }
    return [pscustomobject]@{ Total = $cases.Count; Failed = $failed.Count; Ok = ($failed.Count -eq 0); Cases = @($cases) }
}

Export-ModuleMember -Function *-* -Variable @()
