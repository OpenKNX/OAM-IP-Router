#ifdef DEVICE_DISPLAY_MODULE
#include "WidgetIPRouter.h"
#include "DeviceDisplay.h"
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

    // Rebuild at most every REDRAW_INTERVAL_MS: a full frame plus displayBuff() on every loop pass
    // is wasted work, and the interface widget has had this throttle all along.
    const uint32_t now = millis();
    if (now - _lastDraw < REDRAW_INTERVAL_MS)
        return;
    _lastDraw = now;

    drawIPInfo();
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

    String firmwareVersion = String(_name.c_str()) + " (v" + String(openknx.info.humanFirmwareVersion().c_str()) + ")";
    _display->display->setTextSize(1);
    _display->display->setCursor(0, 0); // title left -- same as every other widget
    _display->display->print(firmwareVersion.c_str());

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

    if (openknxNetwork.established())
    {
        String ip = "IP: " + openknxNetwork.localIP().toString();
        String gw = "GW: " + openknxNetwork.gatewayIP().toString();
        String dns = "DNS: " + openknxNetwork.nameServerIP().toString();

        _display->display->setCursor((SCREEN_WIDTH - (ip.length() * 6)) / 2, 20);
        _display->display->print(ip.c_str());

        _display->display->setCursor((SCREEN_WIDTH - (gw.length() * 6)) / 2, 30);
        _display->display->print(gw.c_str());

        _display->display->setCursor((SCREEN_WIDTH - (dns.length() * 6)) / 2, 40);
        _display->display->print(dns.c_str());
    }
    else
    {
        _display->display->drawBitmap(CENTER_X - 4, 20, x_icon, 8, 8, WHITE);
        // 12 and 15 glyphs at 6 px -> half widths are 36 and 45, not 30 and 42
        _display->display->setCursor(CENTER_X - 36, 36);
        _display->display->print("DISCONNECTED");
        _display->display->setCursor(CENTER_X - 45, 50);
        _display->display->print("Check LAN Cable");
    }

    _display->displayBuff();
}




#endif // DEVICE_DISPLAY_MODULE
