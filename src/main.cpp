#include "OpenKNX.h"


#include "NetworkModule.h"
#include "IPRouterModule.h"
#ifdef ARDUINO_ARCH_RP2040
#include "UsbExchangeModule.h"
#include "FileTransferModule.h"
#pragma message "Pico Core Version: " ARDUINO_PICO_VERSION_STR 
#pragma message "ARDUINO VARIANT: " ARDUINO_VARIANT
#endif



bool core1_separate_stack = true;


void setup()
{
    const uint8_t firmwareRevision = 0;
    openknx.init(firmwareRevision);

    openknx.addModule(6, openknxIPRouterModule);
    openknx.addModule(7, openknxNetwork);
    #ifdef ARDUINO_ARCH_RP2040
    openknx.addModule(8, openknxUsbExchangeModule);
    openknx.addModule(9, openknxFileTransferModule);
    #endif

    if(!knx.configured())
    {
        openknx.ledFunctions.assignLed2Function(openknx.leds.getLed(OpenKNX::Led::LedType::LED_TYPE_INFO3), OPENKNX_LEDFUNC_BASE_KNX);
        openknx.ledFunctions.assignLed2Function(openknx.leds.getLed(OpenKNX::Led::LedType::LED_TYPE_INFO2), OPENKNX_LEDFUNC_NET_STATE);
    }
    
    openknx.setup();
}

uint32_t _showMem = 0;

void loop()
{
    openknx.loop();

    if (delayCheck(_showMem, 1000))
    {
        //openknx.console.showMemory();
        _showMem = millis();
    }
}


#ifdef OPENKNX_DUALCORE
void setup1()
{
    openknx.setup1();
}

void loop1()
{
    openknx.loop1();
    knx.bau().getSecondaryDataLinkLayer()->getTPUart().processReceviedByte();
    knx.bau().getSecondaryDataLinkLayer()->getTPUart().processReceviedByte();
    knx.bau().getSecondaryDataLinkLayer()->getTPUart().processTransmitByte();
}
#endif

/*
ToDos:
-------


BUGS
-------
- memleak apdu 3da 3db (??)


IMPROVEMENTS
-------

return false on send unicast in rp2040 plattform

"cache" router objekt properties? in programming mode, you could lock out yourseld in the middle of the programming. behaviour only should change after restart maybe?


PID_MEDIUM_STATUS (wenn kein TP1 / KNX => macht kein Sinn bei Busversorgt...)

- set PID_KNXNETIP_DEVICE_CAPABILITIES
- set PID_KNXNETIP_DEVICE_STATE 
    PID_QUEUE_OVERFLOW_TO_IP = 72,
    PID_QUEUE_OVERFLOW_TO_KNX = 73,
    PID_MSG_TRANSMIT_TO_IP = 74,
    PID_MSG_TRANSMIT_TO_KNX = 75,

ip data link layer send queue (priority queue?)

entladen => filtertabelle löschen, props auf default ?

- busmon tunnel support

knxprod:
system - multicast-adresse nutzen oder manuell einstellen

*/