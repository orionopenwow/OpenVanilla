# Warfront — the instant-60 PvP realm

A separate realm stack on the live server (like `devkit/staging`): a **stock 1.12.1 world
database**, the Open Vanilla world server with `OpenVanilla.Warfront = 1`, and the Classic+ addons without
Classic+'s client tables. Everything Warfront adds is off on every other realm.

## What's in it

| Part | Where | What |
|---|---|---|
| World server | `realm/mangos/0010-openvanilla-warfront.patch` (`src/game/OpenVanilla/Warfront*.cpp`, small hooks in the battleground queue, chat and player code) | kits, gear picker, enchants, consumables shop, shared gear sets, first-login welcome, duel resets in the mall, kill-streak bounties, the arena (queues, matchmaking, Ring of Law matches, rating, wintrade rules), mixed-faction battlegrounds, labelled bot fill, live counts |
| Addon | `Data/Interface/AddOns/Warfront` (in patch-Z; inert unless the realm answers `WF 1`) | the Warfront window: Kits, Gear, Shop, Shared sets, Arena; `/wf`, `/kit`, `/arena`; a row in the Classic+ menu |
| World SQL | `warfront_kits.sql`, `warfront_item_pool.sql`, `warfront_world.sql` | 29 kits with enchants, 1,072 pickable items by unlock tier, the shop, capital start, battleground sizes, the hourly Gurubashi chest |
| Characters SQL | `warfront_characters.sql` | welcome flag, account progress, shared sets and votes, arena ratings, the live counts row |
| Client patch | `patch-Z.MPQ` (here) | patch-Z without `DBFilesClient` (stock race/class pairs on the character screen) |
| Setup | `hetzner/warfront_up.sh` | `install`, `update`, `start`, `stop`, `status`, `live`, `herald`; a timer writes the live counts JSON for the website |
| Art wanted | [`ART.md`](ART.md) | the images that would give the window its own look |
| Tests | `devkit/sim/tests/warfront.lua`, `devkit/db/test_warfront_sql.py`, `realm/warfront/tests/`, `devkit/heraldlite/scenarios/warfront_*.txt` | see below |

## Regenerating the data

```
python3 tools/warfront/gen_kits.py items.tsv tools/warfront/out spell_template.tsv   # kits, enchants, shop
cp tools/warfront/out/warfront_kits.sql realm/warfront/; cp tools/warfront/out/WarfrontKits.lua Data/Interface/AddOns/Warfront/
python3 tools/warfront/gen_pool.py <dir of world tables as .tsv> tools/warfront/out/kits.json tools/warfront/out/warfront_item_pool.sql
STORMLIB=/path/libstorm.so python3 tools/warfront/make_patch_w.py                    # after patch-Z changes
```
The `.tsv` files are exported from the world database (`item_template`, `spell_template`, the
loot and spawn tables). `gen_kits.py` refuses to write anything if one item or enchant fails.

## Going live

Warfront is stored and listed as SOON™ for now. The full step-by-step is in [`LAUNCH.md`](LAUNCH.md); in short:

1. Push. CI builds `openvanilla-mangos` with patch 0010 (it applies on 0001–0005 and on 0001–0009).
2. On the server: `bash hetzner/warfront_up.sh install warfront.openvanilla.app` (prints the three
   manual steps: DNS, admin login, Discord redirect).
3. `bash hetzner/warfront_up.sh herald` runs `smoke.txt` + `warfront_smoke.txt` as Herald;
   `warfront_arena.txt` and `warfront_sets.txt` need a second account (`HL_USER2`).
4. `WARFRONT_OPEN = 1` in `www/downloads/links.txt` turns it from SOON™ to Online in the website's realm list.

## Settings (mangosd.conf)

`hetzner/warfront_up.sh` writes these; all are optional (defaults in brackets).

| Key | What |
|---|---|
| `OpenVanilla.Warfront` [0] | the realm is Warfront; everything here is off without it |
| `OpenVanilla.Warfront.CrossFactionBG` [1] | battleground queues mix factions: groups go to the side with fewer players, and a running battle takes whoever waits on its short side. Inside, a player plays as that side (team and faction) and everyone in the battle understands everyone's chat |
| `OpenVanilla.Warfront.BotFill` [1] | realm bots may queue for battlegrounds (with `AiPlayerbot.RandomBotJoinBG`) |
| `OpenVanilla.Warfront.BotFill.Hours` ["0-24"] | UTC hours they may, `a-b`, may wrap past midnight (`22-14`) |
| `OpenVanilla.Warfront.BotFill.Below` [10] | and only while fewer real players than this are in battleground queues |
| `OpenVanilla.Warfront.Arena.SameAddressRated` [0] | 1 lets one network address meet itself in rated arena (test realms only) |
| `OpenVanilla.Warfront.Mall`, `.Tier2/3.Rating/Kills`, `.WelcomeGold` | see `Warfront.h` |

Fair-play rules in rated arena: two characters of one account (or one address) are never on opposite
teams; the same players meeting more than 5 times a day stop counting; a team that leaves in the
first 30 seconds still loses, but the winners gain nothing. A battle with realm bots in it says so to
everyone entering, and bots never make or pay kill streaks.

## Tested in game

A private test realm in the cloud (17 October 2026): CMaNGOS `de8f729` + playerbots `31e0f32` +
patches 0001–0005 and 0010, classic-db `4d230bb` + the Warfront SQL, 1.12 map data, two Herald Lite
bots (Dwarf Hunters on GM accounts), 30 level-60 realm bots for the bot-fill test.

| Scenario | What the bots did | Result |
|---|---|---|
| `smoke.txt` | log in, Open Vanilla hello, wallet | 6/6 |
| `warfront_smoke.txt` | Warfront hello, a kit (16 items, 10 enchants), gear picker, enchant, refusals, shop, arena queue and its locks | 28/28 |
| `warfront_live.txt` | live counts line; a queue shows up in it and leaves it | 17/17 |
| `warfront_streak.txt` | a 7-kill streak ended by a non-player death: no bounty, the zone is told | 17/17 |
| `warfront_sets.txt` | share a set, find it on the other account, vote, apply | 18/18 |
| `warfront_ringoflaw.txt` | rated 1v1: both land in the Ring of Law (gates, 25 yd from the centre), 60 s prep, fight, +13/−13 rating, both sent home | 33/33 (×2 in a row) |
| `warfront_arena.txt` | rated 1v1 where the loser logs out: loss counted, winner +0 (left in the first 30 s), 15 min lock | 20/20 |
| `warfront_crossfaction_bg.txt` | two Alliance characters queue Warsong Gulch: one plays Horde (faction 2), both get their own faction back after | 36/36 (×3 in a row) |
| `warfront_wintrade.txt` | two characters from one address in the rated 1v1 queue are never matched | 21/21 |
| `warfront_botfill.txt` | queue alone off-peak: 11 realm bots fill the battle, the bot line and the system message arrive, the live counts show them | 19/19 |

Bugs the bots found and that are fixed in this patch:
- Kits and the gear picker couldn't equip PvP rank gear (Field Marshal's, Marshal's, the Insignia):
  a kit gave 9 of 16 items. Warfront's tiers now replace the rank requirement.
- After a match, the winner couldn't queue again until the opponent who logged out came back (up
  to 30 minutes). Players are freed as soon as they are home.
- An accepted battleground invite whose port failed left the player in the city with the other
  side's faction (guards would attack). The side only applies on the battleground map now.
- Stock CMaNGOS: a battle that closed stayed in the queue's open-battles list, so the next people
  queued were invited to an instance that no longer existed. Fixed in `BattleGround::StartBattleGround`.

Offline: rule tests 57/57, addon sim 15/15, SQL 34/34 (`test_warfront_sql.py --local`), Herald
Lite tests 96/96. Patch 0010 applies on 0001–0005 and on 0001–0009.

Not covered by bots: 2v2/3v3 with parties, Alterac and Arathi, the Gurubashi chest, mall duel
resets (no duel command in Herald Lite), and how the window looks (section 4b of `LAUNCH.md`).

## Known limits

See `LAUNCH.md`, section 7.
