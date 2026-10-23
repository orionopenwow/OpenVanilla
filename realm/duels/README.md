# Duels

Quick 1v1 fights in the browser, on a realm of their own. The player's path:

1. **DUELS** in the site's header (`duels.html?go=1`), or **Duel now** on `duels.html` (a class can be picked).
2. **Sign in, or already signed in**: the Duels realm's own sign-in; *Play now, free* makes a guest at once (a
   saved Hero Key keeps the rating).
3. **Straight into the world** (`?duel=1`, realm patch 0035): no character screen. The account's duel body is
   entered, or made on the spot (level 60, a generated name, the race and class asked for or any).
4. **Gurubashi Arena in Stranglethorn, with everyone**: the hangout (the open-world pit and stands; free-for-all PvP is switched off there). Both factions friendly, chat across
   factions, a practice dummy by the fire; nobody walks out (a fence puts you back).
5. **Queued by itself** after 4 idle seconds (rated, `d1`). The match pops: **Gurubashi Arena**, a copy of it
   per match (map 900). Best of three rounds; sudden death after 3 minutes in a round; potions and
   bandages topped up every round.
6. **Back to the arena's stands**, and into the queue again (unless you left the queue, or `/duels auto off`).

Anyone in the hangout can **watch** a fight from the stands, invisible and untouchable: **Watch a fight** in the
Duels window, or `/duels fights` and `/duels watch <number>`. **Practice duel** (`u1`) is unrated.

| Part | Where | What it does |
|---|---|---|
| World server | `realm/mangos/0021-openvanilla-duels.patch` (on top of Warfront's 0010) | `OpenVanilla.Duels = 1`: 1v1 best of 3, 15 s to prepare, 5 s between rounds, the practice mode `u1`, every finished match logged to `warfront_arena_result` |
| World server | `realm/mangos/0024-openvanilla-duels-arena.patch` | Gurubashi Arena (map 900, a copy per match, fenced), Gurubashi Arena as the hangout (kept there, no free-for-all, both factions friendly, auto-queue), spectating, sudden death, round consumables, Glicko-2 and Duel Points, `duels_now` for the website. Each part is a setting; all off unless set, so Warfront and live are unchanged |
| Round rules | `OpenVanilla/DuelsLogic.h` (0021), `OpenVanilla/DuelsRating.h` (0024); tests `realm/duels/tests/run.sh` | best-of and round outcome, drawn rounds replayed; Glicko-2, sudden-death stacks, Duel Points |
| Gurubashi Arena's map | `tools/duels/arena_map.py`, run by `duels_up.sh` (`arena_map`) | map 900 in the server's Map.dbc, map 0's maps/vmaps/mmaps linked as map 900's, and Map.dbc and Light.dbc with map 900 in the realm's served patch-Z. Made on the server from its own files: never committed |
| Straight in | `realm/patches/0035-openvanilla-duels-straight-in.patch` | `?duel=1` / `?duel=orc-warrior`: no character screen; the duel body is entered or made |
| World SQL | `duels_world.sql`, `duels_lean.sql` | map 900's `instance_template`, every new character starts (and is bound) at Gurubashi Arena, two practice dummies at the pit's edge; the lean world: only the arena's spawns, no boats or zeppelins (`LEAN=0` keeps the world) |
| Addon | `Data/Interface/AddOns/Duels` | the Duels panel: rating, Duel now / Practice duel, round score, result, Rematch, live counts; `/duels` |
| Client patch | `patch-Z.MPQ` (here) | Warfront's patch-Z plus the Duels addon (`tools/duels/make_patch_d.py`) |
| Characters SQL | `duels_characters.sql` (here) | the results log; Glicko-2's `rd`/`vol`; `duels_player` (Duel Points, streaks, auto-queue); `duels_now` (the fights now) |
| Realm stack | `hetzner/duels_up.sh` | install, update, start, stop, status; timers for the website and the Legends |
| Website | `www/duels.html`, the header's DUELS (`www/index.html`) | live counts, the ladder with Duel Points and streaks (each name opens its Legend), the fights now, the latest fights, class win rates; `?go=1` goes straight on to the realm |
| Legend | `legend/` (`SPEC.md`), `www/legend.html` | every duelist's record signed by the realm, verifiable by anyone |

## Put it live

1. Ship (the realm image workflow builds the world server with 0021 and 0024, the web service with 0035).
2. On the server: `bash /opt/openvanilla-classicplus/repo/hetzner/duels_up.sh install duels.openvanilla.app`.
   It refuses to start with less than about 2.3 GB of memory free (the 4 GB server already runs the live
   realm): resize to 8 GB first, or `FORCE=1` to try anyway.
3. DNS: an A record for `duels.openvanilla.app` to the server's address.
4. `https://duels.openvanilla.app/setup`: the admin login (the install prints the setup token).
5. Smoke test (below). Then `DUELS_OPEN = test` (playable, marked testing) or `1` in `www/downloads/links.txt`.

After the first install, `bash hetzner/duels_up.sh update` brings new files, SQL and settings.

## Smoke test

Two browsers (or one normal and one private window), both on `https://duels.openvanilla.app`:

| | What | What should happen |
|---|---|---|
| ☐ | `https://duels.openvanilla.app/?duel=1`, *Play now, free* | no character screen: in Gurubashi Arena at 60; the Duels window opens; Warfront's kits open on the first login |
| ☐ | Walk out of the arena's gate and on | put back in the pit past 75 yards |
| ☐ | Equip a kit | every slot filled and enchanted |
| ☐ | Wait 4 s in the hangout, in both browsers | both queued by themselves ("Looking for an opponent"); a rated pair from one address never meets, so for one machine use **Practice duel** in both (or `SameAddressRated=1` for the test) |
| ☐ | The match pops | both in Gurubashi Arena's pit, on the sand, facing each other; "The gates open in 15 s" |
| ☐ | Run out of the pit | put back at your gate |
| ☐ | A third browser in the hangout: **Watch a fight** | in the stands, unseen; the window keeps the score; back to the hangout when it ends |
| ☐ | Fight round 1 | the loser dies; both are put back at their gates, healed, "Round 2" with the score |
| ☐ | Fight over 3 minutes in a round | "Sudden death" toast; the window shows the stacks |
| ☐ | Win two rounds | Victory / Defeat with the score (2-0 or 2-1) and the Duel Points (rated); back in the hangout after 10 s, queued again 4 s later |
| ☐ | Rematch | queues the same kind of duel again |
| ☐ | **Duel now** from one address on both | never matched (rated duels never pit one address against itself) |
| ☐ | Website | `duels.html` shows the fight in Latest fights within 20 s |
| ☐ | Legend | after a rated duel between two addresses, the ladder name opens `legend.html` with "Verified by duels.openvanilla.app" |

## Settings (mangosd.conf, written by duels_up.sh)

`OpenVanilla.Duels.Rounds` (3), `.PrepSeconds` (15), `.RoundPrepSeconds` (5), `.RoundMinutes` (5),
`.SuddenDeathSeconds` (180), `.Arena` (gurubashi) and `.Arena.Map` (900), `.Hub` and `.Hub.Fence` (Gurubashi Arena),
`.AutoQueue` (d1), `.Consumables` (healing and mana potions, bandages), `.Glicko` (1); `Instance.UnloadDelay`
one minute; both factions talk, group and trade; plus Warfront's: tiers open from the start, no realm bots,
rated play never from one address against itself. The bot AI and the auction-house bot are off
(`aiplayerbot.conf`, `ahbot.conf`). A `*.before-duels` copy of each file is kept.

After a live realm update that brought new maps: `bash hetzner/duels_up.sh arena`, then `update`.

## Not yet

- Mode packs: a download of just the inn's tile and the arena (the plan:
  `claude/duels-and-arcade-modes-plan.md`). Today the browser streams those tiles like any other.
- Spectating from the website (the "Fights now" list is there; watching is in game), a free camera for
  spectators, an HTML countdown over the game.
- A practice bot when nobody else is queued; a dummy that hits back.
- Spending Duel Points on cosmetics (they are counted and shown; nothing to spend them on yet, never sold).
- 2v2 and 3v3 with any loadout, Training Grounds, Boss Rush, King of the Hill, the Weekly Cup.
