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
        case IpTunnelServer::TUN_BUSMON: return "Busmonitor";
        case IpTunnelServer::TUN_CONFIG: return "Device-Mgmt";
        case IpTunnelServer::TUN_OTHER: return "unbekannt";
        default: return "Tunnel";
    }
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
static const char *tunReasonName(uint8_t r)
{
    switch (r)
    {
        case IpTunnelServer::END_TIMEOUT: return "Timeout";
        case IpTunnelServer::END_BUSMON: return "Busmon";
        case IpTunnelServer::END_CLOSED: return "Closed";
        case IpTunnelServer::END_REJ_TYPE: return "Abgelehnt: Typ";
        case IpTunnelServer::END_REJ_LAYER: return "Abgelehnt: Layer";
        case IpTunnelServer::END_REJ_BUSY: return "Abgelehnt: belegt";
        default: return "active";
    }
}
// Refused attempts carry the offending CRI type / KNX layer octet; "" for a normal session.
static void formatTunDetail(uint8_t reason, uint8_t detail, char *b, size_t n)
{
    if (reason == IpTunnelServer::END_REJ_TYPE || reason == IpTunnelServer::END_REJ_LAYER)
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
// Session start: absolute HH:MM:SS when the clock is valid (recomputed from now - elapsed, so it is
// correct even if the clock only became valid AFTER the session started), else relative "vor <ago>".
static void formatStart(unsigned long startMillis, char *b, size_t n)
{
    const uint32_t agoSec = (uint32_t)((millis() - startMillis) / 1000);
    if (openknx.time.isValid())
    {
        auto dt = openknx.time.getLocalTime();
        struct tm t = {};
        t.tm_year = dt.year - 1900;
        t.tm_mon = dt.month - 1;
        t.tm_mday = dt.day;
        t.tm_hour = dt.hour;
        t.tm_min = dt.minute;
        t.tm_sec = dt.second;
        time_t startEpoch = mktime(&t) - (time_t)agoSec;
        struct tm st;
        localtime_r(&startEpoch, &st);
        // mktime() normalised t, so tm_yday/tm_year are valid for "today". Same day -> time only;
        // anything older gets the date, otherwise a session from last week reads like this afternoon.
        if (st.tm_yday == t.tm_yday && st.tm_year == t.tm_year)
            strftime(b, n, "%H:%M:%S", &st);
        else
            strftime(b, n, "%d.%m. %H:%M", &st);
    }
    else
    {
        // No wall clock: stamp on the UPTIME scale instead of "vor <ago>". For an active session the
        // relative form just repeated the Dauer column ("Seit vor 55s" next to "Dauer 55s"); the uptime
        // at connect is a real point in time and stays comparable between entries.
        snprintf(b, n, "Up %s", humanDuration(uptime() > agoSec ? uptime() - agoSec : 0).c_str());
    }
}

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
            knx.bau().propertyValueWrite(OT_DEVICE, 0, PID_MAX_APDU_LENGTH, NoOfElem, 1, data, 0);
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
            knx.bau().propertyValueWrite(OT_ROUTER, 0, PID_MAX_APDU_LENGTH_ROUTER, NoOfElem, 1, data, 0);
            openknx.logger.logWithPrefixAndValues("Set APDU", "PID_MAX_APDU_LENGTH_ROUTER set to %i", apdu);
            return true;
        }
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
        char ip[16], pa[12], start[20], dur[12];
        for (uint8_t i = 0; i < n; i++)
        {
            formatTunIp(act[i].ip, ip, sizeof(ip));
            formatTunPa(act[i].pa, pa, sizeof(pa));
            formatStart(act[i].startMillis, start, sizeof(start));
            formatDuration((uint32_t)((millis() - act[i].startMillis) / 1000), dur, sizeof(dur));
            logInfoP("  %-11s %-8s %-15s  %-18s up %s", tunTypeName(act[i].type), pa, ip, start, dur);
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
                formatStart(e->startMillis, start, sizeof(start));
                formatDuration((uint32_t)((e->endMillis - e->startMillis) / 1000), dur, sizeof(dur));
                char det[8];
                formatTunDetail(e->reason, e->detail, det, sizeof(det));
                logInfoP("  %-11s %-8s %-15s  %-18s %-17s %s", tunTypeName(e->type), pa, ip, start, dur,
                         tunReasonName(e->reason), det);
            }
        }
        return true;
    }
#endif // KNX_TUNNELING

    return false;
}

void IPRouterModule::showHelp()
{
#ifdef KNX_TUNNELING
    openknx.console.printHelpLine("tun", "Tunnel list (active + type) and last-32 connect/disconnect history");
#endif
}

#ifdef IPRO_HAS_WEBPAGE
using namespace OpenKNX::Network;

// Page skeleton; the two panels are filled by tunnels.js. "Aktiv" is the default tab.
static const char tunPage[] =
    "<h1>Tunnel <span id='tn-head' class='gray' style='font-size:.6em;font-weight:normal'>&hellip;</span></h1>"
    "<div class='tn-tabs'>"
    "<a class='tn-tab active' data-t='a'>Aktiv</a>"
    "<a class='tn-tab' id='tn-tab-h' data-t='h'>Historie</a>"
    "</div>"
    "<div id='tn-p-a'><div id='tn-active'></div></div>"
    "<div id='tn-p-h' hidden><div id='tn-hist'></div></div>";

// Same formatters as the `tun` console command above, so both views can never disagree. Counts come
// from the server - nothing here assumes a fixed number of tunnels.
static std::string buildTunnelJson()
{
    IpTunnelServer &ts = knx.bau().getIpTunnelServer();
    IpTunnelServer::TunnelEvent act[KNX_TUNNELING + KNX_TUNNELING_DEVMGMT + 1];
    const uint8_t n = ts.activeTunnels(act, sizeof(act) / sizeof(act[0]));

    // 160: the longest history entry is 120 chars (all six fields at their buffer maxima); the margin
    // keeps a future field from silently truncating an entry into invalid JSON.
    char buf[160], ip[16], pa[12], start[20], dur[12];
    snprintf(buf, sizeof(buf), "{\"max\":%u,\"busmon\":%s,\"active\":[", (unsigned)ts.tunnelMax(),
#ifdef OPENKNX_HW_BUSMON
             ts.busMonitorActive() ? "true" : "false"
#else
             "false"
#endif
    );
    std::string json(buf);
    // Size it up front from the real counts (worst case ~120 B per entry). Growing a std::string in
    // 3-second polls is the fragmentation risk on RP2040, not the peak itself.
    json.reserve((size_t)(n + ts.tunnelHistoryCount()) * 128 + 96);

    for (uint8_t i = 0; i < n; i++)
    {
        formatTunIp(act[i].ip, ip, sizeof(ip));
        formatTunPa(act[i].pa, pa, sizeof(pa));
        formatStart(act[i].startMillis, start, sizeof(start));
        formatDuration((uint32_t)((millis() - act[i].startMillis) / 1000), dur, sizeof(dur));
        snprintf(buf, sizeof(buf), "%s{\"t\":\"%s\",\"pa\":\"%s\",\"ip\":\"%s\",\"start\":\"%s\",\"dur\":\"%s\"}",
                 i ? "," : "", tunTypeName(act[i].type), pa, ip, start, dur);
        json += buf;
    }

    json += "],\"hist\":[";
    const uint8_t hc = ts.tunnelHistoryCount();
    for (uint8_t i = 0; i < hc; i++)
    {
        const IpTunnelServer::TunnelEvent *e = ts.tunnelHistoryAt(i);
        if (e == nullptr) break;
        formatTunIp(e->ip, ip, sizeof(ip));
        formatTunPa(e->pa, pa, sizeof(pa));
        formatStart(e->startMillis, start, sizeof(start));
        formatDuration((uint32_t)((e->endMillis - e->startMillis) / 1000), dur, sizeof(dur));
        char det[8];
        formatTunDetail(e->reason, e->detail, det, sizeof(det));
        snprintf(buf, sizeof(buf),
                 "%s{\"t\":\"%s\",\"pa\":\"%s\",\"ip\":\"%s\",\"start\":\"%s\",\"dur\":\"%s\","
                 "\"reason\":\"%s\",\"det\":\"%s\"}",
                 i ? "," : "", tunTypeName(e->type), pa, ip, start, dur, tunReasonName(e->reason), det);
        json += buf;
    }
    json += "]}";
    return json;
}
#endif // IPRO_HAS_WEBPAGE

void IPRouterModule::setup(bool configured)
{
#ifdef IPRO_HAS_WEBPAGE
    // Route/menu/asset lists are read at request time and never cleared, so registering here - long
    // before the webserver starts - is fine (see OFM-Network/README.Webserver.md).
    openknxNetwork.webserver.addMenuItem("Tunnel", "/tunnels", 105);
    openknxNetwork.webserver.addRoute(
        WEB_GET, "/assets/tunnels.css",
        Webserver::Asset(WebAssets::tunnels_css_mime, WebAssets::tunnels_css_gz, sizeof(WebAssets::tunnels_css_gz)));
    openknxNetwork.webserver.addRoute(
        WEB_GET, "/assets/tunnels.js",
        Webserver::Asset(WebAssets::tunnels_js_mime, WebAssets::tunnels_js_gz, sizeof(WebAssets::tunnels_js_gz)));
    openknxNetwork.webserver.addStylesheet("/assets/tunnels.css");
    openknxNetwork.webserver.addJavaScript("/assets/tunnels.js");

    openknxNetwork.webserver.addRoute(WEB_GET, "/tunnels", [](WebRequest &, WebResponse &res) {
        res.setContentType("text/html");
        res.setLayout(true);
        res.sendStatic(tunPage);
    });
    openknxNetwork.webserver.addRoute(WEB_GET, "/tunnels/state", [](WebRequest &, WebResponse &res) {
        res.setContentType("application/json");
        res.send(buildTunnelJson().c_str());
    });
#else
    (void)configured;
#endif
}

IPRouterModule openknxIPRouterModule;
