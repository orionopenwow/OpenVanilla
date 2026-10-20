# Vanilla Remastered pace

Less waiting, same world: kill XP, mob difficulty and loot tables are untouched. Three parts, each
with its own undo:

| Part | File | Undo |
|---|---|---|
| World data | `classicplus_pace.sql` (backs every value up in `openvanilla_pace_backup`) | `classicplus_pace_rollback.sql` |
| Rates and switches | `openvanilla_gameplay_conf.sh` (writes `mangosd.conf`) | `bash openvanilla_gameplay_conf.sh rollback` |
| World server code | `../mangos/0013-openvanilla-pace.patch` (`src/game/OpenVanilla/Pace.*`, `TrainingDummy.cpp`) | every `OpenVanilla.Pace.*` switch off (the default) |

`hetzner/openvanilla_realm_up.sh` applies the first two on every realm update; the patch arrives
with the next realm image (`realm-image` workflow).

## The rules

| Rule | How |
|---|---|
| Quest items always drop | every quest-only creature drop under 100% is 100% (1,918 drops) |
| Shared quest drops | those items are party loot: each group member on the quest gets their own (418 items newly flagged) |
| Quest XP x1.5, kills x1 | `Rate.XP.Quest = 1.5`, `Rate.XP.Kill = 1`; the gentler XP curve is gone (`classicplus_xp_rollback.sql`) |
| Veteran Mentor | +20% quest XP per other level-60 character on the account, up to 3 (+60%); told at login (`MentorBonus 0.20`, `MentorMax 3`) |
| Rested x5 at inns and capitals | `Rate.Rest.InGame` and `Rate.Rest.Offline.InTavernOrCity = 5`: a full bar in about 2 days (stock: 10). Rested still doubles kill XP; logged out in the wild stays 1.25 |
| Campfire rest | out of combat within 15 yd of any cooking fire (world campfires or Basic Campfire), rested builds at the inn's stock rate (`CampfireRest 1`) |
| Flights x2 | `FlightSpeed 2` (32 → 64 yd/s) |
| Flight paths by level | at 10, 20, ... 60 you learn every flight path of your faction (and neutral ones) whose zone is at or below that level; at login too (`FlightUnlockStep 10`) |
| Hearthstone 15 min | spell 8690 category cooldown 3,600,000 → 900,000 ms |
| Blessings 15 min | the single-target Blessings (Might, Wisdom, Kings, Salvation, Light, Sanctuary; 22 ranks) use the Greater Blessings' duration. Shaman weapon imbues already last 30 min in 1.12.1 |
| Weapon skill x4 | `SkillGain.Weapon = 4` |
| Exploration scales | a new area gives at least 1% of the XP your level needs (stock gives a small fixed amount); grey areas keep the stock falloff (`ExploreXpPct 1`) |
| No abandon penalty | abandoning a quest that a dropped item started gives the item back (`AbandonReturnsItem 1`) when it can't be farmed: it sells for nothing, it's soulbound or a quest item, and no NPC or object also starts the quest (so no Darkmoon-deck gold loop); scripted escort givers (Kernobee, Willix, Belnistrasz, Windsor...) are back 60 s after a failed escort instead of up to 24 h (67 spawns) |
| Dungeon dispatch boards | a board 3 yd inside every entrance of the 19 dungeons (31 boards) gives and takes every quest sorted under that dungeon that someone in the world gives; prerequisites, races and levels still apply. Quests only an item starts stay with the item |
| Training dummies | Level 60, Level 50 and Your level dummies 5 yd in front of the weapon master in Stormwind, Ironforge, Darnassus, Orgrimmar, Thunder Bluff and the Undercity. They never attack or die; stop hitting for 6 s and they whisper damage, time, hits and DPS. "Your level" takes your level and that level's armor |

## Tooltips and timers

The 1.12 client words tooltips and times cooldowns from its own `Spell.dbc`, which Open Vanilla does
not ship (Blizzard data). So the realm tells the addons its real numbers instead, read from its
world database once the addons greet it: `PZ <hearthstone cooldown ms>,<Blessing duration ms>`
(patch 0013). `WenillaCore/Pace.lua` then, only if they differ from 1.12's:

- Blessing tooltips (spellbook, action bar, buffs) say "15 min", and Essentials' timers on other
  players' Blessings count 15 minutes;
- the Hearthstone's "Cooldown remaining", its cooldown spiral in bags and on action bars, and
  Essentials' cooldown numbers count the realm's 15 minutes from when it was used;
- when the 15 minutes are up the realm clears the cooldown on the client (`SMSG_CLEAR_COOLDOWN`),
  so the client lets you use it at once.

The Quests addon's XP per quest (the `QM` line) includes `Rate.XP.Quest` and the Veteran Mentor
bonus, so it matches what the turn-in gives. Tests: `devkit/sim/tests/pace.lua`.

## IDs and placement

Boards 990701-990719 (spawns 9100701-9100760), dummies 990801-990803 (spawns 9100801-9100818).
Boards stand at each instance entrance's arrival point plus 3 yd; dummies stand in a row beside each
weapon master at the same height. Both are computed from existing data, so walk past them once on
the test realm: if one sits in a wall, adjust its row in `creature` / `gameobject` and the matching
offset in `classicplus_pace.sql`.

## Tested

- Patch 0013 applies on 0001-0012 at the pinned CMaNGOS commit (de8f729, wenilla-realm's
  `upstreams.env`); every changed file compiles (GCC, Release) with the other patches applied.
- `classicplus_pace.sql` ran twice on a full classic-db 4d230bb in MariaDB 10.11 (about 40 s);
  the rollback then left all nine touched tables byte-identical to a fresh copy (`CHECKSUM TABLE`).
- `openvanilla_gameplay_conf.sh` apply → rollback → apply on CMaNGOS's stock `mangosd.conf`: one
  line per key, the values above.
- Not yet tested in game: flights, campfire rest, the mentor message, the dummies' whisper, the
  boards' placement, and the Hearthstone cooldown on a real 1.12 client. Do that on a test realm before the live one.
