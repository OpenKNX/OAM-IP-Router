#ifdef DEVICE_DISPLAY_MODULE
#include "WidgetIPRouter.h"
#include "NetworkModule.h"
#include "OpenKNX.h"
#include <WiFi.h>

WidgetIPRouter::WidgetIPRouter(uint32_t displayTime, WidgetFlags action)
    : _displayTime(displayTime), _action(action), _state(WidgetState::STOPPED), _display(nullptr)
{
    rxTrafficHistory.resize(20, 0);
    txTrafficHistory.resize(20, 0);
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
    }
}

void WidgetIPRouter::loop()
{
    if (_state != WidgetState::RUNNING || !_display)
        return;

    drawIPInfo();
    // drawTrafficGraph();
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

void WidgetIPRouter::drawIPInfo()
{
    if (!_display)
        return;

    _display->display->clearDisplay();
    _display->display->setTextColor(WHITE);

    const uint16_t SCREEN_WIDTH = _display->GetDisplayWidth();
    const uint16_t CENTER_X = SCREEN_WIDTH / 2;

    //String firmwareVersion = String(openknx.info.humanFirmwareVersion().c_str()) + " " + String(openknx.info.firmwareName().c_str());
    String firmwareVersion = String(_name.c_str()) + " (v" + String(openknx.info.humanFirmwareVersion().c_str()) + ")";
    _display->display->setTextSize(1);
    _display->display->setCursor((SCREEN_WIDTH - (firmwareVersion.length() * 6)) / 2, 0);
    _display->display->print(firmwareVersion.c_str());

    // Horizontale Linie unter dem Titel
    _display->display->drawLine(0, 10, SCREEN_WIDTH, 10, WHITE);

    if (openknxNetwork.established())
    {
        // IP, Gateway & DNS
        String ip = "IP: " + openknxNetwork.localIP().toString();
        String gw = "GW: " + openknxNetwork.gatewayIP().toString();
        String dns = "DNS: " + openknxNetwork.nameServerIP().toString();

        _display->display->setCursor((SCREEN_WIDTH - (ip.length() * 6)) / 2, 20);
        _display->display->print(ip.c_str());

        _display->display->setCursor((SCREEN_WIDTH - (gw.length() * 6)) / 2, 30);
        _display->display->print(gw.c_str());

        _display->display->setCursor((SCREEN_WIDTH - (dns.length() * 6)) / 2, 40);
        _display->display->print(dns.c_str());

        // Hostname
        //char _hostName[25] = {}; memcpy(_hostName, ParamNET_HostName, 24);
        //String hostname = String("H:") + String(_hostName);
        //_display->display->setCursor((SCREEN_WIDTH - (hostname.length() * 6)) / 2, 50);
        //_display->display->print(hostname.c_str());
    }
    else
    {
        // Kein Netzwerk (X-Icon zentriert)
        _display->display->drawBitmap(CENTER_X - 4, 20, x_icon, 8, 8, WHITE);
        _display->display->setCursor(CENTER_X - 30, 36);
        _display->display->print("DISCONNECTED");
        _display->display->setCursor(CENTER_X - 42, 50);
        _display->display->print("Check LAN Cable");
    }

    _display->displayBuff();
}

void WidgetIPRouter::drawTrafficGraph()
{
    if (!_display)
        return;

    rxTrafficHistory.erase(rxTrafficHistory.begin());
    txTrafficHistory.erase(txTrafficHistory.begin());

    uint16_t rxBytes = getRxBytes();
    uint16_t txBytes = getTxBytes();

    rxTrafficHistory.push_back(rxBytes);
    txTrafficHistory.push_back(txBytes);

    const int graphX = 0;
    const int graphY = 40;
    const int graphWidth = 128;
    const int graphHeight = 20;
    const int barWidth = graphWidth / rxTrafficHistory.size();

    _display->display->drawRect(graphX, graphY, graphWidth, graphHeight, WHITE);

    for (size_t i = 0; i < rxTrafficHistory.size(); i++)
    {
        int rxHeight = map(rxTrafficHistory[i], 0, 5000, 0, graphHeight);
        int txHeight = map(txTrafficHistory[i], 0, 5000, 0, graphHeight);

        _display->display->drawLine(graphX + i * barWidth, graphY + graphHeight - rxHeight,
                                    graphX + i * barWidth, graphY + graphHeight, WHITE);
        _display->display->drawLine(graphX + i * barWidth + 1, graphY + graphHeight - txHeight,
                                    graphX + i * barWidth + 1, graphY + graphHeight, WHITE);
    }

    _display->displayBuff();
}

uint16_t WidgetIPRouter::getRxBytes()
{
    uint16_t bytes = random(1000, 5000);
    uint16_t delta = (bytes > lastRxBytes) ? bytes - lastRxBytes : 0;
    lastRxBytes = bytes;
    return delta;
}

uint16_t WidgetIPRouter::getTxBytes()
{
    uint16_t bytes = random(1000, 5000);
    uint16_t delta = (bytes > lastTxBytes) ? bytes - lastTxBytes : 0;
    lastTxBytes = bytes;
    return delta;
}

#endif // DEVICE_DISPLAY_MODULE