/**
 * @brief A TP1 System B device (mask 07B0, TP-UART data link) running the real stack on the host,
 *        plus a peer that talks to it over the emulated bus.
 */
#pragma once
#include <cstdint>
#include <memory>
#include <vector>

#include "host_env.h"
#include "ncn_emulator.h"

class Bau07B0;
class InterfaceObject;

/** @brief One TP1 telegram, decoded. */
struct Telegram
{
    uint8_t ctrl = 0;
    uint16_t src = 0;
    uint16_t dst = 0;
    bool group = false;
    uint8_t hop = 6;
    std::vector<uint8_t> tpdu;
};

/** @brief Standard frame up to 16 TPDU octets, extended above (03_02_02 2.2.5). */
std::vector<uint8_t> encodeFrame(const Telegram& t);
/** @brief false when the octets are no complete frame with a correct check octet. */
bool decodeFrame(const std::vector<uint8_t>& lpdu, Telegram& out);

class HostDevice
{
  public:
    /** @param flash persisted NVM; kept by the caller so a second HostDevice on it is a power cycle. */
    HostDevice(std::vector<uint8_t>& flash, uint16_t pa);
    ~HostDevice();

    /** @brief Run the device loop for ms of virtual time, in 100 us steps; a restart boots the stack again. */
    void run(uint32_t ms);

    Bau07B0& bau() { return *_bau; }
    /** @brief Interface object by index (0 device, 1 address table, 2 association, 3 group objects, 4 parameters). */
    InterfaceObject* object(uint8_t idx);
    NcnEmulator& chip() { return _chip; }
    HostPlatform& platform() { return *_platform; }
    uint16_t pa() const { return _pa; }
    /** @brief How often the stack restarted itself (A_Restart, master reset). */
    int reboots() const { return _reboots; }

    /** @brief Telegrams the device sent from index `from` on; frames that do not decode are counted. */
    std::vector<Telegram> sent(size_t from = 0) const;
    size_t sentCount() const { return _chip.sent.size(); }
    /** @brief Frames on the bus that did not decode: a case asserting silence must also assert this is 0. */
    int garbled() const;

  private:
    std::vector<uint8_t>& _flash;
    std::unique_ptr<HostPlatform> _platform;
    NcnEmulator _chip;
    std::unique_ptr<Bau07B0> _bau;
    uint16_t _pa;
    int _reboots = 0;

    void boot(uint16_t pa);
};

/**
 * @brief A management peer on the bus (the role ETS plays), connectionless or connection-oriented.
 */
class Peer
{
  public:
    Peer(HostDevice& dev, uint16_t pa) : _dev(dev), _pa(pa) { dev.chip().present.insert(pa); }

    struct Result
    {
        bool answered = false;
        std::vector<uint8_t> apdu; // from the TPCI octet on: [tpci | apci-hi][apci-lo | data] ...
        uint16_t apci = 0;
        Telegram telegram;
        int acks = 0;  // T_ACKs from the device for our numbered request
        int naks = 0;
        int seqErrors = 0; // numbered answers with a sequence number other than the expected one
        bool disconnected = false;
    };

    void connect();
    void disconnect();
    bool connected() const { return _connected; }

    /** @brief expectApci for a service without an answer: request() returns once the device acknowledged it.
     *         A numbered answer arriving after that is left unacknowledged. */
    static constexpr int AckOnly = -2;

    /** @brief Send an application service and wait up to timeoutMs for `expectApci` (-1 = any) from the device. */
    Result request(uint16_t apci, const std::vector<uint8_t>& data, int expectApci, uint32_t timeoutMs = 3000);

    /** @brief Put a raw TPDU on the bus towards the device, e.g. a malformed one. */
    void sendTpdu(const std::vector<uint8_t>& tpdu, bool group = false, uint16_t dst = 0xFFFF);

    uint16_t pa() const { return _pa; }
    uint8_t seqSend = 0;
    uint8_t seqRecv = 0;

  private:
    HostDevice& _dev;
    uint16_t _pa;
    bool _connected = false;
};
