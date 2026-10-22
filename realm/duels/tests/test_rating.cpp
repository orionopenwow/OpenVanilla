// Unit tests for Duels' Glicko-2 rating, sudden death and Duel Points (OpenVanilla/DuelsRating.h, from
// realm/mangos/0024-openvanilla-duels-arena.patch).  realm/duels/tests/run.sh builds and runs them.
#include "OpenVanilla/DuelsRating.h"

#include <cmath>
#include <cstdio>

static int g_fail = 0, g_pass = 0;
#define CHECK(cond) do { if (cond) ++g_pass; else { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } } while (0)

static bool Near(double a, double b, double eps) { return std::fabs(a - b) <= eps; }

int main()
{
    using namespace Warfront::Arena;
    Glicko fresh;
    // two new duelists: the winner goes up as much as the loser goes down, both become surer
    Glicko w = GlickoAfter(fresh, fresh, 1.0), l = GlickoAfter(fresh, fresh, 0.0);
    CHECK(w.r > 1500 && l.r < 1500);
    CHECK(Near(w.r - 1500, 1500 - l.r, 0.01));
    CHECK(w.r - 1500 > 100 && w.r - 1500 < 250);        // a new player moves fast (~+162)
    CHECK(w.rd < 350 && l.rd < 350);
    CHECK(Near(w.vol, 0.06, 0.001));
    // a settled duelist moves slowly
    Glicko settled{ 1500, 60, 0.06 };
    Glicko s = GlickoAfter(settled, settled, 1.0);
    CHECK(s.r - 1500 > 2 && s.r - 1500 < 20);
    // beating a much better player is worth more than beating a weaker one
    Glicko strong{ 1900, 80, 0.06 }, weak{ 1100, 80, 0.06 }, mid{ 1500, 80, 0.06 };
    CHECK(GlickoAfter(mid, strong, 1.0).r - 1500 > GlickoAfter(mid, weak, 1.0).r - 1500);
    CHECK(GlickoAfter(mid, weak, 1.0).r - 1500 < 5);      // expected: barely anything
    CHECK(1500 - GlickoAfter(mid, weak, 0.0).r > 30);     // an upset loss costs
    // a draw between equals changes nothing
    CHECK(Near(GlickoAfter(mid, mid, 0.5).r, 1500, 0.01));
    // the deviation never goes under the floor, the rating never under 0
    Glicko floor = settled;
    for (int i = 0; i < 300; ++i)
        floor = GlickoAfter(floor, mid, i % 2 ? 1.0 : 0.0);
    CHECK(floor.rd >= GLICKO_MIN_RD - 1e-9);
    Glicko low{ 50, 350, 0.06 };
    for (int i = 0; i < 20; ++i)
        low = GlickoAfter(low, strong, 0.0);
    CHECK(low.r >= 0);
    CHECK(std::isfinite(low.r) && std::isfinite(low.rd) && std::isfinite(low.vol));
    // Glickman's worked example (2013), one game of the three: 1500/200 beats 1400/30
    Glicko g = GlickoAfter(Glicko{ 1500, 200, 0.06 }, Glicko{ 1400, 30, 0.06 }, 1.0);
    CHECK(g.r > 1560 && g.r < 1580);

    // sudden death
    CHECK(SuddenDeathStacks(0, 0, 15000, 10) == 0);              // off
    CHECK(SuddenDeathStacks(179999, 180000, 15000, 10) == 0);
    CHECK(SuddenDeathStacks(180000, 180000, 15000, 10) == 1);
    CHECK(SuddenDeathStacks(194999, 180000, 15000, 10) == 1);
    CHECK(SuddenDeathStacks(195000, 180000, 15000, 10) == 2);
    CHECK(SuddenDeathStacks(10000000, 180000, 15000, 10) == 10);
    CHECK(Near(SuddenDeathDamageTaken(0), 1.0, 1e-6));
    CHECK(Near(SuddenDeathDamageTaken(3), 1.3, 1e-6));
    CHECK(Near(SuddenDeathHealingTaken(2), 0.7, 1e-6));
    CHECK(SuddenDeathHealingTaken(7) == 0.0f);
    CHECK(SuddenDeathHealingTaken(10) == 0.0f);

    // Duel Points
    CHECK(DuelPoints(true, 0) == 25);
    CHECK(DuelPoints(true, 2) == 25);
    CHECK(DuelPoints(true, 3) == 35);
    CHECK(DuelPoints(false, 9) == 5);

    std::printf("%d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
