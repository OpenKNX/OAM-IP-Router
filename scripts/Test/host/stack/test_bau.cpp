/**
 * @brief BAU, property and table cases on a TP1 System B device (07B0), judged on the bus.
 *
 * Each case names the finding it pins. Expectations come from 03_03_07 / 03_05_01 / 03_05_02 and the
 * finding, never from what the stack answers today.
 */
#include "host_device.h"
#include "host_test.h"
#include "knx/bau07B0.h"
#include "test_util.h"

using namespace mgmt;

namespace
{
constexpr uint16_t kDevice = 0x110A; // 1.1.10
constexpr uint16_t kEts = 0x1101;    // 1.1.1

struct Rig
{
    std::vector<uint8_t> flash;
    HostDevice dev{flash, kDevice};
    Peer peer{dev, kEts};
    Rig() { peer.connect(); }
};

std::vector<uint8_t> readSerial(Peer& p)
{
    auto r = propRead(p, 0, 11, 1, 1);
    EXPECT(r.answered && propCount(r) == 1, "serial number not readable: " << hex(r.apdu));
    return propData(r);
}
} // namespace

// ---- 8.x management services ------------------------------------------------------------------------

HOST_TEST("HB-8.1", "Verify mode reads memory back: a refused write is answered with 0 octets")
{
    Rig rig;
    auto dc = propWrite(rig.peer, 0, 14, 1, 1, {0x04}); // PID_DEVICE_CONTROL: verify mode
    EXPECT(dc.answered, "PID_DEVICE_CONTROL write not answered");
    auto r = rig.peer.request(MemWrite | 4, {0xFF, 0x00, 0xDE, 0xAD, 0xBE, 0xEF}, -1); // outside the 0x8000 NVM
    NOTE("answer " << hex(r.apdu));
    EXPECT(r.answered && (r.apci & 0x3C0) == MemResponse, "no A_Memory_Response in verify mode");
    EXPECT((r.apci & 0x3F) == 0, "verify answered " << (r.apci & 0x3F) << " octets for a write outside the NVM - it echoed the request");
}

HOST_TEST("HB-8.1c", "Control: verify mode returns the written octets inside the NVM")
{
    Rig rig;
    propWrite(rig.peer, 0, 14, 1, 1, {0x04});
    auto r = rig.peer.request(MemWrite | 4, {0x7F, 0x00, 0xDE, 0xAD, 0xBE, 0xEF}, -1);
    NOTE("answer " << hex(r.apdu));
    EXPECT(r.answered && r.apci == (MemResponse | 4), "verify answer " << hex(r.apdu));
    EXPECT(std::vector<uint8_t>(r.apdu.begin() + 4, r.apdu.end()) == std::vector<uint8_t>({0xDE, 0xAD, 0xBE, 0xEF}), "read-back " << hex(r.apdu));
}

HOST_TEST("HB-8.1e", "Verify mode answers 0 octets for a write across the NVM end and stores none of it")
{
    // 03_03_07 A_Memory_Write error handling: a partly non-existent range fails as a whole; in verify mode the
    // response carries number 0 and no data.
    Rig rig;
    propWrite(rig.peer, 0, 14, 1, 1, {0x04});
    auto before = rig.peer.request(MemRead | 2, {0x7F, 0xFE}, MemResponse | 2);
    auto r = rig.peer.request(MemWrite | 4, {0x7F, 0xFE, 0x11, 0x22, 0x33, 0x44}, -1); // 2 octets inside, 2 past 8000h
    auto after = rig.peer.request(MemRead | 2, {0x7F, 0xFE}, MemResponse | 2);
    NOTE("answer " << hex(r.apdu) << ", 7FFE before " << hex(before.apdu) << ", after " << hex(after.apdu));
    EXPECT(r.answered && r.apci == MemResponse, "verify answer " << hex(r.apdu));
    auto octets = [](const Peer::Result& x) { return x.apdu.size() > 4 ? std::vector<uint8_t>(x.apdu.begin() + 4, x.apdu.end()) : std::vector<uint8_t>(); };
    EXPECT(before.answered && after.answered && octets(before).size() == 2 && octets(before) == octets(after), "the part inside the NVM was written");
}

HOST_TEST("HB-8.1u", "Verify mode answers A_UserMemory_Write with the written octets, and 0 octets outside the NVM")
{
    Rig rig;
    propWrite(rig.peer, 0, 14, 1, 1, {0x04});
    // [number | address bits 16-19] [address 15-8] [address 7-0] data
    auto in = rig.peer.request(0x2C2, {0x04, 0x70, 0x00, 0xDE, 0xAD, 0xBE, 0xEF}, 0x2C1);
    NOTE("inside: " << hex(in.apdu));
    EXPECT(in.answered && in.apdu.size() == 9 && (in.apdu[2] & 0x0F) == 4, "answer " << hex(in.apdu));
    EXPECT(in.apdu.size() == 9 && std::vector<uint8_t>(in.apdu.begin() + 5, in.apdu.end()) == std::vector<uint8_t>({0xDE, 0xAD, 0xBE, 0xEF}),
           "verify returned " << hex(in.apdu));
    auto out = rig.peer.request(0x2C2, {0x14, 0x00, 0x00, 0xDE, 0xAD, 0xBE, 0xEF}, 0x2C1); // 10000h, past the NVM
    NOTE("outside: " << hex(out.apdu));
    EXPECT(out.answered && out.apdu.size() == 5 && (out.apdu[2] & 0x0F) == 0, "answer " << hex(out.apdu));
}

HOST_TEST("HB-6.11", "A memory write whose count does not match its payload is answered 0 octets and stores nothing")
{
    // 08_03_07 2.7.7 p.34 sends both shapes with verify on and expects A_Memory_Response count 0 with no
    // data, and the memory unchanged; 03_03_07 p.113 says the indication is ignored.
    Rig rig;
    propWrite(rig.peer, 0, 14, 1, 1, {0x04});
    auto octets = [](const Peer::Result& x) { return x.apdu.size() > 4 ? std::vector<uint8_t>(x.apdu.begin() + 4, x.apdu.end()) : std::vector<uint8_t>(); };
    auto before = rig.peer.request(MemRead | 4, {0x02, 0x00}, MemResponse | 4);

    auto more = rig.peer.request(MemWrite | 3, {0x02, 0x00, 0x12, 0x34}, -1);       // count 3, two octets
    auto less = rig.peer.request(MemWrite | 2, {0x02, 0x00, 0xAA, 0xBB, 0xCC}, -1); // count 2, three octets
    auto after = rig.peer.request(MemRead | 4, {0x02, 0x00}, MemResponse | 4);
    NOTE("count above payload " << hex(more.apdu) << ", below " << hex(less.apdu) << ", memory " << hex(before.apdu) << " -> " << hex(after.apdu));
    EXPECT(more.answered && more.apci == MemResponse, "count above the payload answered " << hex(more.apdu));
    EXPECT(less.answered && less.apci == MemResponse, "count below the payload answered " << hex(less.apdu));
    EXPECT(before.answered && after.answered && octets(before).size() == 4 && octets(before) == octets(after),
           "memory changed: " << hex(before.apdu) << " -> " << hex(after.apdu));
}

HOST_TEST("HB-8.2", "A_MemoryExtended_Write outside the NVM is not answered Success")
{
    Rig rig;
    auto r = rig.peer.request(MemExtWrite, {4, 0xFF, 0xFF, 0x00, 1, 2, 3, 4}, MemExtWriteResponse);
    NOTE("answer " << hex(r.apdu));
    EXPECT(r.answered && r.apdu.size() >= 3, "no A_MemoryExtended_WriteResponse");
    EXPECT(r.apdu[2] != 0x00, "a write that went nowhere was answered Success");
}

HOST_TEST("HB-8.8", "A_MemoryExtended_Read of 255 octets is refused with F4h, not truncated")
{
    Rig rig;
    auto r = rig.peer.request(MemExtRead, {255, 0x00, 0x00, 0x00}, MemExtReadResponse);
    NOTE("answer " << hex(r.apdu));
    EXPECT(r.answered && r.apdu.size() >= 6, "no A_MemoryExtended_ReadResponse");
    EXPECT(r.apdu[2] == 0xF4 && r.apdu.size() == 6, "expected F4h with no data, got rc " << std::hex << (int)r.apdu[2] << " and " << std::dec << (r.apdu.size() - 6) << " data octets");
}

HOST_TEST("HB-8.4", "A refused erase code does not reset the device")
{
    Rig rig;
    auto r = masterReset(rig.peer, 0x00, 0x00); // 00h is reserved (03_05_02 Table 4 p.82)
    EXPECT(r.answered && r.apdu.size() >= 3, "no A_Restart_Response");
    NOTE("error " << std::hex << (int)r.apdu[2]);
    rig.dev.run(5000);
    EXPECT(r.apdu[2] == 0x02, "reserved erase code answered " << std::hex << (int)r.apdu[2]);
    EXPECT(rig.dev.reboots() == 0, "the device restarted after refusing the request");
}

HOST_TEST("HB-8.5a", "Reserved erase code with channel 05h answers 02h, the erase code comes first")
{
    Rig rig;
    auto r = masterReset(rig.peer, 0x00, 0x05);
    EXPECT(r.answered && r.apdu.size() >= 3, "no A_Restart_Response");
    EXPECT(r.apdu[2] == 0x02, "answered " << std::hex << (int)r.apdu[2] << ", 03_05_02 p.88 checks the erase code before the channel");
}

HOST_TEST("HB-8.5b", "Confirmed restart with channel 05h answers 03h and does not restart")
{
    Rig rig;
    auto r = masterReset(rig.peer, 0x01, 0x05); // 01h fixes the channel to 00h (Table 4 p.82)
    EXPECT(r.answered && r.apdu.size() >= 3, "no A_Restart_Response");
    rig.dev.run(5000);
    EXPECT(r.apdu[2] == 0x03, "answered " << std::hex << (int)r.apdu[2]);
    EXPECT(rig.dev.reboots() == 0, "the device restarted although it refused the request");
}

HOST_TEST("HB-8.5c", "Control: confirmed restart with channel 00h restarts the device")
{
    Rig rig;
    auto r = masterReset(rig.peer, 0x01, 0x00);
    NOTE("answer " << hex(r.apdu) << " (its absence is finding 8.3, see HB-8.3)");
    rig.dev.run(6000);
    EXPECT(rig.dev.reboots() >= 1, "no restart - the harness cannot see restarts, so HB-8.4/8.5b prove nothing");
}

HOST_TEST("HB-8.3", "A confirmed restart is answered before the device restarts")
{
    // 03_05_02 3.7.2/3.7.3: the server answers A_Restart_Response with the process time, then restarts.
    Rig rig;
    auto r = masterReset(rig.peer, 0x01, 0x00);
    rig.dev.run(6000);
    NOTE("reboots " << rig.dev.reboots());
    EXPECT(r.answered && r.apdu.size() >= 3 && r.apdu[2] == 0x00, "no A_Restart_Response reached the bus before the restart");
}

HOST_TEST("HB-8.3c", "The announced process time covers the restart this build actually needs")
{
    // 03_05_02 3.7.3 p.89: the client takes this value as the TIME-OUT after which contact counts as
    // failed, so announcing less than the recovery time declares a booting device dead. Nothing pinned
    // it before, which is how an inherited example value of 3 s survived until D-17.5 measured 3.5 s on
    // real hardware. This build is TP-only (no USE_IP), so 10 s is the value under test.
    Rig rig;
    auto r = masterReset(rig.peer, 0x01, 0x00);
    rig.dev.run(6000);
    const unsigned announced = (r.apdu.size() >= 5) ? ((unsigned)r.apdu[3] << 8 | r.apdu[4]) : 0;
    NOTE("announced " << announced << " s");
    EXPECT(announced == 10, "the announced process time is not the 10 s a TP build needs after a real restart");
}

HOST_TEST("HB-6.2", "A connectionless master reset is answered to the requester, not to 15.15.255")
{
    std::vector<uint8_t> flash;
    HostDevice dev(flash, kDevice);
    Peer peer(dev, kEts); // not connected
    const size_t mark = dev.sentCount();
    auto r = masterReset(peer, 0x00, 0x00);
    for (auto& t : dev.sent(mark))
        if (t.tpdu.size() >= 2 && (((t.tpdu[0] & 3) << 8) | t.tpdu[1]) == RestartResponse)
            NOTE("A_Restart_Response to " << std::hex << t.dst);
    EXPECT(r.answered, "no A_Restart_Response addressed to the requester");
}

HOST_TEST("HB-8.7", "A property write with no data octets is answered with nr_of_elem 0")
{
    Rig rig;
    auto r = propWrite(rig.peer, 0, 54, 1, 1, {});
    NOTE("answer " << hex(r.apdu));
    EXPECT(r.answered, "no response");
    EXPECT(propCount(r) == 0, "a write without data was answered with " << propCount(r) << " element(s)");
}

// ---- 9.x properties ----------------------------------------------------------------------------------

HOST_TEST("HB-9.1", "A classic write to the read-only serial number is refused")
{
    Rig rig;
    auto serial = readSerial(rig.peer);
    auto r = propWrite(rig.peer, 0, 11, 1, 1, serial);
    NOTE("answer " << hex(r.apdu));
    EXPECT(r.answered && propCount(r) == 0, "write to read-only PID 11 answered with " << propCount(r) << " element(s)");
}

HOST_TEST("HB-9.2", "Index-0 reset of the read-only serial number is refused and changes nothing")
{
    Rig rig;
    auto serial = readSerial(rig.peer);
    auto r = propWrite(rig.peer, 0, 11, 1, 0, {0x00, 0x00});
    EXPECT(r.answered && propCount(r) == 0, "index-0 reset of PID 11 answered with " << propCount(r) << " element(s)");
    EXPECT(readSerial(rig.peer) == serial, "the serial number changed");
}

HOST_TEST("HB-9.2r", "Index-0 reset of the hardware type leaves a device that still saves and restores")
{
    std::vector<uint8_t> flash;
    std::vector<uint8_t> hw;
    {
        HostDevice dev(flash, kDevice);
        Peer peer(dev, kEts);
        peer.connect();
        auto before = propRead(peer, 0, 78, 1, 1);
        EXPECT(before.answered && propCount(before) == 1, "PID 78 not readable");
        hw = propData(before);
        auto r = propWrite(peer, 0, 78, 1, 0, {0x00, 0x00});
        NOTE("index-0 write answered " << propCount(r) << " element(s)");
        dev.bau().writeMemory(); // what the next ETS download or save timer does
    }
    HostDevice again(flash, 0x1199);
    Peer peer(again, kEts);
    peer.connect();
    auto after = propRead(peer, 0, 78, 1, 1);
    EXPECT(again.pa() == kDevice, "the configuration was discarded after the restart (address " << std::hex << again.pa() << ")");
    EXPECT(after.answered && propData(after) == hw, "hardware type after restart " << hex(propData(after)) << ", before " << hex(hw));
}

HOST_TEST("HB-9.3", "Index-0 reset of the device descriptor is refused; the descriptor service still answers")
{
    Rig rig;
    auto r = propWrite(rig.peer, 0, 83, 1, 0, {0x00, 0x00});
    EXPECT(r.answered && propCount(r) == 0, "index-0 reset of PID 83 answered with " << propCount(r) << " element(s)");
    auto d = rig.peer.request(mgmt::DeviceDescriptorRead, {}, mgmt::DeviceDescriptorResponse);
    EXPECT(d.answered && d.apdu.size() == 4 && d.apdu[2] == 0x07 && d.apdu[3] == 0xB0, "descriptor " << hex(d.apdu));
}

HOST_TEST("HB-9.11", "Index-0 write with a single data octet is refused")
{
    Rig rig;
    auto r = propWrite(rig.peer, 0, 14, 1, 0, {0x00});
    NOTE("answer " << hex(r.apdu));
    EXPECT(r.answered && propCount(r) == 0, "a one-octet index-0 write answered with " << propCount(r) << " element(s)");
    auto v = propRead(rig.peer, 0, 14, 1, 1);
    EXPECT(v.answered && propCount(v) == 1, "PID 14 lost its element: " << hex(v.apdu));
}

HOST_TEST("HB-9.15", "PID_PROG_MODE keeps only bit 0 and reads back what programming mode is")
{
    Rig rig;
    propWrite(rig.peer, 0, 54, 1, 1, {0x03});
    auto v = propRead(rig.peer, 0, 54, 1, 1);
    NOTE("read back " << hex(propData(v)) << ", progMode()=" << rig.dev.bau().deviceObject().progMode());
    EXPECT(propData(v) == std::vector<uint8_t>({0x01}), "PID 54 reads " << hex(propData(v)) << " after writing 03h");
    EXPECT(rig.dev.bau().deviceObject().progMode(), "the device is not in programming mode although PID 54 says so");
    propWrite(rig.peer, 0, 54, 1, 1, {0x00});
}

HOST_TEST("HB-9.6", "A load event written to element index 0 is refused and not executed")
{
    Rig rig;
    auto r = propWrite(rig.peer, 1, 5, 1, 0, {0x01, 0x00}); // start loading, at index 0
    EXPECT(r.answered && propCount(r) == 0, "index-0 load event answered with " << propCount(r) << " element(s)");
    auto s = propRead(rig.peer, 1, 5, 1, 1);
    EXPECT(propData(s) == std::vector<uint8_t>({0x00}), "load state is " << hex(propData(s)) << " - the event was executed");
}

HOST_TEST("HB-9.4", "PID_MCB_TABLE at index 0 reports its element count")
{
    Rig rig;
    auto r = propRead(rig.peer, 1, 27, 1, 0);
    NOTE("answer " << hex(r.apdu));
    EXPECT(r.answered && propCount(r) == 1 && propData(r).size() == 2, "index-0 read of PID 27: " << hex(r.apdu));
}

// ---- 10.x load state machine (address table, object index 1) -----------------------------------------

HOST_TEST("HB-10.0", "Control: start, allocate, complete loads the table")
{
    Rig rig;
    EXPECT(propData(loadEvent(rig.peer, 1, {0x01})) == std::vector<uint8_t>({0x02}), "start loading did not reach Loading");
    EXPECT(propData(loadEvent(rig.peer, 1, allocControl(16))) == std::vector<uint8_t>({0x02}), "allocation left Loading");
    EXPECT(propData(loadEvent(rig.peer, 1, {0x02})) == std::vector<uint8_t>({0x01}), "load completed did not reach Loaded");
    auto ref = propRead(rig.peer, 1, 7, 1, 1);
    EXPECT(propData(ref).size() == 4 && propData(ref) != std::vector<uint8_t>({0, 0, 0, 0}), "PID_TABLE_REFERENCE " << hex(propData(ref)));
}

HOST_TEST("HB-10.2", "An undefined load event is ignored, not turned into Error")
{
    Rig rig;
    auto r = loadEvent(rig.peer, 1, {0x05});
    EXPECT(propData(r) == std::vector<uint8_t>({0x00}), "state after event 05h: " << hex(propData(r)));
}

HOST_TEST("HB-10.3", "Load completed without an allocation does not report Loaded")
{
    Rig rig;
    loadEvent(rig.peer, 1, {0x01});
    auto r = loadEvent(rig.peer, 1, {0x02});
    auto err = propRead(rig.peer, 1, 28, 1, 1);
    NOTE("state " << hex(propData(r)) << ", error code " << hex(propData(err)));
    EXPECT(propData(r) != std::vector<uint8_t>({0x01}), "the table reports Loaded with no data");
}

HOST_TEST("HB-10.4", "An allocation of 64 KiB or more ends in Error")
{
    Rig rig;
    loadEvent(rig.peer, 1, {0x01});
    auto r = loadEvent(rig.peer, 1, allocControl(0x10000));
    EXPECT(propData(r) == std::vector<uint8_t>({0x03}), "state after a 64 KiB allocation: " << hex(propData(r)));
}

HOST_TEST("HB-10.6", "Leaving Error clears PID_ERROR_CODE")
{
    Rig rig;
    loadEvent(rig.peer, 1, {0x01});
    loadEvent(rig.peer, 1, allocControl(0x10000));
    auto e1 = propRead(rig.peer, 1, 28, 1, 1);
    EXPECT(propData(e1) != std::vector<uint8_t>({0x00}), "no error code in Error: " << hex(propData(e1)));
    auto u = loadEvent(rig.peer, 1, {0x04});
    auto e2 = propRead(rig.peer, 1, 28, 1, 1);
    EXPECT(propData(u) == std::vector<uint8_t>({0x00}), "unload did not reach Unloaded: " << hex(propData(u)));
    EXPECT(propData(e2) == std::vector<uint8_t>({0x00}), "error code still " << hex(propData(e2)) << " after leaving Error");
}

HOST_TEST("HB-10.8", "PID_TABLE_REFERENCE is 0 while the table holds no data")
{
    Rig rig;
    auto r0 = propRead(rig.peer, 1, 7, 1, 1);
    loadEvent(rig.peer, 1, {0x01});
    auto r1 = propRead(rig.peer, 1, 7, 1, 1);
    NOTE("unloaded " << hex(propData(r0)) << ", loading " << hex(propData(r1)));
    EXPECT(propData(r0) == std::vector<uint8_t>({0, 0, 0, 0}), "unloaded: " << hex(propData(r0)));
    EXPECT(propData(r1) == std::vector<uint8_t>({0, 0, 0, 0}), "loading without data: " << hex(propData(r1)));
}

HOST_TEST("HB-10.11", "An allocation larger than the free NVM ends in Error with E_MAX_TABLE_LENGTH_EXEEDED")
{
    Rig rig;
    loadEvent(rig.peer, 1, {0x01});
    auto r = loadEvent(rig.peer, 1, allocControl(0x8000)); // the whole NVM: the metadata already occupies part of it
    auto err = propRead(rig.peer, 1, 28, 1, 1);
    NOTE("state " << hex(propData(r)) << ", error code " << hex(propData(err)));
    EXPECT(propData(r) == std::vector<uint8_t>({0x03}), "state " << hex(propData(r)));
    EXPECT(propData(err) == std::vector<uint8_t>({13}), "error code " << hex(propData(err)));
}

HOST_TEST("HB-10.14", "A load event at element index 0 on PID 5 is refused")
{
    Rig rig;
    auto r = propWrite(rig.peer, 1, 5, 1, 0, {0x04, 0x00});
    EXPECT(r.answered && propCount(r) == 0, "answered with " << propCount(r) << " element(s)");
}

HOST_TEST("HB-8.1d", "A memory read right after a write returns the written octets, not the old flash content")
{
    // Hardware 5.0.7 (2026-09-19): A_MemoryExtended_Write 11 22 33 44 at 7FF0h answered Success, the read right
    // after it returned FF FF FF FF - the write sat in the flash driver's sector buffer.
    Rig rig;
    auto w = rig.peer.request(MemExtWrite, {4, 0x00, 0x7F, 0xF0, 0x11, 0x22, 0x33, 0x44}, MemExtWriteResponse);
    EXPECT(w.answered && w.apdu.size() >= 3 && w.apdu[2] == 0x00, "write answer " << hex(w.apdu));
    auto r = rig.peer.request(MemExtRead, {4, 0x00, 0x7F, 0xF0}, MemExtReadResponse);
    NOTE("read back " << hex(r.apdu));
    EXPECT(r.answered && r.apdu.size() == 10, "read answer " << hex(r.apdu));
    EXPECT(std::vector<uint8_t>(r.apdu.begin() + 6, r.apdu.end()) == std::vector<uint8_t>({0x11, 0x22, 0x33, 0x44}), "read returned " << hex(r.apdu));
}

HOST_TEST("HB-8.3b", "A master reset leaves its response under the old address, and a basic restart meanwhile still applies it")
{
    Rig rig;
    auto r = masterReset(rig.peer, 0x03, 0x00); // ResetIA
    EXPECT(r.answered && r.apdu.size() >= 3 && r.apdu[2] == 0x00, "no A_Restart_Response for ResetIA: " << hex(r.apdu));
    EXPECT(r.telegram.src == kDevice, "the response left with source " << std::hex << r.telegram.src);
    rig.peer.sendTpdu({0x03, 0x80}); // A_Restart basic, connectionless, inside the reset delay
    rig.dev.run(3000);
    NOTE("reboots " << rig.dev.reboots() << ", address after the restart " << std::hex << rig.dev.pa());
    EXPECT(rig.dev.reboots() >= 1, "no restart");
    EXPECT(rig.dev.pa() == 0xFFFF, "the confirmed ResetIA was lost: address " << std::hex << rig.dev.pa());
}

HOST_TEST("HB-7.2", "A held-back answer keeps its place instead of being pushed out by a later one")
{
    std::vector<uint8_t> flash;
    HostDevice dev(flash, 0x110A);
    Peer p(dev, 0x1101);
    p.connect();

    // Three requests without acknowledging a single answer. The first answer goes out and waits for its
    // T_ACK, so the second has to be held back - and the third arrives while that one place is taken.
    // 03_03_04 A11 p.20 says to keep the order, so the SECOND request's answer is the one that may still
    // come, never the third's.
    // 1: A_DeviceDescriptor_Read, 2: A_PropertyValue_Read (a different answer), 3: DeviceDescriptor again.
    p.sendTpdu({0x43, 0x00});                                     // seq 0, descriptor
    dev.run(60);
    p.sendTpdu({0x47, 0xD5, 0x00, 0x0B, 0x10, 0x01});             // seq 1, property value read
    dev.run(60);
    p.sendTpdu({0x4B, 0x00});                                     // seq 2, descriptor again
    dev.run(60);

    const size_t mark = dev.sentCount();
    for (uint8_t seq = 0; seq < 4; seq++)
    {
        p.sendTpdu({(uint8_t)(0xC2 | (seq << 2))}); // T_ACK for the device's numbered answers
        dev.run(400);
    }
    dev.run(1500);

    int descriptors = 0, properties = 0;
    for (auto& t : dev.sent(mark))
    {
        if (t.group || t.tpdu.size() < 2 || (t.tpdu[0] & 0xC0) != 0x40) continue;
        const uint16_t apci = (uint16_t)(((t.tpdu[0] & 0x03) << 8) | t.tpdu[1]);
        if ((apci & 0x3C0) == 0x340) descriptors++;
        if ((apci & 0x3C0) == 0x3C0) properties++;
    }

    NOTE("after the peer went quiet: " << descriptors << " descriptor answer(s), " << properties
         << " property answer(s)");
    EXPECT(properties >= 1, "the answer that was held back first never came - a later request pushed it out");
}


HOST_TEST("HL-2.2b", "Broadcast telegrams whose transport control field is not T_Data_Broadcast change nothing")
{
    // 08_03_04 2.2 b) p.9, precondition programming mode: A_IndividualAddress_Write with TPCI 40h, 80h, 10h
    // (telegrams 3, 6, 10) must not change the address, A_IndividualAddress_Read with C1h (9) must not be
    // answered, and the same read with 00h (7, 8) is. 03_03_04 Figure 3 p.6: only 000000b is T_Data_Broadcast.
    // A fresh device per write, so one write that is taken cannot hide the next; all are judged together.
    std::string taken;
    for (const auto& bad : std::vector<std::vector<uint8_t>>{{0x40, 0xC0, 0x12, 0x34}, {0x80, 0xC0, 0x12, 0x34}, {0x10, 0xC0, 0x12, 0x34}})
    {
        Rig one;
        propWrite(one.peer, 0, 54, 1, 1, {0x01});
        EXPECT(one.dev.bau().deviceObject().progMode(), "the device is not in programming mode");
        one.peer.sendTpdu(bad, true, 0x0000);
        one.dev.run(300);
        const uint16_t ia = one.dev.bau().deviceObject().individualAddress();
        NOTE(hex(bad) << " -> individual address 0x" << std::hex << ia << std::dec);
        if (ia != kDevice)
            taken += hex(bad) + " ";
    }
    EXPECT(taken.empty(), "the device took " << taken << "and changed its individual address");

    Rig rig;
    propWrite(rig.peer, 0, 54, 1, 1, {0x01});
    EXPECT(rig.dev.bau().deviceObject().progMode(), "the device is not in programming mode");
    size_t mark = rig.dev.sentCount();
    rig.peer.sendTpdu({0x01, 0x00}, true, 0x0000); // (7) the same read with the defined control field
    rig.dev.run(500);
    bool control = false;
    for (auto& t : rig.dev.sent(mark))
        if (t.group && t.dst == 0 && t.tpdu.size() >= 2 && t.tpdu[1] == 0x40)
            control = true;
    EXPECT(control, "control: the device in programming mode did not answer A_IndividualAddress_Read (7, 8)");
    mark = rig.dev.sentCount();
    rig.peer.sendTpdu({0xC1, 0x00}, true, 0x0000); // (9) undefined control field
    rig.dev.run(500);
    for (auto& t : rig.dev.sent(mark))
        EXPECT(!(t.group && t.dst == 0), "the device answered A_IndividualAddress_Read with TPCI C1h: " << hex(t.tpdu));
    EXPECT(rig.dev.garbled() == 0, rig.dev.garbled() << " frame(s) on the bus did not decode");
    propWrite(rig.peer, 0, 54, 1, 1, {0x00});
}

HOST_TEST("HL-sb", "A system broadcast whose transport control field is undefined is not answered")
{
    // On TP a system broadcast is a broadcast carrying a system-broadcast APCI; 03_03_04 Figure 3 p.6 gives it no
    // TPCI of its own, so only 000000b is valid. Stimulus: A_SystemNetworkParameter_Read for the serial number by
    // programming mode (object 0, PID 11, operand 01h), answered with the defined control field and not with C1h.
    // The answer comes after a random wait of up to 1 s (03_05_02 2.20.1.4 p.39), so each window is 1100 ms.
    Rig rig;
    propWrite(rig.peer, 0, 54, 1, 1, {0x01});
    EXPECT(rig.dev.bau().deviceObject().progMode(), "the device is not in programming mode");
    auto answered = [&](const std::vector<uint8_t>& tpdu) {
        const size_t mark = rig.dev.sentCount();
        rig.peer.sendTpdu(tpdu, true, 0x0000);
        rig.dev.run(1100);
        for (auto& t : rig.dev.sent(mark))
            if (t.group && t.dst == 0 && t.tpdu.size() >= 2 && (t.tpdu[0] & 0x03) == 0x01 && t.tpdu[1] == 0xC9)
                return true;
        return false;
    };
    EXPECT(answered({0x01, 0xC8, 0x00, 0x00, 0x00, 0xB0, 0x01}), "control: A_SystemNetworkParameter_Read with TPCI 00h was not answered");
    EXPECT(!answered({0xC1, 0xC8, 0x00, 0x00, 0x00, 0xB0, 0x01}), "A_SystemNetworkParameter_Read with TPCI octet C1h was answered");
    EXPECT(answered({0x01, 0xC8, 0x00, 0x00, 0x00, 0xB0, 0x01}), "control after the negative: A_SystemNetworkParameter_Read with TPCI 00h was not answered");
    EXPECT(rig.dev.garbled() == 0, rig.dev.garbled() << " frame(s) on the bus did not decode");
    propWrite(rig.peer, 0, 54, 1, 1, {0x00});
}

HOST_TEST("HL-lg0", "A broadcast without an APCI octet is ignored without reading past the frame")
{
    // Length 0: the frame carries the transport control field only. Deciding whether it is a system broadcast
    // must not read an APCI that is not there; AddressSanitizer reports the read if it happens. In programming
    // mode, so the A_IndividualAddress_Read afterwards proves the device still serves broadcasts.
    Rig rig;
    propWrite(rig.peer, 0, 54, 1, 1, {0x01});
    EXPECT(rig.dev.bau().deviceObject().progMode(), "the device is not in programming mode");
    size_t mark = rig.dev.sentCount();
    rig.peer.sendTpdu({0x00}, true, 0x0000);
    rig.dev.run(300);
    for (auto& t : rig.dev.sent(mark))
        EXPECT(!(t.group && t.dst == 0), "the device answered a broadcast without an APCI octet: " << hex(t.tpdu));
    mark = rig.dev.sentCount();
    rig.peer.sendTpdu({0x01, 0x00}, true, 0x0000);
    rig.dev.run(500);
    bool alive = false;
    for (auto& t : rig.dev.sent(mark))
        if (t.group && t.dst == 0 && t.tpdu.size() >= 2 && (t.tpdu[0] & 0x03) == 0x01 && (t.tpdu[1] & 0xC0) == 0x40)
            alive = true;
    EXPECT(alive, "control after the frame: A_IndividualAddress_Read in programming mode was not answered");
    EXPECT(rig.dev.garbled() == 0, rig.dev.garbled() << " frame(s) on the bus did not decode");
    propWrite(rig.peer, 0, 54, 1, 1, {0x00});
}

HOST_TEST("HL-ind", "An individual telegram whose transport control field is undefined is not answered")
{
    // 03_03_04 Figure 3 p.6, individual address: 000000b is T_Data_Individual, 01ssss T_Data_Connected; an
    // unnumbered data PDU with bit 4 set (octet 13h) is undefined. Control: the same A_DeviceDescriptor_Read with 00h.
    std::vector<uint8_t> flash;
    HostDevice dev(flash, kDevice);
    Peer peer(dev, kEts);
    auto answered = [&](const std::vector<uint8_t>& tpdu) {
        const size_t mark = dev.sentCount();
        peer.sendTpdu(tpdu);
        dev.run(500);
        for (auto& t : dev.sent(mark))
            if (!t.group && t.dst == kEts && t.tpdu.size() >= 2 && (t.tpdu[0] & 0x03) == 0x03 && (t.tpdu[1] & 0xC0) == 0x40)
                return true;
        return false;
    };
    EXPECT(answered({0x03, 0x00}), "control: A_DeviceDescriptor_Read with TPCI 00h was not answered");
    EXPECT(!answered({0x13, 0x00}), "A_DeviceDescriptor_Read with TPCI octet 13h was answered");
    EXPECT(answered({0x03, 0x00}), "control after the negative: A_DeviceDescriptor_Read with TPCI 00h was not answered");
    EXPECT(dev.garbled() == 0, dev.garbled() << " frame(s) on the bus did not decode");
}
