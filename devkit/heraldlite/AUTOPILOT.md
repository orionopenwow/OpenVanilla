# Herald Autopilot v1

`heraldlite autopilot` plays a route from `tools/autopilot` with no human input. It accepts
quests, walks to the mobs, fights, loots, rests, recovers from deaths and turns quests in. It
writes every decision to a JSONL run log and prints a JSON summary. The summary is shaped like
`tools/autopilot/out/predictions.json`, so you can compare a real run with the plan.

v1 targets the Northshire start of a **Human Hunter (levels 1 to about 5)** on **our own
CMaNGOS 1.12.1 realm**.

> **QA tool only.** Run it only against our realms, with bot accounts that are flagged as bots.
> The binary refuses every host except `play.openvanilla.app`, `staging.openvanilla.app`, `localhost`,
> `127.0.0.1`, `*.test` and `*.localhost`. The list is hard-coded (`src/autopilot/guard.rs`) and
> there is no flag to widen it. The world address from the realm list (or `--world`) is checked
> too, before it is dialled.

## Prepare

1. **Build** (see `README.md`): `cargo build --release`.
2. **Route.** From the repo root (needs the KB, see `tools/autopilot/README.md`):

   ```sh
   cd tools/autopilot
   python3 kb_build.py --setup && python3 kb_build.py   # once (private MariaDB under /tmp/claude-0)
   python3 combat_sim.py && python3 planner.py         # -> out/route_elwynn.json
   python3 route_enrich.py                             # adds npc / quests / go_entry / trigger
   ```

   Run `route_enrich.py` after every planner run, because the planner rewrites the file. The bot
   can play an un-enriched route, but it then has to guess more: it uses the nearest quest giver
   within 25 yd of the step and any chest near an objects step.
   `tests/fixtures/route_elwynn_enriched.json` is a committed copy of the enriched route from
   2026-10-16.
3. **Tactics** (optional): `autopilot/tactics_hunter.json` holds combat_sim's winners (kite,
   trigger 20 yd, 3 cycles, with shorter cycles for Defias Thug 38 and Kobold Laborer 80).
   `autopilot/tactics_melee.json` is for other classes. Every field has a default, so `{}` is a
   valid file. The kite fields have the same names as the `params` in `combat_costs.json`
   (`trigger`, `cycles`, `spells`), so you can paste them in. `by_level` and `by_entry` hold
   partial overrides.
4. **Character:** a fresh Human Hunter on a bot account, standing at the Northshire start. One
   character per account: Herald Lite picks `--char`, then `Herald`, then the first character.

## Run

**On the server box (direct mode, loopback):**

```sh
cd devkit/heraldlite
export HL_PASS='...'                       # never on the command line
./target/release/heraldlite autopilot \
    --host 127.0.0.1 --world 127.0.0.1:8085 --user BOTHUNTER1 --char Huntbot \
    --route ../../tools/autopilot/out/route_elwynn.json \
    --tactics autopilot/tactics_hunter.json \
    --max-level 5 --minutes 30 --log runs/huntbot-$(date +%F-%H%M).jsonl -v --pretty
```

realmd advertises the public domain, so `--world 127.0.0.1:8085` keeps the world connection on
loopback.

**Staging (web mode, through the relay):**

```sh
export HL_WEB=https://staging.openvanilla.app HL_USER=herald-bot1 HL_PASS='...'
./target/release/heraldlite autopilot --route ../../tools/autopilot/out/route_elwynn.json \
    --tactics autopilot/tactics_hunter.json --max-level 5 --minutes 30 --log staging-run.jsonl
```

| flag | default | meaning |
|---|---|---|
| `--host`, `--web`, `--user`, `--pass`, `--char`, `--realm`, `--world` | env `HL_*` | as for scenarios (README) |
| `--route <file>` | `tools/autopilot/out/route_elwynn.json` | the planner's route |
| `--tactics <file>` | built-in defaults | combat, rest and food parameters |
| `--minutes <n>` | 30 | time limit, then a clean stop and logout |
| `--max-level <n>` | all | play only the steps planned up to this level (`5` for v1) |
| `--start-step <i>` | 0 | resume at route step *i* (0-based, as in the log's `step`) |
| `--log <file>` | `autopilot_run.jsonl` | the JSONL run log |
| `--timeout <s>` | 10 | connect timeout |
| `--logout-timeout <s>` | 60 | logout is retried every 5 s while in combat until this runs out |
| `-v`, `--pretty` | | every non-movement packet on stderr; pretty JSON |

**Exit codes:**

| code | meaning |
|---|---|
| 0 | the route finished, or the time limit was reached, with no failed step |
| 1 | a step failed, the host was refused, the route or tactics file is bad, or the connection dropped |
| 2 | could not get in: login, realmd, world handshake or character |

stdout holds one JSON object, `{"ok", "exit", "summary": {...}}`. The summary is the same object
as the last log line.

## The run log

Each line is one JSON object with these fields:
`t` (s), `min`, `event`, `step` (route index), `step_kind`, `action`, `result`, `pos` [x,y,z],
`level`, `xp`, `hp`, `max_hp` and `mana`.

`event` takes these values:

| event | when |
|---|---|
| `start` | once at the start: the step count, the strategy, the navigator and the run speed |
| `decision` | the brain picked something new: a step, a walk, a conversation stage, a fight phase (`Ranged`, `KiteRun`, `Turn`, `Melee`), rest, loot. Repeats are collapsed |
| `outcome` | something happened: `step: ...` (`Done`/`Skipped`/`Failed` plus the reason), `pull`, `kill`, `xp`, `level up`, `quest progress`, `quest rewarded`, `loot`, `cast N` (`sent`, or `failed (SpellCastResult r)`), `melee` refused, `stuck`, `server moved us`, `died`, `released`, `corpse`, `resurrected`, `rest`, `finish`, `logout` |
| `snapshot` | every 30 s, the state only (an XP curve like botlab's snapshots) |
| `summary` | the last line, see below |

**What to look for:**

- `step: ... => Failed` and `Skipped` lines: quest givers that were not found
  (`no quest giver within 25 yd`), `timed out`, or turn-ins the ender calls incomplete.
- `stuck` (`sidestep`, `backtrack`, `gave up`) and `server moved us`. The second means the server
  corrected our position (teleport or anticheat). Many of them mean the dead reckoning or the
  straight-line path is wrong for the terrain there.
- `cast N failed (SpellCastResult r)`, with the CMaNGOS `SpellCastResult` code. Auto Shot (75)
  failing with out-of-range, "not in front" or line-of-sight codes points at the movement or
  facing model.
- `melee refused: NotInRange / BadFacing`.
- Deaths per level, and `fight ... dead after N s` compared with combat_sim's `kill_s` for that
  mob.
- `rest done after N s`: too long means the eat/drink thresholds or the food list are wrong.

**Summary** (`summary` object):
`end_reason`, `minutes`, `level_start`/`level_end`, `xp_gained`, `xp_per_min`,
`minutes_per_level` (level-up to level-up), `level_reached_min`,
`xp_per_min_by_band` (`1-4`, `5-8`, `9-12`), `quests` (`{id: {title, taken_min, rewarded_min,
minutes, predicted_minutes}}`), `steps` (`total`, `done`, `skipped`, `failed`, `last_index`),
`kills`, `kills_by_entry`, `deaths`, `stuck_events`, `loot` (`corpses`, `items`, `money_copper`),
and `vs_route.minutes_per_level` (`{L: {actual, predicted, ratio}}`).

Compare with the plan and with botlab:

```sh
jq -c 'select(.event=="summary").summary | {minutes_per_level, xp_per_min_by_band, vs_route}' run.jsonl
jq '.minutes_per_level, .xp_per_min_by_band' ../../tools/autopilot/out/predictions.json
jq -r 'select(.event=="outcome" and (.action|startswith("step:"))) | "\(.min)\t\(.step)\t\(.result)"' run.jsonl
```

botlab's `report.txt` uses the same three measures: median minutes per level, Hunter XP/min by
band, and per-quest minutes.

## What v1 does

- **World model** (`src/autopilot/world.rs`), built from benilla-protocol's decoded events:
  - units, players, game objects, items and corpses, with entry, position (following the server
    path of a moving creature), health, level, unit/dynamic/npc flags, target, faction template
    and auras;
  - our own state: position, health, mana, level, XP, money, bags (backpack and equipped bags);
  - the spell book (`SMSG_INITIAL_SPELLS`, learned, superseded) and cooldowns
    (`SMSG_SPELL_COOLDOWN`, `SMSG_COOLDOWN_EVENT`, our own at cast time);
  - the quest log from `PLAYER_QUEST_LOG_*` and the open NPC panel.
- **Movement** (`movement.rs`):
  - `MSG_MOVE_SET_FACING`, `START_FORWARD` with `MOVEFLAG_FORWARD`, a `HEARTBEAT` every 500 ms
    and `STOP` with no flags, dead-reckoned at the server's run speed;
  - server corrections (teleport, worldport) are adopted at once;
  - stuck detection: no progress for 5 s leads to a sidestep (alternating sides), then a
    backtrack, then giving up after 3 tries;
  - a `Navigator` trait. v1 ships `StraightLine` and takes waypoints from the route.
- **Combat** (`combat.rs`):
  - nearest attackable mob of the step's entry: alive, not tapped by someone else, not
    untargetable, at most 3 levels above us;
  - `CMSG_SET_SELECTION`, Auto Shot via `CMSG_CAST_SPELL 75` and melee via `CMSG_ATTACKSWING`;
  - range bands: melee 5 yd, dead zone 5-8 yd, shots 8-35 yd;
  - the combat_sim kite cycle: open at 35 yd with Hunter's Mark, Serpent Sting / Concussive /
    Arcane on the GCD, and after a shot with the mob inside `trigger` (and slowed or slower than
    us) run during the reload, stop, turn and shoot; melee fallback with Raptor Strike; Wing Clip
    buys another run;
  - "stand" (never run) and "melee" (other classes: walk in and auto-attack);
  - Aspect of the Monkey or Hawk when known;
  - it gives up on a target that takes no damage in 25 s.
- **Loot:** `CMSG_LOOT` on our lootable kills (up to 60 yd away) and any lootable corpse within
  30 yd, take every row we may (`CMSG_AUTOSTORE_LOOT_ITEM`), then `CMSG_LOOT_MONEY` and
  `CMSG_LOOT_RELEASE`. Quest chests (`objects` steps) use `CMSG_GAMEOBJ_USE` and the same flow.
- **Quests:**
  - accept: `HELLO` -> list/gossip -> `QUERY_QUEST` -> details -> `ACCEPT_QUEST`, until the quest
    is in the log;
  - turn in: `HELLO` -> list -> `COMPLETE_QUEST` -> request items -> `REQUEST_REWARD` -> offer
    -> `CHOOSE_REWARD 0` -> `SMSG_QUESTGIVER_QUEST_COMPLETE`;
  - progress comes from `SMSG_QUESTUPDATE_ADD_KILL`/`ADD_ITEM` and the quest-log fields. A kill
    step ends when every quest it lists is complete in the log;
  - the step executor runs the route in order: `travel`, `accept`, `turnin`, `kill`, `grind`,
    `objects`, `explore`. Every step has a timeout of 3x the plan, at least 5 minutes, plus 2
    minutes.
- **Survival:**
  - rest out of combat below 55% health or 35% mana: eat or drink from the bags if a known food
    or drink is there (the default lists are classic-db item entries, overridable), else sit;
  - death: `CMSG_REPOP_REQUEST`, `MSG_CORPSE_QUERY`, run back to the corpse, wait out the reclaim
    delay, then `CMSG_RECLAIM_CORPSE`.
- **Brain** (`brain.rs`): a tick every 150 ms over survive > combat > loot > rest > buffs >
  quest step > done. It stops at `--minutes` and then stops moving, stands, logs out and retries
  while in combat.

## What v1 does not do (stubbed or missing)

- **No navmesh or height map.** Paths are straight lines between route points. Ground z is
  estimated from the z of nearby units and objects. The server does not check collision, so the
  bot can cut through hills and buildings. The z estimate can be off on slopes and in the Abbey,
  which matters for the 3D range and line-of-sight checks.
- **Explore steps:** the bot sends `CMSG_AREATRIGGER` with the route's `trigger` id when it
  arrives. The trigger positions in the KB are approximate (AreaTrigger.dbc is not extracted),
  so the server may not credit it. The step is then logged as `Skipped`.
- **Not supported, logged as Skipped:**
  - `tame` and `pet` steps;
  - quests completed by using an item or casting a spell;
  - escort quests;
  - gossip-option quests (gossip menus are only read for their quest rows);
  - quests started by an item.
- Quest givers that are game objects are not found.
- Reward choice is always index 0. No equipping of rewards, no vendor visits (selling,
  restocking arrows or food) and no repairs.
- Combat:
  - no pet;
  - no group or tagging etiquette beyond skipping mobs tapped by others;
  - no fleeing at low health;
  - spell ranks and costs are a built-in table (`combat.rs`) for the hunter abilities above;
  - melee classes only auto-attack.
- Faction hostility is not computed (FactionTemplate.dbc). Targets are picked by the step's
  creature entry, and self-defence by who attacks us.
- Food is detected by a list of item entries. Item templates are not queried.
- Kills are counted from `SMSG_LOG_XPGAIN` (kill) and from our own dead targets that nobody else
  tapped. A grey mob that someone else kills next to us is not counted.

## Verified here and not verified

**Verified offline** (`cargo test`: 49 new unit tests and 2 new end-to-end tests; all 32 + 12
older tests still pass):

- the movement stream: the opcode order, `FORWARD` on start and heartbeat and none on stop,
  heartbeats at least 500 ms apart, facing math and z handling;
- range bands, every kite state transition, the GCD and cooldowns, stand and melee;
- the quest conversation for accept and turn-in, refusals and timeouts;
- route parsing, including the real enriched route (levels 1-5 contain only playable step
  kinds);
- the loot flow, tactics overrides, the run-log summary arithmetic and the host allowlist;
- every opcode against CMaNGOS classic `Opcodes.h`, and every CMSG body against the server's
  `recv_data >>` order.

The end-to-end tests:

- `sim_tests.rs` is an in-process scripted world on simulated time. Every server message is
  built as raw bytes and decoded by benilla, and every client command is encoded and read back.
  It covers accept -> pull -> kite -> kill -> loot -> turn in, a two-kill step with the kite
  cycle, death -> release -> corpse run -> reclaim, rest before travel, step skips and the time
  limit. The server enforces 5 yd interaction and 8-35 yd standing shots against the position
  from our `MSG_MOVE_*` stream.
- `tests/e2e.rs::autopilot_plays_a_route_against_the_fake_world` runs the real binary over TCP
  (SRP6, header crypto, the bridge) against the fake realm: accept, kill, loot, turn in and log
  out, with no range or movement violations.

**Needs a live server:**

- real CMaNGOS behaviour: anticheat reactions to our dead-reckoned movement, the z estimate on
  real terrain, line of sight, evade and leash, mob AI (fleeing humanoids, casters), whether
  Auto Shot resumes after our stop and turn as modelled;
- the timing of quest-giver gossip versus the quest list for multi-quest NPCs in Northshire;
- AreaTrigger credit, the food item entries a fresh Human Hunter actually has, and the reclaim
  delay;
- web mode through the real relay. It is the same code path as the scenarios, but it has not
  been run with the autopilot.

## Code map

| file | what |
|---|---|
| `src/autopilot/mod.rs` | the driver: connect (guarded), event tap, 150 ms loop, clean logout |
| `world.rs` | the object manager and our own state |
| `movement.rs` | `Mover` (packets), `Navigator`, `PathFollower` with stuck recovery |
| `combat.rs` | `Fight`: kite, stand and melee state machines; spell ranks |
| `loot.rs`, `quest.rs` | `Looter`; route parsing and the `Talk` conversation |
| `brain.rs` | the priority loop and the step executor |
| `runlog.rs` | the JSONL lines and the summary |
| `out.rs` | `OutCmd`, every packet sent, with `encode()` and the `WorldWriter` sink |
| `guard.rs` | the host allowlist |
| `sim.rs`, `sim_tests.rs` | the scripted world and the end-to-end brain tests (test-only) |

## Next steps

1. **Detour navmesh.**
   - Implement `movement::Navigator` with CMaNGOS mmaps: extract with the core's
     `MoveMapGen` from the same client data the realm uses, and load the tiles with
     `recastnavigation` (a `recast-rs`/FFI binding, or a small C++ helper behind a C ABI).
   - `route()` returns the corridor's straight path. Feed z from the navmesh instead of
     `World::ground_z`, and replace the sidestep/backtrack heuristics with re-planning.
   - Add a test that compares a navmesh path with the straight line around the Northshire
     Abbey walls.
2. **More classes.**
   - A class table (spell ranks, costs and cooldowns from `spell_template`, as for the hunter)
     plus one strategy per class on the `Fight` pattern: warrior (Battle Shout, Heroic Strike,
     Rend, rage), mage (Frostbolt kiting, Fireball, drink), priest (shield, smite, renew),
     rogue, paladin, warlock (pet).
   - Load class defaults from `tactics_<class>.json`.
   - Hunter pet: Tame Beast (quest chain 90601-90604) and pet attack/follow.
3. **More quest types.**
   - Use-item and cast-spell objectives (`CMSG_USE_ITEM` on a target, e.g. the taming rods),
     gossip-option quests (`CMSG_GOSSIP_SELECT_OPTION`), escorts (follow and defend), item-started
     quests (`CMSG_OPEN_ITEM` / `QUESTGIVER_HELLO` on the item).
   - Exact area triggers from an extracted `AreaTrigger.dbc` in the KB.
   - Reward choice by class and stats; equip upgrades (`CMSG_AUTOEQUIP_ITEM`).
   - Vendor runs: sell grey items, restock arrows and food.
4. **Fleet and reporting.**
   - Several bots in parallel (one process each, distinct accounts).
   - Append `snap` rows to botlab's `lab.db` so `botlab_report.py` aggregates autopilot runs
     next to playerbots.
   - A `compare_run.py` that prints `vs_route` for a set of logs.
