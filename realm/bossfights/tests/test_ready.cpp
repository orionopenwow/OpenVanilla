// Boss Fights' ready raider: the pure rules (BossFightsReadyLogic.h, realm/mangos/0052-openvanilla-bossfights-ready.patch).
//   sh realm/bossfights/tests/run.sh   (builds this and test_logic.cpp)
#include "OpenVanilla/BossFightsReadyLogic.h"

#include <cstdio>
#include <map>
#include <set>
#include <string>
#include <vector>

using namespace BossFightsReady;

static int g_fail = 0, g_pass = 0;
#define CHECK(cond, what) do { if (cond) ++g_pass; else { ++g_fail; std::printf("FAIL %s:%d %s\n", __FILE__, __LINE__, what); } } while (0)

static uint8_t const CLASSES[] = { WARRIOR, PALADIN, HUNTER, ROGUE, PRIEST, SHAMAN, MAGE, WARLOCK, DRUID };
// the talent frame's tree names (DualSpec.cpp ClassBuilds): the raid builds must use the same
static std::map<uint8_t, std::vector<std::string>> const TREES = {
    { WARRIOR, { "Arms", "Fury", "Protection" } }, { PALADIN, { "Holy", "Protection", "Retribution" } },
    { HUNTER, { "Beast Mastery", "Marksmanship", "Survival" } }, { ROGUE, { "Assassination", "Combat", "Subtlety" } },
    { PRIEST, { "Discipline", "Holy", "Shadow" } }, { SHAMAN, { "Elemental", "Enhancement", "Restoration" } },
    { MAGE, { "Arcane", "Fire", "Frost" } }, { WARLOCK, { "Affliction", "Demonology", "Destruction" } },
    { DRUID, { "Balance", "Feral", "Restoration" } },
};

int main()
{
    // roles -> trees
    CHECK(TreeFor(WARRIOR, R_TANK) == 2 && TreeFor(WARRIOR, R_DPS) == 1 && TreeFor(WARRIOR, R_HEALER) == 1, "warrior: Protection tanks, Fury otherwise");
    CHECK(TreeFor(PALADIN, R_HEALER) == 0 && TreeFor(PALADIN, R_TANK) == 1 && TreeFor(PALADIN, R_DPS) == 2, "paladin: Holy, Protection, Retribution");
    CHECK(TreeFor(PRIEST, R_HEALER) == 1 && TreeFor(PRIEST, R_DPS) == 2 && TreeFor(PRIEST, R_TANK) == 2, "priest: Holy heals, Shadow otherwise");
    CHECK(TreeFor(SHAMAN, R_HEALER) == 2 && TreeFor(SHAMAN, R_DPS) == 0, "shaman: Restoration, Elemental");
    CHECK(TreeFor(DRUID, R_HEALER) == 2 && TreeFor(DRUID, R_TANK) == 1 && TreeFor(DRUID, R_DPS) == 1, "druid: Restoration, Feral");
    CHECK(TreeFor(ROGUE, R_HEALER) == 1 && TreeFor(MAGE, R_TANK) == 2 && TreeFor(WARLOCK, R_DPS) == 2 && TreeFor(HUNTER, R_TANK) == 1, "pure damage classes");

    for (uint8_t c : CLASSES)
    {
        RaidBuild const* b = RaidBuilds(c);
        CHECK(b != nullptr, "every class has raid builds");
        if (!b)
            continue;
        for (uint32_t t = 0; t < 3; ++t)
        {
            CHECK(TREES.at(c)[t] == b[t].name, (std::string("tree name: ") + b[t].name).c_str());
            std::string link = b[t].link;
            for (char ch : link)
                CHECK((ch >= '0' && ch <= '5') || ch == '-', "a link is digits 0-5 and dashes");
            if (link.empty())
                continue;
            CHECK(LinkPoints(b[t].link) == 51, (std::string("51 points: ") + b[t].name).c_str());
            std::vector<uint32_t> per = LinkTrees(b[t].link);
            CHECK(per.size() <= 3, "at most three trees");
            uint32_t own = t < per.size() ? per[t] : 0, most = 0;
            for (uint32_t p : per)
                most = p > most ? p : most;
            CHECK(own == most, (std::string("the build is deepest in its own tree: ") + b[t].name).c_str());
            CHECK(own >= 21, (std::string("at least 21 points in its own tree: ") + b[t].name).c_str());
        }
        for (uint8_t r : { R_DPS, R_TANK, R_HEALER })
        {
            CHECK(std::string(b[TreeFor(c, r)].link).size() > 0, "every role's tree has a build");
            CHECK(!KitWords(c, r).empty(), "every role has gear-set words");
            std::vector<std::string> spec = SpecBar(c, TreeFor(c, r));
            CHECK(spec.size() == 12, "a full main bar per role");
            std::set<std::string> uniq(spec.begin(), spec.end());
            CHECK(uniq.size() == spec.size(), "no ability twice on the main bar");
        }
        std::vector<std::string> cls = ClassBar(c);
        CHECK(cls.size() == 12, "a full class bar");
        CHECK(std::set<std::string>(cls.begin(), cls.end()).size() == 12, "no ability twice on the class bar");
    }
    CHECK(LinkPoints("") == 0 && LinkPoints("5-5-5") == 15, "LinkPoints");
    CHECK(LinkTrees("12-3").size() == 2 && LinkTrees("12-3")[0] == 3 && LinkTrees("12-3")[1] == 3, "LinkTrees");

    // gear sets
    std::vector<std::string> warrior = { "warrior-arms-h", "warrior-fury-h" };
    CHECK(PickKit(warrior, KitWords(WARRIOR, R_DPS)) == "warrior-fury-h", "a warrior's damage set: Fury");
    CHECK(PickKit(warrior, KitWords(WARRIOR, R_TANK)) == "warrior-fury-h", "no Protection set: Fury's");
    std::vector<std::string> priest = { "priest-shadow-a", "priest-holy-discipline-a" };
    CHECK(PickKit(priest, KitWords(PRIEST, R_HEALER)) == "priest-holy-discipline-a", "a healing priest: Holy / Discipline");
    CHECK(PickKit(priest, KitWords(PRIEST, R_DPS)) == "priest-shadow-a", "a damage priest: Shadow");
    std::vector<std::string> druid = { "druid-balance-h", "druid-feral-h", "druid-restoration-h" };
    CHECK(PickKit(druid, KitWords(DRUID, R_TANK)) == "druid-feral-h" && PickKit(druid, KitWords(DRUID, R_HEALER)) == "druid-restoration-h", "druid sets");
    CHECK(PickKit({ "mage-frost-fire-arcane-a" }, KitWords(MAGE, R_DPS)) == "mage-frost-fire-arcane-a", "the mage's one set");
    CHECK(PickKit({ "x-one", "x-two" }, { "nothing" }) == "x-one", "no match: the first set");
    CHECK(PickKit({}, { "fury" }).empty(), "no sets: none");

    // the bars
    {
        std::set<uint32_t> used = { 1 };                        // the player's own button on slot 2
        std::set<std::string> known = { "Bloodthirst", "Whirlwind", "Heroic Strike", "Execute", "Battle Stance", "Charge", "Dire Bear Form" };
        auto free = [&](uint32_t b) { return !used.count(b); };
        auto know = [&](std::string const& alts) -> std::string
        {
            size_t start = 0;
            while (true)
            {
                size_t bar = alts.find('|', start);
                std::string one = alts.substr(start, bar == std::string::npos ? std::string::npos : bar - start);
                if (known.count(one))
                    return one;
                if (bar == std::string::npos)
                    return std::string();
                start = bar + 1;
            }
        };
        std::set<std::string> already = { "Execute" };
        auto onBar = [&](std::string const& n) { return already.count(n) != 0; };
        auto plan = PlanBars(SpecBar(WARRIOR, 1), ClassBar(WARRIOR), free, know, onBar);
        std::map<std::string, uint32_t> at;
        for (auto const& p : plan)
            at[p.second] = p.first;
        CHECK(at.count("Bloodthirst") && at["Bloodthirst"] == 0, "the first ability on key 1");
        CHECK(at.count("Whirlwind") && at["Whirlwind"] != 1, "a used button is never taken");
        CHECK(at.count("Heroic Strike") && at["Heroic Strike"] == 2, "its own button when free");
        CHECK(!at.count("Execute"), "already on a bar: not placed twice");
        CHECK(!at.count("Death Wish"), "unknown: skipped");
        CHECK(at.count("Battle Stance") && at["Battle Stance"] == 60, "the class bar starts bottom left");
        CHECK(at.count("Charge") && at["Charge"] == 63, "in its own place there");
        std::set<uint32_t> slots;
        for (auto const& p : plan)
            slots.insert(p.first);
        CHECK(slots.size() == plan.size(), "one ability a button");

        // the druid's alternatives: the first known
        auto dplan = PlanBars(SpecBar(DRUID, 1), {}, free, know, onBar);
        CHECK(!dplan.empty() && dplan[0].second == "Dire Bear Form" && dplan[0].first == 0, "Dire Bear Form|Bear Form: the one known");

        // no room anywhere: nothing placed, no endless loop
        auto none = PlanBars(SpecBar(WARRIOR, 1), ClassBar(WARRIOR), [](uint32_t) { return false; }, know, onBar);
        CHECK(none.empty(), "full bars: nothing placed");
        // the main bar full: the spec's abilities go to the next bars
        auto later = PlanBars(SpecBar(WARRIOR, 1), {}, [](uint32_t b) { return b >= 12; }, know, onBar);
        CHECK(!later.empty() && later[0].first == 60, "main bar full: bottom left first");
    }

    // consumables
    auto items = ItemCounts("13446:10 13444:500 bad 0:4 17020", 200);
    CHECK(items.size() == 3, "three items parsed (bad and 0 dropped)");
    CHECK(items[0].first == 13446 && items[0].second == 10, "count kept");
    CHECK(items[1].second == 200, "count capped");
    CHECK(items[2].first == 17020 && items[2].second == 1, "no count: one");
    CHECK(ItemCounts(DefaultConsumables(), 200).size() == 11, "the shared list");
    CHECK(UsesMana(PRIEST) && UsesMana(HUNTER) && !UsesMana(WARRIOR) && !UsesMana(ROGUE), "mana users");
    for (uint8_t c : CLASSES)
        if (c != WARRIOR && c != HUNTER)
            CHECK(!ItemCounts(DefaultClassConsumables(c), 200).empty(), "reagents for every reagent class");
    CHECK(AmmoFor(2) == 18042 && AmmoFor(18) == 18042 && AmmoFor(3) == 15997 && AmmoFor(16) == 0, "arrows for bows and crossbows, shells for guns");

    // the line
    Info i;
    i.level = 60; i.spec = "Protection"; i.spent = 51; i.free = 0; i.setsInBags = 3; i.sets = 3; i.worn = "warrior-fury-h";
    i.freeSlots = 61; i.buttons = 64; i.consHave = 13; i.consWant = 13;
    CHECK(IsReady(i, 60), "ready");
    CHECK(Line(i, 60) == "ready,level=60,spec=Protection,spent=51,free=0,sets=3,setsof=3,worn=warrior-fury-h,slots=61,buttons=64,consumables=13,wanted=13,missing=-,ok=1", Line(i, 60).c_str());
    Info j = i;
    j.consHave = 11; j.missing = { 13446, 13444 }; j.worn = "own"; j.setsInBags = 2;
    CHECK(!IsReady(j, 60), "not ready: consumables and a set missing");
    CHECK(Line(j, 60) == "ready,level=60,spec=Protection,spent=51,free=0,sets=2,setsof=3,worn=own,slots=61,buttons=64,consumables=11,wanted=13,missing=13446:13444,ok=0", Line(j, 60).c_str());
    Info k = i;
    k.worn = "-";
    CHECK(!IsReady(k, 60), "nothing worn: not ready");
    k = i; k.level = 59;
    CHECK(!IsReady(k, 60) && IsReady(k, 0), "below the level: not ready (no level asked: ready)");
    k = i; k.spec = "Beast, Mastery;x";
    CHECK(Line(k, 60).find("spec=Beast__Mastery_x,") != std::string::npos, "commas and spaces in a name can't break the line");
    k = i; k.spec = "";
    CHECK(Line(k, 60).find("spec=-,") != std::string::npos, "no spec: -");
    // the self-test reads the line by key (devkit/heraldlite field()): every key once, delimited
    std::string l = Line(i, 60);
    for (char const* key : { "level=60,", "spent=51,", "free=0,", "sets=3,", "buttons=64,", "consumables=13," })
        CHECK(l.find(std::string(",") + key) != std::string::npos, key);

    std::printf("%d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
