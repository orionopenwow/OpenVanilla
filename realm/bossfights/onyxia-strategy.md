# Onyxia (Classic 1.12): the strategy the bots follow

The bots' Onyxia strategy is world server patch `realm/mangos/0059-openvanilla-bots-onyxia.patch`. This page has
the fight as the classic guides describe it, the numbers the bots use, and where they came from.

**About the research:** the written guides below were read. YouTube videos can't be watched here, and the guide
pages linked no videos with transcripts, so nothing on this page comes from a video. The room's geometry, spell ids
and timers come from the server's own Onyxia script (CMaNGOS `boss_onyxia.cpp`), which is what the bots actually
face.

## The fight in three phases

| Phase | Health | What she does | What the raid does |
|---|---|---|---|
| 1 (ground) | 100–65% | Melee on the tank. Flame Breath (frontal cone), Cleave (in front), Wing Buffet (frontal knockback), Knock Away (tank knockback, −25% threat), Tail Sweep (behind her, knockback) | The tank holds her at the north wall with her head to the wall. Everyone else stands at her sides, never in front or behind. DPS waits a few seconds for threat. |
| 2 (air) | 65–40% | Walks south, lifts off, hovers at 8 points around the room. Fireball on a random player (splash about 8 yd). At random, Deep Breath: she crosses the room in a straight line breathing fire, a trail about 10–18 yd wide. Whelps pour from the east and west egg tunnels (20 at once, then 4–10 every 90 s) | Ranged on Onyxia. Melee and the off-tank kill whelps. Everyone spreads (fireball splash) and moves out of the Deep Breath line the moment she starts it. Nobody goes near the eggs. |
| 3 (ground) | 40–0% | Lands, then Bellowing Roar: an AoE fear every 15–45 s, plus Phase 1's abilities | The tank picks her up again and turns her to the wall. Fear counters: Fear Ward on the tank (priest), Tremor Totem (shaman), Berserker Rage (warrior). Healers top everyone up before each roar. |

**Lava eruptions after the roar** are in the guides but not in this server's script, so there is nothing to dodge
there.

## Numbers from the server's script (CMaNGOS `boss_onyxia.cpp`)

- **Onyxia:** creature 10184. Whelps 11262. The Onyxian Warders (12129) are in the lair's tunnel.
- **Phase changes:** below 65% she moves to the south point and lifts off. Below 40% she lands at
  (−1.1, −229.9).
- **Phase 1 abilities and timers:**
  - Flame Breath 18435, every 10–20 s.
  - Cleave 19983, every 5–10 s.
  - Tail Sweep 15847, every 15–20 s.
  - Wing Buffet 18500, every 15–30 s.
  - Knock Away 19633, every 25–40 s.
- **Phase 2 abilities:**
  - Fireball 18392, every 3–5 s. It wipes the target's threat.
  - Every 15–25 s she moves to a neighbouring point, or (1 time in 3) breathes. She is marked by the auras
    Dragon Hover 18430 and Pacify Self 19951.
- **Deep Breath directions:** each spell is a line of fire points across the room, from her point to the opposite
  one.
  - north → south 17086, south → north 18351;
  - east → west 18576, west → east 18609;
  - south-east → north-west 18564, north-west → south-east 18584;
  - south-west → north-east 18596, north-east → south-west 18617;
  - into the entrance 21131, when she's lured out.
- **Phase 3:** Bellowing Roar 18431, every 15–45 s.
- **The 8 air points:**

  | Point | x | y |
  |---|---|---|
  | North | 24.2 | −216.1 |
  | North-east | 10.2 | −247.9 |
  | East | −15.0 | −244.5 |
  | South-east | −63.5 | −240.1 |
  | South | −66.4 | −215.9 |
  | South-west | −58.3 | −189.0 |
  | West | −16.7 | −181.5 |
  | North-west | 12.3 | −181.1 |

  Their middle is (−21.6, −214.5), and every Deep Breath line passes through it.
- **Whelp tunnels:** at (−30.1, −254.5) and (−30.8, −177.1).

## What the bots do (patch 0059)

- **Phases 1 and 3, her target (the tank):** goes to the tank spot (6, −214.5), near the north wall, whenever it's
  more than 6 yd from it and she is close. She follows and faces the tank, so her head points north.
- **Phases 1 and 3, everyone else:**
  - A bot in her front cone (±60°, within 40 yd) or her tail cone (±60°, within 30 yd) moves to her flank, square to
    her facing, on its own side: melee at her flank (her reach plus theirs), ranged and healers 22 yd out.
  - Half the raid goes left and half goes right. Checked every second.
- **Phase 2 (in the air), everyone:**
  - A bot within 9 yd of the line from her current point through the middle of the room moves square to it, 17 yd
    off, on its own side, staying inside the floor (34 yd from the middle) and 16 yd or more from the egg tunnels.
  - This runs every second as a combat trigger, and as a reaction between the bot's other actions.
  - Because she only ever breathes along that line, staying off it beforehand is the dodge. It's what the guides
    mean by "stand at her sides, never across from her".
  - Targets: the bots' own targeting puts ranged on her and melee on the whelps that attack the group.
- **Phase 3:**
  - A shaman keeps a Tremor Totem down.
  - A priest who has Fear Ward keeps it on her tank (in 1.12 only Dwarf priests have it).
  - Warrior tanks aren't in Berserker Stance, so they don't use Berserker Rage.

## Known gaps

- **The tank can still be feared in phase 3** when there's no shaman or Dwarf priest in the raid. Bot fill picks
  healers by turn (Priest, Druid, then Paladin or Shaman), so the raid may not have a Tremor Totem.
- **Whelps:** no bot is told to gather them at the tunnels. They come to the raid and get killed there.
- **The phase 3 tank swap:** her threat resets in the air (Fireball). The bot tank's own taunt logic picks her up
  again, but there is no "stop DPS at 41%" rule.
- **Fireball splash spreading:** not done beyond the two-sided split.
- **Bot-heavy raids can be made softer if the strategy isn't enough.** `OpenVanilla.BossFights.BotRaid.Health` and
  `.Damage` (default 1.0, no change) apply to a raid that's at least half bots, at tier 1. In
  `/opt/openvanilla-bossfights/botraid.env`: `BOTRAID_HEALTH=0.75`, `BOTRAID_DAMAGE=0.75`. This is the owner's
  call.

## Sources

- [Onyxia (Classic), warcraft.wiki.gg](https://warcraft.wiki.gg/wiki/Onyxia_(Classic)): abilities, whelps,
  positioning, the fear counters, and the safe spots for Deep Breath.
- [Onyxia (tactics), warcraft.wiki.gg](https://warcraft.wiki.gg/wiki/Onyxia_(tactics)): phases, the 10-player setup
  (2 tanks, 2 healers, 3 melee, 3 ranged), and the breath trail width.
- [Onyxia guide, Icy Veins (Classic)](https://www.icy-veins.com/wow-classic/onyxia-guide-strategy-abilities-loot):
  tank at the back wall facing it, the raid at one side out of the tail, whelps by the melee.
- [Onyxia's Lair raid guide, Warcraft Tavern](https://www.warcrafttavern.com/wow-classic/guides/onyxias-lair/): the
  raid split left and right, whelp groups, the Deep Breath line, and the Bellowing Roar interval.
- CMaNGOS `src/game/AI/ScriptDevAI/scripts/kalimdor/onyxias_lair/boss_onyxia.cpp`: phases, timers, points, spell ids.
