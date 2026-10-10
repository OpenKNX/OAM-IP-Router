/**
 * @brief Minimal Arduino surface for building lib/TPUart on the host.
 *
 * Only what the driver uses outside its RP2040/ESP32 branches. Time comes from the harness clock.
 */
#pragma once
#include <sys/types.h>
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <functional>

uint32_t millis();
uint32_t micros();
void delay(uint32_t millis);
void delayMicroseconds(unsigned int howLong);
inline void yield() {}

using std::max;
using std::min;
