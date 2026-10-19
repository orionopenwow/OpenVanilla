# Open Vanilla workspace (for any AI coding agent)

This folder is a player's own Open Vanilla data folder: their addons, their single-player world and realms
they host themselves. **Read `CLAUDE.md` in this folder before changing anything**: it is the full
guide (folder layout, Lua 5.0 addon rules, server settings, GM commands) and its rules apply to every
AI tool, not only Claude Code.

The short version:

1. Work only on this PC, in this folder and the player's own server folders. Nothing here can change
   the official Open Vanilla realm or anyone else's server.
2. Never modify Blizzard game files (the WoW 1.12.1 folder, MPQs, FrameXML, `Blizzard_*` addons) or the
   program files (`OpenVanilla.exe`, `app\`, `Game\`, `Server\www\`).
3. Back up any file before editing it, into `Backups\ai-<date>\`.
4. Never print, paste or send passwords, tokens or keys.
5. Addons run on Lua 5.0 (the 1.12 client): `table.getn`, `math.mod`, `string.gfind`, handlers read
   `this` / `event` / `arg1`.

Starter tasks: `Agent\prompts\*.md`.
