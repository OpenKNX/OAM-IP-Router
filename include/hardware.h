// Using OFM-HardwareConfig aggregator so REG1 + REG2 (Pico/PicoW/Pico2/ESP32-S3) configs are available
#include "HardwareConfig.h"

// LED functions while unconfigured (or with the default LED functions in ETS): 1 = KNX, 2 = IP, 3 = none
#define OPENKNX_INFOLED1_DEFAULT OPENKNX_LEDFUNC_BASE_KNX
#define OPENKNX_INFOLED2_DEFAULT OPENKNX_LEDFUNC_NET_STATE
