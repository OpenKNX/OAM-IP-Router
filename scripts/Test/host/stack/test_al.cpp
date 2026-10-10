/**
 * @brief Application layer builders, judged on the octets the device puts on the bus.
 */
#include "host_device.h"
#include "host_test.h"
#include "knx/bau07B0.h"

HOST_TEST("HA-6.9a", "A_IndividualAddress_SerialNumber_Response carries serial, domain address and 2 reserved octets")
{
    // 03_03_07 Figure 13 p.22 and the expected frame in 08_03_07 2.17.3 p.71: TPCI/APCI, APCI, serial (6),
    // domain address (2), reserved (2) = 12 TPDU octets.
    std::vector<uint8_t> flash;
    HostDevice dev(flash, 0x110A);
    Peer peer(dev, 0x1101);
    auto p = peer.request(0x3D5, {0x00, 0x0B, 0x10, 0x01}, 0x3D6); // A_PropertyValue_Read obj 0 PID 11 n=1 start=1
    EXPECT(p.answered && p.apdu.size() == 12, "serial number read failed: " << hex(p.apdu));
    std::vector<uint8_t> serial(p.apdu.begin() + 6, p.apdu.end());

    const size_t mark = dev.sentCount();
    std::vector<uint8_t> req = {0x03, 0xDC};
    req.insert(req.end(), serial.begin(), serial.end());
    peer.sendTpdu(req, true, 0x0000); // broadcast
    dev.run(500);
    bool found = false;
    for (auto& t : dev.sent(mark))
    {
        if (t.tpdu.size() >= 2 && t.tpdu[0] == 0x03 && t.tpdu[1] == 0xDD)
        {
            found = true;
            NOTE("response " << hex(t.tpdu));
            EXPECT(t.group && t.dst == 0, "response not broadcast: dst=" << std::hex << t.dst);
            EXPECT(t.tpdu.size() == 12, "response TPDU has " << t.tpdu.size() << " octets: " << hex(t.tpdu));
            EXPECT(std::vector<uint8_t>(t.tpdu.begin() + 2, t.tpdu.begin() + 8) == serial, "echoed serial differs: " << hex(t.tpdu));
        }
    }
    EXPECT(found, "no A_IndividualAddress_SerialNumber_Response on the bus");
}
