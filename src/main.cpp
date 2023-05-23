#include "OpenKNX.h"
#include "IPConfig.h"
#include <Ethernet_Generic.h>

#pragma message "Pico Core Version: " ARDUINO_PICO_VERSION_STR 

void setup()
{
    const uint8_t firmwareRevision = 0;
    openknx.init(firmwareRevision);

    openknx.addModule(1, new IPConfigModule());
    Serial.println("FooBar2");
    openknx.setup();
}

void loop()
{
    openknx.loop();
}

