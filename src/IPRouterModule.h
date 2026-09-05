#pragma once
#include "OpenKNX.h"
#include <atomic>
#include <new>

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
    void loop(bool configured) override;  // builds the filter-table view in slices

#ifdef OPENKNX_ROUTE_TRACE
    /** @brief Appends the filter-table fragment; asks for a rebuild when it is stale, never scans. */
    void appendFilterTableJson(std::string &json);
#endif

  private:
    static IPRouterModule *_instance;

#ifdef OPENKNX_ROUTE_TRACE
    // The filter table is 8 kB of bits and changes only on an ETS download, but scanning it took ~22 ms
    // in one pass -- a quarter of the loop-time warning. It is scanned in slices under freeLoopTime()
    // and kept as the finished fragment; a request only asks for it, it never scans.
    void filterTableLoop();
    // The finished fragment lives in a plain buffer, not a std::string: the web handler reads it from
    // another task (ESP32 httpd at priority 5 against the module loop at 1) and a growing string would
    // free the very bytes that task is copying. The buffer is allocated once and never moves, and
    // _filtSeq is odd while it is being written so a reader can tell that its copy was torn.
    static const uint16_t FILT_BUF = 1536; // 64 ranges at 22 B plus brackets and counters (worst 1458)
    char *_filtBuf = nullptr;         // allocated on the first scan, never freed or moved
    uint16_t _filtLen = 0;            // bytes written so far
    std::atomic<uint32_t> _filtSeq{0}; // odd = buffer unstable, even = published
    const uint8_t *_filtPtr = nullptr; // what the last scan read, to notice a reload
    uint32_t _filtSize = 0;
    uint32_t _filtGa = 0;             // next address of a running scan
    uint32_t _filtFirst = 0;          // start of an open range
    uint32_t _filtCount = 0;          // addresses set so far
    uint16_t _filtRanges = 0;         // ranges seen so far (emitted are capped)
    /** @brief Marks the buffer as being written; a reader seeing an odd counter takes nothing. */
    void markUnstable()
    {
        if ((_filtSeq.load(std::memory_order_relaxed) & 1) == 0)
            _filtSeq.fetch_add(1, std::memory_order_release);
    }
    /** @brief Appends to the fragment buffer, dropping anything that would not fit. */
    void putFilt(const char *src, int n)
    {
        if (n <= 0 || _filtBuf == nullptr || _filtLen + (uint32_t)n > FILT_BUF) return;
        memcpy(_filtBuf + _filtLen, src, (size_t)n);
        _filtLen += (uint16_t)n;
    }
    bool _filtOpen = false;           // a range is open at _filtFirst
    bool _filtBuilding = false;
    bool _filtValid = false;
    bool _filtWanted = false;         // someone looked at the tab
#endif
};

extern IPRouterModule openknxIPRouterModule;
