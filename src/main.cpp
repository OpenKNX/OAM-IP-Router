#include "OpenKNX.h"
#include <Ethernet_Generic.h>

#ifdef ARDUINO_ARCH_RP2040
#pragma message "Pico Core Version: " ARDUINO_PICO_VERSION_STR 
#endif

#define VERSION_MAJOR 0
#define VERSION_MINOR 2

byte mac[] = {0xDE, 0xAD, 0xBE, 0xEF, 0xFE, 0x01};



void setup()
{
    const uint8_t firmwareRevision = 0;
    openknx.init(firmwareRevision);



    Serial.println("Prepare Ethernet ....");
    delay(200);
    // Prepare Ethernet
    randomSeed(millis());
    pinMode(PIN_SS_, OUTPUT);
    digitalWrite(PIN_SS_, HIGH);

    SPI1.setRX(PIN_MISO_);
    SPI1.setTX(PIN_MOSI_);
    SPI1.setSCK(PIN_SCK_);
    SPI1.setCS(PIN_SS_);
    //SPI.setRX(PIN_MISO_);
    //SPI.setTX(PIN_MOSI_);
    //SPI.setSCK(PIN_SCK_);
    //SPI.setCS(PIN_SS_);

    Serial.println("Setup Pins done ....");
    delay(200);

    Ethernet.init(PIN_SS_);
    Serial.println(F("Initialized "));
    //uint16_t index = millis() % NUMBER_OF_MAC;
    uint16_t index = 0;
    // Use Static IP
    // Ethernet.begin(mac[index], ip);
    Ethernet.begin(mac);
    Serial.print(F("Using mac index = "));
    Serial.println(index);

    Serial.print(F("Connected! IP address: "));
    Serial.println(Ethernet.localIP());

    if ((Ethernet.getChip() == w5500) || (Ethernet.getChip() == w6100) || (Ethernet.getAltChip() == w5100s))
    {
        if (Ethernet.getChip() == w6100)
            Serial.print(F("W6100 => "));
        else if (Ethernet.getChip() == w5500)
            Serial.print(F("W6100 => "));
        else
            Serial.print(F("W5100S => "));

        Serial.print(F("Speed: "));
        Serial.print(Ethernet.speedReport());
        Serial.print(F(", Duplex: "));
        Serial.print(Ethernet.duplexReport());
        Serial.print(F(", Link status: "));
        Serial.println(Ethernet.linkReport());
    }

    openknx.setup();

}

void loop()
{
    openknx.loop();
}