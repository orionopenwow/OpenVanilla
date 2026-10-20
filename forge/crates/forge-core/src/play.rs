//! Test & Play (plan §4.6): put a dev build of the pack into Forge's own test copies of the
//! creator's client and Play Solo realm (`testbed`), start the game, and take it all back out.
//! The creator's real game folder and their own Play Solo are never written: everything below
//! happens in the copies.
//!
//! * **Client**: the dev MPQ (the pack's files plus DBCs merged from the creator's own) goes in as
//!   `Data\patch-~.MPQ`. `~` sorts after every letter in the client's `patch-?.MPQ` order, so it
//!   wins over Open Vanilla's patch-Z. One pack at a time; `Data\forge-dev.json` says which.
//! * **Realm**: Play Solo runs every `.sql` in `solo\forge-dev\` on its next start (after Open
//!   Vanilla's own content, once per change: play_local.py). Forge writes
//!   `forge_dev_<pack>.sql` = the previous install's rollback + this install, so rows the creator
//!   deleted go away too; removing writes just the rollback. The server's DBCs
//!   (`solo\gamedata\dbc`) get the pack's DBC rows merged in, from untouched copies kept in
//!   `solo\forge-dev\dbc-orig\`.
//! * **Ground**: tiles the pack reshaped, holed, watered or re-zoned are converted to the
//!   server's `.map` files (`solo\gamedata\maps`), the originals kept in
//!   `solo\forge-dev\maps-orig\`, so the solo server walks and swims on the new terrain.
//! * **Collision**: tiles where the pack places or hides doodads and buildings get the server's
//!   collision files rewritten (`solo\gamedata\vmaps`, see `vmap`), the originals kept in
//!   `solo\forge-dev\vmaps-orig\`, so a placed inn has walls and a roof on the server.

use crate::build::{self, Report};
use crate::data;
use crate::project::Project;
use crate::vfs::{find_data_dir, GameData};
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

pub const DEV_ARCHIVE: &str = "patch-~.MPQ";
const MARKER: &str = "forge-dev.json";

/// The Open Vanilla folder: configured, or the game folder when it is one (it holds play_local.py).
pub fn openvanilla_dir(configured: Option<&Path>, game: Option<&Path>) -> Option<PathBuf> {
    let is_ov = |d: &Path| d.join("play_local.py").is_file();
    if let Some(c) = configured.filter(|c| is_ov(c)) {
        return Some(c.to_path_buf());
    }
    let g = game?;
    [g.to_path_buf(), g.parent().map(Path::to_path_buf).unwrap_or_default()].into_iter().find(|d| is_ov(d))
}

/// Where Play Solo keeps its servers (play_local.default_solo_root).
pub fn solo_dir(ov: &Path) -> PathBuf {
    if let Ok(e) = std::env::var("OPENVANILLA_SOLO_DIR") {
        return PathBuf::from(e);
    }
    let here = ov.join("solo");
    if here.join("bin").is_dir() {
        return here;
    }
    for base in [std::env::var("LOCALAPPDATA").ok(), std::env::var("APPDATA").ok()].into_iter().flatten() {
        for name in ["OpenVanilla", "OpenWoW"] {
            let d = PathBuf::from(&base).join(name).join("solo");
            if d.join("bin").is_dir() {
                return d;
            }
        }
    }
    here
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClientMarker {
    pub pack: String,
    pub name: String,
    pub project: PathBuf,
    pub build_hash: String,
    /// Addon folders put into Interface\AddOns for testing (the pack's, and Forge Link).
    #[serde(default)]
    pub addons: Vec<String>,
}

/// The client loads addons only from its Interface\AddOns folder (not from archives): put the
/// pack's there for testing, with Forge Link, each marked so Forge only ever touches its own.
fn install_addons(p: &Project, game_dir: &Path, prev: &[String], notes: &mut Vec<String>) -> Result<Vec<String>> {
    let dir = game_dir.join("Interface").join("AddOns");
    std::fs::create_dir_all(&dir)?;
    let ours = |name: &str| dir.join(name).join(".forge-dev").is_file() || prev.iter().any(|x| x.eq_ignore_ascii_case(name));
    let mut done = vec![];
    for a in p.addons() {
        let name = a.file_name().unwrap().to_string_lossy().to_string();
        let to = dir.join(&name);
        if to.exists() && !ours(&name) {
            notes.push(format!("Your client already has an addon called {name} (not Forge's): left as it is, so the game runs that one."));
            continue;
        }
        let _ = std::fs::remove_dir_all(&to);
        copy_dir(&a, &to)?;
        std::fs::write(to.join(".forge-dev"), "installed by Vanilla Forge's Test & Play\r\n")?;
        done.push(name);
    }
    if !dir.join("ForgeLink").exists() || ours("ForgeLink") {
        crate::livelink::install_addon(&dir)?;
        done.push("ForgeLink".into());
    }
    // the previous test's addons this build no longer has
    for old in prev.iter().filter(|o| !done.contains(o)) {
        if dir.join(old).join(".forge-dev").is_file() {
            let _ = std::fs::remove_dir_all(dir.join(old));
        }
    }
    Ok(done)
}

fn remove_addons(game_dir: &Path, list: &[String]) {
    let dir = game_dir.join("Interface").join("AddOns");
    for a in list {
        if dir.join(a).join(".forge-dev").is_file() {
            let _ = std::fs::remove_dir_all(dir.join(a));
        }
    }
}

fn copy_dir(from: &Path, to: &Path) -> Result<()> {
    std::fs::create_dir_all(to)?;
    for e in std::fs::read_dir(from)?.flatten() {
        let (f, t) = (e.path(), to.join(e.file_name()));
        if f.is_dir() {
            copy_dir(&f, &t)?;
        } else {
            std::fs::copy(&f, &t)?;
        }
    }
    Ok(())
}

/// What's installed where, for the Test screen.
pub fn status(p: &Project, game: Option<&Path>, ov: Option<&Path>) -> Value {
    let test_game = game.map(crate::testbed::client_dir);
    let data = game.map(crate::testbed::client_root).and_then(|g| find_data_dir(&g));
    let test_data = test_game.as_deref().and_then(find_data_dir);
    let client = test_data.as_ref().and_then(|d| std::fs::read(d.join(MARKER)).ok()).and_then(|b| serde_json::from_slice::<ClientMarker>(&b).ok());
    let real_solo = ov.map(solo_dir);
    let solo = ov.map(|_| crate::testbed::solo_dir());
    let realm_sql = solo.as_ref().map(|s| s.join("forge-dev").join(sql_name(&p.manifest.pack.id)));
    let realm_state = realm_sql.as_ref().and_then(|f| std::fs::read_to_string(f).ok()).map(|t| if t.contains("-- forge: installed") { "installed" } else { "removed" });
    // GM commands that bring the pack's new things in front of you
    let d = data::load(p);
    let mut gm = vec![];
    for (kind, table, key, cmd, namek) in [("world", "creature_template", "Entry", ".npc add", "Name"), ("world", "item_template", "entry", ".additem", "name"), ("dbc", "Spell", "ID", ".learn", "Name_lang")] {
        let m = if kind == "world" { &d.world } else { &d.dbc };
        for r in m.get(table).map(|r| r.rows.as_slice()).unwrap_or_default() {
            if r.get("override").and_then(toml::Value::as_bool) == Some(true) {
                continue;
            }
            if let Some(id) = r.iter().find(|(k, _)| k.eq_ignore_ascii_case(key)).and_then(|(_, v)| v.as_integer()) {
                let name = r.iter().find(|(k, _)| k.eq_ignore_ascii_case(namek)).and_then(|(_, v)| v.as_str()).unwrap_or("");
                gm.push(json!({"cmd": format!("{cmd} {id}"), "what": name}));
            }
        }
    }
    json!({
        "gm": gm,
        "gameData": data,
        "client": client,
        "clientIsThis": client.as_ref().is_some_and(|c| c.pack == p.manifest.pack.id),
        "openvanilla": ov,
        "solo": solo,
        "testGame": test_game,
        "realLeftovers": real_leftovers(game, ov),
        "testMade": crate::testbed::solo_dir().join("state.json").is_file(),
        "soloReady": real_solo.as_ref().is_some_and(|s| s.join("bin").is_dir()),
        "realm": realm_state,
    })
}

fn sql_name(pack: &str) -> String {
    format!("forge_dev_{}.sql", pack.replace('-', "_"))
}

fn rollback_name(pack: &str) -> String {
    format!("{}.rollback", pack.replace('-', "_"))
}

#[derive(Debug, Serialize)]
pub struct Installed {
    pub build: Report,
    pub client: Option<String>,
    pub realm: Option<String>,
    pub server_dbc: Vec<String>,
    pub server_maps: Vec<String>,
    /// Collision files (vmaps) written for the buildings and props the pack places or hides.
    pub server_vmaps: Vec<String>,
    pub notes: Vec<String>,
}

/// Dev build, then install into the client and (when Play Solo is set up) the solo realm.
pub fn install(p: &Project, game: &GameData, ov: Option<&Path>) -> Result<Installed> {
    let report = build::build_with(p, Some(game), true)?;
    let mut notes = vec![];
    // client: Forge's test copy of the game
    let (test_game, synced) = crate::testbed::sync_client(&game.dir)?;
    if synced.copied_bytes > 512 << 20 {
        notes.push(format!("Made the test copy of your game at {} ({} MB copied: it's on another drive, so it couldn't share the files).", test_game.display(), synced.copied_bytes >> 20));
    }
    let data = find_data_dir(&test_game).context("no Data folder in the test copy of the game")?;
    let marker_path = data.join(MARKER);
    let prev = std::fs::read(&marker_path).ok().and_then(|b| serde_json::from_slice::<ClientMarker>(&b).ok());
    if let Some(prev) = &prev {
        if prev.pack != p.manifest.pack.id {
            notes.push(format!("{} was in your client for testing; it's replaced by this pack (one at a time).", prev.name));
        }
    }
    let addons = install_addons(p, &test_game, &prev.map(|m| m.addons).unwrap_or_default(), &mut notes)?;
    let dst = data.join(DEV_ARCHIVE);
    let client = if report.mpq.is_empty() {
        let _ = std::fs::remove_file(&dst);
        None
    } else {
        std::fs::copy(p.build_dir().join(&report.mpq), &dst).with_context(|| format!("can't write {} (is the game running?)", dst.display()))?;
        Some(dst.display().to_string())
    };
    let m = ClientMarker { pack: p.manifest.pack.id.clone(), name: p.manifest.pack.name.clone(), project: p.root.clone(), build_hash: report.build_hash.clone(), addons };
    std::fs::write(&marker_path, serde_json::to_vec_pretty(&m)?)?;

    // realm
    let mut realm = None;
    let mut server_dbc = vec![];
    let mut server_maps = vec![];
    let mut server_vmaps = vec![];
    match ov.map(|o| (o, solo_dir(o))) {
        Some((o, real)) if real.join("bin").is_dir() => {
            // the realm side: Forge's test copy of Play Solo
            let (solo, _) = crate::testbed::sync_solo(&real, crate::livelink::real_solo_running(o))?;
            let dev = solo.join("forge-dev");
            std::fs::create_dir_all(&dev)?;
            let pack = &p.manifest.pack.id;
            let prev_rollback = std::fs::read_to_string(dev.join(rollback_name(pack))).unwrap_or_default();
            let d = data::load(p);
            let (ins, rb) = data::sql(p, &d);
            let body = format!(
                "-- run against classicmangos\n-- forge: installed {} {} (build {})\n-- 1. undo the previous test install\n{}\n-- 2. this build\n{}",
                p.manifest.pack.name, p.manifest.pack.version, &report.build_hash[..12], prev_rollback, ins
            );
            std::fs::write(dev.join(sql_name(pack)), body)?;
            std::fs::write(dev.join(rollback_name(pack)), rb)?;
            realm = Some(dev.join(sql_name(pack)).display().to_string());
            server_dbc = merge_server_dbcs(&solo, pack, &d)?;
            server_maps = write_server_maps(p, game, &solo, pack, &mut notes)?;
            server_vmaps = write_server_vmaps(p, game, &solo, pack, &report, &mut notes)?;
            notes.push("Forge's test realm takes the rows when it next starts (Test in game starts it; if it's already running, stop it first).".into());
        }
        Some((_, solo)) => notes.push(format!("Play Solo isn't set up in {} yet: run it once from the launcher, then Install again for the realm side.", solo.display())),
        None => notes.push("Forge doesn't know your Open Vanilla folder, so only the client got the pack: set it on this screen.".into()),
    }
    Ok(Installed { build: report, client, realm, server_dbc, server_maps, server_vmaps, notes })
}

/// Whether an older Forge left test files in the real game folder or the real Play Solo.
pub fn real_leftovers(game: Option<&Path>, ov: Option<&Path>) -> bool {
    let client = game.map(crate::testbed::client_root).and_then(|r| find_data_dir(&r)).is_some_and(|d| d.join(MARKER).is_file());
    let realm = ov.map(solo_dir).and_then(|r| std::fs::read_dir(r.join("forge-dev")).ok()).is_some_and(|rd| {
        rd.flatten().any(|e| e.file_name().to_string_lossy().ends_with(".rollback") || e.file_name().to_string_lossy().ends_with(".dbc.json"))
    });
    client || realm
}

/// Older Forge versions put test builds into the real game folder and the real Play Solo. Only
/// when the creator asks: take out only what Forge itself put there (its marked files; the server files it kept originals of;
/// the realm rows it added, through their rollback on the next Play Solo start), once.
pub fn cleanup_real(game: &Path, ov: Option<&Path>) -> Result<Vec<String>> {
    let mut notes = vec![];
    let root = crate::testbed::client_root(game);
    if let Some(data) = find_data_dir(&root) {
        let marker = data.join(MARKER);
        if let Some(m) = std::fs::read(&marker).ok().and_then(|b| serde_json::from_slice::<ClientMarker>(&b).ok()) {
            remove_addons(&root, &m.addons);
            let _ = std::fs::remove_file(data.join(DEV_ARCHIVE));
            let _ = std::fs::remove_file(&marker);
            notes.push(format!("Took an older Forge's test build of {} out of your real game folder: testing now uses a copy.", m.name));
        }
    }
    if let Some(real) = ov.map(solo_dir) {
        let dev = real.join("forge-dev");
        if dev.is_dir() {
            let mut undid = false;
            for e in std::fs::read_dir(&dev)?.flatten() {
                let f = e.path();
                let name = f.file_name().unwrap_or_default().to_string_lossy().to_string();
                if let Some(pack) = name.strip_suffix(".rollback") {
                    let rb = std::fs::read_to_string(&f)?;
                    std::fs::write(dev.join(format!("forge_dev_{pack}.sql")), format!("-- run against classicmangos\n-- forge: removed (testing moved to Forge's own realm)\n{rb}"))?;
                    std::fs::remove_file(&f)?;
                    undid = true;
                }
                if let Some(pack) = name.strip_suffix(".dbc.json") {
                    let _ = pack;
                    if let Some(st) = std::fs::read(&f).ok().and_then(|b| serde_json::from_slice::<ServerState>(&b).ok()) {
                        for t in &st.tables {
                            restore_server_dbc(&real, t)?;
                        }
                        for m in &st.maps {
                            restore_server_map(&real, m)?;
                        }
                    }
                    std::fs::remove_file(&f)?;
                    undid = true;
                }
            }
            if undid {
                notes.push("Put your own Play Solo back as it was before an older Forge's tests (its rows go on its next start).".into());
            }
        }
    }
    Ok(notes)
}

/// The pack's edited tiles as the server's .map files in the solo realm (originals kept).
fn write_server_maps(p: &Project, game: &GameData, solo: &Path, pack: &str, notes: &mut Vec<String>) -> Result<Vec<String>> {
    let maps_dir = solo.join("gamedata").join("maps");
    let dev = solo.join("forge-dev");
    let state_path = dev.join(format!("{}.dbc.json", pack.replace('-', "_")));
    let mut st: ServerState = std::fs::read(&state_path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
    let tiles = crate::world::terrain_tiles(p);
    let mut done = vec![];
    if !tiles.is_empty() && maps_dir.is_dir() {
        let at = server_dbc_file(&solo.join("gamedata").join("dbc"), "AreaTable").map(std::fs::read).transpose()?;
        let at = match at {
            Some(b) => b,
            None => game.read("DBFilesClient\\AreaTable.dbc")?,
        };
        let flags = crate::gridmap::area_flags(&data::Dbc::parse(&at)?);
        let orig_dir = dev.join("maps-orig");
        for (map, a, b) in &tiles {
            let Some(id) = crate::world::map_id(p, map) else { continue };
            let name = crate::gridmap::file_name(id, *a, *b);
            let live = maps_dir.join(&name);
            std::fs::create_dir_all(&orig_dir)?;
            let orig = orig_dir.join(&name);
            if !orig.exists() && live.exists() {
                std::fs::copy(&live, &orig)?;
            }
            let version = std::fs::read(&orig).ok().and_then(|b| crate::gridmap::version_of(&b)).unwrap_or(crate::gridmap::VERSION);
            let (t, _) = crate::world::current_tile(p, game, map, *a, *b)?;
            crate::testbed::write_own(&live, &crate::gridmap::convert(&t, &|i| flags.get(&i).copied(), version)?)?;
            done.push(name);
        }
        notes.push(format!(
            "The solo server walks the new ground on {} tile(s); its movement maps for them are the old ones until rebuilt (creatures may path oddly there).",
            done.len()
        ));
    }
    // tiles no longer edited go back
    for m in st.maps.iter().filter(|m| !done.contains(m)) {
        restore_server_map(solo, m)?;
    }
    st.maps = done.clone();
    std::fs::create_dir_all(&dev)?;
    std::fs::write(&state_path, serde_json::to_vec(&st)?)?;
    Ok(done)
}

/// The buildings and props the pack places (or hides) as the solo server's collision: its vmaps
/// for those tiles rewritten (see `vmap`), the originals kept in `forge-dev\vmaps-orig\`. Each
/// install starts again from the originals, so a removed building leaves no walls behind.
fn write_server_vmaps(p: &Project, game: &GameData, solo: &Path, pack: &str, report: &Report, notes: &mut Vec<String>) -> Result<Vec<String>> {
    let live = solo.join("gamedata").join("vmaps");
    let dev = solo.join("forge-dev");
    let state_path = dev.join(format!("{}.dbc.json", pack.replace('-', "_")));
    let mut st: ServerState = std::fs::read(&state_path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
    for f in &st.vmaps {
        restore_server_vmap(solo, f)?;
    }
    let mut written: Vec<String> = vec![];
    let tiles = crate::world::collision_tiles(p)?;
    if !tiles.is_empty() && live.is_dir() && !report.mpq.is_empty() {
        let archive = crate::realm::read_mpq(&p.build_dir().join(&report.mpq))?;
        let read = |path: &str| crate::world::read_art(p, Some(game), path).ok();
        let tmp = dev.join("vmaps-new");
        let _ = std::fs::remove_dir_all(&tmp);
        let (mut added, mut removed) = (0, 0);
        for (map, set) in &tiles {
            let Some(id) = crate::world::map_id(p, map) else { continue };
            if !live.join(crate::vmap::tree_name(id)).is_file() {
                notes.push(format!("The test realm has no collision data for {map} (no {} in its vmaps): buildings placed there can be walked through.", crate::vmap::tree_name(id)));
                continue;
            }
            let list: Vec<((u32, u32), Vec<u8>)> = set
                .iter()
                .filter_map(|&(a, b)| {
                    let path = crate::adt::tile_path(map, a, b);
                    archive.iter().find(|(n, _)| n.eq_ignore_ascii_case(&path)).map(|(_, bytes)| ((a as u32, b as u32), bytes.clone()))
                })
                .collect();
            if list.is_empty() {
                continue;
            }
            let done = crate::vmap::rebuild(&live, &tmp, id, &list, &read).with_context(|| format!("collision for {map}"))?;
            added += done.added;
            removed += done.removed;
            notes.extend(done.warnings);
            let orig_dir = dev.join("vmaps-orig");
            std::fs::create_dir_all(&orig_dir)?;
            for f in done.files {
                let l = live.join(&f);
                let orig = orig_dir.join(&f);
                if !orig.exists() && l.exists() {
                    std::fs::copy(&l, &orig)?;
                }
                crate::testbed::copy_own(&tmp.join(&f), &l)?;
                written.push(f);
            }
        }
        let _ = std::fs::remove_dir_all(&tmp);
        if added + removed > 0 {
            notes.push(format!(
                "The test realm's collision follows your placements ({added} model(s) solid, {removed} taken away): players and creatures stop at your buildings' walls. Creatures' paths (movement maps) are the old ones until rebuilt."
            ));
        }
    }
    st.vmaps = written.clone();
    std::fs::create_dir_all(&dev)?;
    std::fs::write(&state_path, serde_json::to_vec(&st)?)?;
    Ok(written)
}

fn restore_server_vmap(solo: &Path, name: &str) -> Result<()> {
    let orig = solo.join("forge-dev").join("vmaps-orig").join(name);
    let live = solo.join("gamedata").join("vmaps").join(name);
    if orig.exists() {
        crate::testbed::copy_own(&orig, &live)?;
    } else {
        let _ = std::fs::remove_file(&live); // a file Forge added (a model's collision mesh)
    }
    Ok(())
}

fn restore_server_map(solo: &Path, name: &str) -> Result<()> {
    let orig = solo.join("forge-dev").join("maps-orig").join(name);
    let live = solo.join("gamedata").join("maps").join(name);
    if orig.exists() {
        crate::testbed::copy_own(&orig, &live)?;
    } else {
        let _ = std::fs::remove_file(&live); // a tile the server had no file for
    }
    Ok(())
}

/// The DBC files in the server's dbc folder, by lowercase name.
fn server_dbc_file(dir: &Path, table: &str) -> Option<PathBuf> {
    std::fs::read_dir(dir).ok()?.filter_map(|e| e.ok()).map(|e| e.path()).find(|f| f.file_name().is_some_and(|n| n.to_string_lossy().eq_ignore_ascii_case(&format!("{table}.dbc"))))
}

#[derive(Default, Serialize, Deserialize)]
struct ServerState {
    /// Tables this pack has merged into the server's DBCs.
    tables: Vec<String>,
    /// Server map tiles this pack has replaced.
    #[serde(default)]
    maps: Vec<String>,
    /// Collision files (vmaps) this pack has written.
    #[serde(default)]
    vmaps: Vec<String>,
}

fn merge_server_dbcs(solo: &Path, pack: &str, d: &data::Data) -> Result<Vec<String>> {
    let dbc_dir = solo.join("gamedata").join("dbc");
    let dev = solo.join("forge-dev");
    let orig_dir = dev.join("dbc-orig");
    let state_path = dev.join(format!("{}.dbc.json", pack.replace('-', "_")));
    let prev: ServerState = std::fs::read(&state_path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
    let mut done = vec![];
    for (t, rows) in &d.dbc {
        if rows.rows.is_empty() {
            continue;
        }
        let Some(live) = server_dbc_file(&dbc_dir, t) else { continue };
        std::fs::create_dir_all(&orig_dir)?;
        let orig = orig_dir.join(live.file_name().unwrap());
        if !orig.exists() {
            std::fs::copy(&live, &orig)?;
        }
        let base = data::Dbc::parse(&std::fs::read(&orig)?).with_context(|| format!("server {t}.dbc"))?;
        let merged = data::merge(t, &base, &rows.rows)?;
        crate::testbed::write_own(&live, &merged.write())?;
        done.push(t.clone());
    }
    // tables this pack no longer touches go back to the originals
    for t in prev.tables.iter().filter(|t| !done.contains(t)) {
        restore_server_dbc(solo, t)?;
    }
    std::fs::write(&state_path, serde_json::to_vec(&ServerState { tables: done.clone(), maps: prev.maps, vmaps: prev.vmaps })?)?;
    Ok(done)
}

fn restore_server_dbc(solo: &Path, table: &str) -> Result<()> {
    let orig_dir = solo.join("forge-dev").join("dbc-orig");
    if let Some(orig) = server_dbc_file(&orig_dir, table) {
        let live = solo.join("gamedata").join("dbc").join(orig.file_name().unwrap());
        crate::testbed::copy_own(&orig, &live)?;
    }
    Ok(())
}

/// Take the pack back out: the client archive (if it's this pack's), the realm rows (the next
/// Play Solo start runs the rollback) and the server DBCs.
pub fn remove(p: &Project, game: Option<&Path>, ov: Option<&Path>) -> Result<Vec<String>> {
    let mut did = vec![];
    let test_game = game.map(crate::testbed::client_dir);
    let game = test_game.as_deref();
    let ov_solo = ov.map(|_| crate::testbed::solo_dir()).filter(|d| d.join("state.json").is_file());
    if let Some(data) = game.and_then(find_data_dir) {
        let marker = data.join(MARKER);
        let m = std::fs::read(&marker).ok().and_then(|b| serde_json::from_slice::<ClientMarker>(&b).ok()).filter(|m| m.pack == p.manifest.pack.id);
        if let Some(m) = m {
            if let Some(gd) = game {
                remove_addons(gd, &m.addons);
            }
            let _ = std::fs::remove_file(data.join(DEV_ARCHIVE));
            std::fs::remove_file(&marker)?;
            did.push("Removed from the test copy of your game.".to_string());
        }
    }
    if let Some(solo) = ov_solo {
        let dev = solo.join("forge-dev");
        let pack = &p.manifest.pack.id;
        if let Ok(rb) = std::fs::read_to_string(dev.join(rollback_name(pack))) {
            std::fs::write(dev.join(sql_name(pack)), format!("-- run against classicmangos\n-- forge: removed {}\n{rb}", p.manifest.pack.name))?;
            std::fs::remove_file(dev.join(rollback_name(pack)))?;
            did.push("The test realm puts its rows back when it next starts.".to_string());
        }
        let state_path = dev.join(format!("{}.dbc.json", pack.replace('-', "_")));
        if let Some(st) = std::fs::read(&state_path).ok().and_then(|b| serde_json::from_slice::<ServerState>(&b).ok()) {
            for t in &st.tables {
                restore_server_dbc(&solo, t)?;
            }
            for m in &st.maps {
                restore_server_map(&solo, m)?;
            }
            for f in &st.vmaps {
                restore_server_vmap(&solo, f)?;
            }
            std::fs::remove_file(&state_path)?;
            if !st.tables.is_empty() {
                did.push(format!("Restored the server's {}.", st.tables.join(", ")));
            }
            if !st.maps.is_empty() {
                did.push(format!("Put back the server's ground for {} tile(s).", st.maps.len()));
            }
            if !st.vmaps.is_empty() {
                did.push("Put back the server's collision where your buildings and props stood.".to_string());
            }
        }
    }
    if did.is_empty() {
        bail!("this pack isn't installed for testing");
    }
    Ok(did)
}

/// Start Play Solo (the launcher's own code) in its own window.
/// Start Forge's test realm with the test copy of the game (Play Solo's own code, pointed at the
/// copies): the creator's own Play Solo and game folder aren't used.
pub fn play_solo(ov: &Path, python: &[String], game: Option<&Path>) -> Result<()> {
    let solo = crate::testbed::solo_dir();
    if !solo.join("state.json").is_file() {
        bail!("Forge's test realm isn't made yet: Install on the Test screen (or Test in game) makes it from your Play Solo first");
    }
    if crate::livelink::real_solo_running(ov) {
        bail!("Your own Play Solo is running, and Forge's test realm uses the same ports: close the game (or 'Play Solo.bat' solo-stop), then start again");
    }
    // only ever the test copy of the game (signed in to this PC): never the creator's own game
    let g = game.context("Forge doesn't know your game folder: set it on Home first")?;
    let test_game = crate::testbed::client_dir(g);
    if !test_game.is_dir() || find_data_dir(&test_game).is_none() {
        bail!("The test copy of your game isn't made yet: Build & install on the Test screen (or Test in game) makes it first");
    }
    crate::testbed::pin_local(&test_game)?;
    let mut cmd = std::process::Command::new(&python[0]);
    cmd.args(&python[1..]).arg(ov.join("play_local.py")).arg("solo").current_dir(ov).env("OPENVANILLA_SOLO_DIR", &solo);
    if ["WoW.exe", "Wow.exe", "wow.exe"].iter().any(|n| test_game.join(n).is_file()) {
        cmd.arg("--client").arg(&test_game);
    }
    cmd.arg("--data").arg(&test_game);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0000_0010); // CREATE_NEW_CONSOLE: its progress and log in a window
    }
    cmd.spawn().context("couldn't start Play Solo")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::{create, Template};

    #[test]
    fn install_and_remove_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        // a game with a SpellIcon.dbc, an Open Vanilla folder with a set-up solo realm
        let game_dir = dir.path().join("ov");
        let data_dir = game_dir.join("Data");
        std::fs::create_dir_all(&data_dir).unwrap();
        let dbc = crate::data::tests::fake_dbc().write();
        wow_mpq::ArchiveBuilder::new().add_file_data(dbc.clone(), "DBFilesClient\\SpellIcon.dbc").build(data_dir.join("dbc.MPQ")).unwrap();
        std::fs::write(game_dir.join("play_local.py"), "").unwrap();
        let solo = game_dir.join("solo");
        std::fs::create_dir_all(solo.join("bin")).unwrap();
        std::fs::create_dir_all(solo.join("gamedata/dbc")).unwrap();
        std::fs::write(solo.join("gamedata/dbc/SpellIcon.dbc"), &dbc).unwrap();
        let ov = openvanilla_dir(None, Some(&game_dir)).unwrap();
        // the real game and realm as they were: Forge works in copies of them
        let (test_game, test_solo) = (dir.path().join("test-game"), dir.path().join("test-solo"));
        crate::testbed::override_dirs(Some(test_game.clone()), Some(test_solo.clone()));
        std::fs::write(solo.join("state.json"), "{}").unwrap();
        let real_dbc_before = std::fs::read(solo.join("gamedata/dbc/SpellIcon.dbc")).unwrap();

        let p = create(dir.path().join("p"), "Test Pack", "Orion", Template::Pack).unwrap();
        let mut lock = crate::ids::IdLock::load(&p.root).unwrap();
        let icon = lock.allocate(&p.manifest.pack.id, "SpellIcon", "").unwrap();
        let ct = lock.allocate(&p.manifest.pack.id, "creature_template", "").unwrap();
        lock.save(&p.root).unwrap();
        std::fs::create_dir_all(p.root.join("data/dbc")).unwrap();
        std::fs::create_dir_all(p.root.join("data/world")).unwrap();
        std::fs::write(p.root.join("data/dbc/SpellIcon.toml"), format!("[[row]]\nID = {icon}\nclone = 1\n")).unwrap();
        std::fs::write(p.root.join("data/world/creature_template.toml"), format!("[[row]]\nEntry = {ct}\nName = \"X\"\n")).unwrap();

        let game = GameData::open(&game_dir).unwrap();
        let r = install(&p, &game, Some(&ov)).unwrap();
        assert!(!data_dir.join(DEV_ARCHIVE).exists(), "the real game folder isn't written");
        assert_eq!(std::fs::read(solo.join("gamedata/dbc/SpellIcon.dbc")).unwrap(), real_dbc_before, "nor the real realm");
        assert!(!solo.join("forge-dev").exists());
        let (data_dir, solo) = (test_game.join("Data"), test_solo.clone());
        assert!(data_dir.join(DEV_ARCHIVE).is_file());
        let mut a = wow_mpq::Archive::open(data_dir.join(DEV_ARCHIVE)).unwrap();
        let merged = crate::data::Dbc::parse(&a.read_file("DBFilesClient\\SpellIcon.dbc").unwrap()).unwrap();
        assert!(merged.find(icon).is_some(), "the client sees the new icon");
        assert_eq!(r.server_dbc, vec!["SpellIcon"]);
        let server = crate::data::Dbc::parse(&std::fs::read(solo.join("gamedata/dbc/SpellIcon.dbc")).unwrap()).unwrap();
        assert!(server.find(icon).is_some(), "the server sees it too");
        let sql = std::fs::read_to_string(solo.join("forge-dev/forge_dev_test_pack.sql")).unwrap();
        assert!(sql.starts_with("-- run against classicmangos") && sql.contains(&format!("`Entry` = {ct}")));
        // GameData skips Forge's own archive: the icon isn't "stock"
        let again = GameData::open(&game_dir).unwrap();
        assert!(!crate::check::run(&p, Some(&again)).iter().any(|f| f.code == "data.clash"));
        assert_eq!(status(&p, Some(&game_dir), Some(&ov))["realm"], "installed");

        // a second install undoes the first before applying
        install(&p, &again, Some(&ov)).unwrap();
        let sql2 = std::fs::read_to_string(solo.join("forge-dev/forge_dev_test_pack.sql")).unwrap();
        assert!(sql2.contains("1. undo the previous test install\n-- Test Pack"), "{sql2}");

        let did = remove(&p, Some(&game_dir), Some(&ov)).unwrap();
        assert_eq!(did.len(), 3, "{did:?}");
        assert!(!real_leftovers(Some(&game_dir), Some(&ov)));
        assert!(!data_dir.join(DEV_ARCHIVE).exists());
        assert_eq!(std::fs::read(solo.join("gamedata/dbc/SpellIcon.dbc")).unwrap(), dbc, "server DBC restored byte for byte");
        let rb = std::fs::read_to_string(solo.join("forge-dev/forge_dev_test_pack.sql")).unwrap();
        assert!(rb.contains("forge: removed") && rb.contains(&format!("DELETE FROM `creature_template` WHERE `Entry` = {ct};")));
        assert_eq!(status(&p, Some(&game_dir), Some(&ov))["realm"], "removed");
    }

    #[test]
    fn edited_ground_goes_to_the_solo_server_and_back() {
        let dir = tempfile::tempdir().unwrap();
        let game_dir = dir.path().join("ov");
        let data_dir = game_dir.join("Data");
        std::fs::create_dir_all(&data_dir).unwrap();
        let at = crate::data::Dbc { fields: 4, records: vec![vec![12, 0, 0, 1], vec![87, 0, 0, 5]], strings: vec![0] };
        wow_mpq::ArchiveBuilder::new()
            .add_file_data(at.write(), "DBFilesClient\\AreaTable.dbc")
            .add_file_data(crate::adt::tests::fake_tile(32, 48, 20.0), "World\\Maps\\Azeroth\\Azeroth_32_48.adt")
            .build(data_dir.join("dbc.MPQ"))
            .unwrap();
        std::fs::write(game_dir.join("play_local.py"), "").unwrap();
        let solo = game_dir.join("solo");
        std::fs::create_dir_all(solo.join("bin")).unwrap();
        std::fs::create_dir_all(solo.join("gamedata/maps")).unwrap();
        let stock = b"MAPSz1.4 the extractor's own tile".to_vec();
        std::fs::write(solo.join("gamedata/maps/0004832.map"), &stock).unwrap();
        let ov = openvanilla_dir(None, Some(&game_dir)).unwrap();
        crate::testbed::override_dirs(Some(dir.path().join("test-game")), Some(dir.path().join("test-solo")));
        std::fs::write(solo.join("state.json"), "{}").unwrap();
        let real = solo.clone();
        let p = create(dir.path().join("p"), "Ground Pack", "Orion", Template::Pack).unwrap();
        let t = p.root.join("maps/Azeroth/terrain");
        std::fs::create_dir_all(&t).unwrap();
        std::fs::write(t.join("32_48.chunks.json"), r#"{"3_4":{"area":87}}"#).unwrap();
        let game = GameData::open(&game_dir).unwrap();
        let r = install(&p, &game, Some(&ov)).unwrap();
        assert_eq!(r.server_maps, vec!["0004832.map"]);
        assert_eq!(std::fs::read(real.join("gamedata/maps/0004832.map")).unwrap(), stock, "the real realm's ground isn't written");
        let solo = dir.path().join("test-solo");
        let m = std::fs::read(solo.join("gamedata/maps/0004832.map")).unwrap();
        let k = 40 + 8 + (4 * 16 + 3) * 2;
        assert_eq!(u16::from_le_bytes([m[k], m[k + 1]]), 5, "the server knows the new area");
        assert_eq!(std::fs::read(solo.join("forge-dev/maps-orig/0004832.map")).unwrap(), stock);
        let did = remove(&p, Some(&game_dir), Some(&ov)).unwrap();
        assert!(did.iter().any(|d| d.contains("ground")), "{did:?}");
        assert_eq!(std::fs::read(solo.join("gamedata/maps/0004832.map")).unwrap(), stock, "put back byte for byte");
    }

    #[test]
    fn placed_models_get_collision_in_the_test_realm_and_back() {
        let dir = tempfile::tempdir().unwrap();
        let game_dir = dir.path().join("ov");
        let data_dir = game_dir.join("Data");
        std::fs::create_dir_all(&data_dir).unwrap();
        let at = crate::data::Dbc { fields: 4, records: vec![vec![12, 0, 0, 1]], strings: vec![0] };
        wow_mpq::ArchiveBuilder::new()
            .add_file_data(at.write(), "DBFilesClient\\AreaTable.dbc")
            .add_file_data(crate::adt::tests::fake_tile(32, 48, 20.0), "World\\Maps\\Azeroth\\Azeroth_32_48.adt")
            .add_file_data(crate::vmap::box_m2(), "World\\Generic\\ForgeTest\\Crate.m2")
            .build(data_dir.join("dbc.MPQ"))
            .unwrap();
        std::fs::write(game_dir.join("play_local.py"), "").unwrap();
        let real = game_dir.join("solo");
        std::fs::create_dir_all(real.join("bin")).unwrap();
        crate::vmap::stock_vmaps(&real.join("gamedata/vmaps"));
        let stock: Vec<(String, Vec<u8>)> = std::fs::read_dir(real.join("gamedata/vmaps")).unwrap().flatten().map(|e| (e.file_name().to_string_lossy().to_string(), std::fs::read(e.path()).unwrap())).collect();
        std::fs::write(real.join("state.json"), "{}").unwrap();
        let ov = openvanilla_dir(None, Some(&game_dir)).unwrap();
        crate::testbed::override_dirs(Some(dir.path().join("test-game")), Some(dir.path().join("test-solo")));
        let p = create(dir.path().join("p"), "Crate Pack", "Orion", Template::Pack).unwrap();
        let game = GameData::open(&game_dir).unwrap();
        let pl = crate::world::Placement { model: "World\\Generic\\ForgeTest\\Crate.mdx".into(), x: -8800.0, y: -250.0, z: 20.0, turn: 30.0, scale: 3.0, uid: 0, wmo_box: None, tilt: [0.0; 2], set: 0 };
        crate::world::place(&p, Some(&game), "Azeroth", pl, false).unwrap();
        let r = install(&p, &game, Some(&ov)).unwrap();
        let mut got = r.server_vmaps.clone();
        got.sort();
        assert_eq!(got, vec!["000.vmtree", "000_32_48.vmtile", "Crate.m2.vmo"], "{:?}", r.notes);
        let solo = dir.path().join("test-solo");
        let v = solo.join("gamedata/vmaps");
        let tile = crate::vmap::parse_tile(&std::fs::read(v.join("000_32_48.vmtile")).unwrap()).unwrap();
        assert_eq!(tile.len(), 1);
        let (crate_spawn, idx) = &tile[0];
        assert_eq!((crate_spawn.name.as_str(), *idx), ("Crate.m2", 1), "after the realm's one spawn");
        assert!((crate_spawn.scale - 3.0).abs() < 1e-6);
        let b = crate_spawn.bound.unwrap();
        // the server's coordinates: x = mid - world x, y = mid - world y
        let mid = 533.33333f32 * 32.0;
        assert!(b.0[0] < mid + 8800.0 && mid + 8800.0 < b.1[0] && b.0[1] < mid + 250.0 && mid + 250.0 < b.1[1], "{b:?}");
        assert!((b.1[2] - b.0[2] - 3.0).abs() < 0.01, "three yards tall: {b:?}");
        let tree = crate::vmap::Tree::parse(&std::fs::read(v.join("000.vmtree")).unwrap()).unwrap();
        assert_eq!(tree.bih.objects.len(), 2);
        assert_eq!(std::fs::read(v.join("000_31_48.vmtile")).unwrap(), stock.iter().find(|s| s.0 == "000_31_48.vmtile").unwrap().1, "untouched tiles stay as they are");
        for (name, bytes) in &stock {
            assert_eq!(&std::fs::read(real.join("gamedata/vmaps").join(name)).unwrap(), bytes, "the real realm's {name} isn't written");
        }
        assert!(!real.join("gamedata/vmaps/Crate.m2.vmo").exists());
        assert!(r.notes.iter().any(|n| n.contains("collision")), "{:?}", r.notes);
        // installing again starts from the originals: still one crate
        let r = install(&p, &game, Some(&ov)).unwrap();
        assert_eq!(crate::vmap::Tree::parse(&std::fs::read(v.join("000.vmtree")).unwrap()).unwrap().bih.objects.len(), 2, "{:?}", r.notes);
        let did = remove(&p, Some(&game_dir), Some(&ov)).unwrap();
        assert!(did.iter().any(|d| d.contains("collision")), "{did:?}");
        for (name, bytes) in &stock {
            assert_eq!(&std::fs::read(v.join(name)).unwrap(), bytes, "{name} put back byte for byte");
        }
        assert!(!v.join("Crate.m2.vmo").exists(), "the crate's mesh goes with it");
    }

    #[test]
    fn the_test_realm_only_starts_with_the_test_copy() {
        let dir = tempfile::tempdir().unwrap();
        let ov = dir.path().join("ov");
        std::fs::create_dir_all(&ov).unwrap();
        let game = dir.path().join("Game");
        std::fs::create_dir_all(game.join("Data")).unwrap();
        std::fs::write(game.join("Data/base.MPQ"), b"x").unwrap();
        let (tg, ts) = (dir.path().join("test-game"), dir.path().join("test-solo"));
        crate::testbed::override_dirs(Some(tg.clone()), Some(ts.clone()));
        std::fs::create_dir_all(&ts).unwrap();
        std::fs::write(ts.join("state.json"), "{}").unwrap();
        let py = vec!["definitely-not-python".to_string()];
        let e = play_solo(&ov, &py, None).unwrap_err().to_string();
        assert!(e.contains("game folder"), "{e}");
        let e = play_solo(&ov, &py, Some(&game)).unwrap_err().to_string();
        assert!(e.contains("test copy"), "never the creator's own game: {e}");
        // with the copy it gets as far as starting (and pins the copy to this PC first)
        crate::testbed::sync_client(&game).unwrap();
        std::fs::write(tg.join("realmlist.wtf"), "set realmlist play.openvanilla.app").unwrap();
        let e = play_solo(&ov, &py, Some(&game)).unwrap_err().to_string();
        assert!(e.contains("couldn't start Play Solo"), "{e}");
        assert_eq!(std::fs::read_to_string(tg.join("realmlist.wtf")).unwrap().trim(), crate::testbed::TEST_REALMLIST);
    }
}
