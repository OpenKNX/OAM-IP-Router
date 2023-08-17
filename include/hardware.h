

#ifdef BOARD_REG1_ETH 

#define HARDWARE_NAME "REG1_ETH"

#define OKNXHW_REG1_CONTROLLER2040
#include "OpenKNXHardware.h"

#define USING_SPI2 true
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

#define PROG_LED_PIN LED_BUILTIN
#define PROG_LED_PIN_ACTIVE_ON HIGH
#define PROG_BUTTON_PIN 7
#define PROG_BUTTON_PIN_INTERRUPT_ON FALLING
#define SAVE_INTERRUPT_PIN 6
#define INFO_LED_PIN 3
#define INFO_LED_PIN_ACTIVE_ON HIGH
#define KNX_UART_RX_PIN 1
#define KNX_UART_TX_PIN 0

// Definition for PiPico / SPI0
//#define USING_SPI2 false
//#define PIN_MISO_ (16)
//#define PIN_MOSI_ (19)
//#define PIN_SCK_ (18)
//#define PIN_SS_ (17)

// Definition for PiPico / SPI1 (default)
#define USING_SPI2 true
#define PIN_MISO_ (12)
#define PIN_MOSI_ (15)
#define PIN_SCK_ (14)
#define PIN_SS_ (13)

// Definition for PiPico / SPI1
//#define USING_SPI2 true
//#define PIN_MISO_ (12)
//#define PIN_MOSI_ (11)
//#define PIN_SCK_ (10)
//#define PIN_SS_ (13)


#define PIN_SD_SS (9)
#define PIN_ETH_INT (10)
#define PIN_ETH_RES (11)

#endif

#ifdef BOARD_W5500_EVB_PICO

// https://www.wiznet.io/product-item/w5500-evb-pico/

#define HARDWARE_NAME "W5500-EVB-PICO"

#define PROG_LED_PIN LED_BUILTIN
#define PROG_LED_PIN_ACTIVE_ON HIGH
#define PROG_BUTTON_PIN 14
#define PROG_BUTTON_PIN_INTERRUPT_ON FALLING
#define SAVE_INTERRUPT_PIN 15
#define INFO_LED_PIN -1
#define INFO_LED_PIN_ACTIVE_ON HIGH
#define KNX_UART_RX_PIN 1
#define KNX_UART_TX_PIN 0

// Definition for PiPico / SPI0
#define USING_SPI2 false
#define PIN_MISO_ (16)
#define PIN_MOSI_ (19)
#define PIN_SCK_ (18)
#define PIN_SS_ (17)

#define PIN_SD_SS (22)
#define PIN_ETH_INT (21)
#define PIN_ETH_RES (20)

#endif

#ifdef BOARD_PIPICOW

#define HARDWARE_NAME "PIPICOW"

#define PROG_LED_PIN LED_BUILTIN
#define PROG_LED_PIN_ACTIVE_ON HIGH
#define PROG_BUTTON_PIN 7
#define PROG_BUTTON_PIN_INTERRUPT_ON FALLING
#define SAVE_INTERRUPT_PIN 6
#define INFO_LED_PIN 3
#define INFO_LED_PIN_ACTIVE_ON HIGH
#define KNX_UART_RX_PIN 1
#define KNX_UART_TX_PIN 0

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


//#define PIN_SD_SS (9)

#endif