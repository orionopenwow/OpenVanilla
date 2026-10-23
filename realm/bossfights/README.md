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
| `bossfights_characters.sql` | `bossfights_player`, `bossfights_account`, `bossfights_progress`, `bossfights_result` (with `bots`), `bossfights_now`. |
| `tests/` | `sh realm/bossfights/tests/run.sh` runs the pure rules' tests (no server). |
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
