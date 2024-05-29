#pragma once


#define paramDelay(time) (uint32_t)( \
            (time & 0xC000) == 0xC000 ? (time & 0x3FFF) * 100 : \
            (time & 0xC000) == 0x0000 ? (time & 0x3FFF) * 1000 : \
            (time & 0xC000) == 0x4000 ? (time & 0x3FFF) * 60000 : \
            (time & 0xC000) == 0x8000 ? ((time & 0x3FFF) > 1000 ? 3600000 : \
                                         (time & 0x3FFF) * 3600000 ) : 0 )
                                             
#define MAIN_OpenKnxId 0xA1
#define MAIN_ApplicationNumber 30
#define MAIN_ApplicationVersion 69
#define MAIN_ParameterSize 82
#define MAIN_MaxKoNumber 0
#define MAIN_OrderNumber "REG1-Eth"
#define BASE_ModuleVersion 17
#define NET_ModuleVersion 2
// Parameter with single occurrence


#define BASE_StartupDelayBase                     0      // 2 Bits, Bit 7-6
#define     BASE_StartupDelayBaseMask 0xC0
#define     BASE_StartupDelayBaseShift 6
#define BASE_StartupDelayTime                     0      // 14 Bits, Bit 13-0
#define     BASE_StartupDelayTimeMask 0x3FFF
#define     BASE_StartupDelayTimeShift 0
#define BASE_Watchdog                             5      // 1 Bit, Bit 6
#define     BASE_WatchdogMask 0x40
#define     BASE_WatchdogShift 6

// Zeitbasis
#define ParamBASE_StartupDelayBase                    ((knx.paramByte(BASE_StartupDelayBase) & BASE_StartupDelayBaseMask) >> BASE_StartupDelayBaseShift)
// Zeit
#define ParamBASE_StartupDelayTime                    (knx.paramWord(BASE_StartupDelayTime) & BASE_StartupDelayTimeMask)
// Zeit (in Millisekunden)
#define ParamBASE_StartupDelayTimeMS                  (paramDelay(knx.paramWord(BASE_StartupDelayTime)))
// Watchdog aktivieren
#define ParamBASE_Watchdog                            ((bool)(knx.paramByte(BASE_Watchdog) & BASE_WatchdogMask))

#define NET_HostAddress                          6      // IP address, 4 Byte
#define NET_SubnetMask                          10      // IP address, 4 Byte
#define NET_GatewayAddress                      14      // IP address, 4 Byte
#define NET_NameserverAddress                   18      // IP address, 4 Byte
#define NET_CustomHostname                      22      // 1 Bit, Bit 7
#define     NET_CustomHostnameMask 0x80
#define     NET_CustomHostnameShift 7
#define NET_StaticIP                            22      // 1 Bit, Bit 6
#define     NET_StaticIPMask 0x40
#define     NET_StaticIPShift 6
#define NET_mDNS                                23      // 1 Bit, Bit 7
#define     NET_mDNSMask 0x80
#define     NET_mDNSShift 7
#define NET_HTTP                                23      // 1 Bit, Bit 6
#define     NET_HTTPMask 0x40
#define     NET_HTTPShift 6
#define NET_NTP                                 23      // 1 Bit, Bit 5
#define     NET_NTPMask 0x20
#define     NET_NTPShift 5
#define NET_HostName                            24      // char*, 24 Byte
#define NET_LanMode                             65      // 4 Bits, Bit 7-4
#define     NET_LanModeMask 0xF0
#define     NET_LanModeShift 4
#define NET_Dummy                               81      // uint8_t

// IP-Adresse
#define ParamNET_HostAddress                         (knx.paramInt(NET_HostAddress))
// Subnetzsmaske
#define ParamNET_SubnetMask                          (knx.paramInt(NET_SubnetMask))
// Standardgateway
#define ParamNET_GatewayAddress                      (knx.paramInt(NET_GatewayAddress))
// Nameserver
#define ParamNET_NameserverAddress                   (knx.paramInt(NET_NameserverAddress))
// Hostname anpassen
#define ParamNET_CustomHostname                      ((bool)(knx.paramByte(NET_CustomHostname) & NET_CustomHostnameMask))
// DHCP
#define ParamNET_StaticIP                            ((bool)(knx.paramByte(NET_StaticIP) & NET_StaticIPMask))
// mDNS
#define ParamNET_mDNS                                ((bool)(knx.paramByte(NET_mDNS) & NET_mDNSMask))
// Weberver
#define ParamNET_HTTP                                ((bool)(knx.paramByte(NET_HTTP) & NET_HTTPMask))
// Zeitgeber (NTP)
#define ParamNET_NTP                                 ((bool)(knx.paramByte(NET_NTP) & NET_NTPMask))
// Hostname
#define ParamNET_HostName                            (knx.paramData(NET_HostName))
// LAN-Modus
#define ParamNET_LanMode                             ((knx.paramByte(NET_LanMode) & NET_LanModeMask) >> NET_LanModeShift)
// 
#define ParamNET_Dummy                               (knx.paramByte(NET_Dummy))

#define ROUTE_AckOfPhysTelSubMain                  0      // 2 Bits, Bit 7-6
#define     ROUTE_AckOfPhysTelSubMainMask 0xC0
#define     ROUTE_AckOfPhysTelSubMainShift 6
#define ROUTE_AckOfGrpTelSubMain                   0      // 1 Bit, Bit 5
#define     ROUTE_AckOfGrpTelSubMainMask 0x20
#define     ROUTE_AckOfGrpTelSubMainShift 5
#define ROUTE_BroadcastTelSubMain                  0      // 1 Bit, Bit 3
#define     ROUTE_BroadcastTelSubMainMask 0x08
#define     ROUTE_BroadcastTelSubMainShift 3
#define ROUTE_PhysTelSubMain                       0      // 2 Bits, Bit 1-0
#define     ROUTE_PhysTelSubMainMask 0x03
#define     ROUTE_PhysTelSubMainShift 0
#define ROUTE_GrpTelSubMain_14_31                  0      // 2 Bits, Bit 3-2
#define     ROUTE_GrpTelSubMain_14_31Mask 0x0C
#define     ROUTE_GrpTelSubMain_14_31Shift 2
#define ROUTE_GrpTelSubMain_0_13                   0      // 2 Bits, Bit 1-0
#define     ROUTE_GrpTelSubMain_0_13Mask 0x03
#define     ROUTE_GrpTelSubMain_0_13Shift 0
#define ROUTE_RepetitionBroadcastTelMainSub        0      // 1 Bit, Bit 4
#define     ROUTE_RepetitionBroadcastTelMainSubMask 0x10
#define     ROUTE_RepetitionBroadcastTelMainSubShift 4
#define ROUTE_BroadcastTelMainSub                  0      // 1 Bit, Bit 3
#define     ROUTE_BroadcastTelMainSubMask 0x08
#define     ROUTE_BroadcastTelMainSubShift 3
#define ROUTE_RepetitionPhysTelMainSub             0      // 1 Bit, Bit 2
#define     ROUTE_RepetitionPhysTelMainSubMask 0x04
#define     ROUTE_RepetitionPhysTelMainSubShift 2
#define ROUTE_PhysTelMainSub                       0      // 2 Bits, Bit 1-0
#define     ROUTE_PhysTelMainSubMask 0x03
#define     ROUTE_PhysTelMainSubShift 0
#define ROUTE_RepetitionGrpTelMainSub              0      // 1 Bit, Bit 4
#define     ROUTE_RepetitionGrpTelMainSubMask 0x10
#define     ROUTE_RepetitionGrpTelMainSubShift 4
#define ROUTE_GrpTelMainSub_14_31                  0      // 2 Bits, Bit 3-2
#define     ROUTE_GrpTelMainSub_14_31Mask 0x0C
#define     ROUTE_GrpTelMainSub_14_31Shift 2
#define ROUTE_GrpTelMainSub_0_13                   0      // 2 Bits, Bit 1-0
#define     ROUTE_GrpTelMainSub_0_13Mask 0x03
#define     ROUTE_GrpTelMainSub_0_13Shift 0

// Bestätigung (ACK) von phys. addressierten Telegrammen
#define ParamROUTE_AckOfPhysTelSubMain                 ((knx.paramByte(ROUTE_AckOfPhysTelSubMain) & ROUTE_AckOfPhysTelSubMainMask) >> ROUTE_AckOfPhysTelSubMainShift)
// Bestätigung (ACK) von Gruppentelegrammen
#define ParamROUTE_AckOfGrpTelSubMain                  ((bool)(knx.paramByte(ROUTE_AckOfGrpTelSubMain) & ROUTE_AckOfGrpTelSubMainMask))
// Broadcast Telegramme
#define ParamROUTE_BroadcastTelSubMain                 ((bool)(knx.paramByte(ROUTE_BroadcastTelSubMain) & ROUTE_BroadcastTelSubMainMask))
// Phys. addressierte Telegramme
#define ParamROUTE_PhysTelSubMain                      (knx.paramByte(ROUTE_PhysTelSubMain) & ROUTE_PhysTelSubMainMask)
// Gruppentelegramme (Hauptgruppe 14 - 31)
#define ParamROUTE_GrpTelSubMain_14_31                 ((knx.paramByte(ROUTE_GrpTelSubMain_14_31) & ROUTE_GrpTelSubMain_14_31Mask) >> ROUTE_GrpTelSubMain_14_31Shift)
// Gruppentelegramme (Hauptgruppe 0 - 13)
#define ParamROUTE_GrpTelSubMain_0_13                  (knx.paramByte(ROUTE_GrpTelSubMain_0_13) & ROUTE_GrpTelSubMain_0_13Mask)
// Wiederholung von Broadcast Telegrammen
#define ParamROUTE_RepetitionBroadcastTelMainSub       ((bool)(knx.paramByte(ROUTE_RepetitionBroadcastTelMainSub) & ROUTE_RepetitionBroadcastTelMainSubMask))
// Broadcast Telegramme
#define ParamROUTE_BroadcastTelMainSub                 ((bool)(knx.paramByte(ROUTE_BroadcastTelMainSub) & ROUTE_BroadcastTelMainSubMask))
// Wiederholung von phys. addressierten Telegrammen
#define ParamROUTE_RepetitionPhysTelMainSub            ((bool)(knx.paramByte(ROUTE_RepetitionPhysTelMainSub) & ROUTE_RepetitionPhysTelMainSubMask))
// Phys. addressierte Telegramme
#define ParamROUTE_PhysTelMainSub                      (knx.paramByte(ROUTE_PhysTelMainSub) & ROUTE_PhysTelMainSubMask)
// Wiederholung von Gruppentelegrammen
#define ParamROUTE_RepetitionGrpTelMainSub             ((bool)(knx.paramByte(ROUTE_RepetitionGrpTelMainSub) & ROUTE_RepetitionGrpTelMainSubMask))
// Gruppentelegramme (Hauptgruppe 14 - 31)
#define ParamROUTE_GrpTelMainSub_14_31                 ((knx.paramByte(ROUTE_GrpTelMainSub_14_31) & ROUTE_GrpTelMainSub_14_31Mask) >> ROUTE_GrpTelMainSub_14_31Shift)
// Gruppentelegramme (Hauptgruppe 0 - 13)
#define ParamROUTE_GrpTelMainSub_0_13                  (knx.paramByte(ROUTE_GrpTelMainSub_0_13) & ROUTE_GrpTelMainSub_0_13Mask)

#define ROUTE_ChannelCount 16

// Parameter per channel
#define ROUTE_ParamBlockOffset 0
#define ROUTE_ParamBlockSize -1
#define ROUTE_ParamCalcIndex(index) (index + ROUTE_ParamBlockOffset + _channelIndex * ROUTE_ParamBlockSize)

#define ROUTE_ResTunnel                            0      // 1 Bit, Bit 7
#define     ROUTE_ResTunnelMask 0x80
#define     ROUTE_ResTunnelShift 7
#define ROUTE_TunnelIP                             0      // IP address, 4 Byte
#define ROUTE_OptTunnel                            0      // 2 Bits, Bit 6-5
#define     ROUTE_OptTunnelMask 0x60
#define     ROUTE_OptTunnelShift 5

// Reserviere Tunnel %C%
#define ParamROUTE_ResTunnel                           ((bool)(knx.paramByte(ROUTE_ParamCalcIndex(ROUTE_ResTunnel)) & ROUTE_ResTunnelMask))
// IP-Adresse für Tunnel %C%
#define ParamROUTE_TunnelIP                            (knx.paramInt(ROUTE_ParamCalcIndex(ROUTE_TunnelIP)))
// Verhalten wenn Tunnel belegt
#define ParamROUTE_OptTunnel                           ((knx.paramByte(ROUTE_ParamCalcIndex(ROUTE_OptTunnel)) & ROUTE_OptTunnelMask) >> ROUTE_OptTunnelShift)



// Header generation for Module 'BASE_KommentarModule'

#define BASE_KommentarModuleCount 0
#define BASE_KommentarModuleModuleParamSize 0
#define BASE_KommentarModuleSubmodulesParamSize 0
#define BASE_KommentarModuleParamSize 0
#define BASE_KommentarModuleParamOffset 82
#define BASE_KommentarModuleCalcIndex(index, m1) (index + BASE_KommentarModuleParamOffset + _channelIndex * BASE_KommentarModuleCount * BASE_KommentarModuleParamSize + m1 * BASE_KommentarModuleParamSize)



