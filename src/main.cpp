#include "OpenKNX.h"
#include <Ethernet_Generic.h>

#pragma message "Pico Core Version: " ARDUINO_PICO_VERSION_STR 


IPAddress GetIpProperty(uint8_t PropertyId)
{
    uint8_t NoOfElem = 1;
    uint8_t *data;
    uint32_t length;
    knx.bau().propertyValueRead(OT_IP_PARAMETER, 0, PropertyId, NoOfElem, 1, &data, length);
    IPAddress ret = (data[3] << 24) + (data[2] << 16) + (data[1] << 8) + data[0];
    delete[] data;
    return ret;
}

void setup()
{
    const uint8_t firmwareRevision = 0;
    openknx.init(firmwareRevision);


    // START ETHERNET stuff
    {
        byte mac[] = {0xDE, 0xAD, 0xBE, 0xEF, 0xFE, 0x01};
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

        uint8_t NoOfElem = 1;
        uint8_t *data;
        uint32_t length;
        knx.bau().propertyValueRead(OT_IP_PARAMETER, 0, PID_IP_ASSIGNMENT_METHOD, NoOfElem, 1, &data, length);

        switch(*data)
        {
            case 1: // manually see 2.5.6 of 03_08_03
            {
                Ethernet.begin(mac, GetIpProperty(PID_IP_ADDRESS), IPAddress(0), GetIpProperty(PID_DEFAULT_GATEWAY), GetIpProperty(PID_SUBNET_MASK));
                // ToDo: set PID_CURRENT_IP_ASSIGNMENT_METHOD to 1
            }
            default:
            //case 4: // DHCP see 2.5.6 of 03_08_03
            {
                Ethernet.begin(mac);
                // ToDo: set PID_CURRENT_IP_ASSIGNMENT_METHOD to 4
            }
        }



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

        // todo PID_IP_ASSIGNMENT_METHOD

        Serial.println("KNX Properties:");
        Serial.print(F("PID_IP_ADDRESS: "));
        Serial.println(GetIpProperty(PID_IP_ADDRESS));
        Serial.print(F("PID_SUBNET_MASK: "));
        Serial.println(GetIpProperty(PID_SUBNET_MASK));
        Serial.print(F("PID_DEFAULT_GATEWAY: "));
        Serial.println(GetIpProperty(PID_DEFAULT_GATEWAY));
    }
    // end Ethernet stuff


    openknx.setup();
}

void loop()
{
    openknx.loop();
}

