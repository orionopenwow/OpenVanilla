# realm/mangos/pending — world server patches waiting for launch day

The image build (`realm/mangos/Dockerfile`, CI job `mangos`) applies only `realm/mangos/*.patch`,
so nothing here is built or deployed today. On launch day move the patches up one folder, in
order, and let CI build `ghcr.io/orionopenwow/openvanilla-mangos` (≈30 min) while the old server runs.

| Patch | Owner | What |
|---|---|---|
| `0002-openvanilla-achievements.patch` | achievements work | see `realm/achievements/PROTOCOL.md` |
| `0003-openvanilla-gameplay.patch` | gameplay | spells by level, free respec, dual spec, hunter starter pet, zone NPCs, account mail, closed race/class pairs |
| `0004-openvanilla-aoe-loot.patch` | gameplay | AoE looting (the one patch that changes the loot code) |
| `0006-openvanilla-reports.patch` | reports & moderation | `.wnl report` / `.wnl appeal`, staff `.wnl mod ...` (console too), repeat-spam filter; see "0006" below |
| ~~`0007-openvanilla-world-channel.patch`~~ (live: moved to `realm/mangos/` on 19 Oct) | Discord bridge | the server-side **World** channel (both factions, auto-joined), `/world`, the log Herald posts to Discord, `.wnl worldsay` (SOAP), `.wnl worldoff/worldon`; see "0007" below |
| `0008-openvanilla-armory.patch` | armory | `.wnl armory [public\|friends\|hidden\|newlink]` → `AR <mode>,<key>`: the website armory's privacy setting; see "0008" below |

Both apply on top of `0001-openvanilla-server-hooks.patch` against CMaNGOS classic **de8f729** (the
`MANGOS_CLASSIC_COMMIT` pinned in wenilla-realm's `upstreams.env`, which `realm-image.yml` reads),
with or without 0002: tested `0001 0003 0004` and `0001 0002 0003 0004` with `git apply`.

The world database side (tables, quests, XP, trainer greetings, config) is in
`realm/classicplus/pending/` — its README has the SQL order. The characters tables
(`classicplus_characters.sql`) must exist before the new server starts.

## 0003 — Classic+ gameplay

New files in `src/game/OpenVanilla/`: `Play.h/.cpp` (channel, settings, zone NPCs, respec, mail,
closed pairs, the per-player update), `PlayState.h`, `AutoLearn.cpp`, `DualSpec.cpp`,
`StarterPet.cpp`, `QuestInfo.cpp` (QZ / QM / QU for the Quests addon). It also extends Wnl.cpp's
CP quest pins (see below). Hooks in the core (each a few lines, marked `Open Vanilla`):

| Where | Why |
|---|---|
| `Player::Update` | `OwPlay::Update` after `UpdateHomebindTime` (queued `.wnl` commands, level-up learning, zone NPCs, spec cast, starter pet) |
| `Player::resetTalentsCost` | 0 while `OpenVanilla.FreeRespec` is on (the trainer's wipe is free too) |
| `Player::LearnTalent` | a learned talent opens its trainer ranks (`OwPlay::OnTalentLearned`) |
| `Player.h` | `GetActionButtons()` accessor (dual spec saves the bars) |
| `ChatHandler::HandleWnlCommand` (Wnl.cpp, bottom) | `np respec spec specname specs qz qm qundo` go to `OwPlay::HandleCommand`; it also notes `hi` |
| Wnl.cpp `AddSpots` / `Pins` | CP: full quest titles (no 48-character cut); objective kinds name their target; item objectives pinned |
| `WorldSession::LogoutPlayer` | `OwPlay::Forget` |
| `WorldSession::HandleCharCreateOpcode` | `CHAR_CREATE_DISABLED` for pairs in `openvanilla_closed_combo` (players only; GMs may) |
| `WorldSession::HandleSendMail` | delivery delay 0 between characters of one account |
| Pet opcodes (action, set action, abandon, unlearn, autocast, cast) and stable (stable, unstable, swap) | refused while a hunter's starter pet is AI-only |
| `WorldSession::HandleCastSpellOpcode` | Tame Beast / Call / Dismiss / Feed / Revive Pet refused (with a chat line) until the taming chain is done |

### Behaviour

* **Spells by level** (`OpenVanilla.AutoLearn`): on every level gained, 5 s after login (catch-up)
  and right after a talent is learned, the player learns every spell/rank their class trainers
  would offer now, by the trainer window's own rules (`GetTrainerSpellState`: level, previous
  rank, required ability, race/class fit, trainer conditions). Lists are built once from every
  class trainer of the class (`npc_trainer` + `npc_trainer_template`), the pet trainers for
  hunters, and the weapon skills weapon masters teach. Talent ranks come only with the talent;
  professions, riding and quest rewards are never touched. Trainers still sell (all grey).
* **Free respec** (`OpenVanilla.FreeRespec`): `.wnl respec` out of combat, alive, outside instances,
  with talents spent → talents reset free (hunter pets are put away as *current*, not lost, and
  called back). Talent wipes at trainers cost 0 as well.
* **Dual spec** (`OpenVanilla.DualSpec`): two specs from level 10. The active spec is the live
  character; the other waits in `openvanilla_spec` / `openvanilla_spec_action`. `.wnl spec <1|2>` starts
  a 5 s cast (Divining Trance's cast bar, spell 5017: a dummy nothing handles); moving, combat,
  death or an interrupt cancels it. On completion: the old spec's talents and bars are saved, the
  talents are reset (no cost) and the new spec's are learned tier by tier, its bars replace the
  current ones (a spec never used starts with the current bars), and a chat line confirms.
* **Hunter starter pet** (`OpenVanilla.StarterPet`): a hunter below 10 who never had a pet gets a real
  hunter pet at login: Human Young Wolf (299), Orc Mottled Boar (3098), Dwarf Young Black Bear
  (1128), Night Elf Young Nightsaber (2031), Undead Duskbat (1512), Tauren Plainstrider (2955),
  Gnome Snow Leopard (1201), Troll Bloodtalon Taillasher (3122) — made like Tame Beast makes one,
  saved as the current pet. Until Beast Training is learned (the taming chain's last reward) it
  takes no commands, Tame Beast / Call / Dismiss / Feed / Revive Pet are locked, it is always
  content, it assists the hunter's target (the pet AI already defends the hunter), comes back 30 s
  after dying once the hunter is out of combat (or 3 s after simply going missing), is put away
  while a Taming Rod charm is up, and below level 10 deals about 70% damage. Completing the chain
  unlocks everything at once (`PG 1`) and it is a normal pet.
* **Zone NPCs**: `.wnl np` and every zone change send the zone's service NPCs (repair, vendor,
  flight master, innkeeper, banker, and class trainers of the player's own class) that are not
  hostile to the player, in zone map coordinates (`Map2ZoneCoordinates`, the conversion Wnl.cpp
  uses for CP pins); spawns from game events are left out; max 80.
* **Account mail** (`OpenVanilla.InstantAccountMail`): mail (and items) between characters of the same
  account arrive at once.
* **Closed pairs** (`OpenVanilla.ClosedCombos`): `openvanilla_closed_combo` (from
  `classicplus_races.sql`) is read once; players can't create those pairs, existing characters play on.

## 0004 — AoE looting (`OpenVanilla.AoeLoot`, `OpenVanilla.AoeLoot.Range`)

`OpenVanilla/AoeLoot.cpp`; hooks in `WorldSession::HandleLootOpcode` (gather before the window opens,
`AL` after), `HandleAutostoreLootItemOpcode` (a gathered slot is taken from its own corpse),
`Loot::SendGold` (gathered coins leave their corpses), `Loot::Release` (the window gets back its
own items), and `Loot` gains a friend and two members. Solo or free-for-all groups only: up to
10 corpses within 30 yd that the player may loot and nobody else is looting, 16 slots. Quest and
conditional drops and quest starters stay on their corpse; a corpse emptied this way is marked
looted (skinnable if it can be skinned). Skinning, mining, herbalism, pickpocketing are untouched.

## 0006 — reports and moderation (`OpenVanilla.Reports`, default on)

New `src/game/OpenVanilla/Reports.h/.cpp`; tables in `realm/classicplus/pending/classicplus_reports.sql`
(must exist before the server starts taking reports). Applies after 0001–0005 (`git apply`, tested).

| Where | Why |
|---|---|
| `ChatHandler.cpp` say / yell / emote, public channels (General, Trade, LFG, static ones such as World) | `OwReports::OnPublicChat`: remembered for report context; the same text more than 3 times in 20 s is dropped (4th on), logged once per burst in `openvanilla_mod_log` (kind `hide`), the player gets a system line with the reason and how to appeal. Moderators/GMs and addon traffic (`LANG_ADDON`, addons' hidden channels) are never filtered. |
| `ChatHandler.cpp` whisper | `OwReports::OnWhisper`: remembered for report context |
| `Chat.cpp` command table | `wnl` allowed from the console, for `.wnl mod ...` over SOAP (everything else still needs a player) |
| `Wnl.cpp` `HandleWnlCommand` | `report`, `appeal`, `mod` go to `OwReports` first |

* **`.wnl report <category>,<name>,<note>,<lines>`** (fields escaped `\\` `\c` `\n`; categories spam,
  harassment, cheating, gold-seller, name, other) → one `openvanilla_report` row: reporter guid/name, target
  guid/name, category, note (300), the client's own lines (1200), and `context` JSON: zone, map, x, y, time,
  target_online and `server_lines` — the last 20 lines the server saw in the past 10 minutes between the two
  (public lines of either, whispers between them; per-speaker ring of 60 lines in memory). Answer `RP ok` or
  `RP err,<ratelimit|unknown|dup|self|bad|off>`. 1 per 30 s, 10 per hour per character; the same pair within
  10 minutes is `dup` and its note is appended to the open report.
* **`.wnl appeal <text>`** → `openvanilla_appeal` (Herald adds it to the player's newest case).
* **`.wnl mod mute <name> <minutes> <reason>`** (reason `auto:...` marks Herald's automatic 10-minute mute),
  **`unmute <name> [text]`**, **`kick <name> <reason>`**, **`warn <name> <text>`**, **`note <name> <text>`**
  (`openvanilla_mod_note`), **`spamok <name> [minutes]`** (lift the spam filter, default 60). Moderator level and
  up, or the console; never on an account of equal or higher level. Mute is the stock machinery (session
  `m_muteTime`, `account.mutetime`, `World::WarnAccount`); the player sees the reason and
  `To appeal: /appeal <your side>`. Everything goes to `openvanilla_mod_log`. Bans stay the stock `.ban`.
* Herald (`bot/herald_mod.py`) reads all four tables; see hetzner/README.md "Moderation desk".

## 0007 — the World channel and the Discord bridge (`OpenVanilla.WorldChannel`, default on)

New `src/game/OpenVanilla/World.h/.cpp`; tables in `realm/classicplus/pending/classicplus_world.sql` (run it before
the server starts); Herald's side is `bot/herald_bridge.py`, the client's `Chat/World.lua`; the whole picture
and the moderation rules are in `docs/DISCORD_BRIDGE.md`. Applies after 0001–0005 alone and with every
combination of 0006 / 0008 / 0009 (all eight checked with `git apply` on de8f729; `g++ -fsyntax-only` with
the game target's flags clean on every changed file alone and with all four; `World.cpp`, `Wnl.cpp` and
`Chat.cpp` in each combination).

| Where | Why |
|---|---|
| `CharacterHandler.cpp` end of `HandlePlayerLogin` | `OwWorld::OnLogin`: join World unless the character switched it off (`openvanilla_world_pref`) |
| `Channel::Say`, after the stock checks | `OwWorld::OnSay`: World lines go to the Alliance and the Horde channel in `LANG_UNIVERSAL`, 1 line / 2 s (GMs exempt), mute and anticheat silence honoured, logged to `openvanilla_world_log` |
| `Channel.h` | `IsMember`, `SendToMembers`, `MakeServerOwned` (World is made static: no owner, password, moderators or join/leave announcements, even if a player made a "World" first — which also makes 0006's filter see it) |
| `Chat.cpp/.h` | `.world <text>`; a second, console-enabled `wnl` entry so SOAP reaches `.wnl worldsay` when 0001's entry is player-only (dead but harmless with 0006 / 0009, whose earlier entries already take the console) |
| `Wnl.cpp` `HandleWnlCommand` | `worldsay guildsay worldon worldoff guildlink` go to `OwWorld::HandleCommand` (players and the console) |
| `Guild.cpp` `BroadcastToGuild` | `OwWorld::OnGuildChat`: logs the guild's lines when it is linked to a Discord channel (`openvanilla_guild_bridge`, re-read once a minute) |

* `.wnl worldsay <Name> <text>` (GM 2+ or console): `WD W,<Name>,<text>` to everyone in World with the suite,
  `[World] [D] Name: text` as a system line to the others; logged with guid 0 (Herald skips those).
* `.wnl guildsay <guildId> <Name> <text>`: the same into one guild (`WD G,...`). `.wnl guildlink <6 digits>`:
  a guild master or officer confirms a link Herald offered (`openvanilla_guild_link_code`).
* `.wnl worldoff` / `.wnl worldon`: leave World and stay out across logins / come back; answers `WO 0` / `WO 1`.
* `openvanilla_world_log` keeps the newest 1,000 rows (trimmed every 10 inserts).
* Not yet run in game: a test realm should check two characters of opposite factions in World, the 2 s limit,
  a muted player, `worldoff` across a relog, `.wnl worldsay` over SOAP, and a Discord round trip with Herald.

## Addon lines (server → client)

Same transport as Wnl.cpp: a `CHAT_MSG_PARTY`/`LANG_ADDON` line from the player's own guid,
`WNL\t<TAG> <seq> <i>/<n> <body>` (chunks of 200), its own sequence numbers per player.

| Tag | Body | When |
|---|---|---|
| `NP` | `<zoneId>;<npcId>,<x>,<y>,<flags>,<name>[,<subname>];...` — x/y 0..1 (4 decimals), flags letters `R V F I T B` (repair, vendor, flight, innkeeper, class trainer of your class, banker) in that order, name/subname with `, ; | tab` blanked; the 6th field only when the NPC has a subname. Just `<zoneId>` when none. | `.wnl np`, zone change |
| `CP` (changed) | `<questId>,<x>,<y>,<kind>,<title>;...` as before, but `<title>` is the full title and `<kind>` is `GIVER`, `TURNIN`, `OBJ:m<creatureId>`, `OBJ:o<objectId>` or `OBJ:i<itemId>` (new: items to collect, at the creatures/chests that drop them as quest loot, max 2 per source). Clients that read `OBJ` should match the prefix. | Wnl.cpp's 5 s pin update |
| `QZ` | `<zoneId>;<questId>,<x>,<y>,<level>,<minLevel>,<giverName>,<title>;...` — quests the player can take now from givers spawned in the zone (one giver each, max 60) | `.wnl qz` |
| `QM` | `<questId>,<chainPos>,<chainLen>,<xp>,<turnInX>,<turnInY>,<turnInZoneId>,<turnInNpc>,<title>;...` — one per quest in the log; chain from PrevQuestId / NextQuestInChain; xp for this player; turn-in at the first spawned ender (`0,0,0,` and an empty name when unknown) | `.wnl qm` |
| `QU` | `ok,<title>` or `err,<reason>` (`notfound`, `full`, `cannot`) — takes back a quest abandoned in the last 10 minutes (seen leaving the log unfinished; progress restarts, start items are given again) | `.wnl qundo <title>` |
| `LL` | `<spell name>;...` with ` (Rank n)` when the spell has a rank, e.g. `Fireball (Rank 3);Frost Nova` | level-up, login catch-up, new talent — only when something was learned |
| `RS` | `ok` or `err,<reason>`; reasons: `disabled`, `dead`, `combat`, `instance`, `notalents` | `.wnl respec` |
| `SP` | `<active>,<count>;<name1>;<name2>` — count 1 below level 10 (or tables missing), 2 from 10; names default `Spec 1` / `Spec 2` (max 24 chars) | login, `hi`, `.wnl specs`, level 10, switch, rename, refused/cancelled switch |
| `PG` | `0` = starter pet, AI only (hide the pet bar); `1` = normal | hunters: login, `hi`, change |
| `RP` | `ok` or `err,<reason>` (ratelimit, unknown, dup, self, bad, off) | `.wnl report` |
| `WD` | `<W\|G>,<name>,<text>` — a Discord line for World (`W`) or for the player's guild (`G`); name `A-Za-z0-9_.-` (24), text up to 255 bytes | `.wnl worldsay` / `.wnl guildsay` (Herald) |
| `WO` | `1` or `0` — World on/off for this character | `.wnl worldon` / `.wnl worldoff` |
| `AL` | `<corpses>,<copper>;<slot>,<source>;...` — corpses in the window (1 = only the opened one), total copper, then each visible slot with its source: `0` the opened corpse, `1..n` gathered corpses | after a corpse's loot window opens |

Client → server: `.wnl np`, `.wnl respec`, `.wnl spec <1|2>`, `.wnl specname <1|2> <name>`,
`.wnl specs`, `.wnl qz`, `.wnl qm`, `.wnl qundo <title>` (all silent; refusals of `spec` also print a plain chat line).

## Verification

* Patches apply: `0001 0003 0004` and `0001 0002 0003 0004` on de8f729 (`git apply`).
* Compile: `g++ -fsyntax-only` with the game target's flags passed for every new and changed file;
  a real `cmake` + `make game` of the patched tree (PlayerBots off, PCH off) — see the status line
  at the end of this file.
* SQL: `realm/classicplus/pending/README.md`.
* Not yet run in game: a test realm should walk through a level-up (LL, spells), `.wnl respec`,
  a spec switch with a hunter pet out, a new Human hunter (wolf at login, chain in Goldshire,
  PG 0 → 1), AoE looting of a pack (take items from each source, skin the corpses after), and a
  mail between alts.

## Rollback

* Runtime, no rebuild: set the feature's `Open Vanilla.*` line to 0 in `mangosd.conf` and restart
  (`realm/classicplus/pending/openvanilla_gameplay_conf.sh rollback` turns them all off).
* Full: move 0003/0004 back to `pending/` (0004 depends on 0003; 0003 can stay without 0004) and
  rebuild the image; the database changes can stay (see the other README for each undo).

## 0009 — in-game LIVE marks (streams & creators)

`0009-openvanilla-live.patch`: new `src/game/OpenVanilla/Live.h/.cpp` plus a `wnl` command-table entry in
`Chat.cpp/.h` that sees `.wnl livestreamers` / `.wnl liveopt` first and passes everything else to
the stock `HandleWnlCommand`. Applies after 0001–0005 alone and after 0001–0005 + 0006 + 0007 (both
checked with `git apply` on a de8f729 worktree; `c++ -fsyntax-only` clean on `Live.cpp` and
`Chat.cpp` both ways).

* `.wnl livestreamers Name;Name;...` (`-` clears) — console or GM 2+; Herald
  (`bot/herald_streams.py`) sends it every 5 minutes from `streams.json`'s `ingame` list.
* `.wnl liveopt 0|1` — any player, silent; the Social addon's "Show me as LIVE" switch (off by
  default) sends it on login, /reload and every change. Kept in memory for the session.
* `LV Name;Name;...` / `LV -` — to every client with the suite when the marked set (on Herald's
  list ∩ online ∩ opted in) changes, and to a player right after their `liveopt`.
  `Social/Live.lua` turns it into the ● LIVE marks (friends, /who, the Dungeons board, Persona's
  tooltip, target badge and profile) and `/live`.

## 0008 — armory privacy (`.wnl armory`)

`0008-openvanilla-armory.patch`: new `src/game/OpenVanilla/Armory.h/.cpp`, and two lines in `OwPlay::HandleCommand`
(`OpenVanilla/Play.cpp`, from 0003) that hand `armory` to it — no `Chat.cpp`/`Wnl.cpp` hunks, so it applies after
0001–0005 alone and with any of 0006 / 0007 / 0009 (all eight combinations checked with `git apply` on a
de8f729 + 0001–0005 tree; `c++ -fsyntax-only` with the game target's flags clean on `Armory.cpp` and `Play.cpp`).
Needs `realm/classicplus/pending/classicplus_armory.sql` (without the columns it answers `AR err,off` and logs once).

* `.wnl armory` → `AR <mode>,<key>` (no row = `public,`).
* `.wnl armory public|friends|hidden` → stores it in `classiccharacters.openvanilla_character.armory` and answers the same
  way. Picking `friends` the first time makes the key: 20 characters `a-z0-9` from `std::random_device`.
* `.wnl armory newlink` → a new key (and friends-only); the exporter deletes the old file on its next run.
* `AR err,bad` (unknown word), `AR err,rate` (more than one change per 3 s), `AR err,off` (columns missing).
* The Social addon (`Social/Armory.lua`) asks once per connection and shows the copyable link
  (`https://openvanilla.app/armory/character.html?r=<realm slug>&n=<Name>[&k=<key>]`); docs/ARMORY.md has the rest.
* Not yet run in game: a test realm should set each mode, check the row, and see the next export follow it.
