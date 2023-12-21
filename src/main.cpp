#include "OpenKNX.h"

#include "FileTransferModule.h"
#include "NetworkModule.h"
#include "UsbExchangeModule.h"

#pragma message "Pico Core Version: " ARDUINO_PICO_VERSION_STR 
#pragma message "ARDUINO VARIANT: " ARDUINO_VARIANT

bool core1_separate_stack = true;

uint32_t _tpLedActivity = 0;
uint32_t _ipLedActivity = 0;
#ifdef KNX_ACTIVITYCALLBACK
void activity(uint8_t info)
{
    if((info >> KNX_ACTIVITYCALLBACK_NET))
        _ipLedActivity = millis();
    else
        _tpLedActivity = millis();
}
#endif


void setup()
{
    const uint8_t firmwareRevision = 1;
    openknx.init(firmwareRevision);

    openknx.addModule(7, openknxNetwork);
    openknx.addModule(8, openknxUsbExchangeModule);
    openknx.addModule(9, openknxFileTransferModule);
    
    openknx.setup();

#ifdef KNX_ACTIVITYCALLBACK
#if defined(INFO2_LED_PIN) && defined(INFO3_LED_PIN)
    openknx.info3Led.activity(_ipLedActivity, false);
    openknx.info2Led.activity(_tpLedActivity, false);
#endif
    knx.setActivityCallback(activity);
#endif
}

void loop()
{
    openknx.loop();
}

/*
ToDos:
-------

tunnel: sending to ip 0 => drop telegram (DescReq HPAI = 0)

reverse activity led and signal ip and tp link with "on"



BUGS
-------
none atm :)


IMPROVEMENTS
-------

return false on send unicast in rp2040 plattform

"cache" router objekt properties? in programming mode, you could lock out yourseld in the middle of the programming. behaviour only should change after restart maybe?

-assign tunnels to ip-adresses

PID_MEDIUM_STATUS (wenn kein TP1 / KNX => macht kein Sinn bei Busversorgt...)

- set PID_KNXNETIP_DEVICE_CAPABILITIES
- set PID_KNXNETIP_DEVICE_STATE 
    PID_QUEUE_OVERFLOW_TO_IP = 72,
    PID_QUEUE_OVERFLOW_TO_KNX = 73,
    PID_MSG_TRANSMIT_TO_IP = 74,
    PID_MSG_TRANSMIT_TO_KNX = 75,

ip data link layer send queue (priority queue?)

- check max apdu length (curr: 220 in router obj, 254 in device. why? enertex: 248)

entladen => filtertabelle löschen, props auf default ?

- busmon tunnel support

knxprod:
system - multicast-adresse nutzen oder manuell einstellen

*/