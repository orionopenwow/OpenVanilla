# Open Vanilla Autopilot, Phase 0 (offline)

Predicts how a **Human Hunter** levels from 1 to 12 in Northshire (zone 9) and Elwynn Forest
(zone 12) on our realm: CMaNGOS classic, classic-db, and our Classic+ SQL. Tomorrow we compare
these predictions with the playerbot logs from `tools/botlab` (`botlab_report.py`).

Everything runs offline once the data has been fetched. It needs Python 3.10+ (standard library
only) and, for the knowledge base, the MariaDB binaries (`apt install mariadb-server`). No
Python DB driver is needed: the scripts call the `mariadb` client.

## Run it

```sh
cd tools/autopilot
python3 kb_build.py --setup   # once: clone classic-db to /tmp/claude-0/autopilot_data, start a private
                              # mariadbd on a unix socket there, load Full_DB + every Updates/*.sql,
                              # then realm/classicplus/{races,weapons,classquests,xp,trainers,
                              # starpouch,starpouch_money}.sql
python3 kb_build.py           # -> kb/elwynn_human_hunter.json (gzipped automatically if > 2 MB)
python3 combat_sim.py         # -> out/combat_costs.json   (~30 s)
python3 planner.py            # -> out/route_elwynn.json, out/route_elwynn.txt
python3 predict.py            # -> out/predictions.json, out/predictions.txt (+ route; ~15 s with sensitivity)
python3 route_enrich.py       # adds npc / quests / go_entry / trigger to the route for Herald Autopilot
python3 chain_check.py        # -> out/chain_check.txt (needs the DB; exit 1 on any FAIL)
python3 -m unittest tests.test_autopilot -v     # from the repo root
```

The large downloaded data (the classic-db clone and the MariaDB datadir) stays in
`/tmp/claude-0/autopilot_data` and is never committed. You can change the location with `--data`.

## Files

| file | what |
|---|---|
| `common.py` | XP formulas (cmangos `Formulas.h`, `Quest::XPValue`), travel, JSON helpers |
| `kb_build.py` | builds the knowledge base: quests for race 1 / class 3 (masks, levels, Prev/Next/ExclusiveGroup), givers and enders with spawns, objectives, item sources (creature/GO loot, reference loot, group equal-chance), objective and grind mob templates and spawns (with class-level stats), exploration points, vendors/innkeeper/trainers near Goldshire and Northshire, the nearest flight masters, player level stats, `player_xp_for_level` after our XP SQL (and the stock copy), hunter spells from `spell_template`, and an `unresolved` list |
| `combat_sim.py` | the event-driven hunter-vs-one-mob simulator and the tactic search |
| `planner.py` | the greedy hub-batching route planner with grind filler |
| `predict.py` | turns the route into numbers shaped like the botlab report, plus a sensitivity section |
| `route_enrich.py` | adds per-step NPC entries, kill-step quest lists, chest entries and area-trigger ids from the KB, for `heraldlite autopilot` (devkit/heraldlite/AUTOPILOT.md) |
| `chain_check.py` | static check of the taming chains 90601-90604 (Human) and 90605-90608 (Undead) |
| `out/` | the outputs from the last run (committed so they can be compared tomorrow) |

## How the planner works

1. At a quest giver, accept every available quest from every NPC within 40 yd (one hub).
2. Go to the nearest incomplete objective of an accepted quest: a mob camp, objects, an
   exploration point or a vendor. Each kill counts for every accepted quest that wants that mob
   (kill credit, or the expected drop share `chance/100`). A worthwhile quest whose giver is within
   150 yd is picked up on the way.
3. When no objectives are left, turn in at the nearest ender. Everything else that ends there is
   turned in too, and anything new on offer there is accepted.
4. With nothing accepted, choose the next hub by its XP/min: quest XP plus kill XP, divided by
   travel, objectives and the walk back, with a one-step look-ahead along the quest chain. Grind
   instead (until the next level) if the best grind camp is more than 15% faster, or if no quest is
   available.

Travel = straight-line distance x 1.35 / 7.0 yd/s. Combat time per kill comes from
`combat_costs.json`: kill time + rest + death risk x 90 s. To that the planner adds its own search
time: the mean spacing of the camp's spawns within 150 yd, walked, plus 3 s to loot. Once a camp's
population is used up, kills wait on respawns.

## Combat model (combat_sim.py)

One hunter fights one mob along a line. The simulation jumps from event to event, and movement
between events is linear.

- **Auto Shot**: reload (weapon speed - 0.5 s) continues while moving. The 0.5 s aim that follows
  needs the hunter to stand still: moving cancels it, and it restarts when the hunter stops. The
  first shot needs no reload. Shots need 8-35 yd.
- **Instants**: Serpent Sting (L4, 20 dmg over 15 s; L10 40), Arcane Shot (L6 13 dmg; L12 21,
  6 s cooldown), Concussive Shot (L8, -50% speed for 4 s, 12 s cooldown, 8% of base mana) and
  Hunter's Mark (L6, +20 RAP, cast before the pull). They share a 1.5 s GCD, work while moving
  and need 8-35 yd.
- **Melee**: auto attack, Raptor Strike on the next swing (+5, +11 from L8, 6 s cooldown) and
  Wing Clip (L12, -50% for 10 s). Ranks come from `spell_template`. The realm auto-learns every
  rank at level-up, so there are no trainer visits.
- **Mob**: chases at 7.0 x `creature_template.SpeedRun` (0.857 for most Elwynn mobs, so about
  6 yd/s), slowed by Concussive/Wing Clip, and swings whenever it is within 5 yd (including at a
  hunter running away). Mage-class mobs (`UnitClass` 8) stand and cast three 3 s bolts
  (1.4 x an average melee hit) inside 30 yd before closing. Humanoids add 2 s for fleeing.
- **Tactics compared** (best by XP/min per mob and level):
  - (a) stand: shoot, then melee; three spell sets, with or without Concussive.
  - (b) kite: open at 35 yd. After a shot, if the mob is within the trigger distance (12/15/20 yd)
    and slowed (or slower than us), run during the reload, turn (0.3 s), aim and fire. Up to
    1/2/3 cycles, then melee. Wing Clip at L12 gives another run.
  - (c) melee-heavy: open at 10 yd or 5 yd.
  - (d) pet: from Tame Beast (quest 90603) the pet tanks. Its HP and armor come from
    `pet_levelstats`, it does 0.6 x level + 1 DPS, and it regenerates 3% per second out of
    combat. It is reported separately (`pet`), and the planner uses it after 90603.
- **Objective**: XP/min = XP x (1 - p_death) / (kill + rest + 12 s search + p_death x (60 s corpse
  run + regen of half HP)). There are 40 Monte Carlo runs per mob level.

## Assumptions (and where the numbers come from)

- **Hunter stats**: `player_levelstats` (race 1, class 3, as added by `classicplus_races.sql`) and
  `player_classlevelstats`, plus 5% spirit (The Human Spirit). HP = base + sta (the first 20 count
  1, the rest 10). Mana = base + int (the first 20 count 1, the rest 15). RAP = 2L + 2agi - 10
  (+20 Hawk from L10). Melee AP = 2L + str + agi - 20.
- **Hit, crit, armor**: crit 5%, x2. Miss 5% + 1% per mob level above the hunter. Mobs dodge 5% of
  melee. Hunter dodge 5% (+8% with Monkey from L4). Armor reduction = A / (A + 400 + 85 x
  attacker level). Hunter armor = 2 x agi + 20 + 8 x level (starter gear plus quest greens).
- **Gear**: no bow is sold or rewarded in Northshire or Elwynn (checked in the KB), so the hunter
  keeps the **Worn Shortbow (2-5, 2.3 s)** and Rough Arrows (+1.5 DPS) up to level 12. Bots
  with a 2.8-3.0 s bow will hit harder per shot and less often; to test that, change `BOW` in
  `combat_sim.py`. Melee weapons: Worn Axe, then Militia Quarterstaff (quest 18, from L4), then
  Well-used Sword (quest 46, from L8). Start gear comes from `CharStartOutfit.dbc`, which is not
  in the DB.
- **Mob stats**: cmangos `Creature::SelectLevel`. HP = `BaseHealthExp0` x HealthMultiplier, and
  damage per hit = (BaseDamage x (1 +/- variance/2) + AP/14 x attack time) x DamageMultiplier,
  both taken from `creature_template_classlevelstats`. Armor = BaseArmor x ArmorMultiplier. Old
  template min/max fields, or a level guess, are used only when those are missing. Mob spells
  and EventAI are not modelled, apart from the mage-class bolt rule.
- **Regen and rest**: out-of-combat regen per cmangos `Unit::OCTRegen*`. HP/s = 0.43 x spi - 5.5
  (x1.5 sitting). Mana/s = (spi/5 + 15)/2. Food and drink come from Innkeeper Farley's goods:
  3.4 HP/s and 8.4 mana/s below L5, 11.6 and 20.8 from L5. Rest per kill is spread evenly
  (eat/drink to cover whatever regen during the search does not), plus 1.5 s to sit and stand.
- **XP**: kill XP per cmangos `MaNGOS::XP::Gain`: gray level, zero difference, 5% per level above,
  elite x2.5, no rested bonus, `Rate.XP.*` = 1. Quest XP = RewMoneyMaxLevel / 0.6 (QuestLevel
  <= 60), reduced 80/60/40/20/10% at 6+ levels above the quest. **Our `classicplus_xp.sql`
  changes only the XP needed per level** (1-10 -5%, 11-20 -10%). Kill and quest XP are unchanged.
  The KB holds both tables, and the planner uses the Classic+ one.
- **Quests left out of the route** (see `skipped` in the route): enders outside the region
  (Stormwind, Westfall, Redridge), item-started quests, elite objectives (Hogger), and items with
  no loot source in the DB.
- **Region**: a box (x -10120..-8550, y -1650..950, map 0) minus Stormwind City. There is no
  zone/area column for spawns (`creature_zone` is empty), so this is approximate at the
  Westfall/Duskwood edges.
- **Hostility**: a faction blacklist (Stormwind, Northshire guards, critters, Darkmoon...).
  FactionTemplate.dbc is not in the DB.
- **Exploration points** (Fargodeep/Jasperlode Mine) are approximated from the kobold spawns
  there, because AreaTrigger.dbc is not available.
- **Taming rod objective**: 20 s channel (spell DurationIndex 18, assumed 20 s), plus walking to
  the beast.
- **Timings**: 5 s to accept or turn in. Pools and respawn variance are not modelled (pooled
  spawns count as up). Other players and bots competing for mobs are not modelled.

## Comparing with botlab

`predictions.txt` uses the same headings as `report.txt`:

- median minutes per level
- XP/min for the Hunter in bands 1-4 / 5-8 / 9-12
- per-quest minutes from taken to rewarded
- the 90601-90608 line

Botlab reports medians over many bots and snapshot intervals. These predictions follow one
planned character, so expect bots to be slower: they do not plan routes, they compete for mobs and
they get stuck. The useful signals are the shape of the curve and the per-quest outliers.
