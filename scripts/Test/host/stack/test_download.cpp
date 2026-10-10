/**
 * @brief Cases that need a configured device: an ETS-style download of the four tables first.
 *
 * The download follows 03_05_03 DMP_DownloadLoadablePart as this stack serves it: PID_LOAD_STATE_CONTROL
 * start loading, an additional load control that allocates the table, A_MemoryExtended_Write of the table
 * at the address PID_TABLE_REFERENCE names, load completed. It is a model of ETS, not ETS.
 */
#include <algorithm>
#include <cstring>

#include "host_device.h"
#include "host_test.h"
#include "knx/bau07B0.h"
#include "knx/address_table_object.h"
#include "knx/group_object.h"
#include "test_util.h"

using namespace mgmt;

namespace
{
constexpr uint16_t kDevice = 0x110A;
constexpr uint16_t kEts = 0x1101;
constexpr uint16_t kGa = 0x0901; // 1/1/1

std::vector<uint8_t> words(std::initializer_list<uint16_t> w)
{
    std::vector<uint8_t> out;
    for (uint16_t v : w)
    {
        out.push_back((uint8_t)(v >> 8));
        out.push_back((uint8_t)v);
    }
    return out;
}

/** @brief Loads one table object; `size` is what the allocation asks for (defaults to the data length). */
uint8_t download(Peer& p, uint8_t obj, const std::vector<uint8_t>& table, uint32_t size = 0)
{
    if (size == 0)
        size = (uint32_t)table.size();
    loadEvent(p, obj, {0x01});
    loadEvent(p, obj, allocControl(size));
    auto ref = propRead(p, obj, 7, 1, 1);
    auto r = propData(ref);
    EXPECT(r.size() == 4, "no PID_TABLE_REFERENCE for object " << (int)obj);
    const uint32_t addr = ((uint32_t)r[0] << 24) | ((uint32_t)r[1] << 16) | ((uint32_t)r[2] << 8) | r[3];
    for (size_t off = 0; off < table.size(); off += 32)
    {
        const size_t n = std::min<size_t>(32, table.size() - off);
        std::vector<uint8_t> d = {(uint8_t)n, (uint8_t)((addr + off) >> 16), (uint8_t)((addr + off) >> 8), (uint8_t)(addr + off)};
        d.insert(d.end(), table.begin() + off, table.begin() + off + n);
        auto w = p.request(MemExtWrite, d, MemExtWriteResponse);
        EXPECT(w.answered && w.apdu.size() >= 3 && w.apdu[2] == 0x00, "table write failed: " << hex(w.apdu));
    }
    auto done = loadEvent(p, obj, {0x02});
    auto st = propData(done);
    return st.empty() ? 0xFF : st[0];
}

/** @brief One group address, associated with group object 1 of the given value type code, then the restart
 *         ETS sends after a download (configured() latches false until the next start). */
void configure(HostDevice& dev, Peer& p, uint8_t goCode)
{
    EXPECT(download(p, 1, words({1, kGa})) == 1, "address table not Loaded");
    EXPECT(download(p, 2, words({1, 1, 1})) == 1, "association table not Loaded");
    EXPECT(download(p, 3, words({1, (uint16_t)(0x5C00 | goCode)})) == 1, "group object table not Loaded");
    EXPECT(download(p, 4, std::vector<uint8_t>(16, 0)) == 1, "application program not Loaded");
    p.disconnect();
    p.sendTpdu({0x03, 0x80}); // A_Restart, basic
    dev.run(1500);
    EXPECT(dev.reboots() >= 1, "the device did not restart after the download");
}

/** @brief Two group addresses, each associated with its own one-octet group object. */
void configureTwo(HostDevice& dev, Peer& p)
{
    const uint16_t kGa2 = kGa + 1;
    EXPECT(download(p, 1, words({2, kGa, kGa2})) == 1, "address table not Loaded");
    EXPECT(download(p, 2, words({2, 1, 1, 2, 2})) == 1, "association table not Loaded");
    EXPECT(download(p, 3, words({2, (uint16_t)0x5C01, (uint16_t)0x5C01})) == 1, "group object table not Loaded");
    EXPECT(download(p, 4, std::vector<uint8_t>(16, 0)) == 1, "application program not Loaded");
    p.disconnect();
    p.sendTpdu({0x03, 0x80});
    dev.run(1500);
    EXPECT(dev.reboots() >= 1, "the device did not restart after the download");
}

/** @brief Group telegram from the peer, then the device's answer to a read on the same address. */
std::vector<uint8_t> writeThenRead(HostDevice& dev, Peer& p, const std::vector<uint8_t>& writeTpdu)
{
    p.sendTpdu(writeTpdu, true, kGa);
    dev.run(300);
    const size_t mark = dev.sentCount();
    p.sendTpdu({0x00, 0x00}, true, kGa); // A_GroupValue_Read
    dev.run(500);
    for (auto& t : dev.sent(mark))
        if (t.group && t.dst == kGa && t.tpdu.size() >= 2 && (t.tpdu[1] & 0xC0) == 0x40)
            return t.tpdu;
    return {};
}
/** @brief Outcome of one parameter download. */
struct ParamLoad
{
    int blocks = 0;
    int wrong = 0;         // read-back answers that differ from the block just written
    std::string firstWrong;
    int erases = 0;        // sector erases while the blocks were written
    bool stored = false;   // the flash holds the whole image once the load completed and was saved
};

enum class ReadBack
{
    None,       // no verify
    VerifyMode, // DMP_MemWrite_RCoV: Verify Mode set, each A_Memory_Write answered by A_Memory_Response
    ReadAfter   // DMP_MemWrite_RCo: an A_Memory_Read after each block
};

/**
 * @brief Loads `size` octets of parameters as ETS loads LdCtrlWriteRelMem: a segment allocated with fill 00h,
 *        then 12-octet A_Memory_Write blocks, the size 03_05_02 3.16 p.100 gives without extended frames.
 */
ParamLoad loadParameters(HostDevice& dev, Peer& p, uint32_t size, ReadBack mode)
{
    ParamLoad l;
    if (mode == ReadBack::VerifyMode)
    {
        auto dc = propWrite(p, 0, 14, 1, 1, {0x04}); // PID_DEVICE_CONTROL, bit 2 = verify mode
        EXPECT(propData(dc) == std::vector<uint8_t>({0x04}), "verify mode not set: " << hex(dc.apdu));
    }
    loadEvent(p, 4, {0x01});
    loadEvent(p, 4, allocControl(size));
    auto r = propData(propRead(p, 4, 7, 1, 1));
    EXPECT(r.size() == 4, "no PID_TABLE_REFERENCE for the parameters");
    const uint32_t addr = ((uint32_t)r[0] << 24) | ((uint32_t)r[1] << 16) | ((uint32_t)r[2] << 8) | r[3];
    EXPECT(addr + size <= 0x10000, "segment outside the 16-bit memory services");

    std::vector<uint8_t> image(size);
    for (uint32_t i = 0; i < size; i++)
        image[i] = (uint8_t)(0x11 + i * 7);

    const int erasesBefore = dev.platform().erases();
    for (uint32_t off = 0; off < size; off += 12)
    {
        const uint8_t n = (uint8_t)std::min<uint32_t>(12, size - off);
        const uint16_t a = (uint16_t)(addr + off);
        std::vector<uint8_t> block = {(uint8_t)(a >> 8), (uint8_t)a};
        block.insert(block.end(), image.begin() + off, image.begin() + off + n);
        l.blocks++;

        Peer::Result back;
        if (mode == ReadBack::VerifyMode)
            back = p.request(MemWrite | n, block, MemResponse | n);
        else
        {
            auto w = p.request(MemWrite | n, block, Peer::AckOnly, 500);
            EXPECT(w.acks == 1, "block at " << std::hex << a << " not acknowledged");
            if (mode == ReadBack::ReadAfter)
                back = p.request(MemRead | n, {(uint8_t)(a >> 8), (uint8_t)a}, MemResponse | n);
        }
        if (mode != ReadBack::None)
        {
            const bool same = back.answered && back.apdu.size() == block.size() + 2 &&
                              std::equal(block.begin(), block.end(), back.apdu.begin() + 2);
            if (!same && l.wrong++ == 0)
                l.firstWrong = hex(block) + " answered " + hex(back.apdu);
        }
    }
    l.erases = dev.platform().erases() - erasesBefore;

    auto done = propData(loadEvent(p, 4, {0x02}));
    EXPECT(done == std::vector<uint8_t>({0x01}), "parameters not Loaded: " << hex(done));
    dev.run(6000); // past the save timer
    l.stored = memcmp(dev.platform().flashRead() + addr, image.data(), size) == 0;
    return l;
}

/** @brief One parameter download on a fresh device. */
ParamLoad freshLoad(uint32_t size, ReadBack mode)
{
    std::vector<uint8_t> flash;
    HostDevice dev(flash, kDevice);
    Peer peer(dev, kEts);
    peer.connect();
    return loadParameters(dev, peer, size, mode);
}

constexpr uint32_t kParamSize = 9000; // crosses at least two 4 KiB sectors
} // namespace

HOST_TEST("HD-8.1v", "A download in verify mode gets each block back and costs no more flash erases than one without")
{
    // 03_05_02 3.16.3 p.101-102 (DMP_MemWrite_RCoV); the product templates load with Verify="true". The
    // A_Memory_Response is built while the block still sits in the flash driver's sector buffer.
    const ParamLoad plain = freshLoad(kParamSize, ReadBack::None);
    const ParamLoad verified = freshLoad(kParamSize, ReadBack::VerifyMode);
    NOTE(plain.blocks << " blocks; erases without verify " << plain.erases << ", in verify mode " << verified.erases
                      << "; verify answers wrong " << verified.wrong);
    EXPECT(verified.wrong == 0, verified.wrong << " of " << verified.blocks << " verify answers differ, first: " << verified.firstWrong);
    EXPECT(plain.stored && verified.stored, "the flash does not hold the downloaded parameters");
    EXPECT(verified.erases <= plain.erases, "verify mode costs " << verified.erases << " sector erases, the same download without it " << plain.erases);
}

HOST_TEST("HD-8.1r", "A download read back block by block gets each block back")
{
    // 03_05_02 3.16.2 p.100-101 (DMP_MemWrite_RCo). The erase count is noted: each read after a write finds a
    // changed sector buffer.
    const ParamLoad plain = freshLoad(kParamSize, ReadBack::None);
    const ParamLoad readAfter = freshLoad(kParamSize, ReadBack::ReadAfter);
    NOTE(plain.blocks << " blocks; erases without read-back " << plain.erases << ", with a read after each block " << readAfter.erases
                      << "; read-back answers wrong " << readAfter.wrong);
    EXPECT(readAfter.wrong == 0, readAfter.wrong << " of " << readAfter.blocks << " read-back answers differ, first: " << readAfter.firstWrong);
    EXPECT(readAfter.stored, "the flash does not hold the downloaded parameters");
}

HOST_TEST("HD-0.1", "Control: a downloaded device keeps a one-octet value written to its group address")
{
    std::vector<uint8_t> flash;
    HostDevice dev(flash, kDevice);
    Peer peer(dev, kEts);
    peer.connect();
    configure(dev, peer, 7); // one octet
    EXPECT(dev.bau().configured(), "device not configured after the download and restart");
    auto answer = writeThenRead(dev, peer, {0x00, 0x80, 0x5A});
    NOTE("read answer " << hex(answer));
    EXPECT(answer == std::vector<uint8_t>({0x00, 0x40, 0x5A}), "answer " << hex(answer));
}

HOST_TEST("HD-13.2", "A two-bit group object has storage for its value")
{
    // Value type code 1 is two bits (DPT 2.x); the value rides in the APCI octet (03_03_07 A_GroupValue_Write).
    std::vector<uint8_t> flash;
    HostDevice dev(flash, kDevice);
    Peer peer(dev, kEts);
    peer.connect();
    configure(dev, peer, 1);
    // AddressSanitizer treats new[0] as one byte, so a one-octet write into a zero-byte block is not seen:
    // the storage is checked directly.
    GroupObject& go = dev.bau().groupObjectTable().get(1);
    NOTE("storage " << go.sizeInMemory() << " octet(s) for a value of " << go.valueSize());
    EXPECT(go.sizeInMemory() >= go.valueSize(), "a two-bit object got " << go.sizeInMemory() << " octet(s) of storage for a " << go.valueSize() << "-octet value");
    auto answer = writeThenRead(dev, peer, {0x00, 0x83});
    NOTE("read answer " << hex(answer));
    EXPECT(answer == std::vector<uint8_t>({0x00, 0x43}), "answer " << hex(answer));
}

HOST_TEST("HD-10.17", "An address table whose count exceeds its allocation is not used")
{
    // Count 256 in a 4-octet table (FFFFh would hit the separate "empty table" marker instead). The lookup
    // must not walk 256 entries of whatever follows in the NVM, so the one real address goes unanswered.
    std::vector<uint8_t> flash;
    HostDevice dev(flash, kDevice);
    Peer peer(dev, kEts);
    peer.connect();
    const uint8_t st = download(peer, 1, words({0x0100, kGa}), 4);
    EXPECT(download(peer, 2, words({1, 1, 1})) == 1, "association table not Loaded");
    EXPECT(download(peer, 3, words({1, 0x5C07})) == 1, "group object table not Loaded");
    EXPECT(download(peer, 4, std::vector<uint8_t>(16, 0)) == 1, "application program not Loaded");
    peer.disconnect();
    peer.sendTpdu({0x03, 0x80});
    dev.run(1500);
    auto answer = writeThenRead(dev, peer, {0x00, 0x80, 0x5A});
    // The walk past the table stays inside the NVM image, where the sanitizer cannot see it, and on this
    // layout it matches nothing either way; the count the lookups use is the observable.
    const uint16_t n = static_cast<AddressTableObject*>(dev.object(1))->entryCount();
    NOTE("address table state " << (int)st << ", entries used " << n << ", read answer " << hex(answer));
    EXPECT(n == 0, "the lookups use " << n << " entries of a 4-octet table");
    EXPECT(answer.empty(), "the device answered through an address table whose count its allocation cannot back: " << hex(answer));
}

HOST_TEST("HD-10.16", "A group object table whose count exceeds its allocation is not read past its end")
{
    std::vector<uint8_t> flash;
    HostDevice dev(flash, kDevice);
    Peer peer(dev, kEts);
    peer.connect();
    EXPECT(download(peer, 1, words({1, kGa})) == 1, "address table not Loaded");
    EXPECT(download(peer, 2, words({1, 1, 1})) == 1, "association table not Loaded");
    const uint8_t st = download(peer, 3, words({0xFFFF, 0x5C07}), 4); // count FFFFh in a 4-octet table
    NOTE("group object table state " << (int)st);
    EXPECT(download(peer, 4, std::vector<uint8_t>(16, 0)) == 1, "application program not Loaded");
    peer.disconnect();
    peer.sendTpdu({0x00, 0x80, 0x01}, true, kGa);
    dev.run(500);
}

HOST_TEST("HD-10.18", "A power cut during a group object table download boots with the table not Loaded")
{
    std::vector<uint8_t> flash;
    {
        HostDevice dev(flash, kDevice);
        Peer peer(dev, kEts);
        peer.connect();
        loadEvent(peer, 3, {0x01});
        loadEvent(peer, 3, allocControl(4));
        auto ref = propData(propRead(peer, 3, 7, 1, 1));
        const uint32_t addr = ((uint32_t)ref[0] << 24) | ((uint32_t)ref[1] << 16) | ((uint32_t)ref[2] << 8) | ref[3];
        peer.request(MemExtWrite, {4, (uint8_t)(addr >> 16), (uint8_t)(addr >> 8), (uint8_t)addr, 0xFF, 0xFF, 0x5C, 0x07}, MemExtWriteResponse);
        dev.run(6000); // past the save timer, no load completed
        dev.platform().dropUncommitted();
    }
    HostDevice again(flash, kDevice); // the sanitizer judges the restore of a bogus header
    Peer peer(again, kEts);
    peer.connect();
    auto st = propData(propRead(peer, 3, 5, 1, 1));
    const uint16_t n = again.bau().groupObjectTable().entryCount();
    NOTE("group object table state after the power cut " << hex(st) << ", entries " << n);
    EXPECT(st != std::vector<uint8_t>({0x01}), "a table never completed came back Loaded");
    EXPECT(n == 0, "group objects were rebuilt from a table that was never completed (" << n << " entries)");
}

HOST_TEST("HD-6.5", "Two group objects sending in one round both learn how it went")
{
    std::vector<uint8_t> flash;
    HostDevice dev(flash, 0x110A);
    Peer p(dev, 0x1101);
    configureTwo(dev, p);
    dev.chip().present.insert(0x1101);

    GroupObjectTableObject& table = dev.bau().groupObjectTable();
    EXPECT(table.entryCount() >= 2, "the device did not come up with two group objects");

    GroupObject& a = table.get(1);
    GroupObject& b = table.get(2);

    // Both objects want to send in the same period, which is what an application does when two values
    // change together. The stack sends one telegram per loop pass and does not wait for the confirmation
    // in between, so both are on their way long before the first one is confirmed.
    const size_t mark = dev.sentCount();
    a.valueRef()[0] = 1;
    b.valueRef()[0] = 1;
    a.commFlag(WriteRequest);
    b.commFlag(WriteRequest);

    dev.run(2000);

    int sent = 0;
    for (auto& t : dev.sent(mark))
        if (t.group) sent++;

    NOTE("group telegrams on the line: " << sent << ", first object flag " << (int)a.commFlag()
         << ", second " << (int)b.commFlag() << " (3 = still transmitting, 4 = ok)");
    EXPECT(sent >= 2, "the device did not send both group telegrams, so nothing was under test");
    EXPECT(a.commFlag() != Transmitting, "the first object never learned that its telegram went out");
    EXPECT(b.commFlag() != Transmitting, "the second object never learned that its telegram went out");
}

HOST_TEST("HD-3.10", "Committing the same image again costs no flash erase")
{
    std::vector<uint8_t> flash;
    HostDevice dev(flash, 0x110A);
    Peer p(dev, 0x1101);
    configure(dev, p, 0x01);

    // Every M_Reset_req makes the cEMI server commit the whole NVM, and ETS sends one per download step.
    // What that costs is measured here rather than argued about: the first commit after a download may
    // well have something to write, the second one cannot.
    dev.bau().writeMemory();
    dev.run(200);
    const int afterFirst = dev.platform().erases();

    dev.bau().writeMemory();
    dev.run(200);
    const int afterSecond = dev.platform().erases();

    dev.bau().writeMemory();
    dev.run(200);
    const int afterThird = dev.platform().erases();

    // Control: the measurement only means something if a real change DOES reach the flash.
    dev.bau().deviceObject().individualAddress(0x110B);
    dev.bau().writeMemory();
    dev.run(200);
    const int afterChange = dev.platform().erases();

    NOTE("sector erases: after the first repeat commit " << afterFirst << ", second " << afterSecond
         << ", third " << afterThird << ", after a changed address " << afterChange);
    EXPECT(afterSecond == afterFirst && afterThird == afterSecond,
           "an unchanged image was written to flash again");
    EXPECT(afterChange > afterThird,
           "a changed individual address did not reach the flash, so the measurement above proves nothing");
}

HOST_TEST("HL-2.1b", "Group telegrams whose transport control field is not T_Data_Group change nothing")
{
    // 08_03_04 2.1 b) p.8-9, telegrams (3), (6), (9), (10): TPCI 40h, 80h, C0h, 10h on a group address. 03_03_04
    // Figure 3 p.6 defines only 000000b there (000001b is T_Data_Tag_Group). One-bit object with update on
    // response, so (6) is a real stimulus; the value is set to 1 first, as in (2).
    std::vector<uint8_t> flash;
    HostDevice dev(flash, kDevice);
    Peer peer(dev, kEts);
    peer.connect();
    EXPECT(download(peer, 1, words({1, kGa})) == 1, "address table not Loaded");
    EXPECT(download(peer, 2, words({1, 1, 1})) == 1, "association table not Loaded");
    EXPECT(download(peer, 3, words({1, (uint16_t)0xDC00})) == 1, "group object table not Loaded");
    EXPECT(download(peer, 4, std::vector<uint8_t>(16, 0)) == 1, "application program not Loaded");
    peer.disconnect();
    peer.sendTpdu({0x03, 0x80}); // A_Restart, basic
    dev.run(1500);
    EXPECT(dev.bau().configured(), "device not configured after the download and restart");

    // Each stimulus starts from value 1 and all are judged together, so every one shows on its own.
    std::string taken;
    for (const auto& bad : std::vector<std::vector<uint8_t>>{{0x40, 0x80}, {0x80, 0x40, 0x00}, {0x10, 0x80}})
    {
        auto base = writeThenRead(dev, peer, {0x00, 0x81});
        EXPECT(base == std::vector<uint8_t>({0x00, 0x41}), "control: a valid write of 1 reads back " << hex(base));
        auto answer = writeThenRead(dev, peer, bad);
        NOTE(hex(bad) << " -> read " << hex(answer));
        if (answer != std::vector<uint8_t>({0x00, 0x41}))
            taken += hex(bad) + " (reads " + hex(answer) + ") ";
    }
    EXPECT(taken.empty(), "the object took " << taken);
    const size_t mark = dev.sentCount();
    peer.sendTpdu({0xC0, 0x00}, true, kGa); // (9) read with an undefined control field
    dev.run(500);
    for (auto& t : dev.sent(mark))
        EXPECT(!(t.group && t.dst == kGa), "the device answered a group read with TPCI C0h: " << hex(t.tpdu));
    auto zero = writeThenRead(dev, peer, {0x00, 0x80});
    EXPECT(zero == std::vector<uint8_t>({0x00, 0x40}), "control: a valid write of 0 reads back " << hex(zero));
    EXPECT(dev.garbled() == 0, dev.garbled() << " frame(s) on the bus did not decode");
}
