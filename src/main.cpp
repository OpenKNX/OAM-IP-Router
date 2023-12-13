#include "OpenKNX.h"

#include "FileTransferModule.h"
#include "NetworkModule.h"
#include "UsbExchangeModule.h"

#pragma message "Pico Core Version: " ARDUINO_PICO_VERSION_STR 
#pragma message "ARDUINO VARIANT: " ARDUINO_VARIANT

bool core1_separate_stack = true;

void setup()
{
    const uint8_t firmwareRevision = 0;
    openknx.init(firmwareRevision);

    openknx.addModule(7, openknxNetwork);
    openknx.addModule(8, openknxUsbExchangeModule);
    openknx.addModule(9, openknxFileTransferModule);
    
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

"cache" router objekt properties? in programming mode, you could lock out yourseld in the middle of the programming. behaviour only should change after restart maybe?

return false on send unicast in rp2040 plattform

LAN Link and LAN Act


BUGS
-------
none atm :)


IMPROVEMENTS
-------
DHCP ASYNC

KNXPROD Deutsch

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

DONE
-------
- ipconfig for different libs
investigate and fix FILTER_TABLE_USE (67)
DONE - prog PA over TP does not work (U_STATE_IND_PE) => network layer coupler
DONE - default PA 15.15.0 not 15.15.255
- returning 1.1.0 and 15.15.255 ?! => Home assistant
- sending nonetheless, cemi frame valid length
- Verhalten wenn kein Ethernetchip / getrennt im Betrieb
- HW-Reset Ethernetchip
- Verhalten wenn kein Link - Link getrennt - Link wieder da


*/