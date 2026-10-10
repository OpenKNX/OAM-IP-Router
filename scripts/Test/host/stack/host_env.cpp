/**
 * @brief Host implementations of the free functions the knx stack and TPUart expect, and HostPlatform.
 */
#include "host_env.h"

#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <cstring>

#include "knx/bits.h"

uint64_t g_hostUs = 1000000; // start at 1 s: code that treats 0 as "never" must not see it
static uint32_t g_readsSinceAdvance = 0;

void hostAdvanceUs(uint64_t us)
{
    g_hostUs += us;
    g_readsSinceAdvance = 0;
}

// Only a busy-wait moves the clock by itself: normal code reads it a few times per step and sees exact time.
static void clockRead()
{
    if (++g_readsSinceAdvance > 10000)
        g_hostUs += 1;
}

std::string& hostLog()
{
    static std::string log;
    return log;
}

uint32_t millis()
{
    clockRead();
    return (uint32_t)(g_hostUs / 1000);
}

uint32_t micros()
{
    clockRead();
    return (uint32_t)g_hostUs;
}

void delay(uint32_t ms) { hostAdvanceUs((uint64_t)ms * 1000); }
void delayMicroseconds(unsigned int us) { hostAdvanceUs(us); }
void pinMode(uint32_t, uint32_t) {}
void digitalWrite(uint32_t, uint32_t) {}
uint32_t digitalRead(uint32_t) { return 0; }
void attachInterrupt(uint32_t, voidFuncPtr, uint32_t) {}

static void logf(const char* fmt, ...)
{
    char b[64];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(b, sizeof(b), fmt, ap);
    va_end(ap);
    hostLog() += b;
}

static void logNum(unsigned long long v, int base) { logf(base == HEX ? "%llX" : "%llu", v); }
static void logSigned(long long v, int base) { if (base == HEX) logf("%llX", (unsigned long long)v); else logf("%lld", v); }

void print(const char s[]) { hostLog() += s; }
void print(char c) { hostLog() += c; }
void print(unsigned char v, int base) { logNum(v, base); }
void print(int v, int base) { logSigned(v, base); }
void print(unsigned int v, int base) { logNum(v, base); }
void print(long v, int base) { logSigned(v, base); }
void print(unsigned long v, int base) { logNum(v, base); }
void print(long long v, int base) { logSigned(v, base); }
void print(unsigned long long v, int base) { logNum(v, base); }
void print(double v) { logf("%g", v); }
void println(const char s[]) { print(s); hostLog() += '\n'; }
void println(char c) { print(c); hostLog() += '\n'; }
void println(unsigned char v, int base) { print(v, base); hostLog() += '\n'; }
void println(int v, int base) { print(v, base); hostLog() += '\n'; }
void println(unsigned int v, int base) { print(v, base); hostLog() += '\n'; }
void println(long v, int base) { print(v, base); hostLog() += '\n'; }
void println(unsigned long v, int base) { print(v, base); hostLog() += '\n'; }
void println(long long v, int base) { print(v, base); hostLog() += '\n'; }
void println(unsigned long long v, int base) { print(v, base); hostLog() += '\n'; }
void println(double v) { print(v); hostLog() += '\n'; }
void println(void) { hostLog() += '\n'; }

static HostPlatform* g_active = nullptr;

HostPlatform::HostPlatform(std::vector<uint8_t>& flash) : _flash(flash)
{
    if (_flash.size() < KNX_FLASH_SIZE)
        _flash.resize(KNX_FLASH_SIZE, 0xFF); // erased flash; never resized again, the stack keeps the pointer
    g_active = this;
    registerFlashCallbacks([]() -> uint32_t { return g_active->flashSize(); },
                           []() -> uint8_t* { return g_active->flashRead(); },
                           [](uint32_t a, uint8_t* b, size_t l) -> uint32_t { return g_active->flashWrite(a, b, l); },
                           []() { g_active->flashCommit(); });
}

HostPlatform::~HostPlatform()
{
    if (g_active == this)
        g_active = nullptr;
}

void HostPlatform::loadSector(int sector)
{
    if (sector == _bufferSector)
        return;
    if (_bufferSector >= 0)
        flashCommit(); // another sector is touched: the buffered one is written first, as Flash::Driver does
    _sector.assign(_flash.begin() + (size_t)sector * kSectorSize, _flash.begin() + (size_t)(sector + 1) * kSectorSize);
    _bufferSector = sector;
}

uint32_t HostPlatform::flashWrite(uint32_t relativeAddress, uint8_t* buffer, size_t len)
{
    if ((uint64_t)relativeAddress + len > _flash.size())
        throw std::runtime_error("flash write past the NVM image");
    while (len > 0)
    {
        loadSector((int)(relativeAddress / kSectorSize));
        const uint32_t pos = relativeAddress % kSectorSize;
        const size_t n = std::min<size_t>(len, kSectorSize - pos);
        memcpy(_sector.data() + pos, buffer, n);
        relativeAddress += n;
        buffer += n;
        len -= n;
    }
    return relativeAddress;
}

void HostPlatform::flashCommit()
{
    if (_bufferSector < 0)
        return;
    uint8_t* flash = _flash.data() + (size_t)_bufferSector * kSectorSize;
    if (memcmp(flash, _sector.data(), kSectorSize) == 0)
        return; // Flash::Driver::writeSector skips an unchanged sector
    for (uint32_t i = 0; i < kSectorSize; i++)
        if (_sector[i] & ~flash[i])
        {
            _erases++;
            break;
        }
    memcpy(flash, _sector.data(), kSectorSize);
    _commits++;
}

void HostPlatform::dropUncommitted() { _bufferSector = -1; }
