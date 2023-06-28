#include "OpenKNX.h"
#include "IPConfig.h"

#pragma message "Pico Core Version: " ARDUINO_PICO_VERSION_STR 
#pragma message "ARDUINO VARIANT: " ARDUINO_VARIANT

void setup()
{
    const uint8_t firmwareRevision = 0;
    openknx.init(firmwareRevision);

    openknx.addModule(1, new IPConfigModule());
    
    openknx.setup();
}

void loop()
{
    openknx.loop();
}

/*
ToDos:
knprod prop12

investigate and fix FILTER_TABLE_USE (67)

IPConfig
- ipconfig for different libs
- console 
- Verhalten wenn kein Ethernetchip / getrennt im Betrieb
- HW-Reset Ethernetchip
- Verhalten wenn kein Link - Link getrennt - Link wieder da

- set PID_KNXNETIP_DEVICE_CAPABILITIES
- set PID_KNXNETIP_DEVICE_STATE 

    PID_QUEUE_OVERFLOW_TO_IP = 72,
    PID_QUEUE_OVERFLOW_TO_KNX = 73,
    PID_MSG_TRANSMIT_TO_IP = 74,
    PID_MSG_TRANSMIT_TO_KNX = 75,


PID_MEDIUM_STATUS (wenn kein LAN...)

router / coupler objekte im stack nach ToDos durchsuchen.

stack
CHECK- return false for send*cast
- sending nonetheless, cemi frame valid length
- check max apdu length (curr: 220 in router obj, 254 in device. why? enertex: 248)


DONE
-------
DONE - prog PA over TP does not work (U_STATE_IND_PE) => network layer coupler
DONE - default PA 15.15.0 not 15.15.255
- returning 1.1.0 and 15.15.255 ?! => Home assistant


*/