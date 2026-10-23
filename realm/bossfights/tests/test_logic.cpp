// Unit tests for Boss Fights' pure rules (OpenVanilla/BossFightsLogic.h, from
// realm/mangos/0050-openvanilla-bossfights.patch). realm/bossfights/tests/run.sh builds and runs them.
#include "OpenVanilla/BossFightsLogic.h"

#include <cmath>
#include <cstdio>

static int g_fail = 0, g_pass = 0;
#define CHECK(cond) do { if (cond) ++g_pass; else { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } } while (0)
#define NEAR(a, b) CHECK(std::fabs(double(a) - double(b)) < 0.01)

using namespace BossFights;

static Ticket T(std::initializer_list<Role> r, uint32_t waited = 0) { Ticket t; t.roles = r; t.waitedSec = waited; return t; }

int main()
{
    RoleRule rule;  // 2 tanks, 2 healers, relaxed after 120 s

    // ── forming a raid ──
    {
        // ten dps alone: no raid while roles are required ...
        std::vector<Ticket> q;
        for (int i = 0; i < 10; ++i) q.push_back(T({ ROLE_DPS }, 30));
        CHECK(FormRaid(q, 10, rule).empty());
        // ... but one after the oldest has waited past the relax time
        q[0].waitedSec = 121;
        CHECK(FormRaid(q, 10, rule).size() == 10);
    }
    {
        // roles met: 2 tanks, 2 healers, 6 dps, oldest first
        std::vector<Ticket> q = { T({ ROLE_DPS }), T({ ROLE_TANK }), T({ ROLE_HEALER }), T({ ROLE_DPS }), T({ ROLE_TANK }),
                                  T({ ROLE_HEALER }), T({ ROLE_DPS }), T({ ROLE_DPS }), T({ ROLE_DPS }), T({ ROLE_DPS }), T({ ROLE_DPS }) };
        auto r = FormRaid(q, 10, rule);
        CHECK(r.size() == 10);
        CHECK(r.front() == 0);              // the oldest always plays
        CHECK(r.back() == 9);               // the newest dps waits for the next raid
    }
    {
        // a party is never split: a 5-party, a 3-party and two solos make 10
        std::vector<Ticket> q = { T({ ROLE_TANK, ROLE_HEALER, ROLE_DPS, ROLE_DPS, ROLE_DPS }), T({ ROLE_DPS, ROLE_DPS, ROLE_DPS }),
                                  T({ ROLE_TANK }), T({ ROLE_HEALER }) };
        auto r = FormRaid(q, 10, rule);
        CHECK(r.size() == 4);
        // a 6-party and a 5-party never fit 10 together
        std::vector<Ticket> q2 = { T({ ROLE_TANK, ROLE_TANK, ROLE_HEALER, ROLE_HEALER, ROLE_DPS, ROLE_DPS }, 500),
                                   T({ ROLE_DPS, ROLE_DPS, ROLE_DPS, ROLE_DPS, ROLE_DPS }, 500) };
        CHECK(FormRaid(q2, 10, rule).empty());
    }
    {
        // too many dps early in the line: later tanks and healers jump ahead of dps that would leave no seats
        std::vector<Ticket> q;
        for (int i = 0; i < 8; ++i) q.push_back(T({ ROLE_DPS }, 10));
        q.push_back(T({ ROLE_TANK })); q.push_back(T({ ROLE_TANK })); q.push_back(T({ ROLE_HEALER })); q.push_back(T({ ROLE_HEALER }));
        auto r = FormRaid(q, 10, rule);
        CHECK(r.size() == 10);
        int tanks = 0, heals = 0;
        for (size_t i : r) { for (Role x : q[i].roles) { tanks += x == ROLE_TANK; heals += x == ROLE_HEALER; } }
        CHECK(tanks == 2 && heals == 2);
    }
    {
        // a tiny raid (test size) needs no roles
        std::vector<Ticket> q = { T({ ROLE_DPS }) };
        CHECK(FormRaid(q, 1, rule).size() == 1);
        CHECK(FormRaid({}, 10, rule).empty());
    }

    // ── scaling ──
    {
        Scale full = SizeScale(40, 40);
        NEAR(full.health, 1.0); NEAR(full.damage, 1.0);
        Scale ten = SizeScale(10, 40);
        NEAR(ten.health, 0.25);
        NEAR(ten.damage, 0.3536);           // 0.25 ^ 0.75
        Scale one = SizeScale(1, 40);
        NEAR(one.health, 0.15);             // floors
        NEAR(one.damage, 0.30);
        Scale over = SizeScale(50, 40);
        NEAR(over.health, 1.0);             // never harder for being full
        Scale zg = SizeScale(10, 20);
        NEAR(zg.health, 0.5);
    }
    {
        auto t = ParseTiers("1:1;1.3:1.2;bad;2.2:1.6");
        CHECK(t.size() == 4);
        NEAR(t[1].health, 1.3); NEAR(t[1].damage, 1.2);
        NEAR(t[2].health, 1.0); NEAR(t[2].damage, 1.0);   // malformed: stock
        CHECK(ParseTiers("").size() == 1);
        auto a = ParseAffixes("none;fortified;tyrannical;enrage;fortified, enrage");
        CHECK(a.size() == 5);
        CHECK(a[0] == 0 && a[1] == AFFIX_FORTIFIED && a[2] == AFFIX_TYRANNICAL && a[3] == AFFIX_ENRAGE);
        CHECK(a[4] == (AFFIX_FORTIFIED | AFFIX_ENRAGE));
        CHECK(AffixNames(a[4]) == "fortified+enrage");
        CHECK(AffixNames(0) == "none");
        Scale tier{ 1.3f, 1.2f }, size{ 0.25f, 0.35f };
        Scale boss = CreatureScale(tier, size, AFFIX_TYRANNICAL, true);
        NEAR(boss.health, 1.3 * 0.25 * 1.25);
        Scale trash = CreatureScale(tier, size, AFFIX_TYRANNICAL, false);
        NEAR(trash.health, 1.3 * 0.25);
        Scale fort = CreatureScale(tier, size, AFFIX_FORTIFIED, false);
        NEAR(fort.damage, 1.2 * 0.35 * 1.25);
    }
    {
        NEAR(EnrageFactor(0), 1.0);
        NEAR(EnrageFactor(179999), 1.0);
        NEAR(EnrageFactor(180000), 1.1);
        NEAR(EnrageFactor(210000), 1.2);
        NEAR(EnrageFactor(3600000), 2.0);   // capped at +100%
    }

    // ── unlocks and the tier bonus ──
    CHECK(TierOpen(1, 0, 5));
    CHECK(!TierOpen(2, 0, 5));
    CHECK(TierOpen(2, 1, 5));
    CHECK(TierOpen(3, 5, 5));
    CHECK(!TierOpen(6, 5, 5));
    CHECK(!TierOpen(0, 5, 5));
    CHECK(GearTierFor(0) == 1);
    CHECK(GearTierFor(1) == 2);
    CHECK(GearTierFor(2) == 2);
    CHECK(GearTierFor(3) == 3);
    NEAR(StatBonusPct(0), 0);
    NEAR(StatBonusPct(3), 6);
    NEAR(StatBonusPct(9), 10);              // capped

    // ── encounters and the clock ──
    CHECK(AllEncounters(1, 1));             // Onyxia
    CHECK(!AllEncounters(0, 1));
    CHECK(AllEncounters(0x3FF, 10));        // Molten Core
    CHECK(!AllEncounters(0x1FF, 10));
    CHECK(!AllEncounters(0xFF, 0));
    auto fresh = NewEncounters(0x1, 0x7);
    CHECK(fresh.size() == 2 && fresh[0] == 1 && fresh[1] == 2);
    CHECK(NewEncounters(0x7, 0x7).empty());
    CHECK(Clock(0) == "0:00");
    CHECK(Clock(65000) == "1:05");
    CHECK(Clock(3725000) == "1:02:05");

    // ── text ──
    CHECK(CleanNote("  LF2M heals, <b>need</b> 2 tanks!!  ") == "LF2M heals, bneed/b 2 tanks!!");
    CHECK(CleanNote(std::string(100, 'a')).size() == 60);
    CHECK(RoleFrom("heal") == ROLE_HEALER && RoleFrom("t") == ROLE_TANK && RoleFrom("x") == ROLE_DPS);

    std::printf("%d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
