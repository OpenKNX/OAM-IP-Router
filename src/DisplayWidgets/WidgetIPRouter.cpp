#ifdef DEVICE_DISPLAY_MODULE
#include "WidgetIPRouter.h"
#include "DeviceDisplay.h"
#include "IPRouterModule.h"
#include "NetworkModule.h"
#include "OpenKNX.h"
#include <WiFi.h>

WidgetIPRouter::WidgetIPRouter(uint32_t displayTime, WidgetFlags action)
    : _displayTime(displayTime), _action(action), _state(WidgetState::STOPPED), _display(nullptr)
{
}

void WidgetIPRouter::setup()
{
    logDebugP("Setup...");
    if (_display == nullptr)
    {
        logErrorP("Display is NULL.");
        return;
    }
}

void WidgetIPRouter::start()
{
    if (_state == WidgetState::RUNNING)
        return;

    logDebugP("Starting...");
    _state = WidgetState::RUNNING;
    _duration_timerStart = millis();
    _forceRedraw = true;
}

void WidgetIPRouter::stop()
{
    logDebugP("Stopping...");
    _state = WidgetState::STOPPED;
    if (_display)
    {
        _display->display->clearDisplay();
        _display->displayBuff();
    }
}

void WidgetIPRouter::pause()
{
    if (_state == WidgetState::RUNNING)
    {
        logDebugP("Pausing...");
        _state = WidgetState::PAUSED;
    }
}

void WidgetIPRouter::resume()
{
    if (_state == WidgetState::PAUSED)
    {
        logDebugP("Resuming");
        _state = WidgetState::RUNNING;
        _forceRedraw = true;
    }
}

void WidgetIPRouter::setPage(size_t page)
{
    if (page >= PAGE_COUNT)
        page = PAGE_COUNT - 1;
    if (page != _page)
    {
        _page = page;
        _forceRedraw = true;
    }
}

void WidgetIPRouter::loop()
{
    if (_state != WidgetState::RUNNING || !_display)
        return;

    // Rebuild at most every REDRAW_INTERVAL_MS: a full frame plus displayBuff() on every loop pass
    // is wasted work, and the interface widget has had this throttle all along.
    const uint32_t now = millis();
    if (!_forceRedraw && now - _lastDraw < REDRAW_INTERVAL_MS)
        return;
    _lastDraw = now;
    _forceRedraw = false;

    switch (_page)
    {
        case PAGE_COUPLER: drawCoupler(); break;
        case PAGE_ROUTING: drawRouting(); break;
        default: drawIPInfo(); break;
    }
}

uint32_t WidgetIPRouter::getDisplayTime() const
{
    return _displayTime;
}
WidgetFlags WidgetIPRouter::getAction() const
{
    return _action;
}

void WidgetIPRouter::setDisplayModule(i2cDisplay *displayModule)
{
    _display = displayModule;
}
i2cDisplay *WidgetIPRouter::getDisplayModule() const
{
    return _display;
}

static const unsigned char PROGMEM x_icon[] = {
    0x81, 0x42, 0x24, 0x18, 0x18, 0x24, 0x42, 0x81};

// Clears the frame and draws title, page dots, dwell marker and divider; the caller fills the rows.
void WidgetIPRouter::drawHeader(const char *title)
{
    _display->display->clearDisplay();
    _display->display->setTextColor(WHITE);
    _display->display->setTextSize(1);
    _display->display->setCursor(0, 0); // title left -- same as every other widget
    _display->display->print(title);

    const uint16_t SCREEN_WIDTH = _display->GetDisplayWidth();

    // One dot per page, the current one filled; clear of the manager's corner at x >= W-12.
    const int16_t startX = (int16_t)SCREEN_WIDTH - 12 - PAGE_COUNT * 6;
    for (uint8_t i = 0; i < PAGE_COUNT; i++)
    {
        const int16_t x = startX + i * 6 + 2;
        if (i == _page)
            _display->display->fillCircle(x, 4, 2, WHITE);
        else
            _display->display->drawCircle(x, 4, 1, WHITE);
    }

    // Dwell marker on the divider -- drawn here, inside the rebuild, so it leaves no trail.
    if (_displayTime > 0)
    {
        uint32_t elapsedMillis = millis() - _duration_timerStart;
        if (elapsedMillis >= _displayTime)
        {
            _duration_timerStart = millis();
            elapsedMillis = 0;
        }
        const uint16_t circlePosition = (uint32_t)SCREEN_WIDTH * elapsedMillis / _displayTime;
        _display->display->fillCircle(circlePosition, 10, 2, WHITE);
        _display->display->drawCircle(circlePosition, 10, 2, BLACK);
    }
    _display->display->drawLine(0, 10, SCREEN_WIDTH, 10, WHITE);
}

void WidgetIPRouter::printRow(int16_t y, const char *text)
{
    _display->display->setCursor(0, y);
    _display->display->print(text);
}

static void fmtIp(char *b, size_t n, const char *label, const IPAddress &a)
{
    snprintf(b, n, "%s%u.%u.%u.%u", label, a[0], a[1], a[2], a[3]);
}

void WidgetIPRouter::printCentered(int16_t y, const char *text)
{
    _display->display->setCursor(((int16_t)_display->GetDisplayWidth() - (int16_t)strlen(text) * 6) / 2, y);
    _display->display->print(text);
}

void WidgetIPRouter::drawIPInfo()
{
    drawHeader(_name.c_str());

    if (openknxNetwork.established())
    {
        char b[24];
        fmtIp(b, sizeof(b), "IP: ", openknxNetwork.localIP());
        printCentered(20, b);
        fmtIp(b, sizeof(b), "GW: ", openknxNetwork.gatewayIP());
        printCentered(30, b);
        fmtIp(b, sizeof(b), "DNS: ", openknxNetwork.nameServerIP());
        printCentered(40, b);
    }
    else
    {
        _display->display->drawBitmap(_display->GetDisplayWidth() / 2 - 4, 20, x_icon, 8, 8, WHITE);
        printCentered(36, "DISCONNECTED");
        printCentered(50, "Check LAN Cable");
    }

    _display->displayBuff();
}

// Role from the own address, routing group, TTL, tunnel use. Every row fits 21 characters.
void WidgetIPRouter::drawCoupler()
{
    drawHeader("Coupler");

    char b[24];
    const uint16_t pa = knx.individualAddress();
    const unsigned area = pa >> 12, line = (pa >> 8) & 0x0F, dev = pa & 0xFF;
    if (!knx.configured())
        snprintf(b, sizeof(b), "Not programmed"); // the coupler default 15.15.0 would read as a line coupler
    else if (dev != 0)
        snprintf(b, sizeof(b), "No coupler %u.%u.%u", area, line, dev); // a device part: misconfigured
    else if (line == 0)
        snprintf(b, sizeof(b), "Area coupler %u.0", area);
    else
        snprintf(b, sizeof(b), "Line coupler %u.%u", area, line);
    printRow(14, b);

    const char *group = IPRouterModule::routingGroup();
    snprintf(b, sizeof(b), "Group %s", group[0] ? group : "-");
    printRow(24, b);

    const int ttl = IPRouterModule::routingTtl();
    if (ttl < 0)
        snprintf(b, sizeof(b), "TTL -");
    else
        snprintf(b, sizeof(b), "TTL %d", ttl);
    printRow(34, b);

#ifdef KNX_TUNNELING
    IpTunnelServer &ts = knx.bau().getIpTunnelServer();
    snprintf(b, sizeof(b), "Tunnels %u / %u", (unsigned)ts.tunnelCount(), (unsigned)ts.tunnelMax());
    printRow(44, b);
#endif

    _display->displayBuff();
}

// Telegrams per direction: routed, dropped by the filter table, not delivered on that side (tunnel losses included).
void WidgetIPRouter::drawRouting()
{
    drawHeader("Routing");

    KnxIpCounters &c = knx.bau().getCounters();
    const uint32_t v[6] = {c.routedToKnx(), c.routedToIp(), c.filteredToKnx(), c.filteredToIp(), c.lostToKnx(), c.lostToIp()};
    static const char *const label[3] = {"Routed", "Filter", "Lost"};
    printRow(14, "        IP>TP  TP>IP");
    char b[24], to[8];
    for (uint8_t i = 0; i < 3; i++)
    {
        snprintf(to, sizeof(to), "%s", humanCount(v[2 * i]).c_str());
        snprintf(b, sizeof(b), "%-6s  %5s  %5s", label[i], to, humanCount(v[2 * i + 1]).c_str());
        printRow(24 + i * 10, b);
    }

    _display->displayBuff();
}




#endif // DEVICE_DISPLAY_MODULE
