/**
 * @brief NCN5120/5130 host-UART emulator behind TPUart::Interface::Abstract.
 *
 * Models what the driver talks to (NCN5130-D, 9-bit UART mode): U_Reset/U_State/U_Configure/U_SetAddress/
 * U_SetRepetition, the U_L_Data* transmit bytes, the echo of every transmitted frame, the optional
 * CRC-16/CCITT trailer (after U_Configure with c=1), and a positive/negative L_Data.con decided by a bus
 * model. Received telegrams are injected as the chip forwards them. Bytes to the host carry a due time on
 * the harness clock and only become readable once it is reached.
 */
#pragma once
#include <cstdint>
#include <deque>
#include <functional>
#include <set>
#include <vector>

#include "TPUart/Interface/Abstract.h"

class NcnEmulator : public TPUart::Interface::Abstract
{
  public:
    // --- TPUart::Interface::Abstract
    void flush() override {}
    void begin(int baud) override { _baud = baud; _running = true; }
    void end() override { _running = false; }
    bool available() override;
    bool availableForWrite() override { return true; }
    bool write(char value) override;
    int read() override;

    // --- bus model
    /** @brief Individual addresses that acknowledge; any other individual destination gets a NACK-less silence (negative con). */
    std::set<uint16_t> present;
    /** @brief Group telegrams are acknowledged unless this is false. */
    bool groupAcked = true;

    /** @brief Frames the device put on the bus, as octets incl. FCS. */
    std::vector<std::vector<uint8_t>> sent;
    /** @brief U_Ack.req values the host wrote for injected frames, in order. */
    std::vector<uint8_t> ackRequests;
    /** @brief Host bytes this model does not know; a test can assert it stays empty. */
    std::vector<uint8_t> unknown;

    /** @brief Frames whose check octet from the host did not match; the chip does not send those. */
    int badChecksums = 0;
    /** @brief Repetitions the chip makes when a frame is not acknowledged (U_SetRepetition default 3). */
    int repetitions = 3;

    int resets = 0;
    bool crcMode = false;
    bool monitor = false;
    uint16_t ownAddress = 0;

    /** @brief Queue a telegram from another device, as the chip forwards it (octets incl. FCS). */
    void inject(const std::vector<uint8_t>& lpdu, uint32_t octetSpacingUs = 1350);

    /** @brief Queue octets exactly as given: no FCS, no CRC, no frame model.
     *  @details inject() always builds a telegram. A chip indication such as U_SYSTEM_STAT_IND is two
     *           raw octets and can arrive with a pause between them, which is what a case needs here. */
    void emitRaw(const std::vector<uint8_t>& octets, uint32_t octetSpacingUs = 1350);

    /** @brief TP1 check octet: complement of the XOR of all preceding octets (03_02_02 2.2.4.6). */
    static uint8_t fcs(const std::vector<uint8_t>& octets, size_t count);

  private:
    struct Out
    {
        uint64_t due;
        uint8_t value;
    };
    std::deque<Out> _out;
    int _baud = 0;

    enum class Rx
    {
        Idle,
        SetAddress,
        SetRepetition,
        Data,
        End
    } _st = Rx::Idle;
    int _need = 0;
    uint16_t _pos = 0;
    uint16_t _offsetHigh = 0;
    std::vector<uint8_t> _tx;
    std::vector<uint8_t> _args;

    void emit(uint8_t v, uint64_t due);
    void frameComplete();
    static void crc16(const std::vector<uint8_t>& octets, uint8_t& hi, uint8_t& lo);
};
