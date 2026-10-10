/*
 * Host driver for the knx datapoint converter.
 *
 * Reads vectors from stdin, runs them through the REAL KNX_Encode_Value / KNX_Decode_Value,
 * and writes what the library produced. It carries no expectations of its own -- the runner
 * owns those, so a wrong expectation can never be hidden inside the thing under test.
 *
 * Vector line (TAB separated):
 *   id  dir  main.sub.index  input
 *     dir   = enc | dec
 *     input = enc: a number, or "tm:Y,M,D,h,m,s,wd"   dec: payload hex, e.g. "0F 78"
 * Result line (TAB separated):
 *   id  OK|REJECT  payload-hex-or-value
 */
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include <sstream>
#include <iostream>
#include "knx/dptconvert.h"

// The converter pulls in the stack's logger for one diagnostic. Stub it: this driver reports through
// stdout, and a library print here would corrupt the result stream.
void println(const char*) {}

static std::vector<uint8_t> parseHex(const std::string& s)
{
    std::vector<uint8_t> v; std::istringstream is(s); std::string t;
    while (is >> t) v.push_back((uint8_t)strtoul(t.c_str(), nullptr, 16));
    return v;
}

static std::string toHex(const uint8_t* p, size_t n)
{
    std::string o; char b[4];
    for (size_t i = 0; i < n; i++) { snprintf(b, sizeof(b), "%02X", p[i]); if (i) o += ' '; o += b; }
    return o;
}

static bool parseTm(const std::string& s, struct tm& t)
{
    if (s.rfind("tm:", 0) != 0) return false;
    int y=0,mo=0,d=0,h=0,mi=0,se=0,wd=0;
    if (sscanf(s.c_str() + 3, "%d,%d,%d,%d,%d,%d,%d", &y,&mo,&d,&h,&mi,&se,&wd) < 6) return false;
    memset(&t, 0, sizeof(t));
    t.tm_year = y; t.tm_mon = mo; t.tm_mday = d;      // KNX convention: absolute year, month 1..12
    t.tm_hour = h; t.tm_min = mi; t.tm_sec = se; t.tm_wday = wd;
    return true;
}

int main()
{
    std::string line;
    while (std::getline(std::cin, line))
    {
        if (line.empty() || line[0] == '#') continue;
        std::vector<std::string> f; std::string cell; std::istringstream ls(line);
        while (std::getline(ls, cell, '\t')) f.push_back(cell);
        if (f.size() < 4) continue;

        const std::string& id = f[0];
        const std::string& dir = f[1];
        int mg=0, sg=0, ix=0;
        sscanf(f[2].c_str(), "%d.%d.%d", &mg, &sg, &ix);
        Dpt dpt((short)mg, (short)sg, (short)ix);

        if (dir == "dec")
        {
            std::vector<uint8_t> p = parseHex(f[3]);
            KNXValue v((uint8_t)0);
            int ok = KNX_Decode_Value(p.data(), p.size(), dpt, v);
            if (!ok) { printf("%s\tREJECT\t-\n", id.c_str()); continue; }
            // Integral values exactly, anything else with every significant digit a double carries.
            double d = (double)v;
            // Range first: casting NaN or a value beyond long long is undefined behaviour.
            if (d > -1e15 && d < 1e15 && d == (double)(long long)d)
                printf("%s\tOK\t%lld\n", id.c_str(), (long long)d);
            else
                printf("%s\tOK\t%.17g\n", id.c_str(), d);
        }
        else
        {
            uint8_t buf[16]; memset(buf, 0, sizeof(buf));
            size_t len = dpt.dataLength();
            if (len == 0 || len > sizeof(buf)) len = sizeof(buf);
            int ok;
            struct tm t;
            if (parseTm(f[3], t)) { KNXValue v(t); ok = KNX_Encode_Value(v, buf, len, dpt); }
            else                  { KNXValue v(strtod(f[3].c_str(), nullptr)); ok = KNX_Encode_Value(v, buf, len, dpt); }
            if (!ok) { printf("%s\tREJECT\t-\n", id.c_str()); continue; }
            printf("%s\tOK\t%s\n", id.c_str(), toHex(buf, len).c_str());
        }
    }
    return 0;
}
