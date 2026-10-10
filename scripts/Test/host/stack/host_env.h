/**
 * @brief Host environment for the knx stack: virtual clock, free functions and a Platform.
 *
 * The clock moves only when the harness advances it. A clock read that repeats without an advance is a
 * busy-wait, and only then does each read add 1 us, so a wait on the clock still ends.
 *
 * NVM follows the product (KNX_FLASH_CALLBACK, OGM-Common Flash::Driver): reads go straight to the flash
 * image, writes land in a one-sector buffer that is written back on commit or when another sector is
 * touched. A restart built from the flash image therefore sees exactly what the device had persisted.
 */
#pragma once
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

#include "knx/platform.h"

extern uint64_t g_hostUs;

/** @brief Advance the virtual clock. */
void hostAdvanceUs(uint64_t us);

/** @brief Everything the stack printed since the last clear. */
std::string& hostLog();

/** @brief Thrown by fatalError(): the stack gave up, the test fails with the log. */
struct HostFatal : std::runtime_error
{
    HostFatal() : std::runtime_error("fatalError() called") {}
};

/** @brief Thrown by restart(): nothing after the reset runs, as on the device. */
struct HostRestart
{
};

class HostPlatform : public Platform
{
  public:
    static constexpr uint32_t kSectorSize = 4096; // RP2040 FLASH_SECTOR_SIZE, ESP32 SPI_FLASH_SEC_SIZE

    /** @param flash persisted NVM image; empty means erased flash. */
    explicit HostPlatform(std::vector<uint8_t>& flash);
    ~HostPlatform();

    /** @brief Leaves the stack at once, as the MCU reset does; HostDevice catches it and boots again. */
    void restart() override
    {
        _restarts++;
        throw HostRestart();
    }
    void fatalError() override { throw HostFatal(); }
    uint32_t uniqueSerialNumber() override { return 0x00C0FFEE; }

    int restarts() const { return _restarts; }
    int commits() const { return _commits; }
    /** @brief Sector erases: a commit that has to turn a 0 bit back into 1, as Flash::Driver::needEraseForBuffer. */
    int erases() const { return _erases; }

    /** @brief A power cut: the unwritten sector buffer is lost, the flash image stays. */
    void dropUncommitted();

    // Flash driver, as OGM-Common registers it through registerFlashCallbacks().
    uint32_t flashWrite(uint32_t relativeAddress, uint8_t* buffer, size_t len);
    void flashCommit();
    uint8_t* flashRead() { return _flash.data(); }
    uint32_t flashSize() { return (uint32_t)_flash.size(); }

  private:
    std::vector<uint8_t>& _flash;
    std::vector<uint8_t> _sector;
    int _bufferSector = -1;
    int _restarts = 0;
    int _commits = 0;
    int _erases = 0;

    void loadSector(int sector);
};
