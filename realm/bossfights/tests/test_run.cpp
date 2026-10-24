// Unit tests for Boss Fights' run features (OpenVanilla/BossFightsRunLogic.h, new in
// realm/mangos/0062-openvanilla-bossfights-run-features.patch): run kinds, weekly twists and Raid Roulette, the quick
// reset, the ready check, the ghost split, meters and the death recap, feats, rewards, the Rally Horn and the fear seat.
// realm/bossfights/tests/run.sh builds and runs them.
#include "OpenVanilla/BossFightsRunLogic.h"

#include <cstdio>

static int g_fail = 0, g_pass = 0;
#define CHECK(cond) do { if (cond) ++g_pass; else { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } } while (0)

using namespace BossFights;

int main()
{
    // ── run kinds ──
    {
        RunKind k;
        CHECK(KindFrom("practice2", k) && k == KIND_PRACTICE2);
        CHECK(KindFrom("p3", k) && k == KIND_PRACTICE3);
        CHECK(KindFrom("hardcore", k) && k == KIND_HARDCORE);
        CHECK(KindFrom("story", k) && k == KIND_STORY);
        CHECK(!KindFrom("onyxia", k));
        CHECK(std::string(KindMode(KIND_NORMAL)).empty());
        CHECK(std::string(KindMode(KIND_PRACTICE2)) == "practice" && std::string(KindMode(KIND_PRACTICE3)) == "practice");
        CHECK(std::string(KindMode(KIND_HARDCORE)) == "hardcore" && std::string(KindMode(KIND_STORY)) == "story");
        CHECK(KindUnlocks(KIND_NORMAL) && KindUnlocks(KIND_HARDCORE));
        CHECK(!KindUnlocks(KIND_PRACTICE2) && !KindUnlocks(KIND_PRACTICE3) && !KindUnlocks(KIND_STORY));
        CHECK(!KindRewards(KIND_PRACTICE2) && KindRewards(KIND_STORY) && KindRewards(KIND_HARDCORE));
        CHECK(PracticeHealthPct(KIND_PRACTICE2) == 64.0f && PracticeHealthPct(KIND_PRACTICE3) == 39.0f && PracticeHealthPct(KIND_NORMAL) == 100.0f);
        // 64% is under Onyxia's 65% phase 2 line; 39% under her 40% phase 3 line
        CHECK(PracticeHealthPct(KIND_PRACTICE2) < 65.0f && PracticeHealthPct(KIND_PRACTICE3) < 40.0f);
        CHECK(PracticeOffered("onyxia") && !PracticeOffered("mc"));
        std::string rest;
        CHECK(ExtractKind(" onyxia 2 hardcore", rest, k) && k == KIND_HARDCORE && rest == "onyxia 2");
        CHECK(ExtractKind("onyxia size=2 practice2", rest, k) && k == KIND_PRACTICE2 && rest == "onyxia size=2");
        CHECK(ExtractKind("onyxia", rest, k) && k == KIND_NORMAL && rest == "onyxia");
        CHECK(!ExtractKind("onyxia story hardcore", rest, k));     // one kind at a time
    }

    // ── weekly twists ──
    {
        std::vector<Twist> r = ParseTwists("bloodmoon, shortfuse whelpswarm ironwill bogus");
        CHECK(r.size() == 4 && r[0] == TWIST_BLOOD_MOON && r[3] == TWIST_IRON_WILL);
        CHECK(ParseTwists("").empty());
        // 2026-10-19 was a Monday: Monday 00:00 UTC starts a week, Sunday 23:59 is the week before
        time_t mon = 1792368000;                       // 2026-10-19 00:00:00 UTC
        CHECK(WeekStart(mon) == mon);
        CHECK(WeekStart(mon + 6 * 86400 + 86399) == mon);
        CHECK(WeekStart(mon - 1) == mon - 7 * 86400);
        CHECK(WeekNumber(mon + 7 * 86400) == WeekNumber(mon) + 1);
        CHECK(WeekStart(0) == time_t(-3 * 86400));     // 1970-01-01 was a Thursday: its week began Monday 1969-12-29
        // the rotation turns one step a week and comes round again
        Twist a = WeeklyTwist(r, mon), b = WeeklyTwist(r, mon + 7 * 86400);
        CHECK(a != b);
        CHECK(WeeklyTwist(r, mon) == WeeklyTwist(r, mon + 4 * 7 * 86400));
        CHECK(WeeklyTwist(r, mon) == WeeklyTwist(r, mon + 3 * 86400));
        CHECK(WeeklyTwist({}, mon) == TWIST_NONE);
        CHECK(std::string(TwistName(TWIST_SHORT_FUSE)) == "shortfuse" && std::string(TwistTitle(TWIST_WHELP_SWARM)) == "Whelp Swarm");
        // Blood Moon: both ways, 20%
        CHECK(TwistDamageTaken(TWIST_BLOOD_MOON) > 1.19f && TwistDamageTaken(TWIST_BLOOD_MOON) < 1.21f);
        CHECK(TwistCreatureHealth(TWIST_BLOOD_MOON) < 0.84f && TwistCreatureHealth(TWIST_BLOOD_MOON) > 0.83f);
        CHECK(TwistDamageTaken(TWIST_IRON_WILL) == 1.0f && TwistCreatureHealth(TWIST_NONE) == 1.0f);
        // Short Fuse: nothing before 6 minutes, +25% at 6:00, +50% at 6:30, at most +200%
        CHECK(ShortFuseFactor(359999) == 1.0f);
        CHECK(ShortFuseFactor(360000) == 1.25f);
        CHECK(ShortFuseFactor(390000) == 1.5f);
        CHECK(ShortFuseFactor(3600000) == 3.0f);
        // Raid Roulette: within the raids and the rotation
        for (uint32_t seed = 0; seed < 200; ++seed)
        {
            std::pair<size_t, Twist> p = RoulettePick(2, r, seed);
            CHECK(p.first < 2);
            CHECK(p.second != TWIST_NONE);
        }
        CHECK(RoulettePick(0, {}, 5).second == TWIST_NONE);
    }

    // ── the quick reset and the ready check ──
    {
        CHECK(WipeResets(KIND_NORMAL, 10) && WipeResets(KIND_PRACTICE3, 10) && WipeResets(KIND_STORY, 10));
        CHECK(!WipeResets(KIND_HARDCORE, 10));         // a hardcore wipe ends the run
        CHECK(!WipeResets(KIND_NORMAL, 0));            // off
        CHECK(ReadyOutcome(3, 3, false, 100) == 1);
        CHECK(ReadyOutcome(3, 2, false, 100) == 0);
        CHECK(ReadyOutcome(3, 2, true, 100) == -1);     // a no ends it at once
        CHECK(ReadyOutcome(3, 2, false, 20000) == -2);  // nobody else in 20 s
        CHECK(ReadyOutcome(3, 3, true, 0) == -1);
        CHECK(ReadyOutcome(0, 0, false, 0) == 0);
    }

    // ── the ghost split ──
    {
        CHECK(GhostLine(0, 0, "") == "ghost,0,0,-");
        CHECK(GhostLine(125000, 98000, "Or,ion") == "ghost,125000,98000,Orion");
        CHECK(GhostDelta(60000, 120000, 50.0f) == 0);   // half her health in half the ghost's time: even
        CHECK(GhostDelta(50000, 120000, 50.0f) < 0);    // ahead
        CHECK(GhostDelta(70000, 120000, 50.0f) > 0);    // behind
        CHECK(GhostDelta(70000, 0, 50.0f) == 0);        // no ghost
    }

    // ── meters and the death recap ──
    {
        std::deque<Hit> hits;
        for (int i = 0; i < 7; ++i)
        {
            Hit h;
            h.source = "Onyxia";
            h.spell = i == 6 ? "Flame Breath" : "melee";
            h.amount = 1000 + i;
            h.killing = i == 6;
            PushHit(hits, h);
        }
        CHECK(hits.size() == 5 && hits.front().amount == 1002 && hits.back().killing);
        std::string recap = RecapLine(std::vector<Hit>(hits.begin(), hits.end()));
        CHECK(recap.rfind("recap,Onyxia|melee|1002|0;", 0) == 0);
        CHECK(recap.find(";Onyxia|Flame Breath|1006|1") != std::string::npos);
        CHECK(RecapLine({}) == "recap,-");
        CHECK(LineSafe("a,b;c|d:e") == "abcde" && LineSafe("") == "?" && LineSafe(std::string(40, 'x')).size() == 32);
        std::vector<MeterRow> rows(3);
        rows[0].name = "Tank"; rows[0].cls = 1; rows[0].role = "tank"; rows[0].damage = 50000;
        rows[1].name = "Mage"; rows[1].cls = 8; rows[1].role = "dps"; rows[1].damage = 120000; rows[1].deaths = 1;
        rows[2].name = "Prie"; rows[2].cls = 5; rows[2].role = "healer"; rows[2].healing = 90000; rows[2].bot = true;
        std::string m = MetersLine(rows);
        CHECK(m == "meters;Mage:8:dps:120000:0:1:0;Tank:1:tank:50000:0:0:0;Prie:5:healer:0:90000:0:1");
        CHECK(StatsColumn(rows) == "Tank:50000:0:0,Mage:120000:0:1,Prie:0:90000:0");
        CHECK(IsDeepBreath(17086) && IsDeepBreath(18617) && IsDeepBreath(21131) && !IsDeepBreath(18435));
    }

    // ── feats ──
    {
        RunFacts f;
        f.cleared = true;
        f.raid = "onyxia";
        f.lengthMs = 170000;
        f.people = 1;
        f.bots = 9;
        uint32_t m = FeatsFor(f);
        CHECK(m == (FEAT_NODEATHS | FEAT_UNDER3 | FEAT_NOBREATH | FEAT_BOTSONLY | FEAT_FIRSTTRY));
        CHECK(FeatNames(m) == "nodeaths,under3,nobreath,botsonly,firsttry");
        CHECK(FeatNames(m, '+') == "nodeaths+under3+nobreath+botsonly+firsttry");
        CHECK(FeatCount(m) == 5);
        f.deaths = 2; f.wipes = 1; f.breathHits = 3; f.lengthMs = 0; f.people = 10; f.bots = 0;
        CHECK(FeatsFor(f) == 0);                       // a test kill (no pull): no time feat
        f.roulette = true; f.kind = KIND_HARDCORE;
        CHECK(FeatsFor(f) == (FEAT_ROULETTE | FEAT_HARDCORE));
        f.kind = KIND_PRACTICE2;
        CHECK(FeatsFor(f) == 0);                       // practice: no feats
        f.kind = KIND_NORMAL; f.cleared = false;
        CHECK(FeatsFor(f) == 0);
        f.cleared = true; f.raid = "mc"; f.breathHits = 0; f.roulette = false;
        CHECK((FeatsFor(f) & FEAT_NOBREATH) == 0);      // only Onyxia breathes
        CHECK(FeatNames(0).empty());
        CHECK(std::string(FeatKey(FEAT_FIRSTTRY)) == "firsttry" && std::string(FeatTitle(FEAT_BOTSONLY)) == "Commander");
    }

    // ── rewards ──
    {
        CHECK(ScalesFor(KIND_NORMAL, 1, false, 1, 0) == 2);
        CHECK(ScalesFor(KIND_NORMAL, 3, true, 5, FEAT_NODEATHS | FEAT_UNDER3) == 3 + 2 + 5 + 2);
        CHECK(ScalesFor(KIND_NORMAL, 1, false, 9, 0) == 6);   // the hoard's roll at most 5
        CHECK(ScalesFor(KIND_STORY, 3, true, 5, FEAT_NODEATHS) == 1);
        CHECK(ScalesFor(KIND_PRACTICE2, 3, true, 5, 0) == 0);
        CHECK(EggFor(KIND_NORMAL, true) && EggFor(KIND_HARDCORE, true));
        CHECK(!EggFor(KIND_NORMAL, false) && !EggFor(KIND_STORY, true) && !EggFor(KIND_PRACTICE3, true));
        CHECK(EggsToHatch() == 5);
        CHECK(HoardDrops(0, 35) && HoardDrops(34, 35) && !HoardDrops(35, 35) && !HoardDrops(50, 0) && HoardDrops(99, 100));
        std::vector<std::pair<uint32_t, uint32_t>> shop = ParseShop("900310:30 900311:30,bad 900312: :5 900321:5");
        CHECK(shop.size() == 3 && shop[0].first == 900310 && shop[0].second == 30 && shop[2].first == 900321);
    }

    // ── the Rally Horn ──
    {
        CHECK(HornReady(0, 5000));
        CHECK(!HornReady(10000, 69999));
        CHECK(HornReady(10000, 70000));
        CHECK(HornText("Onyxia's Lair", 2, 6, 10, KIND_NORMAL) == "LFM Onyxia's Lair tier 2, 6 of 10: /bf to join");
        CHECK(HornText("Onyxia's Lair", 1, 1, 10, KIND_HARDCORE) == "LFM Onyxia's Lair tier 1 (hardcore), 1 of 10: /bf to join");
    }

    // ── bossfights_now.phase, and the fear seat of a bot fill ──
    {
        CHECK(OnyxiaPhase(true, false, false, 100.0f, false) == 0);
        CHECK(OnyxiaPhase(true, true, false, 80.0f, false) == 1);
        CHECK(OnyxiaPhase(true, true, true, 60.0f, false) == 2);
        CHECK(OnyxiaPhase(true, true, false, 39.0f, true) == 3);
        CHECK(OnyxiaPhase(true, true, false, 39.0f, false) == 1);  // never in the air yet: still her phase 1
        CHECK(OnyxiaPhase(false, true, false, 0.0f, true) == 0);
        std::vector<Role> plan = { ROLE_TANK, ROLE_HEALER, ROLE_HEALER, ROLE_DPS };
        std::vector<uint8_t> classes = { 1, 5, 11, 8 }, races;
        CHECK(FearSeat(plan, classes, races, false, false) == 1 && classes[1] == 7 && races[1] == 0);   // Horde: a Shaman
        classes = { 1, 5, 11, 8 };
        CHECK(FearSeat(plan, classes, races, true, false) == 1 && classes[1] == 5 && races[1] == 3);    // Alliance: a Dwarf Priest
        classes = { 1, 5, 11, 8 };
        CHECK(FearSeat(plan, classes, races, true, true) == -1 && races.size() == 4 && races[1] == 0);  // the people bring one
        std::vector<Role> dps = { ROLE_DPS, ROLE_DPS };
        std::vector<uint8_t> c2 = { 8, 4 };
        CHECK(FearSeat(dps, c2, races, false, false) == -1);        // no healer seat to change
        std::vector<uint8_t> c3 = { 1, 7, 11, 8 };
        CHECK(FearSeat(plan, c3, races, false, false) == -1);       // a Shaman healer already
    }

    std::printf("test_run: %d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
