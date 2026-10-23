// Open Vanilla 0063: the bots' Onyxia tactics, round 2: the pure parts (OnyxiaGeometry.h).
//   g++ -std=c++17 -I<dir with OnyxiaGeometry.h> test_onyxia2.cpp -o t && ./t
#include "OnyxiaGeometry.h"
#include <cstdio>
#include <cmath>

using namespace ai::onyxia;

static int fails = 0, checks = 0;
#define CHECK(c, what) do { ++checks; if (!(c)) { ++fails; std::printf("FAIL %s (line %d)\n", what, __LINE__); } } while (0)

// the eight air points (her spot in phase 2)
static float const AIR[8][2] = { { 24.2f, -216.1f }, { 10.2f, -247.9f }, { -15.0f, -244.5f }, { -63.5f, -240.1f },
                                 { -66.4f, -215.9f }, { -58.3f, -189.0f }, { -16.7f, -181.5f }, { 12.3f, -181.1f } };

int main()
{
    // 1. nobody within 8 yards: no step
    {
        float nx[1] = { -21.6f + 20.0f }, ny[1] = { -214.5f };
        float x, y;
        CHECK(!SpreadPoint(24.2f, -216.1f, -21.6f, -200.0f, nx, ny, 1, 1, x, y), "no neighbour close: stays");
    }
    // 2. for every air point, a bot at many spots on the floor with a neighbour 3 yards away steps to a spot that is
    //    farther from that neighbour, inside the floor, away from the tunnels and off the breath line
    int stepped = 0, stuck = 0;
    for (int a = 0; a < 8; ++a)
        for (float px = CENTER_X - 30.0f; px <= CENTER_X + 30.0f; px += 5.0f)
            for (float py = CENTER_Y - 30.0f; py <= CENTER_Y + 30.0f; py += 5.0f)
            {
                if (Dist(px, py, CENTER_X, CENTER_Y) > FLOOR_RADIUS - 2.0f || NearTunnel(px, py))
                    continue;
                if (InBreathLine(AIR[a][0], AIR[a][1], px, py))
                    continue;           // the breath dodge comes first there
                for (int k = 0; k < 4; ++k)
                {
                    float ang = k * PI_F / 2.0f;
                    float nx[1] = { px + 3.0f * std::cos(ang) }, ny[1] = { py + 3.0f * std::sin(ang) };
                    float x, y;
                    if (!SpreadPoint(AIR[a][0], AIR[a][1], px, py, nx, ny, 1, 1, x, y))
                    {
                        ++stuck;
                        continue;
                    }
                    ++stepped;
                    CHECK(Dist(x, y, nx[0], ny[0]) > 3.0f, "farther from the neighbour");
                    CHECK(Dist(x, y, CENTER_X, CENTER_Y) <= FLOOR_RADIUS + 0.01f, "inside the floor");
                    CHECK(!NearTunnel(x, y), "away from the tunnels");
                    CHECK(!InBreathLine(AIR[a][0], AIR[a][1], x, y), "off the breath line");
                }
            }
    CHECK(stepped > 0, "some steps found");
    CHECK(stuck * 10 < stepped, "a safe step almost everywhere");
    // 3. two bots on the same spot: the tie sends them to opposite sides
    {
        float nx[1] = { -21.6f }, ny[1] = { -200.0f };
        float x1, y1, x2, y2;
        bool a = SpreadPoint(24.2f, -216.1f, -21.6f, -200.0f, nx, ny, 1, 1, x1, y1);
        bool b = SpreadPoint(24.2f, -216.1f, -21.6f, -200.0f, nx, ny, 1, -1, x2, y2);
        CHECK(a && b, "on top of each other: both step");
        if (a && b)
            CHECK(Dist(x1, y1, x2, y2) > 8.0f, "to opposite sides");
    }
    // 4. the off-tank's waiting spot: 20 yards out of the nearer tunnel, toward the middle, on the floor
    {
        float x, y;
        WhelpWaitPoint(-30.0f, -240.0f, x, y);
        CHECK(std::fabs(Dist(x, y, TUNNEL_A_X, TUNNEL_A_Y) - WHELP_MOUTH) < 0.01f, "tunnel A: 20 yards out");
        CHECK(Dist(x, y, CENTER_X, CENTER_Y) < FLOOR_RADIUS, "tunnel A: on the floor");
        CHECK(!NearTunnel(x, y), "tunnel A: outside the keep-away");
        WhelpWaitPoint(-30.0f, -190.0f, x, y);
        CHECK(std::fabs(Dist(x, y, TUNNEL_B_X, TUNNEL_B_Y) - WHELP_MOUTH) < 0.01f, "tunnel B: 20 yards out");
        CHECK(Dist(x, y, CENTER_X, CENTER_Y) < FLOOR_RADIUS, "tunnel B: on the floor");
    }
    // 5. the hold as she lands: 5 s always, then until her target is a tank, never past 10 s
    CHECK(HoldDamage(0, true), "just landed: hold");
    CHECK(HoldDamage(4999, true), "4.9 s: hold");
    CHECK(!HoldDamage(5000, true), "5 s with the tank on her: go");
    CHECK(HoldDamage(7000, false), "7 s, not on a tank: hold");
    CHECK(!HoldDamage(10000, false), "10 s: go anyway");
    CHECK(!HoldDamage(0xFFFFFFFFu, true), "never landed: no hold");

    std::printf("%d checks, %d failed\n", checks, fails);
    return fails ? 1 : 0;
}
