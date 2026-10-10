/**
 * @brief Unit-level cases on single stack classes, for findings with no symptom on the bus.
 */
#include <algorithm>
#include <cstring>
#include <new>

#include "host_device.h"
#include "host_test.h"
#include "knx/bau07B0.h"
#include "knx/cemi_frame.h"
#include "knx/data_property.h"
#include "knx/device_object.h"
#include "knx/dpt.h"
#include "knx/dptconvert.h"
#include "knx/knx_value.h"
#include "knx/memory.h"
#include "knx/data_link_layer.h"
#include "knx/network_layer_coupler.h"
#include "knx/router_object.h"
#include "knx/table_object.h"

HOST_TEST("HU-6.10", "printPDU ends at an octet count of 255")
{
    // cEMI: MC, AddIL=0, ctrl1, ctrl2, src, dst, length 255, then 256 TPDU octets; the buffer holds all of it,
    // so only the loop is under test.
    std::vector<uint8_t> cemi(300, 0);
    cemi[0] = 0x29;
    cemi[2] = 0xBC;
    cemi[8] = 255;
    CemiFrame frame(cemi.data(), (uint16_t)(9 + 1 + 255));
    frame.apdu().printPDU(); // an 8-bit counter wraps at 255 and never ends; the runner kills a hang
    NOTE("printed " << hostLog().size() << " characters");
}

HOST_TEST("HU-13.18", "Dpt() leaves no member uninitialised")
{
    alignas(Dpt) unsigned char storage[sizeof(Dpt)];
    memset(storage, 0xAA, sizeof(storage));
    Dpt* d = new (storage) Dpt();
    EXPECT(d->mainGroup == 0 && d->subGroup == 0 && d->index == 0,
           "main " << d->mainGroup << " sub " << d->subGroup << " index " << d->index);
    d->~Dpt();
}

HOST_TEST("HU-9.12", "Restoring a zero-element property leaves no zero-length block behind")
{
    DataProperty empty(PID_FRIENDLY_NAME, true, PDT_UNSIGNED_CHAR, 30, ReadLv3 | WriteLv3);
    std::vector<uint8_t> image(empty.saveSize() + 8, 0);
    empty.save(image.data());

    DataProperty restored(PID_FRIENDLY_NAME, true, PDT_UNSIGNED_CHAR, 30, ReadLv3 | WriteLv3);
    const uint8_t hello[] = {'a', 'b'};
    restored.write(1, 2, hello); // give it a block the restore has to replace
    restored.restore(image.data());
    uint8_t cnt[2] = {0xFF, 0xFF};
    restored.read(0, 1, cnt); // index 0 carries the element count
    NOTE("elements after restore: " << ((cnt[0] << 8) | cnt[1]));
    EXPECT(restored.data() == nullptr, "a zero-element record left a non-null block (callers read it as data)");
}

HOST_TEST("HU-9.21", "propertyData() of a PID the object does not carry is null, not a dereference")
{
    DeviceObject dev;
    EXPECT(dev.propertyData(PID_FRIENDLY_NAME) == nullptr, "propertyData returned non-null for an absent PID");
    EXPECT(dev.propertyData(PID_FRIENDLY_NAME, 1) == nullptr, "propertyData(index) returned non-null for an absent PID");
}

HOST_TEST("HU-11.1", "Freeing a, c then b merges them into one block that can be allocated again")
{
    std::vector<uint8_t> flash;
    HostDevice dev(flash, 0x110A);
    Memory& mem = dev.bau().memory();
    uint8_t* a = mem.allocMemory(64);
    uint8_t* b = mem.allocMemory(64);
    uint8_t* c = mem.allocMemory(64);
    uint8_t* d = mem.allocMemory(64); // keeps c from merging with the free tail
    EXPECT(a && b && c && d, "allocation failed");
    mem.freeMemory(a);
    mem.freeMemory(c);
    mem.freeMemory(b);
    uint8_t* abc = mem.allocMemory((size_t)(c - a) + 64);
    NOTE("a=" << (void*)a << " merged block=" << (void*)abc);
    EXPECT(abc == a, "the three freed neighbours did not merge into one block starting at a");
    mem.freeMemory(abc);
    mem.freeMemory(d);
}

namespace
{
/** @brief A table at a fixed NVM address, as the 091A application program (0100h) and filter table use. */
class StaticTable : public TableObject
{
  public:
    StaticTable(Memory& memory) : TableObject(memory, 0x4000, 0x100)
    {
        Property* properties[] = {new DataProperty(PID_OBJECT_TYPE, false, PDT_UNSIGNED_INT, 1, ReadLv3 | WriteLv0, (uint16_t)OT_APPLICATION_PROG)};
        TableObject::initializeProperties(sizeof(properties), properties);
    }
    bool hasData() { return data() != nullptr; }
    uint32_t size() { return tableSize(); }
};

/** @brief A table without a fixed address: ETS allocates its block, as for the address table. */
class DynTable : public TableObject
{
  public:
    DynTable(Memory& memory) : TableObject(memory)
    {
        Property* properties[] = {new DataProperty(PID_OBJECT_TYPE, false, PDT_UNSIGNED_INT, 1, ReadLv3 | WriteLv0, (uint16_t)OT_ADDR_TABLE)};
        TableObject::initializeProperties(sizeof(properties), properties);
    }
    bool hasData() { return data() != nullptr; }
    uint32_t size() { return tableSize(); }
};

/** @brief A static table placed so that its extent runs past the end of the NVM window. */
class OversizedStaticTable : public TableObject
{
  public:
    OversizedStaticTable(Memory& memory) : TableObject(memory, (uint32_t)memory.memorySize() - 0x10, 0x100)
    {
        Property* properties[] = {new DataProperty(PID_OBJECT_TYPE, false, PDT_UNSIGNED_INT, 1, ReadLv3 | WriteLv0, (uint16_t)OT_APPLICATION_PROG)};
        TableObject::initializeProperties(sizeof(properties), properties);
    }
    bool hasData() { return data() != nullptr; }
    uint32_t size() { return tableSize(); }
};

/** @brief PID_LOAD_STATE_CONTROL is ten octets on write (PDT_CONTROL). */
void loadControl(InterfaceObject& obj, const std::vector<uint8_t>& control)
{
    uint8_t ev[10] = {0};
    for (size_t i = 0; i < control.size() && i < sizeof(ev); i++)
        ev[i] = control[i];
    uint8_t count = 1;
    obj.writeProperty(PID_LOAD_STATE_CONTROL, 1, ev, count);
}

void loadEvent(InterfaceObject& obj, uint8_t event)
{
    uint8_t ev[10] = {event};
    uint8_t count = 1;
    obj.writeProperty(PID_LOAD_STATE_CONTROL, 1, ev, count);
}
} // namespace

HOST_TEST("HU-10.3s", "A static table loaded before its first save reaches Loaded with its block")
{
    // Fresh flash: nothing restored the table and no save placed it yet. ETS writes a static table with
    // LdCtrlWriteMem at its fixed address and sends no allocation (03_05_03 3.5.1.2 p.39-40).
    std::vector<uint8_t> flash;
    HostDevice dev(flash, 0x110A);
    StaticTable table(dev.bau().memory());
    loadEvent(table, 0x01);
    loadEvent(table, 0x02);
    NOTE("state " << (int)table.loadState() << ", block " << (table.hasData() ? "set" : "null"));
    EXPECT(table.loadState() == LS_LOADED, "state " << (int)table.loadState() << " after load completed");
    EXPECT(table.hasData(), "Loaded without its block");
}

HOST_TEST("HU-10.4u", "An unloaded table reports no extent, not the one of the block it lost")
{
    // LE_UNLOAD frees the block and leaves data() null, but the extent stayed behind. Anything that reads
    // the size without checking the pointer first - a save, a CRC over the segment - then works on a
    // length that describes memory this object no longer owns. A table at a FIXED address keeps both on
    // purpose (its block is not an allocation), so this has to be a table ETS allocates.
    std::vector<uint8_t> flash;
    HostDevice dev(flash, 0x110A);
    DynTable table(dev.bau().memory());
    loadControl(table, {0x01});                                           // LE_START_LOADING
    loadControl(table, {0x03, 0x0B, 0x00, 0x00, 0x00, 0x40, 0x01, 0x00}); // allocate 64 octets
    loadControl(table, {0x02});                                           // LE_LOAD_COMPLETED
    EXPECT(table.loadState() == LS_LOADED && table.hasData(), "the table was not loaded, so nothing is under test");
    NOTE("loaded: " << table.size() << " octets");

    loadControl(table, {0x04}); // LE_UNLOAD
    NOTE("after unload: state " << (int)table.loadState() << ", block " << (table.hasData() ? "set" : "null") << ", extent " << table.size());
    EXPECT(table.loadState() == LS_UNLOADED, "state " << (int)table.loadState() << " after unload");
    EXPECT(!table.hasData(), "the block survived the unload");
    EXPECT(table.size() == 0, "the unloaded table still reports " << table.size() << " octets");
}

HOST_TEST("HU-10.5s", "A static table that does not fit the NVM is refused instead of taken as a block")
{
    // Address and extent of a static table come from the product, not from flash, and were used unchecked.
    // A block reaching past the window ends in addNewUsedBlock() -> fatalError(), i.e. the device stops.
    std::vector<uint8_t> flash;
    HostDevice dev(flash, 0x110A);
    OversizedStaticTable table(dev.bau().memory());
    NOTE("NVM " << dev.bau().memory().memorySize() << " octets, table at the last 16 asking for 256");

    loadEvent(table, 0x01); // LE_START_LOADING
    loadEvent(table, 0x02); // LE_LOAD_COMPLETED
    NOTE("state " << (int)table.loadState() << ", block " << (table.hasData() ? "set" : "null") << ", extent " << table.size());
    EXPECT(!table.hasData(), "a table reaching past the end of the NVM was handed a block");
    EXPECT(table.loadState() == LS_ERROR, "state " << (int)table.loadState() << " - a table that cannot exist must end in Error");
}

// --- IP System Broadcast Routing Mode (PID_IP_SBC_CONTROL, 03_05_01 4.5.16.1) ---------------------
namespace
{
// A router object on its own: the property layer is what is under test here, not a coupler.
struct SbcFixture
{
    std::vector<uint8_t> flash;
    HostDevice dev;
    RouterObject obj;

    SbcFixture() : dev(flash, 0x110A), obj(dev.bau().memory())
    {
        obj.initialize1x(DptMedium::KNX_IP, 254);
    }

    Property* prop() { return obj.property(PID_IP_ENABLE_SBC); }
};
} // namespace

HOST_TEST("HU-9.20w", "The mode is taken from the ServiceInfo octet, and the write response carries no mode")
{
    SbcFixture f;
    Property* p = f.prop();
    EXPECT(p != nullptr, "PID_IP_ENABLE_SBC is missing on a KNX_IP router object");

    // 03_05_01 Figure 17: octet 10 reserved, octet 11 WriteServiceID, octet 12 ServiceInfo = the mode.
    uint8_t enable[3] = {0x00, 0x00, 0x01};
    uint8_t result[8] = {0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA};
    uint8_t resultLength = sizeof(result);
    p->command(enable, sizeof(enable), result, resultLength);

    EXPECT(f.obj.isIpSbcRoutingEnabled(), "a conformant enable did not switch the mode on");
    // NOTE 22: the response repeats the ServiceID and does not report the resulting mode.
    EXPECT(resultLength == 2 && result[0] == ReturnCodes::Success && result[1] == 0x00,
           "response " << (int)resultLength << " octets: " << (int)result[0] << " " << (int)result[1]);

    uint8_t disable[3] = {0x00, 0x00, 0x00};
    resultLength = sizeof(result);
    p->command(disable, sizeof(disable), result, resultLength);
    EXPECT(!f.obj.isIpSbcRoutingEnabled(), "the mode stayed on after a disable");
}

HOST_TEST("HU-9.20r", "The read response appends the mode as ServiceInfo")
{
    SbcFixture f;
    uint8_t enable[3] = {0x00, 0x00, 0x01};
    uint8_t result[8] = {0};
    uint8_t resultLength = sizeof(result);
    f.prop()->command(enable, sizeof(enable), result, resultLength);

    uint8_t read[2] = {0x00, 0x00};
    resultLength = sizeof(result);
    f.prop()->state(read, sizeof(read), result, resultLength);

    // Figure 19: Return Code, ReadServiceID, IP SBC Mode.
    EXPECT(resultLength == 3 && result[0] == ReturnCodes::Success && result[1] == 0x00 && result[2] == 0x01,
           "response " << (int)resultLength << " octets: " << (int)result[0] << " " << (int)result[1] << " " << (int)result[2]);
}

HOST_TEST("HU-9.20g", "A truncated command is refused instead of read past its end")
{
    SbcFixture f;
    uint8_t result[8] = {0};

    // Only the reserved octet: there is not even a ServiceID to echo.
    uint8_t justReserved[1] = {0x00};
    uint8_t resultLength = sizeof(result);
    f.prop()->command(justReserved, sizeof(justReserved), result, resultLength);
    EXPECT(resultLength == 2 && result[0] == ReturnCodes::DataVoid, "return code " << (int)result[0]);
    EXPECT(!f.obj.isIpSbcRoutingEnabled(), "a truncated command switched the mode on");

    // ServiceID present, ServiceInfo missing.
    uint8_t noInfo[2] = {0x00, 0x00};
    resultLength = sizeof(result);
    f.prop()->command(noInfo, sizeof(noInfo), result, resultLength);
    EXPECT(resultLength == 2 && result[0] == ReturnCodes::DataVoid && result[1] == 0x00,
           "return code " << (int)result[0] << " service id " << (int)result[1]);

    // An undefined ServiceID, and an unsupported ServiceInfo value.
    uint8_t badService[3] = {0x00, 0x07, 0x01};
    resultLength = sizeof(result);
    f.prop()->command(badService, sizeof(badService), result, resultLength);
    EXPECT(resultLength == 2 && result[0] == ReturnCodes::InvalidCommand && result[1] == 0x07,
           "return code " << (int)result[0] << " service id " << (int)result[1]);

    uint8_t badValue[3] = {0x00, 0x00, 0x02};
    resultLength = sizeof(result);
    f.prop()->command(badValue, sizeof(badValue), result, resultLength);
    EXPECT(resultLength == 2 && result[0] == ReturnCodes::DataVoid, "return code " << (int)result[0]);
    EXPECT(!f.obj.isIpSbcRoutingEnabled(), "an unsupported ServiceInfo value switched the mode on");
}

HOST_TEST("HU-9.20t", "The mode falls back after 20 s and another command prolongs it")
{
    SbcFixture f;
    uint8_t enable[3] = {0x00, 0x00, 0x01};
    uint8_t result[8] = {0};
    uint8_t resultLength = sizeof(result);

    f.prop()->command(enable, sizeof(enable), result, resultLength);
    hostAdvanceUs(19000ull * 1000ull);
    EXPECT(f.obj.isIpSbcRoutingEnabled(), "the mode expired before its 20 s were up");

    // Enabling again while it is still on restarts the interval (08_TSSK 80111).
    resultLength = sizeof(result);
    f.prop()->command(enable, sizeof(enable), result, resultLength);
    hostAdvanceUs(19000ull * 1000ull);
    EXPECT(f.obj.isIpSbcRoutingEnabled(), "the second command did not prolong the mode");

    hostAdvanceUs(2000ull * 1000ull);
    EXPECT(!f.obj.isIpSbcRoutingEnabled(), "the mode did not fall back to disabled");
}

namespace
{
/** @brief A router object whose table block and size can be read, so a case can see what it allocated. */
struct TestRouter : RouterObject
{
    TestRouter(Memory& memory) : RouterObject(memory) {}
    bool hasData() { return data() != nullptr; }
    uint32_t size() { return tableSize(); }
};

} // namespace

HOST_TEST("HU-9.5", "propertyData() of a property that keeps no data block is null, not the block it never had")
{
    // propertyData() cast every Property to DataProperty* and read data() through it. A FunctionProperty
    // keeps no such block, so what came back was whatever sat at that offset in a differently shaped
    // object. PID_ROUTETABLE_CONTROL is served by a FunctionProperty, PID_OBJECT_TYPE by a DataProperty,
    // so one object carries both cases.
    std::vector<uint8_t> flash;
    HostDevice dev(flash, 0x110A);
    TestRouter obj(dev.bau().memory());
    obj.initialize1x(DptMedium::KNX_IP, 254);

    EXPECT(obj.property(PID_ROUTETABLE_CONTROL) != nullptr, "the function property is missing, so nothing is under test");
    EXPECT(obj.propertyData(PID_ROUTETABLE_CONTROL) == nullptr,
           "a function property was read as if it kept a data block");
    EXPECT(obj.propertyData(PID_ROUTETABLE_CONTROL, 1) == nullptr,
           "the same through the element-index form");

    // Control: a real data property still hands out its block, so the guard did not simply turn it off.
    EXPECT(obj.propertyData(PID_OBJECT_TYPE) != nullptr, "a data property no longer returns its block");
}

HOST_TEST("HU-9.22", "Route table services on an object without a filter table report the failure instead of reading it")
{
    // The filter table is null until ETS loads one. The services used to work on kFilterTableSize (8192)
    // octets regardless and answered Success either way, so an unloaded table was read through a null
    // pointer and the caller was told the work had been done. 03_05_01 p.95 asks for FFh when it was not.
    std::vector<uint8_t> flash;
    HostDevice dev(flash, 0x110A);
    TestRouter obj(dev.bau().memory());
    obj.initialize1x(DptMedium::KNX_IP, 254);
    Property* p = obj.property(PID_ROUTETABLE_CONTROL);
    EXPECT(p != nullptr, "PID_ROUTETABLE_CONTROL is missing on a router object");
    EXPECT(!obj.hasData(), "this case needs an object whose filter table was never loaded");

    uint8_t result[8] = {0};
    uint8_t resultLength = sizeof(result);
    uint8_t clearTable[2] = {0x00, 0x01}; // ClearRoutingTable
    p->state(clearTable, sizeof(clearTable), result, resultLength);
    NOTE("ClearRoutingTable state: return code 0x" << std::hex << (int)result[0]);
    EXPECT(resultLength == 2 && result[0] == ReturnCodes::GenericError,
           "a table that does not exist was reported as cleared (return code " << (int)result[0] << ")");

    resultLength = sizeof(result);
    uint8_t setTable[2] = {0x00, 0x02}; // SetRoutingTable
    p->state(setTable, sizeof(setTable), result, resultLength);
    EXPECT(resultLength == 2 && result[0] == ReturnCodes::GenericError,
           "a table that does not exist was reported as set (return code " << (int)result[0] << ")");

    // ClearGroupAddress / SetGroupAddress carry a range: 03_05_01 4.5.16.1 puts start at data[2] and end
    // at data[4], and the answer repeats both.
    resultLength = sizeof(result);
    uint8_t range[6] = {0x00, 0x03, 0x08, 0x00, 0x08, 0xFF}; // ClearGroupAddress 0x0800..0x08FF
    p->state(range, sizeof(range), result, resultLength);
    NOTE("ClearGroupAddress state: return code 0x" << std::hex << (int)result[0] << ", " << std::dec << (int)resultLength << " octets");
    EXPECT(resultLength == 6 && result[0] == ReturnCodes::GenericError,
           "a range of a table that does not exist was judged (return code " << (int)result[0] << ")");
    EXPECT(result[2] == 0x08 && result[3] == 0x00 && result[4] == 0x08 && result[5] == 0xFF,
           "the answer did not repeat the range it was asked about");
}

HOST_TEST("HU-9.23", "A group address range outside the loaded filter table is refused, not written past its end")
{
    // A coupler whose ETS allocates a table shorter than all 8192 octets still has to serve the range it
    // holds - and must refuse the rest instead of reaching past the allocation.
    std::vector<uint8_t> flash;
    HostDevice dev(flash, 0x110A);
    TestRouter obj(dev.bau().memory());
    obj.initialize1x(DptMedium::KNX_IP, 254);
    Property* p = obj.property(PID_ROUTETABLE_CONTROL);
    EXPECT(p != nullptr, "PID_ROUTETABLE_CONTROL is missing on a router object");

    // 256 octets cover group addresses 0..2047; everything above is outside the allocation.
    loadControl(obj, {0x01});                                              // LE_START_LOADING
    loadControl(obj, {0x03, 0x0B, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00});    // allocate 256 octets
    loadControl(obj, {0x02});                                              // LE_LOAD_COMPLETED
    NOTE("load state " << (int)obj.loadState() << ", table " << obj.size() << " octets");
    EXPECT(obj.hasData() && obj.size() == 256, "the 256 octet filter table was not allocated (size " << obj.size() << ")");

    uint8_t result[8] = {0};
    uint8_t resultLength = sizeof(result);
    uint8_t inside[6] = {0x00, 0x03, 0x00, 0x00, 0x07, 0xFF}; // 0..2047: the last octet is 255
    p->state(inside, sizeof(inside), result, resultLength);
    NOTE("inside the allocation: return code 0x" << std::hex << (int)result[0]);
    EXPECT(result[0] == ReturnCodes::Success, "a range the table holds was refused (return code " << (int)result[0] << ")");

    resultLength = sizeof(result);
    uint8_t outside[6] = {0x00, 0x03, 0x00, 0x00, 0x08, 0x00}; // one group address past the allocation
    p->state(outside, sizeof(outside), result, resultLength);
    NOTE("one address past the allocation: return code 0x" << std::hex << (int)result[0]);
    EXPECT(result[0] == ReturnCodes::GenericError,
           "a range past the allocation was judged instead of refused (return code " << (int)result[0] << ")");

    resultLength = sizeof(result);
    uint8_t reversed[6] = {0x00, 0x03, 0x00, 0xFF, 0x00, 0x0A}; // end before start
    p->state(reversed, sizeof(reversed), result, resultLength);
    NOTE("end before start: return code 0x" << std::hex << (int)result[0]);
    EXPECT(result[0] == ReturnCodes::GenericError, "a range whose end is before its start was accepted");
}

namespace
{
/** @brief The bus access unit has no pure virtuals, so an empty one is enough to build a stack above it. */
struct SilentBau : BusAccessUnit
{
};
} // namespace

HOST_TEST("HU-2.10", "A device address that is no coupler address leaves no stale coupler type behind")
{
    // evaluateCouplerType() assigns the type only in the two branches that need a device part of 0; the
    // branch for every other address was empty, so the member kept whatever it held before - on the very
    // first evaluation an indeterminate value, and after a move away from a coupler address the previous
    // type. Bau091A::isAckRequired reads the verdict, so a stale type decides L2 acknowledges on TP.
    SilentBau bau;
    ApplicationLayer app(bau);
    TransportLayer transport(app);
    DeviceObject devObj;

    devObj.individualAddress(0x1100); // 1.1.0 - a line coupler
    NetworkLayerCoupler coupler(devObj, transport);
    const bool asCoupler = coupler.isRoutedIndividualAddress(0x1105, 1); // 1.1.5, on our own sub line
    NOTE("as line coupler 1.1.0, verdict for 1.1.5 from the sub line: " << (asCoupler ? "routed" : "not routed"));

    // ETS moves the device to an address with a device part: it is no longer a coupler.
    devObj.individualAddress(0x1105); // 1.1.5
    const bool asDevice = coupler.isRoutedIndividualAddress(0x1205, 1); // a foreign line
    NOTE("after the move to 1.1.5, verdict for 1.2.5: " << (asDevice ? "routed" : "not routed"));
    EXPECT(!asDevice, "a device that is no coupler still routed - the coupler type survived the move");

    // And it must stay that way for an address on what used to be its own line.
    const bool ownLine = coupler.isRoutedIndividualAddress(0x1109, 1);
    NOTE("after the move, verdict for 1.1.9: " << (ownLine ? "routed" : "not routed"));
    EXPECT(!ownLine, "a device that is no coupler routed an address of its former sub line");
}

namespace
{
/** @brief Counts what a network layer entity hands down, so a case can see whether a frame went out. */
struct RecordingDll : DataLinkLayer
{
    using DataLinkLayer::DataLinkLayer;
    int sent = 0;
    void loop() override {}
    void enabled(bool) override {}
    bool enabled() const override { return true; }
    DptMedium mediumType() const override { return DptMedium::KNX_TP1; }
    bool sendFrame(CemiFrame&) override { sent++; return true; }
};
} // namespace

HOST_TEST("HU-2.10b", "A device that is no coupler still sends the telegrams it originates")
{
    // The coupler type answers two different questions, and they must not be collapsed: whether to carry
    // SOMEONE ELSE'S frame (no, without a coupler role) and which interface carries a frame THIS device
    // originated (still one of them). Dropping the second left a device that acknowledges on layer 2 and
    // then answers nothing - no T_ACK, no device descriptor response - which is the harder failure.
    std::vector<uint8_t> flash;
    HostDevice dev(flash, 0x110A);
    SilentBau bau;
    ApplicationLayer app(bau);
    TransportLayer transport(app);
    DeviceObject devObj;
    devObj.individualAddress(0x1105); // 1.1.5: a device address, so no coupler role
    NetworkLayerCoupler coupler(devObj, transport);

    RecordingDll primary(devObj, coupler.getPrimaryInterface(), dev.platform(), bau);
    RecordingDll secondary(devObj, coupler.getSecondaryInterface(), dev.platform(), bau);
    coupler.getPrimaryInterface().dataLinkLayer(primary);
    coupler.getSecondaryInterface().dataLinkLayer(secondary);

    // A T_ACK back to a peer on what used to be our own line - the shape of every answer ETS waits for.
    CemiFrame frame(2);
    TPDU& tpdu = frame.tpdu();
    tpdu.type(DataInduvidual); // the library spells it this way
    coupler.dataIndividualRequest(AckRequested, 0x1109, NetworkLayerParameter, SystemPriority, tpdu);
    NOTE("sent on primary " << primary.sent << ", on secondary " << secondary.sent);
    EXPECT(primary.sent + secondary.sent >= 1,
           "a device that is no coupler dropped the telegram it originated - it would acknowledge and stay mute");
    // 1.1.9 shares the subnet of 1.1.5, so the answer belongs on the secondary side (TP), not out on IP.
    // Asserting only "something went out" would let a later change send every answer the wrong way.
    EXPECT(secondary.sent == 1 && primary.sent == 0,
           "the answer left on the wrong interface: primary " << primary.sent << ", secondary " << secondary.sent);
}

namespace
{
/** @brief Records the connect confirmations the transport layer passes up. */
struct ConnectRecordingBau : BusAccessUnit
{
    int confirms = 0;
    uint16_t lastTsap = 0;
    void connectConfirm(uint16_t tsap) override { confirms++; lastTsap = tsap; }
};

/** @brief Hands the transport layer a confirmation for a T_Connect it sent to destination. */
void confirmConnect(TransportLayer& tl, uint16_t destination, bool status)
{
    CemiFrame frame(1);
    TPDU& tpdu = frame.tpdu();
    tpdu.type(Connect);
    tl.dataIndividualConfirm(AckRequested, destination, NetworkLayerParameter, SystemPriority, tpdu, status);
}

/** @brief A transport layer above a coupler whose data link layers confirm nothing on their own. */
struct ConnectRig
{
    std::vector<uint8_t> flash;
    HostDevice dev{flash, 0x110A};
    ConnectRecordingBau bau;
    ApplicationLayer app{bau};
    TransportLayer tl{app};
    DeviceObject devObj;
    NetworkLayerCoupler coupler{devObj, tl};
    RecordingDll primary{devObj, coupler.getPrimaryInterface(), dev.platform(), bau};
    RecordingDll secondary{devObj, coupler.getSecondaryInterface(), dev.platform(), bau};
    ConnectRig()
    {
        devObj.individualAddress(0x1100); // 1.1.0
        tl.networkLayer(coupler);
        coupler.getPrimaryInterface().dataLinkLayer(primary);
        coupler.getSecondaryInterface().dataLinkLayer(secondary);
    }
    /** @brief Connect to a, give up, connect to b: the layer waits in CONNECTING for b. */
    void abandonAndReconnect(uint16_t a, uint16_t b)
    {
        tl.connectRequest(a, LowPriority);
        tl.disconnectRequest(a, LowPriority);
        tl.connectRequest(b, LowPriority);
    }
};
} // namespace

// 03_03_04 p.17 forbids the user a second request before the confirmation of the first, so E19/E20 (p.19) carry no
// address. A client that gives up (E26) and connects elsewhere can still meet the old confirmation late.
HOST_TEST("HU-3.4.1", "A late positive T_Connect confirmation for an abandoned partner does not open the new connect")
{
    ConnectRig r;
    const uint16_t a = 0x1205, b = 0x1206; // 1.2.5 abandoned, 1.2.6 being connected
    r.abandonAndReconnect(a, b);
    EXPECT(r.tl.hasOpenConnection() && r.tl.connectionPeer() == b && r.bau.confirms == 0,
           "the second T_Connect did not leave the layer waiting for 1.2.6");

    confirmConnect(r.tl, a, true);
    NOTE("after the late positive confirmation for 1.2.5: confirmations " << r.bau.confirms << ", tsap " << std::hex << r.bau.lastTsap);
    EXPECT(r.bau.confirms == 0, "a confirmation for 1.2.5 opened the connection to 1.2.6 (tsap " << std::hex << r.bau.lastTsap << ")");

    confirmConnect(r.tl, b, true);
    EXPECT(r.bau.confirms == 1 && r.bau.lastTsap == b, "the confirmation for 1.2.6 did not open the connection to 1.2.6");
}

HOST_TEST("HU-3.4.2", "A late negative T_Connect confirmation for an abandoned partner does not close the new connect")
{
    ConnectRig r;
    const uint16_t a = 0x1205, b = 0x1206;
    r.abandonAndReconnect(a, b);
    EXPECT(r.tl.hasOpenConnection() && r.tl.connectionPeer() == b && r.bau.confirms == 0,
           "the second T_Connect did not leave the layer waiting for 1.2.6");

    confirmConnect(r.tl, a, false);
    NOTE("after the late negative confirmation for 1.2.5: open " << r.tl.hasOpenConnection() << ", peer " << std::hex << r.tl.connectionPeer());
    EXPECT(r.tl.hasOpenConnection() && r.tl.connectionPeer() == b, "a negative confirmation for 1.2.5 closed the pending connect to 1.2.6");

    confirmConnect(r.tl, b, true);
    EXPECT(r.bau.confirms == 1 && r.bau.lastTsap == b, "the confirmation for 1.2.6 did not open the connection to 1.2.6");
}

// --- DPT converters: does a value survive the way out and back? ----------------------------------

HOST_TEST("HU-13.3", "A datapoint value survives decode, encode and decode again")
{
    // Whole-payload coverage cannot be measured from outside: several datapoints are field-addressed and
    // the index selects which part of the payload a converter writes (valueToBusValueTime is the clearest
    // case), so an octet left partly untouched is the design, not a fault. What CAN be measured is
    // fidelity: what the device read must come back out of the encoder unchanged.
    int checked = 0, broken = 0;
    std::string names;

    for (uint16_t main = 1; main <= 300; main++)
    {
        for (uint16_t sub : {1, 2, 3, 5, 6, 10, 11, 12, 13, 20, 100, 600, 1200})
        {
            for (uint8_t index = 0; index <= 2; index++)
            {
                Dpt dpt(main, sub, index);
                const uint8_t len = dpt.dataLength();
                if (len == 0 || len > 32) continue;

                // Several patterns: a single one decodes to an out-of-range value for some datapoints
                // (0x5A is hour 26 for DPT 10), which silently drops them out of the test.
                // The buffer has to outlive the value: busValueToString hands out a pointer INTO it
                // (dptconvert.cpp:1240), so letting it die first is a use-after-free in the caller.
                KNXValue a = (uint8_t)0;
                std::vector<uint8_t> first(len, 0x00);
                bool decoded = false;
                for (uint8_t pat : {0x00, 0x01, 0x11, 0x5A})
                {
                    std::fill(first.begin(), first.end(), pat);
                    if (KNX_Decode_Value(first.data(), len, dpt, a)) { decoded = true; break; }
                }
                if (!decoded) continue;

                std::vector<uint8_t> out(len, 0x00);
                if (!KNX_Encode_Value(a, out.data(), len, dpt)) continue; // not encodable at all: not this test

                // From here the converter has committed itself: it wrote a payload and called that a
                // success. Everything after this counts, including a refusal - skipping a failed step is
                // how this case first passed against a deliberately corrupted encoder.
                checked++;
                KNXValue b = (uint8_t)0;
                if (!KNX_Decode_Value(out.data(), len, dpt, b))
                {
                    broken++;
                    if (names.size() < 260) names += " " + std::to_string(main) + "." + std::to_string(sub) + "/" + std::to_string(index) + "(unreadable)";
                    continue;
                }

                std::vector<uint8_t> again(len, 0x00);
                if (!KNX_Encode_Value(b, again.data(), len, dpt))
                {
                    broken++;
                    if (names.size() < 260) names += " " + std::to_string(main) + "." + std::to_string(sub) + "/" + std::to_string(index) + "(unwritable)";
                    continue;
                }

                // The second encode must reproduce the first one octet for octet: the value reached a
                // fixed point, or it is being changed by passing through.
                if (memcmp(out.data(), again.data(), len) != 0)
                {
                    broken++;
                    if (names.size() < 260)
                        names += " " + std::to_string(main) + "." + std::to_string(sub) + "/" + std::to_string(index);
                }
            }
        }
    }

    NOTE("round trips exercised: " << checked << ", not stable: " << broken << names);
    EXPECT(checked > 40, "too few converters were exercised for this to mean anything");
    EXPECT(broken == 0, "a value changed while passing through the converters");
}
