#include "IPRouterModule.h"
#include <time.h>

// Tunnel status page. Same double guard as every module-contributed page: NetworkModule.h wraps its
// whole content in KNX_IP_*, so __has_include alone would resolve to an empty header. The router does
// not build a webserver today, so this compiles away - it activates by itself once one is enabled.
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
#endif
        case IpTunnelServer::END_CLOSED: return "Closed";
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
static void formatStart(const WallNow &now, unsigned long startMillis, char *b, size_t n)
{
    const uint32_t agoSec = (uint32_t)((millis() - startMillis) / 1000);
    if (now.valid)
    {
        time_t startEpoch = now.epoch - (time_t)agoSec;
        struct tm st;
        localtime_r(&startEpoch, &st);
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
static void formatCouplerRole(uint16_t pa, char *buf, size_t len)
{
    const uint8_t area = (uint8_t)(pa >> 12);
    const uint8_t line = (uint8_t)((pa >> 8) & 0x0F);
    if ((pa & 0x00FF) != 0)
        snprintf(buf, len, "NO ROUTER - address %u.%u.%u has a device part", area, line, (unsigned)(pa & 0xFF));
    else if (line == 0)
        snprintf(buf, len, "Backbone coupler   IP <-> main line %u.0", area);
    else
        snprintf(buf, len, "Line coupler       IP <-> line %u.%u", area, line);
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
        if (ts.busMonitorActive())
            logInfoP("  ** HW BUSMONITOR ACTIVE - bus TX paused, tunnel connects rejected **");
#endif
        refreshReserved(); // console runs on the KNX loop, so the mirror can be taken right here
        char ip[16], pa[12], start[20], dur[12], zs[28];
        const WallNow now = wallNow();
        for (uint8_t i = 0; i < n; i++)
        {
            formatTunIp(act[i].ip, ip, sizeof(ip));
            formatTunPa(act[i].pa, pa, sizeof(pa));
            formatStart(now, act[i].startMillis, start, sizeof(start));
            formatDuration((uint32_t)((millis() - act[i].startMillis) / 1000), dur, sizeof(dur));
            const uint8_t z = tunAssign(act[i].slot, act[i].resSlot);
            if (z == TUN_ASSIGN_FIXED)
                snprintf(zs, sizeof(zs), "  fixed T%u", (unsigned)(act[i].resSlot + 1));
            else if (z == TUN_ASSIGN_FALLBACK)
                snprintf(zs, sizeof(zs), "  fallback, T%u reserved", (unsigned)(act[i].resSlot + 1));
            else
                zs[0] = 0;
            logInfoP("  %-11s %-8s %-15s  %-18s up %s%s", tunTypeName(act[i].type), pa, ip, start, dur, zs);
        }
        if (resvAny)
        {
            for (uint8_t i = 0; i < KNX_TUNNELING; i++)
            {
                if ((resvCtrl[i] & 0x80) == 0) continue;
                formatTunIp(reservedIpAt(resvIp, i), ip, sizeof(ip));
                logInfoP("  reserved: T%-2u %s", i + 1, ip);
            }
        }

        const uint8_t hc = ts.tunnelHistoryCount();
        if (hc)
        {
            logInfoP("History (last %u):", hc);
            for (uint8_t i = 0; i < hc; i++)
            {
                const IpTunnelServer::TunnelEvent *e = ts.tunnelHistoryAt(i);
                if (e == nullptr)
                    break;
                formatTunIp(e->ip, ip, sizeof(ip));
                formatTunPa(e->pa, pa, sizeof(pa));
                formatStart(now, e->startMillis, start, sizeof(start));
                formatDuration((uint32_t)((e->endMillis - e->startMillis) / 1000), dur, sizeof(dur));
        // A refusal is not a session: repeated identical refusals are folded into one entry
        // whose end keeps moving, so the span would read like a connection that lasted minutes.
        if (e->reason >= IpTunnelServer::END_REJ_TYPE) dur[0] = '\0';
                // A refusal is not a session: repeated identical refusals are folded into one entry
                // whose end keeps moving, so the span would read like a connection that lasted minutes.
                if (e->reason >= IpTunnelServer::END_REJ_TYPE) dur[0] = '\0';
                char det[8];
                formatTunDetail(e->reason, e->detail, det, sizeof(det));
                logInfoP("  %-11s %-8s %-15s  %-18s %-8s %s %s", tunTypeName(e->type), pa, ip, start, dur,
                         tunReasonName(e->reason, e->detail), det);
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

static void appendTunnelActive(std::string &json, const WallNow &now)
{
    IpTunnelServer &ts = knx.bau().getIpTunnelServer();
    IpTunnelServer::TunnelEvent act[KNX_TUNNELING + KNX_TUNNELING_DEVMGMT + 1];
    const uint8_t n = ts.activeTunnels(act, sizeof(act) / sizeof(act[0]));

    // 160: a history entry is 148 chars with its separator, 155 with every field at its buffer
    // maximum. Truncation here would emit invalid JSON, so any new field needs this recomputed.
    // 136 bytes is the upper bound from the field capacities (11+11+15+19+11 plus the fixed text and
    // the 23-byte slot/assignment tail); truncation would emit invalid JSON, so a new field needs
    // this re-derived.
    char buf[160], ip[16], pa[12], start[20], dur[12];
    for (uint8_t i = 0; i < n; i++)
    {
        formatTunIp(act[i].ip, ip, sizeof(ip));
        formatTunPa(act[i].pa, pa, sizeof(pa));
        formatStart(now, act[i].startMillis, start, sizeof(start));
        formatDuration((uint32_t)((millis() - act[i].startMillis) / 1000), dur, sizeof(dur));
        const uint8_t z = tunAssign(act[i].slot, act[i].resSlot);
        char zs[32] = {0};
        int zn = 0;
        if (act[i].slot != 0xFF) // which slot it occupies; device-mgmt and busmon have none
            zn = snprintf(zs, sizeof(zs), ",\"s\":%u", (unsigned)(act[i].slot + 1));
        if (z != TUN_ASSIGN_FREE && zn >= 0 && (size_t)zn < sizeof(zs))
            snprintf(zs + zn, sizeof(zs) - zn, ",\"z\":%u,\"slot\":%u", z, (unsigned)(act[i].resSlot + 1));
        snprintf(buf, sizeof(buf), "%s{\"t\":\"%s\",\"pa\":\"%s\",\"ip\":\"%s\",\"start\":\"%s\",\"dur\":\"%s\"%s}",
                 i ? "," : "", tunTypeName(act[i].type), pa, ip, start, dur, zs);
        json += buf;
    }
}

static void appendTunnelHistory(std::string &json, const WallNow &now)
{
    IpTunnelServer &ts = knx.bau().getIpTunnelServer();
    // 171 bytes is the upper bound: fixed text plus the field capacities and the longest reason.
    char buf[192], ip[16], pa[12], start[20], dur[12], det[8];
    const uint8_t hc = ts.tunnelHistoryCount();
    for (uint8_t i = 0; i < hc; i++)
    {
        const IpTunnelServer::TunnelEvent *e = ts.tunnelHistoryAt(i);
        if (e == nullptr) break;
        formatTunIp(e->ip, ip, sizeof(ip));
        formatTunPa(e->pa, pa, sizeof(pa));
        formatStart(now, e->startMillis, start, sizeof(start));
        formatDuration((uint32_t)((e->endMillis - e->startMillis) / 1000), dur, sizeof(dur));
        formatTunDetail(e->reason, e->detail, det, sizeof(det));
        snprintf(buf, sizeof(buf),
                 "%s{\"t\":\"%s\",\"pa\":\"%s\",\"ip\":\"%s\",\"start\":\"%s\",\"dur\":\"%s\","
                 "\"reason\":\"%s\",\"det\":\"%s\"}",
                 i ? "," : "", tunTypeName(e->type), pa, ip, start, dur, tunReasonName(e->reason, e->detail), det);
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
    char buf[224], role[64];
    formatCouplerRole(pa, role, sizeof(role));

    // One buffer for all three endpoints: a request is answered and copied out before the next one
    // starts, so they are never live at the same time. clear() keeps the capacity, so after the first
    // requests the polls stop allocating. An active entry is ~95 B, a history entry up to 155 B.
    std::string &json = reportBuffer();
    json.clear();
    // Measured on a real device: an active entry is ~85 B, header plus load block ~450 B.
    json.reserve((size_t)(ts.tunnelCount() + KNX_TUNNELING_DEVMGMT + 1) * 96 + 640);

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

    uint8_t *pv = nullptr;
    uint32_t plen = 0;
    uint8_t cnt = 1;
    knx.bau().propertyValueRead(OT_IP_PARAMETER, 0, PID_ROUTING_MULTICAST_ADDRESS, cnt, 1, &pv, plen);
    if (pv != nullptr && cnt > 0 && plen >= 4)
    {
        snprintf(buf, sizeof(buf), ",\"mc\":\"%u.%u.%u.%u\"", pv[0], pv[1], pv[2], pv[3]);
        json += buf;
    }
    delete[] pv;

    pv = nullptr;
    plen = 0;
    cnt = 1;
    knx.bau().propertyValueRead(OT_IP_PARAMETER, 0, PID_TTL, cnt, 1, &pv, plen);
    if (pv != nullptr && cnt > 0 && plen >= 1)
    {
        snprintf(buf, sizeof(buf), ",\"ttl\":%u", pv[0]);
        json += buf;
    }
    delete[] pv;

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
    json.reserve((size_t)ts.tunnelHistoryCount() * 128 + 128);
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
        formatStart(now, e.at, start, sizeof(start));
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
    formatStart(now, rt.topSince(), start, sizeof(start));
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

void IPRouterModule::loop(bool configured)
{
    (void)configured;

    // The reservation table changes only on an ETS download; mirroring it every few seconds keeps the
    // web handler off the property heap without costing anything in the hot loop.
    if (resvAt == 0 || (uint32_t)(millis() - resvAt) >= 5000)
    {
        resvAt = millis();
        refreshReserved();
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
