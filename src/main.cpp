#include <Arduino.h>

#include "OpenKNX.h"

#ifdef ARDUINO_ARCH_RP2040
#pragma message "Pico Core Version: " ARDUINO_PICO_VERSION_STR 
#endif

// Definition for PiPico / SPI0
//#define PIN_MISO_ (16)
//#define PIN_MOSI_ (19)
//#define PIN_SCK_ (18)
//#define PIN_SS_ (17)

// Definition for PiPico / SPI1 (default)
//#define PIN_MISO_ (12)
//#define PIN_MOSI_ (15)
//#define PIN_SCK_ (14)
//#define PIN_SS_ (13)

// Definition for PiPico / SPI1
//#define PIN_MISO_ (12)
//#define PIN_MOSI_ (11)
//#define PIN_SCK_ (10)
//#define PIN_SS_ (13)


// Definition for UP1 / REG1 Controller SPI1
#define PIN_MISO_ (28)
#define PIN_MOSI_ (27)
#define PIN_SCK_ (26)
#define PIN_SS_ (29)


// Definition for UP1 / REG1 Controller SPI0 (TEST) => Geht
//#define PIN_MISO_ (16)
//#define PIN_MOSI_ (3)
//#define PIN_SCK_ (18)
//#define PIN_SS_ (17)





//#define PROG_BUTTON_PIN 8
//#define PROG_LED_PIN LED_BUILTIN
//#define PROG_LED_PIN_ACTIVE_ON HIGH



//#define PIN_SD_SS (16)
//#define PIN_ETH_INT (17)
//#define PIN_ETH_RES (18)


#include <knx.h>
#include <Ethernet_Generic.h>

#define VERSION_MAJOR 0
#define VERSION_MINOR 2

byte mac[] = {0xDE, 0xAD, 0xBE, 0xEF, 0xFE, 0x01};




void setup()
{
    const uint8_t firmwareRevision = 0;

    Serial.begin(115200);
    ArduinoPlatform::SerialDebug = &Serial;
    while (!Serial)
    {
        delay(10);
    }
    delay(300);
    Serial.println("Loading ....");

    // Prepare KNX interface
    //knx.platform().knxUart(&serialTpuart);
    //knx.platform().knxUart(&Serial1);
    knx.ledPin(PROG_LED_PIN);
    knx.ledPinActiveOn(PROG_LED_PIN_ACTIVE_ON);
    knx.buttonPin(PROG_BUTTON_PIN);

    // Init KNX
    knx.version((VERSION_MAJOR << 6) | (VERSION_MINOR & 0x3F)); // PID_VERSION
    knx.orderNumber((const uint8_t *)"50000");                  // PID_ORDER_INFO
    knx.manufacturerId(0xfa);                                   // PID_SERIAL_NUMBER (2 first bytes) - 0xfa for KNX Association
    knx.hardwareType((const uint8_t *)"M-091A");                // PID_HARDWARE_TYPE

    Serial.println("Prepare Ethernet ....");
    delay(200);
    // Prepare Ethernet
    randomSeed(millis());
    pinMode(PIN_SS_, OUTPUT);
    digitalWrite(PIN_SS_, HIGH);

    Serial.println("Prepare Ethernet 2 ....");
    delay(200);

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
    /*
    result = udp.beginMulticast(mcastaddr, port);
    KNX_DEBUG_SERIAL.printf("Setup Mcast addr: ");
    mcastaddr.printTo(KNX_DEBUG_SERIAL);
    KNX_DEBUG_SERIAL.printf(" on port: %d result %d\n", port, result);
    result = udp.beginPacket(mcastaddr, port);
    KNX_DEBUG_SERIAL.printf("begin:%d ", result);
    udp.write(test, 24);
    result = udp.endPacket();
    KNX_DEBUG_SERIAL.printf("end:%d \n", result);
    */

    // read adress table, association table, groupobject table and parameters from eeprom
    knx.readMemory();

    // print values of parameters if device is already configured
    if (knx.configured())
    {
        Serial.println("Coupler configured.");

        // KNX_DEBUG_SERIAL.printf("IP Address: %x.%x.%x.%x\n", ip[0], ip[1], ip[2], ip[3]);
    }
    else
    {
        Serial.println("Coupler not configured");
    }

    // pin or GPIO the programming led is connected to. Default is LED_BUILTIN
    // knx.ledPin(LED_BUILTIN);
    // is the led active on HIGH or low? Default is LOW
    // knx.ledPinActiveOn(HIGH);
    // pin or GPIO programming button is connected to. Default is 0
    // knx.buttonPin(0);

    // start the framework.
    knx.start();

    Serial.println("Params:");
    uint32_t p_ipadr = knx.paramInt(0);
    uint32_t p_gw = knx.paramInt(32);
    uint32_t p_mask = knx.paramInt(64);

    Serial.println(p_ipadr);
    Serial.println(p_gw);
    Serial.println(p_mask);

    //knx.platform().setupMultiCast(3758102284, 3671);

    //udp.begin(12345);
}

uint32_t last_millis = millis();

void loop()
{
    // don't delay here to much. Otherwise you might lose packages or mess up the timing with ETS
    knx.loop();

    if (millis() - last_millis > 50000)
    {
        last_millis = millis();
        byte dat[4] = {0xDE, 0xEA, 0xBE, 0xEF};
        //udp.beginPacket(etsaddr, 54321);
        //udp.write(dat, 4);
        //udp.endPacket();
        //knx.platform().sendBytesUniCast(3232281288, 12345, dat, 4);
        //knx.platform().sendBytesMultiCast(dat, 4);
    }

    // only run the application code if the device was configured with ETS
    if (!knx.configured())
        return;

    // Send UDP packet every second
    /*if (millis() % 1000)
    {
        result = udp.beginPacket(mcastaddr, port);
        // KNX_DEBUG_SERIAL.printf("begin:%d ", result);
        udp.write(test, 24);
        result = udp.endPacket();
        // KNX_DEBUG_SERIAL.printf("end:%d \n", result);
    }
    */

}
