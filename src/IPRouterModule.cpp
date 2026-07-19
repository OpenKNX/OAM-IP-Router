#include "IPRouterModule.h"

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

    return false;
}

IPRouterModule openknxIPRouterModule;
