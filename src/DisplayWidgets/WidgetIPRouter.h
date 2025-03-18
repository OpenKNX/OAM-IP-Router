#ifdef DEVICE_DISPLAY_MODULE

#pragma once
#include "Widget.h"
#include <vector>

class WidgetIPRouter : public Widget
{
  public:
    const std::string logPrefix() { return "WidgetIPRouter"; }
    WidgetIPRouter(uint32_t displayTime, WidgetFlags action);

    void start() override;
    void stop() override;
    void pause() override;
    void resume() override;
    void setup() override;
    void loop() override;

    inline const WidgetState getState() const override { return _state; }
    inline const std::string getName() const override { return _name; }
    inline void setName(const std::string &name) override { _name = name; }

    uint32_t getDisplayTime() const override;
    WidgetFlags getAction() const override;

    inline void setDisplayTime(uint32_t displayTime) override { _displayTime = displayTime; }
    inline void setAction(uint8_t action) override { _action = static_cast<WidgetFlags>(action); }
    inline void addAction(uint8_t action) override { _action = static_cast<WidgetFlags>(_action | action); }
    inline void removeAction(uint8_t action) override { _action = static_cast<WidgetFlags>(_action & ~action); }

    void setDisplayModule(i2cDisplay *displayModule) override;
    i2cDisplay *getDisplayModule() const override;

  private:
    WidgetState _state;
    uint32_t _displayTime;
    WidgetFlags _action;
    i2cDisplay *_display;
    std::string _name = "IP Router";

    std::vector<uint16_t> rxTrafficHistory;
    std::vector<uint16_t> txTrafficHistory;
    uint16_t lastRxBytes = 0;
    uint16_t lastTxBytes = 0;

    void drawIPInfo();
    void drawTrafficGraph();
    uint16_t getRxBytes();
    uint16_t getTxBytes();
};

#endif // DEVICE_DISPLAY_MODULE