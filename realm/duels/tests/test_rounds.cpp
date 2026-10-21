// Unit tests for Duels' round rules (OpenVanilla/DuelsLogic.h, from realm/mangos/0021-openvanilla-duels.patch).
//   realm/duels/tests/run.sh builds and runs them; no server needed.
#include "OpenVanilla/DuelsLogic.h"

#include <cstdio>

static int g_fail = 0, g_pass = 0;
#define CHECK(cond) do { if (cond) ++g_pass; else { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } } while (0)

int main()
{
    using namespace Warfront::Arena;
    // best-of settings
    CHECK(RoundsBestOf(0) == 1);
    CHECK(RoundsBestOf(1) == 1);
    CHECK(RoundsBestOf(2) == 3);
    CHECK(RoundsBestOf(3) == 3);
    CHECK(RoundsBestOf(4) == 5);
    CHECK(RoundsBestOf(7) == 7);
    CHECK(RoundsBestOf(50) == 7);
    // best of 3
    CHECK(RoundOutcome(0, 0, 3, 0) == -1);
    CHECK(RoundOutcome(1, 0, 3, 1) == -1);
    CHECK(RoundOutcome(2, 0, 3, 2) == 0);
    CHECK(RoundOutcome(0, 2, 3, 2) == 1);
    CHECK(RoundOutcome(1, 1, 3, 2) == -1);
    CHECK(RoundOutcome(2, 1, 3, 3) == 0);
    CHECK(RoundOutcome(1, 2, 3, 3) == 1);
    // drawn rounds are replayed, up to 2 x best-of rounds
    CHECK(RoundOutcome(1, 1, 3, 3) == -1);
    CHECK(RoundOutcome(1, 1, 3, 5) == -1);
    CHECK(RoundOutcome(1, 1, 3, 6) == 2);
    CHECK(RoundOutcome(1, 0, 3, 6) == 0);
    CHECK(RoundOutcome(0, 1, 3, 6) == 1);
    CHECK(RoundOutcome(0, 0, 3, 6) == 2);
    // best of 1 and 5
    CHECK(RoundOutcome(1, 0, 1, 1) == 0);
    CHECK(RoundOutcome(0, 0, 1, 1) == -1);
    CHECK(RoundOutcome(0, 0, 1, 2) == 2);
    CHECK(RoundOutcome(2, 2, 5, 4) == -1);
    CHECK(RoundOutcome(3, 2, 5, 5) == 0);
    std::printf("%d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
