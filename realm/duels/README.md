# Duels

Quick 1v1 fights in the browser, on a realm of their own: make a level 60 (any race and class), pick a
kit or any gear and enchants, and queue. Matches are best of three rounds in the Ring of Law. **Duel now**
is rated (the ladder); **Practice duel** is not. Guests can play; a saved Hero Key keeps the rating.

| Part | Where | What it does |
|---|---|---|
| World server | `realm/mangos/0021-openvanilla-duels.patch` (on top of Warfront's 0010) | `OpenVanilla.Duels = 1`: 1v1 best of 3, 15 s to prepare, 5 s between rounds, the practice mode `u1`, every finished match logged to `warfront_arena_result` |
| Round rules | `OpenVanilla/DuelsLogic.h` (in 0021); tests `realm/duels/tests/run.sh` | best-of and round outcome, drawn rounds replayed |
| Addon | `Data/Interface/AddOns/Duels` | the Duels panel: rating, Duel now / Practice duel, round score, result, Rematch, live counts; `/duels` |
| Client patch | `patch-Z.MPQ` (here) | Warfront's patch-Z plus the Duels addon (`tools/duels/make_patch_d.py`) |
| Characters SQL | `duels_characters.sql` (here) | the results log table |
| Realm stack | `hetzner/duels_up.sh` | install, update, start, stop, status; timers for the website and the Legends |
| Website | `www/duels.html` | live counts, the ladder (each name opens its Legend), the latest fights, class win rates |
| Legend | `legend/` (`SPEC.md`), `www/legend.html` | every duelist's record signed by the realm, verifiable by anyone |

## Put it live

1. Ship (the realm image workflow builds the world server with 0021).
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
| ☐ | Play free as a guest, make a level 60 | in the world at 60; the Duels window opens; Warfront's kits open on the first login |
| ☐ | Equip a kit | every slot filled and enchanted |
| ☐ | Both press **Practice duel** | the match pops; both land in the Ring of Law; "The gates open in 15 s" |
| ☐ | Fight round 1 | the loser dies; both are put back at their gates, healed, "Round 2" with the score |
| ☐ | Win two rounds | Victory / Defeat with the score (2-0 or 2-1); home after 10 s |
| ☐ | Rematch | queues the same kind of duel again |
| ☐ | **Duel now** from one address on both | never matched (rated duels never pit one address against itself) |
| ☐ | Website | `duels.html` shows the fight in Latest fights within 20 s |
| ☐ | Legend | after a rated duel between two addresses, the ladder name opens `legend.html` with "Verified by duels.openvanilla.app" |

## Settings (mangosd.conf, written by duels_up.sh)

`OpenVanilla.Duels.Rounds` (3), `.PrepSeconds` (15), `.RoundPrepSeconds` (5), `.RoundMinutes` (5), plus
Warfront's: tiers open from the start, no realm bots, rated play never from one address against itself.

## Not yet

- A smaller map than the Ring of Law, and a download of just the arena (the plan:
  `claude/duels-and-arcade-modes-plan.md`, "mode packs").
- A practice bot when nobody else is queued.
- 2v2 and 3v3 with any loadout, Training Grounds, Boss Rush, King of the Hill, the Weekly Cup.
