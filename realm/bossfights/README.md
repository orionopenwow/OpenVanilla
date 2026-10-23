# Boss Fights

Raids at level 60, by queue. Every group gets its own fresh copy of the raid, scaled to the group's size and
the tier it picked. Clearing a tier opens the next one and makes the account's characters stronger.

Boss Fights is a second mode on the Duels realm. It runs on the Duels world server, and Warfront's kits and
gear picker are its armory. It is off unless `mangosd.conf` says `OpenVanilla.BossFights = 1`.

## One hangout, two modes

Duelers and raiders hang out together in Duels' hangout: Gurubashi Arena in Stranglethorn, where every new
character starts. Boss Fights uses Duels' own settings for it (`OpenVanilla.Duels.Hub` and `.Hub.Fence`) and
defines no second fence.

Each character is in one mode at a time (`bossfights_player.mode`). Each mode has its own window, queue,
results and rules, and touches only its own characters:

- Duels' hangout code skips raiders entirely: its fence, outfits, hangout consumables and bots.
- Boss Fights acts only on raiders: its fence (the same circle), shared faction and tier aura.
- Becoming a raider: `go`, a raid queue, or `mode boss`. Each one also takes the character off the Duels
  queue.
- Becoming a dueler again: `duels`, `mode duels`, or pressing a Duels queue button (Duels' `join`). None of
  these work during a run.
- Both modes use the same friendly faction in the hangout, so raiders and duelers can talk, group and trade.
- A raider can `/duel` a dueler there; that is ordinary consent.
- Watching a duel from an arena copy is left to Duels: the Boss Fights fence waits until the watcher is back.

## The player's path

1. Press **Fight now** on the site's Boss Fights page. The play page keeps the mode (`?mode=boss&raid=...`).
2. Sign in. The character screen stays: realm patch 0035 skipped it and was removed (47566a9).
3. A new character starts in the hangout, as every Duels character does.
4. In the world, the Boss Fights addon opens. It sends `mode boss`, and then `go` if the answer says the
   character isn't at the hangout. `go` works at once from anywhere on the realm, except in a fight or a Duels
   match.
   - Server fallback: `mode boss` also marks the account for 30 minutes. A character the account makes in that
     time starts as a raider at its first login, and the server sends it `go`, which opens the window.
5. In the hangout: the armory, the queue and party search.
6. When the queue pops, the raid group is made and everyone is put into a new copy of the raid made for that
   group alone.
7. During the run, the timer starts at the first pull. Boss kills (splits), deaths and wipes are counted.
8. The run ends with a clear (the next tier opens) or with leaving. Either way, the raider goes back to the
   hangout.

## Parts

| Part | What it is |
|---|---|
| `realm/mangos/0050-openvanilla-bossfights.patch` | The world server: `OpenVanilla/BossFights.{h,cpp}` (lobby, commands, queue, runs) and `OpenVanilla/BossFightsLogic.h` (pure rules), plus hooks in `World.cpp`, `WorldSession.cpp`, `Unit.cpp` (damage taken), `Creature.cpp` (health), `MovementHandler.cpp` (raid entry checks), `Warfront.cpp` (commands, updates, armory tier) and `WarfrontArena.{h,cpp}` (Duels' hangout skips raiders; Duels' `join` makes a raider a dueler again; `LeaveQueue` for the switch the other way). Made on 0001-0039. |
| `bossfights_world.sql` | Short John Mithril becomes friendly to both factions. Two Raid Quartermasters stand in the arena (reagents, ammunition, bandages). The consumables a run gives sell for nothing. |
| `bossfights_lean.sql` | The world keeps only the hangout (the same 70 yards as `duels_lean.sql`) and every spawn on the raid maps. |
| `realm/mangos/0051-openvanilla-bossfights-selftest.patch` | The self-test's server side (off unless `OpenVanilla.BossFights.SelfTest = 1`): test accounts, their own queue, `size=N`, the `test` commands, `OpenVanilla/BossFightsSelfTest.h` (pure rules). For everyone: the waiting line's position, and the refresh on leaving a run. See "Self-test". |
| `bossfights_characters.sql` | `bossfights_player`, `bossfights_account`, `bossfights_progress`, `bossfights_result` (with `bots` and `test`), `bossfights_now`. |
| `tests/` | `sh realm/bossfights/tests/run.sh` runs the pure rules' tests and the self-test's (no server). |
| `hetzner/bossfights_check.sh` | The self-test runner: two test accounts play the mode with Herald Lite; a public report. |
| `hetzner/bossfights_up.sh` | An add-on to `duels_up.sh`'s stack: copies the raids back, runs the SQL, adds `OpenVanilla.BossFights = 1`, runs the website feed (`bossfights_live.json`) and `testbots`. |

## How a run works

### One copy of the raid per group

`StartRun` runs on the world thread. It works the same way as Warfront's arena:

1. It asks for a new instance id (`sMapMgr.GenerateInstanceId()`).
2. It makes that copy's persistent state.
3. It binds every member to that copy permanently. A player's permanent bind wins over any group save, so
   nobody can land in somebody else's copy.
4. It teleports the members in with `TELE_TO_SKIP_ENTRY_CHECKS`. `SkipEntryChecks` also lets their raid's area
   trigger through, so attunement and the raid-group requirement don't block them.

Everyone leaves their old party first. One raid group is made for the run, so parties stay together inside it.
When everyone is out, the binds are dropped, the group is disbanded, and the copy unloads after
`Instance.UnloadDelay`.

### Scaling

| What | Where it happens | Factor |
|---|---|---|
| Health | `Creature::AddToWorld`, once per creature in a run's copy | tier × size × affix |
| Damage | `Unit::SpellDamageBonusTaken` and `MeleeDamageBonusTaken`, when the attacker is a run's creature | tier × size × affix × enrage |

- Size factor: `(players ÷ the raid's maximum)`, raised to `SizeExp.Health` for health and `SizeExp.Damage`
  for damage. Health is never below 0.15 and damage never below 0.30.
- Bosses are world-boss rank. The tyrannical and enrage affixes apply to bosses; fortified applies to trash.

### Encounters

The run checks its copy's completed-encounter mask every second. The encounter list comes from
`instance_dungeon_encounters`: Molten Core has 10 encounters and Onyxia has 1.

### Tiers

- Tier 1 is open from the start. A clear of tier N opens tier N+1, per raid.
- The best tier cleared in any raid gives:
  - the tier aura: +2% to every stat per tier, at most +10%;
  - Warfront's armory tier: tier 2 gear after any clear, tier 3 after a tier-3 clear.

### On entering

Players are healed, get the world buffs, and have their consumables topped up. Molten Core also gives Eternal
Quintessence for the runes.

## Settings

All settings go in `mangosd.conf` and are listed in `BossFights.h`.

| Setting | Default | Meaning |
|---|---|---|
| `OpenVanilla.BossFights` | 0 | Turns Boss Fights on. |
| `.Only` | 0 | 1 puts every character in Boss Fights. Use it only on a realm that is Boss Fights alone. |
| `.Raids` | `onyxia mc` | The raids offered. Keys: onyxia mc bwl zg aq20 aq40 naxx. |
| `.Lobby` | Duels' `.Hub` | A lobby of its own: map x y z orientation. Leave it unset to share Duels' hangout. |
| `.Lobby.Fence` | Duels' `.Hub.Fence` | The fence for a lobby of its own: x y radius. With no Duels hangout either, Gurubashi's pit is used (-13202.9 276.76, 70 yards). |
| `.RaidSize` | 10 | Players per run. |
| `.MinTanks` | 2 | Tanks a raid needs, until the oldest ticket has waited `.RelaxRolesSeconds`. |
| `.MinHealers` | 2 | Healers a raid needs, with the same relax rule. |
| `.RelaxRolesSeconds` | 120 | How long the oldest ticket waits before roles stop being required. |
| `.MaxTier` | 5 | The highest tier. |
| `.Tiers` | `1:1;1.3:1.2;1.7:1.4;2.2:1.6;3:1.8` | Health and damage factor for each tier. |
| `.Affixes` | `none;fortified;tyrannical;enrage;fortified,enrage` | The affixes for each tier. |
| `.SizeExp.Health` | 1.0 | Exponent for scaling health to the run's size. |
| `.SizeExp.Damage` | 0.75 | Exponent for scaling damage to the run's size. |
| `.WorldBuffs` | (spell ids) | Cast on entering a run. |
| `.Consumables` | (item:count list) | Topped up on entering a run. |
| `.Consumables.<raid>` | | Extra items for one raid, such as `.Consumables.mc`. |
| `.StatBonusPerTier` | 2 | The tier aura's +% per tier cleared. |
| `.StatBonusCap` | 10 | The tier aura's maximum %. |
| `.PortSeconds` | 60 | Time to reach the raid after the pop. |
| `.RunMinutes` | 120 | A run ends, not cleared, after this. |
| `.LeaverMinutes` | 10 | Queue lock after leaving a run before it ends. |

## Commands

Commands are `.wnl wf bf <cmd>`. Each answer is sent on addon tag `BF` and also as a chat line.

| Command | What it does |
|---|---|
| `go [raid]` | Become a raider, and go to the hangout if you are not there. |
| `role tank` / `role healer` / `role dps` | Set your role. |
| `q <raid> [tier]` | Queue. A party's leader queues the whole party. |
| `unq` | Leave the queue. |
| `status` | Your queue or run status. |
| `lfg [raid]` | List party search posts. |
| `lfg post <raid> <tier> <tanks> <healers> <dps> [note]` | Post your party. |
| `lfg join <id>` | Join a posted party. |
| `lfg drop` | Remove your post. |
| `tiers` | Your tiers per raid. |
| `board <raid> <tier> [bots]` | The 10 fastest clears by people only, or (`bots`) of runs that had bots. |
| `abandon` | Leave the run. |
| `duels` | Become a dueler again (same hangout). Answer: `mode,0,<at hub>`. |
| `mode boss` / `mode duels` | Switch mode where you stand, with no teleport, and mark the account for its next new character (30 minutes). Answer: `mode,<1\|0>,<at hub 0\|1>`. |
| `hi` | Hello: `hi,<on>,<mode>,<raid>,<role>,<bonus>,<raids>,<at hub>`. `status` when idle answers `idle,<at hub>`. |

## Keeping Duels and Boss Fights together

- `duels_up.sh update` runs `duels_lean.sql` again, which removes the raids, and rewrites the config. Always
  follow it with `bossfights_up.sh update`.
- Hangout check: `duels_up.sh` (at 4e717e7) still writes `OpenVanilla.Duels.Hub` as the Goldshire inn, while
  `duels_world.sql` starts characters in Gurubashi and `duels_lean.sql` keeps only Gurubashi's spawns.
  `bossfights_up.sh status` prints the hangout in use and warns when it is not Gurubashi.
- On a realm that is Boss Fights alone, use `.Only = 1`.

## Bots

Bots are for playtests, and for a person who wants to fill a party.

- A playerbot in the party leader's party is queued with the party, and joins Boss Fights with it. Its role
  comes from its spec.
- A run with bots is stored with `bossfights_result.bots` set and each bot marked `:bot` in `members`. It
  ranks on its own boards: `board <raid> <tier> bots` in game, and `boards_bots` in `bossfights_live.json`.
  Clears with bots still open tiers.
- To turn the bot AI on for a playtest: `bash hetzner/bossfights_up.sh testbots on <ACCOUNT> [<ACCOUNT2>]`.
  This does four things:
  - saves the stack's bot settings;
  - turns the AI on with no random-bot pool, and makes no bot accounts ahead of time;
  - makes each account a GM;
  - restarts the world server.
- In game, `.rndbot group size=5 temporary=1` (GM only) makes four level-60 bots next to you, in your party,
  with classes that fit the roles. Their gear is the bot factory's level-60 pick, not Warfront's kits.
- `testbots off` restarts once with the AI on (the bot AI deletes `temporary=1` bots at start), then puts the
  saved bot settings back (a second start) and restores the GM levels. Duels' own practice and hangout bots
  are never deleted.
- Memory: the bot AI loads its own world data at start, about a few hundred MB on top of the world server.
  Check `free -m` before `testbots on`.

## Smoke test

### Setup

On the server:

```
RAIDSIZE=5 RELAX=0 bash hetzner/bossfights_up.sh update
bash hetzner/bossfights_up.sh testbots on YOURACCOUNT FRIENDACCOUNT
```

`RAIDSIZE=5` makes 5-player runs; `RELAX=0` means roles never hold the queue. Undo both with
`bash hetzner/bossfights_up.sh update` and `testbots off`.

Log in at the Modes site and make a level 60. All commands below are typed in chat. Each `.wnl wf bf ...`
answer also prints a `[Boss Fights]` chat line.

| # | Feature | Type | Expect |
|---|---|---|---|
| 1 | Lobby (shared hangout) | A new character starts in Gurubashi Arena as a dueler. Type `.wnl wf bf go`. | "Boss Fights: gear up, find a party..." with no teleport (you are already in the hangout). `.wnl wf bf hi` ends in `,1` (at the hub). |
| 2 | Fence | Run up the ramp and out past the stands, or `.go xyz -13100 300 30 0`. | Within a second you are back at the arrival point. |
| 3 | Friendly, no FFA | Stand in the pit next to a character of the other faction. | Neither of you is flagged; you can group and trade. |
| 4 | Armory | Open the Warfront window (kits, gear picker) and take a kit. The Raid Quartermasters in the stands sell reagents. | The gear is equipped. |
| 5 | Role | `.wnl wf bf role tank` | "role,tank". |
| 6 | Tiers | `.wnl wf bf tiers` | "Onyxia's Lair: cleared tier 0, open to 1; Molten Core: ...". |
| 7 | Locked tier | `.wnl wf bf q onyxia 2` | "err,tier" (tier 2 is not open yet). |
| 8 | Go from anywhere | `.go xyz -11000 -1500 30 0` (somewhere in Stranglethorn), then `.wnl wf bf go` | At once back in the hangout. |
| 9 | Status, leave queue | `.wnl wf bf status`, then `.wnl wf bf unq` | "Queued: onyxia,1,1,<seconds>", then "Left the queue." |
| 10 | Party search: post | `.wnl wf bf lfg post onyxia 1 1 1 2 bring pots` | "Your party is listed in party search." |
| 11 | Party search: list and join | On FRIENDACCOUNT: `.wnl wf bf lfg`, then `.wnl wf bf lfg join <#>` | "Parties: #1 YourName onyxia t1 ..."; the friend joins your party. `lfg drop` removes the post. |
| 12 | Bots fill the party | `.rndbot group size=5 temporary=1` | Four level-60 bots appear next to you, in your party. (Leave the friend's party first; `size` counts everyone.) |
| 13 | Party queue | As leader: `.wnl wf bf q onyxia` | Every member gets "Queued..."; only the leader can queue (`err,leader` for the others). |
| 14 | Pop, fresh copy | Wait a second. | "Your raid is ready. Taking you in.", then all five are inside Onyxia's Lair: "Onyxia's Lair, tier 1 (none), 5 players... (run 1, copy N)". The server log has "Boss Fights: run 1, onyxia tier 1, 5 players, instance N". |
| 15 | A second group, a different copy | FRIENDACCOUNT, in Gurubashi: `.rndbot group size=5 temporary=1`, then `.wnl wf bf q onyxia` | "(run 2, copy M)" with M different from N; the two groups never see each other. |
| 16 | Scaling | Target Onyxia and type `.npc info`. | Health is the stock value × 5/40 (the size factor) × 1 (tier 1). At tier 2 it is 1.3× the tier-1 number, and the damage you take rises too. |
| 17 | World buffs, consumables | Look at your buffs and bags on entering. | Rallying Cry, Songflower and the other world buffs; Major Healing and Mana Potions, flasks, dumplings and bandages topped up. In Molten Core you also get Eternal Quintessence. |
| 18 | Timer, pull | Pull Onyxia. Type `.wnl wf bf status`. | "Run 1 (copy N): onyxia tier 1, 0:12, bosses 0/1, wipes 0". |
| 19 | Boss kill, encounter, split | `.die` with Onyxia targeted (GM). | "Down: Onyxia 0:20", then "Cleared! The next tier is open." `status` shows bosses 1/1. |
| 20 | Clear, unlock, aura | Wait 30 s to loot, then you are back in Gurubashi. Type `.wnl wf bf tiers`. | "Onyxia's Lair: cleared tier 1, open to 2". Your character sheet stats are 2% higher (the tier aura), and the Warfront armory offers tier 2 gear. |
| 21 | Wipe | Queue tier 2, pull, and let the bots die. `.die` yourself. | A wipe is counted (`status`: wipes 1). Release spirit: you come back alive at the raid's entry point, in the same copy. |
| 22 | Leaver lock | Mid-run: `.wnl wf bf abandon`, then `.wnl wf bf q onyxia` | Back in Gurubashi, then "err,locked" for 10 minutes (`.LeaverMinutes`). |
| 23 | Results, boards | `.wnl wf bf board onyxia 1 bots` and `.wnl wf bf board onyxia 1` | The bots board lists your clear; the people board doesn't (the run had bots). |
| 24 | Database | `SELECT raid, tier, size, bots, cleared, length_ms, members FROM bossfights_result ORDER BY id DESC LIMIT 3;` on the Modes characters database | One row per run, bots marked `:bot`, `bossfights_progress` best_tier 1. |
| 25 | Website feed | `bash hetzner/bossfights_up.sh live; jq . /opt/openvanilla-herald/public/bossfights_live.json` | During a run, "now" lists it. Afterwards, the clear is under "boards_bots", and "feed" has every run. |
| 26 | Back to Duels | `.wnl wf bf duels` | "Back to Duels."; `mode,0,1`. You stay where you are; Duels' hangout rules (its consumables top-up, outfits) apply again within a minute. |
| 27 | Mode switch, no port | `.wnl wf bf mode boss` in the hangout, then away from it | `mode,1,1` (no teleport), then `mode,1,0` (the addon answers that with `go`). `.wnl wf bf mode duels` gives `mode,0,<hub>`. |
| 28 | One queue at a time | As a dueler, queue for a duel in the Duels window. Then `.wnl wf bf go`. | The Duels window shows you left its queue. Pressing a Duels queue button as a raider makes you a dueler again (`BF mode,0`); during a run it answers `err,busy`. |
| 29 | Duels leaves raiders alone | As a raider, stand in the hangout for two minutes with empty bags. | No Duels consumables or outfit appear (Duels' hangout skips raiders). The Duels hangout bots never pick you. |
| 30 | New character in Boss Fights | `.wnl wf bf mode boss`, log out, make a new character, and log in within 30 minutes. | The new character starts in the hangout as a raider: a `go` line opens the Boss Fights window, and `hi` says mode 1. A character made later starts as a dueler. |

### GM shortcuts

- `.die` kills your target, or you with no target.
- `.revive` brings you back.
- `.tele GurubashiArena` goes straight to the lobby.
- `.npc info` shows a creature's health.
- `.gps` shows your map and position.
- Molten Core's ten bosses are faster with `.die` on each in turn; `status` counts them.
- A solo run: `RAIDSIZE=1 bash hetzner/bossfights_up.sh update`. A raid smaller than its role minimums needs no
  roles.

### Afterwards

```
bash hetzner/bossfights_up.sh testbots off
bash hetzner/bossfights_up.sh update
```

`testbots off` deletes the bots and puts the GM levels back. `update` puts RaidSize 10 and RelaxRoles 120 back.

## Ready raider


A character in Boss Fights doesn't need any setup. About 3 seconds after it arrives in the Gurubashi hangout, the realm makes it ready. That happens when it is alive, out of combat and inside the fence. The realm makes it ready again after every run, and tops up its bags every minute.

### What the realm does

1. **Level.** A character below `OpenVanilla.BossFights.Ready.Level` (default 60) is raised to that level. The realm then:
   - teaches the class's spells (AutoLearn);
   - sets every weapon skill, Defense and Unarmed to their maximum, the same as a duelist gets.
2. **Bags.** Each empty bag slot gets a Traveler's Backpack (`.Ready.Bag`, item 4500).
3. **Talents.** The realm makes active the spec for the talent tree the character's role plays (see below). It uses that tree's raid build (51 points) from the playerbots' PvE builds. Specs the character has never used also get raid builds, not PvP ones.
   - **A player's own choice is never overwritten.** The realm only picks while either of these holds:
     - the character's talents still match a template and the player has never saved a spec;
     - the talents are still exactly what Boss Fights set last time (the `bossfights_ready` row).
   - Changing role (`.wnl wf bf role`) picks again, under the same rule.
4. **Gear.** Every gear set of the class goes in the bags (Warfront's kits). The role's set is worn in three cases:
   - the character is (nearly) bare;
   - the first time, if it wears only gear-set pieces;
   - later, if it still wears the set Boss Fights put on.

   Anything else the character wears is the player's own and stays on.
5. **Consumables.** These are topped up when the character arrives, after every run, and every minute:
   - everyone: potions, flasks, elixirs, food and bandages;
   - mana users: water;
   - each class: its reagents or poisons;
   - hunters: arrows or shells to match the ranged weapon worn (1000, set as the ammunition).

   Nothing given sells for money (`bossfights_world.sql`).
6. **Action bars.** The server lays these out, so they're right before any addon runs:

   | Bar | What goes on it |
   |---|---|
   | Main bar (keys 1 to =) | The active spec's raid abilities |
   | Bottom left | The class's buffs, auras, forms and utility |
   | Bottom right, right, right 2 | Every other class spell |
   | Stance, form and stealth bars | A copy of the main bar |

   - Abilities only go on **empty buttons**.
   - A character under 10 minutes played whose bars Boss Fights hasn't laid out yet has its bars cleared first. At that age only the realm's starter layout is on them.
   - The Boss Fights addon turns all four extra bars on.
   - The Duels addon doesn't lay out its PvP bars or put on its "best kit" for a raider.
   - On the server, Duels' hangout doesn't set up a character until Boss Fights has checked it (`BossFights::Pending`).
7. **Refresh after a run**, back in the hangout:
   - health and mana full, and rage at 0;
   - every cooldown reset;
   - the run's world buffs removed;
   - bags topped up.

Playerbots are left alone; the bot factory gears them.

**Role → talent tree:**

| Class | Tank | Healer | Damage |
|---|---|---|---|
| Warrior | Protection | Fury | Fury |
| Paladin | Protection | Holy | Retribution |
| Priest | Shadow | Holy | Shadow |
| Shaman | Elemental | Restoration | Elemental |
| Druid | Feral | Restoration | Feral |
| Hunter, Rogue, Mage, Warlock | Marksmanship, Combat, Frost, Destruction | (same) | (same) |

### The ready check: `.wnl wf bf ready`

If the character is in Boss Fights and in the hangout, this makes it ready first. Then it answers on addon tag `BF` with one line of `key=value` pairs, plus a chat line:

```
ready,level=60,spec=Protection,spent=51,free=0,sets=3,setsof=3,worn=warrior-fury-h,slots=61,buttons=64,consumables=13,wanted=13,missing=-,ok=1
```

| Key | Meaning |
|---|---|
| level | the character's level |
| spec | the active spec's name, spaces as `_` (`Beast_Mastery`) |
| spent, free | talent points spent and unspent |
| sets | the class's gear sets the character has complete (in the bags or worn) |
| setsof | the class's gear sets |
| worn | the kit key worn whole (`warrior-fury-h`), `own` (gear that isn't from a set), `mixed` (pieces of several sets) or `-` (fewer than 8 items worn) |
| slots | empty slots in the backpack and the bags |
| buttons | action buttons in use (every bar) |
| consumables | wanted items at their count |
| wanted | items wanted (potions, flasks, food, reagents, ammunition) |
| missing | item ids short, joined with `:` (at most 12), or `-` |
| ok | `1` when the character is ready |

`ok` is `1` when all of these hold:
- level is at least `.Ready.Level`;
- talent points are spent;
- `sets` = `setsof` (every set is in the bags or worn);
- something is worn;
- at least 12 action buttons are set;
- `consumables` = `wanted`.

The self-test (0051, `devkit/heraldlite/scenarios/bossfights_selftest.txt`) reads `level`, `spent`, `free`, `sets`, `buttons` and `consumables` by key. Its checks match this line:

| Key | Check |
|---|---|
| level | = 60 |
| spent | > 0 |
| free | = 0 |
| sets | ≥ 1 |
| buttons | ≥ 12 |
| consumables | > 0 |

A stricter check is `ok == 1`, together with `consumables == wanted`.

The realm sends the same line to the addon by itself whenever it makes a raider ready, and after every run. The addon shows it on the Armory tab's **Ready check** (with a **Check again** button), and pops a "Ready for raids" toast. `/bf ready` asks for it.

### Settings

All of these are on by default while `OpenVanilla.BossFights = 1`.

| Setting | Default | |
|---|---|---|
| `OpenVanilla.BossFights.Ready` | 1 | 0 turns the whole ready raider off |
| `.Ready.Talents`, `.Ready.Gear`, `.Ready.Bars` | 1 | each part on or off |
| `.Ready.Level` | 60 | 0: levels aren't raised |
| `.Ready.Bag` | 4500 | the bag for an empty bag slot (0: none) |
| `.Ready.Ammo` | 1000 | a hunter's arrows or shells |
| `.Ready.Consumables` | `13446:10 13444:10 13510:1 13511:1 13512:1 13452:5 9206:5 13454:5 20452:10 8932:20 14530:20` | everyone (counts up to 200) |
| `.Ready.Consumables.Mana` | `8766:20` | mana users |
| `.Ready.Consumables.<Class>` | Rogue `8928:20 20844:20 5140:20`, Mage `17020:20`, Priest `17029:20`, Paladin `21177:40 17033:5`, Druid `17026:20 17038:5`, Shaman `17030:5`, Warlock `6265:6` | each class's own |

Characters table `bossfights_ready` (`bossfights_characters.sql`) keeps what Boss Fights set:
- `spec` and `talents`: the spec it made active and the talents it spent;
- `kit`: the set it put on;
- `bars`: whether it laid out the bars;
- `readied`: when.

Without the table, the realm picks again at every login, and the server log says the table is missing.

### Manual check (add to the smoke test)

| # | What | Do | Expect |
|---|---|---|---|
| R1 | A new raider is ready | Make a new character from the site's Fight now (Boss Fights), and wait 5 s in Gurubashi. | Level 60. Talent frame: the role's tree with 51 points. All 4 extra bars on, with the spec's abilities on keys 1 to =. The bags hold every gear set of the class plus potions, flasks, food and reagents. The Armory tab says **Ready.** and a "Ready for raids" toast shows. |
| R2 | The role decides | `/bf`, Queue tab: **Tank** (a warrior). | Within seconds: Protection active, the warrior set worn, and Protection's abilities on the empty buttons. |
| R3 | Your choice stays | Switch to another spec yourself (the talent frame's spec row), then change role. | Your spec stays. `.wnl wf bf ready` still answers `ok=1`. |
| R4 | Refreshed after a run | Clear (or leave) a run and come back to Gurubashi. | Full health and mana, cooldowns reset, no world buffs left, and the bags topped up. `.wnl wf bf ready` answers `…,ok=1`. |
| R5 | Duelers untouched | A Duels character (not in Boss Fights) in the same hangout. | Duels' PvP bars and kit as before. Nothing from Boss Fights' ready raider. |

## Bot fill


A raid nobody else joins is filled with bots, so one player, or a small party, can raid alone.

### For the player

- **Going solo** on the Queue tab says: "if nobody else comes in 30 s, bots fill the raid (10 players)".
- In the queue the box counts down ("bots fill the empty spots in 20 s"), then shows "bots joining: 3/9" and "9 bots in: starting".
- The raid pops with the person and the bots in **one new copy** of the raid, as any run.
- The run's timer shows "9 bots".
- When the run ends (cleared, abandoned, or the person gone for a minute) the bots log out.

### How it works

1. **The turn.** When the oldest ticket of a pool (same raid, tier, queue and size) has waited `BotFill.After` (30 s), it takes the younger people of its pool who fit (one raid, not one each), then asks for bots for the seats left.
2. **The roles** (`PlanFill`): the missing tanks first, then the missing healers, then damage. A filled raid of 10 aims for 2 tanks and 3 healers (20: 2 and 5; 40: 2 and 10; 3 to 9 seats: 1 and 1). It always meets the queue's role rule, so the ticket pops at once. One case doesn't: a raid size of exactly 4 with the 2-and-2 rule and a damage dealer in it leaves no seat for the rule; it pops when the roles relax after 2 minutes.
3. **The classes** (`FillClass`), of the leader's faction:
   - tanks: Warriors;
   - healers, in turn: Priest, Druid, then Paladin (Alliance) or Shaman (Horde);
   - damage, in turn: Mage, Rogue, Warlock, Hunter, Warrior.
4. **The bots** are characters on the bot AI's own accounts (`RNDBOT*`). They are kept in `bossfights_fill_bot`, and one is made the first time a role, class and faction is needed. A new bot gets its role's talents when it is made (the bot AI's premade builds for tank, healer or damage) and, at its first raid, the bot factory's level-60 epic gear, spells and consumables. Later raids only top up food, potions, reagents and ammo.
5. **The login.** The bot is put at the hangout and its old raid saves are removed before it logs in. It is in Boss Fights from its first update, so Duels' hangout code leaves it alone. When ready (level 60, gear, no wandering or questing, the dungeon strategies on, full) it joins the ticket. The ticket pops when every bot is in.
6. **In the run** the bots are ported like anyone. Inside, the dungeon strategies are switched on. The bot AI takes the group's person as its master: they follow, tank, heal and fight.
7. **Out.** A bot is logged out as soon as nothing wants it:
   - its ticket is gone (the person left the queue or logged out);
   - its run is over or it left;
   - a run with bots also ends when its people have all left, or none of them has been online for a minute.

   A bot that never logs in within a minute is given up, and the ticket asks for another. After three such failures that ticket stops asking ("error").

### Limits and memory

- **`BotFill.Max`** (18) is the most fill bots logged in at once, realm-wide. A raid's whole fill must fit, or the ticket waits for people ("max").
- **`BotFill.MinFreeMB`** (600): no new bots below this much free memory. That is the smaller of the host's `MemAvailable` and the room left under the world server container's limit (cgroup v2 or v1). The ticket then says "memory" and keeps waiting for people.
- **Each bot logged in** costs roughly 10–15 MB (a Player, its session and the bot AI's state), so a full ten (9 bots) is about 100–150 MB while it lasts.
- **The bot AI itself** loads its tables and caches at start, whether or not a bot is online. With bot fill's settings it skips the biggest one, the quest travel table and travel nodes (`AutoDoQuests = 0`; the ~1 GB seen on Duels on 23 October 2026 had them). What it still takes has not been measured on the server yet: `bossfights_up.sh botfill status` prints the world server's memory.
- **The container's limit** is raised to 3200 MB (`BOTFILL_MEM`) when bot fill is on. It is a limit, not a reservation.

### Settings (mangosd.conf; on with `OpenVanilla.BossFights = 1`, but `bossfights_up.sh` writes `BotFill = 0` until `botfill on`)

| Setting | Default | |
|---|---|---|
| `OpenVanilla.BossFights.BotFill` | 1 | bots fill the seats nobody takes |
| `OpenVanilla.BossFights.BotFill.After` | 30 | seconds the oldest ticket waits first (0: at once) |
| `OpenVanilla.BossFights.BotFill.Max` | 18 | most fill bots logged in at once |
| `OpenVanilla.BossFights.BotFill.MinFreeMB` | 600 | no new bots below this |

The bot AI (aiplayerbot.conf), as `botfill on` writes it:

- `AiPlayerbot.Enabled = 1`
- no random bots at all: `RandomBotAutologin = 0`, `Min/MaxRandomBots = 0`, `RandomBotAutoCreate = 0`, `RandomBotLoginWithPlayer = 0`
- none of the roaming parts: `AutoDoQuests = 0`, `RandomBotJoinBG = 0`, `RandomBotJoinLfg = 0`, `RandomBotGuildCount = 0`

`duels_up.sh update` writes `AiPlayerbot.Enabled = 0`, so `bossfights_up.sh update` writes these again while bot fill is on.

### The protocol (BF tag)

- `fill,<1|0>,<after s>` follows the hello: whether bots fill this realm's raids.
- The waiting line gains four fields where bots may fill it (a players' ticket with bot fill on; a self-test ticket only with `bots=1`, so the main self-test's line is unchanged):
  `q,<raid>,<tier>,<queued>,<waited>,<position>,<size>,<needed>,<state>,<seconds>,<ready>,<wanted>`
  The state is one of:
  - `wait`: bots come in `<seconds>`;
  - `joining`: `<ready>` of `<wanted>` in;
  - `ready`: all in, it pops;
  - `full`: people fill it;
  - `off` | `ai` | `memory` | `max` | `error`: bots can't come now, so it waits for people.
- `rbots,<n>`: the run has n bots (to its people, after `pop`).
- Self-test (test accounts): `q <raid> size=<n> bots=1` fills at once. `test state` adds:
  - `bots=` (in my run, or for my ticket);
  - `botsin=` (fill bots on my map copy now);
  - `fillalive=` (fill bots logged in realm-wide);
  - `fill=` (my ticket's state).

### Counts, boards and the website

- Bots are never counted as players: the live counts (`warfront_live` row 2: queued and raiding count people) and `bossfights_now.size` (people).
- `bossfights_result` keeps `size` (everyone) and `bots`. A run with bots ranks on `boards_bots`, never on the people's boards (as before).
- `bossfights_live.json`'s feed and boards give `size` as people and `bots` beside it.

### Commands

```
bash hetzner/bossfights_up.sh botfill on       # the bot AI's tables on the Duels stack (once), the AI, the settings, a restart
bash hetzner/bossfights_up.sh botfill status   # settings, kept bots, online now, the world server's memory, MemAvailable
bash hetzner/bossfights_up.sh botfill off      # BotFill = 0 (the AI off too unless testbots is on), a restart
BOTFILL_AFTER=15 BOTFILL_MAX=27 BOTFILL_MINMB=500 bash hetzner/bossfights_up.sh botfill on   # other numbers
```

`botfill on` runs `hetzner/playerbots_db.sh` with `OW_REALM_DIR=/opt/wenilla-duels NO_RESTART=1`. It puts in the bot AI's own tables (`ai_playerbot_*`) only where none of a script's tables exist yet. Without them, no bot could log in (the reason the Duels hangout bots were switched off on 23 October 2026).

### Self-test

When the server has bot fill on, `hetzner/bossfights_check.sh` runs `devkit/heraldlite/scenarios/bossfights_botfill.txt` after the main scenario:

1. The first test account, alone and as a tank, queues for Onyxia with `size=5 bots=1`.
2. The line names the bots' state.
3. The raid pops with `rbots,4`, and all five are in one new copy (`bots=4`, `botsin=4`).
4. `test kill`, then `end,1`.
5. Back in the hangout: `fillalive=0`.

Then the script checks:
- the stored row (`test = 1`, `bots = 4`, `size = 5`, cleared);
- that no fill bot is still online (`bossfights_fill_bot` joined with `characters.online`).

If the server can't fill the raid (the AI off, memory, the cap), every step after the pop is a skip that names the bots' state, not a failure. With bot fill off, the whole part is one skipped check ("off on this server").

### What the bots don't do (yet)

The pinned playerbots (31e0f32) have a Molten Core strategy (Magmadar, the runes) but **Onyxia's fight strategy is empty**:
- no dodging Deep Breath;
- no tank turning her away from the raid;
- no plan for the whelps or for Bellowing Roar's fear.

The bots tank, heal and fight with their class strategies, and the raid is scaled to its size (health with the size, damage less steeply). A real clear of tier 1 by one person and nine bots is likely but not certain; higher tiers will wipe more. Gear is the bot factory's level-60 epic pick, not Boss Fights' kits.

### Manual checks (B1–B5)

| # | Do | Expect |
|---|---|---|
| B1 | `bossfights_up.sh botfill on`, then `botfill status` | `AiPlayerbot.Enabled = 1`, `BotFill = 1`; the world server up |
| B2 | In game, alone, Damage, queue Onyxia | "bots fill the empty spots in 30 s", then "bots joining: n/9", then the pop |
| B3 | In the raid | 2 Warriors, 3 healers, 4 damage, your faction; they follow you and fight; the timer says "9 bots" |
| B4 | Kill Onyxia (or `.die` on her as a GM) | the clear; the bots log out at once; `botfill status`: 0 online |
| B5 | Queue again, then leave the queue while the bots join | the bots log out within a few seconds; nothing left online |

## Self-test

Two test accounts play the whole mode on the server, with no one at a keyboard, and the result is public:
https://openvanilla.app/community/bossfights_selftest.json. It runs every 2 hours and after every
`bossfights_up.sh update`.

**Turn it on (once, after a release with 0051):**

```
bash hetzner/bossfights_up.sh update            # the 0051 world server, the test column
bash hetzner/bossfights_up.sh selftest on       # SelfTest = 1, a restart, the timer, a first run
```

`selftest now` runs it by hand (exit 0 when all passed); `selftest off` turns it off.

**Who plays.** `hetzner/bossfights_check.sh` makes or repairs two game accounts, BFTEST1 and BFTEST2 (GM level
0), straight in the Modes realm's own account table, with random passwords in
`/etc/openvanilla-bossfights-test.env` (mode 600, never printed). Herald Lite makes their characters the first
time: a Human Warrior (tank) and a Troll Priest (healer), level 60 because the Modes server starts everyone
there. Nothing is made on the live realm or on a public sign-in page.

**What makes them test accounts** (patch 0051, only with `OpenVanilla.BossFights.SelfTest = 1`; the names in
`OpenVanilla.BossFights.TestAccounts`, `"BFTEST*"`):
- They're in Boss Fights from their first login, so Duels' hangout code (its bots, rooms, ladders, auto-queue)
  leaves them alone.
- They queue in a pool of their own: never matched with a player, no role rule, and they may set the run's size
  (`q onyxia size=2`). A player can't set a size.
- Their runs aren't in "Raids now" or the live counts, and their results (`bossfights_result.test = 1`) aren't on
  the boards, the in-game board or the website's feed.
- Their own commands: `test state` (one `k=v` line: mode, hangout, waiting line, run, copy, map, tiers, aura,
  health, mana, world buffs, consumables, level, faction, group), `test kill` (every encounter left: its boss
  killed by the player, so the raid's script, loot and the encounter credit run as in a real kill), `test wipe`,
  `test revive`, `test out` (a step past the fence) and `test reset` (progress, test results, leaver lock,
  ticket, raid save). Anyone else gets `err,test`.

**For everyone** (0051): the waiting line says where you stand (`q,...,<position>,<raid size>,<still needed>`
and "Waiting line: 1 of 10" in chat), and leaving a run puts you back in the hangout ready: alive, full health
and mana, the run's world buffs gone, cooldowns ready (the consumables stay in the bags). The tier aura is read
again 5 s after a clear (the progress row is written in the background).

**What it checks** (`devkit/heraldlite/scenarios/bossfights_selftest.txt`, about 4 minutes):
1. The world server is up, Boss Fights and the self-test are on, the results table has its test column.
2. The website's sign-in path: a guest of the Modes realm service (made once by the script, then resumed) gets
   `/api/play`, whose realm must be realmd's (otherwise players see the realm list); the Boss Fights address
   opens in Boss Fights (`?mode=boss`), once its DNS exists.
3. A clean start (`test reset`), then both in Boss Fights in the Gurubashi hangout: level 60, the shared faction,
   the fence brings a player back.
4. Readiness (patch 0052, `.wnl wf bf ready`): level 60, talents spent and none free, gear sets in the bags, 12+
   action buttons, consumables. Skipped ("ready patch not live") until 0052 answers. Its keys are read with
   `field()`, so the line may be `k=v,...` or `k:v ...`; `BF_READY_LEVEL`, `_SPENT`, `_FREE`, `_SETS`,
   `_BUTTONS`, `_CONSUMABLES` rename them.
5. The waiting line: alone, "1 of 2" and no pop for 6 s; leaving and rejoining.
6. The pop: one new copy of Onyxia's Lair, the same copy for both, a raid group, world buffs and consumables.
7. A wipe is counted, everyone is brought back; the boss is killed; the run is cleared, tier 2 opens, the tier
   aura is on.
8. Both back in the hangout after the 30 s to loot, refreshed (alive, full health and mana, no world buffs,
   out of combat); readiness again.
9. A second run, tier 2 (fortified), in a different copy.
10. Leaving early: the leaver gets the queue lock; the run ends when the last one leaves.
11. The database: the two runs are stored as test runs; nothing in "Raids now"; the test characters are nowhere
    in `bossfights_live.json`.

**The report** (`/opt/openvanilla-herald/public/bossfights_selftest.json`): `ok`, `pass`/`fail`/`skipped`, the
failures, every step with its time and detail, the runs' copy ids, the versions (repo commit, world server
image, Herald Lite). Account and character names are replaced (Raider A, Raider B), addresses removed. The full
Herald Lite report stays root-only in `/opt/openvanilla-bossfights/selftest-last.json`; one line per run goes
to `selftest-history.tsv` there.

**When it fails**: the report's `failures` names the scenario line (`bossfights_selftest.txt:<line> [a|b] <step>:
<reason>`). The usual causes: the world server restarted mid-run (run it again), the test column missing (run
`update`), a run left over (the next run's first steps leave it).

The manual smoke test above still covers what the self-test can't: the windows, real players, bots in a raid.
