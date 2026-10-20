slug: editing
title: Edit your own game
kicker: Chapter 12 · Build
summary: Make addons and UI changes for the Vanilla client, test them with the Lua sim, change your realm's rules, port models and mounts, and rebuild the patch, without ever touching Blizzard's files.

> **Never:** Never modify, extract, copy or share Blizzard's files (`WoW.exe`, `Data\*.MPQ`, `Interface\FrameXML`, `Interface\GlueXML`, `Blizzard_*` addons). Everything here works alongside them. Make backups before changing anything.

## What you can change, and where {#map}

| You want to change | Where | Section |
| --- | --- | --- |
| How the interface looks or works | An addon in `AddOns\Enabled` | [Your first addon](#first-addon) |
| A Vanilla Remastered addon's behaviour | A copy under a new name, never the original | [Change a Vanilla Remastered addon](#change-classic-plus) |
| XP, drops, rules on **your** realm | `mangosd.conf`, realm SQL | [Realm rules](#realm-rules) |
| New creatures and mounts | The Model Porter | [Models and mounts](#models) |
| Art, icons, window kit | `tools/gen_*_art.py` | [Art](#art) |

Prefer to describe it and let an AI do the typing? [Connect an AI](ai.html) gives an agent all of this.

## Addon basics for Vanilla {#addon-basics}

An addon is a folder with a `.toc` file (its table of contents) and Lua files. The folder name must match the `.toc` name.

```
MyFirstAddon\
  MyFirstAddon.toc
  MyFirstAddon.lua
```

```
## Interface: 11200
## Title: My First Addon
## Notes: Says hello.
## Author: You
## Version: 1.0.0
MyFirstAddon.lua
```

`## Interface: 11200` marks it as a Vanilla addon. Add `## Dependencies: WenillaCore` if you use the Vanilla Remastered core.

### Lua 5.0: the rules that trip people up {#lua50}

The Vanilla client runs **Lua 5.0** with the Vanilla API. Code from modern addons often breaks on these:

| Don't use | Use instead |
| --- | --- |
| `#t` (length) | `table.getn(t)` or `getn(t)` |
| `a % b` | `math.mod(a, b)` or `mod(a, b)` |
| `string.match`, `string.gmatch`, `s:match()` | `string.find`, `string.gfind` |
| `select()`, `...` outside a parameter list | `arg` (the table of extra arguments) |
| `s:upper()` and other string methods | `string.upper(s)` |
| `hooksecurefunc`, `C_Timer`, `print` | Hook by saving and replacing the function; `DEFAULT_CHAT_FRAME:AddMessage` |
| `frame:SetSize(w, h)` | `frame:SetWidth(w)` and `frame:SetHeight(h)` |

Event handlers read the globals `this`, `event`, `arg1`, `arg2`... rather than parameters. Registering an event that didn't exist in Vanilla is an error.

## Your first addon {#first-addon}

```
-- MyFirstAddon.lua
SLASH_MYFIRSTADDON1 = "/hello"
SlashCmdList["MYFIRSTADDON"] = function(msg)
  DEFAULT_CHAT_FRAME:AddMessage("Hello, " .. UnitName("player") .. "!")
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:SetScript("OnEvent", function()
  DEFAULT_CHAT_FRAME:AddMessage("MyFirstAddon loaded (" .. event .. ")")
end)
```

1. Put the folder in your data folder's `AddOns\Enabled\` (the launcher's **Workshop → Installed → Open folder** gets you there).
2. Press **PLAY**: the launcher copies your enabled addons into the client.
3. In game, type `/hello`. After editing the Lua, `/reload` loads your changes.

Settings that should survive a relog go in a saved variable: add `## SavedVariables: MyFirstAddon_DB` to the `.toc` and read it after `VARIABLES_LOADED`.

## Change a Vanilla Remastered addon {#change-classic-plus}

Don't edit the shipped Vanilla Remastered addons in place: updates replace them. Copy the folder under a new name (and rename the `.toc` and its `## Title`), switch the original off in `/addons`, and change your copy. Settings in the **AddOns** window are usually enough to change behaviour without code; see [In-game features](classic-plus.html).

## Test without starting the game: the Lua sim {#lua-sim}

The repo's **Lua sim** runs addons in a fake Vanilla client in seconds, with the Lua 5.0 rules enforced. It loads addons from `Data/Interface/AddOns/` in a checkout of the repo, so put your addon folder there to test it.

```
lua5.1 devkit/sim/run_tests.lua            # every test
lua5.1 devkit/sim/run_tests.lua persona    # only tests matching "persona"
SIM_VERBOSE=1 lua5.1 devkit/sim/run_tests.lua
```

Results are **PASS**, **FAIL** and **XFAIL** (a known bug that's still there). A test lives in `devkit/sim/tests/<addon>.lua`:

```
T.test("hello prints a greeting", function()
  local env = T.addon("MyFirstAddon")
  env.__slash("/hello")
  T.has(api.chat_text(env), "Hello")
end)
```

On Windows, put `lua5.1.exe` on your PATH (the LuaBinaries 5.1.4 Win64 build).

### Check any addon like the Workshop does {#scan}

```
python3 tools/workshop_scan.py path\to\MyAddon --json
```

The scanner loads the addon in the sim, logs in, runs it for two seconds, and reports **works**, **partly** (uses API the sim doesn't model), **needs-fixes** or **unknown**, plus anything risky (sending chat at login, reading other addons' saved data, `os`/`io`). It's the same check the Workshop's review gate runs: see [Publish to the Workshop](workshop.html#review).

## The devkit {#devkit}

`devkit\Dev.bat` has a menu for everything:

| Option | What it does |
| --- | --- |
| Quick checks | `py -3 devkit\check.py`: repo sanity, including refusing Blizzard files |
| Addon tests | The Lua sim |
| SQL tests | Realm database changes, in Docker or locally |
| Dev proxy | `http://localhost:8080` is the live realm, but the page scripts and Vanilla Remastered addons come from **your** folder. Nothing is pushed. |
| Herald Lite | A headless test bot running scenarios in `devkit/heraldlite/scenarios/` |
| Measure loading | How fast the browser client loads |
| Rebuild patch-Z | The client patch, in Docker |

## Realm rules on your own server {#realm-rules}

On a realm you host (or Play Solo), the rules are yours.

- **Rates** (XP, drops, rested, honor) live in `mangosd.conf`: Solo's is under `Realms\Solo\...\mangosd.conf`, a hosted realm's under `Realms\Hosted\custom\mangosd.conf`. Change a line, save, restart the world server.
- **Vanilla Remastered switches** are lines in the same file, set to 1 (on) or 0 (off):

| Setting | Does |
| --- | --- |
| `OpenVanilla.AutoLearn` | Learn trainer spells on level-up |
| `OpenVanilla.FreeRespec` | Free talent resets |
| `OpenVanilla.DualSpec` | Two specs from level 10 |
| `OpenVanilla.StarterPet` | Hunters start with a pet (official realm: 0) |
| `OpenVanilla.AoeLoot`, `OpenVanilla.AoeLoot.Range` | Loot nearby corpses at once, and how far (30) |
| `OpenVanilla.InstantAccountMail` | Instant mail between your own characters |
| `OpenVanilla.ClosedCombos` | Race and class pairs closed to new characters |

On a Linux realm, `bash realm/classicplus/openvanilla_gameplay_conf.sh` applies the Vanilla Remastered set (and `rollback` undoes it).

- **Content** (NPCs, vendors, items, quests) is SQL in the world database. Write it as a `.sql` file you can re-run and undo, keep custom IDs high (NPC entries above 190000) so they never clash, and export the tables first. The realm's own changes are in `realm/classicplus/*.sql`, each with a rollback file, as examples.

> **Warning:** Server changes apply to your realm only. Never point tools or an AI at a realm you don't run.

## Models and mounts: the Model Porter {#models}

The **Model Porter** turns a modern model into one the Vanilla client can show, and adds it to your realm as a creature or rideable mount.

1. Run `Model_Porter.bat`; it opens `http://127.0.0.1:8765`. (Command line: `python tools/modelport model.glb --name Gryphon --kind mount --add`.)
2. Feed it a **glTF/glb**, or a modern `.m2` with its `.skin`, `.skel`, `.anim` and `.blp` files.
3. For a mount, name the rider's node `Seat` (or `Saddle`); animations are matched by name (Idle, Walk, Run...).
4. Test in game as a GM: `.additem`, `.npc add`, `.modify morph`, `.demorph`.

Limits: up to 254 bones; models over 21,845 triangles are simplified automatically; textures 256–1024 px. Only port models you made or have the rights to.

## Art {#art}

The Vanilla Remastered windows, icons and frames are drawn by scripts in `tools/` (`gen_*_art.py`, sharing `tools/artkit.py`). Each writes a `.tga` for the Vanilla client and a `.blp` for the browser client; sizes must be powers of two. `tools/png_to_blp.py` converts your own PNGs.

## The client patch (patch-Z) {#patch-z}

The Vanilla Remastered addons, art, loading screens, custom models and a few data tables ship to clients in one small archive, `patch-Z.MPQ`, the only archive in the repo. Rebuild it after changing those: `python3 tools/sync_patchz.py` (with StormLib), or **Rebuild patch-Z** in the devkit. `--check` only reports what would change.

## Share what you made {#share}

When it works, share it: [Publish to the Workshop](workshop.html).
