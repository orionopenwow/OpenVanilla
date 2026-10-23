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
| World SQL | `duels_world.sql`, `duels_lean.sql` | map 900's `instance_template`, every new character starts (and is bound) at Gurubashi Arena, four practice dummies around the pit that never take damage (patch 0040); the lean world: only the arena's spawns, no boats or zeppelins (`LEAN=0` keeps the world) |
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

## The pit (patch 0061)

Everything around the open duels in the hangout, with or without the queue (`OpenVanilla.Duels.Pit = 1`):
every duel there is on the record (wins, losses, streaks, Duel Points; different accounts on different networks,
5 a day against the same opponent), an announcer for streaks and ended streaks, the opponent card, a 3-2-1-FIGHT
countdown and a result card, **winner stays on** (join the line by the minimap, the duel starts by itself), a crowd
in the stands that cheers, the **hourly brawl** (a 3-minute free-for-all, nobody dies, the last one standing wins
Contest Winner's Tabard once), **formal challenges** with Duel Points at stake, the **Weekly Duel Cup** (Saturday
19:00 UTC, sign-ups the hour before, one duel at a time in the pit) and a **sparring dummy** that hits back. The
website's ladder, "The pit now", the cup's bracket and `duels-overlay.html` (a stream overlay) read it from
`duels_live.json`'s `pit`. `bash hetzner/duels_up.sh season NAME` closes a month: titles for the top 10.

| | What (two browsers, two different networks for the record) | What should happen |
|---|---|---|
| ☐ | Arrive | "GURUBASHI ARENA" card and a slow camera turn; The Pit by the minimap with your record |
| ☐ | Duel the other browser (right-click, Duel) | both see the other's card; 3-2-1-FIGHT; then Victory/Defeat with damage, time and +1 DP |
| ☐ | Win 3 in a row | the banner "… is on a streak" for everyone in the arena; the crowd cheers |
| ☐ | Both press **Join the line** | the first holds the pit; the two are put in the middle and the duel starts by itself; the loser goes to the back |
| ☐ | `/duels challenge <name> 1` (both with 1+ DP) | the arena hears the challenge; the duel request goes out; the winner takes the point |
| ☐ | `/duels brawl` with 3 people, wait for the hour | "BRAWL!", everyone in the pit, nobody dies; the last one standing wins the tabard |
| ☐ | Hit the Sparring Dummy | it casts back (kick its heal); stop for 6 s: it whispers your DPS and the casts you stopped |
| ☐ | Website | the ladder says LIVE with your names; "The pit now" shows the line fight within 20 s |

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
- A practice bot when nobody else is queued.
- Spending Duel Points on cosmetics (they are counted and shown; nothing to spend them on yet, never sold).
- 2v2 and 3v3 with any loadout, Training Grounds, Boss Rush.
