

#ifdef BOARD_REG1_ETH 

#define HARDWARE_NAME "REG1_ETH"

#define OKNXHW_REG1_CONTROLLER2040
#include "OpenKNXHardware.h"

#define PIN_MISO_ (28)
#define PIN_MOSI_ (27)
#define PIN_SCK_ (26)
#define PIN_SS_ (29)

#define PIN_SD_SS (16)
#define PIN_ETH_INT (17)
#define PIN_ETH_RES (18)


#endif

#ifdef BOARD_PIPICO

#define HARDWARE_NAME "PIPICO"

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

#define PROG_BUTTON_PIN 8
#define PROG_LED_PIN LED_BUILTIN
#define PROG_LED_PIN_ACTIVE_ON HIGH

//#define PIN_SD_SS (16)
//#define PIN_ETH_INT (17)
//#define PIN_ETH_RES (18)

#endif