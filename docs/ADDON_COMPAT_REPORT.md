# Open Vanilla: 1.12.1 addon compatibility report

Date: 2026-10-12. Client tested: `AdventureWorld/www/wenilla_bg.wasm` (87,643,605 bytes, built 2026-10-12), served by `asset_server.py` at http://localhost:18090. Test character: Testflow (level 1 Human Warrior), Vanilla Realm, Northshire.

## Summary

**No unmodified 1.12 addon in `Data/Interface/AddOns` loads in the web client right now.** That includes the custom `ClassicPlus_Core` (its `/cp` slash command is `nil` in game). The only reason is discovery. The web build's addon registry holds two kinds of entry:

- the 12 Blizzard LoadOnDemand addons, whose `.toc` files are probed over HTTP;
- 15 compiled-in "bundled" stand-ins (Aux, Bagnon, Questie, …). These are small rewrites, not the real addons.

The loose-folder pass that should find player addons does nothing on wasm. It is `discover_folder()`, which uses `std::fs::read_dir` and has no filesystem in the browser. So `CLASSIC_PLUS_ARCHITECTURE.md` describes Tier 1 ("Data/Interface/AddOns discovered live") as working, but it does not work in the web client.

Once the engine side is bypassed, the Lua and widget API is in very good shape. I fed the unmodified addons' files into the live UI VM through the page's JavaScript bridge (the harness is described in Part 4):

- **ShaguDPS** loads with zero errors. Its window renders, and it recorded real melee damage from a fight.
- **pfQuest** loads with zero errors: 40 files, including about 15 MB of database. Its first-run dialog, world-map dropdown and quest database work, and it builds 23 map pins.
- **Ace2** (the full embedded stack OneBag ships) loads with zero errors. That covers AceLibrary, AceOO, AceEvent, AceHook-2.1, AceDB (including its debugstack-based path detection), AceLocale, AceConsole, AceAddon and Dewdrop.

The second blocker is that **addon art does not draw**. `SetTexture("Interface\\AddOns\\…")` returns nil and never makes a network request. As a result, pfQuest's map pins and its first-run preview images are invisible, and ShaguDPS's buttons are blank.

| # | Gap | Fix | Unblocks |
|---|---|---|---|
| G1 | Loose AddOns folders are never discovered on web (no registry row, no load, no ADDON_LOADED) | Rust | every addon |
| G2 | `Interface\AddOns\…` textures and fonts never resolve on web (texture/font probe and decoder root are `None`) | Rust | every addon that ships art (pfQuest, ShaguDPS, OneBag, Bagnon, pfUI…) |
| G3 | Per-addon SavedVariables are read and written with `std::fs`, which fails on wasm | Rust (verify after G1) | every addon with `## SavedVariables` |
| G4 | 53 engine globals of the 1.12 `_G` are missing, 2 of them API that addons use (`UnitCanAssist`, `UnitIsTrivial`) | `!Compat_112` shim now, Rust later | healing / click-cast / level-colour addons |
| G5 | `EditBox:SetScript("OnInputLanguageChanged")` is rejected (the stock FloatingChatFrame.xml warns at every load) | Rust | stock chat; chat addons |
| G6 | Bundled stand-ins share names with real addons (Questie, Bagnon, Postal…) and will shadow or duplicate the real folders once G1 lands | Rust | anyone installing the real Questie/Bagnon/etc. |

---

## 1. Addon pipeline map (deployed web build)

Sources:
- the live client's console log, e.g. `crates\benilla-app\src\ui_script\addons.rs:816 ui_script: 27 addon(s) found: Blizzard_AuctionUI, …, Questie, Cartographer, …`;
- XHR and fetch tracing in the page;
- `strings` of the wasm;
- the benilla-main snapshot (Oct 5) at `the local benilla-main folder`. Its file and function names match the deployed log lines.

| Stage | Where (benilla-main) | Web build behaviour, observed |
|---|---|---|
| Discovery: archive pass | `benilla-app/src/ui_script/addons.rs` `chain_addons()` | Works. At world entry and on each `/reload`, the client requests `GET /data/Interface%2FAddOns%2FBlizzard_<X>%2FBlizzard_<X>.toc` for each of the 12 fixed names. These rows are hidden from `GetNumAddOns()` by the `SMSG_ADDON_INFO` reply, which is correct 1.12 behaviour. |
| Discovery: bundled registry | `bundled_addons.rs` (not in the snapshot) | 15 rows compiled into the wasm, e.g. `-- Questie Classic+ Bundled Addon`, `Questie = Questie or { version = "3.7.1" … }`. Log line: `ui_script: Questie/Questie.lua ran`. |
| Discovery: loose folders | `addons.rs` `discover_folder()` → `root()` = `local_state::home()/AddOns` → `std::fs::read_dir` | **Never runs usefully on wasm.** It sends no request for any player folder (traced: zero XHR or fetch to `pfQuest`, `ShaguDPS`, `ClassicPlus_Core` …). |
| `/data/__index` | `asset_server.py` serves `www/__index.json`, loaded once at startup | 79,734 lowercase backslash paths, generated before ClassicPlus_Core existed. Experiment: I injected loose-addon entries into the index, both mixed-case and lowercased, by rebooting the page with a `fetch` override. Neither discovery nor `SetTexture` changed. The index is not the lever for G1 or G2. |
| `.toc` parsing | `benilla-ui/src/toc.rs` | Honoured: `Interface` (version gate exact `== 11200`, overridable by "Load out of date AddOns"), `Title`, `Notes`, `URL`, `Secure`, `Dependencies` / `RequiredDeps` / any `Dep*` key (prefix match), `OptionalDeps`, `LoadOnDemand`, `DefaultState`, `SavedVariables`, `SavedVariablesPerCharacter`. Every `## Key` is kept for `GetAddOnMetadata`. A UTF-8 BOM is stripped, and cp1252 is decoded. **Not honoured: `## LoadWith`** (documented in `Walk::load`). |
| Load order | `addons.rs` `sort_by_directory_order()` | NTFS `$UpCase` collation, so `!Compat_112` sorts first, as on Windows. Within each addon: OptionalDeps, then required deps, then `.toc` files in order, then `Bindings.xml`, then SavedVariables (account, then per-character), then `ADDON_LOADED(arg1=folder name)`. LoadOnDemand addons wait for `LoadAddOn`. There is a 200M-instruction budget per addon. |
| File and XML resolution | `Addon::read` and `benilla_ui::loader::join_ref` | `\` and `/` are both separators. `<Script file>` and `<Include file>` resolve against the including document's directory. `..\` collapses. Reads under `Interface/AddOns/` are sandboxed to the AddOns root, then fall back to the patch chain. Lua chunk names are `@Interface\AddOns\<Name>\<path>`, which Ace2's `debugstack` path parsing relies on. Verified live: `debugstack()` output carries the chunk name. |
| `/data/*` path case | `asset_server.py` `handle_data_asset` | The host is Windows/NTFS, so nested wrong-case paths already resolve: `GET /data/interface/addons/pfquest/img/tracking/chests/barrel.tga` and `/data/INTERFACE%5CADDONS%5CSHAGUDPS%5CIMG%5CSETTINGS.TGA` both return 200. `..` returns 403 or 404. The old basename-only fallback would have broken nested paths on a Linux host; this is now fixed (Part 5). |
| SavedVariables | `benilla-ui/src/script/addon.rs` `load_saved_variables()`, `ui_script/addons.rs` `save_addon_variables()` | Paths come from `local_state::addon_saved_*_dir()`. Reading uses `std::fs::read` and writing uses `local_state::write_atomic_bytes`. In the web build, `localStorage` holds only `benilla:/benilla-config/{saved-variables.lua, config.toml, chat/…, cache/…, layout/…}`. There are no per-addon keys and no `AddOns.txt`. See G3. |
| AddOns list UI | char-select and Game Menu "AddOn List" (`BenillaAddonList_*` Lua in the wasm) | Lists exactly the registry: the 15 bundled names, with profile buttons (Classic+ / Purist / Raider) hard-coded to those names. Enable and disable work through `EnableAddOn` / `DisableAddOn`. No player addon can appear until G1 is fixed. |
| Bridge | `www/bridge.js` → `window.wenilla.lua(chunk)` | Evaluates Lua in the live UI VM. The test harness uses this. |

## 2. Conformance suite (installed)

All folders are new, under `Data\Interface\AddOns\`. No existing file was touched.

| Folder | Source | License | Notes |
|---|---|---|---|
| `pfQuest` | github.com/shagu/pfQuest @ 104f356 (2025-08-25), built with the repo's own `make enUS` target, which is exactly the official enUS release zip (162 files, 18 MB). | MIT | Quest helper, the vanilla equivalent of Questie. `## SavedVariables` and `SavedVariablesPerCharacter`, `OptionalDeps: pfUI`. |
| `ShaguDPS` | github.com/shagu/ShaguDPS @ HEAD (git checkout minus `.git`) | No license file in the repo, so it was **installed locally only, not redistributed** | Damage meter that parses the combat log. |
| `OneBag`, `OneBank` | github.com/laytya/OneBag (1.12 / Ace2 r13688) | Ace2 libs are LGPL; OneBag has no license file, so local install only | Bag replacement **and** the library-heavy addon: it embeds 13 Ace2 and Dewdrop libraries. OneBank: `Dependencies: OneBag`, `LoadOnDemand: 1`. |
| `!Compat_112` | Written here (Part 5) | — | Shim for G4. Loads first. |

## 3. Static scan and gap table

The scanner (`scratchpad/scan.py`, Python) walks each `.toc` in order, follows XML `<Script>`/`<Include>`, and extracts global calls, `lib.fn` calls, `:Method(` calls, `RegisterEvent("X")` names and Lua 5.0 idioms. It removes names each addon defines itself. Every remaining name was then **probed in the live VM**: `getfenv(0)[name]`, and method lookup on instances of all 18 frame types plus Texture and FontString.

**Idioms found (all supported by the VM, verified at runtime):**

| Idiom | Count | Where |
|---|---|---|
| `this` | 675 | all addons |
| `arg1..argN` globals | 172 | all addons |
| global `event` | 218 | all addons |
| `arg` vararg table | 60 | Ace2 |
| `table.getn` / `getn` | 57 / 2 | all addons |
| `table.setn` | 1 | — |
| `string.gfind` | — | pfQuest, ShaguDPS |
| `strfind` / `tinsert` / `mod` | — | all addons |
| `debugstack`, `setfenv` / `getfenv`, `loadstring` | — | Ace2 |

The 5.1-only names (`string.gmatch`, `math.fmod`, `hooksecurefunc`, `select`) appear only behind feature tests like `string.gmatch or string.gfind`. The VM correctly does **not** define them, so the addons take their 1.12 code paths.

**API gap table, by addon (live VM probe, in world):**

| Addon | External globals used | Missing in VM | Methods used | Missing methods | Events used | Verdict |
|---|---|---|---|---|---|---|
| ShaguDPS | 24 | none | 62 | `GetAttribute` (only behind a `tbc and …` guard, never reached on 1.12) | 4 plus 31 `CHAT_MSG_COMBAT_*` / `CHAT_MSG_SPELL_*` (all present in the wasm) | API-complete |
| pfQuest | 96 | `GetQuestLink`, `GetQuestsCompleted`, `QueryQuestsCompleted`, `QuestLogTitleButton_Resize`, `WorldMapFrame_ClearQuestPOIs`: all post-1.12 and all guarded (`if GetQuestLink then`, `compat.client >= 30300`) | 176 | none | 17 (`QUEST_QUERY_COMPLETE` is 3.x and guarded) | API-complete |
| OneBag (Ace2) | 73 | `AceLibrary` (defined by its own embedded lib), `print` (a local in AceAddon) | 239 (mostly Ace OO methods) | `SetTopLevel` (guarded `if frame.SetTopLevel`), `RegisterTabCompletion` (AceConsole-2.0 optional), `GetInventorySlot` (set at runtime by stock `BankFrameItemButton_OnLoad`) | 21 | API-complete |

**Engine API coverage against the real 1.12 `_G`.** The benilla reference table `reference/1.12-globals.tsv` lists 1,121 engine/lua functions. 1,068 are present in the live VM. The 53 missing are:

- **Used by real addons:** `UnitCanAssist`, `UnitIsTrivial`. Both are shimmed in `!Compat_112`.
- **Need server data, so they cannot be shimmed:**
  - `GetActiveLevel`, `GetAvailableLevel` (gossip and quest-greeting quest levels; used by quest addons);
  - `GetCraftSkillLine`, `GetTradeSkillItemStats`;
  - `GetTrainerServiceStepIncrease`, `IsTrainerServiceSkillStep`, `GetTrainerSkillLines`, `GetTrainerSkillLineFilter`, `SetTrainerSkillLineFilter`, `OpenTrainer`;
  - `AcceptSkillUps`, `AddSkillUp`, `RemoveSkillUp`;
  - `ReplaceTradeEnchant`, `IsVendorActive`.
- **Dead or debug in the retail 1.12 UI** (`LFG*`, lottery and minigame, `GMSurvey*`, `ReadFile` / `AppendToFile` / `DeleteFile`, `Toggle{Collision,Tris,Portals,PlayerBounds,Performance*}`, `ResetPerformanceValues`, `GMRequestPlayerInfo`): low priority.

**Script handlers.** `SetScript` was probed for each 1.12 handler on each widget type. All handlers the suite uses are accepted. `EditBox` `OnInputLanguageChanged` is rejected (G5). `OnMinMaxChanged`, `OnHyperlinkEnter` / `OnHyperlinkLeave` and `OnMessageScrollChanged` are also rejected; those are not 1.12 handlers, as far as I can tell.

## 4. Live test results

**Baseline, engine only.** I installed all folders and ran `/reload`. `GetNumAddOns() == 15` (bundled only), and `pfQuest`, `ShaguDPS` and `OneBag` are all `nil`. The console log is `ui_script: 27 addon(s) found: Blizzard_AuctionUI, …, Blizzard_TrainerUI, Questie, Cartographer, ClassicCastbars, OmniCC, Bagnon, Aux, Postal, VoiceOver, ClassicThreatMeter, LunaUnitFrames, BigWigs, DPSMate, Clique, ItemRack, Immersion`. No loose folder is listed. `SlashCmdList["CLASSICPLUS"] == nil`.

**Through the dev loader** (`tools/openvanilla_addon_devloader.js`, run in the browser console). It reproduces only what the missing loose pass does:

- fetches the `.toc` over `/data`;
- runs files in `.toc` order, with chunk names `@Interface\AddOns\…`;
- follows XML `<Script>` / `<Include>`;
- adds a registry row for `GetAddOnInfo` / `GetAddOnMetadata` / `IsAddOnLoaded`;
- fires `ADDON_LOADED`, `VARIABLES_LOADED`, `PLAYER_LOGIN` and `PLAYER_ENTERING_WORLD` on the frames the addon registered.

It **cannot materialize XML frames or templates**; only the engine's FrameXML loader can do that.

| Addon | Load result | Exact errors | What visibly works | What doesn't, and why |
|---|---|---|---|---|
| ShaguDPS | `loaded`, 5/5 files | none | The DPS window appears ("Current / Damage"). After a scripted melee fight (I killed a Rabbit), `ShaguDPS.data.damage` = `1:Testflow=4, 0:Testflow=4` and the window shows "Testflow 4 (100.0%)", so combat-log parsing works end to end. | Button icons (`Interface\AddOns\ShaguDPS\img\*.tga`) are blank. `SetTexture` returns `nil` with no request (G2). |
| pfQuest | `loaded`, 40 files (≈5.3 s, the db files 18–293 ms each) | none during load or events | The first-run "select your preferred pfQuest mode" dialog appears and Save & Close works. `pfQuestConfig.path = "Interface\AddOns\pfQuest"`. The world map gets pfQuest's "All Quests" dropdown. `pfMap` built 23 `pfMapPin` frames, all shown. `SlashCmdList.PFDB` (`/db`) exists. | The three mode preview images and every map pin are invisible: the pin texture is `nil` (G2). The pin positions and logic are right but nothing draws. |
| OneBag + OneBank | `loaded`. Lua: 21 files, 0 errors. All 8 Ace2 libraries register (`AceLibrary:HasInstance` is true for each); `OneBag.db.profile` exists; `/ob` is registered. | `Interface\AddOns\OneBag\OneBag.lua:81: attempt to index global 'OneBagFrameName' (a nil value)`; `Interface\AddOns\OneBank\OneBank.lua:79: attempt to index global 'OneBankFrameName' (a nil value)`; `Interface\AddOns\OneBank\OneBank.lua:96: attempt to index field 'frame' (a nil value)` | Ace2 runs fully on this VM. | These errors are a **harness limitation**: `OneBagFrame` and its templates are XML `<Frame>` / `<Button>` definitions, which the dev loader skips (8 elements in `templates.xml` / `OneBag.xml`, 2 in `OneBank.xml`). They would be created by the engine once G1 lands. |
| ClassicPlus_Core | `loaded` | none | It prints "[Classic+] Classic+ Core v1.0.0 active. Type /cp for options." and `/cp` exists. | `ClassicPlus_CoordsFrame` is an XML frame (harness limitation). |
| !Compat_112 | `loaded` | none | `UnitCanAssist("player","player") == 1`, `UnitCanAssist("player", <Deputy Willem>) == 1`, `UnitCanAssist("player", <Rabbit>) == nil` (attackable), `UnitIsTrivial(<lvl-1 Rabbit>) == nil` for a level-1 player. | — |

Other console findings:
- `ui_script(FrameXML/Interface\FrameXML\FloatingChatFrame.xml): ChatFrameEditBox: SetScript("OnInputLanguageChanged") unsupported in v1` (G5).
- `UnitReaction("player","target")` returns nil while `UnitReaction("target","player")` returns 5. This may be faithful to the reference; it should be checked against `1.12-shapes.tsv` before changing anything.

**Not tested live:**
- The engine's own FrameXML path for addon XML (blocked by G1).
- SavedVariables round-trip through the engine (G3).
- LoadOnDemand via `LoadAddOn` for a player addon.
- OneBag's bag frame.
- pfQuest's tracker, routes and minimap pins with real quest-log entries (the test character has no quests).

## 5. Fixes applied (no wasm rebuild)

1. **Suite installed** (Part 2), plus `!Compat_112`.
2. **`!Compat_112` shim** (`Data/Interface/AddOns/!Compat_112/Compat.lua`).
   - What it adds: `UnitCanAssist` and `UnitIsTrivial`. Both are real 1.12 engine globals missing from the VM, and both return 1/nil like the original.
   - When it applies: each function is installed only `if <name> == nil`, so it becomes a no-op as soon as the engine adds the real one.
   - What it never adds: post-1.12 names. 1.12 addons feature-test those names to choose code paths, so defining them would change what an unmodified addon does.
   - **It only takes effect after G1**, or through the dev loader.
3. **`asset_server.py`.** I staged the device copy (mtime 1791840258894), edited it, checked it with `ast.parse`, and tested it on a case-sensitive host using aiohttp's TestClient. It was committed with that expectedMtimeMs. **Restart the web backend from the launcher for it to take effect.**
   - `resolve_case_insensitive()`: the `/data/*` fallback now matches **every path component** case-insensitively, not just the basename. The result goes back through the existing `safe_join` guard, and `..` and drive-qualified components are refused. This has no effect on NTFS. On Linux it fixes nested mixed-case addon paths, e.g. `pfQuest\img\tracking\chests\Barrel.tga`.
   - New `GET /data/__addons` (`Cache-Control: no-store`): a live listing of `Data/Interface/AddOns/*` folders that contain a `<Folder>.toc` (case-insensitive), giving each folder's files relative to the AddOns root. It returns `{"root":"Interface/AddOns/","addons":[{"name","toc","tocMtime","files":[…]}]}`. It is read-only and capped at 20,000 files per addon. This is the server half of the G1 fix: the web client cannot list directories, and the static `__index.json` goes stale.
   - Unchanged: `/data/__index` and all other routes.
4. **`tools/openvanilla_addon_devloader.js`**, a test harness, not deployed. Paste it into the console on `game.html` while in world, then run `await openvanillaDevLoad(['pfQuest','ShaguDPS'])`. `openvanillaDevSave()` persists the declared SavedVariables in `localStorage` under the `openvanilla-devloader:SV:` prefix. A `/reload` drops everything it loaded. It touches nothing in `www/`.

## 6. Engine (Rust) change list, by how many addons each unblocks

Paths are against the benilla-main layout. The deployed wenilla fork has the same files: its log lines cite `ui_script/addons.rs:163/223/816/834/895` and `ui_saved.rs:48`.

### E1 (G1): discover loose AddOns on web. Unblocks every addon.
- **Files:**
  - `crates/benilla-app/src/ui_script/addons.rs`: `discover_folder()`, `root()`, `enum Source`, `Addon::read`, `Addon::prefix`, `Addon::chunk_name`, `info_for()`;
  - `crates/benilla-app/src/char_select/addons.rs` (`installed_rows()`, used by the glue AddOns screen).
- **Change:**
  1. Add a `Source::Http` variant. Make `discover_folder()` under `#[cfg(target_arch = "wasm32")]` read `GET /data/__addons` once per discovery (same sync-XHR path `reference_ui::read` already uses). Build one `Addon` per entry, with the `.toc` read via `reference_ui::read("Interface/AddOns/<toc>")`.
  2. Keep the native `std::fs` path unchanged.
  3. Sort the names with `sort_by_directory_order()`.
  4. `Source::Http` behaves like `Dir` for `prefix()` (`Interface/AddOns/<Name>`) and `chunk_name()` (`@Interface\AddOns\…`). `read(req)` must refuse anything outside `Interface/AddOns/` after `join_ref` (a leading `..` component), then call `reference_ui::read(req)`. That routes through `/data/…`; the server resolves case and guards traversal.
  5. `info_for()` keeps `chain = false`, so `LoadAddOn` uses a reader for it. Give `register_addons` a reader for Http rows: add `AddonHttpReader`, mirroring `set_addon_chain_reader` in `benilla-ui/src/script/addon.rs` `load_addon()`. Without it, LoadOnDemand player addons return `MISSING`.
  6. `installed_rows()` takes the same listing, so the char-select AddOns screen shows the folders.
- **Test:** in `addons.rs` tests, add `a_web_listing_registers_loose_addons_in_directory_order`. Feed a fake listing (`!Compat_112`, `pfQuest`, `OneBank`, plus a folder without a `.toc`) through an injected fetch closure. Assert:
  - the registry order and that the `.toc`-less folder is skipped;
  - `GetNumAddOns()`;
  - `ADDON_LOADED` arg1 order;
  - `OneBank` stays LoadOnDemand and loads via `LoadAddOn("OneBank")`.

### E2 (G2): addon textures and fonts on web. Unblocks every addon that ships art.
- **File:** `crates/benilla-app/src/ui_script/lifecycle.rs` `install_addon_asset_resolvers()`. It calls `assets.set_loose_addon_root(addons::root())`, and the texture, size and font probes test `chain.contains(c) || loose_addon_file(root, c)`. On web, `root()` is `None` and the chain does not list loose files, so every `Interface\AddOns\…` path answers nil and never fetches. Verified: `SetTexture("Interface\\AddOns\\pfQuest\\img\\logo")` returns nil with zero requests, even when the index contains the file.
- **Change:**
  1. On wasm, build the set of loose addon files from the same `/data/__addons` listing (normalized like `benilla_assets::normalize_path`, lowercased, `\`).
  2. Make the probes answer from that set. Try the candidates from `sprite_candidates()`: `.blp`, then `.tga`.
  3. Add a loose-addon reader to `benilla_assets::WorldAssets` (`crates/benilla-assets/src/world_assets/images.rs`, the loose root and `loose_addon_file`) that fetches `/data/Interface/AddOns/…` bytes through the same HTTP chain reader. TGA decoding already exists in `benilla-formats/src/tga.rs`.
  4. Fonts (`ui_text::engine` face loader) need the same treatment.
- **Test:** in `benilla-assets`, `a_listed_loose_addon_tga_resolves_through_the_http_reader` (fake listing plus fake fetch returns a 2×2 TGA). In `benilla-ui/src/script/tests/regions.rs`, add `set_texture_on_an_addon_path_answers_1_when_listed`.

### E3 (G3): SavedVariables storage on web. Unblocks every addon with settings or databases.
- **Files:**
  - `crates/benilla-ui/src/script/addon.rs` `load_saved_variables()`, which uses `std::fs::read(&path)`. On wasm32 this yields `ErrorKind::Unsupported`, not `NotFound`, so the file is logged as unreadable and added to `held_saved_files`, and the writer then skips it forever.
  - `crates/benilla-app/src/ui_script/addons.rs` `save_addon_variables()`, plus the in-world twin `UiScript::load_addon_saved_variables`.
- **Change:**
  1. Route both through the `local_state` storage the web build already uses for `benilla:/benilla-config/saved-variables.lua`. Keys: `benilla:/benilla-config/SavedVariables/<Addon>.lua` for account scope and `…/SavedVariables/<Realm>/<Character>/<Addon>.lua` per character, which is the WTF layout.
  2. Pass a `read(path) -> Option<Vec<u8>>` closure into `register_addons` instead of calling `std::fs`.
  3. Treat `Unsupported` as `NotFound`.
  4. Also write `AddOns.txt` (enable state) through the same store. Today no `AddOns.txt` key exists, so enable choices do not persist across sessions on web.
- **Test:** in `addon.rs` tests, `saved_variables_round_trip_through_an_injected_store`: load, mutate a global, save, reload the VM, assert the value. Also assert that an `Unsupported` read is not held.

### E4 (G6): bundled stand-ins vs real folders. Matters as soon as E1 lands.
- **Files:** `crates/benilla-app/src/bundled_addons.rs` and `discover()` in `ui_script/addons.rs`.
- **Change:** register loose folders before the bundled rows, and drop a bundled row whose name matches a loose folder case-insensitively. This is what `CLASSIC_PLUS_ARCHITECTURE.md` promises ("Overridden automatically if a matching folder exists in Tier 1"). The current code would register the bundled `Questie` first, and "a name's first registration wins" would shadow the real Questie. Also make the AddOn List profile buttons (`BenillaAddonList_ApplyProfile`) leave unknown names alone, instead of disabling every addon not in the hard-coded list.
- **Test:** `a_loose_folder_replaces_the_bundled_row_of_the_same_name`.

### E5 (G4): missing 1.12 engine functions.
- **Files:** the `benilla-ui/src/script/unit/bindings.rs` family, `gossip.rs` / `quest.rs`, `trainer/mod.rs`, `tradeskill/api.rs`.
- **Change, in priority order:**
  1. `UnitCanAssist`, `UnitIsTrivial` in `unit/bindings.rs`, from the faction-template reaction already used by `UnitIsFriend` / `UnitCanAttack`, and the grey-level rule. Remove the shim functions once these land; the shim already steps aside.
  2. `GetActiveLevel` / `GetAvailableLevel`, from the quest-level field of `SMSG_QUESTGIVER_QUEST_LIST` / `SMSG_GOSSIP_MESSAGE`.
  3. `GetTradeSkillItemStats`, `GetCraftSkillLine`.
  4. The trainer skill-step family.
- **Test:** extend `reference_surface.rs` so its `missing` list shrinks, plus unit tests per verb.

### E6 (G5): `OnInputLanguageChanged`.
- **File:** the EditBox script table in `crates/benilla-ui/src/script/editbox/methods.rs` (the `unsupported script` gate).
- **Change:** accept the handler. Fire it on language change (`ChatEdit_OnInputLanguageChanged` exists in stock FrameXML).
- **Test:** `the_stock_chat_edit_box_loads_without_an_unsupported_script_warning`.

## 7. Files

- `/mnt/user-data/outputs/addons/`: `pfQuest/`, `ShaguDPS/`, `OneBag/`, `OneBank/`, `!Compat_112/` (all committed to `AdventureWorld\Data\Interface\AddOns\`).
- `/mnt/user-data/outputs/asset_server.py`, committed to `AdventureWorld\asset_server.py` (restart the backend).
- `/mnt/user-data/outputs/tools/openvanilla_addon_devloader.js` (the harness; not committed to the device).
- This report, committed to `AdventureWorld\ADDON_COMPAT_REPORT.md`.
