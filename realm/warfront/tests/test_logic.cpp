// Unit tests for Warfront's pure rules (WarfrontLogic.cpp). Build without a server:
//   g++ -std=c++17 -I<stub dir> -I<mangos>/src/game test_logic.cpp <mangos>/src/game/OpenVanilla/WarfrontLogic.cpp
// (realm/warfront/tests/run_logic_tests.sh does it.)
#include "OpenVanilla/Warfront.h"
#include "OpenVanilla/WarfrontArena.h"

#include <cstdio>
#include <string>
#include <vector>

static int g_fail = 0, g_pass = 0;
#define CHECK(cond) do { if (cond) ++g_pass; else { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } } while (0)

int main()
{
    using namespace Warfront;
    // tiers
    CHECK(TierFor(0, 0, 1600, 1500, 1850, 5000) == 0);
    CHECK(TierFor(1599, 1499, 1600, 1500, 1850, 5000) == 0);
    CHECK(TierFor(1600, 0, 1600, 1500, 1850, 5000) == 2);
    CHECK(TierFor(0, 1500, 1600, 1500, 1850, 5000) == 2);
    CHECK(TierFor(1850, 0, 1600, 1500, 1850, 5000) == 3);
    CHECK(TierFor(0, 5000, 1600, 1500, 1850, 5000) == 3);
    // set names
    CHECK(CleanSetName("  Burst   Rogue  ") == "Burst Rogue");
    CHECK(CleanSetName("<script>alert(1)</script>") == "scriptalert1script");
    CHECK(CleanSetName("Gladiator's 2v2 - Arms") == "Gladiator's 2v2 - Arms");
    CHECK(CleanSetName("|cffff0000red|r") == "cffff0000redr");
    CHECK(CleanSetName("   ").empty());
    CHECK(CleanSetName(std::string(60, 'a')).size() == 24);
    CHECK(CleanSetName("abc'; DROP TABLE x;--") == "abc' DROP TABLE x--");
    // slot:item lists
    std::vector<std::pair<uint32, uint32>> v;
    CHECK(ParseSlotItems("0:16478,15:19364", v) && v.size() == 2 && v[0].first == 0 && v[1].second == 19364);
    CHECK(!ParseSlotItems("", v));
    CHECK(!ParseSlotItems("0:16478,0:16479", v));        // a slot twice
    CHECK(!ParseSlotItems("3:100", v));                  // shirt
    CHECK(!ParseSlotItems("18:100", v));                 // tabard
    CHECK(!ParseSlotItems("19:100", v));                 // past the last slot
    CHECK(!ParseSlotItems("1:abc", v));
    CHECK(!ParseSlotItems("1:1234567", v));              // item id too long
    CHECK(!ParseSlotItems("1:0", v));
    CHECK(!ParseSlotItems("1:5,", v));
    CHECK(!ParseSlotItems(":5", v));
    // Elo
    CHECK(EloAfter(1500, 1500, true) == 1516);
    CHECK(EloAfter(1500, 1500, false) == 1484);
    CHECK(EloAfter(1500, 2400, true) > 1530);           // beating a far better team pays more
    CHECK(EloAfter(2400, 1500, true) == 2401);           // a win always moves at least 1
    CHECK(EloAfter(2400, 1500, false) < 2370);
    CHECK(EloAfter(5, 3000, false) == 4);                // a loss always moves at least 1
    CHECK(EloAfter(0, 1500, false) == 0);                // never below 0
    // team forming
    using Arena::FormTeams;
    auto t = FormTeams({ 1, 1, 1, 1 }, 2);
    CHECK(t.size() == 2 && t[0] == std::vector<size_t>({ 0, 1 }) && t[1] == std::vector<size_t>({ 2, 3 }));
    t = FormTeams({ 2, 1, 2, 1 }, 2);                    // parties stay whole; the two solos pair up
    CHECK(t.size() == 3);
    t = FormTeams({ 3, 2, 1, 1, 2 }, 3);
    CHECK(t.size() == 3);                                // [0] [1,2] [3,4]
    t = FormTeams({ 4, 1 }, 3);                          // an oversized party never plays
    CHECK(t.empty());
    t = FormTeams({ 2, 2 }, 3);
    CHECK(t.empty());
    t = FormTeams({ 1 }, 1);
    CHECK(t.size() == 1);
    // rating window
    CHECK(Arena::RatingsMeet(1500, 1650, 0));
    CHECK(!Arena::RatingsMeet(1500, 1651, 0));
    CHECK(Arena::RatingsMeet(1500, 1900, 30));
    CHECK(!Arena::RatingsMeet(1500, 3000, 600));         // the window stops widening at 1350
    // time limit
    CHECK(Arena::TimeLimitWinner(0.6f, 0.4f) == 0);
    CHECK(Arena::TimeLimitWinner(0.1f, 0.9f) == 1);
    CHECK(Arena::TimeLimitWinner(0.5f, 0.5f) == 2);
    // bot-fill hours (UTC, "a-b", b exclusive, may wrap)
    CHECK(InHours("0-24", 13));
    CHECK(InHours("", 3));
    CHECK(InHours("2-14", 2));
    CHECK(InHours("2-14", 13));
    CHECK(!InHours("2-14", 14));
    CHECK(!InHours("2-14", 1));
    CHECK(InHours("22-6", 23));
    CHECK(InHours("22-6", 0));
    CHECK(InHours("22-6", 5));
    CHECK(!InHours("22-6", 6));
    CHECK(!InHours("22-6", 12));
    CHECK(InHours("5-5", 9));                            // same start and end: always
    CHECK(InHours("x-y", 9));                            // unreadable: always (the setting is ignored)
    std::printf("%d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
