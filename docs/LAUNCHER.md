# The Open Vanilla launcher

`OpenVanilla.exe` is the one program players run. It is `launcher/openvanilla_launcher.py` frozen by
`packaging/build_repack.py`; every feature (Play Solo, Host for friends, the dedicated server, the
Workshop, the updater, live content) is frozen in. It starts the game itself: `Game\Open Vanilla Game.exe`
(the engine) or the player's own `WoW.exe`.

## What players see

- **HOME.** One PLAY button. The switch at the bottom left says how PLAY plays: **ONLINE** (the realm
  picked in the left rail), **SOLO** (SPP Classics on this PC) or **BROWSER** (the realm's web client).
  The bar above PLAY says what's missing, and pressing PLAY fixes it (pick the WoW folder, Solo's next
  setup step…). The left column has the news, the server, the account card and, under it, the client
  button (GET WOW 1.12.1 / CHOOSE WOW 1.12.1 FOLDER / GET CLIENT / SET UP CLIENT / CHANGE WOW FOLDER /
  CLIENT DOWNLOAD for the selected client; CANCEL DOWNLOAD while one runs). In ONLINE mode the client line
  under the switch (`▾`) always opens the client menu; its last row, *More clients in Workshop ›*, opens
  Workshop > CLIENTS. The news and the DISCORD / SUPPORT buttons come from live content; HOME draws no
  banner or featured cards.
- **Workshop > CLIENTS.** Every game client the launcher knows: the built-in ones (Vanilla, always in the
  menu), the parked ones in `defaults.json` (`clients_parked`), the maintainer's live list and the
  player's `clients.txt` (see [Game clients](#game-clients-workshop--clients)). Each row has
  *Add to my clients* / *Remove* (the HOME menu), *Download* / *Get* (picks the client and runs the usual
  client download) and *Page*.
- **Update ready.** Updates download quietly in the background (the text beside the bar shows
  `Downloading update 42%`). Once a signed update is staged, a gold **UPDATE READY · RESTART** button
  appears above PLAY on HOME (elsewhere the text beside the bar says it). Pressing it hands off to the
  silent installer (installer build) or the zip swap step and restarts Open Vanilla.
- **No HOST tab.** Running a realm is the separate Open Vanilla Server download (openvanilla_server.py +
  launcher_gui.py, packed by packaging/build_server.py into OpenVanilla-Server.zip on every release).
  The hosting code (launcher/p2p host, launcher/server_host.py, page_host) is still in the tree but
  unreachable: `show_page("host")` lands on REALMS.
- **Settings.** *Folders* opens AddOns, Screenshots, Logs, Realms, Backups and the install folder.
  *Advanced* (off by default) shows developer controls: client download links, the Workshop's GitHub
  search and HOST > Downloads (torrent seeding).

## Play Solo (SPP Classics)

`launcher/spp.py` moves through `missing -> downloaded -> unpacked -> base -> ready` in `Realms\Solo`:

1. PLAY (Solo) asks first, then downloads `SPP_Classics_V2.zip` (110 MB, SHA-256 pinned, resumable),
   with progress in the bar.
2. It unpacks it and runs SPP's own git clone of the server files (about 700 MB), hidden.
3. It opens SPP's `Launcher.bat` once and says what to type (1, wait, then 0); it watches the folder and
   PLAY turns ready by itself.
4. PLAY starts mysqld/realmd/mangosd hidden, points the game at 127.0.0.1 and logs in as SOLO / SOLO.
   Closing the game saves the world and stops what it started.

A player who already has SPP Classics can point Solo at it (Solo page: *I have SPP Classics…*).
`SPP_URL`, `SPP_SHA256` and `SPP_SIZE` in live content or links.txt re-point the download.

## Folder layout (layout 2, launcher/layout.py)

```
OpenVanilla.exe            the launcher: start here
app\                   its internals; app\data holds defaults.json, version.json, patch_notes.json, links.txt
Game\Open Vanilla Game.exe  the engine (started by OpenVanilla.exe) + Game\benilla-config (its settings)
Server\www\            the realm website the dedicated server serves
links.txt              the player's own overrides (all commented out)

user data (beside OpenVanilla.exe for the zip; %LOCALAPPDATA%\OpenVanilla for the installer, or the data folder an install
from before the rename already has, which is kept;
_local\launcher-data when run from a checkout; OPENVANILLA_DATA_DIR overrides):
AddOns\Enabled|Disabled  addons every client loads (PLAY copies them into the client it starts)
Realms\Solo              Play Solo (SPP Classics)       Realms\SoloPack   the older solo pack
Realms\Hosted            Host for friends               Screenshots  Logs  Backups
Settings\                settings.json, server.json, layout.json, nowplaying.json
Cache\                   live.json, Updates\ (staged releases), torrents\
clients.txt              the player's own game clients (Workshop > CLIENTS; optional)
CLAUDE.md  AGENTS.md  Agent\   only after Settings > AI > Set up AI workspace (the optional AI kit)
```

An older install is moved into this layout at start (nothing is deleted; conflicts go to
`Backups\migration-<date>`). A source checkout's own `solo\` and `host\` folders are never moved.

## Activate your AI (optional)

Settings > AI (launcher/ai_setup.py) helps a player use an AI coding agent they already have, with their
own account, on their own copy: it detects Claude Code (`claude` on PATH or in its installer folders) and
other agents, links to the Claude Code install page, copies the starter kit (`agent/`, shipped as
`app\agent`) into the user-data folder (CLAUDE.md and AGENTS.md at its root, README and prompts in
`Agent\`; files the player edited are kept), opens a terminal there running `claude`, and copies a starter
prompt to the clipboard. A one-time card offers it on the second launch. Open Vanilla stores no AI keys and
makes no network calls for it. The live flag `ai` hides it. In game the Assistant addon (`/assistant`, Esc
menu) shows the same prompts; `python launcher/ai_setup.py --write-lua` regenerates its Prompts.lua from
`agent/prompts/*.md`. The website page is `www/ai.html`.

## Live content (for the maintainer)

News, game clients, feature flags, button labels/links and download links change in every launcher
within minutes, without a new launcher:

1. Edit `www/downloads/live.src.json` (keys starting with `_` are notes). Check it with
   `py -3 packaging\live_content.py --check`.
2. Run `dev\Ship.bat`. `pages.yml` signs it with `OPENVANILLA_MANIFEST_KEY` into `downloads/live.json` +
   `.sig` and publishes it from `stable` (taking `live.src.json` from `main`).

Launchers fetch it at start, ignore anything unsigned, badly signed or older (`serial`), and cache the
last good copy in `Cache\live.json`. Useful keys:

| Key | What it does |
| --- | --- |
| `news` | News on HOME and the NEWS page. `link` may be `https://…` or `openvanilla://page/<solo\|host\|notes\|…>`. |
| `hero`, `featured` | Keep them empty (`{}` / `[]`). Current launchers don't draw them; launchers released as 1.17.0 still draw a banner and cards from them. |
| `clients` | Game clients for Workshop > CLIENTS (up to 12): see [Game clients](#game-clients-workshop--clients). |
| `flags` | `online`, `solo`, `browser_play` hide PLAY modes; `host_friends`, `dedicated_server` hide HOST tabs; `workshop` hides the Workshop tab (tabs change at the next start); `relay` offers *Through Open Vanilla* once the relay runs; `solo_pack` re-enables the older solo pack. |
| `buttons` | Relabel or re-point `discord`, `support`. |
| `links` | `SPP_URL`, `SPP_SHA256`, `SPP_SIZE`, `DISCORD_INVITE`, `PATCH_NOTES_URL`, … (allow-listed in `launcher/live_content.py`). |
| `message` | A one-line notice under the bar: `{"text": "...", "level": "info|warn|good"}`. |

## Game clients (Workshop > CLIENTS)

`launcher/game_clients.py` merges four lists by `id`, later ones updating what an earlier one set (a
shipped client's `type` never changes):

1. `defaults.json` `clients`: built in, always in the HOME menu, can't be removed (Vanilla 1.12.1).
2. `defaults.json` `clients_parked`: known clients that aren't offered by default.
3. Live content `clients`, published by the maintainer.
4. `clients.txt` in the user-data folder, for the maintainer and power users.

A client a player adds is remembered by id (`my_clients` in settings.json), so a client added from live
content keeps following the maintainer's edits (and leaves the menu if the maintainer removes it).

**The maintainer (live, every launcher):** add an entry to `clients` in `www/downloads/live.src.json`
check it with `py -3 packaging\live_content.py --check`
and publish as usual:

```json
"clients": [
  {"id": "classicplus-test", "name": "Open Vanilla Classic+ (test build)", "type": "engine", "version": "1.14.3",
   "url": "https://openvanilla.app/downloads/OpenVanilla_test.zip",
   "page": "https://github.com/orionopenwow/OpenVanilla", "description": "The next engine build, for testers.",
   "status": "available"}
]
```

Fields: `id` (a-z, 0-9, `-`, `_`), `name`, `type` (`exe` = the player's own WoW.exe, `engine` = an
Open Vanilla engine build, `web` = plays in the browser), `version`, `url` (https; a .zip downloads in the
launcher, a page opens in the browser), `page` (https project page or repo), `description`, `image`
(https, optional), `status` (`available` or `coming_soon`). Anything else is dropped.

**clients.txt (one PC):** Workshop > CLIENTS > *OPEN CLIENTS.TXT* creates it (all comments) and opens it
in Notepad. One client per block, a blank line between blocks, `#` for comments; the same fields, same
checks (`id` is made from the name when left out):

```
name = My Classic+ build
type = engine
version = 1.12.1
url = https://example.org/downloads/MyClient.zip
page = https://github.com/example/my-client
description = A test build of the engine.

name = Wrath of the Lich King
type = exe
version = 3.3.5a
page = https://example.org/wotlk
```

The list is read again every time the CLIENTS tab opens.

## Releases ("Update ready")

`dev\Release.bat <version>` tags a release; `release.yml` builds `OpenVanilla.exe` + the installer, runs
`OpenVanilla.exe --self-test`, and publishes a `version.json` signed with the same `OPENVANILLA_MANIFEST_KEY`.
Launchers check it at start, stage the matching asset in `Cache\Updates`, and show UPDATE READY.
