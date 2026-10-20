# Achievements protocol (`AC`)

Achievements are **server-authoritative**: the world server (`src/game/OpenVanilla/Achievements.cpp`,
pending patch `realm/mangos/pending/0002-openvanilla-achievements.patch`) decides what a character has
earned, stores it, and tells the Achievements addon. The client never grants anything, so an
achievement can't be faked by editing SavedVariables or sending commands. Achievements give
points and recognition only, never power: nothing here touches items, stats, spells or gold.

Transport is the existing WNL channel (see `OpenVanilla/Wnl.h`): every line is an addon message the
player sends to themself, `WNL\tAC <seq> <i>/<n> <part>`, chunked at 200 bytes and reassembled by
WenillaCore. The server greets with `HI 1 ...,Achievements` (the `Achievements` entry tells the
addon this realm keeps them). Nothing is sent before the client has answered `.wnl hi`.

Bodies use `;` between records and `,` between fields. Dates are Unix seconds (UTC). Names never
contain `,` `;` `|` or tabs (the server replaces them with spaces).

## Server → client

| Packet | Body | When |
|---|---|---|
| `L` | `L <id>,<date>;<id>,<date>;...` (empty list: `L`) | the full earned list: after every `.wnl hi`, and in answer to `.wnl ac list`. Replaces the client's list. |
| `E` | `E <id>,<date>[;<id>,<date>...]` | just earned (the client shows the banner). Metas earned by the same event come in the same packet. |
| `P` | `P <id>,<value>[,<goal>];...` | progress toward an achievement with a bar. `value` is the current count (level, quests, skill, gold, kills, wins, steps...). `goal` is only sent when the catalogue can't know it (exploration: the number of areas the zone needs). Sent when it changes, and all non-zero ones after `L`. |
| `C` | `C <criteria>,<value>;...` | a step of a multi-step achievement is done (`criteria` = achievement × 100 + step; `value` 1). For boss councils, totems and the like. Metas are not sent: the client counts earned achievements itself. |
| `R` | `R <id>,<name>,<date>;...` | every realm first already claimed on this realm (after `L`). Replaces the client's list. |
| `F` | `F <id>,<name>,<date>` | someone just claimed a realm first (sent to every online player; the server also prints `Realm First! <name> has earned [<achievement>].` in their chat). |
| `I` | `I <name>,<class>,<points>;<id>,<date>;...` | answer to `.wnl ac inspect <name>`: that character's achievements. `class` is the numeric class id. |
| `I` | `I <name>,-` | nobody by that name. |

## Client → server

| Command | Meaning |
|---|---|
| `.wnl ac list` | send `L`, `P`, `C` and `R` again (the addon asks when it opened the window without having the list, at most every 30 s) |
| `.wnl ac inspect <name>` | answer with `I` (online or offline characters, any faction) |

Both are silent: the server never answers in chat.

## Criteria (world table `openvanilla_achievement_criteria.type`)

| Type | Name | Fields | Done when |
|---|---|---|---|
| 1 | level | `value1` level | the character's level ≥ value1 |
| 2 | quests | `count` | rewarded quests (each quest once) ≥ count |
| 3 | zone_quests | `value1` zone, `count` Alliance, `value2` Horde | rewarded quests whose `ZoneOrSort` is the zone ≥ the count for the player's side (0 = not for that side) |
| 4 | quest | `value1` quest; alternatives = racial variants | any alternative rewarded |
| 5 | explore | `value1` zone | ≥ 90% of the zone's explorable areas (AreaTable children on the same map) explored |
| 6 | meta | `value1` achievement | that achievement earned |
| 7 | kill | `value1` creature (alternatives: any), `count`, `value2` flags (1 = without dying in this instance), `value3` seconds since first entering this instance | kill credit (solo or group credit) `count` times under the conditions |
| 8 | skill | `value1` skill, `count` value | the skill's value ≥ count |
| 9 | skills_at | `value1` value, `value2` skill (one row per allowed skill), `count` | count of those skills ≥ value |
| 10 | reputation | `value1` faction, `value2` rank (7 = exalted) | reputation rank ≥ value2 |
| 11 | exalted | `count` | exalted with count visible factions |
| 12 | money | `count` copper | holding that much at once |
| 13 | bags | `value1` slots, `count` | count equipped bags with ≥ value1 slots |
| 14 | pets | `value2` item (one row per companion pet), `count` | owns count different ones (bags or bank) |
| 15 | item | `value1` item (alternatives: any) | owns one (bags or bank) |
| 16 | honor_kills | `count` | lifetime honorable kills ≥ count |
| 17 | bg_wins | `value1` battleground map (489 WSG, 529 AB, 30 AV), `count` | wins ≥ count |
| 18 | pvp_rank | `value1` rank 1..14 | highest PvP rank reached ≥ value1 |

An achievement needs every criterion (or `need` of them). It is only offered to its `faction`
(1 Alliance, 2 Horde) and `class_mask`. `flags`: 1 realm first (only the first character on the
realm gets it), 2 group first (the rest of that group, in the same instance within two minutes,
shares it), 4 Feat of Strength (no points).

## When the server checks

Level up, quest reward, kill credit (including group credit and Majordomo Executus's surrender),
newly explored area, skill change, reputation change, honorable kill, battleground win; gold, bags,
pets, items and PvP rank every 10 seconds. Deaths and instance entry are noted every update for
the "without dying" and "within N minutes" kills.

## Retroactive grant and storage

* `character_achievement (guid, achievement, date)` — earned achievements.
* `character_achievement_progress (guid, criteria, counter, date)` — counters: kill counts per
  criterion, `1000001` lifetime honorable kills, `1100000 + map` battleground wins, and criteria `0`
  marking that the retroactive grant ran.
* `openvanilla_realm_first (achievement, guid, name, date)` — one row per realm first, never changed.

The first time a character logs in after launch, everything the database already shows — level,
rewarded quests, skills, reputation, explored areas, honorable kills, gold, bags, items, PvP rank
— is granted, dated the release day (`openvanilla_achievement_config.release_date`, set to the day
the SQL is installed). Realm firsts are never granted retroactively (nobody can know who was
first), and kills and battleground wins before launch were not recorded, so those start at zero.
Each later login re-checks everything and grants anything already done, dated that day.

## Install (launch day)

1. `realm/classicplus/pending/classicplus_achievements.sql` against the world database
   (it creates the character tables in `classiccharacters` by name).
2. Build the world server with `realm/mangos/pending/0002-openvanilla-achievements.patch` on top of
   `0001-openvanilla-server-hooks.patch`.
3. The addon is already in patch-Z; it shows the catalogue and a note until the realm answers.

The catalogue itself lives in `realm/achievements/achievements.yml`; `tools/gen_achievements.py`
regenerates the SQL, the addon's `Data.lua` and `www/achievements.json` from it and checks it.
