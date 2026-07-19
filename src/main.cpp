#include "OpenKNX.h"

#include "IPRouterModule.h"
#include "NetworkModule.h"
#ifdef ARDUINO_ARCH_RP2040
#include "FileTransferModule.h"
#include "UsbExchangeModule.h"
#pragma message "Pico Core Version: " ARDUINO_PICO_VERSION_STR
#pragma message "ARDUINO VARIANT: " ARDUINO_VARIANT
#endif

// REG2 Device Display (buttons use OGM-Common native openknx.gpio, no OFM-GPIOModule)
#ifdef DEVICE_DISPLAY_MODULE
#include "DeviceDisplay.h"
#include "DisplayWidgets/WidgetIPRouter.h"
#endif
#ifdef OPENKNX_SD_CARD_MODULE_ENABLE
#include "SDCardModule.h"
#endif

#if defined(ARDUINO_ARCH_ESP32) && defined(OPENKNX_DEBUG_HEAP_LOG)
#include "esp_heap_caps.h" // only the optional periodic heap log (loop) uses heap_caps_*
#endif

bool core1_separate_stack = true;

void setup()
{
#ifdef FIRMWARE_REVISION
    openknx.init(); // OGM-Common 7.5+: revision via FIRMWARE_REVISION flag, 0-arg init()
#else
    const uint8_t firmwareRevision = 0;
    openknx.init(firmwareRevision);
#endif

    openknx.addModule(6, openknxIPRouterModule);
    openknx.addModule(7, openknxNetwork);
#ifdef ARDUINO_ARCH_RP2040
    openknx.addModule(8, openknxUsbExchangeModule);
    openknx.addModule(9, openknxFileTransferModule);
#endif
#ifdef DEVICE_DISPLAY_MODULE
    openknx.addModule(10, openknxDisplayModule);
#endif
#ifdef OPENKNX_SD_CARD_MODULE_ENABLE
    openknx.addModule(30, sdCardModule);
#endif

    if (!knx.configured())
    {
        openknx.ledFunctions.assignLed2Function(openknx.leds.getLed(OpenKNX::Led::LedType::LED_TYPE_INFO3), OPENKNX_LEDFUNC_BASE_KNX);
        openknx.ledFunctions.assignLed2Function(openknx.leds.getLed(OpenKNX::Led::LedType::LED_TYPE_INFO2), OPENKNX_LEDFUNC_NET_STATE);
    }

    openknx.setup();

#ifdef DEVICE_DISPLAY_MODULE
    // Setup the IP Router widget after the display module is ready
    WidgetIPRouter* ipRouterWidget = new WidgetIPRouter(15000, WidgetFlags::DefaultWidget);
    openknxDisplayModule.getWidgetManager()->addWidget(ipRouterWidget);
#endif
}

#if defined(ARDUINO_ARCH_ESP32) && defined(OPENKNX_DEBUG_HEAP_LOG)
uint32_t _showMem = 0;
#endif

void loop()
{
    openknx.loop();

#if defined(ARDUINO_ARCH_ESP32) && defined(OPENKNX_DEBUG_HEAP_LOG)
    // Periodic heap trend -- opt-in via its own switch OPENKNX_DEBUG_HEAP_LOG (ESP32 only).
    // The same numbers are always available on demand via the console 'mem'/'info' command
    // (OGM-Common, all ESP32 nodes). 'largest' is the contiguous block the EMAC RX buffer
    // needs; a steady drop = leak.
    if (delayCheck(_showMem, 10000))
    {
        openknx.logger.logWithPrefixAndValues("HEAP",
                                              "free=%u min=%u largest=%u | dma_free=%u dma_min=%u dma_largest=%u",
                                              (unsigned)heap_caps_get_free_size(MALLOC_CAP_DEFAULT),
                                              (unsigned)heap_caps_get_minimum_free_size(MALLOC_CAP_DEFAULT),
                                              (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_DEFAULT),
                                              (unsigned)heap_caps_get_free_size(MALLOC_CAP_DMA),
                                              (unsigned)heap_caps_get_minimum_free_size(MALLOC_CAP_DMA),
                                              (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_DMA));
        _showMem = millis();
    }
#endif
}

#ifdef OPENKNX_DUALCORE
void setup1()
{
    openknx.setup1();
}

void loop1()
{
    openknx.loop1();
    knx.bau().getSecondaryDataLinkLayer()->getTPUart().processReceviedByte();
    knx.bau().getSecondaryDataLinkLayer()->getTPUart().processReceviedByte();
    knx.bau().getSecondaryDataLinkLayer()->getTPUart().processTransmitByte();
}
#endif

/*
ToDos:
-------


BUGS
-------


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

entladen => filtertabelle löschen, props auf default ?

- busmon tunnel support

knxprod:
system - multicast-adresse nutzen oder manuell einstellen

*/
