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
    logInfoP("IP Router Setup...");
    if (_display == nullptr)
    {
        logErrorP("Display is NULL.");
        return;
    }
}

void WidgetIPRouter::start()
{
    if (_state == WidgetState::RUNNING) return;

    logInfoP("Starting IP Router Widget...");
    _state = WidgetState::RUNNING;
}

void WidgetIPRouter::stop()
{
    logInfoP("Stopping IP Router Widget...");
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
        logInfoP("Pausing IP Router Widget...");
        _state = WidgetState::PAUSED;
    }
}

void WidgetIPRouter::resume()
{
    if (_state == WidgetState::PAUSED)
    {
        logInfoP("Resuming IP Router Widget...");
        _state = WidgetState::RUNNING;
    }
}

void WidgetIPRouter::loop()
{
    if (_state != WidgetState::RUNNING || !_display) return;

    drawIPInfo();
    //drawTrafficGraph();
}

uint32_t WidgetIPRouter::getDisplayTime() const { return _displayTime; }
WidgetFlags WidgetIPRouter::getAction() const { return _action; }

void WidgetIPRouter::setDisplayModule(i2cDisplay *displayModule) { _display = displayModule; }
i2cDisplay *WidgetIPRouter::getDisplayModule() const { return _display; }

void WidgetIPRouter::drawIPInfo()
{
    if (!_display) return;

    _display->display->clearDisplay();
    
    String ip = openknxNetwork.localIP().toString().c_str();
    String subnet = openknxNetwork.subnetMask().toString().c_str();
    String gateway = openknxNetwork.gatewayIP().toString().c_str();
    String dns = openknxNetwork.nameServerIP().toString().c_str();
    #ifdef ARDUINO_ARCH_ESP32
    String hostname = KNX_NETIF.getHostname();
    #endif

    _display->display->setTextWrap(false);
    #ifdef ARDUINO_ARCH_ESP32
    _display->display->setCursor(0, 0);
    _display->display->print("");
    _display->display->print(hostname.c_str());
    #endif

    _display->display->setCursor(0, 20);
    _display->display->print("IP: ");
    _display->display->print(ip.c_str());

    _display->display->setCursor(0, 30);
    _display->display->print("Subnet: ");
    _display->display->print(subnet.c_str());

    _display->display->setCursor(0, 40);
    _display->display->print("Gateway: ");
    _display->display->print(gateway.c_str());

    _display->display->setCursor(0, 50);
    _display->display->print("DNS: ");
    _display->display->print(dns.c_str());

    

    _display->displayBuff();
}

void WidgetIPRouter::drawTrafficGraph()
{
    if (!_display) return;

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