# Pending wenilla engine patches — Open Vanilla 1.15 loading

These four patches change the browser client (and one line of the realm's play page). They are
**pending**: CI's `for p in realm/patches/*.patch` does not look in this folder, so nothing here
is built or shipped until the files are moved up into `realm/patches/` (see *Deploy* below).

The page-side half of the same work is **not** pending — it lives in `realm/www/` and ships with
the next push through the hot-patch path (players get it on their next page load). Every page
file degrades to today's behaviour against today's client; the engine patches add the signals
that make the page side complete.

| patch | what it does |
|---|---|
| `0008-openvanilla-loading-screen.patch` | The 1.12-style loading screen, finished |
| `0009-openvanilla-deferred-sound.patch` | No audio while loading; the device opens after the world is up |
| `0010-openvanilla-glue-logo-class-combos.patch` | The Open Vanilla corner logo hook; the class grid driven by the realm's combinations |
| `0011-openvanilla-travel-prefetch-map-warm.patch` | Travel hints for fetch-ahead, the world map warm-up, a time budget for model building |

## Base

The image workflow clones `Arnesen/wenilla` at the commit labelled on
`ghcr.io/arnesen/wenilla-realm:latest` and applies `realm/patches/*.patch`. The image could not be
pulled here, so the base used is **`def2a7b0`** (2026-10-02, "Merge pull request #30", the
newest `main` commit): 0001–0007 apply cleanly on it, in order, and so do 0008–0011 after them
(checked with `git apply --check` on a fresh worktree, every patch, in order). The file groups of
the four patches are disjoint, so they also apply in any order. **On deploy day, check the label**
(`docker inspect -f '{{ index .Config.Labels "org.opencontainers.image.revision" }}'
ghcr.io/arnesen/wenilla-realm:latest`); if it is not `def2a7b0`, re-run the apply check below
against it.

```bash
git clone https://github.com/Arnesen/wenilla /tmp/w && git -C /tmp/w checkout <rev>
for p in realm/patches/*.patch realm/patches/pending/*.patch; do git -C /tmp/w apply --whitespace=nowarn --check "$PWD/$p" && git -C /tmp/w apply --whitespace=nowarn "$PWD/$p" || echo "FAIL $p"; done
```

## 0008 — the loading screen

wenilla already had a faithful 1.12 loading screen (`benilla-app/src/loading_screen.rs`): the
`Map.dbc → LoadingScreens.dbc → BLP` art, `Loading-BarBorder` + `Loading-BarFill`, raised at the
character pick's `Connected` edge and at `SMSG_TRANSFER_PENDING` (instances, portals,
battlegrounds), with a backstop raise for a far same-map snap (a hearthstone, a mage teleport)
that lands on ground that is not resident yet. The asset-counting bar players saw was the
*page's* pre-login boot overlay (`web/boot.js`: "Downloading client — 45% (12 MB)",
"game data — 123/404", and the corner line "preparing world data — N/M"); that is replaced in
`realm/www/openvanilla.js` (below). This patch finishes the engine screen:

- **Art fallback.** A map with no `LoadingScreens.dbc` row, or whose BLP fails, shows its
  continent's screen (the last continent the player stood on for an instance) instead of black.
- **The bar fills on real progress, smoothly, and never sits full.** Shares: world residency
  (terrain tiles + the placed models in the view range, the streamer's own `WorldLoadProgress`)
  70 %, the sliced in-game UI load 20 % (first world entry only; other loads give that share to
  the world), the renderer's pipeline warm-up 10 % (the settled share of the pipelines in flight,
  counted only once the world is in). The shown value eases toward the target (exponential,
  5/s — a warm cache is a quick glide, never a jump), is monotonic, and is capped at 98.5 % while
  the screen is up. Sound is deliberately not a stage: it is deferred (0009), so a loading screen
  never waits for it. *Deviation from 1.12, which showed residency alone.*
- **The spark.** `Loading-BarGlow` (a blue comet on black, meant to be added) is converted to
  alpha at load (alpha = brightest channel) and rides the fill's leading edge, clipped to the
  filled part, with a slow shimmer.
- **Tips under the bar, every 8 s, on every load.** `GameTips.dbc` rows with Open Vanilla's own tips
  mixed in (one after every two), centred under the bar, changing every 8 s for as long as the
  screen is up — on world entry, instances, portals and hearthstones alike (1.12 showed one tip,
  above the bar, on the first entry only). The `gameTip` CVar cursor still advances.
- **No names, counts or bytes on screen.** The engine screen never had any; the residency
  numbers stay in the log line it already writes while waiting.
- **Signals for the page.** `window.__wenilla_progress('world-loading')` at every raise and
  `('world-ready')` at the clear, for `ow/stages.js` (stage timings) and the deferred sound.

Tests added: `ow_the_bar_eases_toward_real_progress_and_never_reads_full_while_up`,
`ow_a_world_entry_shares_the_bar_with_the_ui_load`, `ow_every_raise_carries_a_tip`,
`ow_additive_art_becomes_alpha`, `ow_our_tips_are_mixed_in_after_every_two_of_the_games`.
The existing loading-screen tests are unchanged and their asserted behaviour still holds.

## 0009 — deferred sound

- The browser build opens **no audio device at app start** (`sound/ow_deferred.rs`). With no
  mixer, every sound system already treats the output as absent, so the queued plays of the
  loading frames are dropped and nothing is fetched or decoded for them.
- The world's sound stays held (the same `world_hold` the loading cover uses) until the device
  opens, so the zone soundscape starts as a fresh zone entry — music, then the ambience bed —
  rather than half-started.
- The device opens once the world is revealed **and** the player has moved (0.5 yd) or 3 s have
  passed, whichever is first, and only after the page has seen a user gesture
  (`navigator.userActivation.hasBeenActive`; the Enter World click counts). A playing cinematic
  (the new-character intro) opens it at once, and the narration of the shot under way starts
  when it opens (`sound/cinematic.rs` no longer marks a shot narrated while there is no device).
- Music and ambience fade in over 2 s (`SoundConfig::bed_fade`, applied in `category_amp`);
  effects are not faded.
- `window.__wenilla_progress('audio-ready')` when it opens.
- On by default in the browser; `?sound_defer=0` (or `sound_defer: "0"` in the page env) turns
  it off. Natively it is off unless `WOW_SOUND_DEFER=1`.
- Consequence: no glue music on the login and character screens in the browser (there was none
  audible before the first click anyway: the browser suspends a context made before a gesture).

Sound files load in the background, in priority order, through the service worker:
`realm/www/prefetch.js` fetches the current zone's sounds (from its captured zone manifest) after
`audio-ready` — music, ambience, interface, spells, the rest — at low priority, and `sw.js` now
keeps `/data/Sound%5C…` in its cache (the browser build loads every sound with `fetch()`, never a
synchronous read, so the worker sees them).

**Not done: streaming music and ambience.** On wasm, kira has no streaming decoder (no
threads); wenilla already moved the fetch to `fetch()` and the decode to the browser's
`decodeAudioData` (off the main thread, `sound/web_load.rs`), so a whole track no longer costs the
frame, but it is still downloaded whole before it plays. True streaming needs a
`MediaElementAudioSourceNode` path for the two beds; that touches the mixer's track graph and was
left for a later change.

Tests added: `the_device_waits_for_a_revealed_world_then_movement_or_three_seconds`,
`the_beds_ride_the_fade_and_everything_else_does_not`.

## 0010 — corner logo and the class grid

**Corner logo.** The top-left icon on the login, character select and character create screens
was the WoW logo (`Interface\Glues\Common\Glues-WoW-Logo`, drawn by the engine in
`login/screen.rs`, `char_select/screen.rs`, `char_create/screen.rs` from `glue/art.rs`). With
`glue_logo: "page"` in the page env (`WOW_GLUE_LOGO=page` natively) the engine no longer loads it,
and `realm/www/openvanilla.js` draws the main site's hero logo there instead
(`realm/www/ow-corner-logo.webp` 280×158 and `ow-corner-logo@2x.webp` 560×317, from
`www/assets/openvanilla_logo_hero.png`), at the 4:3 glue area's top-left, 14 % of the height, only on
those three screens. This patch also adds `glue_logo: 'page'` to `play.html`'s env.

**Class grid from `combos.json`.** Patch 0005 made the grid nine slots, filled with the race's
valid classes (so a slot's class changed per race). Now:

- One fixed slot per class (Warrior, Paladin, Hunter, Rogue, Priest, Shaman, Mage, Warlock,
  Druid). A class the selected race cannot be is greyed, and its hover line says why
  ("Night Elves can't be Paladins").
- Picking a greyed class picks it anyway and moves to the first race (same side first) that can
  be it; the races that cannot be the chosen class are then greyed, with the same hover line
  ("Undead can't be Druids"). Switching race keeps a class picked first when the new race can be
  it.
- Which combinations exist is the realm's: `realm/classicplus/combos.json` (56: Warrior, Hunter,
  Rogue, Priest, Mage, Warlock for all eight races; Paladin Human/Dwarf; Shaman
  Orc/Tauren/Troll; Druid Night Elf/Tauren/Troll). `play.html` fetches `ow/combos.json` alongside
  the credentials (2.5 s cap) and passes it as `class_combos: "race:class,…;…"`; without it the
  client's `CharBaseInfo.dbc` decides, as before. A copy is in `realm/www/combos.json` (served at
  `/ow/combos.json`); `devkit/loadlab/test_loadlab.mjs` fails if the two differ. The server side
  (the same 56 in the world DB) is another worker's SQL in `realm/classicplus/pending/`.

Tests added: `ow_the_realm_combos_parse_and_decide`, `ow_without_combos_the_dbc_decides`; the
existing lock-highlight test still holds (Mage is slot 6 of the fixed grid too).

## 0011 — travel hints, the world map warm-up, the model-building budget

**World map: how it is drawn.** The world map is the stock FrameXML `WorldMapFrame` running in
wenilla's Lua VM, not native code. Its 12 detail tiles per map (`Interface\WorldMap\<file>\
<file>1..12`) and the explored overlays are UI sprites; `WorldAssets::sprite_texture` decodes each
the first time the frame asks — synchronously, each behind a synchronous read — and keeps the
handle for the session. So a re-open is already a cache hit (well under 100 ms); the first open of
a map is 12+ blocking reads and decodes in one frame, and over a cold network each read is a
round trip on the main thread. That first open is what was slow, and what popped in.

The fix is to make the first open a re-open, without baking anything:

- **Engine (`ow_travel.rs`):** 4 s after each reveal, it plans the current zone's tiles and its
  overlays, then the continent's tiles, then the world sheet's (36 files plus overlays), asks the
  page to fetch them into memory (`window.__ow_warm(urls)`), and decodes each into the sprite
  cache once the page holds it (`window.__ow_has(url)`), inside a 4 ms per-frame budget. Its own
  synchronous read is then answered from memory, so it never waits on the network. A page without
  the hooks gets no warm-up (today's behaviour). Re-planned on every zone change.
- **Page (`realm/www/ahead.js`):** 20 s after the world is up, every zone of the current continent
  (from `WorldMapArea.dbc`) into the HTTP cache, low priority, so clicking to any other zone is a
  disk read, not a network wait.
- Targets: re-open < 100 ms (already true: cached handles); first open < 400 ms and no pop-in
  for the zone you are in, its continent and the world (warmed before the player can reasonably
  open it); other zones of the continent are disk reads plus decodes. **Not measured** — there is
  no wasm build or game data here; measure with `owdiag` on the realm.
- **Baked per-zone atlases: not built, on purpose.** An atlas would turn 12 requests into one, but
  the cost that matters is the synchronous read on the main thread and the decode, and the warm-up
  removes both from the open; an atlas would also need a second copy of Blizzard art served from
  the realm and a client path to slice it. `tools/make_map_atlases.py` was therefore not written.

**Travel hints for fetch-ahead.** The bridge snapshot's `self` gains:

- `bind: {map, pos:[x,y,z]}` — the hearthstone's destination, from `SMSG_BINDPOINTUPDATE` (the
  protocol event now carries the map and position the packet always had; the stock store kept only
  the area id),
- `flight: {nodes:[…]}` — the TaxiNodes ids of the flight under way, only while on a taxi (the
  route `TakeTaxiNode` sent).

`realm/www/ahead.js` uses them (see *Page layer*). Movement direction and mage
teleports/portals need no engine help.

**Per-frame budget.** The tile and placement spawner already stops at 4 ms a frame
(`terrain_stream::SPAWN_BUDGET`) and colliders at 2 ms; the model render-form builder only had a
count budget (96 submeshes / 16k vertices), which a slow device can blow far past. It now also
stops at 4 ms while the world is paced (never under the loading cover, where speed wins), after
at least one build.

**Not done: low-mip-first texture streaming with a blend.** That needs the engine to load a
texture twice (a small mip first, then the full one) and swap the image under a live material with
a crossfade; wenilla's texture path is one `AssetServer` load per handle. The nearest thing that
exists is patch 0006's lite textures (top mip dropped, opt-in). Left for later.

Tests added: `the_detail_tiles_are_named_as_world_map_frame_names_them`,
`an_overlay_is_cut_into_256_pieces`, `the_plan_puts_the_zone_first_then_its_continent_then_the_world`.

## Page layer (ships with the next push, not pending)

| file | what |
|---|---|
| `realm/www/openvanilla.js` | Hides the boot overlay's counts and bytes ("Preparing your adventure…" over the real progress bar; the corner line is hidden); draws the corner logo on the glue screens; installs the modules below. |
| `realm/www/stages.js` | Stage marks (`engine`, `login`, `charlist`, `world-enter`, `world-ready`, `first-frame`, `sound-ready`, `first-move`) and every frame over 100 ms in the first 30 s in the world. `owStages.summary()`. |
| `realm/www/syncread.js` | The memory store for the client's **synchronous** reads (%5C). A service worker never sees a synchronous XHR, so these could only ever hit the HTTP cache (or the network, on the main thread). A small `XMLHttpRequest` subclass answers a synchronous GET/HEAD of a stored `/data/` URL from memory, byte for byte, and lets the file go; everything else passes through untouched. 96 MB budget; unchanging files are also kept in Cache Storage (`owsync-v1`) for the next visit; `?nosyncmem=1` turns it off. Also the engine's `__ow_warm`/`__ow_has` hooks. |
| `realm/www/prefetch.js` | At the login/character screens: the zone manifest's synchronous-read files and the world-entry UI set (`/world-manifest.json`) now go into the memory store (the asynchronous ones still to the caches); after `audio-ready`, the zone's sounds in priority order. |
| `realm/www/ahead.js` | Fetch-ahead in the world: tiles along the heading out to ~25 s at the current speed (300–2000 yd) with the models and textures they place (ADT `MTEX`/`MMDX`/`MWMO`, WMO groups/`MOTX`, M2 textures), every tile of a flight path in flight order (TaxiPath/TaxiPathNode), the 3×3 tiles around a hearthstone / Astral Recall / mage teleport or portal destination from the moment the cast starts, and the continent's world-map tiles. Low priority, 3 at a time, 400 MB a session, off on Save-Data/2g/3g and with `?noahead=1`. |
| `realm/www/sw.js` | Keeps `/data/Sound%5C…` too (see 0009). |
| `realm/www/owdiag-load.js` | The `load` routine adds `stages`, `syncRead` and `ahead`. |
| `realm/www/combos.json`, `ow-corner-logo*.webp` | See 0010. |
| `devkit/loadlab/measure.mjs` | `--repeat N` (median and p90 per stage), `--shot`/`--baseline`/`--max-diff` (the quality guard: the settled picture against a baseline), `--max-hitches N`. |

## How it was verified — and what was not

Verified here:

- **Apply:** 0001–0007 then 0008–0011 apply in order on `def2a7b0` (fresh worktree, `git apply`).
- **Build (native):** `cargo check -p benilla-app -p benilla-protocol -p benilla-world` (and with
  `--tests`) on the patched tree with Rust 1.97 stable, x86_64 Linux: clean, no warnings.
  The repo pins Rust 1.98.1, which could not be downloaded here (`static.rust-lang.org` is
  blocked from this machine); nothing used here is newer than 1.97.
- **Logic:** the new pure functions (bar target and ease, additive→alpha, tip mixing, the sound
  gate, combos parsing and the "can't be" lines, world-map tile naming) were extracted verbatim
  from the patched sources into a scratch crate and their tests run: 6/6 pass (a simulated entry
  at 60 fps: the bar reads 0.28 / 0.71 / 0.88 / 0.98 at 1 / 2 / 3 / 4 s, no frame-to-frame step
  over 5 %).
- **Page layer:** `node devkit/loadlab/test_loadlab.mjs` in real headless Chromium against the
  stub realm: 40/40 (the 28 existing checks plus: fetch-ahead parsing of ADT/WMO references and
  world-map tile URLs, the sound order, the combos files, median/p90, every stage marked in order,
  a warmed file answering a synchronous XHR from memory with no request and identical bytes,
  `owdiag` carrying the new blocks, `measure.mjs --repeat 2`, and `--baseline` screenshot
  comparison).
- The spark's alpha conversion and placement were checked on a mock-up rendered from the real
  `Loading-BarBorder/-BarFill/-BarGlow` art in `Data/Interface/glues/loadingbar/`.

**Not verified here:**

- **The wasm build.** The `wasm32-unknown-unknown` target could not be installed, so the
  `#[cfg(target_arch = "wasm32")]` code — the user-gesture check in `ow_deferred.rs` and the page
  hooks in `ow_travel.rs` — was reviewed by eye against the identical patterns already in
  `webprogress.rs`/`webenv.rs`, but not compiled. The first CI image build is the compile check.
- **The full `benilla-app` test suite** was not run (a test build of the 400k-line crate did not
  fit the time here); the new tests were compiled (`--tests`) and their logic run as above.
- **Nothing ran against the real client or the realm**: no screenshots of the loading screen, the
  logo or the class grid in the game, no audio check, no world-map timing. Do these on a staging
  realm (`devkit/staging`) before launch: enter the world, port into an instance, hearth, take a
  flight; open the world map right after login; check the character-create grid for every race;
  run `measure.mjs --repeat 10` before and after.

## Deploy (when the realm restart is scheduled)

1. Check the upstream label (see *Base*); re-run the apply loop if it moved.
2. `git mv realm/patches/pending/00{08,09,10,11}-*.patch realm/patches/` and push. The
   realm-image workflow rebuilds `ghcr.io/orionopenwow/openvanilla-realm` (~40 min). Note: its `paths`
   filter is `realm/patches/**`, so pushing files into *this* folder already triggers a rebuild —
   a harmless one (pending patches are not applied), but 40 minutes of CI.
3. Make sure the page layer is live first (it is harmless without the engine patches):
   `realm/www/{stages,syncread,ahead}.js`, `combos.json`, `ow-corner-logo.webp`,
   `ow-corner-logo@2x.webp`. The hot-patch script copies every changed `realm/www/*` file; for a
   fresh `hetzner/openvanilla_realm_up.sh` install, add those six names to its page-layer download
   list (`for f in openvanilla.js owdiag.js …`).
4. Make sure the world DB allows the same 56 combinations (the pending SQL in
   `realm/classicplus/pending/`) **before** the client offers them, or a new combination will be
   refused by the server at Create.
5. Restart the realm on the new image (the usual `openvanilla_realm_up.sh` / hot-patch tier 1).
6. Afterwards: `await owdiag.snapshot(['load'])` in a player's console shows the stages, and
   `node devkit/loadlab/measure.mjs --repeat 10 --max-hitches 0` from a desktop gives the medians
   and p90 to compare with the numbers taken before the restart.

## 0015 — creator links (streams & creators)

`0015-openvanilla-creators.patch` (applies after `realm/patches/0001–0011` and pending `0012`; checked
with `git apply` on a fresh `def2a7b0` worktree; `cargo check`/`clippy -p wenilla-realm --tests`
clean; `cargo test -p wenilla-realm --test creators` and `--lib creators` pass). It touches only
`src/lib.rs` (two `merge` lines and `pub mod creators;`) and adds `src/creators.rs`,
`migrations/0015_creator_links.sql` (numbered after the patch so it cannot collide with another
pending patch's migration) and `tests/creators.rs`.

| route | who | what |
|---|---|---|
| `GET /api/creator/link` | signed in | this account's links, its code `OW-XXXXXX`, the CSRF token |
| `POST /api/creator/link` | signed in + `X-CSRF-Token` | `{platform, handle, character?, show_live?}`; one channel per platform per account, one account per channel (409), the character must be one of the account's own (checked in `classiccharacters`) |
| `DELETE /api/creator/link?platform=` | signed in + `X-CSRF-Token` | unlink |
| `GET /api/creator/links` | `Authorization: Bearer $CREATOR_EXPORT_TOKEN` | every link for `tools/streams_fetch.py`; 404 while the variable is unset or shorter than 16 characters |

The page is `realm/www/creator-link.html` (page layer, served at `/ow/creator-link.html` behind the
sign-in). Proof of ownership is done by the fetcher, not the service: see `docs/STREAMS.md`.
Deploy: set `CREATOR_EXPORT_TOKEN` (e.g. `openssl rand -hex 24`) in the realm's environment and the
same value in `/etc/openvanilla-streams.env` with `REALM_URL=https://play.openvanilla.app`.

## 0014 — community armory uploads

`0014-openvanilla-armory-upload.patch` (applies after `realm/patches/0001–0011` and pending `0012`, before
or after `0015`; checked with `git apply` on a fresh `def2a7b0` worktree in both orders; `cargo test
-p wenilla-realm` passes with 0012+0014+0015, no warnings). It touches only `src/lib.rs` (`pub mod
armory;` and one `merge` line after `web::setup::router()`) and adds `src/armory.rs` and
`tests/armory.rs`. No migration, no new crates (ed25519-dalek, sha2, hex, base64 come with 0012).

| route | who | what |
|---|---|---|
| `POST /api/armory/upload` | a directory-claimed host: `Authorization: Bearer <claim token>`, `X-OpenVanilla-Host-Id`, `X-OpenVanilla-Host-Key` (hex Ed25519), `X-OpenVanilla-Signature` (over the body) | a stored zip ≤ 20 MB of `*.json` only (≤ 1 MB each, `[a-z0-9~._-]`, top level or `guilds/`, `index.json` required, each parsed); replaces `ARMORY_UPLOAD_DIR/<host_id>/` as a whole; the key is pinned per host id in `<state>/armory-hosts.json`; one upload per host per 10 min. 403 bad claim/signature/other key, 400 bad zip, 413 too big, 429 rate, 503 directory off |

Off unless `ARMORY_UPLOAD_ENABLED=1` (the route is not mounted). `ARMORY_UPLOAD_DIR` defaults to
`<state>/armory-uploads`; the realm's `tools/armory_export.py --community-dir` copies it into the
armory (docs/ARMORY.md). The host side is `launcher/p2p/armory.py` (`HostConfig.armory`, off by
default). A Python-made zip and a `launcher/ed25519.py` signature are checked in the unit tests.

## 0013 — the Workshop (ratings, reviews, installs, collections, uploads)

`0013-openvanilla-workshop.patch` (applies after `realm/patches/0001–0011` and pending `0012`, and the
whole series `0012 → 0013 → 0014 → 0015` applies in order with `git apply` on a fresh `def2a7b0`
worktree; `cargo check -p wenilla-realm --tests` clean on the full stack; `cargo test -p
wenilla-realm` passes on 0012+0013, including `--test workshop` and `--lib workshop`). It touches
only `src/lib.rs` (`pub mod workshop;` after `pub mod web;`, and one `.merge(workshop::router(…))`
after `.merge(game)` — away from the lines 0014 and 0015 change) and adds `src/workshop.rs`,
`migrations/0013_workshop.sql` and `tests/workshop.rs`. No new crates.

| route | who | what |
|---|---|---|
| `GET /api/workshop/stats` | anyone | `{addons: {id: {rating, votes, installs}}}` (the listing's sort; `tools/workshop_build.py --stats` snapshot) |
| `GET /api/workshop/reviews/{id}?page=` | anyone | average, votes, 1–5 histogram, 20 written reviews a page (hidden ones without their text) |
| `GET`/`POST /api/workshop/installs/{id}` | anyone (the launcher posts after a verified install) | count; one per address hash per addon per day; 60/h per address |
| `GET /api/workshop/collections`, `/collections/u{n}` | anyone | players' collections |
| `GET /api/workshop/me` | signed in | name, CSRF token, moderator flag, this account's ratings |
| `POST`/`DELETE /api/workshop/rate` | signed in + `X-CSRF-Token` | `{addon, stars 1–5, review ≤ 2000}`: one rating per account per addon (rating again edits it); 30/h |
| `POST`/`DELETE /api/workshop/my/collections` | signed in + `X-CSRF-Token` | `{id?, name, summary?, addons}`; 20 per account, 60 addons each |
| `POST /api/workshop/upload?name=&summary=&license=&source=` | signed in + `X-CSRF-Token` | body = a zip ≤ 10 MB (413 over) → `<state>/workshop/queue/<n>.zip` + a `pending` row; 5 a day, 5 pending at most |
| `GET /api/workshop/queue`, `POST /api/workshop/queue/{n}` `{action: approve\|reject}`, `POST /api/workshop/review/hide` | moderators (admins, or `WORKSHOP_MODERATORS=user,user`) | the queue with each upload's scan; approving needs `<n>.scan.json` first (409) |

Addon ids follow the catalogue (`^[a-z0-9][a-z0-9-]{1,47}$`). CORS answers only the Open Vanilla origins
(openvanilla.app, www., play., openvanilla.app, localhost) with credentials; the site is same-site with
the realm, so `credentials: "include"` carries the session cookie and `csrf::reject_cross_site` lets it
through. Uploads are never served: a moderator's approval only means a person adds a catalogue
entry (`workshop/catalog/<id>.yml`) and rebuilds. Deploy: run the scanner on the host against the
host path of the realm's `/state` volume (`<state>` = `REALM_STATE_DIR`), e.g. every 10 minutes:
`python3 tools/workshop_scan.py --queue <state on the host>/workshop/queue` (needs `lua5.1`; set
`WORKSHOP_QUEUE_DIR` in the realm if the queue should live elsewhere). No cron unit is shipped yet.
