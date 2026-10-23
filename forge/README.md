# Vanilla Forge

The creator app for Open Vanilla: make addons, art and content packs, check them, and build them
into a patch a realm can load.

> **Run it:** double-click **`Vanilla Forge.bat`** in the Open Vanilla folder (it fetches the portable
> Forge the first time), or download the portable zip (`VanillaForge-<version>-Windows.zip`: unzip, run
> `Vanilla Forge.exe`) or the installer from <https://openvanilla.app/forge.html>. From source:
> `cargo run --release -p openvanilla-forge` in this folder. Windows 10/11 and your own Vanilla game client. **Early access, 0.9.0.** Its page is <https://openvanilla.app/forge.html>
(`www/forge.html`); changes are in `CHANGELOG.md`. The plan and design are in the project doc
"Vanilla Forge: creator app plan" (`claude/forge-creator-app-plan.md`).

Built so far: **Phase 0, Foundations** and **Phase 1, the Creator Kit**.

### Phase 0: foundations

| Piece | Where | What it does |
|---|---|---|
| Project format | `crates/forge-core/src/project.rs` | `forge.toml`, `credits.toml`, `addons/`, `art/`, `files/`; templates: addon, content pack, empty |
| IDs | `ids.rs` | Per-pack ID ranges in `.forge/ids.lock`; Open Vanilla's own blocks (Classic+, Warfront, Model Porter) are reserved |
| Checks | `check.rs` | Manifest, credits, `.toc` (Interface 11200), Lua 5.0 pitfalls, allowed game folders, no whole DBCs, texture sizes, and never a file byte-identical to the game's |
| Game data | `vfs.rs` | The creator's own Vanilla MPQs as one patch chain (client load order), searchable, with BLP/TGA/PNG and text previews |
| Build | `build.rs`, `mpqw.rs` | `build/patch-<pack>.MPQ` (MPQ v1, zlib sectors, listfile), loose files, `manifest.json` (BLAKE3), `report.json`; PNG art becomes BLP2 (DXT1, or DXT5 with alpha) |
| App API | `api.rs` | The one command surface the UI calls, from the desktop shell or `forge serve` |
| CLI | `crates/forge-cli` | `forge new / check / build / ids / game / assets / serve` |
| Desktop app | `app/src-tauri` + `app/ui` | Tauri 2 window: Home (new project, recent, setup), Project (pack form, checks, files with previews, build, IDs), Assets (browse and preview the game) |

### Phase 1: the Creator Kit

| Piece | Where | What it does |
|---|---|---|
| Data Editor | `data.rs`, `schemas/` | Rows for the realm's world tables (creature_template, items, quests, loot, gossip, vendors, trainers ...) and the client DBCs (CreatureDisplayInfo, CreatureModelData, ItemDisplayInfo, Spell, SpellIcon) in `data/world/*.toml` and `data/dbc/*.toml`. New rows, `clone` of a stock row, `override` of a stock row. Checked against the CMaNGOS and Vanilla layouts. Builds `server/sql/install.sql` + `rollback.sql` and DBC deltas; dev builds merge the deltas into your own DBCs |
| Addon Studio | `sim.rs` | The repo's Lua sim (`devkit/sim`) bundled in: Lua parse + 5.0 guard lint, and a fake Vanilla client that runs the project's addons (slash commands, clicks, events, time, a Lua console; chat, windows and errors back). Code screen with editor, and `forge sim` |
| Model Importer | `model.rs` | The Model Porter (`tools/modelport`) bundled in and run with your Python: `.glb`/`.gltf` (or a modern `.m2` set, flagged) becomes M2 + BLP in the pack plus the display, model and creature rows |
| Test & Play | `play.rs`, `testbed.rs` | A dev build into Forge's own test copies, never your real folders: a copy of your game beside it (`<game> (Forge test)`: archives hard-linked, settings and addons copied; the pack as `Data\patch-~.MPQ`) and a copy of Play Solo (`<Forge config>\test-solo`: database copied once; SQL run on its next start; server DBCs and map tiles merged in the copy), and back out again |
| Publish | `publish.rs` | A stricter gate, the release build, and `build/publish/<pack>-<ver>.ovpack`: a deterministic zip signed with your Ed25519 creator key. `forge verify` and `tools/forge_verify.py` (standard-library Python, what the Workshop runs) check the signature, the SQL allow-list and the file roots |

### Since Phase 1

| Piece | Where | What it does |
|---|---|---|
| Realm build | `realm.rs`, `forge realm build realm.toml` | A realm's approved `.ovpack`s verified, ordered by `depends`, conflict-checked (files, ID ranges, DBC records) and merged: one realm patch with every pack's DBC rows, a content-addressed `cas/` copy of every client file, merged server DBCs, install/rollback SQL |
| Server spells | `data.rs`, `schemas/spell_template_map.py` | Spell rows also go to CMaNGOS `spell_template` (the server reads spells from the database), through a field map checked against all 22,357 Vanilla spells |
| Mounts | `model.rs` | A mount model also gets its summon spell (copy of 458 / 23229) and reins (copy of 5656 / 18777) |
| 3D view | `app/ui/viewer.js` | The ported model as the game reads it back, skinned and animated (three.js, MIT) |
| Content wizards | `wizards.rs`, Content screen | Quests (story, kills, items to bring, rewards, money; giver and ender relations; quest giver flag on the pack's own NPCs), items (kind, quality, look from the game's ItemDisplayInfo, stats, damage, armour, prices), vendor lists. Ordinary rows, replaced on re-save; SQL checked against MariaDB |
| World: doodads on maps | `adt.rs`, `world.rs`, World screen | ADT v18 tiles read and edited in place (unedited tiles write back byte for byte; MHDR/MCIN/MCNK offsets fixed up). Placements live in `maps/<Map>/placements.toml` (world coordinates, uids from the pack's range); the World screen shows a tile as shaded relief with the game's doodads and yours, and places the chosen model on the ground where you click. Dev builds put the edited tiles in the test patch; releases ship placements as data; the realm build adds every pack's doodads to the realm's tiles. Doodad models: Model Importer kind `doodad` (`World\Forge\<Pack>\`) |
| Terrain sculpting | `world.rs`, World screen tools | Raise, lower, smooth and flatten brushes (hold to keep shaping), across chunk and tile edges without cracks. Edits are height deltas per tile (`maps/<Map>/terrain/<A>_<B>.hd`); builds apply them and recompute the normals (their byte layout read from the tile itself). The server's ground for reshaped tiles needs its maps rebuilt (noted by the checks) |
| Texture paint, holes, areas | `adt.rs`, `world.rs`, World screen tools | Paint any of the game's ground textures (`Tileset\…`, searchable) with a soft brush: up to four layers a chunk, 64×64 alpha maps (MCLY/MCAL rebuilt, the weakest layer gives way when a fifth texture arrives). Cut or fill 8-yard holes (cave mouths, cellars), and paint a zone's area ID (AreaTable: name, music, PvP rules) chunk by chunk. Edits live in `maps/<Map>/terrain/<A>_<B>.chunks.json` and ship with the pack like the height deltas |
| Water | `adt.rs` (MCLQ), `world.rs`, World screen | Paint water, ocean, magma or slime with its surface at a chosen height (a chunk's water is level, like the game's lakes); shift-click drains. MCLQ written the Vanilla way (sizeLiquid in the chunk header, the MCNK liquid flag, depth bytes from the ground, tiles deep enough to swim marked). Stored with the chunk edits |
| Server ground | `gridmap.rs` | Edited tiles converted to the server's own `maps/MMMYYXX.map` (a port of CMaNGOS's extractor: heights packed to 8/16 bits, area flags from AreaTable, MCLQ water, holes), so the server walks, swims and names zones the way players see them. Test & Play swaps them into the solo server (originals kept, put back on Remove); the realm build writes `server/maps/` plus the `MoveMapGen <map> --tile A,B` runs for their movement maps. Placed doodads and buildings reach the server's collision too (next row) |
| Own server only | `testbed.rs` (`pin_local`), `play.rs` (`play_solo`) | Testing never reaches Open Vanilla's (or anyone's) servers: the test copy's realmlist.wtf files are set to 127.0.0.1 and Config.wtf's realmList dropped on every sync and start; the test realm starts only with the test copy and not while the creator's own Play Solo runs; Live Link talks to 127.0.0.1 only. Creators host for friends on their own server (`www/forge-server.html`) |
| Server collision | `vmap.rs` | The server's vmaps (CMaNGOS: `MMM.vmtree`, `MMM_AA_BB.vmtile`, `Name.vmo`) for the tiles where packs place or hide doodads and buildings, from the realm's own: each edited tile's spawns worked out as `vmap_extractor` does (doodads with a collision mesh, buildings, a building's doodad set), new spawns appended to the map's list so untouched tiles stay valid, the tree rebuilt with a port of the server's BIH builder, `.vmo` meshes for models the realm's vmaps lack (M2 bounding triangles, the pack's own models). Checked against CMaNGOS's own extractor, assembler and loader: the tree byte for byte, 7,114 spawns on 31 real tiles, line of sight blocked by a placed inn and unchanged through 338 stock models. Test & Play rewrites the test realm's (originals kept, put back on Remove); the realm build writes `server/vmaps/` when `server_vmaps` is set. A building no spawn on the realm uses yet still needs the extractor |
| Minimap | `minimap.rs`, World screen | Edited tiles get new minimap pictures (256 × 256 DXT1 BLPs baked from the ground textures' colours by their alpha maps, a north-west sun on the slopes, water over it) and their lines in `md5translate.trs`, in dev builds and the realm patch. "As the minimap will look" on the World screen shows the bake |
| 3D view | `app/ui/terrain3d.js` | The World screen's tile in 3D (three.js): the ground mesh with the 2D map draped over it (relief or the minimap bake, overlays, the brush ring), water sheets, doodad pins. Every tool works in it with the left button, picked on the ground; right-drag turns, the wheel zooms |
| New maps | `world.rs` (`new_map`), `adt.rs` (`new_tile`, `new_wdt`), World screen | A whole new map from a name: flat Vanilla tiles (1–4 across) and a WDT in `files/World/Maps/<Dir>/`, its Map row (cloned from Kalimdor, Shadowfang Keep or Molten Core for the fields Forge doesn't set, like the loading screen), an AreaTable zone with its own explore bit, `instance_template` for a dungeon or raid, and a `game_tele` spot (`.tele <Dir>`). IDs from the pack's new Map/AreaTable/AreaBit/game_tele ranges. Every World tool works on it; dev builds, Test & Play and the realm build give it minimap pictures and server map tiles |
| Buildings (WMO) | `adt.rs` (`add_wmos`, `wmos`, `wmo_bounds`), `world.rs`, World screen | Place the game's buildings like doodads: MWMO/MWID/MODF entries with a bounding box from the WMO's MOHD (turned any way, it fits), a reference in every map chunk the box covers, and the same uid on every tile it reaches. Shown as footprints (2D) and boxes (3D). Their walls reach the server's collision (`vmap.rs`) |
| Portals | `world.rs` (`add_portal`), World screen Portal tool | Click an entrance, go to any map or tile, click where players arrive: an AreaTrigger row (client) and an `areatrigger_teleport` row (server), from the pack's AreaTrigger range, with a radius and lowest level. Drawn on both ends; listed with remove |
| Loading screens | `world.rs` (`set_loading_screen`) | A picture for one of the pack's maps: fitted to 1024 × 1024 in `art/Interface/Glues/LoadingScreens/` (built to BLP), a LoadingScreens row, the Map row pointed at it |
| Spawns on the map | `world.rs`, `data.rs` (`add_object_spawn`), World screen Spawn tool | Click to spawn a creature or a game object (the pack's own, or any game entry) on the ground: facing, respawn time, wander radius; `creature` / `gameobject` rows from the pack's guid ranges. Shown on the map and in 3D, listed per tile with remove |
| Undo | `world.rs` (`checkpoint`, `undo`), World screen | Every World edit (a stroke, a hole, a placement, a spawn, a portal, a new map …) saves a step first; Ctrl+Z or ↶ Undo goes back one, up to 30. Steps live in `.forge/undo/` (not shipped, git-ignored) |
| Doodad collision | Model Porter `--collision`, Models screen | A doodad made from your own model collides with its own shape (welded, simplified to 6,000 triangles at most), so an imported house can be walked into and its roof stood on; `box` or `none` instead. Creatures and mounts keep their box |
| Donor search, spawns | `data.rs` | Find a stock record to copy by name or ID; place a creature by pasting what `.gps` prints |
| True View | `trueview.rs`, `app/ui/terrain3d.js` | The ground painted with the game's real tileset textures by their alpha maps (2D "Real ground" and the 3D drape); in 3D the game's own M2 doodads and WMO buildings as meshes (rest pose, their textures), and the pack's own ported doodads. Read from the creator's install, never stored |
| Behaviour Studio | `behaviour.rs`, Behaviour screen | When → If → Do cards compiled to CMaNGOS EventAI (`creature_ai_scripts`, ids `entry × 100 + n`, `AIName = EventAI`), lines in `custom_texts` (negative ids from the pack's range); ready-made plans (caster, two-phase boss, runs at low health) and a plain-words reading; dialogue pages → `npc_text`, `gossip_menu`, `gossip_menu_option` (+ vendor/trainer/innkeeper/banker choices) with a gossip-window preview; patrol paths drawn on the World map → `creature_movement`, the spawn's `MovementType = 2`. Checked against MariaDB with CMaNGOS's schema |
| World kit | `kit.rs`, World tools | Scatter (count, spacing, size range, slope limit; shift-click clears), Road (ground smoothed along a line, painted in one pass), Prefabs (`prefabs/<name>.json`: the pack's doodads and spawns in a box, stamped turned, optional levelling), heightmaps (16-bit PNG out, a picture in over one tile or a block of tiles) |
| Pictures | `thumbs.rs`, `usage.rs`, `app.js` | Small renders made on the creator's PC and cached in the config folder (never the project): models three-quarter from the front with their textures (a character's default geosets), creatures by their look (CreatureDisplayInfo skins, the pack's rows merged in), objects, ground swatches, item icons, a pack's cover (its first tile's ground). They fill visual pickers (World place/paint/spawn, creature and item looks), the World screen's "On this tile" strip (point to find on the map, click to use) and the Project screen's "In your pack" (`usage`) |
| Live Link | `livelink.rs`, `forgelink/`, Test screen | With Forge's test realm running (never your own Play Solo: it refuses while yours is up): Make me a GM (SOAP `account set gmlevel`, until its next start), Apply my changes now (the dev SQL through Play Solo's own MariaDB client, then `reload <table>` for what CMaNGOS can reload), Play here (a `forgelink` game_tele row, `tele name`). The Forge Link addon's `/forge` marks position and target (`.gps`, `.npc info`) into SavedVariables, which Forge shows. Test & Play now also puts the pack's addons in `Interface\AddOns` (the client only loads addons from there) |
| Sample, tour, palette, fixes | `sample.rs`, `fixes.rs`, `app.js` | "Make the sample island" builds Ember Isle with every tool above (≈8 s); a five-step tour on first open; Ctrl+K to go to any screen, tool or creature; "Fix it" for findings with one safe answer, "Go there" for the rest |
| Your own AI (MCP) | `forge-cli/src/mcp.rs` | `forge mcp [--project DIR]`: an MCP server on stdio with `forge_guide`, `forge` (any API command), `forge_check`, `forge_tile`; big arrays are summarised. The installer carries `forge.exe`; Home shows the command to give an AI assistant. Nothing is hosted |

Built archives are read by the browser client's own MPQ and BLP readers (wenilla's
`benilla-mpq`/`benilla-blp`), `wow-mpq`, and `tools/modelport/mpq.py`. Forge writes MPQs itself
(`mpqw.rs`) because `wow-mpq`'s writer stores small files as single units, which wenilla can't read.

## Build and run

Needs Rust (stable). The desktop app on Windows also needs WebView2 (built into Windows 10/11).

```
cd forge
cargo test                                  # core tests
cargo run -p forge-cli -- new MyPack --template pack --name "My Pack"
cargo run -p forge-cli -- game set "C:\Games\Vanilla"
cargo run -p forge-cli -- build MyPack
cargo run -p forge-cli -- publish MyPack     # build/publish/my-pack-0.1.0.ovpack, signed
cargo run -p forge-cli -- sim MyAddonProject # run its addons in the sim, as a console
cargo run -p forge-cli -- serve             # the app in a browser at http://127.0.0.1:8777
cargo run -p openvanilla-forge              # the desktop app
```

**The easy way:** double-click `Vanilla Forge.bat` in the Open Vanilla folder. It opens the portable
Forge in `forge\bin\Vanilla Forge` (git-ignored), else an installed Forge, else fetches the newest
portable zip (`VanillaForge-<version>-Windows.zip`, from `downloads/forge.json`, checked by its SHA-256),
else builds from source with Rust. `Vanilla Forge.bat --update` fetches the newest again.

A Windows installer: the **forge** workflow, run by hand from GitHub Actions, uploads
`VanillaForge-Setup-<version>.exe` as a build artifact (not a release). The installer carries an
embeddable Python 3.12 with numpy and Pillow for the Model Porter (`FORGE_BUNDLED_PYTHON`).

## Releasing

1. Set the version in `forge/Cargo.toml` (`[workspace.package]`) and `app/src-tauri/tauri.conf.json`.
2. Add `## <version>` at the top of `CHANGELOG.md`. Its first bullet is the one line the website
   and Forge's update notice show.
3. Ship as usual, then tag: `git tag forge-v<version>` and push the tag.

The workflow checks the tag matches both versions, builds the installer, and makes the GitHub
Release "Vanilla Forge <version>" with the installer, its SHA-256 and `forge.json`. It is **never
marked latest** (the site's Pages build downloads the latest release's files, which must stay the
game's). It then runs `pages.yml`, which puts the newest `forge-v*` release's `forge.json` in
`www/downloads/`: the download button on `forge.html` and the app's update notice read it. Until
the first release, the page says "Coming soon". The installer isn't code-signed, so SmartScreen
asks once.

## Rules it keeps

- Forge never contains or downloads Blizzard's files. It reads your own install, and a build refuses
  any file byte-identical to one in it.
- Packs ship only into game folders (`Interface`, `Textures`, `Creature`, `Item`, ...). Client DBCs
  are never shipped whole: they ship as row deltas, and the realm merges them.
- Published packs refuse models converted from the game's own files, and need a credit for every model.
- Forge only writes SQL it generates, on the world tables it edits; the review checks that again.
- The same project always builds to the same bytes (the build hash in `report.json`).

## Not yet

- The Workshop side of Publish: uploads from Forge, the ID-range registry, the reviewer's diff view
  (backend work on the pending upload patch). Until then packages go through "Submit your mod".
- Serving the realm build's `cas/` files to browsers (a realm web-service change), and staging + Herald
  smoke tests before a realm deploy.
- Later phases in the plan: dialogue tools, the spell designer, server mods; macOS/Linux installers.
