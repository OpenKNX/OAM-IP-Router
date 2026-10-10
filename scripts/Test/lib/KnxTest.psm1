#!/usr/bin/env pwsh
# Open ■
# ┬────┴  KnxTest
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/KnxTest.psm1

<#
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
      * A result engine: PASS / FAIL / SKIP / N-A, byte-level evidence on failure,
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
    ROUTING_SYSTEM_BROADCAST          = 0x0533   # 03_02_06 4.1.3, always on the system setup group
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
    E_AUTHORISATION_ERROR         = 0x28
    E_TUNNELING_LAYER             = 0x29
    E_NO_TUNNELLING_ADDRESS       = 0x2D
    E_CONNECTION_IN_USE           = 0x2E
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
    # Extended and user services, same source: the stack's ApduType enum. These are the System B
    # surface a plain TP device exposes alongside the classic services.
    PROPERTY_EXT_VALUE_READ          = 0x1CC
    PROPERTY_EXT_VALUE_RESPONSE      = 0x1CD
    PROPERTY_EXT_VALUE_WRITE_CON     = 0x1CE
    PROPERTY_EXT_VALUE_WRITE_CON_RES = 0x1CF
    PROPERTY_EXT_DESCRIPTION_READ     = 0x1D2
    PROPERTY_EXT_DESCRIPTION_RESPONSE = 0x1D3
    MEMORY_EXT_WRITE          = 0x1FB
    MEMORY_EXT_WRITE_RESPONSE = 0x1FC
    MEMORY_EXT_READ           = 0x1FD
    MEMORY_EXT_READ_RESPONSE  = 0x1FE
    USER_MANUFACTURER_INFO_READ     = 0x2C5
    USER_MANUFACTURER_INFO_RESPONSE = 0x2C6
    FUNCTION_PROPERTY_COMMAND        = 0x2C7
    FUNCTION_PROPERTY_STATE          = 0x2C8
    FUNCTION_PROPERTY_STATE_RESPONSE = 0x2C9
    IND_ADDR_SERIAL_READ     = 0x3DC
    IND_ADDR_SERIAL_RESPONSE = 0x3DD
    RESTART_MASTER_RESET = 0x381
    # The master reset answer reuses the Restart code and marks itself in the APCI octet:
    # data[0] |= (1 << 5) | 1 (application_layer.cpp restartResponse), so the code on the wire is 3A1h.
    RESTART_RESPONSE = 0x3A1
    USER_MEMORY_READ     = 0x2C0
    USER_MEMORY_RESPONSE = 0x2C1
    SYSTEM_NETWORK_PARAM_READ     = 0x1C8
    SYSTEM_NETWORK_PARAM_RESPONSE = 0x1C9
    AUTHORIZE_REQUEST  = 0x3D1
    AUTHORIZE_RESPONSE = 0x3D2
    ADC_READ     = 0x180
    ADC_RESPONSE = 0x1C0
    ROUTING_TABLE_READ          = 0x3C1
    ROUTING_TABLE_READ_RESPONSE = 0x3C2
    ROUTING_TABLE_OPEN  = 0x3C0
    ROUTING_TABLE_WRITE = 0x3C3
    MEMORY_ROUTER_WRITE = 0x3CA
    USER_MEMORY_WRITE   = 0x2C2
    KEY_WRITE           = 0x3D3
    KEY_RESPONSE        = 0x3D4
    IND_ADDR_SERIAL_WRITE = 0x3DE
    PROPERTY_EXT_VALUE_WRITE_UNCON = 0x1D0
    FUNCTION_PROPERTY_EXT_COMMAND        = 0x1D4
    FUNCTION_PROPERTY_EXT_STATE          = 0x1D5
    FUNCTION_PROPERTY_EXT_STATE_RESPONSE = 0x1D6
    DOMAIN_ADDR_SERIAL_READ     = 0x3EC
    DOMAIN_ADDR_SERIAL_RESPONSE = 0x3ED
    DOMAIN_ADDR_SERIAL_WRITE    = 0x3EE
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
    TABLE                          = 23   # PID_TABLE on the address/association table objects (lib/knx property.h:85)
    ROUTING_COUNT                  = 51
    MAX_APDU_LENGTH                = 56
    SUBNET_ADDR                    = 57
    DEVICE_ADDR                    = 58
    PROJECT_INSTALLATION_ID        = 51
    KNX_INDIVIDUAL_ADDRESS         = 52
    # 53, verified against knx/src/knx/property.h - 55 is PID_IP_ASSIGNMENT_METHOD.
    ADDITIONAL_INDIVIDUAL_ADDRESSES = 53
    # 201/202 are OpenKNX properties (PID >= 200), not in the standard: which tunnel slot is reserved
    # for which client IP. Numbers from knx/src/knx/property.h.
    CUSTOM_RESERVED_TUNNELS_CTRL   = 201
    CUSTOM_RESERVED_TUNNELS_IP     = 202
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
    # 69, verified against knx/src/knx/property.h - the evented device state
    # (03_08_03 2.5.20 p.14). The tool calls it PID_EIBNETIP_DEVICE_STATE.
    KNXNETIP_DEVICE_STATE          = 69
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
    # 03_02_02 2.2.2 p.26: CTRL bit7 FT - 1 = standard, 0 = extended. A standard frame carries its
    # length in a 4-bit field, so at most 15 octets of APDU fit. The tunnel copies this control octet
    # onto TP1 unchanged, so asking for a standard frame with a longer APDU puts a frame on the line
    # whose length cannot be expressed - the device never sees a valid telegram and stays silent.
    # Measured 2026-09-26 on 5.0.8: APDU 15 answered, APDU 16 and above were silent, for EVERY
    # command. That is what made Test-Rename report "no answer" while `oknx mv` renamed the same file.
    $apduLength = $Tpdu.Length - 1
    $ctrl1 = if ($apduLength -le 15) { 0x80 } else { 0x00 }
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

function New-TpduPropertyValueWrite {
    <#
    .SYNOPSIS
        Builds an A_PropertyValue_Write TPDU (APCI 0x3D7).
    .PARAMETER ObjectIndex
        Interface object INDEX, not the object type - property access by index here.
    #>
    param([int]$ObjectIndex = 0, [int]$PropertyId = 1, [int]$ElementCount = 1, [int]$StartIndex = 1, [byte[]]$Data = @(0x00))
    return , ([byte[]]@(
        0x03, 0xD7,
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
    if ($ElementCount -lt 0 -or $ElementCount -gt 15) {
        throw "ElementCount $ElementCount does not fit the 4-bit cEMI field (0..15); split the request."
    }
    if ($StartIndex -lt 0 -or $StartIndex -gt 4095) {
        throw "StartIndex $StartIndex does not fit the 12-bit cEMI field (0..4095)."
    }
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

function Get-KnxMaskVersion {
    <#
    .SYNOPSIS
        Reads a device's mask version from PID_DEVICE_DESCRIPTOR (83) in the Device Object.
    .DESCRIPTION
        NOT from the DESCRIPTION_RESPONSE: 03_08_02 Table 5 p.31 lists the Extended Device
        Information DIB as "Not allowed" there, so a device that omits it is right and looking
        for the mask in that frame can only ever answer "unknown". The same page names the
        authoritative source - the field "shall be identical as the contents of the Property
        PID_DEVICE_DESCRIPTOR (PID: 83) in the Device Object".
    .OUTPUTS
        The mask as '0xNNNN', or $null when the device serves no device management connection
        (a foreign interface may refuse one) or does not answer the property.
    #>
    param([Parameter(Mandatory)][string]$Ip, [int]$Port = 3671, [int]$TimeoutMs = 2000)
    $K = Get-KnxConstants
    $mgmt = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1 -TimeoutMs $TimeoutMs
    if (-not $mgmt.Ok) { return $null }
    try {
        $dd = Read-KnxProperty -Connection $mgmt -ObjectType $K.ObjType.DEVICE -PropertyId 83
        if ($null -eq $dd.Parsed -or $dd.Parsed.IsError -or $dd.Parsed.Data.Length -lt 2) { return $null }
        return ('0x{0:X4}' -f (Get-Uint16 -Bytes $dd.Parsed.Data -Offset 0))
    }
    catch { return $null }
    finally { [void](Close-KnxConnection -Connection $mgmt) }
}

function Get-KnxMaskVersionText {
    <#
    .SYNOPSIS
        The mask version for a report header - never $null, always something the reader can act on.
    .DESCRIPTION
        Says WHY it is missing instead of "unknown": a device that serves no device management
        connection cannot be asked, and that is a property of that device, not an open question.
    #>
    param([Parameter(Mandatory)][string]$Ip, [int]$Port = 3671)
    $m = Get-KnxMaskVersion -Ip $Ip -Port $Port
    if ($null -ne $m) { return $m }
    return 'not readable (no device management connection, or PID 83 unanswered)'
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
    # A TP1 acknowledge frame is a SINGLE octet (03_02_02 section 2.2.7 p.32, pattern
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
        Cemi        = $Cemi   # kept so a caller can show the framing a slicing question turns on
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
        # Data endpoint HPAI the server selected. Needed to judge route back: 08_TSSH 5.4.1 p.93 expects it
        # all zero when the request carried a route-back HPAI. Get-Uint16 does the port - a bare
        # "$b[6] -shl 8" would be evaluated in byte width and silently yield 0.
        DataHpaiIp   = $null
        DataHpaiPort = $null
    }
    if ($res.IsError -or $Body.Length -lt 12) { return $res }
    $res.DataHpaiIp = '{0}.{1}.{2}.{3}' -f $Body[4], $Body[5], $Body[6], $Body[7]
    $res.DataHpaiPort = Get-Uint16 -Bytes $Body -Offset 8
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
        return [pscustomobject]@{ Ok = $false; Status = -1; StatusName = 'NO_ANSWER'; Channel = -1; Socket = $null; Ip = $Ip; Port = $Port; SeqSend = 0; SeqRecv = 0; TunnelPa = $null; Request = $frame; Response = $null; Disconnected = $true; DisconnectedBy = 'client'; DisconnectPacket = $null; LocalIp = ''; LocalPort = 0; LastSpoke = [DateTime]::UtcNow }
    }
    $cr = Read-KnxConnectResponse -Body $rsp.Header.Body
    if ($cr.IsError) {
        $sock.Dispose()
        return [pscustomobject]@{ Ok = $false; Status = $cr.Status; StatusName = $cr.StatusName; Channel = -1; Socket = $null; Ip = $Ip; Port = $Port; SeqSend = 0; SeqRecv = 0; TunnelPa = $null; Request = $frame; Response = $rsp.Packet.Bytes; Disconnected = $true; DisconnectedBy = 'client'; DisconnectPacket = $null; LocalIp = ''; LocalPort = 0; LastSpoke = [DateTime]::UtcNow }
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
        # 03_08_02 5.4 p.14 puts the heartbeat on the CLIENT: a CONNECTIONSTATE_REQUEST every 60 s.
        # Update-KnxTunnelHeartbeat needs to know when we last spoke, and the connect counts.
        LastSpoke  = [DateTime]::UtcNow
        # The teardown record, declared here so every reader finds it: who ended the channel and the
        # datagram that said so. Set-KnxTunnelGone / Clear-KnxTunnelGone / Test-KnxTunnelGone own it.
        Disconnected     = $false
        DisconnectedBy   = ''
        DisconnectPacket = $null
    }
}

function Set-KnxTunnelGone {
    <#
    .SYNOPSIS
        Records that a tunnel channel is finished, and by whom.
    .DESCRIPTION
        Four places learn of it: a DISCONNECT_REQUEST caught while waiting for an acknowledge, one caught
        while receiving, one caught by the heartbeat, and a teardown this client sent itself after a
        failed acknowledge. They used to raise the same anonymous flag, so a waiting function could not
        tell a teardown by the device from one we caused - and nothing ever cleared it, which left a
        reused connection object marked dead for the rest of the run.
    #>
    param([Parameter(Mandatory)]$Connection, [Parameter(Mandatory)][ValidateSet('device', 'client')][string]$By, $Packet = $null)
    # A teardown by the DEVICE is never overwritten by a client one. The client teardown is the routine
    # cleanup that follows - Send-KnxTunnelCemi ends a connection whose acknowledge failed, and
    # Close-KnxConnection ends every connection - and letting it win erased both the origin and the
    # datagram, which is what every reader uses to tell "the device ended it" from "we did".
    if ($By -eq 'client' -and (Test-KnxTunnelGone -Connection $Connection) -and
        (Get-KnxTunnelGoneBy -Connection $Connection) -eq 'device') { return }
    Add-Member -InputObject $Connection -NotePropertyName 'Disconnected' -NotePropertyValue $true -Force
    Add-Member -InputObject $Connection -NotePropertyName 'DisconnectedBy' -NotePropertyValue $By -Force
    Add-Member -InputObject $Connection -NotePropertyName 'DisconnectPacket' -NotePropertyValue $Packet -Force
}

function Clear-KnxTunnelGone {
    <#
    .SYNOPSIS
        Marks a channel as live again. Only for a connection the device has just acknowledged.
    #>
    param([Parameter(Mandatory)]$Connection)
    Add-Member -InputObject $Connection -NotePropertyName 'Disconnected' -NotePropertyValue $false -Force
    Add-Member -InputObject $Connection -NotePropertyName 'DisconnectedBy' -NotePropertyValue '' -Force
    Add-Member -InputObject $Connection -NotePropertyName 'DisconnectPacket' -NotePropertyValue $null -Force
}

function Get-KnxTunnelGoneBy {
    <#
    .SYNOPSIS
        Who ended the channel: 'device', 'client', or '' when it is not ended or not recorded.
    .DESCRIPTION
        Read through this, never as $Connection.DisconnectedBy: under Set-StrictMode -Version Latest a
        bare read throws on any connection-like object that does not carry the field, and the suites
        build several of those by hand.
    #>
    param([Parameter(Mandatory)]$Connection)
    if ($null -eq $Connection -or $null -eq $Connection.PSObject.Properties['DisconnectedBy']) { return '' }
    return [string]$Connection.DisconnectedBy
}

function Test-KnxTunnelGone {
    <#
    .SYNOPSIS
        True when this connection's channel has been torn down, by either side.
    #>
    param([Parameter(Mandatory)]$Connection)
    if ($null -eq $Connection -or $null -eq $Connection.PSObject.Properties['Disconnected']) { return $false }
    return [bool]$Connection.Disconnected
}

function Test-KnxTunnelRepeat {
    <#
    .SYNOPSIS
        True when a TUNNELLING_REQUEST repeats one already handed out; otherwise records it and returns false.
    .DESCRIPTION
        03_08_04 2.6.1 p.9: "If a TUNNELLING_REQUEST frame is not confirmed within the
        TUNNELLING_REQUEST_TIMEOUT time of one (1) second then the frame shall be repeated once with the
        same sequence counter value". Every path that hands a frame to a caller asks here - the parked
        queue and the direct read in Receive-KnxTunnelCemi - so the repeat is handed out once, whichever
        path saw the original. Bounded by byte identity, a 2000 ms window and a lookback of 128 frames.
    #>
    param([Parameter(Mandatory)]$Connection, [int]$Channel, [int]$Sequence, [byte[]]$Cemi)
    # Kept apart from the queue: the consumer removes a queue entry long before the one-second repeat.
    if ($null -eq $Connection.PSObject.Properties['PendingSeen']) {
        Add-Member -InputObject $Connection -NotePropertyName 'PendingSeen' `
                   -NotePropertyValue (New-Object 'System.Collections.Generic.List[object]') -Force
        Add-Member -InputObject $Connection -NotePropertyName 'PendingRepeats' -NotePropertyValue 0 -Force
    }
    # The window alone does not bound the 8-bit sequence counter at high frame rates; the 128-frame
    # lookback does, as long as every frame handed out is recorded here (a number returns after 256).
    $nowUtc = [DateTime]::UtcNow
    while ($Connection.PendingSeen.Count -gt 0 -and
           ($nowUtc - $Connection.PendingSeen[0].Stamp).TotalMilliseconds -gt 2000) {
        $Connection.PendingSeen.RemoveAt(0)
    }
    while ($Connection.PendingSeen.Count -ge 128) { $Connection.PendingSeen.RemoveAt(0) }
    for ($q = $Connection.PendingSeen.Count - 1; $q -ge 0; $q--) {
        $prev = $Connection.PendingSeen[$q]
        if ($null -eq $prev) { continue }
        if ($prev.Channel -ne $Channel -or $prev.Sequence -ne $Sequence) { continue }
        $same = ($null -ne $prev.Cemi -and $null -ne $Cemi -and $prev.Cemi.Length -eq $Cemi.Length)
        if ($same) {
            for ($b = 0; $b -lt $Cemi.Length; $b++) { if ($prev.Cemi[$b] -ne $Cemi[$b]) { $same = $false; break } }
        }
        if ($same) {
            # The server repeats when our acknowledge was lost; the caller never sees the copy, so it is
            # counted apart from PendingDropped and the first one per measurement goes into the evidence.
            $Connection.PendingRepeats++
            if ($Connection.PendingRepeats -eq 1) {
                Add-KnxEvidence -Note ("suppressed a repeated TUNNELLING_REQUEST: channel $Channel, sequence $Sequence, identical cEMI within 2000 ms (03_08_04 2.6.1)")
            }
            return $true
        }
    }
    [void]$Connection.PendingSeen.Add([pscustomobject]@{
            Channel = $Channel; Sequence = $Sequence; Cemi = $Cemi; Stamp = $nowUtc
        })
    return $false
}

function Add-KnxTunnelParked {
    <#
    .SYNOPSIS
        Parks an ALREADY acknowledged TUNNELLING_REQUEST on the connection, in arrival order.
    .DESCRIPTION
        One queue, one shape, one consumer: whoever reads a frame it was not waiting for acknowledges it
        and parks it here, and Receive-KnxTunnelCemi is the only function that takes one out. A second
        parking mechanism next to this one is what made a capture lose frames and a paced wait eat a
        confirmation the case was about to read.
    #>
    param([Parameter(Mandatory)]$Connection, [int]$Channel, [int]$Sequence, [byte[]]$Cemi, [byte[]]$Raw, $Ignored = @())
    if ($null -eq $Connection.PSObject.Properties['Pending']) {
        Add-Member -InputObject $Connection -NotePropertyName 'Pending' `
                   -NotePropertyValue (New-Object 'System.Collections.Generic.List[object]') -Force
        Add-Member -InputObject $Connection -NotePropertyName 'PendingDropped' -NotePropertyValue 0 -Force
    }
    # A repeat of a frame already handed out is acknowledged by the caller but not parked again.
    if (Test-KnxTunnelRepeat -Connection $Connection -Channel $Channel -Sequence $Sequence -Cemi $Cemi) { return $false }
    $nowUtc = [DateTime]::UtcNow
    # Bounded: the shared traffic connection is sent on far more often than it is read from. The oldest
    # goes - dropping the NEWEST instead made a full connection permanently deaf, holding 256 stale
    # records and refusing everything after them. At this depth the head is minutes old, so the
    # confirmation a case is waiting for is never the one evicted.
    while ($Connection.Pending.Count -ge 256) {
        $Connection.Pending.RemoveAt(0)
        if ($null -ne $Connection.PSObject.Properties['PendingDropped']) { $Connection.PendingDropped++ }
    }
    [void]$Connection.Pending.Add([pscustomobject]@{
            Channel = $Channel; Sequence = $Sequence; Cemi = $Cemi; Raw = $Raw; Ignored = $Ignored
            Stamp   = $nowUtc
        })
    return $true
}

function Clear-KnxTunnelParked {
    <#
    .SYNOPSIS
        Throws away everything parked on a connection.
    .DESCRIPTION
        For a case that is about to measure and must not be handed a frame an earlier case left behind.
        Two suites reached into the queue directly to do this; this is the same thing with a name.
    #>
    param([Parameter(Mandatory)]$Connection)
    if ($null -ne $Connection.PSObject.Properties['Pending']) { $Connection.Pending.Clear() }
    # The drop counter describes the measurement that is starting, not the life of the process.
    if ($null -ne $Connection.PSObject.Properties['PendingDropped']) { $Connection.PendingDropped = 0 }
    # The dedup memory goes with it: "start from nothing" must not leave a record behind that can
    # suppress the first frame of the measurement.
    if ($null -ne $Connection.PSObject.Properties['PendingSeen']) { $Connection.PendingSeen.Clear() }
    if ($null -ne $Connection.PSObject.Properties['PendingRepeats']) { $Connection.PendingRepeats = 0 }
}

function Clear-KnxTunnelTraffic {
    <#
    .SYNOPSIS
        Throws away everything a connection is holding - parked and still on the socket - while staying
        a valid client.
    .DESCRIPTION
        "Start this measurement from nothing" needs both halves: the parked queue AND the datagrams still
        in the socket. Draining the socket with Clear-KnxSocket alone discards TUNNELLING_REQUESTs
        UNACKNOWLEDGED, which is the 03_08_04 2.6.1 trigger - the device repeats each one and then ends
        the connection, on the very connection a whole run shares. This acknowledges what it discards.
    .OUTPUTS
        How many frames were thrown away, so a case can say so instead of wondering.
    #>
    param([Parameter(Mandatory)]$Connection, [int]$QuietMs = 200, [int]$MaxMs = 5000)
    $n = 0
    if ($null -ne $Connection.PSObject.Properties['Pending']) {
        $n += $Connection.Pending.Count
        $Connection.Pending.Clear()
    }
    if ($null -ne $Connection.PSObject.Properties['PendingDropped']) { $Connection.PendingDropped = 0 }
    if ($null -ne $Connection.PSObject.Properties['PendingSeen']) { $Connection.PendingSeen.Clear() }
    if ($null -ne $Connection.PSObject.Properties['PendingRepeats']) { $Connection.PendingRepeats = 0 }
    if ($null -eq $Connection.Socket) { return $n }
    # Bounded: acknowledging keeps the device sending, so on a busy line "drain until quiet" is
    # "drain until the bus stops", which it does not.
    $stopBy = [DateTime]::UtcNow.AddMilliseconds($MaxMs)
    while ([DateTime]::UtcNow -lt $stopBy) {
        $r = Wait-KnxService -Socket $Connection.Socket -TimeoutMs $QuietMs `
                             -Service @($script:KnxService.TUNNELLING_REQUEST, $script:KnxService.DISCONNECT_REQUEST)
        if ($r.TimedOut) { break }
        if ($r.Header.Service -eq $script:KnxService.DISCONNECT_REQUEST) {
            if ($r.Header.Body.Length -ge 1 -and $r.Header.Body[0] -eq $Connection.Channel) {
                Send-KnxFrame -Socket $Connection.Socket -Frame (New-KnxDisconnectResponse -Channel $r.Header.Body[0] -Status 0) `
                              -Ip $Connection.Ip -Port $Connection.Port
                Set-KnxTunnelGone -Connection $Connection -By 'device' -Packet $r
                break
            }
            continue
        }
        if ($r.Header.Body.Length -lt 4 -or $r.Header.Body[1] -ne $Connection.Channel) { continue }
        Send-KnxFrame -Socket $Connection.Socket -Frame (New-KnxTunnellingAck -Channel $r.Header.Body[1] -Sequence $r.Header.Body[2]) `
                      -Ip $Connection.Ip -Port $Connection.Port
        $Connection.SeqRecv = $r.Header.Body[2]
        $n++
    }
    return $n
}

function Read-KnxTunnelParked {
    <#
    .SYNOPSIS
        Takes every parked frame off a connection, in arrival order, and empties the queue.
    .DESCRIPTION
        For a capture that never calls Receive-KnxTunnelCemi: without an explicit drain the queue is the
        place its frames go to be forgotten, and it grows for the life of the process.

        The records are emitted one by one, NOT as "return , $out": that idiom hands the whole array to
        the pipeline as a single object, and a caller writing @(Read-KnxTunnelParked ...) then gets one
        element - measured, two parked frames came back as one.
    .OUTPUTS
        The parked records, oldest first. Nothing when the queue is empty.
    #>
    param([Parameter(Mandatory)]$Connection)
    if ($null -eq $Connection.PSObject.Properties['Pending'] -or $Connection.Pending.Count -eq 0) { return }
    $out = @($Connection.Pending.ToArray())
    $Connection.Pending.Clear()
    return $out
}

function Update-KnxTunnelHeartbeat {
    <#
    .SYNOPSIS
        Sends the CONNECTIONSTATE_REQUEST the client owes when the connection has been quiet too long.
    .DESCRIPTION
        03_08_02 5.4 p.14 gives the client a duty and the server a deadline: the client sends a
        CONNECTIONSTATE_REQUEST about every 60 s, and the server ends a connection 120 s after the last
        frame it received. Acknowledging what the device pushes does NOT discharge that duty - measured on
        11.11.0.126: a client that returned 930 TUNNELLING_ACKs and sent nothing of its own was
        disconnected at exactly 120.0 s, while the same client plus four requests of its own survived. Any
        loop that may sit on a tunnel longer than a minute has to call this, or it kills its own tunnel and
        then reports the device for it (D-4.3 under bus load).
    .OUTPUTS
        $true while the device still answers for this channel, $false when it does not.
    #>
    param([Parameter(Mandatory)]$Connection, [int]$IntervalSeconds = 45, [int]$TimeoutMs = 1500)
    if ($null -eq $Connection -or -not $Connection.Ok -or $null -eq $Connection.Socket) { return $false }
    if ($null -eq $Connection.PSObject.Properties['LastSpoke']) {
        Add-Member -InputObject $Connection -NotePropertyName 'LastSpoke' -NotePropertyValue ([DateTime]::UtcNow) -Force
        return $true
    }
    if (([DateTime]::UtcNow - $Connection.LastSpoke).TotalSeconds -lt $IntervalSeconds) { return $true }

    $probe = New-KnxConnectionStateRequest -Channel $Connection.Channel -ControlIp $Connection.LocalIp -ControlPort $Connection.LocalPort
    $r = Invoke-KnxRequest -Socket $Connection.Socket -Frame $probe -Ip $Connection.Ip -Port $Connection.Port `
                           -Expect @($script:KnxService.CONNECTIONSTATE_RESPONSE) -TimeoutMs $TimeoutMs
    $Connection.LastSpoke = [DateTime]::UtcNow
    # Wait-KnxService puts everything that is not the expected answer into Ignored and does not act on
    # it. Two things must not be lost there: a TUNNELLING_REQUEST left unanswered makes the device repeat
    # it once and then end the connection (03_08_04 2.6.1 p.9) - the very thing the heartbeat prevents -
    # and a DISCONNECT_REQUEST dropped here leaves the caller waiting on a channel that is already gone,
    # which reads as "the device did not disconnect". Both go through the same state every other reader
    # uses: the parked queue and the teardown record. The channel sits at a different offset per service -
    # a DISCONNECT_REQUEST carries it in body octet 0 with a reserved octet behind it, a tunnelling
    # request in octet 1 behind the structure length.
    foreach ($p in @($r.Ignored)) {
        $h = Read-KnxHeader -Frame $p.Bytes
        if ($null -eq $h) { continue }
        if ($h.Service -eq $script:KnxService.DISCONNECT_REQUEST) {
            if ($h.Body.Length -lt 1 -or $h.Body[0] -ne $Connection.Channel) { continue }
            Send-KnxFrame -Socket $Connection.Socket -Frame (New-KnxDisconnectResponse -Channel $h.Body[0] -Status 0) `
                          -Ip $Connection.Ip -Port $Connection.Port
            Set-KnxTunnelGone -Connection $Connection -By 'device' -Packet ([pscustomobject]@{ Header = $h; Packet = $p })
            # Nothing after a teardown belongs on this channel any more, so acknowledging further frames
            # from the same batch would be answering for a connection we just agreed is closed.
            break
        }
        if ($h.Service -ne $script:KnxService.TUNNELLING_REQUEST) { continue }
        if ($h.Body.Length -lt 4 -or $h.Body[1] -ne $Connection.Channel) { continue }
        Send-KnxFrame -Socket $Connection.Socket -Frame (New-KnxTunnellingAck -Channel $h.Body[1] -Sequence $h.Body[2]) `
                      -Ip $Connection.Ip -Port $Connection.Port
        $Connection.SeqRecv = $h.Body[2]
        $inCemi = if ($h.Body.Length -gt 4) { [byte[]]$h.Body[4..($h.Body.Length - 1)] } else { [byte[]]@() }
        # [void]: the helper answers whether the queue took it, and an unconsumed answer would be
        # emitted as this function's output next to its real return value.
        [void](Add-KnxTunnelParked -Connection $Connection -Channel $h.Body[1] -Sequence $h.Body[2] -Cemi $inCemi -Raw $p.Bytes)
    }
    if (Test-KnxTunnelGone -Connection $Connection) { return $false }
    if ($r.TimedOut -or $r.Header.Body.Length -lt 2) { return $false }
    # An answer for SOMEBODY ELSE'S channel says nothing about ours - servers recycle channel ids
    # seconds after they reap one, so this is not theoretical.
    if ($r.Header.Body[0] -ne $Connection.Channel) { return $false }
    if ($r.Header.Body[1] -ne 0x00) {
        # 03_08_02 5.4 p.14: a non-zero status on our own channel - E_CONNECTION_ID above all - is the
        # server stating it does not have this connection. Continuing to wait on it waits on nothing.
        Set-KnxTunnelGone -Connection $Connection -By 'device'
        return $false
    }
    return $true
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
    finally {
        try { $Connection.Socket.Dispose() } catch { }
        # Leave nothing usable behind. A disposed socket is not $null, so the reuse check in
        # Get-KnxTrafficConnection let it through and the next send threw ObjectDisposedException out of
        # the case - deterministic in suite 6, where three cases close the SHARED connection themselves.
        Set-KnxTunnelGone -Connection $Connection -By 'client'
        try { $Connection.Socket = $null } catch { }
        if ($null -ne $script:TrafficConnection -and [object]::ReferenceEquals($script:TrafficConnection, $Connection)) {
            $script:TrafficConnection = $null
        }
    }
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
    # A closed connection has no socket; sending into it threw out of the case instead of reporting it.
    if ($null -eq $Connection -or $null -eq $Connection.Socket) {
        # Same shape as the normal return, or a caller reading AckSeq gets a strict-mode error instead
        # of a result.
        return [pscustomobject]@{ Acked = $false; Status = -1; Sequence = -1; AckChannel = -1; AckSeq = -1
                                  AckSeen = $false; AckStatusSeen = -1; Sent = $null; Disconnected = $true; Ignored = @() }
    }
    $seq = if ($Sequence -ge 0) { $Sequence } else { $Connection.SeqSend }
    $frame = New-KnxTunnellingRequest -Channel $Connection.Channel -Sequence $seq -Cemi $Cemi

    # While waiting for our own ack the device may already be sending us frames - the
    # L_Data.con for this very request, and any indication that arrives meanwhile. Waiting
    # only for TUNNELLING_ACK discards them unacked; the device then keeps them queued,
    # runs into its outstanding-frame limit and drops the connection, which looks exactly
    # like "the device never answered". Take them here, ack them, and park them so the
    # next Receive-KnxTunnelCemi hands them out in arrival order.
    # 03_08_04 p.9: on a missing TUNNELLING_ACK the sending device shall repeat the frame ONCE
    # with the SAME sequence number, then terminate the connection. Both shortcuts are wrong and
    # both were tried here: keeping the counter turns the NEXT, different frame into a duplicate
    # that the server acks with E_NO_ERROR and DISCARDS, so the caller believes it went out;
    # advancing past a frame the server never saw puts every later frame outside its window,
    # where the server "shall not reply and shall discard" - on a connection shared by the whole
    # run that silences it for good. The repeat is correct either way: if only the ack was lost
    # the repeat is a duplicate and gets acked, and if the frame was lost the repeat is the one
    # the server was waiting for.
    $status = -1; $ackSeq = -1; $ackCh = -1
    $seenAck = $false; $seenCh = -1; $seenSeq = -1; $seenStatus = -1
    $ack = $null
    # Update-KnxTunnelHeartbeat measures the quiet time from here: a request of our own restarts the
    # server's 120 s window (03_08_02 5.4 p.14), an acknowledge does not.
    if ($null -ne $Connection.PSObject.Properties['LastSpoke']) { $Connection.LastSpoke = [DateTime]::UtcNow }
    for ($attempt = 1; $attempt -le 2; $attempt++) {
    if ($attempt -gt 1) { $status = -1; $ackSeq = -1; $ackCh = -1; $ack = $null }
    Send-KnxFrame -Socket $Connection.Socket -Frame $frame -Ip $Connection.Ip -Port $Connection.Port
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
            Set-KnxTunnelGone -Connection $Connection -By 'device' -Packet $r
            $ack = [pscustomobject]@{ TimedOut = $true; Ignored = $r.Ignored }
            break
        }
        if ($r.Header.Service -eq $script:KnxService.TUNNELLING_ACK) {
            # Two different questions, and they were being answered by one value. For the PROTOCOL the
            # acknowledge must match channel and sequence - a late one for the previous frame otherwise
            # validates this one, and a real error status at the end of a burst becomes invisible. For
            # the REPORT the cases need to know an acknowledge arrived at all and what it carried:
            # "the device acknowledged a sequence one too large" is the finding H-5.2.4 exists for, and
            # matching silently would have turned it into a pass.
            $ab = $r.Header.Body
            if ($ab.Length -ge 4) {
                if (-not $seenAck) { $seenAck = $true; $seenCh = $ab[1]; $seenSeq = $ab[2]; $seenStatus = $ab[3] }
                if ($ab[1] -eq $Connection.Channel -and $ab[2] -eq $seq) {
                    # The matching one is authoritative for the report as well as for the decision.
                    $seenCh = $ab[1]; $seenSeq = $ab[2]; $seenStatus = $ab[3]
                    $ack = $r; break
                }
            }
            continue
        }
        $b = $r.Header.Body
        # Same filter as every other reader: a frame for another channel is not ours to acknowledge, and
        # parking it would hand a case a telegram that was never addressed to its tunnel.
        if ($b.Length -ge 4 -and $b[1] -eq $Connection.Channel) {
            Send-KnxFrame -Socket $Connection.Socket -Frame (New-KnxTunnellingAck -Channel $b[1] -Sequence $b[2]) `
                          -Ip $Connection.Ip -Port $Connection.Port
            $inCemi = if ($b.Length -gt 4) { [byte[]]$b[4..($b.Length - 1)] } else { [byte[]]@() }
            $Connection.SeqRecv = $b[2]
            [void](Add-KnxTunnelParked -Connection $Connection -Channel $b[1] -Sequence $b[2] -Cemi $inCemi `
                                       -Raw $r.Packet.Bytes -Ignored $r.Ignored)
        }
    }
    if ($null -eq $ack) { $ack = [pscustomobject]@{ TimedOut = $true; Ignored = @() } }
    if (-not $ack.TimedOut -and $ack.Header.Body.Length -ge 4) {
        $ackCh = $ack.Header.Body[1]; $ackSeq = $ack.Header.Body[2]; $status = $ack.Header.Body[3]
    }
    elseif ($seenAck) {
        # No acknowledge for THIS frame, but one was seen. Report what it carried; the protocol decision
        # below stays "unacknowledged", which is what 03_08_04 2.6.1 prescribes for it.
        $ackCh = $seenCh; $ackSeq = $seenSeq
    }
    # 03_08_04 2.6.1 names TWO repeat triggers: no ack within the timeout, AND an ack whose status
    # signals any error. Leaving on any received ack implemented only half of it.
    if (-not $ack.TimedOut -and $status -eq 0) { break }
    if (Test-KnxTunnelGone -Connection $Connection) { break }
    }
    if ($null -eq $ack) { $ack = [pscustomobject]@{ TimedOut = $true; Ignored = @() } }
    # Advance only on a positive ack. After two unanswered attempts the server never confirmed
    # receipt, so moving the counter would step out of its window for every frame that follows.
    if (-not $NoAdvance -and $status -eq 0) { $Connection.SeqSend = (($seq + 1) -band 0xFF) }
    # ...and then the clause requires the connection to be TERMINATED. Without that the counter
    # stays put while the server has moved on, so the next DIFFERENT frame arrives as "one less
    # than expected": acknowledged with E_NO_ERROR and discarded. The caller reads a positive ack,
    # advances, and every frame from there on is silently thrown away - on a connection the whole
    # run shares. Ending it is what stops one lost ack from poisoning every later case; the next
    # Get-KnxTrafficConnection finds it dead and opens a fresh one.
    # Covers both triggers: a timeout leaves $status at -1, an error status leaves it non-zero.
    # -NoAdvance marks a caller that is deliberately probing sequence handling and expects no ack;
    # ending its connection would destroy the very case it is running.
    if (-not $NoAdvance -and $status -ne 0 -and -not (Test-KnxTunnelGone -Connection $Connection)) {
        try {
            $bye = New-KnxDisconnectRequest -Channel $Connection.Channel -ControlIp $Connection.LocalIp -ControlPort $Connection.LocalPort
            Send-KnxFrame -Socket $Connection.Socket -Frame $bye -Ip $Connection.Ip -Port $Connection.Port
        }
        catch { }
        Set-KnxTunnelGone -Connection $Connection -By 'client'
        # Leave nothing usable behind, as Close-KnxConnection does: this is the one place that ended a
        # channel and kept a live, bound socket on the object.
        try { $Connection.Socket.Dispose() } catch { }
        try { $Connection.Socket = $null } catch { }
        if ($null -ne $script:TrafficConnection -and [object]::ReferenceEquals($script:TrafficConnection, $Connection)) {
            $script:TrafficConnection = $null
        }
    }
    $gone = Test-KnxTunnelGone -Connection $Connection
    return [pscustomobject]@{
        Sent         = $frame
        Disconnected = $gone
        Sequence   = $seq
        # Positively acknowledged, not merely answered: an ack carrying an error status (E_SEQUENCE_NUMBER,
        # E_CONNECTION_ID) tore the channel down above (except under -NoAdvance), so reporting it as acked
        # let a case assert Acked, then read nothing from the dead socket and call that a silent device.
        Acked      = ((-not $ack.TimedOut) -and $status -eq 0)
        # AckSeen is "an acknowledge arrived", Acked is "OUR frame was acknowledged". A device that
        # answers the wrong sequence sets the first and not the second, and a case needs to tell them
        # apart to report what the device actually did.
        AckSeen    = $seenAck
        AckChannel = $ackCh
        AckSeq     = $ackSeq
        # The status of the acknowledge that was SEEN. Status below stays the protocol answer for this
        # frame (-1 when it was never acknowledged) - feeding a seen status into it would let an
        # acknowledge for someone else's frame advance our sequence counter.
        AckStatusSeen = $seenStatus
        Status     = $status
        Ignored    = $ack.Ignored
    }
}

function Test-KnxTransmitted {
    <#
    .SYNOPSIS
        Drains a tunnel for the L_Data.con of a frame just sent and reports whether the device
        transmitted it.
    .DESCRIPTION
        A TUNNELLING_ACK only says the interface took the packet off the wire; it says nothing
        about TP. 03_06_03 p.80: the L_Data.con (MC 2Eh) is generated by the cEMI server's own
        data link layer, and bit 0 of Control field 1 is the confirm flag - 1 = Error, 0 = No
        Error. That flag, not the ack, is the proof a frame reached the bus.
    .OUTPUTS
        $true on a positive confirmation, $false on an error confirmation or none at all.
    #>
    param([Parameter(Mandatory)]$Connection, [byte[]]$Sent, [int]$TimeoutMs = 1500)
    # Without -Sent the FIRST confirmation wins, and on a connection that has just carried a load
    # case that is somebody else's: Send-KnxTunnelCemi parks every frame that arrives while it
    # waits, so a backlog of older L_Data.con sits there and each probe collects one. Every probe
    # then reads as "transmitted" while nothing new went out.
    #
    # -Sent filters by destination and NPDU. That rejects a confirmation for a DIFFERENT telegram,
    # but it does NOT separate two telegrams that differ only in their control field - measured:
    # five of B-14's probes and its canary all carry destination 7/7/7 with the same GroupValueRead
    # and differ only in priority, hop count or the repeat flag. The control field cannot be used
    # to tell them apart either, because a normalising interface rewrites it before the L_Data.con
    # and every probe would then read as unconfirmed. The caller must therefore drain this
    # connection before each send; this filter is the second line, not the first.
    $wantDa = $null; $wantNpdu = $null
    if ($null -ne $Sent -and $Sent.Length -gt 8) {
        $o = 2 + [int]$Sent[1]
        if ($Sent.Length -ge ($o + 7)) {
            $wantDa = @($Sent[($o + 4)], $Sent[($o + 5)])
            $wantNpdu = @($Sent[($o + 6)..($Sent.Length - 1)])
        }
    }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
        $in = Receive-KnxTunnelCemi -Connection $Connection -TimeoutMs $left
        if ($null -eq $in) { break }
        $c = $in.Cemi
        if ($c.Length -lt 3 -or $c[0] -ne 0x2E) { continue }   # not an L_Data.con - keep draining
        $addIL = [int]$c[1]
        $o = 2 + $addIL
        if ($c.Length -lt ($o + 1)) { continue }
        if ($null -ne $wantDa) {
            if ($c.Length -lt ($o + 7)) { continue }
            if ($c[$o + 4] -ne $wantDa[0] -or $c[$o + 5] -ne $wantDa[1]) { continue }
            $npdu = @($c[($o + 6)..($c.Length - 1)])
            if ($npdu.Count -ne $wantNpdu.Count) { continue }
            $same = $true
            for ($k = 0; $k -lt $npdu.Count; $k++) { if ($npdu[$k] -ne $wantNpdu[$k]) { $same = $false; break } }
            if (-not $same) { continue }
        }
        return ((($c[$o]) -band 0x01) -eq 0)
    }
    return $false
}

function Receive-KnxTunnelCemi {
    <#
    .SYNOPSIS
        Waits for a TUNNELLING_REQUEST from the device, acks it, and returns its cEMI.
    .PARAMETER NoAck
        Do not answer - for the "repeat and timeout after missing ACK" test cases.
    #>
    param([Parameter(Mandatory)]$Connection, [int]$TimeoutMs = 3000, [switch]$NoAck)
    # A closed connection has no socket. Reading from it threw a parameter-binding error out of the
    # case instead of reporting "nothing arrived", which is what a closed channel means.
    if ($null -eq $Connection -or $null -eq $Connection.Socket) { return $null }
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
    # A frame for another channel is not ours, and it must not read as "nothing arrived": returning null
    # for it ended a drain loop early with the whole budget unspent. Keep listening until the deadline.
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ($true) {
        $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
        $r = Wait-KnxService -Socket $Connection.Socket `
                             -Service @($script:KnxService.TUNNELLING_REQUEST, $script:KnxService.DISCONNECT_REQUEST) `
                             -TimeoutMs $left
        if ($r.TimedOut) { return $null }
        if ($r.Header.Service -eq $script:KnxService.DISCONNECT_REQUEST) {
            $db = $r.Header.Body
            if ($db.Length -lt 1 -or $db[0] -ne $Connection.Channel) {
                if ([DateTime]::UtcNow -ge $deadline) { return $null }
                continue
            }
            Send-KnxFrame -Socket $Connection.Socket -Frame (New-KnxDisconnectResponse -Channel $db[0] -Status 0) `
                          -Ip $Connection.Ip -Port $Connection.Port
            Set-KnxTunnelGone -Connection $Connection -By 'device' -Packet $r
            return $null
        }
        $b = $r.Header.Body
        if ($b.Length -lt 4 -or $b[1] -ne $Connection.Channel) {
            if ([DateTime]::UtcNow -ge $deadline) { return $null }
            continue
        }
        $ch = $b[1]; $seq = $b[2]
        $cemi = if ($b.Length -gt 4) { [byte[]]$b[4..($b.Length - 1)] } else { [byte[]]@() }
        if (-not $NoAck) {
            $ack = New-KnxTunnellingAck -Channel $ch -Sequence $seq
            Send-KnxFrame -Socket $Connection.Socket -Frame $ack -Ip $Connection.Ip -Port $Connection.Port
        }
        $Connection.SeqRecv = $seq
        # A repeat of a frame this path or the queue already handed out is acknowledged above but not
        # returned again. Not for -NoAck: those cases provoke the repeat on purpose and must see it.
        if (-not $NoAck -and (Test-KnxTunnelRepeat -Connection $Connection -Channel $ch -Sequence $seq -Cemi $cemi)) {
            if ([DateTime]::UtcNow -ge $deadline) { return $null }
            continue
        }
        return [pscustomobject]@{ Channel = $ch; Sequence = $seq; Cemi = $cemi; Raw = $r.Packet.Bytes; Ignored = $r.Ignored }
    }
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

function Wait-KnxTpduFromTunnel {
    <#
    .SYNOPSIS
        Waits for an inbound L_Data on a tunnel whose TPDU starts with a given TPCI octet.
    .DESCRIPTION
        Used to see a T_Disconnect (0x81) the device sends back. L_Data.con is skipped: that is
        the confirmation of our own send, it carries the TPDU we just sent and would match.
        Returns the parsed L_Data, or $null on timeout.
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][int]$Tpci,
        [int]$TimeoutMs = 3000,
        [int]$Source = -1
    )
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
        $in = Receive-KnxTunnelCemi -Connection $Connection -TimeoutMs $left
        if ($null -eq $in) { continue }
        $ld = Read-CemiLData -Cemi $in.Cemi
        if ($null -eq $ld) { continue }
        if ($ld.MessageCode -eq 0x2E) { continue }   # L_Data.con - our own frame coming back
        if ($ld.Tpdu.Length -lt 1) { continue }
        if ($Source -ge 0 -and $ld.Source -ne $Source) { continue }
        if (($ld.Tpdu[0] -band 0xFF) -eq ($Tpci -band 0xFF)) { return $ld }
    }
    return $null
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

        Count-driven, in blocks of at most 15 (the cEMI element-count field is four bits), because a
        property read is all-or-nothing: a fixed request of 15 is refused by a device holding fewer.
    .OUTPUTS
        Addresses, Held, and Complete - false when the pool could not be read in full. A caller that
        judges a device on this must check Complete first: a short read is not a short pool.
    #>
    param([Parameter(Mandatory)][string]$Ip, [int]$Port = 3671, [int]$Count = 16)
    $entries = @()
    $conn = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $script:KnxConnType.DEVICE_MGMT_CONNECTION -Layer -1
    if (-not $conn.Ok) { return [pscustomobject]@{ Addresses = @(); Held = -1; Complete = $false } }
    try {
        # Ask how many there are instead of assuming 16. A property read is all-or-nothing (03_03_07,
        # and knx data_property.cpp): asking 15 elements of a device that holds 5 is refused outright,
        # and the old code swallowed that refusal - so every device with fewer than 15 entries reported
        # an EMPTY pool, and the one case whose result turns on the pool then demanded the wrong error
        # code from a conformant device.
        $c0 = Read-KnxProperty -Connection $conn -ObjectType $script:ObjType.KNXNETIP_PARAM `
                               -PropertyId $script:KnxPid.ADDITIONAL_INDIVIDUAL_ADDRESSES -ElementCount 1 -StartIndex 0
        $held = -1
        if ($null -ne $c0.Parsed -and -not $c0.Parsed.IsError -and $c0.Parsed.Data.Length -ge 2) {
            $held = Get-Uint16 -Bytes $c0.Parsed.Data -Offset 0
        }
        $complete = $true
        if ($held -lt 0) {
            # No count to go by, and asking for 15 elements of a device that holds fewer is refused
            # outright - that refusal used to be swallowed and the pool read as EMPTY. One element at a
            # time is the only request an all-or-nothing read cannot refuse for being too large.
            for ($i = 1; $i -le 64; $i++) {
                $r1 = Read-KnxProperty -Connection $conn -ObjectType $script:ObjType.KNXNETIP_PARAM `
                                       -PropertyId $script:KnxPid.ADDITIONAL_INDIVIDUAL_ADDRESSES -ElementCount 1 -StartIndex $i
                # A timeout looks exactly like "this element does not exist", so a lost datagram would
                # truncate the pool and the caller would judge on it. An error is the natural end; no
                # answer at all is not, and it makes the result incomplete.
                if ($null -eq $r1.Parsed) { $complete = $false; break }
                if ($r1.Parsed.IsError -or $r1.Parsed.Data.Length -lt 2) { break }
                $entries += (ConvertFrom-KnxPa -Raw (Get-Uint16 -Bytes $r1.Parsed.Data -Offset 0))
            }
            return [pscustomobject]@{ Addresses = $entries; Held = $entries.Count; Complete = $complete }
        }
        if ($held -gt 64) { $held = 64 }
        $index = 1
        while ($index -le $held) {
            $n = [Math]::Min(15, $held - $index + 1)
            $r = Read-KnxProperty -Connection $conn -ObjectType $script:ObjType.KNXNETIP_PARAM `
                                  -PropertyId $script:KnxPid.ADDITIONAL_INDIVIDUAL_ADDRESSES -ElementCount $n -StartIndex $index
            if ($null -eq $r.Parsed -or $r.Parsed.IsError) { $complete = $false; break }
            $d = $r.Parsed.Data
            $got = [int][Math]::Floor($d.Length / 2)
            if ($got -le 0) { $complete = $false; break }
            for ($o = 0; ($o + 1) -lt $d.Length; $o += 2) {
                # Zero entries are KEPT. An ETS slot left without an address reads as 0.0.0, and those
                # are exactly the duplicates the uniqueness case looks for - dropping them made the
                # check it performs impossible to reach.
                $entries += (ConvertFrom-KnxPa -Raw (Get-Uint16 -Bytes $d -Offset $o))
            }
            $index += $got
        }
    }
    finally { [void](Close-KnxConnection -Connection $conn) }
    return [pscustomobject]@{ Addresses = $entries; Held = $held; Complete = ($complete -and $entries.Count -eq $held) }
}

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
    param([Parameter(Mandatory)][string]$Ip, [int]$Port = 3671, [int]$TimeoutMs = 3000, [int]$WaitSeconds = 25)
    if ($null -ne $script:TrafficConnection) {
        $c = $script:TrafficConnection
        # A connection whose record says the channel is finished is not probed back to life: the teardown
        # this client sends is fire-and-forget, so a CONNECTIONSTATE_RESPONSE that overtakes it would
        # "prove" a channel the device is about to reap, and the object would carry its old sequence
        # counter and parked backlog into the next case.
        if ($null -ne $c.Socket -and $c.Ip -eq $Ip -and -not (Test-KnxTunnelGone -Connection $c)) {
            # Holding a socket is not proof the DEVICE still knows the channel: after its
            # 120 s reaper fires we would keep sending into a dead channel and every
            # "from KNX" case would fail for a reason that has nothing to do with the BDUT.
            # Ask the device, and only reuse what it still acknowledges.
            $probe = New-KnxConnectionStateRequest -Channel $c.Channel -ControlIp $c.LocalIp -ControlPort $c.LocalPort
            $r = Invoke-KnxRequest -Socket $c.Socket -Frame $probe -Ip $c.Ip -Port $c.Port `
                                   -Expect @($script:KnxService.CONNECTIONSTATE_RESPONSE) -TimeoutMs 1500
            # Bus traffic that lands in this 1500 ms window is in $r.Ignored, and dropping it there is
            # unacknowledged - the same hole the heartbeat had. On the one connection a whole run shares
            # that is how a device starts repeating and then ends the channel.
            foreach ($p in @($r.Ignored)) {
                $h = Read-KnxHeader -Frame $p.Bytes
                if ($null -eq $h) { continue }
                if ($h.Service -eq $script:KnxService.DISCONNECT_REQUEST) {
                    # Answered and recorded, like every other reader. Dropping it here left the device
                    # repeating a teardown nobody had answered and the harness never learning of it.
                    if ($h.Body.Length -ge 1 -and $h.Body[0] -eq $c.Channel) {
                        Send-KnxFrame -Socket $c.Socket -Frame (New-KnxDisconnectResponse -Channel $h.Body[0] -Status 0) `
                                      -Ip $c.Ip -Port $c.Port
                        Set-KnxTunnelGone -Connection $c -By 'device' -Packet ([pscustomobject]@{ Header = $h; Packet = $p })
                    }
                    continue
                }
                if ($h.Service -ne $script:KnxService.TUNNELLING_REQUEST) { continue }
                if ($h.Body.Length -lt 4 -or $h.Body[1] -ne $c.Channel) { continue }
                Send-KnxFrame -Socket $c.Socket -Frame (New-KnxTunnellingAck -Channel $h.Body[1] -Sequence $h.Body[2]) `
                              -Ip $c.Ip -Port $c.Port
                $c.SeqRecv = $h.Body[2]
            }
            if (-not $r.TimedOut -and $r.Header.Body.Length -ge 2 -and $r.Header.Body[1] -eq 0x00) {
                # Whatever an earlier case left belongs to that case, not to the next one - and what is
                # thrown away is acknowledged first, because a discarded frame the device never saw an
                # acknowledge for is exactly what makes it end the channel.
                [void](Clear-KnxTunnelTraffic -Connection $c -QuietMs 50)
                # The probe said alive, but the drain can still meet the teardown that was already on
                # its way - handing the object back then gives the caller a live socket on a channel
                # this module has just recorded as gone, and every wait on it returns at once.
                if (-not (Test-KnxTunnelGone -Connection $c)) { return $c }
            }
            # Same cleanup as Close-KnxConnection: a disposed socket that is still referenced passes
            # every "is it there" check and throws on the next send, and a caller may still hold this
            # object after the cache has moved on.
            try { $c.Socket.Dispose() } catch { }
            Set-KnxTunnelGone -Connection $c -By 'client'
            try { $c.Socket = $null } catch { }
        }
        $script:TrafficConnection = $null
    }
    # A device does not free a tunnel slot the instant the previous client disconnects. Run
    # standalone there is always one; run as one stage after another, the stage before has just
    # released its tunnel and the slot is still held - the case then fails for a reason that has
    # nothing to do with the device under test, and the suite looks non-deterministic when it is
    # merely impatient. Wait, bounded, and only while the device says it is FULL: an unreachable
    # or refusing device is answered once and not hammered.
    $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
    while ($true) {
        $conn = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $script:KnxConnType.TUNNEL_CONNECTION `
                                   -Layer $script:KnxLayer.TUNNEL_LINKLAYER -TimeoutMs $TimeoutMs
        if ($conn.Ok) {
            $script:TrafficConnection = $conn
            return $conn
        }
        $full = ($conn.Status -eq 0x24 -or $conn.Status -eq 0x25)   # E_NO_MORE_CONNECTIONS / _UNIQUE
        if (-not $full -or [DateTime]::UtcNow -ge $deadline) { return $null }
        Start-Sleep -Milliseconds 1500
    }
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
        # Suites the runner refused to start, with the reason. Empty is the normal case.
        Dropped     = New-Object System.Collections.ArrayList
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

# How many assertions the running case has raised. Invoke-KnxTestCase resets it before the body and
# reads it afterwards: a body that completes without raising one has judged nothing. Module scope, so
# an assertion inside a helper the body calls counts as well, however deep the call stack.
$script:KnxAssertions = 0

function Add-KnxAssertion {
    <#
    .SYNOPSIS
        Records that the running case has just put a requirement to the device.
    .DESCRIPTION
        Called by every Assert-Knx* function as its FIRST statement, before the condition is evaluated:
        a failing assertion throws, and counting afterwards would make the case that found the defect
        look like a case that checked nothing.
    #>
    $script:KnxAssertions++
}

function Get-KnxAssertionCount {
    <#
    .SYNOPSIS
        Assertions raised since the running case started.
    #>
    return [int]$script:KnxAssertions
}

function Assert-KnxTrue {
    <#
    .SYNOPSIS
        Fails the current test case unless the condition holds.
    #>
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    Add-KnxAssertion
    if (-not $Condition) { throw "KNXTEST_FAIL::$Message" }
}

function Assert-KnxEqual {
    <#
    .SYNOPSIS
        Fails unless two scalars are equal, recording both values as evidence.
    #>
    param($Expected, $Actual, [Parameter(Mandatory)][string]$Message)
    Add-KnxAssertion
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
    Add-KnxAssertion
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
    Add-KnxAssertion
    if ($Expected -ne $Actual) {
        $e = Get-KnxErrorName -Status $Expected
        $a = Get-KnxErrorName -Status $Actual
        Add-KnxEvidence -Note "expected $e (0x$($Expected.ToString('X2'))), got $a (0x$($Actual.ToString('X2')))"
        throw "KNXTEST_FAIL::$Message - expected $e, got $a"
    }
}

function Assert-KnxStatusAny {
    <#
    .SYNOPSIS
        Fails unless a KNXnet/IP status byte is one of the accepted values, recording which came.
    .DESCRIPTION
        For the places where the standard allows more than one answer, or where the rig cannot
        prove which limit the device hit. Why is written to the report either way, so a passing
        run still says WHICH code the device sent and on what grounds it was accepted.
    #>
    param([Parameter(Mandatory)][int[]]$Accept, [Parameter(Mandatory)][int]$Actual,
          [string]$Why = '', [string]$Message = 'unexpected status code')
    Add-KnxAssertion
    $names = (@($Accept) | ForEach-Object { Get-KnxErrorName -Status $_ }) -join ' or '
    $got = Get-KnxErrorName -Status $Actual
    if ($Why) { Add-KnxEvidence -Note "expecting $names because $Why" }
    if (@($Accept) -notcontains $Actual) {
        Add-KnxEvidence -Note "expected $names, got $got (0x$($Actual.ToString('X2')))"
        throw "KNXTEST_FAIL::$Message - expected $names, got $got"
    }
    Add-KnxEvidence -Note "device answered $got (0x$($Actual.ToString('X2')))"
}

function Request-KnxOperatorAction {
    <#
    .SYNOPSIS
        Asks the operator to do something at the device or in ETS, waits a bounded time, and skips
        the case when nobody answers.
    .DESCRIPTION
        Some of what a device has to get right cannot be driven over a tunnel: pressing the
        programming button, an ETS download, assigning group addresses. Those steps are not left
        out and they are not faked either - the case asks for the step and then VERIFIES the result
        on the bus like any other case.

        Three ways out, and all of them let the REST of the run continue:
          - not guided            -> SKIP immediately, with the instruction as the reason
          - no interactive input  -> SKIP (a redirected stdin cannot be asked)
          - nobody answers in time -> SKIP after -TimeoutSeconds

        That last one is the point: a guided run left alone must not block on one prompt. The wait
        is shown as a countdown so an operator who IS there can see how long they have.
    .PARAMETER Instruction
        What the operator has to do, in one line.
    .PARAMETER Detail
        Optional second line: why it is needed, or what to watch for.
    .PARAMETER Guided
        Set by the runner when a human may be present.
    .PARAMETER TimeoutSeconds
        How long to wait for ENTER before skipping. 0 waits forever (not recommended unattended).
    .OUTPUTS
        $true once the operator confirms. Never returns otherwise - it skips the case.
    #>
    param(
        [Parameter(Mandatory)][string]$Instruction,
        [string]$Detail = '',
        [switch]$Guided,
        [int]$TimeoutSeconds = 90
    )
    if (-not $Guided) {
        Set-KnxTestNotRun -MissingInput '-Guided' -Reason "needs an operator step, run with -Guided: $Instruction"
    }

    # A redirected or absent stdin cannot be asked. Probing KeyAvailable is the portable test:
    # it throws exactly in that situation, and catching it is cheaper than guessing from $Host.
    $interactive = $true
    try { [void][Console]::KeyAvailable } catch { $interactive = $false }
    if (-not $interactive) {
        Set-KnxTestSkip "needs an operator step but no interactive console is attached: $Instruction"
    }

    Write-Host ''
    Write-Host '  +-- Handgriff noetig ------------------------------------------' -ForegroundColor Yellow
    Write-Host "  |  $Instruction" -ForegroundColor Yellow
    if ($Detail) { Write-Host "  |  $Detail" -ForegroundColor DarkGray }
    Write-Host '  |  ENTER = erledigt   S = diesen Fall ueberspringen' -ForegroundColor DarkGray
    Write-Host '  +--------------------------------------------------------------' -ForegroundColor Yellow

    $deadline = if ($TimeoutSeconds -gt 0) { [DateTime]::UtcNow.AddSeconds($TimeoutSeconds) } else { [DateTime]::MaxValue }
    $lastShown = -1
    while ([DateTime]::UtcNow -lt $deadline) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'Enter') {
                Write-Host ''
                Add-KnxEvidence -Note "operator confirmed: $Instruction"
                return $true
            }
            if ("$($key.KeyChar)".ToLower() -eq 's') {
                Write-Host ''
                Set-KnxTestSkip "operator skipped the step: $Instruction"
            }
        }
        if ($TimeoutSeconds -gt 0) {
            $left = [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalSeconds)
            if ($left -ne $lastShown) {
                $lastShown = $left
                Write-Host ("`r  >  warte auf ENTER ... {0,3}s " -f $left) -NoNewline -ForegroundColor DarkGray
            }
        }
        Start-Sleep -Milliseconds 200
    }
    Write-Host ''
    Set-KnxTestSkip "no answer within $TimeoutSeconds s - the step was not carried out: $Instruction"
}

function Set-KnxTestSkip {
    <#
    .SYNOPSIS
        Ends the current test case as SKIP with a mandatory reason.
    #>
    param([Parameter(Mandatory)][string]$Reason)
    throw "KNXTEST_SKIP::$Reason"
}

function Set-KnxTestNotRun {
    <#
    .SYNOPSIS
        Ends the case as NOT-RUN: an input the rig was supposed to supply is missing.
    .DESCRIPTION
        Three different things used to end up in one SKIP bucket: the device does not have the feature
        (N-A, correct and nobody's fault), a safety gate refused (dropped), and the run was started
        without an argument the case needs (this). Only the last one is a gap in the RUN, and a report
        that cannot tell them apart says "passed" over work it never did.
    .PARAMETER MissingInput
        The argument that was missing, spelled as the operator would pass it: -TestGa, -WitnessIp,
        -Guided, -IncludeDestructive, -TrafficIp, -BdutPa. It is named in the report so the next run
        can be complete. NOT called -Input: that is an automatic variable in PowerShell, and a
        parameter of that name binds to nothing - the report then showed an empty column.
    #>
    param([Parameter(Mandatory)][string]$MissingInput, [Parameter(Mandatory)][string]$Reason)
    throw "KNXTEST_NOTRUN::${MissingInput}::$Reason"
}

function Add-KnxRunDropped {
    <#
    .SYNOPSIS
        Records that a whole suite was dropped before it ran, and why.
    .DESCRIPTION
        A suite the runner refuses to start - the routing cases on the production multicast group are
        the standing example - leaves no cases behind, so nothing in the results shows it is missing.
        Recorded here, it appears in the report instead of being invisible: a router run whose section 6
        never ran still read "conformance PASS".
    #>
    param([Parameter(Mandatory)][string]$Suite, [Parameter(Mandatory)][string]$Reason)
    if ($null -eq $script:Run) { return }
    if ($null -eq $script:Run.PSObject.Properties['Dropped']) {
        Add-Member -InputObject $script:Run -NotePropertyName 'Dropped' -NotePropertyValue (New-Object System.Collections.ArrayList) -Force
    }
    [void]$script:Run.Dropped.Add([pscustomobject]@{ Suite = $Suite; Reason = $Reason })
}

function Set-KnxTestNotApplicable {
    <#
    .SYNOPSIS
        Ends the current test case as N-A with a mandatory reason.
    #>
    param([Parameter(Mandatory)][string]$Reason)
    throw "KNXTEST_NA::$Reason"
}

$script:KnxCaseFilter = @()

function Sync-KnxTunnel {
    <#
    .SYNOPSIS
        Takes everything the device has pushed into a tunnel and acknowledges it.
    .DESCRIPTION
        A tunnel client that leaves a TUNNELLING_REQUEST unacknowledged loses its connection: the server
        repeats the frame once and then sends DISCONNECT_REQUEST (03_08_04 2.6.1 p.9), which takes about
        two seconds on a live bus. Three probes in one session read that teardown as a device defect
        (T.30, T.32, T.33), so anything that waits on a tunnel calls this instead of sitting silent.
    .OUTPUTS
        Frames: a VIEW of the cEMI payloads seen, in arrival order - the frames themselves stay parked on
        the connection for Receive-KnxTunnelCemi or for an explicit Read-KnxTunnelParked, so a caller that
        discards this result loses nothing. Reading both is therefore reading the same frames twice.
        Disconnected: the channel was torn down; Disconnect carries the datagram when one was seen.
    #>
    param([Parameter(Mandatory)]$Connection, [int]$Ms = 800)
    # A closed connection has no socket: report it as gone instead of throwing a parameter-binding
    # error out of the case.
    if ($null -eq $Connection -or $null -eq $Connection.Socket) {
        return [pscustomobject]@{ Frames = @(); Disconnected = $true; Disconnect = $null; Dropped = 0; Repeats = 0 }
    }
    $frames = @()
    $disconnected = $false
    $disconnectPacket = $null
    $deadline = [DateTime]::UtcNow.AddMilliseconds($Ms)
    while ([DateTime]::UtcNow -lt $deadline) {
        # A channel that has been torn down - by either side - is not something to wait on. The record
        # carries who ended it and the datagram, where one was seen, so a case can report both.
        # Only the DEVICE ending the channel stops a paced wait. A teardown this client sent is recorded
        # too, and treating that as "done" turned every later wait on the object into a no-op - the
        # pacing a case needs then vanishes and the device is blamed for the lost timing.
        if ((Test-KnxTunnelGone -Connection $Connection) -and (Get-KnxTunnelGoneBy -Connection $Connection) -eq 'device') {
            $disconnected = $true
            if ($null -ne $Connection.PSObject.Properties['DisconnectPacket']) { $disconnectPacket = $Connection.DisconnectPacket }
            break
        }
        $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
        # The heartbeat blocks for its own answer, so it must not be given longer than this call has.
        $parkedBefore = 0
        if ($null -ne $Connection.PSObject.Properties['Pending']) { $parkedBefore = $Connection.Pending.Count }
        [void](Update-KnxTunnelHeartbeat -Connection $Connection -TimeoutMs ([Math]::Min(1500, $left)))
        # Whatever the heartbeat caught belongs in this call's view too. Without this, Frames reported
        # the same traffic or not depending on whether 45 s had elapsed - the same function answering
        # differently by the clock. The frames stay parked either way; this is a view, not a removal.
        if ($null -ne $Connection.PSObject.Properties['Pending']) {
            # Only the tail that grew. At the cap the queue evicts as it appends, so an index walk from
            # the old count finds nothing - the heartbeat's frames are then reported by the count of
            # what it parked, which Update-KnxTunnelHeartbeat returns through the connection.
            for ($i = $parkedBefore; $i -lt $Connection.Pending.Count; $i++) {
                $rec = $Connection.Pending[$i]
                if ($null -ne $rec) { $frames += , ([byte[]]$rec.Cemi) }
            }
        }
        # Frames the heartbeat caught are acknowledged and parked for Receive-KnxTunnelCemi. This is a
        # pump, not a consumer: it does not take them out, or a paced wait would eat the confirmation a
        # case is about to read. A capture drains the queue itself with Read-KnxTunnelParked.
        if ((Test-KnxTunnelGone -Connection $Connection) -and (Get-KnxTunnelGoneBy -Connection $Connection) -eq 'device') {
            $disconnected = $true
            if ($null -ne $Connection.PSObject.Properties['DisconnectPacket']) { $disconnectPacket = $Connection.DisconnectPacket }
            break
        }
        $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
        $r = Wait-KnxService -Socket $Connection.Socket -TimeoutMs $left `
                             -Service @($script:KnxService.TUNNELLING_REQUEST, $script:KnxService.DISCONNECT_REQUEST)
        if ($r.TimedOut) { break }
        if ($r.Header.Service -eq $script:KnxService.DISCONNECT_REQUEST) {
            # 03_08_02 5.5.2: the client answers it. Every other path in this module does; staying silent
            # here made the device repeat the teardown and the close below wait out its whole timeout.
            if ($r.Header.Body.Length -ge 1) {
                Send-KnxFrame -Socket $Connection.Socket -Frame (New-KnxDisconnectResponse -Channel $r.Header.Body[0] -Status 0) `
                              -Ip $Connection.Ip -Port $Connection.Port
            }
            Set-KnxTunnelGone -Connection $Connection -By 'device' -Packet $r
            $disconnected = $true; $disconnectPacket = $r; break
        }
        # Guarded and filtered like every sibling: a body shorter than the connection header would throw
        # out of here as an unhandled error instead of a result, and a frame for another channel is not
        # ours to acknowledge or to report as traffic on this one.
        if ($r.Header.Body.Length -lt 4 -or $r.Header.Body[1] -ne $Connection.Channel) { continue }
        Send-KnxFrame -Socket $Connection.Socket -Frame (New-KnxTunnellingAck -Channel $r.Header.Body[1] -Sequence $r.Header.Body[2]) `
                      -Ip $Connection.Ip -Port $Connection.Port
        $Connection.SeqRecv = $r.Header.Body[2]
        $inCemi = if ($r.Header.Body.Length -gt 4) { [byte[]]$r.Header.Body[4..($r.Header.Body.Length - 1)] } else { [byte[]]@() }
        # Parked, not consumed. Taking a frame off the socket, acknowledging it and then handing it only
        # to the return value destroys it for every caller that discards that value - and most of them do
        # ([void](Wait-KnxTunnel ...) as a paced wait), which is how a drain right afterwards found
        # nothing and a case reported the device for a frame this function had eaten.
        # Count it in the view only when the queue actually took it: a repeat with the same sequence is
        # suppressed there (03_08_04 2.6.1), and counting it here would put the duplicate back into the
        # very report the suppression exists for.
        # The queue says whether it took it. Comparing counts could not: at the cap one is evicted and
        # one appended, so an accepted frame looked exactly like a suppressed repeat and every frame
        # after the 256th vanished from this view while still being acknowledged and parked.
        $took = Add-KnxTunnelParked -Connection $Connection -Channel $r.Header.Body[1] -Sequence $r.Header.Body[2] `
                                    -Cemi $inCemi -Raw $r.Packet.Bytes -Ignored $r.Ignored
        if ($took) { $frames += , $inCemi }
    }
    $dropped = 0
    if ($null -ne $Connection.PSObject.Properties['PendingDropped']) { $dropped = [int]$Connection.PendingDropped }
    # Repeats the queue suppressed (03_08_04 2.6.1). Reported next to Dropped so a case can tell
    # "the device sent nothing" from "the device sent the same frame twice".
    $repeats = 0
    if ($null -ne $Connection.PSObject.Properties['PendingRepeats']) { $repeats = [int]$Connection.PendingRepeats }
    return [pscustomobject]@{ Frames = $frames; Disconnected = $disconnected; Disconnect = $disconnectPacket; Dropped = $dropped; Repeats = $repeats }
}

function Wait-KnxTunnel {
    <#
    .SYNOPSIS
        Waits a fixed time on an open tunnel while acknowledging everything that arrives.
    .DESCRIPTION
        Start-Sleep on an open tunnel costs the tunnel as soon as the bus carries traffic: the device
        pushes indications the sleeping client does not acknowledge, repeats the head once and ends the
        connection (03_08_04 2.6.1 p.9). Measured on 11.11.0.126 with a group telegram every 120 ms -
        800 ms of Start-Sleep lost the tunnel in 2 of 4 runs, 800 ms of reading and acknowledging in 0 of
        4. Unlike Sync-KnxTunnel this always waits the whole time, so it can replace a sleep that a case
        needs for its timing.
    .OUTPUTS
        The same shape as Sync-KnxTunnel: Frames, Disconnected, Disconnect.
    #>
    param([Parameter(Mandatory)]$Connection, [Parameter(Mandatory)][int]$Ms)
    $frames = @()
    $disconnected = $false
    $disconnectPacket = $null
    $deadline = [DateTime]::UtcNow.AddMilliseconds($Ms)
    while ([DateTime]::UtcNow -lt $deadline) {
        $r = Sync-KnxTunnel -Connection $Connection -Ms ([int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)))
        $frames += $r.Frames
        if ($r.Disconnected) { $disconnected = $true; $disconnectPacket = $r.Disconnect; break }
    }
    $dropped = 0
    if ($null -ne $Connection.PSObject.Properties['PendingDropped']) { $dropped = [int]$Connection.PendingDropped }
    # Repeats the queue suppressed (03_08_04 2.6.1). Reported next to Dropped so a case can tell
    # "the device sent nothing" from "the device sent the same frame twice".
    $repeats = 0
    if ($null -ne $Connection.PSObject.Properties['PendingRepeats']) { $repeats = [int]$Connection.PendingRepeats }
    return [pscustomobject]@{ Frames = $frames; Disconnected = $disconnected; Disconnect = $disconnectPacket; Dropped = $dropped; Repeats = $repeats }
}

function Set-KnxCaseFilter {
    <#
    .SYNOPSIS
        Restricts a run to the case ids matching these wildcard patterns.
    .DESCRIPTION
        An empty list runs everything, which is the default. A case that does not match is not executed
        and does not appear in the report at all - a targeted run should not claim coverage it skipped.
    #>
    param([string[]]$Pattern = @())
    $script:KnxCaseFilter = @($Pattern | Where-Object { $_ })
}

function Test-KnxCaseSelected {
    <#
    .SYNOPSIS
        True when no filter is set or the id matches one of its patterns.
    #>
    param([Parameter(Mandatory)][string]$Id)
    if (-not $script:KnxCaseFilter -or $script:KnxCaseFilter.Count -eq 0) { return $true }
    foreach ($p in $script:KnxCaseFilter) { if ($Id -like $p) { return $true } }
    return $false
}

function Invoke-KnxTestCase {
    <#
    .SYNOPSIS
        Runs one test case, captures its result and evidence, and records it in the run.
    .DESCRIPTION
        The body decides the result by what it throws: an Assert-* failure = FAIL,
        Set-KnxTestSkip = SKIP, Set-KnxTestNotApplicable = N-A, Set-KnxTestNotRun = NOT-RUN.
        Nothing thrown is PASS only if at least one assertion ran, otherwise NO-PROOF. An
        unexpected exception is a FAIL with the exception text - a test harness must never swallow one.
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
    if (-not (Test-KnxCaseSelected -Id $Id)) { return }

    $script:Evidence = [pscustomobject]@{
        Sent = $null; Expected = $null; Received = $null
        Notes = (New-Object System.Collections.ArrayList)
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = 'PASS'; $reason = ''; $missing = ''
    # Counted from zero for this case only. A value left over from the previous one would let a case
    # that asserts nothing inherit its predecessor's proof.
    $script:KnxAssertions = 0
    try {
        & $Body
    }
    catch {
        $msg = "$($_.Exception.Message)"
        if     ($msg -like 'KNXTEST_SKIP::*') { $result = 'SKIP'; $reason = $msg.Substring(14) }
        elseif ($msg -like 'KNXTEST_NA::*')   { $result = 'N-A';  $reason = $msg.Substring(12) }
        elseif ($msg -like 'KNXTEST_NOTRUN::*') {
            $result = 'NOT-RUN'
            $rest = $msg.Substring(16)   # 'KNXTEST_NOTRUN::' is 16 characters
            $cut = $rest.IndexOf('::')
            if ($cut -ge 0) { $missing = $rest.Substring(0, $cut); $reason = $rest.Substring($cut + 2) }
            else            { $reason = $rest }
        }
        elseif ($msg -like 'KNXTEST_FAIL::*') { $result = 'FAIL'; $reason = $msg.Substring(14) }
        else {
            # Only this branch is touched: the sentinels above carry reasons that the report and the
            # reference comparison match on. Without the position an "unhandled error" cannot be
            # diagnosed from the report at all - a bare "The property 'Length' cannot be found on
            # this object" appeared in 16 cases at once and named neither file nor line.
            $result = 'FAIL'
            $where = ''
            $inv = $_.InvocationInfo
            if ($null -ne $inv -and $inv.ScriptLineNumber -gt 0) {
                $file = if ($inv.ScriptName) { Split-Path -Leaf $inv.ScriptName } else { 'inline' }
                $where = ' [' + $file + ':' + $inv.ScriptLineNumber + ']'
            }
            $reason = "unhandled error: $msg$where"
        }
    }
    $sw.Stop()
    $assertions = [int]$script:KnxAssertions
    # A body that ran to the end without putting a single requirement to the device has not passed
    # anything - it has said nothing. Only on the normal-completion path: SKIP, N-A, NOT-RUN and FAIL
    # all arrive by a throw and keep their result, and a FAIL is itself an assertion that was raised.
    if ($result -eq 'PASS' -and $assertions -eq 0) {
        $result = 'NO-PROOF'
        $reason = 'the case body ran to the end without raising an assertion'
    }

    $evSent = ''; $evExpected = ''; $evReceived = ''
    if ($null -ne $script:Evidence.Sent)     { $evSent     = ConvertTo-HexString -Bytes $script:Evidence.Sent -MaxBytes 64 }
    if ($null -ne $script:Evidence.Expected) { $evExpected = ConvertTo-HexString -Bytes $script:Evidence.Expected -MaxBytes 64 }
    if ($null -ne $script:Evidence.Received) { $evReceived = ConvertTo-HexString -Bytes $script:Evidence.Received -MaxBytes 64 }

    $res = [pscustomobject]@{
        Id       = $Id
        Suite    = $Suite
        Title    = $Title
        Clause   = $Clause
        Result   = $result
        Reason   = $reason
        # The argument the run did not supply, for NOT-RUN. Empty everywhere else.
        Missing  = $missing
        # Assertions the case raised. Zero on a body that completed is what makes it NO-PROOF.
        Assertions = $assertions
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
    # object would be formatted onto the console after every single result line.
}

function Write-KnxResultLine {
    <#
    .SYNOPSIS
        Prints one aligned, colour-coded result line.
    #>
    param([Parameter(Mandatory)]$Case)
    $col = switch ($Case.Result) {
        'PASS' { 'Green' }
        'FAIL' { 'Red' }
        'SKIP' { 'Yellow' }
        'NOT-RUN' { 'Magenta' }
        'NO-PROOF' { 'DarkYellow' }
        'N-A'  { 'DarkGray' }
        default { 'Gray' }
    }
    $id = $Case.Id.PadRight(10)
    # NO-PROOF is the longest result; a narrower pad put the title of every other line one column left.
    $vd = $Case.Result.PadRight(8)
    Write-Host ("  {0} {1} " -f $id, $vd) -ForegroundColor $col -NoNewline
    Write-Host $Case.Title -ForegroundColor Gray -NoNewline
    if ($Case.Reason) { Write-Host ("  -- " + $Case.Reason) -ForegroundColor $col } else { Write-Host '' }
}

function Get-KnxRunSummary {
    <#
    .SYNOPSIS
        Counts results of the current run.
    #>
    param($Run = $null)
    if ($null -eq $Run) { $Run = $script:Run }
    $c = @{ PASS = 0; FAIL = 0; SKIP = 0; 'NOT-RUN' = 0; 'NO-PROOF' = 0; 'N-A' = 0 }
    foreach ($r in $Run.Results) {
        if ($c.ContainsKey($r.Result)) { $c[$r.Result] = $c[$r.Result] + 1 }
        else { $c[$r.Result] = 1 }
    }
    $dropped = 0
    if ($null -ne $Run.PSObject.Properties['Dropped']) { $dropped = $Run.Dropped.Count }
    # Judged is the number the run may claim. Everything else is named for what it is: the device does
    # not have it (NA), the run did not supply what it needs (NotRun), a gate refused it (Dropped), or
    # the case ran and asserted nothing (NoProof) - which is not a statement about the device either.
    return [pscustomobject]@{
        Total   = $Run.Results.Count
        Pass    = $c.PASS
        Fail    = $c.FAIL
        Skip    = $c.SKIP
        NotRun  = $c.'NOT-RUN'
        NoProof = $c.'NO-PROOF'
        NA      = $c.'N-A'
        Dropped = $dropped
        Judged  = ($c.PASS + $c.FAIL)
    }
}

function Write-KnxRunSummary {
    <#
    .SYNOPSIS
        Prints the result counts of a run, with the same buckets the Markdown table and the JSON carry.
    .DESCRIPTION
        One place for the summary line, so the console cannot silently disagree with the report. Every
        caller printed its own line, and each of them left out a bucket: a run whose section 6 was
        dropped and a run that ran everything printed the same green heading. Dropped suites and the
        cases that asserted nothing are named here, not only in the file.
    #>
    param($Run = $null, [string]$Indent = '  ')
    if ($null -eq $Run) { $Run = $script:Run }
    if ($null -eq $Run) { return }
    $sum = Get-KnxRunSummary -Run $Run
    Write-Host ("{0}Total {1}   " -f $Indent, $sum.Total) -NoNewline
    Write-Host ("PASS {0}  " -f $sum.Pass) -ForegroundColor Green -NoNewline
    Write-Host ("FAIL {0}  " -f $sum.Fail) -ForegroundColor $(if ($sum.Fail -gt 0) { 'Red' } else { 'DarkGray' }) -NoNewline
    Write-Host ("SKIP {0}  " -f $sum.Skip) -ForegroundColor Yellow -NoNewline
    Write-Host ("NOT-RUN {0}  " -f $sum.NotRun) -ForegroundColor $(if ($sum.NotRun -gt 0) { 'Magenta' } else { 'DarkGray' }) -NoNewline
    Write-Host ("NO-PROOF {0}  " -f $sum.NoProof) -ForegroundColor $(if ($sum.NoProof -gt 0) { 'DarkYellow' } else { 'DarkGray' }) -NoNewline
    Write-Host ("N-A {0}  " -f $sum.NA) -ForegroundColor DarkGray -NoNewline
    Write-Host ("Dropped {0}" -f $sum.Dropped) -ForegroundColor $(if ($sum.Dropped -gt 0) { 'Red' } else { 'DarkGray' })
    Write-Host ("{0}Judged {1} of {2}." -f $Indent, $sum.Judged, $sum.Total) -ForegroundColor DarkGray
    Write-KnxRunGaps -Run $Run -Indent $Indent
}

function Write-KnxRunGaps {
    <#
    .SYNOPSIS
        Names the suites a run refused to start and the cases that raised no assertion.
    .DESCRIPTION
        Both are invisible in a result list - a dropped suite leaves no cases behind at all - and a
        green heading over a section that never ran is what a reader takes away from the console.
    #>
    param($Run = $null, [string]$Indent = '  ')
    if ($null -eq $Run) { $Run = $script:Run }
    if ($null -eq $Run) { return }
    if ($null -ne $Run.PSObject.Properties['Dropped']) {
        foreach ($d in @($Run.Dropped)) {
            Write-Host ("{0}DROPPED suite {1}: {2}" -f $Indent, $d.Suite, $d.Reason) -ForegroundColor Red
        }
    }
    $noProof = @($Run.Results | Where-Object { $_.Result -eq 'NO-PROOF' })
    foreach ($n in $noProof) {
        Write-Host ("{0}NO-PROOF {1}: {2}" -f $Indent, $n.Id, $n.Title) -ForegroundColor DarkYellow
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
    [void]$md.AppendLine('| Total | PASS | FAIL | SKIP | NOT-RUN | NO-PROOF | N-A | Suites dropped |')
    [void]$md.AppendLine('|---|---|---|---|---|---|---|---|')
    [void]$md.AppendLine("| $($sum.Total) | $($sum.Pass) | $($sum.Fail) | $($sum.Skip) | $($sum.NotRun) | $($sum.NoProof) | $($sum.NA) | $($sum.Dropped) |")
    [void]$md.AppendLine('')
    # What the run may claim, stated before the tables: "everything passed" is worth nothing
    # without "and this much was actually judged".
    $coverPct = if ($sum.Total -gt 0) { [int](100 * $sum.Judged / $sum.Total) } else { 0 }
    [void]$md.AppendLine("**Judged: $($sum.Judged) of $($sum.Total) cases ($coverPct %).** The rest was not a result about this device.")
    [void]$md.AppendLine('')
    # Anyone reading this report for the first time needs to know what the words mean before the
    # tables make sense - above all that SKIP, NOT-RUN and N-A are not softer failures.
    [void]$md.AppendLine('PASS - the device did what the specification requires.  ')
    [void]$md.AppendLine('FAIL - it did not. The reason and the bytes are further down.  ')
    [void]$md.AppendLine('NOT-RUN - the RUN was missing an input the case needs. A gap in this run, not in the device.  ')
    [void]$md.AppendLine('NO-PROOF - the case ran to the end and raised no assertion. It says nothing about the device, and it is not counted as judged.  ')
    [void]$md.AppendLine('SKIP - the case chose not to run for a reason of its own, named per case.  ')
    [void]$md.AppendLine('N-A - the requirement does not apply to this device, and why.')
    [void]$md.AppendLine('')

    # Everything the run did NOT judge, and what it would take to judge it. This is the section that
    # turns "all that ran passed" into a statement somebody can act on.
    $notRun = @($Run.Results | Where-Object { $_.Result -eq 'NOT-RUN' })
    $noProof = @($Run.Results | Where-Object { $_.Result -eq 'NO-PROOF' })
    $droppedSuites = @()
    if ($null -ne $Run.PSObject.Properties['Dropped']) { $droppedSuites = @($Run.Dropped) }
    if ($notRun.Count -gt 0 -or $droppedSuites.Count -gt 0 -or $noProof.Count -gt 0) {
        [void]$md.AppendLine('## What this run did not judge')
        [void]$md.AppendLine('')
        if ($noProof.Count -gt 0) {
            [void]$md.AppendLine('Cases that ran to the end without raising an assertion:')
            [void]$md.AppendLine('')
            [void]$md.AppendLine('| ID | Test case | Specification |')
            [void]$md.AppendLine('|---|---|---|')
            foreach ($n in $noProof) { [void]$md.AppendLine("| ``$($n.Id)`` | $($n.Title) | $($n.Clause) |") }
            [void]$md.AppendLine('')
        }
        if ($droppedSuites.Count -gt 0) {
            [void]$md.AppendLine('Whole suites the runner refused to start:')
            [void]$md.AppendLine('')
            foreach ($d in $droppedSuites) { [void]$md.AppendLine("* **$($d.Suite)** - $($d.Reason)") }
            [void]$md.AppendLine('')
        }
        if ($notRun.Count -gt 0) {
            [void]$md.AppendLine('Cases that need an input this run did not have:')
            [void]$md.AppendLine('')
            [void]$md.AppendLine('| Missing | Cases | What they would have judged |')
            [void]$md.AppendLine('|---|---|---|')
            foreach ($g in ($notRun | Group-Object -Property Missing | Sort-Object Name)) {
                $ids = (@($g.Group | ForEach-Object { $_.Id }) -join ', ')
                $what = ($g.Group[0].Reason -replace '\|', '\|')
                [void]$md.AppendLine("| ``$($g.Name)`` | $($g.Count) - $ids | $what |")
            }
            [void]$md.AppendLine('')
        }
    }

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

    $droppedOut = @()
    if ($null -ne $Run.PSObject.Properties['Dropped']) { $droppedOut = @($Run.Dropped) }
    $payload = [pscustomobject]@{
        product     = $Run.Product
        bdut        = $Run.BdutIp
        dropped     = $droppedOut
        profile     = $Run.Profile
        started     = $Run.Started.ToString('o')
        finished    = $Run.Finished.ToString('o')
        environment = $Run.Environment
        summary     = $sum
        results     = @($Run.Results)
    }
    $payload | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonPath -Encoding UTF8

    # The gaps are NOT printed here: every caller calls Write-KnxRunSummary, which ends in Write-KnxRunGaps;
    # printing them here too would show every "DROPPED suite ..." and "NO-PROOF <id>" line twice.
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
        A suite that builds wrong frames produces wrong results, and a wrong PASS is worse
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

    # Network layer ----------------------------------------------------------
    # 03_02_02 2.2.2 p.26: CTRL bit7 FT - 1 standard, 0 extended. A standard frame's length field is
    # four bits, so an APDU above 15 octets MUST be sent as an extended frame. Getting this wrong made
    # every request longer than 15 octets vanish without a trace.
    Add-Vector 'L_Data.req standard frame, 15 octet APDU' `
        (New-CemiLData -MessageCode 0x11 -Destination 0x1101 -Tpdu ([byte[]](, 0x00 * 16)) -Priority 0 -HopCount 6) `
        '1100 B060 0000 1101 0F 00000000000000000000000000000000'
    Add-Vector 'L_Data.req extended frame, 16 octet APDU' `
        (New-CemiLData -MessageCode 0x11 -Destination 0x1101 -Tpdu ([byte[]](, 0x00 * 17)) -Priority 0 -HopCount 6) `
        '1100 3060 0000 1101 10 0000000000000000000000000000000000'
    # 08_03_03 needs any routing counter 0..7 on the wire; it lands in ctrl2 bits 6..4.
    Add-Vector 'L_Data.req routing counter 7' `
        (New-CemiLData -MessageCode 0x11 -Destination 0x1101 -Tpdu ([byte[]]@(0x00, 0x00)) -Priority 0 -HopCount 7) `
        '1100 B070 0000 1101 01 0000'
    Add-Vector 'L_Data.req routing counter 0' `
        (New-CemiLData -MessageCode 0x11 -Destination 0x1101 -Tpdu ([byte[]]@(0x00, 0x00)) -Priority 0 -HopCount 0) `
        '1100 B000 0000 1101 01 0000'

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

    # The 4-bit field must refuse 16, not mask it to 0: the silent mask produced two phantom
    # findings (a device rejecting a zero-element request was read as a device defect).
    $threwCount = $false
    try { [void](New-CemiMPropRead -ObjectType 11 -ObjectInstance 1 -PropertyId 53 -ElementCount 16 -StartIndex 1) }
    catch { $threwCount = $true }
    Add-Vector 'cEMI M_PropRead.req refuses elem 16 (4-bit field)' `
        ([byte[]]@($(if ($threwCount) { 1 } else { 0 }))) '01'

    $threwIndex = $false
    try { [void](New-CemiMPropRead -ObjectType 11 -ObjectInstance 1 -PropertyId 53 -ElementCount 1 -StartIndex 4096) }
    catch { $threwIndex = $true }
    Add-Vector 'cEMI M_PropRead.req refuses start index 4096 (12-bit field)' `
        ([byte[]]@($(if ($threwIndex) { 1 } else { 0 }))) '01'

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
