/**
 * @brief Minimal test registry for the host stack harness.
 *
 * Each case prints "RUN <id>" before it starts, so a sanitizer abort is attributed to the right case, and
 * one result line "<id> TAB PASS|FAIL|SKIP TAB <title> TAB <detail>".
 */
#pragma once
#include <functional>
#include <sstream>
#include <string>
#include <vector>

struct HostTestFail
{
    std::string msg;
};
struct HostTestSkip
{
    std::string msg;
};

struct HostTestCase
{
    std::string id;
    std::string title;
    std::function<void()> fn;
};

std::vector<HostTestCase>& hostTests();

struct HostTestRegistrar
{
    HostTestRegistrar(const char* id, const char* title, std::function<void()> fn) { hostTests().push_back({id, title, fn}); }
};

#define HT_CAT2(a, b) a##b
#define HT_CAT(a, b) HT_CAT2(a, b)
#define HOST_TEST(id, title)                                                                     \
    static void HT_CAT(ht_fn_, __LINE__)();                                                     \
    static HostTestRegistrar HT_CAT(ht_reg_, __LINE__)(id, title, HT_CAT(ht_fn_, __LINE__));  \
    static void HT_CAT(ht_fn_, __LINE__)()

#define EXPECT(cond, what)                                                                  \
    do                                                                                      \
    {                                                                                       \
        if (!(cond))                                                                        \
        {                                                                                   \
            std::ostringstream _os;                                                         \
            _os << what;                                                                    \
            throw HostTestFail{_os.str()};                                                  \
        }                                                                                   \
    } while (0)

#define SKIP(what)                    \
    do                                \
    {                                 \
        std::ostringstream _os;       \
        _os << what;                  \
        throw HostTestSkip{_os.str()}; \
    } while (0)

std::string hex(const std::vector<uint8_t>& v);

/** @brief Evidence of the running case; printed with the verdict, PASS included. */
std::string& hostNote();
#define NOTE(what)                  \
    do                              \
    {                               \
        std::ostringstream _os;     \
        _os << what;                \
        if (!hostNote().empty())    \
            hostNote() += "; ";     \
        hostNote() += _os.str();    \
    } while (0)
