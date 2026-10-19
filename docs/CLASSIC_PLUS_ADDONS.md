# Classic+ native addons — 1.1.0 (2026-10-12)

Eleven addons plus a shared core, in `Data/Interface/AddOns/`, with eight more coming in 1.15. Every addon goes by a plain name, and its folder, window and settings all use it. Saved settings and slash commands from before the rename still work.

| Addon | Works today without server telemetry |
|---|---|
| Meters | Yes. Damage and healing for you, your party/raid and pets, read from the combat log with the client's own GlobalStrings |
| Quests | Ring, compass rose and coordinates. Quest pins need the server (`CP`) |
| Threat | Needs the server (`VG`); vanilla clients have no threat data |
| Casting | Yes in the web client. The engine reports enemy casts and the loader resolves them from Spell.dbc |
| Guilds | Yes. Listings travel over a hidden chat channel (`CPConcord`) |
| Bags | Yes. All bags, search, and a bank remembered at every banker visit. |
| Prices | Yes. Auction pages you browse are remembered for 7 days. Server medians and vendor prices come from `LG` |
| Vendor | Yes. Sells greys and repairs from the merchant window |
| Plates | Yes. Restyled nameplates and target debuffs. Timers need the server (`VS`) |
| Raid | Yes. Markers, ready check and pull timer over the party/raid addon channel |
| Persona | Yes. Roleplay profiles over a hidden chat channel (`OWPersona`); see below |

Also in the folder: **Repack** (the ElvUI-style makeover, off until you add it from the Workshop) and **Themes** (Move Anything, `/move`, and the Workshop, `/workshop`).

### Coming in 1.15

| Addon | What it does |
|---|---|
| Social | Friends, guild, group, /who, ignore and recent people in one window. Opens with O, `/social` |
| Dungeons | A group finder board for every dungeon and raid: list yourself, browse by dungeon, ask to join, invite, endorse. `/lfg` |
| Achievements | Achievements for levelling, quests, exploring, dungeons, professions, reputation and PvP, tracked by the realm (`AC`). Points only, never power |
| Chat | A readable chat window: five themes, timestamps, class colours, clickable links, copy and spam control |
| Mail | Open All and Return All, tick several letters at once, Alt-click bag items to mail them, attachment search, name suggestions |
| Loot | Every item on one list, money from every corpse added up, Take All, one chat line for auto loot; shows merged area loot (`AL`) |
| Talents | Free talent resets (`RS`), two talent specs you can name and switch between (`SP`), a planner with saved builds and share codes, and a note when you learn new spell ranks (`LL`) |
| Essentials | Everyday helpers, starting with each zone's repairers, vendors, flight masters, innkeepers, trainers and bankers on your map (`NP`) |

`/addons` opens the settings. `/vanilla` switches to pure 1.12. `/wnl demo` plays imitation data through every window. `/wnl reset` restores window positions. `/wnl status` shows what is connected.

## How it reaches every player

* **Web client**: `www/addons-loader.js` streams the suite into each player's UI VM after world entry. It does the following:
  * reads each `.toc` that has `## X-ClassicPlus`;
  * restores `WenillaCore_Config` from localStorage;
  * replays the login events;
  * reloads after `/reload`.
* **Native 1.12 client**: `launch_native.sync_addons()` copies the folder as before. The `.toc` files now list the renamed `.lua` files, which is why nothing loaded before.

## Things to do on the server machine

1. **Restart the web backend** (`asset_server.py`). It now does three things:
   * adds `Data/Interface/ClassicPlus/*.blp` to the asset index, so the brass compass ring, rose, pins, level medallion, parchment and stone slots draw in the web client. Until the restart, every window uses its stock-texture fallback.
   * revalidates the index (`no-cache` + ETag) instead of caching it for a day.
   * revalidates addon files instead of caching them for a year, so updates reach players on their next load.
2. **Re-run `www/patch_wasm.py`** (it still reads `wenilla_bg.wasm.orig`). The bundled stub rows no longer define slash commands. The old `Raid` stub set `SLASH_RAID2 = '/rally'`, which turned `/rally` into raid chat and broke `/ra`. The Raid addon repairs this at load in the meantime. The script now also rewrites `wenilla_bg.wasm.gz`, and `.br` when the `brotli` module is installed. Without `brotli` it deletes the stale `.br`.

Safe to delete: `Data/Interface/ClassicPlusStaging/` and `www/addons-loader.next.js` (test copies). Originals of every replaced file: `backups/classicplus-before-2026-10-12/`.

## Server packets (for a future vMaNGOS hook)

Nothing goes to the server until it greets the client with `HI <version>`. That way a realm without the hook never sees `.wnl` lines said out loud. Carrier lines are `CHAT_MSG_SYSTEM` text `WNL\t<TAG> <body>`, which is hidden from chat, or an addon message with prefix `WNL` sent as the player themself.

| Tag | Body |
|---|---|
| `CH` | `name,classId,total,perSec;...` / `inspect,name;ability,amount,pct;...` |
| `CP` | `questId,x,y,OBJ\|GIVER\|TURNIN[,title];...` (x, y in 0..1 zone space) |
| `VG` | `target;name,pct,isTank;...;S,rank,pct,pullAt` or `-` |
| `CL` | `target\|plate,caster,spell,durMs,interruptible[,icon][,channel]` / `stop,role,caster,interrupted` |
| `CO` | `L~guild~focus~minLevel~members~pitch~poster;...` / `announcement,text` |
| `VT` | `itemId,count,quality,icon;...` (bank snapshot) |
| `LG` | `itemId,median,vendor,samples;...` |
| `SC` | `count,copper` |
| `VS` | `unitName;iconName,remainingMs;...` |
| `RL` | `pull,seconds` / `check,id` |

Long bodies can be chunked: `<TAG> <seq> <i>/<n> <part>`.

## Persona (roleplay profiles), 1.1.0

`/rp` (or `/persona`) opens your target's profile, or your own. `/rp <name>`, `/rp edit`, `/rp list`,
`/rp ic | ooc | lfrp | st`, `/rp demo`, `/rp help`.

* **Profile**: roleplay name, title, pronouns, age, height & build, home, motto, crest (18 icons),
  roleplay experience (new / casual / experienced / mentor), currently, appearance, bio (2,400
  characters), five shares, an OOC "currently" line and an account-wide OOC note.
* **Seen by others**: player tooltips (roleplay name, title, status, a glance line, currently),
  a status gem on the target portrait (click to read), "View Persona" on right-click menus, and a
  Directory of every profile you've met (search, "seen today", "looking for roleplay").
* **Status**: in character, out of character, looking for roleplay, storytelling. The minimap
  button cycles it with a right-click.
* **Settings** (`/addons` > Persona): tooltips, roleplay names in tooltips, target badge, minimap button.
* **Safety**: text from other players is shown literally (no colour codes or links), and players on
  your ignore list neither see your profile in your tooltips nor appear in yours.
* **Wire format** (hidden channel `OWPersona`, filtered out of every chat window): `?P <name> <rev>`
  asks, `!P <rev> <i>/<n> <chunk>` answers, `#P <rev> <status> <name>~<title>` announces. Payloads
  carry no spaces, pipes or newlines (`_` for space, `\\`-escapes), because the server trims and
  collapses spaces in chat lines. New fields are only ever appended.
* **Art**: `art/persona/make_persona_art.py` writes `Persona_Icon`, `Persona_Ring`, `Persona_Divider`
  and the four status gems as TGA (WenillaCore/Media) and BLP (Interface/ClassicPlus).
* Profiles are saved per account in `Persona_DB`; on the web client that's the browser, so they
  don't follow a player to another device yet.
