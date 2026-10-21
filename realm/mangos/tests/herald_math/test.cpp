// Open Vanilla: tests for Herald's pull decision numbers (playerbot/HeraldMath.h, patch 0020).
//   g++ -std=c++17 -I <PlayerBots dir> herald_math_test.cpp -o t && ./t
#include "playerbot/HeraldMath.h"
#include <cstdio>
#include <cstdlib>

using namespace HeraldBrain;
static int fails = 0;
#define CHECK(c, what) do { if (!(c)) { std::printf("FAIL %s\n", what); ++fails; } else std::printf("ok   %s\n", what); } while (0)

int main()
{
    // a level-10 character: about 300 health, the seed damage for his level, 400 armor
    float hp = 300.0f, dps = SeedDps(10);
    float dr = ArmorReduction(400.0f, 10);
    Foe mob{ 300.0f, MobDps(10, false) * (1.0f - dr) };
    Foe elite{ 900.0f, MobDps(10, true) * (1.0f - dr) };

    CHECK(dps > 12.0f && dps < 18.0f, "seed damage at 10 is a leveling character's (12-18)");
    CHECK(SeedDps(60) > 140.0f && SeedDps(60) < 200.0f, "seed damage at 60 is 140-200");
    CHECK(dr > 0.2f && dr < 0.3f, "400 armor against a level-10 mob takes off 20-30%");
    CHECK(ArmorReduction(1e9f, 60) <= 0.75f, "armor never takes off more than 75%");

    Outlook one = Predict(hp, hp, dps, { mob }, 1.0f);
    CHECK(one.endHealthPct > 0.5f, "one mob of his level: he ends above half health");
    CHECK(one.endHealthPct >= MinEndHealth(false, false, 1), "one mob of his level is worth it even with no way out");

    Outlook two = Predict(hp, hp, dps, { mob, mob }, 1.0f);
    CHECK(two.endHealthPct < MinEndHealth(true, true, 1), "two mobs at once at level 10 is too much alone");
    Outlook twoGroup = Predict(hp, hp, dps * 1.8f, { mob, mob }, 0.5f);
    CHECK(twoGroup.endHealthPct >= MinEndHealth(false, false, 2), "but fine for two Heralds together");

    Outlook el = Predict(hp, hp, dps, { elite }, 1.0f);
    CHECK(el.endHealthPct < 0.1f, "an elite of his level would kill him alone");

    Outlook pet = Predict(hp, hp, dps, { mob, mob }, 0.6f);
    CHECK(pet.endHealthPct > two.endHealthPct, "a pet that tanks makes the same fight safer");

    Outlook hurt = Predict(hp * 0.5f, hp, dps, { mob }, 1.0f);
    CHECK(hurt.endHealthPct < one.endHealthPct - 0.4f, "starting at half health ends half a bar lower");

    // order: lowest health first is never worse than the other order
    Foe weak{ 100.0f, 5.0f }, strong{ 400.0f, 5.0f };
    Outlook a = Predict(hp, hp, dps, { weak, strong }, 1.0f), b = Predict(hp, hp, dps, { strong, weak }, 1.0f);
    CHECK(a.damageTaken == b.damageTaken, "the order foes come in doesn't matter (sorted inside)");

    // the risk budget: more ways out, more risk allowed; never below 10%
    CHECK(MinEndHealth(true, true, 1) < MinEndHealth(true, false, 1), "escape + potion allows more than escape alone");
    CHECK(MinEndHealth(false, false, 1) == 0.30f, "no way out: keep 30%");
    CHECK(MinEndHealth(true, true, 5) >= 0.10f, "never plans to end below 10%");

    // nothing to fight / no damage: no crash, no change
    Outlook none = Predict(hp, hp, dps, {}, 1.0f);
    CHECK(none.endHealthPct == 1.0f && none.damageTaken == 0.0f, "no foes: full health");
    CHECK(Predict(hp, hp, 0.0f, { mob }, 1.0f).damageTaken == 0.0f, "zero damage per second doesn't divide by zero");

    std::printf("%s (%d failed)\n", fails ? "FAILED" : "PASSED", fails);
    return fails ? 1 : 0;
}
