# Discord ↔ World chat bridge

The realm has a server-side chat channel named **World** that every character joins at login (both
factions hear each other). Discord's **#world** channel is linked to it both ways by Herald:

```
in game                                  world server (patch 0007)                 Herald (bot/herald_bridge.py)        Discord
/world hi  ── or the World tab, /4 hi ─> Channel::Say ─> OwWorld::OnSay ─────────> tails openvanilla_world_log ─────────────> #world
                                          (rate limit, mute, both factions)        every 2 s, batched                     **Thrall** (Shaman): hi
                                          INSERT classiccharacters.openvanilla_world_log
World tab:  [D] Anna_B: hey  <──────────  .wnl worldsay Anna_B hey  <──────────── SOAP console  <─────────────────────── Anna B: hey
            (WD W,Anna_B,hey)             (staff/console only)                    role, mutes, rate, 255 bytes
```

Optional: an officer can link a guild's chat to another Discord channel the same way (`/guild discord
#channel` on Discord, `/guildlink <code>` in game; `.wnl guildsay`).

## Pieces

| Piece | File | What |
|---|---|---|
| World server | `realm/mangos/pending/0007-openvanilla-world-channel.patch` (`OpenVanilla/World.h/.cpp`) | the channel, `/world`/`.world`, the log, `.wnl worldsay`, `.wnl worldoff/worldon`, guild links |
| Tables | `realm/classicplus/pending/classicplus_world.sql` | `openvanilla_world_log`, `openvanilla_world_pref`, `openvanilla_guild_bridge`, `openvanilla_guild_link_code` |
| Herald | `bot/herald_bridge.py`, hooked from `bot/herald.py` | both directions, `/bridge` and `/guild` slash commands |
| Chat addon | `Data/Interface/AddOns/Chat/World.lua` | the World tab, `[W]`, `[D]` lines, channel cycle, `/world`, settings |
| Grants | `hetzner/herald_up.sh` | Herald's database login may edit the guild link tables |
| Tests | `tests/test_herald_bridge.py`, `devkit/sim/tests/chat_world.lua` (+ `devkit/sim/ext/world.lua`) | fakes for Discord, SOAP, the DB and the server |

## Setup (launch day)

1. **World server.** Move `0007` into `realm/mangos/` with the other pending patches (it applies after
   0001–0005 alone and with any of 0006 / 0008 / 0009) and build the image. The feature switch is
   `OpenVanilla.WorldChannel` in `mangosd.conf` (default 1; 0 = no World channel, `.wnl worldsay` refuses).
2. **Tables.** Run `classicplus_world.sql` against `classicmangos` *before* the new server starts:
   ```
   docker compose exec -T -e MYSQL_PWD="$DB_ROOT_PASSWORD" mariadb mariadb -uroot classicmangos < classicplus_world.sql
   ```
3. **Herald's grants.** Re-run `hetzner/herald_up.sh`: it grants the guild link tables once they exist
   (the log is covered by the `SELECT` on `classiccharacters.*` Herald already has). The console account
   (`SOAP_USER`, HELPDESK, GM level 3) is the one the support desk made; SOAP runs commands at console
   level, which `.wnl worldsay` requires.
4. **Discord.**
   * Developer Portal → your bot → *Bot* → **Message Content Intent** on (Herald asks for it while the
     bridge is enabled; without it Discord refuses the login).
   * A text channel whose name (or the part after `│`, e.g. `🌍│world`) is `world` — or set `BRIDGE_CHANNEL`.
     Herald needs *View*, *Send Messages*, *Add Reactions* and *Read Message History* there.
   * Slow mode on #world is a good idea anyway (Herald also rate-limits each member).
5. Restart Herald (`systemctl restart openvanilla-herald`). The log says `[bridge] ...` if something is
   missing; `/bridge status` (staff) shows the channel, the last log id and the ignore list.

Herald starts at the *end* of the log the first time (no backlog flood) and remembers the last id it
posted (`bridge_state` in its SQLite), so a restart carries on where it stopped.

### Environment (`/etc/openvanilla-herald.env`)

| Variable | Default | Meaning |
|---|---|---|
| `BRIDGE_ENABLED` | `1` | `0` turns the bridge off (and Herald stops asking for the Message Content intent) |
| `BRIDGE_CHANNEL` | `world` | the Discord channel linked to World (name, or the part after `│`) |
| `BRIDGE_POLL_SEC` | `2` | how often the log is read |
| `BRIDGE_USER_GAP_SEC` | `3` | per Discord member: at least this many seconds between relayed messages |
| `BRIDGE_USER_PER_MIN` | `12` | per Discord member: at most this many a minute |
| `BRIDGE_ROLE` | `Adventurer` | who may talk into the game (the old `Player` role counts too); staff always may |
| `SUPPORT_DB_*`, `CHARACTERS_DATABASE` | from `herald_up.sh` | the characters database |
| `SOAP_URL`, `SOAP_USER`, `SOAP_PASS` | from `herald_up.sh` | the world server's console |

## What players see

**In game.** A **World** tab next to the chat tabs (on by default; right-click hides it, bring it back
from any chat tab's right-click menu, the Chat settings or `/cpchat world`). While the tab is hidden,
World lines show in the main window as `[W] [Name]: text`. Lines from Discord look like
`[D] Anna_B: text`, the `[D]` in Discord blue; the tab carries the Chat_Discord mark while Discord
lines are shown. Talk with `/world <text>`, by pressing Enter while the World tab is open, with
**Tab** in an empty input line (it cycles Say → Party → Raid → Guild → World; Shift+Tab goes back) or
with the channel number (`/4 text`). Chat settings: **World tab**, **Show Discord messages**,
**Join World chat** (off sends `.wnl worldoff`: the character leaves World and stays out across logins
until it is switched on again; `.wnl worldon` / `.wnl worldoff` typed by hand flip the setting too).
Players without the addon suite get Discord lines as system lines: `[World] [D] Anna_B: text`.

**On Discord.** `**Thrall** (Shaman): text` — class from the log, item and quest links as `[Name]`,
batched (one post per poll with every new line, split at 2,000 characters on line boundaries),
mentions disabled (`@everyone`, `<@id>` are defused too), Discord markdown escaped, web links shown as
text without previews.

Discord messages become one game line: custom emoji → `:name:`, emoji → `:their_name:`, spoilers →
`[spoiler]`, attachments / embeds / stickers → `[image]`, markdown stripped, `|` → `/`, line breaks
→ spaces, cut at 255 bytes. The sender's display name becomes an ASCII game name (`Zoë the Great` →
`Zoe_the_Great`, max 24).

## Moderation

Rules on the server (they apply to every World line, whatever client sent it):

* **One line per 2 seconds** per character (GMs exempt); a faster line gets "World: one line every 2
  seconds, please." and is not sent or logged.
* **Mutes**: a muted account (stock `.mute`, or `.wnl mod mute` from the moderation desk) cannot talk in
  World; the anticheat's silence lets the player see only their own line (nothing is logged).
* The receiver's **ignore list** applies to player lines; the Chat addon applies it to `[D]` names too.
* The channel belongs to the server: it is made *static* (no owner, no password, no moderators, no
  join/leave spam), even if a player had made a channel called World first.
* With patch 0006 the reports system sees World like any public channel: lines go into report context,
  and the repeat-spam filter (same text more than 3 times in 20 s) applies.

Rules in Herald (Discord → game):

* Only members with the **Adventurer** role (or staff) are relayed; **bots and webhooks never** (no loops).
* **Per-member rate limit** (3 s gap, 12 a minute); a dropped message gets a ⏳ reaction.
* **Mutes**: a member in a **Discord timeout** is not relayed, nor is anyone whose game name is a
  character currently muted from #moderation (Mute 1h / Mute 24h for their length, Herald's automatic
  10-minute mute until it runs out or is undone; read from `mod_cases`). Those characters' World lines
  are not posted to Discord either.
* **Shared ignore list** (staff): `/bridge ignore member:@x` or `character:Name` stops relaying that
  person both ways; `/bridge unignore`, `/bridge status`.
* Discord lines are logged too (`guid` 0) so moderators can see what reached the game; Herald skips
  them when posting, so nothing echoes.

Turning it off: `BRIDGE_ENABLED=0` + restart Herald (game ↔ Discord stops, World keeps working), or
`OpenVanilla.WorldChannel = 0` + restart the world server (no World channel at all).

## Server reference

Commands (`OpenVanilla/World.h`):

| Command | Who | What |
|---|---|---|
| `.world <text>` | player | say a line in World (joins first unless switched off) |
| `.wnl worldoff` / `.wnl worldon` | player | leave World and stay out (`openvanilla_world_pref`) / come back; answers `WO 0` / `WO 1` |
| `.wnl worldsay <Name> <text>` | GM level 2+ or the console (SOAP) | a Discord line to everyone in World: `WD W,<Name>,<text>` to clients with the suite, `[World] [D] Name: text` system line to the rest; logged with guid 0 |
| `.wnl guildsay <guildId> <Name> <text>` | GM / console | the same into one guild's chat (`WD G,...`) |
| `.wnl guildlink <code>` | guild master or officer | confirm a guild ↔ Discord channel link Herald offered |

`openvanilla_world_log` (id, guid, name, class, guild, text, created): every World line (guild 0) and every
line of a linked guild; a ring of the newest 1,000 rows (the server trims it every 10 inserts).
Names are cleaned to `A-Za-z0-9_.-` (24), texts to printable characters (255 bytes, whole UTF-8).

## Tests

* `python3 -m unittest tests.test_herald_bridge` — formatting and escaping, links, 2,000-character
  splitting and batching, first start / restart, echo suppression, guild routing, roles, the per-member
  rate limit, the ignore list, mutes from the moderation desk and Discord timeouts, attachments and
  length, SOAP failures, the slash commands, the guild link flow, the SQL BridgeRealm sends, and that
  the bridge's `on_message` sits beside herald_mod's (`bot.add_listener`) instead of replacing it.
* `lua5.1 devkit/sim/run_tests.lua "Chat World"` — the World tab, `[W]`, `[D]` lines, ignore list,
  the settings, hiding the tab, `/world`, Enter in the tab, the channel cycle, `worldoff/worldon`.
* World server: `git apply` of 0007 after 0001–0005 alone and with every combination of 0006 / 0008 /
  0009, and `g++ -fsyntax-only` with the game target's flags on every changed file (see
  `realm/mangos/pending/README.md`). Not yet run on a live realm: a test realm should check two
  characters of opposite factions talking in World, the 2-second limit, a muted player, `worldoff`
  across a relog, and a real Discord round trip.
