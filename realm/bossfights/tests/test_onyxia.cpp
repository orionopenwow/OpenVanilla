// The bots' Onyxia geometry (realm/mangos/0059-openvanilla-bots-onyxia.patch, playerbot/strategy/generic/OnyxiaGeometry.h)
// and the bot-raid softening rule (BossFightsLogic.h, BotRaidSofter). Built by run.sh.
#include "OpenVanilla/OnyxiaGeometry.h"
#include "OpenVanilla/BossFightsLogic.h"
#include <cstdio>
#include <cmath>

using namespace ai::onyxia;

static int fails = 0, checks = 0;
#define CHECK(c) do { ++checks; if (!(c)) { ++fails; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #c); } } while (0)

// the eight points Onyxia hovers at in phase 2 (CMaNGOS boss_onyxia.cpp, aMoveData)
static const float AIR[8][2] = {
    { 24.16f, -216.08f }, { 10.22f, -247.91f }, { -15.01f, -244.48f }, { -63.52f, -240.10f },
    { -66.36f, -215.93f }, { -58.25f, -189.02f }, { -16.70f, -181.45f }, { 12.27f, -181.11f } };

int main()
{
    // angles
    CHECK(std::fabs(AngleDiff(0.1f, -0.1f) - 0.2f) < 1e-4f);
    CHECK(std::fabs(AngleDiff(3.0f, -3.0f) - (6.0f - 2.0f * PI_F)) < 1e-4f);
    CHECK(AngleDiff(PI_F, 0.0f) <= PI_F && AngleDiff(PI_F, 0.0f) > -PI_F);

    // Onyxia at the tank spot's foot facing north (+x): in front, behind, at her sides
    float ox = 0.0f, oy = -214.5f, oo = 0.0f;
    CHECK(InBadSpot(ox, oy, oo, 10.0f, -214.5f));          // straight ahead, 10 yd: Flame Breath
    CHECK(InBadSpot(ox, oy, oo, 30.0f, -220.0f));          // ahead, a little off, 30 yd
    CHECK(!InBadSpot(ox, oy, oo, 45.0f, -214.5f));         // ahead but beyond the cone's reach
    CHECK(InBadSpot(ox, oy, oo, -10.0f, -214.5f));         // straight behind: Tail Sweep
    CHECK(InBadSpot(ox, oy, oo, -20.0f, -205.0f));         // behind, a little off
    CHECK(!InBadSpot(ox, oy, oo, -35.0f, -214.5f));        // behind but past the sweep
    CHECK(!InBadSpot(ox, oy, oo, 0.0f, -200.0f));          // her left flank
    CHECK(!InBadSpot(ox, oy, oo, 0.0f, -230.0f));          // her right flank
    CHECK(!InBadSpot(ox, oy, oo, 3.0f, -222.0f));          // right flank, a bit forward (69° off her nose)

    // every flank point is out of the bad spots, both sides, melee and ranged, for any facing
    for (int i = 0; i < 16; ++i)
    {
        float o = i * PI_F / 8.0f;
        for (int side = -1; side <= 1; side += 2)
            for (float d : { 8.0f, 12.0f, 22.0f })
            {
                float x, y;
                FlankPoint(ox, oy, o, side, d, x, y);
                CHECK(!InBadSpot(ox, oy, o, x, y));
                CHECK(std::fabs(Dist(ox, oy, x, y) - d) < 0.01f);
                CHECK(SideOf(ox, oy, o, x, y, 0) == side);
            }
    }

    // side of her: left is positive, the centre line uses the tie
    CHECK(SideOf(ox, oy, oo, 0.0f, -200.0f, -1) == 1);
    CHECK(SideOf(ox, oy, oo, 0.0f, -230.0f, 1) == -1);
    CHECK(SideOf(ox, oy, oo, 10.0f, -214.5f, 1) == 1);
    CHECK(SideOf(ox, oy, oo, 10.0f, -214.5f, -1) == -1);

    // lines
    int s = 0;
    CHECK(std::fabs(LineDistance(0, 0, 10, 0, 5, 3, s) - 3.0f) < 1e-4f && s == 1);
    CHECK(std::fabs(LineDistance(0, 0, 10, 0, 5, -4, s) - 4.0f) < 1e-4f && s == -1);

    // phase 2: from every air point, the middle of the room is in the breath; a spot square to the line,
    // 17 yd out, isn't; the escape spot is out of the line, on the floor and away from the egg tunnels
    int escapes = 0, tries = 0;
    for (auto const& p : AIR)
    {
        CHECK(InBreathLine(p[0], p[1], CENTER_X, CENTER_Y));
        // a grid of floor spots: every spot in the line has an escape, and the escape is safe
        for (float x = CENTER_X - 30.0f; x <= CENTER_X + 30.0f; x += 3.0f)
            for (float y = CENTER_Y - 30.0f; y <= CENTER_Y + 30.0f; y += 3.0f)
            {
                if (Dist(x, y, CENTER_X, CENTER_Y) > FLOOR_RADIUS || NearTunnel(x, y))
                    continue;
                if (!InBreathLine(p[0], p[1], x, y))
                    continue;
                int side = 0;
                LineDistance(p[0], p[1], CENTER_X, CENTER_Y, x, y, side);
                float ex = 0, ey = 0;
                bool ok = BreathEscape(p[0], p[1], x, y, side, ex, ey) || BreathEscape(p[0], p[1], x, y, -side, ex, ey);
                ++tries;
                if (ok)
                {
                    ++escapes;
                    CHECK(!InBreathLine(p[0], p[1], ex, ey));
                    CHECK(Dist(ex, ey, CENTER_X, CENTER_Y) <= FLOOR_RADIUS + 0.01f);
                    CHECK(!NearTunnel(ex, ey));
                    CHECK(Dist(x, y, ex, ey) < 45.0f);          // a short run, not across the room
                }
            }
    }
    CHECK(tries > 100);
    CHECK(escapes == tries);                                    // always somewhere to go

    // the floor clamp
    float cx = CENTER_X + 80.0f, cy = CENTER_Y;
    ClampToFloor(cx, cy);
    CHECK(std::fabs(Dist(cx, cy, CENTER_X, CENTER_Y) - FLOOR_RADIUS) < 0.01f);

    // the tank spot is on the floor, north of the middle, away from the tunnels
    CHECK(Dist(TANK_X, TANK_Y, CENTER_X, CENTER_Y) <= FLOOR_RADIUS);
    CHECK(TANK_X > CENTER_X);
    CHECK(!NearTunnel(TANK_X, TANK_Y));

    // bot-heavy raids (softening applies only when the owner sets it below 1.0)
    using BossFights::BotRaidSofter;
    CHECK(BotRaidSofter(9, 10, 1, 0.5f, 1));
    CHECK(BotRaidSofter(5, 10, 1, 0.5f, 1));
    CHECK(!BotRaidSofter(4, 10, 1, 0.5f, 1));
    CHECK(!BotRaidSofter(9, 10, 2, 0.5f, 1));
    CHECK(BotRaidSofter(9, 10, 3, 0.5f, 5));
    CHECK(!BotRaidSofter(0, 10, 1, 0.0f, 1));
    CHECK(!BotRaidSofter(3, 0, 1, 0.5f, 1));

    std::printf("onyxia: %d checks, %d failed\n", checks, fails);
    return fails ? 1 : 0;
}
