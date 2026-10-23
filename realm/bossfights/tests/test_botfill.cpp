// Unit tests for Boss Fights' bot fill rules (OpenVanilla/BossFightsBotFillLogic.h, from
// realm/mangos/0054-openvanilla-bossfights-bot-fill.patch) and the queue's bots=0|1 word (BossFightsSelfTest.h as
// 0054 leaves it). realm/bossfights/tests/run.sh builds and runs them.
#include "OpenVanilla/BossFightsBotFillLogic.h"
#include "OpenVanilla/BossFightsSelfTest.h"

#include <cstdio>

static int g_fail = 0, g_pass = 0;
#define CHECK(cond) do { if (cond) ++g_pass; else { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } } while (0)

using namespace BossFights;

static uint32_t Count(std::vector<Role> const& v, Role r)
{
    uint32_t n = 0;
    for (Role x : v)
        n += x == r;
    return n;
}

// the plan plus the people meet FormRaid's role rule, so the filled ticket pops at once
static bool PopsWhole(uint32_t size, uint32_t t, uint32_t h, uint32_t d, RoleRule const& rule)
{
    std::vector<Role> plan = PlanFill(size, t, h, d, rule);
    Ticket k;
    for (uint32_t i = 0; i < t; ++i) k.roles.push_back(ROLE_TANK);
    for (uint32_t i = 0; i < h; ++i) k.roles.push_back(ROLE_HEALER);
    for (uint32_t i = 0; i < d; ++i) k.roles.push_back(ROLE_DPS);
    for (Role r : plan) k.roles.push_back(r);
    k.waitedSec = 0;                                    // strict: roles enforced
    std::vector<Ticket> line{ k };
    return FormRaid(line, size, rule).size() == 1;
}

int main()
{
    RoleRule rule;                                      // 2 tanks, 2 healers, relax 120 s (the players' default)
    RoleRule none;
    none.tanks = none.healers = 0;

    // ── how many tanks and healers a filled raid aims for ──
    {
        FillTarget t = FillTargetFor(10, rule);
        CHECK(t.tanks == 2 && t.healers == 3);           // 2 tanks, 3 healers, 5 damage
        t = FillTargetFor(20, rule);
        CHECK(t.tanks == 2 && t.healers == 5);
        t = FillTargetFor(40, rule);
        CHECK(t.tanks == 2 && t.healers == 10);
        t = FillTargetFor(5, none);
        CHECK(t.tanks == 1 && t.healers == 1);           // a self-test five: one of each
        t = FillTargetFor(5, rule);
        CHECK(t.tanks == 2 && t.healers == 2);           // RaidSize 5 with the role rule: the rule's numbers
        t = FillTargetFor(2, none);
        CHECK(t.tanks == 0 && t.healers == 0);
        t = FillTargetFor(3, rule);                      // the rule doesn't apply below 4 seats
        CHECK(t.tanks == 1 && t.healers == 1);
        t = FillTargetFor(1, none);
        CHECK(t.tanks + t.healers <= 1);
    }

    // ── the bots' roles ──
    {
        // a lone damage dealer in a ten: 2 tanks, 3 healers, 4 damage
        std::vector<Role> p = PlanFill(10, 0, 0, 1, rule);
        CHECK(p.size() == 9);
        CHECK(Count(p, ROLE_TANK) == 2 && Count(p, ROLE_HEALER) == 3 && Count(p, ROLE_DPS) == 4);
        CHECK(p[0] == ROLE_TANK && p[1] == ROLE_TANK && p[2] == ROLE_HEALER);     // tanks first, then healers
        // a lone tank: one more tank
        p = PlanFill(10, 1, 0, 0, rule);
        CHECK(Count(p, ROLE_TANK) == 1 && Count(p, ROLE_HEALER) == 3 && Count(p, ROLE_DPS) == 5);
        // a lone healer
        p = PlanFill(10, 0, 1, 0, rule);
        CHECK(Count(p, ROLE_TANK) == 2 && Count(p, ROLE_HEALER) == 2 && Count(p, ROLE_DPS) == 5);
        // a party of three healers and a tank: their roles count
        p = PlanFill(10, 1, 3, 0, rule);
        CHECK(p.size() == 6 && Count(p, ROLE_TANK) == 1 && Count(p, ROLE_HEALER) == 0 && Count(p, ROLE_DPS) == 5);
        // more healers than the target: no bot healer, never fewer seats filled
        p = PlanFill(10, 0, 5, 0, rule);
        CHECK(p.size() == 5 && Count(p, ROLE_HEALER) == 0 && Count(p, ROLE_TANK) == 2);
        // a full raid: no bots
        CHECK(PlanFill(10, 2, 3, 5, rule).empty());
        CHECK(PlanFill(10, 2, 3, 7, rule).empty());     // more people than seats (never asked): none
        // the self-test's five: one tank (the tester), a healer and three damage
        p = PlanFill(5, 1, 0, 0, none);
        CHECK(p.size() == 4 && Count(p, ROLE_HEALER) == 1 && Count(p, ROLE_TANK) == 0 && Count(p, ROLE_DPS) == 3);
        // two seats left, three roles missing: tanks first, the plan never grows past the seats
        p = PlanFill(10, 0, 0, 8, rule);
        CHECK(p.size() == 2 && Count(p, ROLE_TANK) == 2);
        // the plan pops whole under the players' role rule (strict: the oldest ticket hasn't waited 120 s)
        CHECK(PopsWhole(10, 0, 0, 1, rule));
        CHECK(PopsWhole(10, 1, 0, 0, rule));
        CHECK(PopsWhole(10, 0, 1, 0, rule));
        CHECK(PopsWhole(10, 0, 0, 4, rule));
        CHECK(PopsWhole(5, 0, 0, 1, rule));
        CHECK(PopsWhole(20, 1, 1, 1, rule));
        CHECK(PopsWhole(40, 0, 0, 1, rule));
        CHECK(PopsWhole(5, 1, 0, 0, none));
        // every size and every lone role pops whole (but a size of exactly the rule's tanks + healers, 4, with a
        // damage dealer in it: no seat is left for the rule, so it pops when the roles relax after 2 minutes)
        bool all = true;
        for (uint32_t size = 1; size <= 40; ++size)
            for (int r = 0; r < 3; ++r)
            {
                if (!(size == rule.tanks + rule.healers && r == 0))
                    all = all && PopsWhole(size, r == 1, r == 2, r == 0, rule);
                all = all && PopsWhole(size, r == 1, r == 2, r == 0, none);
            }
        CHECK(all);
        CHECK(!PopsWhole(4, 0, 0, 1, rule));            // that one case, as said
    }

    // ── the classes ──
    {
        CHECK(FillClass(ROLE_TANK, true, 0) == 1 && FillClass(ROLE_TANK, false, 3) == 1);   // Warriors tank
        CHECK(FillClass(ROLE_HEALER, true, 0) == 5);    // Priest
        CHECK(FillClass(ROLE_HEALER, true, 1) == 11);   // Druid
        CHECK(FillClass(ROLE_HEALER, true, 2) == 2);    // Alliance: Paladin
        CHECK(FillClass(ROLE_HEALER, false, 2) == 7);   // Horde: Shaman
        CHECK(FillClass(ROLE_HEALER, false, 3) == 5);   // round again
        CHECK(FillClass(ROLE_DPS, true, 0) == 8 && FillClass(ROLE_DPS, true, 1) == 4 && FillClass(ROLE_DPS, true, 2) == 9 &&
              FillClass(ROLE_DPS, true, 3) == 3 && FillClass(ROLE_DPS, true, 4) == 1 && FillClass(ROLE_DPS, true, 5) == 8);
        // no faction's class for the other faction
        bool ok = true;
        for (uint32_t n = 0; n < 12; ++n)
            for (int r = 0; r < 3; ++r)
            {
                ok = ok && FillClass(Role(r), true, n) != 7;
                ok = ok && FillClass(Role(r), false, n) != 2;
            }
        CHECK(ok);
        // counted per role: the plan's second healer is a Druid even after tanks
        std::vector<uint8_t> c = FillClasses(PlanFill(10, 0, 0, 1, rule), false);
        CHECK(c.size() == 9);
        CHECK(c[0] == 1 && c[1] == 1);                  // two Warriors
        CHECK(c[2] == 5 && c[3] == 11 && c[4] == 7);    // Priest, Druid, Shaman
        CHECK(c[5] == 8 && c[6] == 4 && c[7] == 9 && c[8] == 3);
    }

    // ── whether bots may come ──
    {
        CHECK(CanFill(true, true, 2000, 600, 0, 9, 18, 0) == FILL_OK);
        CHECK(CanFill(false, true, 2000, 600, 0, 9, 18, 0) == FILL_OFF);
        CHECK(CanFill(true, false, 2000, 600, 0, 9, 18, 0) == FILL_AI);
        CHECK(CanFill(true, true, 599, 600, 0, 9, 18, 0) == FILL_MEMORY);
        CHECK(CanFill(true, true, 600, 600, 0, 9, 18, 0) == FILL_OK);
        CHECK(CanFill(true, true, 2000, 600, 9, 9, 18, 0) == FILL_OK);      // 18 alive is the cap
        CHECK(CanFill(true, true, 2000, 600, 10, 9, 18, 0) == FILL_MAX);    // the whole fill must fit
        CHECK(CanFill(true, true, 2000, 600, 0, 9, 0, 0) == FILL_MAX);      // .Max 0: never
        CHECK(CanFill(true, true, 2000, 600, 0, 9, 18, 3) == FILL_ERROR);   // three failed asks
        CHECK(CanFill(true, true, 100, 600, 20, 9, 18, 5) == FILL_ERROR);   // the order: off, ai, error, max, memory
        CHECK(std::string(FillBlockName(FILL_MEMORY)) == "memory" && std::string(FillBlockName(FILL_MAX)) == "max" &&
              std::string(FillBlockName(FILL_AI)) == "ai" && std::string(FillBlockName(FILL_OFF)) == "off" &&
              std::string(FillBlockName(FILL_ERROR)) == "error");
        CHECK(FillDue(30, 30) && FillDue(31, 30) && !FillDue(29, 30) && FillDue(0, 0));
    }

    // ── free memory ──
    {
        CHECK(FreeMB(2048 * 1024, 0, 0) == 2048);                          // no container limit
        CHECK(FreeMB(2048 * 1024, 3000ull << 20, 2800ull << 20) == 200);   // the container's limit is nearer
        CHECK(FreeMB(500 * 1024, 3000ull << 20, 1000ull << 20) == 500);    // the host is nearer
        CHECK(FreeMB(2048 * 1024, 1000ull << 20, 1200ull << 20) == 0);     // over the limit
        CHECK(FreeMB(2048 * 1024, ~0ull, 5) == 2048);                      // "no limit" as a huge number
    }

    // ── the queue line's bot fields ──
    {
        FillState s = FillStateFor(false, 0, 9, FILL_OK, 10, 30);
        CHECK(s.state == "wait" && s.seconds == 20 && s.want == 9);
        CHECK(FillFields(s) == ",wait,20,0,9");
        s = FillStateFor(false, 0, 9, FILL_OK, 45, 30);
        CHECK(s.state == "wait" && s.seconds == 0);
        s = FillStateFor(true, 4, 9, FILL_OK, 45, 30);
        CHECK(FillFields(s) == ",joining,0,4,9");
        s = FillStateFor(true, 9, 9, FILL_OK, 45, 30);
        CHECK(FillFields(s) == ",ready,0,9,9");         // every bot in: it pops
        s = FillStateFor(false, 9, 9, FILL_MEMORY, 45, 30);
        CHECK(s.state == "ready");                      // the ones in stay in, whatever the memory now
        s = FillStateFor(false, 0, 9, FILL_MEMORY, 45, 30);
        CHECK(FillFields(s) == ",memory,0,0,9");
        s = FillStateFor(false, 0, 0, FILL_MEMORY, 45, 30);
        CHECK(FillFields(s) == ",full,0,0,0");          // people fill it: no bots, whatever the memory
        // old readers: the first eight fields are unchanged
        std::string line = "q,onyxia,1,1,12,1,10,9" + FillFields(FillStateFor(false, 0, 9, FILL_OK, 12, 30));
        std::istringstream in(line);
        std::string f;
        int n = 0;
        while (std::getline(in, f, ','))
            ++n;
        CHECK(n == 12);
        CHECK(line.compare(0, 23, "q,onyxia,1,1,12,1,10,9,") == 0);
    }

    // ── bots=0|1 in the queue's words (0054) ──
    {
        std::string raid;
        uint32_t tier = 0, size = 0;
        bool bots = false;
        CHECK(ParseQueueWords(" onyxia size=5 bots=1", raid, tier, size, &bots) && raid == "onyxia" && size == 5 && bots);
        CHECK(ParseQueueWords(" onyxia bots=0 size=5", raid, tier, size, &bots) && !bots && size == 5);
        CHECK(ParseQueueWords(" onyxia 2", raid, tier, size, &bots) && !bots && tier == 2);
        CHECK(!ParseQueueWords(" onyxia bots=2", raid, tier, size, &bots));
        CHECK(!ParseQueueWords(" onyxia bots=1", raid, tier, size));        // without `bots`: as before 0054
        CHECK(ParseQueueWords(" onyxia size=2", raid, tier, size));         // the main self-test's words
        bool b = true;
        CHECK(ParseBotsWord("bots=0", b) && !b && ParseBotsWord("bots=1", b) && b && !ParseBotsWord("bots=x", b));
    }

    std::printf("%d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
