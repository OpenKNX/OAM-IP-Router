/**
 * @brief NCN5120/5130 host-UART emulator, see ncn_emulator.h.
 */
#include "ncn_emulator.h"

#include "host_env.h"

namespace
{
constexpr uint32_t kOctetUs = 1350;   // one TP1 octet incl. stop bits and idle, 9600 bit/s
constexpr uint32_t kAckWindowUs = 3000; // frame end -> L_Data.con (ACK window + processing)
} // namespace

bool NcnEmulator::available()
{
    return !_out.empty() && _out.front().due <= g_hostUs;
}

int NcnEmulator::read()
{
    if (!available())
        return -1;
    uint8_t v = _out.front().value;
    _out.pop_front();
    return v;
}

void NcnEmulator::emit(uint8_t v, uint64_t due)
{
    // Keep the stream ordered: a byte can never overtake one queued before it.
    if (!_out.empty() && due < _out.back().due)
        due = _out.back().due;
    _out.push_back({due, v});
}

uint8_t NcnEmulator::fcs(const std::vector<uint8_t>& octets, size_t count)
{
    uint8_t x = 0;
    for (size_t i = 0; i < count; i++)
        x ^= octets[i];
    return (uint8_t)~x;
}

void NcnEmulator::crc16(const std::vector<uint8_t>& octets, uint8_t& hi, uint8_t& lo)
{
    // CRC-16/CCITT-FALSE over the whole frame incl. its check octet, high octet first (as Frame.h checks it).
    uint16_t crc = 0xFFFF;
    for (uint8_t o : octets)
    {
        crc ^= (uint16_t)o << 8;
        for (int j = 0; j < 8; j++)
            crc = (crc & 0x8000) ? (uint16_t)((crc << 1) ^ 0x1021) : (uint16_t)(crc << 1);
    }
    hi = crc >> 8;
    lo = crc & 0xFF;
}

void NcnEmulator::emitRaw(const std::vector<uint8_t>& octets, uint32_t octetSpacingUs)
{
    uint64_t t = g_hostUs;
    for (uint8_t o : octets)
    {
        t += octetSpacingUs;
        emit(o, t);
    }
}

void NcnEmulator::inject(const std::vector<uint8_t>& lpdu, uint32_t octetSpacingUs)
{
    uint64_t t = g_hostUs;
    for (uint8_t o : lpdu)
    {
        t += octetSpacingUs;
        emit(o, t);
    }
    if (crcMode && !monitor)
    {
        uint8_t hi, lo;
        crc16(lpdu, hi, lo);
        emit(hi, t);
        emit(lo, t);
    }
}

void NcnEmulator::frameComplete()
{
    // The chip checks the host's check octet and refuses a frame that does not match (NCN5130-D p.41).
    if (_tx.size() < 2 || fcs(_tx, _tx.size() - 1) != _tx.back())
    {
        badChecksums++;
        emit(0x0B, g_hostUs + kAckWindowUs);
        _tx.clear();
        return;
    }

    bool acked = true;
    const bool standard = (_tx[0] & 0x80) != 0;
    if (_tx.size() >= (standard ? 6u : 7u))
    {
        // Standard: CTRL SA SA DA DA [AT|hop|LG]. Extended: CTRL CTRLE(AT|hop|EFF) SA SA DA DA LG.
        const bool group = standard ? (_tx[5] & 0x80) != 0 : (_tx[1] & 0x80) != 0;
        const uint16_t dst = standard ? (((uint16_t)_tx[3] << 8) | _tx[4]) : (((uint16_t)_tx[4] << 8) | _tx[5]);
        acked = group ? groupAcked : present.count(dst) != 0;
    }

    // Every transmission passes the chip's receiver and is handed back; an unacknowledged frame is repeated
    // with the repeat flag cleared (bit 5 = 0) and a new check octet, then confirmed negatively.
    uint64_t t = g_hostUs;
    const int transmissions = acked ? 1 : 1 + repetitions;
    for (int n = 0; n < transmissions; n++)
    {
        std::vector<uint8_t> f = _tx;
        if (n > 0)
        {
            f[0] &= (uint8_t)~0x20;
            f.back() = fcs(f, f.size() - 1);
            t += 50 * 104; // 50 bit times of line idle before a repetition
        }
        sent.push_back(f);
        for (uint8_t o : f)
        {
            t += kOctetUs;
            emit(o, t);
        }
        if (crcMode)
        {
            uint8_t hi, lo;
            crc16(f, hi, lo);
            emit(hi, t);
            emit(lo, t);
        }
        t += kAckWindowUs;
    }
    emit(acked ? 0x8B : 0x0B, t); // L_Data.con: bit 7 = positive
    _tx.clear();
}

bool NcnEmulator::write(char c)
{
    const uint8_t b = (uint8_t)c;
    switch (_st)
    {
        case Rx::SetAddress:
            _args.push_back(b);
            if (--_need == 0)
            {
                ownAddress = ((uint16_t)_args[0] << 8) | _args[1]; // third octet is the dummy
                _st = Rx::Idle;
            }
            return true;
        case Rx::SetRepetition:
            if (--_need == 0)
                _st = Rx::Idle;
            return true;
        case Rx::Data:
            if (_tx.size() <= _pos)
                _tx.resize(_pos + 1, 0);
            _tx[_pos] = b;
            _st = Rx::Idle;
            return true;
        case Rx::End:
            if (_tx.size() <= _pos)
                _tx.resize(_pos + 1, 0);
            _tx[_pos] = b;
            _st = Rx::Idle;
            frameComplete();
            return true;
        case Rx::Idle:
            break;
    }

    if (b == 0x01) // U_Reset.req
    {
        resets++;
        crcMode = false;
        monitor = false;
        ownAddress = 0;
        _tx.clear();
        _out.clear();
        emit(0x03, g_hostUs + 100); // U_Reset.ind
    }
    else if (b == 0x02) // U_State.req
        emit(0x07, g_hostUs + 100);
    else if ((b & 0xF8) == 0x18) // U_Configure.req 0 0 0 1 1 p c m
    {
        if (b & 0x02)
            crcMode = true;
        emit(0x01 | (crcMode ? 0x08 : 0) | (ownAddress ? 0x20 : 0), g_hostUs + 100); // U_Configure.ind
    }
    else if (b == 0xF1) // U_SetAddress.req + 2 address octets + dummy
    {
        _args.clear();
        _need = 3;
        _st = Rx::SetAddress;
    }
    else if (b == 0xF2) // U_SetRepetition.req + 3 octets
    {
        _need = 3;
        _st = Rx::SetRepetition;
    }
    else if (b >= 0x08 && b <= 0x0C) // U_L_DataOffset.req: bits 8..6 of the position, kept until the next one (p.42)
        _offsetHigh = (uint16_t)(b & 0x07) << 6;
    else if ((b & 0xC0) == 0x80) // U_L_DataStart/Continue.req + position
    {
        if (b == 0x80 && _offsetHigh == 0) // U_L_DataStart: a new frame, a new offset (p.49)
            _tx.clear();
        _pos = _offsetHigh | (b & 0x3F);
        _st = Rx::Data;
    }
    else if ((b & 0xC0) == 0x40) // U_L_DataEnd.req + position, then the check octet
    {
        _pos = _offsetHigh | (b & 0x3F);
        _offsetHigh = 0;
        _st = Rx::End;
    }
    else if ((b & 0xF8) == 0x10) // U_Ack.req
        ackRequests.push_back(b);
    else if (b == 0x05) // U_Busmon.req
        monitor = true;
    else if (b == 0x0D) // U_SystemStat.req -> U_SystemStat.ind: V20V VDD2 VBUS VFILT XTAL good, no TW, mode Normal
    {
        emit(0x4B, g_hostUs + 100);
        emit(0xFB, g_hostUs + 100);
    }
    else if (b >= 0x38 && b <= 0x3D) // U_IntRegRd.req: reset values of an NCN5130 (WD 0Fh, ACR1 60h, part 0Ch)
    {
        static const uint8_t reg[] = {0x0F, 0x00, 0x60, 0x00, 0x00, 0x0C};
        emit(reg[b - 0x38], g_hostUs + 100);
    }
    else if (b == 0x03 || b == 0x04 || b == 0x0E || b == 0x0F) // set/quit busy, stop, exit stop
    {
        if (b == 0x0E)
            emit(0x2B, g_hostUs + 100); // U_StopMode.ind
    }
    else
        unknown.push_back(b);
    return true;
}
