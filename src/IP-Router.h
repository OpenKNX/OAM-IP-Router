#pragma once


#define paramDelay(time) (uint32_t)( \
            (time & 0xC000) == 0xC000 ? (time & 0x3FFF) * 100 : \
            (time & 0xC000) == 0x0000 ? (time & 0x3FFF) * 1000 : \
            (time & 0xC000) == 0x4000 ? (time & 0x3FFF) * 60000 : \
            (time & 0xC000) == 0x8000 ? ((time & 0x3FFF) > 1000 ? 3600000 : \
                                         (time & 0x3FFF) * 3600000 ) : 0 )
                                             
#define MAIN_OpenKnxId 0xA1
#define MAIN_ApplicationNumber 30
#define MAIN_ApplicationVersion 13
#define MAIN_ParameterSize 0
#define MAIN_MaxKoNumber 0
#define MAIN_OrderNumber "SYS-REG1-IP-Router"
// Parameter with single occurrence
#define AckOfPhysTelSubMain        0      // 2 Bits, Bit 7-6
#define     AckOfPhysTelSubMainMask 0xC0
#define     AckOfPhysTelSubMainShift 6
#define AckOfGrpTelSubMain         0      // 1 Bit, Bit 5
#define     AckOfGrpTelSubMainMask 0x20
#define     AckOfGrpTelSubMainShift 5
#define BroadcastTelSubMain        0      // 1 Bit, Bit 3
#define     BroadcastTelSubMainMask 0x08
#define     BroadcastTelSubMainShift 3
#define PhysTelSubMain             0      // 2 Bits, Bit 1-0
#define     PhysTelSubMainMask 0x03
#define     PhysTelSubMainShift 0
#define GrpTelSubMain_14_31        0      // 2 Bits, Bit 3-2
#define     GrpTelSubMain_14_31Mask 0x0C
#define     GrpTelSubMain_14_31Shift 2
#define GrpTelSubMain_0_13         0      // 2 Bits, Bit 1-0
#define     GrpTelSubMain_0_13Mask 0x03
#define     GrpTelSubMain_0_13Shift 0
#define RepetitionBroadcastTelMainSub  0      // 1 Bit, Bit 4
#define     RepetitionBroadcastTelMainSubMask 0x10
#define     RepetitionBroadcastTelMainSubShift 4
#define BroadcastTelMainSub        0      // 1 Bit, Bit 3
#define     BroadcastTelMainSubMask 0x08
#define     BroadcastTelMainSubShift 3
#define RepetitionPhysTelMainSub   0      // 1 Bit, Bit 2
#define     RepetitionPhysTelMainSubMask 0x04
#define     RepetitionPhysTelMainSubShift 2
#define PhysTelMainSub             0      // 2 Bits, Bit 1-0
#define     PhysTelMainSubMask 0x03
#define     PhysTelMainSubShift 0
#define RepetitionGrpTelMainSub    0      // 1 Bit, Bit 4
#define     RepetitionGrpTelMainSubMask 0x10
#define     RepetitionGrpTelMainSubShift 4
#define GrpTelMainSub_14_31        0      // 2 Bits, Bit 3-2
#define     GrpTelMainSub_14_31Mask 0x0C
#define     GrpTelMainSub_14_31Shift 2
#define GrpTelMainSub_0_13         0      // 2 Bits, Bit 1-0
#define     GrpTelMainSub_0_13Mask 0x03
#define     GrpTelMainSub_0_13Shift 0

// Acknowledge (ACK) of individual addressed telegrams
#define ParamAckOfPhysTelSubMain       ((knx.paramByte(AckOfPhysTelSubMain) & AckOfPhysTelSubMainMask) >> AckOfPhysTelSubMainShift)
// Acknowledge (ACK) of group telegrams
#define ParamAckOfGrpTelSubMain        ((bool)(knx.paramByte(AckOfGrpTelSubMain) & AckOfGrpTelSubMainMask))
// Broadcast telegrams
#define ParamBroadcastTelSubMain       ((bool)(knx.paramByte(BroadcastTelSubMain) & BroadcastTelSubMainMask))
// Individual addressed telegrams
#define ParamPhysTelSubMain            (knx.paramByte(PhysTelSubMain) & PhysTelSubMainMask)
// Group telegrams (main groups 14 to 31)
#define ParamGrpTelSubMain_14_31       ((knx.paramByte(GrpTelSubMain_14_31) & GrpTelSubMain_14_31Mask) >> GrpTelSubMain_14_31Shift)
// Group telegrams (main groups 0 to 13)
#define ParamGrpTelSubMain_0_13        (knx.paramByte(GrpTelSubMain_0_13) & GrpTelSubMain_0_13Mask)
// Repetition of broadcast telegrams
#define ParamRepetitionBroadcastTelMainSub ((bool)(knx.paramByte(RepetitionBroadcastTelMainSub) & RepetitionBroadcastTelMainSubMask))
// Broadcast telegrams
#define ParamBroadcastTelMainSub       ((bool)(knx.paramByte(BroadcastTelMainSub) & BroadcastTelMainSubMask))
// Repetition of individual addressed telegrams
#define ParamRepetitionPhysTelMainSub  ((bool)(knx.paramByte(RepetitionPhysTelMainSub) & RepetitionPhysTelMainSubMask))
// Individual addressed telegrams
#define ParamPhysTelMainSub            (knx.paramByte(PhysTelMainSub) & PhysTelMainSubMask)
// Repetition of group telegrams
#define ParamRepetitionGrpTelMainSub   ((bool)(knx.paramByte(RepetitionGrpTelMainSub) & RepetitionGrpTelMainSubMask))
// Group telegrams (main groups 14 to 31)
#define ParamGrpTelMainSub_14_31       ((knx.paramByte(GrpTelMainSub_14_31) & GrpTelMainSub_14_31Mask) >> GrpTelMainSub_14_31Shift)
// Group telegrams (main groups 0 to 13)
#define ParamGrpTelMainSub_0_13        (knx.paramByte(GrpTelMainSub_0_13) & GrpTelMainSub_0_13Mask)

