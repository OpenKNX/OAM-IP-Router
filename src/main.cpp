#include "OpenKNX.h"
#include "IPConfig.h"
#include "UpdaterModule.h"

#pragma message "Pico Core Version: " ARDUINO_PICO_VERSION_STR 
#pragma message "ARDUINO VARIANT: " ARDUINO_VARIANT

void setup()
{
    const uint8_t firmwareRevision = 0;
    openknx.init(firmwareRevision);

    openknx.addModule(1, new IPConfigModule());
    openknx.addModule(9, new UpdaterModule());
    
    openknx.setup();
}

void loop()
{
    openknx.loop();
}

/*
ToDos:

IPConfig
- console 
- Verhalten wenn kein Ethernetchip / getrennt im Betrieb
- HW-Reset Ethernetchip
- Verhalten wenn kein Link - Link getrennt - Link wieder da

router / coupler objekte im stack nach ToDos durchsuchen.

CHECK- return false for send*case

"cache" router objekt properties? in programming mode, you could lock out yourseld in the middle of the programming. behaviour only should change after restart maybe?

void RouterObject::beforeStateChange(LoadState& newState): routing table control



BUGS
-------


routing table modify !! nicht im ram möglich




IMPROVEMENTS
-------
KNXPROD English

PID_MEDIUM_STATUS (wenn kein TP1 / KNX => macht kein Sinn bei Busversorgt...)

- set PID_KNXNETIP_DEVICE_CAPABILITIES
- set PID_KNXNETIP_DEVICE_STATE 
    PID_QUEUE_OVERFLOW_TO_IP = 72,
    PID_QUEUE_OVERFLOW_TO_KNX = 73,
    PID_MSG_TRANSMIT_TO_IP = 74,
    PID_MSG_TRANSMIT_TO_KNX = 75,

ip data link layer send queue

- check max apdu length (curr: 220 in router obj, 254 in device. why? enertex: 248)


entladen => filtertabelle löschen, props auf default ?

DONE
-------
- ipconfig for different libs
investigate and fix FILTER_TABLE_USE (67)
DONE - prog PA over TP does not work (U_STATE_IND_PE) => network layer coupler
DONE - default PA 15.15.0 not 15.15.255
- returning 1.1.0 and 15.15.255 ?! => Home assistant
- sending nonetheless, cemi frame valid length


*/