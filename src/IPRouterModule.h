#pragma once
#include "OpenKNX.h"

class IPRouterModule : public OpenKNX::Module
{

  public:
    IPRouterModule();

    const std::string name() override;
    const std::string version() override;
    static IPRouterModule *instance();
    bool processCommand(const std::string cmd, bool diagnoseKo) override;

  private:
    static IPRouterModule *_instance;
};

extern IPRouterModule openknxIPRouterModule;
