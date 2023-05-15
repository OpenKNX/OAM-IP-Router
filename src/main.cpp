#include <Arduino.h>
#include <knx.h>


// Definition for PiPico
//#define PIN_SPI0_MISO (16)
//#define PIN_SPI0_MOSI (19)
//#define PIN_SPI0_SCK (18)
//#define PIN_SPI0_SS (17)

// Definition for UP1 / REG1 Controller
#define PIN_SPI0_MISO (28)
#define PIN_SPI0_MOSI (27)
#define PIN_SPI0_SCK (26)
#define PIN_SPI0_SS (29)



#include <Ethernet_Generic.h>

#define VERSION_MAJOR 0
#define VERSION_MINOR 2

byte mac[] = {0xDE, 0xAD, 0xBE, 0xEF, 0xFE, 0x01};

#define PIN_PROG_SWITCH 5
#define PIN_PROG_LED 11

// ITSY BITSY
#define PIN_TPUART_RX 1
#define PIN_TPUART_TX 0


void setup()
{

}

void loop()
{
    delay(1000);
}