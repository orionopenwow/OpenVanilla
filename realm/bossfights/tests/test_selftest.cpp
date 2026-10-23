// Unit tests for the Boss Fights self-test's pure rules (OpenVanilla/BossFightsSelfTest.h, from
// realm/mangos/0051-openvanilla-bossfights-selftest.patch). realm/bossfights/tests/run.sh builds and runs them.
#include "OpenVanilla/BossFightsSelfTest.h"

#include <cstdio>

static int g_fail = 0, g_pass = 0;
#define CHECK(cond) do { if (cond) ++g_pass; else { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } } while (0)

using namespace BossFights;

int main()
{
    // ── test accounts ──
    {
        TestAccounts t = TestAccounts::Parse("BFTEST* qa_bot 42");
        CHECK(t.Matches(7, "BFTEST1"));
        CHECK(t.Matches(7, "bftest2"));             // case blind
        CHECK(t.Matches(7, "QA_BOT"));
        CHECK(t.Matches(42, "ANYONE"));             // by id
        CHECK(!t.Matches(7, "ORION"));
        CHECK(!t.Matches(7, "BFTES"));              // shorter than the prefix
        CHECK(!t.Matches(7, "QA_BOT2"));            // a name is exact
        CHECK(!t.Matches(7, ""));
    }
    {
        // a lone "*" never makes every account a test account; nothing set: nobody
        TestAccounts t = TestAccounts::Parse("*");
        CHECK(t.Empty());
        CHECK(!t.Matches(1, "ORION"));
        CHECK(!TestAccounts::Parse("").Matches(1, "BFTEST1"));
    }

    // ── the queue's words ──
    {
        std::string raid;
        uint32_t tier = 9, size = 9;
        CHECK(ParseQueueWords(" onyxia", raid, tier, size) && raid == "onyxia" && tier == 1 && size == 0);
        CHECK(ParseQueueWords(" onyxia 3", raid, tier, size) && raid == "onyxia" && tier == 3 && size == 0);
        CHECK(ParseQueueWords(" onyxia size=2", raid, tier, size) && raid == "onyxia" && tier == 1 && size == 2);
        CHECK(ParseQueueWords(" mc 2 size=5", raid, tier, size) && raid == "mc" && tier == 2 && size == 5);
        CHECK(ParseQueueWords(" size=5 any", raid, tier, size) && raid == "any" && size == 5);
        CHECK(ParseQueueWords("", raid, tier, size) && raid.empty() && tier == 1);
        CHECK(!ParseQueueWords(" onyxia size=0", raid, tier, size));
        CHECK(!ParseQueueWords(" onyxia size=41", raid, tier, size));
        CHECK(!ParseQueueWords(" onyxia size=two", raid, tier, size));
        CHECK(!ParseQueueWords(" onyxia 2 3", raid, tier, size));
        CHECK(!ParseQueueWords(" onyxia bogus", raid, tier, size));
        CHECK(ParseQueueWords(" onyxia 0", raid, tier, size) && tier == 1);   // tier 0 is tier 1
    }

    // ── the state line ──
    {
        StateLine l;
        l.Add("mode", true).Add("hub", false).Add("q", std::string("queued")).Add("pos", uint64_t(1)).Add("raid", std::string("a,b=c"));
        std::string s = l.Str();
        CHECK(s == "state,mode=1,hub=0,q=queued,pos=1,raid=abc");
        CHECK(StateValue(s, "q") == "queued");
        CHECK(StateValue(s, "pos") == "1");
        CHECK(StateValue(s, "po").empty());           // a key is matched whole
        CHECK(StateValue(s, "missing").empty());
        StateLine e;
        CHECK(e.Add("x", std::string("")).Str() == "state,x=-");
    }

    std::printf("%d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
