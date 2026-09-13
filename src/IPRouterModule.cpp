#include "IPRouterModule.h"
#include <time.h>

// Tunnel status page. Same double guard as every module-contributed page: NetworkModule.h wraps its
// whole content in KNX_IP_*, so __has_include alone would resolve to an empty header.
#if defined(OPENKNX_WEBSERVER) && defined(KNX_TUNNELING) && (defined(KNX_IP_LAN) || defined(KNX_IP_WIFI))
    #define IPRO_HAS_WEBPAGE 1
    #include "NetworkModule.h"
    #include "OpenKNX/Network/Webserver/Webserver.h"
    #include "webassets.h"
#endif

#ifdef KNX_TUNNELING
// --- `tun` formatting helpers (identical to OAM-IP-Interface, so both products read the same) ---
// Spec names, not house shorthand: DEVICE_MGMT_CONNECTION 03h / TUNNEL_CONNECTION 04h
// (03_08_02 Core Table 7) and the busmonitor layer 80h (03_08_04 Table 10).
static const char *tunTypeName(uint8_t t)
{
    switch (t)
    {
#ifdef OPENKNX_HW_BUSMON // only a device with the HW busmonitor can ever report this
        case IpTunnelServer::TUN_BUSMON: return "Busmonitor";
#endif
        case IpTunnelServer::TUN_CONFIG: return "Device-Mgmt";
        case IpTunnelServer::TUN_OTHER: return "unbekannt";
        default: return "Tunnel";
    }
}
// --- Reserved tunnels -------------------------------------------------------------------------
// ETS writes the reservation onto the KNXnet/IP object; the stack picks the slot at connect time.
// Here it is only read back so the view can say which connection sits where.
enum TunAssign : uint8_t
{
    TUN_ASSIGN_FREE = 0,     // no reservation applies to this client
    TUN_ASSIGN_FIXED = 1,    // sits on the slot reserved for its IP
    TUN_ASSIGN_FALLBACK = 2, // a slot is reserved for its IP, but it sits elsewhere
};

static uint32_t reservedIpAt(const uint8_t *ips, uint8_t i)
{
    const uint8_t *p = ips + 4 * i;
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

// The reservation table is owned by the KNX property and is freed on the next ETS write to it, so it
// is mirrored here from the module loop and only the mirror is read -- the web handler runs on another
// task on ESP32 and must never hold that pointer.
static uint8_t resvCtrl[KNX_TUNNELING];
static uint8_t resvIp[KNX_TUNNELING * 4];
static bool resvAny = false; // at least one tunnel is reserved
static uint32_t resvAt = 0;  // millis() of the last mirror
// Same rule as the reservation table: the property is reallocated on every write, the web handler
// runs on another task, so it reads this mirror.
static uint16_t resvIa[KNX_TUNNELING];
static uint8_t resvIaUsed = 0, resvIaTotal = 0;
// knx.configured() is NOT const -- it writes _configured on every call. Mirrored like the rest so the
// web task never reaches into BAU state; the KNX loop is the only caller.
static bool cfgMirror = true;

// Routing group + TTL, mirrored from the KNX loop (see refreshIas).
static char mcAddr[16] = {0};
static uint8_t mcTtl = 0;
static bool mcTtlValid = false; // 0 is a legal configured TTL, so absent must not render as 0

static void refreshReserved()
{
    IpTunnelServer &ts = knx.bau().getIpTunnelServer();
    const uint8_t *ctrl = ts.reservedTunnelsCtrl();
    const uint8_t *ips = ts.reservedTunnelsIp();
    resvAny = false;
    if (ctrl == nullptr || ips == nullptr) return;
    memcpy(resvCtrl, ctrl, sizeof(resvCtrl));
    memcpy(resvIp, ips, sizeof(resvIp));
    for (uint8_t i = 0; i < KNX_TUNNELING; i++)
        if (resvCtrl[i] & 0x80) resvAny = true;
}

/** @brief What the stack decided at connect time, not a guess from the address shown. */
static uint8_t tunAssign(uint8_t slot, uint8_t resSlot)
{
    if (resSlot == 0xFF) return TUN_ASSIGN_FREE;
    return (slot == resSlot) ? TUN_ASSIGN_FIXED : TUN_ASSIGN_FALLBACK;
}

static void formatTunIp(uint32_t ip, char *b, size_t n)
{
    snprintf(b, n, "%u.%u.%u.%u", (unsigned)((ip >> 24) & 0xFF), (unsigned)((ip >> 16) & 0xFF),
             (unsigned)((ip >> 8) & 0xFF), (unsigned)(ip & 0xFF));
}
static void formatTunPa(uint16_t pa, char *b, size_t n)
{
    if (pa == 0)
        snprintf(b, n, "-");
    else
        snprintf(b, n, "%u.%u.%u", (pa >> 12) & 0x0F, (pa >> 8) & 0x0F, pa & 0xFF);
}
static const char *tunReasonName(uint8_t r, uint8_t det)
{
    switch (r)
    {
        case IpTunnelServer::END_TIMEOUT: return "Timeout";
#ifdef OPENKNX_HW_BUSMON // set by ip_tunnel_server only under this switch -- dead on a router
        case IpTunnelServer::END_BUSMON: return "Busmon";
        case IpTunnelServer::END_BUSMON_LOST: return "Busmon unerwartet beendet";
#endif
        case IpTunnelServer::END_CLOSED: return "Vom Client getrennt";
        case IpTunnelServer::END_EVICTED: return "Ersetzt (Reservierung)";
        case IpTunnelServer::END_NOACK: return "Keine Quittung";
        case IpTunnelServer::END_OVERFLOW: return "Warteschlange voll";
        case IpTunnelServer::END_LOCAL: return "Getrennt (lokal)";
        case IpTunnelServer::END_REJ_TYPE: return "Abgelehnt: Typ";
        case IpTunnelServer::END_REJ_LAYER: return "Abgelehnt: Layer";
        // The stack reports three different causes under one reason; detail carries the KNX error code
        // it sent back (0x24 no free slot, 0x25 no unique address, 0 the busmonitor holds the bus).
        case IpTunnelServer::END_REJ_BUSY:
            return det == 0x24 ? "Abgelehnt: kein freier Tunnel"
                 : det == 0x25 ? "Abgelehnt: keine freie Adresse"
                               : "Abgelehnt: belegt";
        default: return "active";
    }
}
// Refused attempts carry the offending CRI type / KNX layer octet; "" for a normal session.
static void formatTunDetail(uint8_t reason, uint8_t detail, char *b, size_t n)
{
    if (reason == IpTunnelServer::END_REJ_TYPE || reason == IpTunnelServer::END_REJ_LAYER ||
        (reason == IpTunnelServer::END_REJ_BUSY && detail != 0))
        snprintf(b, n, "%02Xh", detail);
    else
        b[0] = '\0';
}
static void formatDuration(uint32_t sec, char *b, size_t n)
{
    if (sec < 60)
        snprintf(b, n, "%us", (unsigned)sec);
    else if (sec < 3600)
        snprintf(b, n, "%um%02us", (unsigned)(sec / 60), (unsigned)(sec % 60));
    else
        snprintf(b, n, "%uh%02um", (unsigned)(sec / 3600), (unsigned)((sec / 60) % 60));
}
// Can this entry serve as a tunnel identity? Empty, and FFh, cannot: 03_05_01 3.3 p.20 reserves FFh
// for "device without an assigned address" and ETS writes x.y.FF for a tunnel it left unassigned -- that
// is what shows as "5.0.-" in the topology. Device part 00h IS allowed (03_08_04 4.2.2 p.18 permits it
// for tunnelling), so it counts as usable even though NOTE 6 calls it topologically undesirable.
static bool tunIaHasDevicePart(uint16_t pa) { return pa != 0 && (pa & 0x00FF) != 0x00FF; }

// ias/iasMax optionally receive the raw per-slot addresses, so the UI can name the slot that is missing
// one instead of only reporting a total.
static bool readAdditionalIas(uint8_t &used, uint8_t &total, uint16_t *ias = nullptr, uint8_t iasMax = 0)
{
    used = total = 0;
    for (uint8_t i = 0; i < iasMax && ias != nullptr; i++)
        ias[i] = 0;
    // Element 0 of a property array is its current element count. Asking for 16 when fewer are
    // programmed makes DataProperty::read() return nothing at all, and the row would vanish instead
    // of saying "4 of 16" - so ask how many there are first.
    uint8_t *pv = nullptr;
    uint32_t plen = 0;
    uint8_t cnt = 1;
    knx.bau().propertyValueRead(OT_IP_PARAMETER, 0, PID_ADDITIONAL_INDIVIDUAL_ADDRESSES, cnt, 0, &pv, plen);
    const uint16_t have = (pv != nullptr && cnt > 0 && plen >= 2) ? (uint16_t)((pv[0] << 8) | pv[1]) : 0;
    delete[] pv;
    if (have == 0) return false;

    total = (uint8_t)(have > KNX_TUNNELING ? KNX_TUNNELING : have);
    pv = nullptr;
    plen = 0;
    cnt = total;
    knx.bau().propertyValueRead(OT_IP_PARAMETER, 0, PID_ADDITIONAL_INDIVIDUAL_ADDRESSES, cnt, 1, &pv, plen);
    // propertyValueRead() sizes the buffer from the REQUEST, so only the elements it reports as
    // written may be read - the rest of the block is uninitialised heap.
    const bool ok = (pv != nullptr && cnt > 0 && (uint32_t)cnt * 2 <= plen);
    if (ok)
    {
        total = cnt;
        for (uint32_t i = 0; i + 1 < (uint32_t)cnt * 2; i += 2)
        {
            const uint16_t pa = (uint16_t)((uint16_t)pv[i] << 8 | pv[i + 1]);
            if (ias != nullptr && (i / 2) < iasMax) ias[i / 2] = pa;
            // A duplicate is not a second usable identity: 03_08_03 2.5.4 p.9 makes a duplicated entry
            // the very case that answers E_NO_MORE_UNIQUE_CONNECTIONS. It also happens by itself --
            // DataProperty::write only ever GROWS an array, so a shorter ETS list leaves the old tail
            // in place and the stale entry can repeat an address from the current one.
            bool dup = false;
            for (uint32_t j = 0; j < i && !dup; j += 2)
                dup = (((uint16_t)pv[j] << 8 | pv[j + 1]) == pa);
            if (tunIaHasDevicePart(pa) && !dup) used++;
        }
    }
    delete[] pv;
    return ok;
}

// Mirrored from the KNX loop for the same reason as refreshReserved().
static void refreshIas()
{
    // Built into locals and published at the end: readAdditionalIas() zeroes its outputs and sets the
    // total BEFORE it fills the addresses, so a web request landing in that window read "0 of 16" on a
    // healthy device and turned the whole status bar red for one poll.
    uint8_t u = 0, t = 0;
    uint16_t ia[KNX_TUNNELING] = {0};
    if (!readAdditionalIas(u, t, ia, KNX_TUNNELING)) u = t = 0;
    char mc[sizeof(mcAddr)] = {0};
    uint8_t ttl = 0;
    bool ttlOk = false;

    // The routing group and its TTL. Mirrored for the same reason as the addresses above: a web
    // request runs in its own task on ESP32, and propertyValueRead() copies out of DataProperty::_data
    // while an ETS download can be reallocating it.
    uint8_t *pv = nullptr;
    uint32_t plen = 0;
    uint8_t cnt = 1;
    knx.bau().propertyValueRead(OT_IP_PARAMETER, 0, PID_ROUTING_MULTICAST_ADDRESS, cnt, 1, &pv, plen);
    if (pv != nullptr && cnt > 0 && plen >= 4)
        snprintf(mc, sizeof(mc), "%u.%u.%u.%u", pv[0], pv[1], pv[2], pv[3]);
    delete[] pv;

    pv = nullptr;
    plen = 0;
    cnt = 1;
    knx.bau().propertyValueRead(OT_IP_PARAMETER, 0, PID_TTL, cnt, 1, &pv, plen);
    if (pv != nullptr && cnt > 0 && plen >= 1)
    {
        ttl = pv[0];
        ttlOk = true;
    }
    delete[] pv;

    // Gate CLOSED first, payload second, gate OPEN last -- the order refreshReserved() uses one function
    // above. Publishing resvIaUsed before resvIaTotal let a web reader land on "0 of 16" (new used, old
    // total) and paint the whole status bar red on a healthy device: exactly the glitch this mirror was
    // written to remove. The barriers are what make the order real; without them the compiler may sink
    // or hoist any of these three stores, and on ESP32 the reader is a different task.
    cfgMirror = knx.configured();
    resvIaTotal = 0;
    __asm__ volatile("" ::: "memory");
    if (memcmp(resvIa, ia, sizeof(resvIa)) != 0) memcpy(resvIa, ia, sizeof(resvIa));
    // Written only on an actual change, so the steady state cannot tear at all: the web task reads
    // these without a lock, and this string changes at most once per ETS download. On that one tick a
    // reader can still catch a spliced address -- a cosmetic glitch on a device being reconfigured,
    // not worth a seqlock here.
    if (memcmp(mcAddr, mc, sizeof(mcAddr)) != 0) memcpy(mcAddr, mc, sizeof(mcAddr));
    mcTtl = ttl;
    mcTtlValid = ttlOk;
    resvIaUsed = u;
    __asm__ volatile("" ::: "memory");
    resvIaTotal = t; // last: every consumer gates the address column and the warnings on this
}

// "Now" on the wall clock, read once per report: getLocalTime()/mktime() are invariant across all
// entries of one list, only the elapsed seconds differ.
struct WallNow
{
    bool valid = false;
    time_t epoch = 0;
    int yday = 0, year = 0;
};

static WallNow wallNow()
{
    WallNow w;
    if (!openknx.time.isValid()) return w;
    auto dt = openknx.time.getLocalTime();
    struct tm t = {};
    t.tm_year = dt.year - 1900;
    t.tm_mon = dt.month - 1;
    t.tm_mday = dt.day;
    t.tm_hour = dt.hour;
    t.tm_min = dt.minute;
    t.tm_sec = dt.second;
    // -1, not the 0 a value-initialised tm carries: with 0 mktime resolves the local time as standard
    // time, so every stamp is an hour late while summer time is in effect (and the same-day test with
    // it). The ambiguous hour of the autumn fall-back is the price for seven correct months.
    t.tm_isdst = -1;
    w.epoch = mktime(&t); // normalises t -> tm_yday/tm_year valid for "today"
    w.valid = true;
    w.yday = t.tm_yday;
    w.year = t.tm_year;
    return w;
}

// Session start: absolute HH:MM:SS when the clock is valid (recomputed from now - elapsed, so it is
// correct even if the clock only became valid AFTER the session started), else on the uptime scale.
static void formatStart(const WallNow &now, uint32_t agoSec, char *b, size_t n)
{
    if (now.valid)
    {
        // Clamp before the subtraction: agoSec is an unsigned difference, and time_t is 32-bit signed
        // on the RP2040, so an out-of-range value would be signed overflow rather than a wrong date.
        // localtime_r can still refuse the value, which leaves st untouched -- hence the zeroing.
        const uint32_t ago = (agoSec > (uint32_t)now.epoch) ? (uint32_t)now.epoch : agoSec;
        time_t startEpoch = now.epoch - (time_t)ago;
        struct tm st = {};
        if (localtime_r(&startEpoch, &st) == nullptr)
        {
            snprintf(b, n, "-");
            return;
        }
        // Same day -> time only; anything older gets the date.
        if (st.tm_yday == now.yday && st.tm_year == now.year)
            strftime(b, n, "%H:%M:%S", &st);
        else
            strftime(b, n, "%d.%m. %H:%M", &st);
    }
    else
    {
        snprintf(b, n, "Up %s", humanDuration(uptime() > agoSec ? uptime() - agoSec : 0).c_str());
    }
}

// Second console line of a session: what crossed it and what went wrong. active adds the last-contact
// age, which a finished session does not have. "<-client" is what was ACCEPTED from the client -- not
// what reached TP: a frame addressed to the interface itself or to a tunnel PA is answered locally.
// A busmonitor has no receive direction and no send queue at all, so those fields are left out rather
// than printed as a zero or as a dash under a name that does not apply to it.
static void formatTunStats(const IpTunnelServer::TunnelEvent &e, bool active, char *b, size_t n)
{
    const bool busmon = (e.type == IpTunnelServer::TUN_BUSMON);
    const bool fifo = (e.queueDepth != 0) && !busmon;
    char rx[28], fi[72], dp[20], last[32];
    rx[0] = fi[0] = last[0] = '\0';
    // Every connection type can lose a frame -- the busmonitor most of all, because nothing retries
    // there. So this field is never gated on the send FIFO.
    snprintf(dp, sizeof(dp), "  dropped %u", (unsigned)e.txDrop);
    if (!busmon)
        snprintf(rx, sizeof(rx), "  <-client %s", humanCount(e.fromClient).c_str());
    if (fifo)
        snprintf(fi, sizeof(fi), "  resend %u  queue max %u/%u  load-dropped %u", (unsigned)e.resend,
                 (unsigned)e.queuePeak, (unsigned)e.queueDepth, (unsigned)e.grpDrop);
    if (active && e.hbMillis != 0)
    {
        char d[12];
        formatDuration((uint32_t)((millis() - e.hbMillis) / 1000), d, sizeof(d));
        snprintf(last, sizeof(last), "  last contact %s", d);
    }
    // A sequence error is any datagram discarded because its counter was not the expected one -- a gap
    // as well as a stale repeat. The busmonitor has no receive direction, so it has none.
    char sq[24];
    sq[0] = '\0';
    if (!busmon)
        snprintf(sq, sizeof(sq), "  seq-err %u", (unsigned)e.seqGap);
    snprintf(b, n, "->client %s%s%s%s%s%s", humanCount(e.toClient).c_str(), rx, fi, dp, sq, last);
}

#ifdef OPENKNX_ROUTE_TRACE
// Group address in the three-level notation ETS shows. Only the routing views need it.
static const uint16_t MAX_FILT_RANGES = 64; // emitted ranges; the counter still reports the true total
static const uint32_t FILT_SLICE = 2048;    // addresses per loop pass, ~0.7 ms on the RP2040

static void formatGa(uint16_t ga, char *b, size_t n)
{
    snprintf(b, n, "%u/%u/%u", (unsigned)((ga >> 11) & 0x1F), (unsigned)((ga >> 8) & 0x07), (unsigned)(ga & 0xFF));
}
#endif

#endif // KNX_TUNNELING

IPRouterModule *IPRouterModule::_instance = nullptr;

IPRouterModule::IPRouterModule()
{
    IPRouterModule::_instance = this;
}

IPRouterModule *IPRouterModule::instance()
{
    return IPRouterModule::_instance;
}

const std::string IPRouterModule::name()
{
    return "IPRouterModule";
}

const std::string IPRouterModule::version()
{
    return "";
}


// Router = device part 0; line part 0 means backbone coupler (x.0.0), else line coupler (x.y.0).
// Two audiences with opposite conventions: the console is English and pure ASCII, the web page is German
// and UTF-8. One formatter with a flag, because two would drift apart. The German text is written as HEX
// ESCAPES, not HTML entities: the page escapes every device string (esc() turns & into &amp;), so an
// entity would be printed literally. Escapes keep this file free of non-ASCII bytes and still put real
// UTF-8 on the wire.
static void formatCouplerRole(uint16_t pa, char *buf, size_t len, bool web = false)
{
    const uint8_t area = (uint8_t)(pa >> 12);
    const uint8_t line = (uint8_t)((pa >> 8) & 0x0F);
    // VS15 keeps the arrow a text glyph; alone it becomes a colour emoji on Windows and Android.
    const char *arrow = web ? "\xE2\x86\x94\xEF\xB8\x8E" : "<->"; // U+2194 + VS15 (text, not emoji)
    if ((pa & 0x00FF) != 0)
        snprintf(buf, len, web ? "Kein Koppler - Adresse %u.%u.%u hat einen Ger\xC3\xA4teteil"
                               : "NO ROUTER - address %u.%u.%u has a device part",
                 area, line, (unsigned)(pa & 0xFF));
    else if (line == 0)
        snprintf(buf, len, web ? "Bereichskoppler IP %s Hauptlinie %u.0"
                               : "Backbone coupler   IP %s main line %u.0", arrow, area);
    else
        snprintf(buf, len, web ? "Linienkoppler IP %s Linie %u.%u"
                               : "Line coupler       IP %s line %u.%u", arrow, area, line);
}

bool IPRouterModule::processCommand(const std::string cmd, bool diagnoseKo)
{
    if (diagnoseKo)
        return false;

    if (cmd.substr(0, 5) == "apdu " && cmd.length() > 5)
    {
        std::string apdustr = cmd.substr(5, cmd.length() - 5);
        uint16_t apdu = std::stoi(apdustr, nullptr, 10);
        if (apdu >= 15 && apdu <= 254)
        {
            uint8_t NoOfElem = 1;
            uint8_t data[2];
            data[0] = apdu / 0x100;
            data[1] = apdu % 0x100;
            knx.bau().propertyValueWrite(OT_DEVICE, 0, PID_MAX_APDU_LENGTH, NoOfElem, 1, data, sizeof(data));
            openknx.logger.logWithPrefixAndValues("Set APDU", "PID_MAX_APDU_LENGTH set to %i", apdu);
            return true;
        }
    }
    else if (cmd.substr(0, 11) == "route apdu " && cmd.length() > 11)
    {
        std::string apdustr = cmd.substr(11, cmd.length() - 11);
        uint8_t apdu = std::stoi(apdustr, nullptr, 10);
        if (apdu >= 15 && apdu <= 254)
        {
            uint8_t NoOfElem = 1;
            uint8_t data[2];
            data[0] = apdu / 0x100;
            data[1] = apdu % 0x100;
            knx.bau().propertyValueWrite(OT_ROUTER, 0, PID_MAX_APDU_LENGTH_ROUTER, NoOfElem, 1, data, sizeof(data));
            openknx.logger.logWithPrefixAndValues("Set APDU", "PID_MAX_APDU_LENGTH_ROUTER set to %i", apdu);
            return true;
        }
    }

    if (cmd == "ipro reset")
    {
        openknx.busLoad.reset();
#ifdef OPENKNX_ROUTE_TRACE
        knx.bau().getRouteTrace().resetTop();
        logInfoP("Bus load history and the per-address routing counts cleared");
#else
        logInfoP("Bus load history, average and peak cleared");
#endif
        return true;
    }
    if (cmd == "ipro ?")
    {
        showHelp();
        return true;
    }
    if (cmd == "ipro")
    {
        char buf[64];
        const uint16_t pa = knx.individualAddress();
        formatCouplerRole(pa, buf, sizeof(buf));
        logInfoP("Role       %s", buf);
        logInfoP("PA         %u.%u.%u", (unsigned)(pa >> 12), (unsigned)((pa >> 8) & 0x0F), (unsigned)(pa & 0xFF));

        uint8_t *pv = nullptr;
        uint32_t plen = 0;
        uint8_t cnt = 1;
        knx.bau().propertyValueRead(OT_IP_PARAMETER, 0, PID_ROUTING_MULTICAST_ADDRESS, cnt, 1, &pv, plen);
        char mcs[16] = "-";
        if (pv != nullptr && cnt > 0 && plen >= 4) // cnt: what was written, plen: what was requested
            snprintf(mcs, sizeof(mcs), "%u.%u.%u.%u", pv[0], pv[1], pv[2], pv[3]);
        delete[] pv;

        pv = nullptr;
        plen = 0;
        cnt = 1;
        knx.bau().propertyValueRead(OT_IP_PARAMETER, 0, PID_TTL, cnt, 1, &pv, plen);
        const uint8_t ttl = (pv != nullptr && cnt > 0 && plen >= 1) ? pv[0] : 0;
        delete[] pv;
        logInfoP("Multicast  %-15s TTL %u", mcs, ttl);

#ifdef KNX_TUNNELING
        IpTunnelServer &ts = knx.bau().getIpTunnelServer();
        logInfoP("Tunnels    %u / %u active", ts.tunnelCount(), ts.tunnelMax());
#endif

        // Ours: what the routing decision did. Filtered telegrams are dropped by design, not lost.
        KnxIpCounters &c = knx.bau().getCounters();
        logInfoP("Routed     ->IP %lu   ->TP %lu", (unsigned long)c.routedToIp(), (unsigned long)c.routedToKnx());
        logInfoP("Filtered   ->IP %lu   ->TP %lu", (unsigned long)c.filteredToIp(), (unsigned long)c.filteredToKnx());
        // 03_08_03: ->IP counts EVERY KNXnet/IP datagram, tunnelling and ACKs included.
        logInfoP("Telegrams  ->IP %lu   ->TP %lu   (PID 74/75)",
                 (unsigned long)c.transmitToIp(), (unsigned long)c.transmitToKnx());
        logInfoP("Lost       ->IP %u    ->TP %u    (PID 72/73, queue overflow)",
                 c.overflowToIp(), c.overflowToKnx());
        // Telegrams that had used up their couplers. Nothing counted these before.
        logInfoP("Hop-Count 0->IP %lu   ->TP %lu",
                 (unsigned long)c.hopCountToIp(), (unsigned long)c.hopCountToKnx());

        // Shared 1 Hz sampler; 100% = the line is full (03_02_02 line time, not a byte rate).
        const uint16_t now10 = openknx.busLoad.currentPermille();
        const uint16_t avg10 = openknx.busLoad.averagePermille();
        const uint16_t pk10 = openknx.busLoad.peakPermille();
        logInfoP("Bus load   %u.%u%% now   %u.%u%% avg/%us   %u.%u%% peak   (%u B/s)",
                 now10 / 10, now10 % 10, avg10 / 10, avg10 % 10,
                 (unsigned)openknx.busLoad.historyCount(), pk10 / 10, pk10 % 10,
                 (unsigned)openknx.busLoad.currentBytesPerSec());
        return true;
    }

#ifdef KNX_TUNNELING
    if (cmd == "tun ?")
    {
        showHelp();
        return true;
    }
    if (cmd == "tun")
    {
        IpTunnelServer &ts = knx.bau().getIpTunnelServer();
        IpTunnelServer::TunnelEvent act[KNX_TUNNELING + KNX_TUNNELING_DEVMGMT + 1];
        const uint8_t n = ts.activeTunnels(act, sizeof(act) / sizeof(act[0]));

        logInfoP("Tunnels: %u / %u active", ts.tunnelCount(), ts.tunnelMax());
#ifdef OPENKNX_HW_BUSMON
        // Asks the tunnel server, so it sees only an ETS busmonitor. The interface asks the DRIVER
        // instead, which also catches a local `bcu mon`. Dead here (no OPENKNX_HW_BUSMON on a
        // router); align it with the interface before ever enabling the HW busmonitor.
        if (ts.busMonitorActive())
            logInfoP("  ** HW BUSMONITOR ACTIVE - bus TX paused, tunnel connects rejected **");
#endif
        refreshReserved(); // console runs on the KNX loop, so the mirror can be taken right here
        uint8_t iaUsed = 0, iaTotal = 0;
        uint16_t slotIa[KNX_TUNNELING] = {0};
        const bool haveIas = readAdditionalIas(iaUsed, iaTotal, slotIa, KNX_TUNNELING);
        if (haveIas && iaUsed < iaTotal)
            logInfoP("  note: %u of %u tunnel addresses not assigned (.255 marker or duplicate)",
                     (unsigned)(iaTotal - iaUsed), (unsigned)iaTotal);
        char ip[16], pa[12], start[20], dur[12], zs[28];
        const WallNow now = wallNow();
        for (uint8_t i = 0; i < n; i++)
        {
            formatTunIp(act[i].ip, ip, sizeof(ip));
            formatTunPa(act[i].pa, pa, sizeof(pa));
            formatStart(now, ts.secondsSince(act[i].startS), start, sizeof(start));
            formatDuration(act[i].ageS, dur, sizeof(dur));
            const uint8_t z = tunAssign(act[i].slot, act[i].resSlot);
            if (z == TUN_ASSIGN_FIXED)
                snprintf(zs, sizeof(zs), "  fixed T%u", (unsigned)(act[i].resSlot + 1));
            else if (z == TUN_ASSIGN_FALLBACK)
                snprintf(zs, sizeof(zs), "  fallback, T%u reserved", (unsigned)(act[i].resSlot + 1));
            else
                zs[0] = 0;
            logInfoP("  %-11s %-8s %-15s  %-18s up %s%s", tunTypeName(act[i].type), pa, ip, start, dur, zs);
            char st[192]; // 186 by the capacity rule this file uses (9+5+27+71+19+23+31+NUL)
            formatTunStats(act[i], true, st, sizeof(st));
            logInfoP("    %s", st);
        }
        if (resvAny)
        {
            for (uint8_t i = 0; i < KNX_TUNNELING; i++)
            {
                if ((resvCtrl[i] & 0x80) == 0) continue;
                formatTunIp(reservedIpAt(resvIp, i), ip, sizeof(ip));
                // Always the address as stored, so the reservation can be checked against ETS.
                char spa[12];
                if (haveIas && i < iaTotal)
                    formatTunPa(slotIa[i], spa, sizeof(spa));
                else
                    snprintf(spa, sizeof(spa), "?");
                logInfoP("  reserved: T%-2u %-15s %s", i + 1, ip, spa);
            }
        }

        const uint8_t hc = ts.tunnelHistoryCount();
        if (hc)
        {
            logInfoP("History (last %u):", hc);
            for (uint8_t i = 0; i < hc; i++)
            {
                IpTunnelServer::TunnelEvent ev;
                if (!ts.tunnelHistoryCopy(i, ev))
                    continue; // torn copy: skip this row, the rest of the list is still good
                const IpTunnelServer::TunnelEvent *e = &ev;
                formatTunIp(e->ip, ip, sizeof(ip));
                formatTunPa(e->pa, pa, sizeof(pa));
                formatStart(now, ts.secondsSince(e->startS), start, sizeof(start));
                formatDuration(e->ageS, dur, sizeof(dur));
                // A refusal is not a session: repeated identical refusals are folded into one entry
                // whose end keeps moving, so the span would read like a connection that lasted minutes.
                if (e->reason >= IpTunnelServer::END_REJ_TYPE) dur[0] = '\0';
                char det[8];
                formatTunDetail(e->reason, e->detail, det, sizeof(det));
                logInfoP("  %-11s %-8s %-15s  %-18s %-8s %s %s", tunTypeName(e->type), pa, ip, start, dur,
                         tunReasonName(e->reason, e->detail), det);
                // A refused connect never had a session, so it has no counters to print.
                if (e->reason < IpTunnelServer::END_REJ_TYPE)
                {
                    char st[192]; // 186 by the capacity rule this file uses (9+5+27+71+19+23+31+NUL)
                    formatTunStats(*e, false, st, sizeof(st));
                    logInfoP("    %s", st);
                }
            }
        }
        return true;
    }
#endif // KNX_TUNNELING

    return false;
}

void IPRouterModule::showHelp()
{
#ifdef OPENKNX_ROUTE_TRACE
    openknx.console.printHelpLine("ipro reset", "Clear bus load history/average/peak AND the per-address routing counts");
#else
    openknx.console.printHelpLine("ipro reset", "Clear the bus load history, average and peak");
#endif
    openknx.console.printHelpLine("ipro", "Router status: coupler role/line, multicast, routing + KNXnet/IP counters, bus load");
#ifdef KNX_TUNNELING
    openknx.console.printHelpLine("tun", "Tunnel list (active + type) and last-32 connect/disconnect history");
#endif
}

#ifdef IPRO_HAS_WEBPAGE
using namespace OpenKNX::Network;

// All report endpoints share one buffer. Its capacity is a high-water mark that is never returned,
// so three separate buffers would hold three peaks for the whole uptime instead of one.
static std::string &reportBuffer()
{
    static std::string buf;
    return buf;
}

// Active/finished tunnel entries as JSON arrays, formatted by the same helpers the `tun` console
// command uses, so both views can never disagree.
// The configured reservations, so the page can show them even when nothing is connected.
static void appendTunnelReserved(std::string &json)
{
    if (!resvAny) return; // nothing reserved: the key stays away and the page keeps its old columns

    char buf[40], ip[16];
    bool first = true;
    for (uint8_t i = 0; i < KNX_TUNNELING; i++)
    {
        if ((resvCtrl[i] & 0x80) == 0) continue;
        formatTunIp(reservedIpAt(resvIp, i), ip, sizeof(ip));
        snprintf(buf, sizeof(buf), "%s[%u,\"%s\"]", first ? ",\"resv\":[" : ",", i + 1, ip);
        json += buf;
        first = false;
    }
    if (!first) json += "]";
}

// The counters as JSON keys. A key that does not apply to this connection type is LEFT OUT, so the
// page renders a dash instead of a zero. "k" is the session's connect time in millis(): the page needs
// a row identity that does NOT change between polls, and the formatted start jitters by a second
// because "now" and the elapsed time round independently.
// Upper bound 140 bytes: k 16, tc/fc 17 each, rs/dr/gp/gd 12 each, qp/qd 10 each, idle 22.
static void appendTunCounters(char *b, size_t n, const IpTunnelServer::TunnelEvent &e, bool active)
{
    const bool busmon = (e.type == IpTunnelServer::TUN_BUSMON);
    const bool fifo = (e.queueDepth != 0) && !busmon;
    // dr is NOT in the FIFO group: a busmonitor and a build without the FIFO lose frames too, and there
    // they are unrecoverable -- exactly the case that must reach the screen.
    int w = snprintf(b, n, ",\"k\":%lu,\"tc\":%lu,\"dr\":%u", (unsigned long)e.startMillis,
                     (unsigned long)e.toClient, (unsigned)e.txDrop);
    if (w < 0 || (size_t)w >= n) return;
    // Accepted from the client. Not "to the bus": a frame for the interface itself or for a tunnel PA
    // is answered locally and never leaves for TP.
    if (!busmon)
        w += snprintf(b + w, n - w, ",\"fc\":%lu,\"gp\":%u", (unsigned long)e.fromClient, (unsigned)e.seqGap);
    if (w < 0 || (size_t)w >= n) return;
    if (fifo)
        w += snprintf(b + w, n - w, ",\"rs\":%u,\"qp\":%u,\"qd\":%u,\"gd\":%u", (unsigned)e.resend,
                      (unsigned)e.queuePeak, (unsigned)e.queueDepth, (unsigned)e.grpDrop);
    if (w < 0 || (size_t)w >= n) return;
    if (active && e.hbMillis != 0)
    {
        char d[12];
        formatDuration((uint32_t)((millis() - e.hbMillis) / 1000), d, sizeof(d));
        snprintf(b + w, n - w, ",\"idle\":\"%s\"", d);
    }
}

static void appendTunnelIas(std::string &json)
{
    const uint8_t total = resvIaTotal; // the mirror, never the live property (see refreshIas)
    const uint16_t *ias = resvIa;
    if (total == 0) return;
    char buf[16], pa[12];
    json += ",\"ia\":[";
    for (uint8_t i = 0; i < total; i++)
    {
        // The address exactly as stored. A slot that cannot serve is flagged, not hidden: hiding it
        // would keep the reader from comparing what ETS wrote against what the device holds.
        // "*" = no device part (ETS shows 5.0.-), "!" = repeats an earlier slot.
        formatTunPa(ias[i], pa, sizeof(pa));
        bool dup = false;
        for (uint8_t j = 0; j < i && !dup; j++)
            dup = (ias[j] == ias[i]);
        if (!tunIaHasDevicePart(ias[i])) strncat(pa, "*", sizeof(pa) - strlen(pa) - 1);
        else if (dup) strncat(pa, "!", sizeof(pa) - strlen(pa) - 1);
        snprintf(buf, sizeof(buf), "%s\"%s\"", i ? "," : "", pa);
        json += buf;
    }
    json += "]";
}

static void appendTunnelActive(std::string &json, const WallNow &now)
{
    IpTunnelServer &ts = knx.bau().getIpTunnelServer();
    IpTunnelServer::TunnelEvent act[KNX_TUNNELING + KNX_TUNNELING_DEVMGMT + 1];
    const uint8_t n = ts.activeTunnels(act, sizeof(act) / sizeof(act[0]));

    // 312 bytes is the upper bound, derived from the BUFFER CAPACITIES below rather than from what the
    // formatters happen to produce: 51 literal + ch 3 + type 11 + pa 11 + ip 15 + start 19 + dur 11 +
    // zs 31 + cs 159 + NUL. Capacities on purpose -- the bound then holds whatever a formatter writes,
    // so it cannot go stale when one of them grows. Truncation would emit invalid JSON, so a new field
    // needs this re-derived AND compared against sizeof(buf).
    char buf[320], ip[16], pa[12], start[20], dur[12], cs[160];
    for (uint8_t i = 0; i < n; i++)
    {
        formatTunIp(act[i].ip, ip, sizeof(ip));
        formatTunPa(act[i].pa, pa, sizeof(pa));
        formatStart(now, ts.secondsSince(act[i].startS), start, sizeof(start));
        formatDuration(act[i].ageS, dur, sizeof(dur));
        const uint8_t z = tunAssign(act[i].slot, act[i].resSlot);
        char zs[32] = {0};
        int zn = 0;
        if (act[i].slot != 0xFF) // which slot it occupies; device-mgmt and busmon have none
            zn = snprintf(zs, sizeof(zs), ",\"s\":%u", (unsigned)(act[i].slot + 1));
        if (z != TUN_ASSIGN_FREE && zn >= 0 && (size_t)zn < sizeof(zs))
            snprintf(zs + zn, sizeof(zs) - zn, ",\"z\":%u,\"slot\":%u", z, (unsigned)(act[i].resSlot + 1));
        appendTunCounters(cs, sizeof(cs), act[i], true);
        // ch = the KNXnet/IP channel id, the handle the disconnect button posts back. It is the same
        // handle a client uses to disconnect itself, and ids are only reused after a full 255 wrap.
        snprintf(buf, sizeof(buf), "%s{\"t\":\"%s\",\"pa\":\"%s\",\"ip\":\"%s\",\"start\":\"%s\",\"dur\":\"%s\",\"ch\":%u%s%s}",
                 i ? "," : "", tunTypeName(act[i].type), pa, ip, start, dur, (unsigned)act[i].chId, zs, cs);
        json += buf;
    }
}

static void appendTunnelHistory(std::string &json, const WallNow &now)
{
    IpTunnelServer &ts = knx.bau().getIpTunnelServer();
    // 337 bytes is the upper bound, from the BUFFER CAPACITIES below plus the longest string a
    // non-buffer argument can return: 66 literal + type 11 + pa 11 + ip 15 + start 19 + dur 11 +
    // reason 30 ("Abgelehnt: keine freie Adresse") + det 7 + cs 159 + ab 7 + NUL. Capacities, so the
    // bound cannot go stale when a formatter grows; the two branches are not added up because a reject
    // carries neither counters nor the flag. Truncation emits invalid JSON -- re-derive on any new field.
    char buf[384], ip[16], pa[12], start[20], dur[12], det[8], cs[160];
    const uint8_t hc = ts.tunnelHistoryCount();
    uint8_t emitted = 0; // NOT the loop index: a skipped row must not shift the comma and emit `[,{`
    for (uint8_t i = 0; i < hc; i++)
    {
        IpTunnelServer::TunnelEvent ev;
        // Skip, not break: a torn row is one missing entry, the rest of the list is fine.
        if (!ts.tunnelHistoryCopy(i, ev)) continue;
        const IpTunnelServer::TunnelEvent *e = &ev;
        formatTunIp(e->ip, ip, sizeof(ip));
        formatTunPa(e->pa, pa, sizeof(pa));
        formatStart(now, ts.secondsSince(e->startS), start, sizeof(start));
        formatDuration(e->ageS, dur, sizeof(dur));
        // A refusal is not a session: repeated identical refusals are folded into one entry
        // whose end keeps moving, so the span would read like a connection that lasted minutes.
        if (e->reason >= IpTunnelServer::END_REJ_TYPE) dur[0] = '\0';
        formatTunDetail(e->reason, e->detail, det, sizeof(det));
        // A refused connect never had a session: no counters at all, so the page shows dashes.
        cs[0] = '\0';
        if (e->reason < IpTunnelServer::END_REJ_TYPE) appendTunCounters(cs, sizeof(cs), *e, false);
        // A flag, not the localised reason text -- that text would break the moment it is translated.
        // INVERSE by design: named here are the endings somebody ASKED for (the client, the operator,
        // a busmonitor taking the bus); everything else in between is an anomaly by default, which is
        // how the eviction was caught. Not future-proof upwards: a reason appended AFTER the reject
        // block would render as a reject, so a new session reason belongs before END_REJ_TYPE.
        const char *ab = (e->reason > IpTunnelServer::END_ACTIVE &&
                          e->reason != IpTunnelServer::END_CLOSED &&
                          e->reason != IpTunnelServer::END_LOCAL &&
                          e->reason != IpTunnelServer::END_BUSMON &&
                          e->reason < IpTunnelServer::END_REJ_TYPE) ? ",\"ab\":1" : "";
        snprintf(buf, sizeof(buf),
                 "%s{\"t\":\"%s\",\"pa\":\"%s\",\"ip\":\"%s\",\"start\":\"%s\",\"dur\":\"%s\","
                 "\"reason\":\"%s\",\"det\":\"%s\"%s%s}",
                 emitted++ ? "," : "", tunTypeName(e->type), pa, ip, start, dur, tunReasonName(e->reason, e->detail), det, cs, ab);
        json += buf;
    }
}

// --- /ipro/state: what `ipro` and `tun` print ---------------------------------
// Raw counters; the page applies the same humanCount/humanBytes rules as the console. A value this
// build does not collect is left out entirely, so no zero can be read as a measurement.
static const std::string &buildIproJson()
{
    IpTunnelServer &ts = knx.bau().getIpTunnelServer();
    const uint16_t pa = knx.individualAddress();
    // role[96]: the longest German variant is 55 B incl. NUL ("Kein Koppler - Adresse 15.15.255 hat einen
    // Geraeteteil", the ae being two UTF-8 bytes). snprintf truncates silently, so the headroom is
    // deliberate -- a multi-byte glyph costs more than it looks on screen.
    char buf[224], role[96];
    formatCouplerRole(pa, role, sizeof(role), true); // web: German, arrow as raw UTF-8 (see the note above)

    // One buffer for all three endpoints: a request is answered and copied out before the next one
    // starts, so they are never live at the same time. clear() keeps the capacity, so after the first
    // requests the polls stop allocating. An active entry is ~95 B, a history entry up to 155 B.
    std::string &json = reportBuffer();
    json.clear();
    // Measured on a real device: an active entry is ~85 B, header plus load block ~450 B.
    json.reserve((size_t)(ts.tunnelCount() + KNX_TUNNELING_DEVMGMT + 1) * 320 + 640 + KNX_TUNNELING * 14);

    // Role as data, not as a sentence: the page needs the short form for the status bar and has to
    // know that a PA with a device part is a misconfiguration, not a role.
    const uint8_t rArea = (uint8_t)(pa >> 12), rLine = (uint8_t)((pa >> 8) & 0x0F);
    const bool rBad = (pa & 0x00FF) != 0;
    char rShort[24];
    if (rBad)
        snprintf(rShort, sizeof(rShort), "kein Koppler");
    else if (rLine == 0)
        snprintf(rShort, sizeof(rShort), "Bereichskoppler %u.0", rArea);
    else
        snprintf(rShort, sizeof(rShort), "Linienkoppler %u.%u", rArea, rLine);
    snprintf(buf, sizeof(buf),
             "{\"pa\":\"%u.%u.%u\",\"mask\":\"%04X\",\"up\":\"%s\",\"role\":\"%s\","
             "\"roleShort\":\"%s\",\"roleBad\":%s",
             (unsigned)(pa >> 12), (unsigned)((pa >> 8) & 0x0F), (unsigned)(pa & 0xFF),
             (unsigned)MASK_VERSION, humanDuration(uptime()).c_str(), role,
             rShort, rBad ? "true" : "false");
    json += buf;

    // Independent: one property read failing must not suppress the other value, and an unreadable TTL
    // is omitted rather than sent as 0 -- 0 is a legal setting (the packet never leaves the host).
    if (mcAddr[0] != '\0')
    {
        snprintf(buf, sizeof(buf), ",\"mc\":\"%s\"", mcAddr);
        json += buf;
    }
    if (mcTtlValid)
    {
        snprintf(buf, sizeof(buf), ",\"ttl\":%u", (unsigned)mcTtl);
        json += buf;
    }

    // Whether the stack has a configuration at all. Everything else on the page is downstream of this:
    // an unprogrammed device has no tunnel addresses, no group objects and the default 15.15.255.
    if (!cfgMirror) json += ",\"cfg\":0";

    if (resvIaTotal)
    {
        snprintf(buf, sizeof(buf), ",\"addIa\":{\"used\":%u,\"max\":%u}", resvIaUsed, resvIaTotal);
        json += buf;
    }

    KnxIpCounters &c = knx.bau().getCounters();
    snprintf(buf, sizeof(buf),
             ",\"rtIp\":%lu,\"rtTp\":%lu,\"flIp\":%lu,\"flTp\":%lu,\"toIp\":%lu,\"toTp\":%lu,"
             "\"lostIp\":%u,\"lostTp\":%u,\"hop0Ip\":%lu,\"hop0Tp\":%lu",
             (unsigned long)c.routedToIp(), (unsigned long)c.routedToKnx(),
             (unsigned long)c.filteredToIp(), (unsigned long)c.filteredToKnx(),
             (unsigned long)c.transmitToIp(), (unsigned long)c.transmitToKnx(),
             c.overflowToIp(), c.overflowToKnx(),
             (unsigned long)c.hopCountToIp(), (unsigned long)c.hopCountToKnx());
    json += buf;

    snprintf(buf, sizeof(buf), ",\"load\":{\"now\":%u,\"avg\":%u,\"peak\":%u,\"bps\":%u,\"hist\":[",
             openknx.busLoad.currentPermille(), openknx.busLoad.averagePermille(),
             openknx.busLoad.peakPermille(), openknx.busLoad.currentBytesPerSec());
    json += buf;
    // 60 samples, one snprintf each was the most expensive part of this document; four digits and a
    // comma are cheaper to write by hand, and this runs inside loop() on the RP2040.
    const uint8_t hn = openknx.busLoad.historyCount();
    for (uint8_t i = 0; i < hn; i++)
    {
        if (i) json += ',';
        uint16_t v = openknx.busLoad.historyAt(i);
        char d[6];
        uint8_t n = 0;
        do { d[n++] = (char)('0' + v % 10); v /= 10; } while (v);
        while (n) json += d[--n];
    }
    json += "]}";

    snprintf(buf, sizeof(buf), ",\"tun\":{\"n\":%u,\"max\":%u,\"act\":[", ts.tunnelCount(), ts.tunnelMax());
    json += buf;
    const WallNow now = wallNow();
    appendTunnelActive(json, now);
    // The history is two thirds of this document, changes only on connect/disconnect and sits behind a
    // tab that is not the default: only its count travels in the 2-second poll, the entries have their
    // own endpoint - the same split the bus block already uses.
    json += "]";
    appendTunnelReserved(json);
    appendTunnelIas(json);
    snprintf(buf, sizeof(buf), ",\"histN\":%u}}", ts.tunnelHistoryCount());
    json += buf;
    return json;
}

// --- /ipro/hist: the finished tunnel connections, fetched when their tab is opened ---
static const std::string &buildIproHistJson()
{
    IpTunnelServer &ts = knx.bau().getIpTunnelServer();
    std::string &json = reportBuffer();
    json.clear();
    json.reserve((size_t)ts.tunnelHistoryCount() * 344 + 128);
    json += "{\"hist\":[";
    appendTunnelHistory(json, wallNow());
    json += "]}";
    return json;
}

// --- /ipro/bus: the `bcu stat` block, fetched only while the section is open ---
static const std::string &buildIproBusJson()
{
    std::string &json = reportBuffer();
    auto *dll = knx.bau().getSecondaryDataLinkLayer();
    if (dll == nullptr)
    {
        json = "{}";
        return json;
    }
    auto &tp = dll->getTPUart();
    auto &st = tp.getStatistics();
    char buf[256];

    json.clear();
    json.reserve(768);
    snprintf(buf, sizeof(buf),
             "{\"state\":\"%s\",\"baud\":%d,\"tx\":%lu,\"rxF\":%lu,\"rxB\":%lu,\"disc\":%lu,\"recv\":%lu,"
             "\"bps\":%u,\"buf\":%u,\"await\":%u,\"rep\":%lu,\"ovf\":[%lu,%lu,%lu,%lu]",
             tp.getBcuStateInfo(), tp.getBaudrate(),
             (unsigned long)st.getTxFrames(), (unsigned long)st.getRxFrames(),
             (unsigned long)st.getRxFrameBytes(), (unsigned long)st.getRxDiscardedBytes(),
             (unsigned long)st.getRxReceivedBytes(), openknx.busLoad.currentBytesPerSec(),
             tp.getReceiver().getSearchBufferPosition(), tp.getReceiver().getAwaitBytes(),
             (unsigned long)st.getRxRepetitions(),
             (unsigned long)st.getRxUartOverflow(), (unsigned long)st.getRxSearchBufferOverflow(),
             (unsigned long)st.getRxFrameBufferOverflow(), (unsigned long)st.getTxOverflowFrameBuffer());
    json += buf;

#if defined(TPUART_API_LEVEL) && TPUART_API_LEVEL >= 2
    snprintf(buf, sizeof(buf), ",\"autoack\":%s,\"crc\":%s,\"ack\":%lu",
             tp.isAutoAcknowledge() ? "true" : "false", tp.isExtendedCRC() ? "true" : "false",
             (unsigned long)tp.getTransmitter().droppedAcknowledges());
    json += buf;
    #ifdef TPUART_BUSMON_INTEGRITY
    snprintf(buf, sizeof(buf), ",\"be\":[%lu,%lu,%lu,%lu]",
             (unsigned long)st.getRxByteFraming(), (unsigned long)st.getRxByteParity(),
             (unsigned long)st.getRxByteBreak(), (unsigned long)st.getRxByteOverrun());
    json += buf;
    #endif
#endif

#ifdef TPUART_BCU_HEALTH
    snprintf(buf, sizeof(buf),
             ",\"health\":{\"rst\":%lu,\"dis\":%lu,\"con\":%lu,\"sc\":%lu,\"re\":%lu,\"te\":%lu,"
             "\"pe\":%lu,\"tw\":%lu}",
             (unsigned long)st.getBcuResets(), (unsigned long)st.getBcuDisconnects(),
             (unsigned long)st.getBcuConRescues(), (unsigned long)st.getBcuSlaveCollisions(),
             (unsigned long)st.getBcuReceiveErrors(), (unsigned long)st.getBcuTransmitErrors(),
             (unsigned long)st.getBcuProtocolErrors(), (unsigned long)st.getBcuTempWarnings());
    json += buf;
#endif

#ifdef TPUART_BCU_REGISTER_INFO
    if (tp.getBcuType() == TPUart::BCU_NCN5120)
    {
        auto &ss = tp.getSystemState();
        // The rails are only polled outside monitor mode; a stale reading must not look like a
        // measurement. This product has no ETS busmonitor, but `bcu mon` on the console does it too.
        snprintf(buf, sizeof(buf),
                 ",\"rails\":{\"seen\":%s,\"stale\":%s,\"since\":\"\",\"vbus\":%s,\"vfilt\":%s,"
                 "\"v20v\":%s,\"vdd2\":%s,\"xtal\":%s,\"mode\":\"%s\"}",
                 ss.seen() ? "true" : "false", tp.isMonitoring() ? "true" : "false",
                 ss.vbus() ? "true" : "false", ss.vfilt() ? "true" : "false",
                 ss.v20v() ? "true" : "false", ss.vdd2() ? "true" : "false",
                 ss.xtal() ? "true" : "false", ss.modeString());
        json += buf;

    #if TPUART_API_LEVEL >= 3
        // The driver owns the identification: "unknown" is a real outcome and a chip concluded from an
        // absent RevID register is flagged. ASR0 has its own validity - "no thermal shutdown" about a
        // register that never answered would be a false claim.
        if (tp.ncnRegValid())
        {
            const bool named = !(tp.getNcnChip() == TPUart::NCN_CHIP_UNKNOWN && tp.getNcnRevId());
            const bool hasRev = (tp.getNcnChip() == TPUart::NCN_CHIP_5130 || tp.getNcnChip() == TPUart::NCN_CHIP_5121);
            char rev[8];
            if (hasRev)
                snprintf(rev, sizeof(rev), "%u", (unsigned)((tp.getNcnRevId() >> 5) & 0x07));
            else
                snprintf(rev, sizeof(rev), "null");
            if (named)
                snprintf(buf, sizeof(buf), ",\"chip\":{\"name\":\"%s\",\"inferred\":%s,\"rev\":%s,\"tsd\":%s}",
                         tp.getNcnChipName(), tp.ncnChipInferred() ? "true" : "false", rev,
                         tp.ncnAsr0Valid() ? ((tp.getNcnAsr0() & ASR0_TSD) ? "true" : "false") : "null");
            else
                snprintf(buf, sizeof(buf), ",\"chip\":{\"name\":null,\"revId\":%u,\"rev\":null,\"tsd\":%s}",
                         (unsigned)tp.getNcnRevId(),
                         tp.ncnAsr0Valid() ? ((tp.getNcnAsr0() & ASR0_TSD) ? "true" : "false") : "null");
            json += buf;
        }
    #endif
    }
#endif

    json += "}";
    return json;
}

#ifdef OPENKNX_ROUTE_TRACE
// --- /ipro/route: the routing decisions, the per-address counts and the filter table -------------
// Only fetched while the Routing section is open.
static const char *decisionName(uint8_t flags)
{
    switch (flags & 0x07)
    {
        case RouteTrace::FILTERED: return "gefiltert";
        case RouteTrace::HOPCOUNT: return "Hop-Count 0";
        case RouteTrace::PHYS_LOCKED: return "physikalisch gesperrt";
        case RouteTrace::PHYS_NOT_ROUTED: return "nicht geroutet";
        default: return "weitergeleitet";
    }
}

// Filter table as ranges: 8 kB of bits would be unreadable as single addresses, and consecutive
// addresses are the normal case. Scanned in slices because one pass measured ~22 ms on the RP2040 -
// a quarter of the loop-time warning, every two seconds while the tab is open.
void IPRouterModule::filterTableLoop()
{
    const uint8_t *ft = _filtPtr; // pointer and size are checked in loop() before we get here
    const uint32_t size = _filtSize;
    if (size == 0) return;

    if (!_filtBuilding)
    {
        if (_filtBuf == nullptr)
        {
            _filtBuf = new (std::nothrow) char[FILT_BUF];
            if (_filtBuf == nullptr) return; // no view rather than a failed allocation
        }
        _filtBuilding = true;
        _filtGa = 1; // 0/0/0 is broadcast, never in the table
        _filtFirst = _filtCount = 0;
        _filtRanges = 0;
        _filtLen = 0;
        _filtOpen = false;
        markUnstable();
        static const char head[] = "\"ranges\":[";
        putFilt(head, (int)(sizeof(head) - 1)); // length from the literal, never counted by hand
    }

    char buf[64], a[12], b[12];
    auto closeRange = [&](uint32_t last) {
        if (_filtRanges < MAX_FILT_RANGES)
        {
            formatGa((uint16_t)_filtFirst, a, sizeof(a));
            formatGa((uint16_t)last, b, sizeof(b));
            const int n = (_filtFirst == last)
                              ? snprintf(buf, sizeof(buf), "%s\"%s\"", _filtRanges ? "," : "", a)
                              : snprintf(buf, sizeof(buf), "%s\"%s - %s\"", _filtRanges ? "," : "", a, b);
            putFilt(buf, n);
        }
        _filtRanges++;
        _filtOpen = false;
    };

    // One slice per loop pass, and only while there is time left. 2048 addresses are ~0.7 ms.
    const uint32_t lastGa = (size * 8 > 0x10000) ? 0xFFFF : (size * 8 - 1);
    const uint32_t end = (_filtGa + FILT_SLICE > lastGa) ? lastGa : (_filtGa + FILT_SLICE);
    for (uint32_t ga = _filtGa; ga <= end; ga++)
    {
        if ((ga & 0x07) == 0 && ft[ga >> 3] == 0) // whole octet clear -> skip its eight addresses
        {
            if (_filtOpen) closeRange(ga - 1);
            ga += 7;
            continue;
        }
        const bool set = (ft[ga >> 3] & (1 << (ga & 0x07))) != 0;
        if (set)
        {
            _filtCount++;
            if (!_filtOpen)
            {
                _filtFirst = ga;
                _filtOpen = true;
            }
        }
        else if (_filtOpen)
            closeRange(ga - 1);
    }

    if (end >= lastGa)
    {
        if (_filtOpen) closeRange(lastGa); // a range open at the last address would otherwise vanish
        const int n = snprintf(buf, sizeof(buf), "],\"count\":%lu,\"ranges_total\":%u",
                               (unsigned long)_filtCount, _filtRanges);
        putFilt(buf, n);
        _filtBuilding = false;
        _filtValid = true;
        _filtSeq.fetch_add(1, std::memory_order_release); // even again: the buffer is readable
    }
    else
        _filtGa = end + 1;
}

// A request never scans: it asks for the table and takes whatever is ready.
void IPRouterModule::appendFilterTableJson(std::string &json)
{
    _filtWanted = true;
    RouterObject &ro = knx.bau().getRouterObject();
    if (ro.filterTableData() == nullptr || ro.filterTableSize() == 0)
    {
        json += ",\"filt\":{\"loaded\":false}";
        return;
    }

    // inUse is read live, never cached: a management client can switch filtering off with a property
    // write that leaves the table itself untouched, so a stored flag would contradict the router.
    char buf[64];
    snprintf(buf, sizeof(buf), ",\"filt\":{\"loaded\":true,\"inUse\":%s,",
             ro.filterTableInUse() ? "true" : "false");
    json += buf;

    const size_t mark = json.size();
    const uint32_t seq = _filtSeq.load(std::memory_order_acquire);
    if ((seq & 1) == 0 && _filtBuf != nullptr && _filtLen != 0)
    {
        json.append(_filtBuf, _filtLen);
        if (_filtSeq.load(std::memory_order_acquire) == seq)
        {
            json += "}";
            return;
        }
        json.resize(mark); // the loop began a rebuild while we copied - drop it and report progress
    }

    const uint32_t total = (_filtSize * 8 > 0x10000) ? 0x10000 : _filtSize * 8;
    snprintf(buf, sizeof(buf), "\"building\":%u}",
             (unsigned)((_filtBuilding && total) ? (_filtGa * 100 / total) : 0));
    json += buf;
}

static const std::string &buildIproRouteJson(bool withFilter)
{
    RouteTrace &rt = knx.bau().getRouteTrace();
    std::string &json = reportBuffer();
    json.clear();
    // The filter-table fragment is worth reserving only when it is actually asked for. This buffer is
    // shared and keeps its high-water mark, so the reserve follows the measured worst case, not a guess.
    json.reserve(RouteTrace::TRACE_SIZE * 128 + RouteTrace::TOP_SIZE * 2 * 48 + (withFilter ? 1600u : 256u));

    // 192: a trace entry is 124 chars at its maxima; truncation would emit invalid JSON.
    char buf[192], ga[12], src[12], start[20];
    const WallNow now = wallNow();
    json += "{\"trace\":[";
    const uint8_t n = rt.traceCount();
    for (uint8_t i = 0; i < n; i++)
    {
        RouteTrace::Entry e;
        if (!rt.traceAt(i, e)) break;
        const bool group = (e.flags & 0x10) != 0;
        if (group)
            formatGa(e.dst, ga, sizeof(ga));
        else
            formatTunPa(e.dst, ga, sizeof(ga));
        formatTunPa(e.src, src, sizeof(src));
        formatStart(now, (uint32_t)((millis() - e.at) / 1000), start, sizeof(start)); // trace stamps are millis()
        snprintf(buf, sizeof(buf),
                 "%s{\"t\":\"%s\",\"toIp\":%s,\"grp\":%s,\"hop\":%u,\"dst\":\"%s\",\"src\":\"%s\",\"act\":\"%s\"}",
                 i ? "," : "", start, (e.flags & 0x08) ? "true" : "false", group ? "true" : "false",
                 (unsigned)((e.flags >> 5) & 0x07), ga, src, decisionName(e.flags));
        json += buf;
    }
    snprintf(buf, sizeof(buf), "],\"size\":%u", (unsigned)RouteTrace::TRACE_SIZE);
    json += buf;

    // The two long-running tables, sorted here: 16 entries make a selection sort cheaper than any
    // ordering kept on the routing path.
    for (uint8_t pass = 0; pass < 2; pass++)
    {
        // pass 0 is the filtered table -- topAt(true) is the filtered one.
        const bool filtered = (pass == 0);
        json += filtered ? ",\"topF\":[" : ",\"topR\":[";
        bool used[RouteTrace::TOP_SIZE] = {};
        uint8_t written = 0;
        for (uint8_t k = 0; k < RouteTrace::TOP_SIZE; k++)
        {
            RouteTrace::Top best = {};
            uint8_t bestIdx = 0;
            bool found = false;
            for (uint8_t i = 0; i < RouteTrace::TOP_SIZE; i++)
            {
                RouteTrace::Top t;
                if (used[i] || !rt.topAt(filtered, i, t)) continue;
                if (!found || t.count > best.count)
                {
                    best = t;
                    bestIdx = i;
                    found = true;
                }
            }
            if (!found) break;
            used[bestIdx] = true;
            formatGa(best.ga, ga, sizeof(ga));
            snprintf(buf, sizeof(buf), "%s{\"ga\":\"%s\",\"toIp\":%s,\"n\":%lu}",
                     written ? "," : "", ga, best.toIp ? "true" : "false", (unsigned long)best.count);
            json += buf;
            written++;
        }
        json += "]";
    }
    formatStart(now, (uint32_t)((millis() - rt.topSince()) / 1000), start, sizeof(start)); // millis()
    snprintf(buf, sizeof(buf), ",\"since\":\"%s\"", start);
    json += buf;

    if (withFilter) openknxIPRouterModule.appendFilterTableJson(json); // ready-made, never scans here
    json += "}";
    return json;
}
#endif // OPENKNX_ROUTE_TRACE

// Page shell only: the markup lives in the gzipped asset, where the same bytes cost about a third
// of what they take as an uncompressed C string in flash. The script fills it before its first poll.
static const char iproPage[] = "<div id='ii-root'></div>";
#endif // IPRO_HAS_WEBPAGE

// Performs what the web task parked. Runs in the KNX loop, so the teardown cannot race the stack.
void IPRouterModule::runPendingCloses()
{
    const uint8_t ch = _closeCh.exchange(0, std::memory_order_acquire);
    if (ch == 0)
        return;

    // Decimal, like the page and the JSON -- the operator clicks channel 12 and must find "12" here.
    // The slot is freed either way; `sent` says whether the client could still be told, which is the
    // one part that can fail silently on an unreachable client.
    bool sent = false;
    if (knx.bau().getIpTunnelServer().closeTunnel(ch, IpTunnelServer::END_LOCAL, &sent))
        logInfoP("close channel %u on request: closed%s", (unsigned)ch, sent ? "" : ", client not reachable");
    else
        logInfoP("close channel %u on request: no such channel", (unsigned)ch);
}

// A restart tears the sockets down without a word, leaving every client to find out via its own 120 s
// heartbeat timeout. One DISCONNECT_REQUEST each costs nothing and lets ETS reconnect at once.
void IPRouterModule::processBeforeRestart()
{
    uint8_t told = 0;
    const uint8_t n = knx.bau().getIpTunnelServer().closeAllTunnels(IpTunnelServer::END_LOCAL, true, &told);
    if (n)
        logInfoP("restart: %u connection(s) closed, %u client(s) told", (unsigned)n, (unsigned)told);
}

void IPRouterModule::loop(bool configured)
{
    (void)configured;

    // Cheap gate: one relaxed load in the steady state (an inlined ldrb), the locked exchange only
    // when something is actually parked.
    if (_closeCh.load(std::memory_order_relaxed) != 0)
        runPendingCloses();

    // The reservation table changes only on an ETS download; mirroring it every few seconds keeps the
    // web handler off the property heap without costing anything in the hot loop.
    if (resvAt == 0 || (uint32_t)(millis() - resvAt) >= 5000)
    {
        resvAt = millis();
        refreshReserved();
        refreshIas();
    }
#ifdef OPENKNX_ROUTE_TRACE
    // Two pointer comparisons every pass so a download is never missed, the scan only when
    // there is time left. During LS_LOADING the table reads as nullptr, which is the signal.
    RouterObject &ro = knx.bau().getRouterObject();
    const uint8_t *ft = ro.filterTableData();
    const uint32_t size = ro.filterTableSize();
    if (ft != _filtPtr || size != _filtSize)
    {
        _filtPtr = ft;
        _filtSize = size;
        _filtValid = _filtBuilding = false;
        _filtGa = _filtLen = 0; // else the next request reports the progress of the previous scan
        markUnstable();
    }
    if (_filtWanted && !_filtValid && ft != nullptr && openknx.common.freeLoopTime()) filterTableLoop();
#endif
}

void IPRouterModule::setup(bool configured)
{
#ifdef IPRO_HAS_WEBPAGE
    // Route/menu/asset lists are read at request time and never cleared, so registering here - long
    // before the webserver starts - is fine (see OFM-Network/README.Webserver.md).
    // The tunnel list is section 3 of /ipro; the separate /tunnels page and its script are gone.
    openknxNetwork.webserver.addMenuItem("IP-Router", "/ipro", 104);
    openknxNetwork.webserver.addRoute(
        WEB_GET, "/assets/ipro.css",
        Webserver::Asset(WebAssets::ipro_css_mime, WebAssets::ipro_css_gz, sizeof(WebAssets::ipro_css_gz)));
    openknxNetwork.webserver.addRoute(
        WEB_GET, "/assets/ipro.js",
        Webserver::Asset(WebAssets::ipro_js_mime, WebAssets::ipro_js_gz, sizeof(WebAssets::ipro_js_gz)));
    openknxNetwork.webserver.addStylesheet("/assets/ipro.css");
    openknxNetwork.webserver.addJavaScript("/assets/ipro.js");

    openknxNetwork.webserver.addRoute(WEB_GET, "/ipro", [](WebRequest &, WebResponse &res) {
        res.setContentType("text/html");
        res.setLayout(true);
        res.sendStatic(iproPage);
    });
    openknxNetwork.webserver.addRoute(WEB_GET, "/ipro/state", [](WebRequest &, WebResponse &res) {
        res.setContentType("application/json");
        res.send(buildIproJson().c_str());
    });
    openknxNetwork.webserver.addRoute(WEB_GET, "/ipro/hist", [](WebRequest &, WebResponse &res) {
        res.setContentType("application/json");
        res.send(buildIproHistJson().c_str());
    });
    // Own endpoint: the bus block is the expensive part and the section is closed by default.
    openknxNetwork.webserver.addRoute(WEB_GET, "/ipro/bus", [](WebRequest &, WebResponse &res) {
        res.setContentType("application/json");
        res.send(buildIproBusJson().c_str());
    });
#ifdef OPENKNX_ROUTE_TRACE
    openknxNetwork.webserver.addRoute(WEB_GET, "/ipro/route", [](WebRequest &req, WebResponse &res) {
        res.setContentType("application/json");
        res.send(buildIproRouteJson(!req.getQueryParam("filt").empty()).c_str());
    });
#endif
    // Ends ONE connection. 202: parked, not done -- the row leaving the next poll is the confirmation.
    // Deliberately no "close all" here: the page has no button for it, and an unauthenticated endpoint
    // that drops every ETS connection at once is not worth having for a caller that does not exist.
    openknxNetwork.webserver.addRoute(WEB_POST, "/ipro/close", [](WebRequest &req, WebResponse &res) {
        // Digits only. strtol would also take " 12" and "+7" (and the query decoder turns '+' into a
        // space), which no caller sends and this endpoint has no reason to understand.
        const std::string ch = req.getQueryParam("ch");
        const bool numeric = !ch.empty() && ch.size() <= 3 &&
                             ch.find_first_not_of("0123456789") == std::string::npos;
        const unsigned v = numeric ? (unsigned)strtoul(ch.c_str(), nullptr, 10) : 0;
        IPRouterModule *m = IPRouterModule::instance();
        uint16_t code = 202;
        const char *body = "{\"q\":1}";
        if (v < 1 || v > 255) { code = 400; body = "{\"e\":\"bad channel\"}"; }
        else if (m == nullptr) { code = 500; body = "{\"e\":\"no module\"}"; }
        // A parked request must not be overwritten, so a second one is refused instead of being
        // answered "accepted" and then dropped.
        else if (!m->requestTunnelClose((uint8_t)v)) { code = 409; body = "{\"e\":\"eine Trennung ist noch offen\"}"; }
        res.setStatus(code);
        res.setContentType("application/json");
        res.sendStatic(body);
    });
    // Same effect as the `ipro reset` console command.
    openknxNetwork.webserver.addRoute(WEB_POST, "/ipro/reset", [](WebRequest &, WebResponse &res) {
        openknx.busLoad.reset();
#ifdef OPENKNX_ROUTE_TRACE
        knx.bau().getRouteTrace().resetTop();
#endif
        res.setContentType("application/json");
        res.sendStatic("{}");
    });
#else
    (void)configured;
#endif
}

IPRouterModule openknxIPRouterModule;
