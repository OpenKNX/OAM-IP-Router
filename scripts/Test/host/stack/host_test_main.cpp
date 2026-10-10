/**
 * @brief Runs the registered host stack cases; argument = id prefix filter.
 */
#include <cstdio>
#include <exception>

#include "host_env.h"
#include "host_test.h"

std::vector<HostTestCase>& hostTests()
{
    static std::vector<HostTestCase> t;
    return t;
}

std::string& hostNote()
{
    static std::string note;
    return note;
}

std::string hex(const std::vector<uint8_t>& v)
{
    std::string o;
    char b[4];
    for (size_t i = 0; i < v.size(); i++)
    {
        snprintf(b, sizeof(b), "%02X", v[i]);
        if (i)
            o += ' ';
        o += b;
    }
    return o;
}

static std::string oneLine(std::string s)
{
    for (char& c : s)
        if (c == '\n' || c == '\t' || c == '\r')
            c = ' ';
    return s;
}

int main(int argc, char** argv)
{
    // "--list" prints the ids; "=ID" runs exactly one case (a runner isolates a crash that way);
    // anything else is an id prefix.
    const std::string filter = argc > 1 ? argv[1] : "";
    if (filter == "--list")
    {
        for (auto& tc : hostTests())
            printf("%s\n", tc.id.c_str());
        return 0;
    }
    const bool exact = !filter.empty() && filter[0] == '=';
    int fails = 0;
    for (auto& tc : hostTests())
    {
        if (exact ? tc.id != filter.substr(1) : (!filter.empty() && tc.id.rfind(filter, 0) != 0))
            continue;
        printf("RUN %s\n", tc.id.c_str());
        fflush(stdout);
        hostLog().clear();
        hostNote().clear();
        std::string verdict = "PASS", detail;
        try
        {
            tc.fn();
        }
        catch (HostTestFail& f)
        {
            verdict = "FAIL";
            detail = f.msg;
        }
        catch (HostTestSkip& s)
        {
            verdict = "SKIP";
            detail = s.msg;
        }
        catch (HostFatal&)
        {
            verdict = "FAIL";
            detail = "the stack called fatalError(); log: " + hostLog().substr(0, 300);
        }
        catch (std::exception& e)
        {
            verdict = "FAIL";
            detail = std::string("exception: ") + e.what();
        }
        if (verdict == "FAIL")
            fails++;
        if (!hostNote().empty())
            detail = detail.empty() ? hostNote() : detail + " | " + hostNote();
        printf("%s\t%s\t%s\t%s\n", tc.id.c_str(), verdict.c_str(), tc.title.c_str(), oneLine(detail).c_str());
        fflush(stdout);
    }
    return fails ? 1 : 0;
}
