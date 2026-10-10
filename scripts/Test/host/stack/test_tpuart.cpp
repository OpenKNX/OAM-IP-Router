/**
 * @brief TP-UART data link cases: what the driver tells the chip and what it does with received frames.
 */
#include "host_device.h"
#include "host_test.h"
#include "host_env.h"
#include "knx/bau07B0.h"

namespace
{
/** @brief Connectionless A_DeviceDescriptor_Read from 1.1.1 with a chosen control field. */
std::vector<uint8_t> descriptorRead(uint16_t dst, uint8_t ctrl)
{
    Telegram t;
    t.ctrl = ctrl;
    t.src = 0x1101;
    t.dst = dst;
    t.tpdu = {0x03, 0x00};
    return encodeFrame(t);
}

int descriptorAnswers(HostDevice& dev, size_t from)
{
    int n = 0;
    for (auto& t : dev.sent(from))
        if (t.dst == 0x1101 && t.tpdu.size() >= 2 && (t.tpdu[0] & 0x03) == 0x03 && t.tpdu[1] == 0x40 && (t.ctrl & 0x20))
            n++; // first transmissions only; the chip's own repetitions carry the repeat flag cleared
    return n;
}
} // namespace

HOST_TEST("HT-1.14", "An individual address in areas 8-15 is handed to the chip for auto-acknowledge")
{
    std::vector<uint8_t> flash;
    HostDevice dev(flash, 0x9007); // 9.0.7: the high bit of the address is set
    NOTE("chip address " << std::hex << dev.chip().ownAddress);
    EXPECT(dev.chip().ownAddress == 0x9007, "U_SetAddress not sent for 9.0.7 (chip has " << std::hex << dev.chip().ownAddress << ")");
}

HOST_TEST("HT-2.15c", "Our own repetitions are recognised as repetitions, not carried up as foreign telegrams")
{
    // HT-2.15 asserts the symptom - the device must not report its own address as duplicated. This one
    // asserts the mechanism underneath: the repetitions have to REACH the filter and be counted there.
    // While our own transmissions were kept out of it, the filter had no original to match, so nothing was
    // counted and every repetition travelled on as a received frame.
    std::vector<uint8_t> flash;
    HostDevice dev(flash, 0x110A);
    auto& stats = dev.bau().getDataLinkLayer()->getTPUart().getStatistics();
    const unsigned int before = stats.getRxRepetitions();

    // 1.1.1 is not on the line, so nothing acknowledges our answer and the chip repeats it.
    const size_t mark = dev.sentCount();
    dev.chip().inject(descriptorRead(0x110A, 0xBC));
    dev.run(3000);

    int transmissions = 0;
    for (auto& t : dev.sent(mark))
        if (t.dst == 0x1101)
            transmissions++;
    const unsigned int filtered = stats.getRxRepetitions() - before;
    NOTE("own transmissions on the line: " << transmissions << ", counted as repetitions: " << filtered);
    EXPECT(transmissions > 1, "the chip did not repeat the unacknowledged answer, so nothing was under test");
    // EVERY repetition has to be recognised, not merely some of them. Without the original in the filter
    // the first repetition is what creates the entry, so only the ones after it match and the count comes
    // out one short - which is exactly how this case tells the two states apart.
    EXPECT(filtered == (unsigned int)(transmissions - 1),
           "expected " << (transmissions - 1) << " recognised repetitions, counted " << filtered
                       << " - the original was not in the filter, so the first repetition passed as a new telegram");
    // One request, one answer. A repetition carried up would have been answered again.
    EXPECT(descriptorAnswers(dev, mark) == 1, "the device answered more than once for a single request");
}

HOST_TEST("HT-1.14b", "The acknowledge leaves before the check octet is known and is the same for a faulty frame")
{
    std::vector<uint8_t> flash;
    HostDevice dev(flash, 0x110A);

    // A broadcast is decided by the host alone: the chip auto-acknowledges only the one individual address
    // it was handed with U_SetAddress.req (NCN5130-D p.36), so this is the class the register row is about.
    Telegram t;
    t.src = 0x1101;
    t.dst = 0x0000;
    t.group = true;
    t.tpdu = {0x01, 0x00}; // A_IndividualAddress_Read
    const std::vector<uint8_t> good = encodeFrame(t);
    std::vector<uint8_t> bad = good;
    bad.back() ^= 0xFF; // the check octet no longer covers the frame (03_02_02 2.2.4.6 p.27)

    // Nine octets at 1350 us: the sixth is through at 8.1 ms, the check octet arrives only at 12.2 ms.
    dev.chip().ackRequests.clear();
    dev.chip().inject(bad);
    dev.run(9);
    const size_t early = dev.chip().ackRequests.size();
    const uint8_t value = early ? dev.chip().ackRequests.front() : 0;
    dev.run(20);
    const size_t afterFrame = dev.chip().ackRequests.size();
    NOTE("after six octets: " << early << " acknowledge(s), first 0x" << std::hex << (unsigned)value
                              << std::dec << "; after the whole faulty frame: " << afterFrame);
    EXPECT(early == 1, "no acknowledge was written before the check octet arrived, so nothing was measured");
    EXPECT(value == 0x11, "the acknowledge was not a plain addressed ACK (U_Ack.req 10h | addressed)");
    EXPECT(afterFrame == early, "the driver wrote a further acknowledge once the check octet was in");

    // Control: the same telegram with a correct check octet is acknowledged identically, so the decision
    // does not depend on the check octet at all.
    dev.chip().ackRequests.clear();
    dev.chip().inject(good);
    dev.run(30);
    NOTE("correct frame: " << dev.chip().ackRequests.size() << " acknowledge(s), first 0x" << std::hex
                           << (unsigned)(dev.chip().ackRequests.empty() ? 0 : dev.chip().ackRequests.front()));
    EXPECT(dev.chip().ackRequests.size() == 1 && dev.chip().ackRequests.front() == value,
           "the correct frame was acknowledged differently than the faulty one");
}

HOST_TEST("HT-1.6", "A repetition long after its original is a new telegram, not a duplicate")
{
    std::vector<uint8_t> flash;
    HostDevice dev(flash, 0x110A);
    dev.chip().present.insert(0x1101);
    size_t mark = dev.sentCount();
    dev.chip().inject(descriptorRead(0x110A, 0xBC));
    dev.run(300);
    const int first = descriptorAnswers(dev, mark);
    dev.run(3500); // longer than the filter may remember a telegram
    mark = dev.sentCount();
    dev.chip().inject(descriptorRead(0x110A, 0x9C)); // same telegram, repeat flag cleared
    dev.run(300);
    const int late = descriptorAnswers(dev, mark);
    NOTE("answers: original " << first << ", repetition after 3.5 s " << late);
    EXPECT(first == 1, "the original was not answered");
    EXPECT(late == 1, "a repetition 3.5 s later was dropped as a duplicate of a telegram long gone");
}

HOST_TEST("HT-1.6c", "Control: a repetition right after its original is dropped")
{
    std::vector<uint8_t> flash;
    HostDevice dev(flash, 0x110A);
    dev.chip().present.insert(0x1101);
    size_t mark = dev.sentCount();
    dev.chip().inject(descriptorRead(0x110A, 0xBC));
    dev.run(300);
    dev.chip().inject(descriptorRead(0x110A, 0x9C));
    dev.run(300);
    const int n = descriptorAnswers(dev, mark);
    NOTE("answers " << n);
    EXPECT(n == 1, "a repetition 300 ms after the original was answered again (" << n << " answers)");
}

HOST_TEST("HT-2.15", "A repetition of our own answer is not taken for a foreign frame with our address")
{
    std::vector<uint8_t> flash;
    HostDevice dev(flash, 0x110A);

    // 1.1.1 is deliberately NOT present on the line: nothing acknowledges the answer, so the chip
    // repeats it and the repetitions come back on our own receiver.
    const size_t mark = dev.sentCount();
    dev.chip().inject(descriptorRead(0x110A, 0xBC));
    dev.run(3000);

    int transmissions = 0;
    for (auto& t : dev.sent(mark))
        if (t.dst == 0x1101)
            transmissions++;
    NOTE("own transmissions on the line: " << transmissions);
    EXPECT(transmissions > 1, "the chip did not repeat the unacknowledged answer, so nothing was under test");

    // 03_05_01 PID_DEVICE_CONTROL bit 1 means another device on the line uses our individual address.
    // Our own repetition is not another device, and the bit is never cleared again once it is set.
    InterfaceObject* devObj = dev.object(0);
    EXPECT(devObj != nullptr, "no device object");
    uint8_t control = 0;
    devObj->property(PID_DEVICE_CONTROL)->read(control);
    EXPECT((control & 0x02) == 0, "the device reported its own individual address as duplicated after repeating its own answer");
}

HOST_TEST("HT-1.21", "A telegram survives a host blockage while its octets wait in the interface")
{
    std::vector<uint8_t> flash;
    HostDevice dev(flash, 0x110A);
    dev.chip().present.insert(0x1101);
    const size_t mark = dev.sentCount();

    // The receiver measures the gap between two READS. A 4 KB flash erase runs with interrupts off, so
    // nothing is read for tens of milliseconds while the octets pile up in the interface - nothing is
    // lost on the wire. Taking that for a quiet bus swept a complete telegram and latched _invalid.
    dev.chip().inject(descriptorRead(0x110A, 0xBC));
    dev.run(3);           // the first octets are read
    hostAdvanceUs(26000); // host blocked: the rest arrives, nobody reads
    dev.run(300);

    const int n = descriptorAnswers(dev, mark);
    NOTE("answers " << n);
    EXPECT(n == 1, "the telegram was discarded after a host blockage although every octet had arrived");
}

HOST_TEST("HT-1.22", "A two-octet chip indication survives a pause between its octets")
{
    std::vector<uint8_t> flash;
    HostDevice dev(flash, 0x110A);
    dev.run(50); // let the startup exchange drain before the counter is read

    auto discarded = [&dev] {
        return dev.bau().getDataLinkLayer()->getTPUart().getStatistics().getRxDiscardedBytes();
    };
    const unsigned before = discarded();

    // U_SYSTEM_STAT_IND (0x4B) asks the parser for its data octet. On hardware that octet followed 29 ms
    // later, far past the intra-frame timeout and with the interface empty - so the gap is real, the
    // marker is set, and sweeping it tore the chip's own status answer apart.
    dev.chip().emitRaw({0x4B}, 100);
    dev.run(2);
    hostAdvanceUs(29000);
    dev.chip().emitRaw({0xFB}, 100);
    dev.run(50);

    NOTE("discarded " << (discarded() - before));
    EXPECT(discarded() == before, "the chip indication was swept although both of its octets arrived");
}
