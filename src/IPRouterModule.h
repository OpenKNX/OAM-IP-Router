#pragma once
#include "OpenKNX.h"

class IPRouterModule : public OpenKNX::Module
{

  public:
    IPRouterModule();

    const std::string name() override;
    const std::string logPrefix() { return "ipro"; }
    const std::string version() override;
    static IPRouterModule *instance();
    bool processCommand(const std::string cmd, bool diagnoseKo) override;
    void showHelp() override;
    void setup(bool configured) override; // registers the tunnel status page (webserver builds only)

  private:
    static IPRouterModule *_instance;
};

extern IPRouterModule openknxIPRouterModule;
