#pragma once


#define paramDelay(time) (uint32_t)( \
            (time & 0xC000) == 0xC000 ? (time & 0x3FFF) * 100 : \
            (time & 0xC000) == 0x0000 ? (time & 0x3FFF) * 1000 : \
            (time & 0xC000) == 0x4000 ? (time & 0x3FFF) * 60000 : \
            (time & 0xC000) == 0x8000 ? ((time & 0x3FFF) > 1000 ? 3600000 : \
                                         (time & 0x3FFF) * 3600000 ) : 0 )
                                             
#define ETS_ModuleId_NONE 0
#define ETS_ModuleId_BASE 1
#define ETS_ModuleId_NET 2
#define ETS_ModuleId_FTM 3
#define ETS_ModuleId_ROUTE 4
#define MAIN_FirmwareName "IP-Router (Dev)"
#define MAIN_OpenKnxId 0xA1
#define MAIN_ApplicationNumber 30
#define MAIN_ApplicationVersion 120
#define MAIN_FirmwareRevision 0
#define MAIN_ApplicationEncoding iso-8859-15
#define MAIN_ParameterSize 295
#define MAIN_MaxKoNumber 0
#define MAIN_OrderNumber "IP-Router"
#define BASE_ModuleVersion 25
#define NET_ModuleVersion 8
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
#define BASE_Info1LedFunc                         6      // 16 Bits, Bit 15-0
#define BASE_Info2LedFunc                         8      // 16 Bits, Bit 15-0
#define BASE_Info3LedFunc                        10      // 16 Bits, Bit 15-0
#define BASE_DefaultLedFunc                      12      // 1 Bit, Bit 7
#define     BASE_DefaultLedFuncMask 0x80
#define     BASE_DefaultLedFuncShift 7
#define BASE_Timezone                            13      // 5 Bits, Bit 7-3
#define     BASE_TimezoneMask 0xF8
#define     BASE_TimezoneShift 3
#define BASE_CombinedTimeDate                    13      // 1 Bit, Bit 2
#define     BASE_CombinedTimeDateMask 0x04
#define     BASE_CombinedTimeDateShift 2
#define BASE_SummertimeAll                       13      // 2 Bits, Bit 1-0
#define     BASE_SummertimeAllMask 0x03
#define     BASE_SummertimeAllShift 0
#define BASE_InternalTime                        13      // 1 Bit, Bit 0
#define     BASE_InternalTimeMask 0x01
#define     BASE_InternalTimeShift 0
#define BASE_TimezoneCustom                      14      // char*, 63 Byte
#define     BASE_TimezoneCustomLength 63

// Zeitbasis
#define ParamBASE_StartupDelayBase                    ((knx.paramByte(BASE_StartupDelayBase) & BASE_StartupDelayBaseMask) >> BASE_StartupDelayBaseShift)
// Zeit
#define ParamBASE_StartupDelayTime                    (knx.paramWord(BASE_StartupDelayTime) & BASE_StartupDelayTimeMask)
// Zeit (in Millisekunden)
#define ParamBASE_StartupDelayTimeMS                  (paramDelay(knx.paramWord(BASE_StartupDelayTime)))
// Watchdog aktivieren
#define ParamBASE_Watchdog                            ((bool)(knx.paramByte(BASE_Watchdog) & BASE_WatchdogMask))
// Info1 (KNX-IP)
#define ParamBASE_Info1LedFunc                        (knx.paramWord(BASE_Info1LedFunc))
// Info2 (IP)
#define ParamBASE_Info2LedFunc                        (knx.paramWord(BASE_Info2LedFunc))
// Info3 (KNX)
#define ParamBASE_Info3LedFunc                        (knx.paramWord(BASE_Info3LedFunc))
// 
#define ParamBASE_DefaultLedFunc                      ((bool)(knx.paramByte(BASE_DefaultLedFunc) & BASE_DefaultLedFuncMask))
// Zeitzone
#define ParamBASE_Timezone                            ((knx.paramByte(BASE_Timezone) & BASE_TimezoneMask) >> BASE_TimezoneShift)
// Empfangen über
#define ParamBASE_CombinedTimeDate                    ((bool)(knx.paramByte(BASE_CombinedTimeDate) & BASE_CombinedTimeDateMask))
// Sommerzeit ermitteln durch
#define ParamBASE_SummertimeAll                       (knx.paramByte(BASE_SummertimeAll) & BASE_SummertimeAllMask)
// InternalTime
#define ParamBASE_InternalTime                        ((bool)(knx.paramByte(BASE_InternalTime) & BASE_InternalTimeMask))
// POSIX TZ-String
#define ParamBASE_TimezoneCustom                      (knx.paramData(BASE_TimezoneCustom))
#define ParamBASE_TimezoneCustomStr                   (knx.paramString(BASE_TimezoneCustom, BASE_TimezoneCustomLength))

#define NET_HostAddress                         78      // IP address, 4 Byte
#define NET_SubnetMask                          82      // IP address, 4 Byte
#define NET_GatewayAddress                      86      // IP address, 4 Byte
#define NET_NameserverAddress                   90      // IP address, 4 Byte
#define NET_CustomHostname                      94      // 1 Bit, Bit 7
#define     NET_CustomHostnameMask 0x80
#define     NET_CustomHostnameShift 7
#define NET_StaticIP                            94      // 1 Bit, Bit 6
#define     NET_StaticIPMask 0x40
#define     NET_StaticIPShift 6
#define NET_mDNS                                95      // 1 Bit, Bit 7
#define     NET_mDNSMask 0x80
#define     NET_mDNSShift 7
#define NET_HTTP                                95      // 1 Bit, Bit 6
#define     NET_HTTPMask 0x40
#define     NET_HTTPShift 6
#define NET_NTP                                 95      // 1 Bit, Bit 5
#define     NET_NTPMask 0x20
#define     NET_NTPShift 5
#define NET_OTAUpdate                           95      // 2 Bits, Bit 4-3
#define     NET_OTAUpdateMask 0x18
#define     NET_OTAUpdateShift 3
#define NET_MQTT                                95      // 1 Bit, Bit 2
#define     NET_MQTTMask 0x04
#define     NET_MQTTShift 2
#define NET_HostName                            96      // char*, 24 Byte
#define     NET_HostNameLength 24
#define NET_LanMode                             137      // 4 Bits, Bit 7-4
#define     NET_LanModeMask 0xF0
#define     NET_LanModeShift 4
#define NET_NTPServer                           138      // char*, 50 Byte
#define     NET_NTPServerLength 50
#define NET_MQTTServer                          189      // char*, 20 Byte
#define     NET_MQTTServerLength 20
#define NET_MQTTUsername                        210      // char*, 20 Byte
#define     NET_MQTTUsernameLength 20
#define NET_MQTTPassword                        231      // char*, 20 Byte
#define     NET_MQTTPasswordLength 20
#define NET_MQTTPrefix                          252      // char*, 20 Byte
#define     NET_MQTTPrefixLength 20
#define NET_MQTTPort                            273      // uint16_t
#define NET_MQTTTPRawData                       275      // 1 Bit, Bit 7
#define     NET_MQTTTPRawDataMask 0x80
#define     NET_MQTTTPRawDataShift 7
#define NET_MQTTMode                            275      // 1 Bit, Bit 6
#define     NET_MQTTModeMask 0x40
#define     NET_MQTTModeShift 6

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
// NTP-Client
#define ParamNET_NTP                                 ((bool)(knx.paramByte(NET_NTP) & NET_NTPMask))
// OTA-Update
#define ParamNET_OTAUpdate                           ((knx.paramByte(NET_OTAUpdate) & NET_OTAUpdateMask) >> NET_OTAUpdateShift)
// MQTT
#define ParamNET_MQTT                                ((bool)(knx.paramByte(NET_MQTT) & NET_MQTTMask))
// Hostname
#define ParamNET_HostName                            (knx.paramData(NET_HostName))
#define ParamNET_HostNameStr                         (knx.paramString(NET_HostName, NET_HostNameLength))
// LAN-Modus
#define ParamNET_LanMode                             ((knx.paramByte(NET_LanMode) & NET_LanModeMask) >> NET_LanModeShift)
// Zeitserver
#define ParamNET_NTPServer                           (knx.paramData(NET_NTPServer))
#define ParamNET_NTPServerStr                        (knx.paramString(NET_NTPServer, NET_NTPServerLength))
// Server
#define ParamNET_MQTTServer                          (knx.paramData(NET_MQTTServer))
#define ParamNET_MQTTServerStr                       (knx.paramString(NET_MQTTServer, NET_MQTTServerLength))
// Benutzer
#define ParamNET_MQTTUsername                        (knx.paramData(NET_MQTTUsername))
#define ParamNET_MQTTUsernameStr                     (knx.paramString(NET_MQTTUsername, NET_MQTTUsernameLength))
// Passwort
#define ParamNET_MQTTPassword                        (knx.paramData(NET_MQTTPassword))
#define ParamNET_MQTTPasswordStr                     (knx.paramString(NET_MQTTPassword, NET_MQTTPasswordLength))
// Prefix
#define ParamNET_MQTTPrefix                          (knx.paramData(NET_MQTTPrefix))
#define ParamNET_MQTTPrefixStr                       (knx.paramString(NET_MQTTPrefix, NET_MQTTPrefixLength))
// Port
#define ParamNET_MQTTPort                            (knx.paramWord(NET_MQTTPort))
// Sende KNX TP Rohdaten
#define ParamNET_MQTTTPRawData                       ((bool)(knx.paramByte(NET_MQTTTPRawData) & NET_MQTTTPRawDataMask))
// Modus
#define ParamNET_MQTTMode                            ((bool)(knx.paramByte(NET_MQTTMode) & NET_MQTTModeMask))

#define FTM_Security                            276      // 8 Bits, Bit 7-0
#define FTM_Password                            277      // char*, 16 Byte
#define     FTM_PasswordLength 16
#define FTM_AuthTimeout                         293      // uint16_t

// Zugriff
#define ParamFTM_Security                            (knx.paramByte(FTM_Security))
// Passwort
#define ParamFTM_Password                            (knx.paramData(FTM_Password))
#define ParamFTM_PasswordStr                         (knx.paramString(FTM_Password, FTM_PasswordLength))
// Abmeldung bei Leerlauf
#define ParamFTM_AuthTimeout                         (knx.paramWord(FTM_AuthTimeout))

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


// enumeration types


#ifdef MAIN_FirmwareRevision
#ifndef FIRMWARE_REVISION
#define FIRMWARE_REVISION MAIN_FirmwareRevision
#endif
#endif
#ifdef MAIN_FirmwareName
#ifndef FIRMWARE_NAME
#define FIRMWARE_NAME MAIN_FirmwareName
#endif
#endif
