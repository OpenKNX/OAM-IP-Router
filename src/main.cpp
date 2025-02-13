#include "OpenKNX.h"


#include "NetworkModule.h"
#ifdef ARDUINO_ARCH_RP2040
#include "UsbExchangeModule.h"
#include "FileTransferModule.h"
#pragma message "Pico Core Version: " ARDUINO_PICO_VERSION_STR 
#pragma message "ARDUINO VARIANT: " ARDUINO_VARIANT
#endif



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
    const uint8_t firmwareRevision = 2;
    openknx.init(firmwareRevision);

    openknx.addModule(7, openknxNetwork);
    #ifdef ARDUINO_ARCH_RP2040
    openknx.addModule(8, openknxUsbExchangeModule);
    openknx.addModule(9, openknxFileTransferModule);
    #endif

    
    openknx.setup();
}

uint32_t _showMem = 0;
uint32_t _leds = 0;
uint8_t _ipLedState = 0;
uint8_t _tpLedState = 0;
void loop()
{
    openknx.loop();

    if (delayCheck(_leds, 100))
    {
        #ifdef KNX_ACTIVITYCALLBACK
            #if defined(INFO2_LED_PIN) && defined(INFO3_LED_PIN)
            if(openknxNetwork.established())
            {
                if(_ipLedState != 1)
                {
                    #ifdef OPENKNX_SERIALLED_ENABLE
                    openknx.info2Led.setColor(OPENKNX_SERIALLED_COLOR_GREEN);
                    #endif
                    openknx.info2Led.activity(_ipLedActivity, true);
                    _ipLedState = 1;
                }
            }
            else if(openknxNetwork.connected())
            {
                if(_ipLedState != 2)
                {
                    #ifdef OPENKNX_SERIALLED_ENABLE
                    openknx.info2Led.setColor(OPENKNX_SERIALLED_COLOR_YELLOW);
                    openknx.info2Led.on();
                    #else
                    openknx.info2Led.off();
                    #endif

                    _ipLedState = 2;
                }
            }
            else
            {
                if(_ipLedState != 3)
                {
                    #ifdef OPENKNX_SERIALLED_ENABLE
                    openknx.info2Led.setColor(OPENKNX_SERIALLED_COLOR_RED);
                    openknx.info2Led.on();
                    #else
                    openknx.info2Led.off();
                    #endif
                    _ipLedState = 3;
                }
            }

            if(knx.bau().getSecondaryDataLinkLayer()->isConnected())
            {
                if(_tpLedState != 1)
                {
                    #ifdef OPENKNX_SERIALLED_ENABLE
                    openknx.info3Led.setColor(OPENKNX_SERIALLED_COLOR_GREEN);
                    #endif
                    openknx.info3Led.activity(_tpLedActivity, true);
                    _tpLedState = 1;
                }
            }
            else
            {
                if(_tpLedState != 3)
                {
                    #ifdef OPENKNX_SERIALLED_ENABLE
                    openknx.info3Led.setColor(OPENKNX_SERIALLED_COLOR_RED);
                    openknx.info3Led.on();
                    #else
                    openknx.info2Led.off();
                    #endif
                    _tpLedState = 3;
                }
            }
            #endif
            knx.bau().setActivityCallback(activity);
        #endif

        _leds = millis();
    }

    if (delayCheck(_showMem, 1000))
    {
        //openknx.console.showMemory();
        _showMem = millis();
    }
}

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

- check max apdu length (curr: 220 in router obj, 254 in device. why? enertex: 248)

entladen => filtertabelle löschen, props auf default ?

- busmon tunnel support

knxprod:
system - multicast-adresse nutzen oder manuell einstellen

*/