// The Duels pit's rules (OpenVanilla/DuelsPitLogic.h, realm/mangos/0061-openvanilla-duels-pit.patch): streak calls,
// the crowd, counted wins, winner stays on, the brawl and cup clocks, the cup's bracket.
#include "OpenVanilla/DuelsPitLogic.h"
#include <cstdio>
#include <set>

using namespace DuelsPitLogic;
static int fails = 0;
#define CHECK(c, what) do { if (!(c)) { std::printf("FAIL %s\n", what); ++fails; } else std::printf("ok   %s\n", what); } while (0)

int main()
{
    CHECK(!CallStreak(1) && !CallStreak(2) && CallStreak(3) && !CallStreak(4) && CallStreak(5), "streaks called at 3 and 5");
    CHECK(CallStreak(10) && !CallStreak(11) && CallStreak(15) && CallStreak(40), "then 10 and every 5");
    CHECK(!CallEnded(2) && CallEnded(3), "an ended streak of 3+ is called");
    CHECK(Cheering(0, 0, 16) == 3 && Cheering(10, 0, 16) == 16 && Cheering(1, 4, 6) == 6, "the crowd cheers louder, never more than it has");

    Matchups m;
    std::time_t t = 1792700000;
    int counted = 0;
    for (int i = 0; i < 8; ++i) counted += m.Count(1, 2, t) ? 1 : 0;
    CHECK(counted == 5, "5 wins a day against the same opponent count");
    CHECK(m.Count(2, 1, t), "the other way round is its own count");
    CHECK(m.Count(1, 3, t), "another opponent counts");
    CHECK(m.Count(1, 2, t + 86400), "a new day counts again");

    Line l;
    CHECK(l.Next() == std::make_pair(0u, 0u), "an empty line: nobody fights");
    l.Join(10);
    CHECK(l.Next() == std::make_pair(0u, 0u) && l.champion == 10, "alone in line: you hold the pit, nobody to fight");
    CHECK(!l.Join(10), "the champion can't join again");
    l.Join(20); l.Join(30);
    CHECK(!l.Join(20), "nobody is in line twice");
    CHECK(l.Next() == std::make_pair(10u, 20u), "the champion against the first in line");
    CHECK(l.Place(20) == 1 && l.Place(30) == 2 && l.Place(99) == 0, "places in line");
    uint32_t ended = l.Result(10, 20, true);
    CHECK(ended == 0 && l.champion == 10 && l.streak == 1, "the champion wins: streak 1");
    CHECK(l.Place(30) == 1 && l.Place(20) == 2, "the loser goes to the back");
    CHECK(l.Next() == std::make_pair(10u, 30u), "next challenger");
    l.Result(10, 30, false);
    CHECK(l.streak == 2 && !l.Has(30), "a loser who leaves is out");
    l.Join(40); l.Join(50);
    CHECK(l.Next() == std::make_pair(10u, 20u), "20 is next again");
    ended = l.Result(20, 10, true);
    CHECK(ended == 2 && l.champion == 20 && l.streak == 1 && l.Place(10) == 3, "the challenger ends a 2 streak and holds the pit");
    l.Skip(40);
    CHECK(l.Place(40) == 3, "a no-show goes to the back");
    l.Skip(40); l.Skip(40);
    CHECK(!l.Has(40), "and is out after three misses");
    l.Leave(20);
    CHECK(l.champion == 0 && l.streak == 0, "the champion leaves: the pit is free");
    CHECK(l.Next().first == 50 || l.Next().first == 10, "the first in line takes it");

    CHECK(SecondsToBrawl(3600 * 5, 60) == 0, "on the hour: brawl now");
    CHECK(SecondsToBrawl(3600 * 5 + 59 * 60, 60) == 60, "a minute before the hour");
    CHECK(SecondsToBrawl(3600 * 5 + 10, 30) == 1790, "every 30 minutes");

    // 2026-10-24 is a Saturday; 19:00 UTC that day
    std::time_t sat = 1792800000 - (1792800000 % 86400);   // some midnight
    long wd = (sat / 86400 + 4) % 7;
    std::time_t thatSat = sat + (6 - wd) * 86400;
    CHECK(SecondsToCup(thatSat + 18 * 3600, 6, 19) == 3600, "an hour before the Saturday cup");
    CHECK(SecondsToCup(thatSat + 19 * 3600 + 5, 6, 19) == -5, "5 s after it started");
    CHECK(WeekOf(thatSat) == WeekOf(thatSat + 86400 - 1) && WeekOf(thatSat - 5 * 86400) == WeekOf(thatSat) && WeekOf(thatSat - 6 * 86400) == WeekOf(thatSat) - 1, "the week runs Monday to Sunday");
    CHECK(WeekOf(thatSat + 2 * 86400) == WeekOf(thatSat) + 1, "Monday is a new week");

    for (int n : { 1, 2, 3, 5, 8, 13 })
    {
        Bracket b;
        std::vector<uint32_t> e;
        for (int i = 1; i <= n; ++i) e.push_back(uint32_t(i));
        b.Start(e);
        int fights = 0;
        std::set<uint32_t> out;
        while (!b.Champion() && fights < 100)
        {
            Bracket::Fight* f = b.Next();
            if (!f) break;
            uint32_t w = f->a < f->b ? f->a : f->b;   // the lower number always wins
            out.insert(f->a == w ? f->b : f->a);
            b.Result(w);
            ++fights;
        }
        char what[80];
        std::snprintf(what, sizeof(what), "%d entrants: %d fights, champion 1", n, n - 1);
        CHECK(b.Champion() == 1 && fights == n - 1 && out.size() == size_t(n - 1), what);
    }
    {
        Bracket b;
        b.Start({ 7, 8, 9 });
        CHECK(b.Next()->a == 7 && b.Next()->b == 8, "the first fight is the first two");
        b.Result(8);
        CHECK(b.Round() == 2 && b.Next() && b.Next()->a == 8 && b.Next()->b == 9, "9 had a bye: final 8 against 9");
        b.Result(9);
        CHECK(b.Champion() == 9, "9 wins the cup");
    }
    CHECK(Clean("a,b;c|d'e") == "a b c d e", "separators come out of names");
    CHECK(Clean("abcdef", 3) == "abc", "and long ones are cut");

    std::printf(fails ? "%d FAILED\n" : "all ok\n", fails);
    return fails ? 1 : 0;
}
