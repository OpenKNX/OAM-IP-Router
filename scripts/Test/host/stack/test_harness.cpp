/**
 * @brief Cases that prove the harness itself before any finding is judged with it.
 */
#include "host_device.h"
#include "knx/bau07B0.h"
#include "host_test.h"

HOST_TEST("HS-0.1", "Device boots against the chip emulator: reset, configure, address")
{
    std::vector<uint8_t> flash;
    HostDevice dev(flash, 0x110A);
    EXPECT(dev.chip().resets >= 1, "the driver never sent U_Reset.req");
    EXPECT(dev.chip().crcMode, "the driver never switched on the CRC trailer (U_Configure c=1)");
    EXPECT(dev.chip().ownAddress == 0x110A, "the chip was given address " << std::hex << dev.chip().ownAddress);
    EXPECT(dev.chip().unknown.empty(), "the driver sent bytes the emulator does not know: " << hex(dev.chip().unknown));
}

HOST_TEST("HS-0.2", "A_DeviceDescriptor_Read connectionless is answered with mask 07B0")
{
    std::vector<uint8_t> flash;
    HostDevice dev(flash, 0x110A);
    Peer peer(dev, 0x1101);
    auto r = peer.request(0x300, {}, 0x340);
    EXPECT(r.answered, "no A_DeviceDescriptor_Response; log: " << hostLog().substr(0, 200));
    EXPECT(r.apdu.size() == 4 && r.apdu[2] == 0x07 && r.apdu[3] == 0xB0, "response " << hex(r.apdu));
}

HOST_TEST("HS-0.3", "Connection-oriented read: T_ACK, numbered answer, our T_ACK accepted")
{
    std::vector<uint8_t> flash;
    HostDevice dev(flash, 0x110A);
    Peer peer(dev, 0x1101);
    peer.connect();
    auto r = peer.request(0x300, {}, 0x340);
    EXPECT(r.answered && r.acks == 1, "answered=" << r.answered << " acks=" << r.acks << " naks=" << r.naks);
    auto r2 = peer.request(0x300, {}, 0x340);
    EXPECT(r2.answered && r2.acks == 1 && !r2.disconnected, "second request: answered=" << r2.answered << " acks=" << r2.acks << " disc=" << r2.disconnected);
    EXPECT(r.seqErrors == 0 && r2.seqErrors == 0, "answers out of sequence: " << r.seqErrors << "/" << r2.seqErrors);
    EXPECT(dev.garbled() == 0, dev.garbled() << " frame(s) on the bus did not decode");
    peer.disconnect();
}

HOST_TEST("HS-0.4", "A restart from the persisted image keeps the individual address")
{
    std::vector<uint8_t> flash;
    {
        HostDevice dev(flash, 0x110A);
        dev.bau().writeMemory();
    }
    HostDevice again(flash, 0x1199);
    EXPECT(again.pa() == 0x110A, "restored address " << std::hex << again.pa());
}

HOST_TEST("HS-0.5", "A frame of more than 65 octets survives the offset protocol (A_MemoryExtended_Read of 100)")
{
    std::vector<uint8_t> flash;
    HostDevice dev(flash, 0x110A);
    Peer peer(dev, 0x1101);
    peer.connect();
    auto r = peer.request(0x1FD, {100, 0x00, 0x00, 0x00}, 0x1FE);
    NOTE("answer of " << r.apdu.size() << " octets, rc " << (r.apdu.size() > 2 ? (int)r.apdu[2] : -1));
    EXPECT(r.answered && r.apdu.size() == 106 && r.apdu[2] == 0x00, "long answer: answered=" << r.answered << " size=" << r.apdu.size());
    EXPECT(dev.garbled() == 0 && dev.chip().badChecksums == 0, "garbled=" << dev.garbled() << " badChecksums=" << dev.chip().badChecksums);
}

HOST_TEST("HS-0.6", "A restart is visible: the stack boots again and the transport connection is gone")
{
    std::vector<uint8_t> flash;
    HostDevice dev(flash, 0x110A);
    Peer peer(dev, 0x1101);
    peer.connect();
    auto r = peer.request(0x381, {0x01, 0x00}, 0x3A1); // confirmed restart; whether it is answered is HB-8.3
    NOTE("answer " << hex(r.apdu));
    dev.run(6000);
    EXPECT(dev.reboots() == 1, "reboots=" << dev.reboots());
    auto after = peer.request(0x300, {}, 0x340);
    NOTE("after the restart: acks=" << after.acks << " answered=" << after.answered << " disconnected=" << after.disconnected);
    EXPECT(after.acks == 0 && !after.answered, "the old connection still answers after a restart");
}

HOST_TEST("HS-0.7", "A telegram to an absent device is repeated three times and confirmed negatively")
{
    std::vector<uint8_t> flash;
    HostDevice dev(flash, 0x110A);
    Peer peer(dev, 0x1101);
    dev.chip().present.erase(0x1101); // the peer stops acknowledging
    const size_t mark = dev.sentCount();
    peer.request(0x300, {}, 0x340, 500);
    dev.run(500);
    auto s = dev.sent(mark);
    int copies = 0;
    for (auto& t : s)
        if (t.dst == 0x1101 && t.tpdu.size() >= 2 && t.tpdu[1] == 0x40)
            copies++;
    NOTE(copies << " copies of the answer on the bus");
    EXPECT(copies == 4, "expected the answer and three repetitions, got " << copies);
}
