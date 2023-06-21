#include "OpenKNX.h"
#include "IPConfig.h"

#pragma message "Pico Core Version: " ARDUINO_PICO_VERSION_STR 
#pragma message "ARDUINO VARIANT: " ARDUINO_VARIANT

OpenKNX::Log::VirtualSerial ETG_SERIAL = OpenKNX::Log::VirtualSerial("ETG");

void setup()
{
    const uint8_t firmwareRevision = 0;
    openknx.init(firmwareRevision);

    openknx.addModule(1, new IPConfigModule());
    
    openknx.setup();

    ETG_SERIAL.print("Test");
}

void loop()
{
    openknx.loop();
}

/*
ToDos:
- Verhalten wenn kein Ethernetchip / getrennt im Betrieb
- HW-Reset Ethernetchip
- Verhalten wenn kein Link - Link getrennt - Link wieder da
- set PID_KNXNETIP_DEVICE_CAPABILITIES
- set PID_KNXNETIP_DEVICE_STATE 

*/