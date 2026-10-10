/**
 * @brief Management helpers for the host cases: the services ETS uses, built as 03_03_07 lays them out.
 *
 * Result.apdu starts at the TPCI octet: [0] TPCI|APCI-hi, [1] APCI-lo, [2..] service data.
 */
#pragma once
#include <cstdint>
#include <vector>

#include "host_device.h"

namespace mgmt
{
constexpr uint16_t PropRead = 0x3D5, PropResponse = 0x3D6, PropWrite = 0x3D7;
constexpr uint16_t MemRead = 0x200, MemResponse = 0x240, MemWrite = 0x280;
constexpr uint16_t MemExtWrite = 0x1FB, MemExtWriteResponse = 0x1FC, MemExtRead = 0x1FD, MemExtReadResponse = 0x1FE;
constexpr uint16_t MasterReset = 0x381, RestartResponse = 0x3A1, DeviceDescriptorRead = 0x300, DeviceDescriptorResponse = 0x340;

inline Peer::Result propRead(Peer& p, uint8_t obj, uint8_t pid, uint8_t count, uint16_t start)
{
    return p.request(PropRead, {obj, pid, (uint8_t)((count << 4) | ((start >> 8) & 0x0F)), (uint8_t)start}, PropResponse);
}

inline Peer::Result propWrite(Peer& p, uint8_t obj, uint8_t pid, uint8_t count, uint16_t start, const std::vector<uint8_t>& data)
{
    std::vector<uint8_t> d = {obj, pid, (uint8_t)((count << 4) | ((start >> 8) & 0x0F)), (uint8_t)start};
    d.insert(d.end(), data.begin(), data.end());
    return p.request(PropWrite, d, PropResponse);
}

/** @brief nr_of_elem of a property response. */
inline int propCount(const Peer::Result& r) { return r.apdu.size() >= 5 ? (r.apdu[4] >> 4) : -1; }

/** @brief Data octets of a property response. */
inline std::vector<uint8_t> propData(const Peer::Result& r)
{
    return r.apdu.size() > 6 ? std::vector<uint8_t>(r.apdu.begin() + 6, r.apdu.end()) : std::vector<uint8_t>();
}

/** @brief A_Restart master reset; the answer (if any) is A_Restart_Response [error, process time]. */
inline Peer::Result masterReset(Peer& p, uint8_t eraseCode, uint8_t channel)
{
    return p.request(MasterReset, {eraseCode, channel}, RestartResponse);
}

/** @brief Load state control event on a table object (PID 5); additional load controls carry 03 0B size mode fill. */
inline Peer::Result loadEvent(Peer& p, uint8_t obj, const std::vector<uint8_t>& ev)
{
    std::vector<uint8_t> d = ev;
    d.resize(10, 0x00); // PDT_CONTROL: ten octets on write
    return propWrite(p, obj, 5, 1, 1, d);
}

inline std::vector<uint8_t> allocControl(uint32_t size)
{
    return {0x03, 0x0B, (uint8_t)(size >> 24), (uint8_t)(size >> 16), (uint8_t)(size >> 8), (uint8_t)size, 0x01, 0x00};
}
} // namespace mgmt
