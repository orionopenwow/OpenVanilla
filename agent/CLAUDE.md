# Open Vanilla workspace: notes for your AI agent

You are helping a player change **their own copy** of Open Vanilla: their addons, their single-player
world (Play Solo) and realms they host themselves. This file is the guide. Read it before you change
anything. Starter tasks are in `Agent/prompts/`.

Open Vanilla is an independent, open-source fan project for the 1.12.1 (build 5875) game client. It is not
affiliated with Blizzard Entertainment or with the maker of the AI tool you are.

## What you may and may not touch

You work only on this PC, in this folder and in the player's own server folders.

- **Never touch the official Open Vanilla realm** or any server the player does not run. You have no access
  to it, and nothing here can change it. If the player asks, explain that changes apply to their own
  copy and their own realms only.
- **Never modify Blizzard game files**: the player's World of Warcraft 1.12.1 folder (`WoW.exe`,
  `Data\*.MPQ`, `WTF\`) and anything under `Interface\FrameXML`, `Interface\GlueXML` or a
  `Blizzard_*` addon. Read them if you must; do not write, extract, copy or share them.
- **Never read out, paste, print or send passwords, tokens or keys.** Server configs contain database
  passwords (`LoginDatabaseInfo`, `WorldDatabaseInfo`, `CharacterDatabaseInfo` in `mangosd.conf`) and
  `Settings\settings.json` can hold a saved game password. Use them locally if a task needs them; never
  copy them into chat, commit messages, websites, bug reports or files outside this PC. Ask the player
  to type secrets themselves.
- **Back up first.** Before you edit any file that already exists, copy it into
  `Backups\ai-<yyyy-mm-dd-hhmm>\` keeping its relative path, and tell the player where the copy is.
  Before any database change, export the tables you touch (or ask the player to press Backup in the
  launcher's HOST tab).
- **Program files are off limits**: `OpenVanilla.exe`, `app\`, `Game\` and `Server\www\` are replaced by
  every update. Change user-data folders only (below).
- Do not download or run code from the internet without telling the player what it is and why.
- Small steps. Say what you are about to change, change it, say how to test it, and how to undo it.

## Folder layout (layout 2)

Program files (the install folder; an update replaces them):

```
OpenVanilla.exe            the launcher: the player starts everything here
app\                   the launcher's internals (app\addons: the Classic+ addons it ships)
Game\Open Vanilla Game.exe  the Open Vanilla engine; Game\benilla-config\ holds its settings
Server\www\            the realm website the dedicated server serves
links.txt              the player's own link overrides
```

User data (survives updates; this workspace is its root). For the portable zip it is the folder
beside `OpenVanilla.exe`; for the installer it is `%LOCALAPPDATA%\OpenVanilla`; `OPENVANILLA_DATA_DIR` overrides it.

```
CLAUDE.md, AGENTS.md   this guide (AGENTS.md for other AI tools)
Agent\                 README.md and prompts\*.md (the starter prompt library)
AddOns\Enabled\        addons every game client loads; PLAY copies them into the client it starts
AddOns\Disabled\       addons the player switched off in the launcher
Realms\Solo\           Play Solo: SPP Classics (CMaNGOS) on this PC, with bots
Realms\SoloPack\       the older Open Vanilla solo pack (Host for friends runs on it)
Realms\Hosted\         the realm this PC hosts for friends
Screenshots\  Logs\  Backups\
Settings\              settings.json, server.json, layout.json (launcher state)
Cache\                 downloads and live content: never edit
```

Logs worth reading: `Logs\launcher.log`, `Logs\update.log`, `Logs\web-backend.log`,
`Logs\spp-mangosd.log` and `Logs\spp-realmd.log` (Play Solo / dedicated server),
`Realms\Hosted\logs\` (hosted realm).

## Addons (Lua 5.0, the 1.12 client)

An addon is a folder `AddOns\Enabled\<Name>\` with `<Name>.toc` and its `.lua` files.

```
## Interface: 11200
## Title: MyFirstAddon
## Notes: One line about what it does.
## Author: <player>
## Version: 0.1.0
## SavedVariables: MyFirstAddon_DB
MyFirstAddon.lua
```

The 1.12 client runs **Lua 5.0**, not 5.1. Rules that bite:

- No `#t` length operator: use `table.getn(t)`. No `%` operator: use `math.mod(a, b)`.
- No `select()`, no `string.gmatch` (use `string.gfind`), no `s:upper()` string methods (use
  `string.upper(s)`). Varargs are the `arg` table, not `...` in expressions.
- Event handlers take no parameters: read the globals `this`, `event`, `arg1` ... `arg9`.
  `frame:SetScript("OnEvent", function() if event == "PLAYER_LOGIN" then ... end end)`
- 1.12 has no `SetSize` (use `SetWidth` / `SetHeight`), no `C_` namespaces, no `hooksecurefunc` (hook by
  saving the old global function and calling it), no clipboard API, and no retail-only events.
- Slash commands: `SLASH_MYADDON1 = "/myaddon"` and `SlashCmdList["MYADDON"] = function(msg) ... end`.
- Add a window's name to `UISpecialFrames` so Escape closes it.
- SavedVariables are written when the player logs out or types `/reload`.
- Test in game with `/reload` after each change. Lua errors appear in the game's error dialog; ask the
  player to copy the text (or a screenshot) if you need it.

The Classic+ addons (Meters, Quests, Bags, Social, Essentials, Assistant ...) share **WenillaCore**, a
settings registry and window kit. A new addon may use it (`## Dependencies: WenillaCore`):
`W:RegisterSchema(id, {title=, desc=, defaults=, options=})`, `W:RegisterAddon(id, refresh)`,
`W.UI.Window(name, {width=, height=, title=, skin=true})`, `W.UI.Button`, `W.UI.Label`,
`W.UI.SwitchRow`, `W.UI.Tabs`. Read `AddOns\Enabled\WenillaCore\*.lua` for the exact API.

**Do not edit the shipped Classic+ addons in place**: each launcher update puts them back. To change
one, copy it to a new folder with a new name (and a new `.toc` title), or write a small separate addon
that changes what you need.

## Your own servers

| What | Where its settings are | Notes |
|---|---|---|
| Play Solo (SPP Classics) | `Realms\Solo\SPP_Classics_V2\SPP_Server\Settings\vanilla\mangosd.conf` (also `realmd.conf`, `aiplayerbot.conf`) | Edit the file itself (back it up first); restart Solo to apply |
| Host for friends | `Realms\Hosted\custom\mangosd.conf` (create it) | `etc\*.conf` is rebuilt at every start from the defaults plus `custom\`: put only the lines you change in `custom\`, e.g. `Rate.XP.Kill = 2` |
| Older solo pack | `Realms\SoloPack\custom\mangosd.conf` | Same rule as Host for friends |
| Dedicated server | the SPP folder chosen in HOST > Dedicated server, `Settings\vanilla\mangosd.conf` | Restart from the launcher to apply |

Common `mangosd.conf` keys: `Rate.XP.Kill`, `Rate.XP.Quest`, `Rate.XP.Explore`, `Rate.Drop.Money`,
`Rate.Drop.Item.*`, `Rate.Rest.InGame`, `PlayerLimit`, `Motd`, `AiPlayerbot.*` (in `aiplayerbot.conf`).
The servers are CMaNGOS (classic); its documentation applies.

Start and stop everything from the launcher: **PLAY** with the Solo switch (Play Solo), **HOST > Host
for friends**, **HOST > Dedicated server**. Closing the game stops Play Solo and saves the world.

### GM commands (in game, on your own realm)

Commands need a GM account. On the world console (HOST > Dedicated server has a console box) run
`account set gmlevel <ACCOUNT> 3`, then log in again. Useful in-game commands: `.gm on`,
`.levelup 10`, `.additem <itemId> [count]`, `.tele <place>`, `.npc add <creatureEntry>`,
`.npc delete`, `.reload all`, `.server info`, `.help`. Type `.help <command>` for details: the exact
set depends on the server version.

### Database changes (custom NPCs, vendors, items)

The world database (`creature_template`, `npc_vendor`, `item_template`, ...) runs on this PC while the
realm runs. Use entry numbers above the stock range (for example 190000+) for anything new. Write the
change as a `.sql` file in `Agent\sql\` first, show it to the player, back up the affected rows, then
apply it. Most template changes need a server restart (`.reload` covers only some tables).

## How to work with the player

- They may be new to programming: explain in plain words, one step at a time.
- Prefer creating new files over editing existing ones. Keep changes small and reversible.
- After each change: what changed, how to test it (in game, `/reload`; for servers, restart from the
  launcher), and how to undo it (the backup path).
- If something needs the official Open Vanilla team (the official realm, the website, accounts), say so and
  stop: point the player to the Open Vanilla Discord or GitHub issues.
