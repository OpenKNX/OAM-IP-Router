/**
 * @brief HostDevice and Peer, see host_device.h.
 */
#include "host_device.h"

#include "knx/bau07B0.h"

std::vector<uint8_t> encodeFrame(const Telegram& t)
{
    std::vector<uint8_t> f;
    const size_t n = t.tpdu.size();
    const uint8_t at = t.group ? 0x80 : 0x00;
    if (n >= 1 && n <= 16)
    {
        // Standard: CTRL SA SA DA DA [AT|hop|LG] TPDU FCS, LG = TPDU octets - 1.
        f = {(uint8_t)(t.ctrl ? t.ctrl : 0xBC), (uint8_t)(t.src >> 8), (uint8_t)t.src, (uint8_t)(t.dst >> 8), (uint8_t)t.dst,
             (uint8_t)(at | ((t.hop & 7) << 4) | ((n - 1) & 0x0F))};
    }
    else
    {
        // Extended: CTRL CTRLE SA SA DA DA LG TPDU FCS, frame type bit 7 of CTRL cleared.
        f = {(uint8_t)((t.ctrl ? t.ctrl : 0xBC) & 0x7F), (uint8_t)(at | ((t.hop & 7) << 4)), (uint8_t)(t.src >> 8), (uint8_t)t.src,
             (uint8_t)(t.dst >> 8), (uint8_t)t.dst, (uint8_t)(n - 1)};
    }
    f.insert(f.end(), t.tpdu.begin(), t.tpdu.end());
    f.push_back(NcnEmulator::fcs(f, f.size()));
    return f;
}

bool decodeFrame(const std::vector<uint8_t>& lpdu, Telegram& out)
{
    if (lpdu.size() < 8 || NcnEmulator::fcs(lpdu, lpdu.size() - 1) != lpdu.back())
        return false;
    out.ctrl = lpdu[0];
    if (lpdu[0] & 0x80)
    {
        const size_t lg = lpdu[5] & 0x0F;
        if (lpdu.size() != 8 + lg)
            return false;
        out.src = (uint16_t)(lpdu[1] << 8 | lpdu[2]);
        out.dst = (uint16_t)(lpdu[3] << 8 | lpdu[4]);
        out.group = (lpdu[5] & 0x80) != 0;
        out.hop = (lpdu[5] >> 4) & 7;
        out.tpdu.assign(lpdu.begin() + 6, lpdu.end() - 1);
    }
    else
    {
        if (lpdu.size() < 9 || lpdu.size() != 9u + lpdu[6])
            return false;
        out.src = (uint16_t)(lpdu[2] << 8 | lpdu[3]);
        out.dst = (uint16_t)(lpdu[4] << 8 | lpdu[5]);
        out.group = (lpdu[1] & 0x80) != 0;
        out.hop = (lpdu[1] >> 4) & 7;
        out.tpdu.assign(lpdu.begin() + 7, lpdu.end() - 1);
    }
    return true;
}

namespace
{
/** @brief The device BAU with its object lookup opened for the cases; the stack itself is unchanged. */
class HostBau : public Bau07B0
{
  public:
    using Bau07B0::Bau07B0;
    using Bau07B0::getInterfaceObject;
};
} // namespace

InterfaceObject* HostDevice::object(uint8_t idx) { return static_cast<HostBau*>(_bau.get())->getInterfaceObject(idx); }

HostDevice::HostDevice(std::vector<uint8_t>& flash, uint16_t pa) : _flash(flash), _pa(pa)
{
    boot(pa);
    run(300);
}

HostDevice::~HostDevice()
{
    _bau.reset(); // the stack goes before the platform it runs on
}

void HostDevice::boot(uint16_t pa)
{
    // A reset loses RAM, the unwritten flash sector included; flash and the transceiver stay.
    _bau.reset();
    _platform.reset(new HostPlatform(_flash));
    _platform->interface(&_chip);
    _bau.reset(new HostBau(*_platform));
    _bau->readMemory();
    // A device that restored an address keeps it; a fresh one gets the requested one.
    if (_bau->deviceObject().individualAddress() == 0xFFFF && pa != 0xFFFF)
        _bau->deviceObject().individualAddress(pa);
    _pa = _bau->deviceObject().individualAddress();
    _bau->enabled(true);
}

void HostDevice::run(uint32_t ms)
{
    for (uint32_t i = 0; i < ms * 10; i++)
    {
        try
        {
            _bau->loop();
        }
        catch (HostRestart&)
        {
            _reboots++;
            boot(0xFFFF);
        }
        hostAdvanceUs(100);
    }
}

std::vector<Telegram> HostDevice::sent(size_t from) const
{
    std::vector<Telegram> out;
    for (size_t i = from; i < _chip.sent.size(); i++)
    {
        Telegram t;
        if (decodeFrame(_chip.sent[i], t))
            out.push_back(t);
    }
    return out;
}

int HostDevice::garbled() const
{
    int n = 0;
    Telegram t;
    for (auto& f : _chip.sent)
        if (!decodeFrame(f, t))
            n++;
    return n;
}

void Peer::sendTpdu(const std::vector<uint8_t>& tpdu, bool group, uint16_t dst)
{
    Telegram t;
    t.src = _pa;
    t.dst = (dst == 0xFFFF && !group) ? _dev.pa() : dst;
    t.group = group;
    t.tpdu = tpdu;
    _dev.chip().inject(encodeFrame(t));
}

void Peer::connect()
{
    sendTpdu({0x80}); // T_Connect
    _dev.run(50);
    _connected = true;
    seqSend = seqRecv = 0;
}

void Peer::disconnect()
{
    sendTpdu({0x81}); // T_Disconnect
    _dev.run(50);
    _connected = false;
}

Peer::Result Peer::request(uint16_t apci, const std::vector<uint8_t>& data, int expectApci, uint32_t timeoutMs)
{
    const size_t mark = _dev.sentCount();
    const uint8_t sentSeq = seqSend;
    std::vector<uint8_t> tpdu;
    const uint8_t tpci = _connected ? (uint8_t)(0x40 | (sentSeq << 2)) : 0x00;
    tpdu.push_back((uint8_t)(tpci | ((apci >> 8) & 0x03)));
    tpdu.push_back((uint8_t)apci);
    tpdu.insert(tpdu.end(), data.begin(), data.end());
    sendTpdu(tpdu);

    Result r;
    size_t seen = mark;
    for (uint32_t waited = 0; waited < timeoutMs; waited += 10)
    {
        _dev.run(10);
        for (; seen < _dev.sentCount(); seen++)
        {
            Telegram t;
            if (!decodeFrame(_dev.chip().sent[seen], t) || t.group || t.src != _dev.pa() || t.dst != _pa || t.tpdu.empty())
                continue;
            const uint8_t c = t.tpdu[0];
            if ((c & 0xC3) == 0xC2) // T_ACK
            {
                if (((c >> 2) & 0x0F) == sentSeq)
                {
                    r.acks++;
                    seqSend = (sentSeq + 1) & 0x0F;
                    if (expectApci == AckOnly)
                        return r;
                }
                continue;
            }
            if ((c & 0xC3) == 0xC3) // T_NAK
            {
                r.naks++;
                continue;
            }
            if (c == 0x81) // T_Disconnect
            {
                r.disconnected = true;
                _connected = false;
                continue;
            }
            if ((c & 0x80) || t.tpdu.size() < 2)
                continue;
            if (c & 0x40) // numbered data: acknowledge it, or the device repeats and disconnects
            {
                const uint8_t seq = (c >> 2) & 0x0F;
                if (seq == ((seqRecv - 1) & 0x0F)) // a repetition of the last answer: ACK again, do not take it (03_03_04 E05/A3)
                {
                    sendTpdu({(uint8_t)(0xC2 | (seq << 2))});
                    continue;
                }
                if (seq != seqRecv)
                {
                    r.seqErrors++;
                    continue;
                }
                sendTpdu({(uint8_t)(0xC2 | (seq << 2))});
                seqRecv = (seq + 1) & 0x0F;
            }
            const uint16_t got = (uint16_t)(((c & 0x03) << 8) | t.tpdu[1]);
            if (expectApci >= 0 && got != (uint16_t)expectApci)
                continue;
            r.answered = true;
            r.apci = got;
            r.apdu.assign(t.tpdu.begin(), t.tpdu.end());
            r.telegram = t;
            _dev.run(20); // let our T_ACK go out before the caller continues
            return r;
        }
    }
    return r;
}
