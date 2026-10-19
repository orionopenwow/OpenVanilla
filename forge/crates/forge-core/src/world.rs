//! The World layer (plan §4.4, Phase 3): doodads a pack places on the game's own maps.
//!
//! A pack never ships the game's terrain tiles. It keeps its placements as data:
//!
//! ```toml
//! # maps/Azeroth/placements.toml
//! [[doodad]]
//! model = "model:Lantern"          # one of the pack's doodad models, or a game path (World\...\X.mdx)
//! x = -9464.8                      # world (server, .gps) coordinates
//! y = 62.1
//! z = 56.7
//! turn = 90.0                      # degrees around the up axis
//! scale = 1.0
//! uid = 40261000                   # from the pack's range, set when placed
//! ```
//!
//! A dev build reads each touched tile from the creator's own game, adds the doodads (adt.rs) and
//! puts the tile in the test patch. A release build ships the placements as JSON
//! (`data/world/<Map>.json`), and the realm build adds them to the realm's own tiles.

use crate::adt::{self, Adt, Doodad};
use crate::check::Finding;
use crate::ids::IdLock;
use crate::project::Project;
use crate::vfs::GameData;
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::PathBuf;

/// Map IDs (what `.gps` prints) → the map's folder under World\Maps.
pub const MAPS: &[(u32, &str)] = &[
    (0, "Azeroth"),
    (1, "Kalimdor"),
    (13, "Test"),
    (25, "ScottTest"),
    (29, "CashTest"),
    (30, "PVPZone01"),
    (33, "Shadowfang"),
    (34, "StormwindJail"),
    (35, "StormwindPrison"),
    (36, "DeadminesInstance"),
    (37, "PVPZone02"),
    (42, "Collin"),
    (43, "WailingCaverns"),
    (44, "Monastery"),
    (47, "RazorfenKraulInstance"),
    (48, "Blackfathom"),
    (70, "Uldaman"),
    (90, "GnomeragonInstance"),
    (109, "SunkenTemple"),
    (129, "RazorfenDowns"),
    (169, "EmeraldDream"),
    (189, "MonasteryInstances"),
    (209, "TanarisInstance"),
    (229, "BlackRockSpire"),
    (230, "BlackrockDepths"),
    (249, "OnyxiaLairInstance"),
    (269, "CavernsOfTime"),
    (289, "SchoolofNecromancy"),
    (309, "Zul'gurub"),
    (329, "Stratholme"),
    (349, "Mauradon"),
    (369, "DeeprunTram"),
    (389, "OrgrimmarInstance"),
    (409, "MoltenCore"),
    (429, "DireMaul"),
    (449, "AlliancePVPBarracks"),
    (450, "HordePVPBarracks"),
    (451, "development"),
    (469, "BlackwingLair"),
    (489, "PVPZone03"),
    (509, "AhnQiraj"),
    (529, "PVPZone04"),
    (531, "AhnQirajTemple"),
    (533, "Stratholme Raid"),
];

pub fn map_name(id: u32) -> Option<&'static str> {
    MAPS.iter().find(|(i, _)| *i == id).map(|x| x.1)
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Placement {
    pub model: String,
    pub x: f64,
    pub y: f64,
    pub z: f64,
    #[serde(default)]
    pub turn: f64,
    #[serde(default = "one")]
    pub scale: f64,
    #[serde(default)]
    pub uid: u32,
    /// A building's (WMO's) bounding box in its own coordinates, read from the game when it's
    /// placed. None for doodads.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wmo_box: Option<[f32; 6]>,
    /// Leaning: degrees about the model's own two level axes (the game's rotation x and z).
    #[serde(default, skip_serializing_if = "is_level")]
    pub tilt: [f64; 2],
    /// A building's furniture: which of its doodad sets it shows (0, the default, always shows).
    #[serde(default, skip_serializing_if = "is_zero")]
    pub set: u16,
}

fn is_zero(n: &u16) -> bool {
    *n == 0
}

fn is_level(t: &[f64; 2]) -> bool {
    t[0] == 0.0 && t[1] == 0.0
}

pub fn is_wmo(model: &str) -> bool {
    model.to_ascii_lowercase().ends_with(".wmo")
}

fn one() -> f64 {
    1.0
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct PlacementsFile {
    #[serde(default)]
    doodad: Vec<Placement>,
}

fn maps_dir(p: &Project) -> PathBuf {
    p.root.join("maps")
}

/// Every map the pack places things on: map folder → placements.
pub fn load(p: &Project) -> Result<BTreeMap<String, Vec<Placement>>> {
    let mut out = BTreeMap::new();
    let Ok(rd) = std::fs::read_dir(maps_dir(p)) else { return Ok(out) };
    for e in rd.filter_map(|e| e.ok()) {
        let f = e.path().join("placements.toml");
        if f.is_file() {
            let pf: PlacementsFile = toml::from_str(&std::fs::read_to_string(&f)?).with_context(|| format!("{} isn't valid", f.display()))?;
            out.insert(e.file_name().to_string_lossy().to_string(), pf.doodad);
        }
    }
    Ok(out)
}

pub fn save_placements(p: &Project, map: &str, list: &[Placement]) -> Result<()> {
    save(p, map, list)
}

fn save(p: &Project, map: &str, list: &[Placement]) -> Result<()> {
    let dir = maps_dir(p).join(map);
    std::fs::create_dir_all(&dir)?;
    let mut s = format!("# Doodads this pack places on {map} (world coordinates, as .gps prints them). Edited by Forge's World screen.\n");
    s.push_str(&toml::to_string_pretty(&PlacementsFile { doodad: list.to_vec() })?);
    std::fs::write(dir.join("placements.toml"), s)?;
    Ok(())
}

/// A placement's model as the tile names it: a pack model (`model:Name`) becomes its game path.
pub fn model_path(p: &Project, model: &str) -> Result<String> {
    match model.strip_prefix("model:") {
        Some(name) => {
            let rep = crate::model::report(p, name).with_context(|| format!("model {name} isn't ported yet"))?;
            if rep["doodad"].is_null() {
                bail!("model {name} is a {}, not a doodad: set its kind to doodad and port it again", crate::model::load_spec(p, name).map(|s| s.kind).unwrap_or_default());
            }
            Ok(rep["meta"]["model_path"].as_str().unwrap_or("").to_string())
        }
        None => {
            let m = model.replace('/', "\\");
            Ok(if m.to_ascii_lowercase().ends_with(".m2") { format!("{}.mdx", &m[..m.len() - 3]) } else { m })
        }
    }
}

/// Place a doodad: a uid from the pack's range, and z from the ground when not given.
pub fn place(p: &Project, game: Option<&GameData>, map: &str, mut pl: Placement, ground: bool) -> Result<Placement> {
    model_path(p, &pl.model)?;
    if is_wmo(&pl.model) {
        let g = game.context("placing a building needs your game folder (Forge reads its size)")?;
        let root = read_world(p, g, &pl.model.replace('/', "\\")).with_context(|| format!("{} isn't in your game", pl.model))?;
        pl.wmo_box = Some(adt::wmo_bounds(&root)?);
        pl.scale = 1.0; // 1.12 buildings don't scale
    }
    let (a, b) = adt::tile_of(pl.x, pl.y);
    if ground {
        let g = game.context("snapping to the ground needs your game folder")?;
        // the ground as the pack has shaped it
        let (tile, _) = current_tile(p, g, map, a, b).with_context(|| format!("{map} has no tile {a}_{b} there"))?;
        let f = adt::to_file(pl.x, pl.y, 0.0);
        // (on a tile's very edge, rounding mustn't step off it)
        let inside = |v: f64, t: i32| v.clamp(t as f64 * adt::TILE + 0.01, (t + 1) as f64 * adt::TILE - 0.01);
        pl.z = tile.height_at((a, b), inside(f[0] as f64, a), inside(f[2] as f64, b)).context("no ground there")?;
    }
    if pl.uid == 0 {
        let mut lock = IdLock::load(&p.root)?;
        pl.uid = lock.allocate(&p.manifest.pack.id, "MDDF", &pl.model)?;
        lock.save(&p.root)?;
    }
    let mut all = load(p)?;
    let list = all.entry(map.to_string()).or_default();
    list.retain(|x| x.uid != pl.uid);
    list.push(pl.clone());
    save(p, map, list)?;
    Ok(pl)
}

/// One placement's new spot (fields left out stay).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Move {
    pub uid: u32,
    #[serde(default)]
    pub x: Option<f64>,
    #[serde(default)]
    pub y: Option<f64>,
    #[serde(default)]
    pub z: Option<f64>,
    #[serde(default)]
    pub turn: Option<f64>,
    #[serde(default)]
    pub scale: Option<f64>,
    /// Lean (degrees about the model's two level axes).
    #[serde(default)]
    pub tilt: Option<[f64; 2]>,
    #[serde(default)]
    pub set: Option<u16>,
}

/// Move many placements at once (a selection dragged together): one save.
pub fn move_many(p: &Project, map: &str, moves: &[Move]) -> Result<Vec<Placement>> {
    let mut all = load(p)?;
    let list = all.get_mut(map).with_context(|| format!("the pack places nothing on {map}"))?;
    let mut out = vec![];
    for m in moves {
        let pl = list.iter_mut().find(|x| x.uid == m.uid).with_context(|| format!("no placement {} on {map}", m.uid))?;
        if let Some(v) = m.x { pl.x = v; }
        if let Some(v) = m.y { pl.y = v; }
        if let Some(v) = m.z { pl.z = v; }
        if let Some(v) = m.turn { pl.turn = v.rem_euclid(360.0); }
        if let Some(t) = m.tilt { pl.tilt = [t[0].clamp(-89.0, 89.0), t[1].clamp(-89.0, 89.0)]; }
        if let Some(v) = m.set { pl.set = v; }
        if let Some(v) = m.scale {
            if !is_wmo(&pl.model) {
                pl.scale = v.clamp(0.05, 50.0);
            }
        }
        out.push(pl.clone());
    }
    let list = list.clone();
    save(p, map, &list)?;
    Ok(out)
}

/// Place many (a paste): each gets its own uid, and the ground under it when `ground`.
pub fn place_many(p: &Project, game: Option<&GameData>, map: &str, list: Vec<Placement>, ground: bool) -> Result<Vec<Placement>> {
    list.into_iter().map(|pl| place(p, game, map, Placement { uid: 0, ..pl }, ground)).collect()
}

/// Remove many placements (a selection deleted).
pub fn remove_many(p: &Project, map: &str, uids: &[u32]) -> Result<usize> {
    let mut all = load(p)?;
    let Some(list) = all.get_mut(map) else { return Ok(0) };
    let before = list.len();
    list.retain(|x| !uids.contains(&x.uid));
    let n = before - list.len();
    let list = list.clone();
    save(p, map, &list)?;
    Ok(n)
}

/// Move, turn or size one of the pack's placements (any field left out stays). A building keeps
/// its size (the game doesn't scale them).
pub fn move_placement(p: &Project, map: &str, uid: u32, x: Option<f64>, y: Option<f64>, z: Option<f64>, turn: Option<f64>, scale: Option<f64>) -> Result<Placement> {
    let mut all = load(p)?;
    let list = all.get_mut(map).with_context(|| format!("the pack places nothing on {map}"))?;
    let pl = list.iter_mut().find(|x| x.uid == uid).with_context(|| format!("no placement {uid} on {map}"))?;
    if let Some(v) = x { pl.x = v; }
    if let Some(v) = y { pl.y = v; }
    if let Some(v) = z { pl.z = v; }
    if let Some(v) = turn { pl.turn = v.rem_euclid(360.0); }
    if let Some(v) = scale {
        if !is_wmo(&pl.model) {
            pl.scale = v.clamp(0.05, 50.0);
        }
    }
    let out = pl.clone();
    let list = list.clone();
    save(p, map, &list)?;
    Ok(out)
}

pub fn remove(p: &Project, map: &str, uid: u32) -> Result<()> {
    let mut all = load(p)?;
    let list = all.get_mut(map).context("no placements on that map")?;
    let before = list.len();
    list.retain(|x| x.uid != uid);
    if list.len() == before {
        bail!("no doodad {uid} on {map}");
    }
    save(p, map, list)
}

fn to_doodad(p: &Project, pl: &Placement) -> Result<Doodad> {
    Ok(Doodad {
        model: model_path(p, &pl.model)?,
        uid: pl.uid,
        pos: adt::to_file(pl.x, pl.y, pl.z),
        rot: [pl.tilt[0] as f32, pl.turn as f32, pl.tilt[1] as f32],
        scale: (pl.scale * 1024.0).round().clamp(1.0, 65535.0) as u16,
        flags: 0,
        extents: pl.wmo_box.map(|b| adt::wmo_extents(b, adt::to_file(pl.x, pl.y, pl.z), pl.turn as f32)),
        set: pl.set,
    })
}

// ---------------------------------------------------------------- terrain

/// A tile's height edits: 256 map chunks × 145 vertices of height change (0 = untouched), kept in
/// `maps/<Map>/terrain/<A>_<B>.hd` (zlib-compressed little-endian f32).
pub type Delta = Vec<f32>;
pub const DELTA_LEN: usize = 256 * 145;

fn delta_path(p: &Project, map: &str, a: i32, b: i32) -> PathBuf {
    maps_dir(p).join(map).join("terrain").join(format!("{a}_{b}.hd"))
}

pub fn decode_delta(bytes: &[u8]) -> Result<Delta> {
    use std::io::Read;
    let mut raw = vec![];
    flate2::read::ZlibDecoder::new(bytes).read_to_end(&mut raw)?;
    if raw.len() != DELTA_LEN * 4 {
        bail!("a terrain delta holds {} values, not {DELTA_LEN}", raw.len() / 4);
    }
    Ok(raw.chunks_exact(4).map(|c| f32::from_le_bytes(c.try_into().unwrap())).collect())
}

pub fn encode_delta(d: &Delta) -> Vec<u8> {
    use std::io::Write;
    let mut e = flate2::write::ZlibEncoder::new(vec![], flate2::Compression::best());
    for v in d {
        e.write_all(&v.to_le_bytes()).unwrap();
    }
    e.finish().unwrap()
}

pub fn load_delta(p: &Project, map: &str, a: i32, b: i32) -> Result<Option<Delta>> {
    match std::fs::read(delta_path(p, map, a, b)) {
        Ok(bytes) => Ok(Some(decode_delta(&bytes)?)),
        Err(_) => Ok(None),
    }
}

pub fn save_delta_pub(p: &Project, map: &str, a: i32, b: i32, d: &Delta) -> Result<()> {
    save_delta(p, map, a, b, d)
}

fn save_delta(p: &Project, map: &str, a: i32, b: i32, d: &Delta) -> Result<()> {
    let f = delta_path(p, map, a, b);
    if d.iter().all(|v| *v == 0.0) {
        let _ = std::fs::remove_file(&f);
        return Ok(());
    }
    std::fs::create_dir_all(f.parent().unwrap())?;
    std::fs::write(f, encode_delta(d))?;
    Ok(())
}

/// Every tile the pack reshapes: (map, a, b).
pub fn terrain_tiles(p: &Project) -> Vec<(String, i32, i32)> {
    let mut out = vec![];
    for m in std::fs::read_dir(maps_dir(p)).into_iter().flatten().filter_map(|e| e.ok()) {
        let Ok(t) = std::fs::read_dir(m.path().join("terrain")) else { continue };
        for f in t.filter_map(|e| e.ok()) {
            let n = f.file_name().to_string_lossy().to_string();
            if let Some((a, b)) = n.strip_suffix(".hd").or_else(|| n.strip_suffix(".chunks.json")).or_else(|| n.strip_suffix(".hidden.json")).and_then(|x| x.split_once('_')) {
                if let (Ok(a), Ok(b)) = (a.parse(), b.parse()) {
                    out.push((m.file_name().to_string_lossy().to_string(), a, b));
                }
            }
        }
    }
    // tiles the pack ships itself (a new map's): files/World/Maps/<Map>/<Map>_A_B.adt
    for m in std::fs::read_dir(p.root.join("files/World/Maps")).into_iter().flatten().filter_map(|e| e.ok()) {
        let map = m.file_name().to_string_lossy().to_string();
        let Ok(t) = std::fs::read_dir(m.path()) else { continue };
        for f in t.filter_map(|e| e.ok()) {
            let n = f.file_name().to_string_lossy().to_string();
            let Some(stem) = n.strip_suffix(".adt").and_then(|x| x.strip_prefix(&format!("{map}_"))) else { continue };
            if let Some((a, b)) = stem.split_once('_') {
                if let (Ok(a), Ok(b)) = (a.parse(), b.parse()) {
                    out.push((map.clone(), a, b));
                }
            }
        }
    }
    out.sort();
    out.dedup();
    out
}

/// Where the pack's world is: the first tile it changes, else the first thing it places.
pub fn start_tile(p: &Project) -> Option<(String, i32, i32)> {
    terrain_tiles(p).into_iter().next().or_else(|| {
        load(p).ok().and_then(|all| all.into_iter().find_map(|(m, l)| l.first().map(|pl| { let (a, b) = adt::tile_of(pl.x, pl.y); (m.clone(), a, b) })))
    })
}

/// A tile's edit files (heights, chunks), for cache keys: changes when the tile is edited.
pub fn tile_edit_bytes(p: &Project, map: &str, a: i32, b: i32) -> Vec<u8> {
    let mut out = vec![];
    for f in [delta_path(p, map, a, b), chunks_path(p, map, a, b), p.root.join(format!("files/World/Maps/{map}/{map}_{a}_{b}.adt"))] {
        if let Ok(bytes) = std::fs::read(f) {
            out.extend_from_slice(&bytes);
        }
    }
    out
}

/// A game file as the pack sees it: the pack's own copy (files/…) first, then the game's.
pub fn read_world(p: &Project, g: &GameData, path: &str) -> Result<Vec<u8>> {
    let own = p.root.join("files").join(path.replace('\\', "/"));
    if own.is_file() {
        return Ok(std::fs::read(own)?);
    }
    g.read(path)
}

/// Art for True View: the pack's own files, then its ported models' files (`models/*/.port/game`,
/// `.mdx` names read as `.m2`), then the game's.
pub fn read_art(p: &Project, g: Option<&GameData>, path: &str) -> Result<Vec<u8>> {
    let rel = path.replace('\\', "/");
    let own = p.root.join("files").join(&rel);
    if own.is_file() {
        return Ok(std::fs::read(own)?);
    }
    if let Ok(rd) = std::fs::read_dir(crate::model::models_dir(p)) {
        for e in rd.flatten() {
            let f = e.path().join(".port").join("game").join(&rel);
            if f.is_file() {
                return Ok(std::fs::read(f)?);
            }
        }
    }
    match g {
        Some(g) => g.read(path),
        None => bail!("{path} isn't in the pack, and Forge doesn't know where your game is"),
    }
}

/// The tile's ground for the 3D view to paint itself (see [`crate::trueview::splat`]).
pub fn splat(p: &Project, g: &GameData, map: &str, a: i32, b: i32) -> Result<Value> {
    let (t, _) = current_tile(p, g, map, a, b)?;
    crate::trueview::splat(&t, &|path| read_world(p, g, path), 256)
}

/// The tile's ground painted with its real textures (PNG, base64). `shade` for the 2D map.
pub fn true_ground_png(p: &Project, g: &GameData, map: &str, a: i32, b: i32, size: u32, shade: bool) -> Result<String> {
    let (t, _) = current_tile(p, g, map, a, b)?;
    let img = crate::trueview::ground(&t, &|path| read_world(p, g, path), size.clamp(256, 2048), shade);
    crate::trueview::png_b64(&img)
}

pub fn has_world(p: &Project, g: &GameData, path: &str) -> bool {
    p.root.join("files").join(path.replace('\\', "/")).is_file() || g.contains(path)
}

/// The maps a pack can work on: the game's, and the ones it adds (data/dbc/Map.toml).
pub fn maps(p: &Project) -> Vec<(u32, String)> {
    let mut out: Vec<(u32, String)> = MAPS.iter().map(|(i, n)| (*i, n.to_string())).collect();
    if let Ok(text) = std::fs::read_to_string(p.root.join("data/dbc/Map.toml")) {
        if let Ok(t) = text.parse::<toml::Table>() {
            for r in t.get("row").and_then(toml::Value::as_array).cloned().unwrap_or_default() {
                if let (Some(id), Some(dir)) = (r.get("ID").and_then(toml::Value::as_integer), r.get("Directory").and_then(toml::Value::as_str)) {
                    out.push((id as u32, dir.to_string()));
                }
            }
        }
    }
    out
}

pub fn map_id(p: &Project, map: &str) -> Option<u32> {
    maps(p).into_iter().find(|(_, n)| n.eq_ignore_ascii_case(map)).map(|x| x.0)
}

/// Apply a height delta to a tile (heights, then normals of the chunks that changed).
pub fn apply_delta(t: &mut Adt, tile: (i32, i32), d: &Delta) -> Result<()> {
    let layout = t.normal_layout(tile);
    let mut changed = vec![];
    for row in 0..16 {
        for col in 0..16 {
            let k0 = (row * 16 + col) * 145;
            if d[k0..k0 + 145].iter().all(|v| *v == 0.0) {
                continue;
            }
            let mut hs = t.chunk_heights(col, row).context("map chunk missing")?;
            for k in 0..145 {
                hs[k] += d[k0 + k];
            }
            t.set_chunk_heights(col, row, &hs)?;
            changed.push((col, row));
        }
    }
    // normals of the changed chunks and their neighbours (their edge slopes changed too)
    let mut redo: Vec<(usize, usize)> = vec![];
    for (c, r) in changed {
        for dc in -1i32..=1 {
            for dr in -1i32..=1 {
                let (cc, rr) = (c as i32 + dc, r as i32 + dr);
                if (0..16).contains(&cc) && (0..16).contains(&rr) && !redo.contains(&(cc as usize, rr as usize)) {
                    redo.push((cc as usize, rr as usize));
                }
            }
        }
    }
    for (c, r) in redo {
        t.recompute_normals(tile, c, r, layout)?;
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum Brush {
    Raise,
    Lower,
    Smooth,
    Flatten,
}

/// One brush stroke at world (x, y): reshapes every vertex within `radius` yards, on every tile
/// the circle touches. Returns the tiles changed.
/// How a brush fades from its middle to its edge: full strength inside `inner` (a fraction of the
/// radius), then down by the curve.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
pub struct Shape {
    #[serde(default)]
    pub falloff: Falloff,
    #[serde(default)]
    pub inner: f64,
    /// Spray (paint): only this share (0–1) of the ground under the brush takes it, in yard-wide
    /// specks; 0 paints everywhere.
    #[serde(default)]
    pub spray: f64,
    /// Which specks a spray stroke hits (a new number each stroke).
    #[serde(default)]
    pub seed: u32,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Falloff {
    Flat,
    Linear,
    #[default]
    Smooth,
    Quadratic,
    Trigonometric,
    Gaussian,
}

impl Shape {
    /// Whether the speck at file (x, z) takes the spray (always, without spray).
    pub fn speck(&self, x: f64, z: f64) -> bool {
        if self.spray <= 0.0 || self.spray >= 1.0 {
            return true;
        }
        let (cx, cz) = ((x / 1.2).floor() as i64, (z / 1.2).floor() as i64);
        let mut h = (cx as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ (cz as u64).wrapping_mul(0xC2B2_AE3D_27D4_EB4F) ^ (self.seed as u64).wrapping_mul(0x1656_67B1_9E37_79F9);
        h ^= h >> 31;
        h = h.wrapping_mul(0xD6E8_FEB8_6659_FD93);
        h ^= h >> 32;
        (h % 10_000) as f64 / 10_000.0 < self.spray
    }

    /// 0–1 at `dist` from the middle of a brush `radius` across.
    pub fn weight(&self, dist: f64, radius: f64) -> f64 {
        if dist >= radius {
            return 0.0;
        }
        let inner = self.inner.clamp(0.0, 0.99) * radius;
        if dist <= inner {
            return 1.0;
        }
        let u = ((dist - inner) / (radius - inner)).clamp(0.0, 1.0);
        match self.falloff {
            Falloff::Flat => 1.0,
            Falloff::Linear => 1.0 - u,
            Falloff::Smooth => 0.5 * (1.0 + (std::f64::consts::PI * u).cos()),
            Falloff::Quadratic => 1.0 - u * u,
            Falloff::Trigonometric => (u * std::f64::consts::FRAC_PI_2).cos(),
            Falloff::Gaussian => ((-u * u * 4.5).exp() - (-4.5f64).exp()) / (1.0 - (-4.5f64).exp()),
        }
    }
}

pub fn sculpt(p: &Project, g: &GameData, map: &str, x: f64, y: f64, radius: f64, strength: f64, brush: Brush) -> Result<Vec<(i32, i32)>> {
    sculpt_shaped(p, g, map, x, y, radius, strength, brush, Shape::default())
}

#[allow(clippy::too_many_arguments)]
pub fn sculpt_shaped(p: &Project, g: &GameData, map: &str, x: f64, y: f64, radius: f64, strength: f64, brush: Brush, shape: Shape) -> Result<Vec<(i32, i32)>> {
    if !(1.0..=200.0).contains(&radius) {
        bail!("brush radius is 1 to 200 yards");
    }
    let c = adt::to_file(x, y, 0.0);
    let (cx, cz) = (c[0] as f64, c[2] as f64);
    let (a0, b0) = (((cx - radius) / adt::TILE).floor() as i32, ((cz - radius) / adt::TILE).floor() as i32);
    let (a1, b1) = (((cx + radius) / adt::TILE).floor() as i32, ((cz + radius) / adt::TILE).floor() as i32);
    // the current terrain under the brush: (tile, chunk index, vertex, distance, height)
    struct V {
        tile: (i32, i32),
        idx: usize,
        w: f64,
        h: f64,
    }
    let mut verts = vec![];
    let mut deltas: BTreeMap<(i32, i32), Delta> = BTreeMap::new();
    let mut centre_h = None;
    for a in a0..=a1 {
        for b in b0..=b1 {
            let Ok(bytes) = read_world(p, g, &adt::tile_path(map, a, b)) else { continue };
            let mut t = Adt::parse(&bytes)?;
            let d = load_delta(p, map, a, b)?.unwrap_or_else(|| vec![0.0; DELTA_LEN]);
            apply_delta(&mut t, (a, b), &d)?;
            if centre_h.is_none() && adt::tile_of(x, y) == (a, b) {
                centre_h = t.height_at((a, b), cx, cz);
            }
            for row in 0..16 {
                for col in 0..16 {
                    // skip chunks the circle can't reach
                    let (mx, mz) = (a as f64 * adt::TILE + (col as f64 + 0.5) * adt::CHUNK, b as f64 * adt::TILE + (row as f64 + 0.5) * adt::CHUNK);
                    if ((mx - cx).powi(2) + (mz - cz).powi(2)).sqrt() > radius + adt::CHUNK {
                        continue;
                    }
                    let hs = t.chunk_heights(col, row).context("map chunk missing")?;
                    for (k, hv) in hs.iter().enumerate() {
                        let (vx, vz) = adt::vertex_xz((a, b), col, row, k);
                        let dist = ((vx - cx).powi(2) + (vz - cz).powi(2)).sqrt();
                        if dist < radius {
                            let w = shape.weight(dist, radius);
                            verts.push(V { tile: (a, b), idx: (row * 16 + col) * 145 + k, w, h: *hv as f64 });
                        }
                    }
                }
            }
            deltas.insert((a, b), d);
        }
    }
    if verts.is_empty() {
        bail!("no terrain under the brush");
    }
    let mean = {
        let sw: f64 = verts.iter().map(|v| v.w).sum();
        verts.iter().map(|v| v.h * v.w).sum::<f64>() / sw
    };
    let target = centre_h.unwrap_or(mean);
    for v in &verts {
        let change = match brush {
            Brush::Raise => strength * v.w,
            Brush::Lower => -strength * v.w,
            Brush::Smooth => (mean - v.h) * (strength.clamp(0.0, 1.0) * v.w),
            Brush::Flatten => (target - v.h) * (strength.clamp(0.0, 1.0) * v.w),
        };
        if let Some(d) = deltas.get_mut(&v.tile) {
            d[v.idx] += change as f32;
        }
    }
    // a vertex on a chunk or tile edge exists twice: keep both copies equal (no cracks)
    let mut touched = vec![];
    for ((a, b), d) in &deltas {
        save_delta(p, map, *a, *b, d)?;
        touched.push((*a, *b));
    }
    Ok(touched)
}

/// The tiles whose models the server's collision (vmaps) must follow: where the pack places
/// doodads or buildings, or hides the game's, by map.
pub fn collision_tiles(p: &Project) -> Result<BTreeMap<String, std::collections::BTreeSet<(i32, i32)>>> {
    let mut out: BTreeMap<String, std::collections::BTreeSet<(i32, i32)>> = BTreeMap::new();
    for (map, list) in load(p)? {
        if !list.is_empty() {
            out.entry(map.clone()).or_default().extend(by_tile(p, &map, &list)?.into_keys());
        }
    }
    for (map, a, b) in terrain_tiles(p) {
        if !hidden(p, &map, a, b).is_empty() {
            out.entry(map).or_default().insert((a, b));
        }
    }
    Ok(out)
}

/// The placements as tile edits: tile path → doodads, for one map.
fn by_tile(p: &Project, map: &str, list: &[Placement]) -> Result<BTreeMap<(i32, i32), Vec<Doodad>>> {
    let mut out: BTreeMap<(i32, i32), Vec<Doodad>> = BTreeMap::new();
    for pl in list {
        let d = to_doodad(p, pl)?;
        match d.extents {
            // a building goes on every tile its box reaches
            Some(e) => {
                let t = |v: f32| (v as f64 / adt::TILE).floor() as i32;
                for a in t(e[0])..=t(e[3]) {
                    for b in t(e[2])..=t(e[5]) {
                        out.entry((a, b)).or_default().push(d.clone());
                    }
                }
            }
            None => out.entry(adt::tile_of(pl.x, pl.y)).or_default().push(d),
        }
    }
    let _ = map;
    Ok(out)
}

// ---------------------------------------------------------------- texture paint, holes, areas

/// One map chunk's edits: its area, its holes (4 × 4 bits), its texture layers (alpha maps as
/// base64 of 4096 bytes). Absent = as the game has it.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ChunkEdit {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub area: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub holes: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layers: Option<Vec<LayerData>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub water: Option<WaterData>,
    /// Impassable (the server keeps players off the chunk).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub impass: Option<bool>,
    /// The baked shadow cleared.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub noshadow: Option<bool>,
}

/// A chunk's water: `tiles` 64 bytes as hex (all 0F = no water), 81 vertex heights, and the
/// original vertex info and flow bytes (base64) when the chunk had water before.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WaterData {
    pub kind: String,
    pub heights: Vec<f32>,
    pub tiles: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub info: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub flow: Option<String>,
}

impl WaterData {
    fn to_liquid(&self) -> Result<Option<adt::Liquid>> {
        use base64::Engine;
        let b64 = base64::engine::general_purpose::STANDARD;
        let tiles: Vec<u8> = (0..self.tiles.len() / 2).map(|i| u8::from_str_radix(&self.tiles[i * 2..i * 2 + 2], 16)).collect::<Result<_, _>>().context("water tiles are hex")?;
        let tiles: [u8; 64] = tiles.try_into().map_err(|_| anyhow::anyhow!("water has 64 tiles"))?;
        if tiles.iter().all(|t| t & 0x0F == 0x0F) {
            return Ok(None);
        }
        if self.heights.len() != 81 {
            bail!("water has 81 vertex heights");
        }
        let info = self.info.as_ref().map(|i| b64.decode(i)).transpose()?.filter(|i| i.len() == 324).unwrap_or_else(|| vec![0; 324]);
        let flow = self.flow.as_ref().map(|f| b64.decode(f)).transpose()?.filter(|f| f.len() == 84).unwrap_or_else(|| vec![0; 84]);
        Ok(Some(adt::Liquid {
            kind: adt::LiquidKind::parse(&self.kind)?,
            verts: self.heights.iter().enumerate().map(|(k, h)| (info[k * 4..k * 4 + 4].try_into().unwrap(), *h)).collect(),
            tiles,
            flow,
        }))
    }

    pub fn from_liquid_pub(l: &adt::Liquid) -> Self {
        Self::from_liquid(l)
    }

    fn from_liquid(l: &adt::Liquid) -> Self {
        use base64::Engine;
        let b64 = base64::engine::general_purpose::STANDARD;
        let info: Vec<u8> = l.verts.iter().flat_map(|v| v.0).collect();
        WaterData {
            kind: l.kind.name().into(),
            heights: l.verts.iter().map(|v| v.1).collect(),
            tiles: l.tiles.iter().map(|t| format!("{t:02x}")).collect(),
            info: info.iter().any(|&x| x != 0).then(|| b64.encode(&info)),
            flow: l.flow.iter().any(|&x| x != 0).then(|| b64.encode(&l.flow)),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LayerData {
    pub texture: String,
    #[serde(default)]
    pub flags: u32,
    #[serde(default)]
    pub effect: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub alpha: Option<String>,
}

/// "col_row" → edit.
pub type ChunkEdits = BTreeMap<String, ChunkEdit>;

/// A tile's edits: heights and chunk edits.
#[derive(Debug, Clone, Default)]
pub struct TileEdit {
    pub heights: Option<Delta>,
    pub chunks: ChunkEdits,
    /// The game's own doodads and buildings the pack hides (uids).
    pub hidden: Vec<u32>,
}

fn hidden_path(p: &Project, map: &str, a: i32, b: i32) -> PathBuf {
    maps_dir(p).join(map).join("terrain").join(format!("{a}_{b}.hidden.json"))
}

/// The uids of the game's doodads and buildings the pack hides on a tile.
pub fn hidden(p: &Project, map: &str, a: i32, b: i32) -> Vec<u32> {
    std::fs::read(hidden_path(p, map, a, b)).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

/// Hide the game's own doodads or buildings on a tile (or show them again). Returns the tile's
/// hidden list.
pub fn set_hidden(p: &Project, map: &str, a: i32, b: i32, uids: &[u32], hide: bool) -> Result<Vec<u32>> {
    let mut h = hidden(p, map, a, b);
    for u in uids {
        if hide && !h.contains(u) {
            h.push(*u);
        }
        if !hide {
            h.retain(|x| x != u);
        }
    }
    h.sort();
    let f = hidden_path(p, map, a, b);
    if h.is_empty() {
        let _ = std::fs::remove_file(&f);
    } else {
        std::fs::create_dir_all(f.parent().unwrap())?;
        std::fs::write(&f, serde_json::to_vec(&h)?)?;
    }
    Ok(h)
}

/// Hide (or show again) the game's own doodads and buildings on tile a_b by uid. A building is
/// hidden on every tile its box reaches (each tile's chunks name it). Returns how many tiles changed.
pub fn hide_game_objects(p: &Project, g: &GameData, map: &str, a: i32, b: i32, uids: &[u32], hide: bool) -> Result<usize> {
    let t = Adt::parse(&read_world(p, g, &adt::tile_path(map, a, b))?)?;
    let mut tiles: BTreeMap<(i32, i32), Vec<u32>> = BTreeMap::new();
    for d in t.doodads() {
        if uids.contains(&d.uid) {
            tiles.entry((a, b)).or_default().push(d.uid);
        }
    }
    for w in t.wmos() {
        if !uids.contains(&w.uid) {
            continue;
        }
        let e = w.extents.unwrap_or([w.pos[0], 0.0, w.pos[2], w.pos[0], 0.0, w.pos[2]]);
        let tl = |v: f32| (v as f64 / adt::TILE).floor() as i32;
        for ta in tl(e[0])..=tl(e[3]) {
            for tb in tl(e[2])..=tl(e[5]) {
                if has_world(p, g, &adt::tile_path(map, ta, tb)) {
                    tiles.entry((ta, tb)).or_default().push(w.uid);
                }
            }
        }
    }
    if tiles.is_empty() {
        bail!("none of those are the game's on tile {a}_{b}");
    }
    for ((ta, tb), us) in &tiles {
        set_hidden(p, map, *ta, *tb, us, hide)?;
    }
    Ok(tiles.len())
}

/// Pick up the game's own doodads or buildings: each becomes the pack's own placement, in the
/// same spot, turn, lean and size, and the game's copy is hidden. Returns the new placements.
pub fn pick_up(p: &Project, g: &GameData, map: &str, a: i32, b: i32, uids: &[u32]) -> Result<Vec<Placement>> {
    let t = Adt::parse(&read_world(p, g, &adt::tile_path(map, a, b))?)?;
    let mut out = vec![];
    let mut done = vec![];
    for d in t.doodads().into_iter().chain(t.wmos()) {
        if !uids.contains(&d.uid) || done.contains(&d.uid) {
            continue;
        }
        let pl = Placement {
            model: d.model.clone(),
            x: adt::HALF - d.pos[2] as f64,
            y: adt::HALF - d.pos[0] as f64,
            z: d.pos[1] as f64,
            turn: d.rot[1] as f64,
            scale: if d.extents.is_some() { 1.0 } else { d.scale as f64 / 1024.0 },
            uid: 0,
            wmo_box: None,
            tilt: [d.rot[0] as f64, d.rot[2] as f64],
            set: d.set,
        };
        out.push(place(p, Some(g), map, pl, false)?);
        done.push(d.uid);
    }
    if done.is_empty() {
        bail!("none of those are the game's on tile {a}_{b}");
    }
    hide_game_objects(p, g, map, a, b, &done, true)?;
    Ok(out)
}

fn chunks_path(p: &Project, map: &str, a: i32, b: i32) -> PathBuf {
    maps_dir(p).join(map).join("terrain").join(format!("{a}_{b}.chunks.json"))
}

pub fn load_chunks(p: &Project, map: &str, a: i32, b: i32) -> Result<ChunkEdits> {
    match std::fs::read(chunks_path(p, map, a, b)) {
        Ok(bytes) => Ok(serde_json::from_slice(&bytes)?),
        Err(_) => Ok(ChunkEdits::new()),
    }
}

pub fn save_chunks_pub(p: &Project, map: &str, a: i32, b: i32, e: &ChunkEdits) -> Result<()> {
    save_chunks(p, map, a, b, e)
}

pub fn from_layers_pub(ls: &[adt::Layer]) -> Vec<LayerData> {
    from_layers(ls)
}

fn save_chunks(p: &Project, map: &str, a: i32, b: i32, e: &ChunkEdits) -> Result<()> {
    let f = chunks_path(p, map, a, b);
    if e.is_empty() {
        let _ = std::fs::remove_file(&f);
        return Ok(());
    }
    std::fs::create_dir_all(f.parent().unwrap())?;
    std::fs::write(f, serde_json::to_vec(e)?)?;
    Ok(())
}

fn to_layers(ls: &[LayerData]) -> Result<Vec<adt::Layer>> {
    use base64::Engine;
    ls.iter()
        .map(|l| {
            Ok(adt::Layer {
                texture: l.texture.clone(),
                flags: l.flags,
                effect: l.effect,
                alpha: l.alpha.as_ref().map(|a| base64::engine::general_purpose::STANDARD.decode(a)).transpose()?,
            })
        })
        .collect()
}

fn from_layers(ls: &[adt::Layer]) -> Vec<LayerData> {
    use base64::Engine;
    ls.iter()
        .map(|l| LayerData { texture: l.texture.clone(), flags: l.flags, effect: l.effect, alpha: l.alpha.as_ref().map(|a| base64::engine::general_purpose::STANDARD.encode(a)) })
        .collect()
}

pub fn apply_chunks(t: &mut Adt, e: &ChunkEdits) -> Result<()> {
    for (k, c) in e {
        let (col, row) = k.split_once('_').and_then(|(a, b)| Some((a.parse::<usize>().ok()?, b.parse::<usize>().ok()?))).context("chunk key is col_row")?;
        if let Some(a) = c.area {
            t.set_area(col, row, a)?;
        }
        if let Some(h) = c.holes {
            t.set_holes(col, row, h)?;
        }
        if let Some(i) = c.impass {
            t.set_impass(col, row, i)?;
        }
        if c.noshadow == Some(true) {
            t.clear_shadow(col, row);
        }
        if let Some(ls) = &c.layers {
            t.set_layers(col, row, &to_layers(ls)?)?;
        }
        if let Some(w) = &c.water {
            t.set_liquid(col, row, w.to_liquid()?.as_ref())?;
        }
    }
    Ok(())
}

/// The tile as the pack has it now (heights and chunk edits applied), and its edits.
pub(crate) fn current_tile(p: &Project, g: &GameData, map: &str, a: i32, b: i32) -> Result<(Adt, ChunkEdits)> {
    let mut t = Adt::parse(&read_world(p, g, &adt::tile_path(map, a, b)).with_context(|| format!("{map} has no tile {a}_{b}"))?)?;
    if let Some(d) = load_delta(p, map, a, b)? {
        apply_delta(&mut t, (a, b), &d)?;
    }
    let e = load_chunks(p, map, a, b)?;
    apply_chunks(&mut t, &e)?;
    Ok((t, e))
}

/// Chunks (tile, col, row) whose square the circle touches.
pub fn chunks_under_pub(cx: f64, cz: f64, radius: f64) -> Vec<((i32, i32), usize, usize)> {
    chunks_under(cx, cz, radius)
}

fn chunks_under(cx: f64, cz: f64, radius: f64) -> Vec<((i32, i32), usize, usize)> {
    let mut out = vec![];
    let (x0, x1) = (((cx - radius) / adt::CHUNK).floor() as i64, ((cx + radius) / adt::CHUNK).floor() as i64);
    let (z0, z1) = (((cz - radius) / adt::CHUNK).floor() as i64, ((cz + radius) / adt::CHUNK).floor() as i64);
    for gx in x0..=x1 {
        for gz in z0..=z1 {
            out.push(((gx.div_euclid(16) as i32, gz.div_euclid(16) as i32), gx.rem_euclid(16) as usize, gz.rem_euclid(16) as usize));
        }
    }
    out
}

/// Paint `texture` at world (x, y): up to 4 layers per chunk (a new texture takes a free layer,
/// or replaces the faintest), alpha raised under the brush and the layers above it thinned.
pub fn paint(p: &Project, g: &GameData, map: &str, x: f64, y: f64, radius: f64, strength: f64, texture: &str) -> Result<Vec<String>> {
    paint_shaped(p, g, map, x, y, radius, strength, texture, Shape::default())
}

#[allow(clippy::too_many_arguments)]
pub fn paint_shaped(p: &Project, g: &GameData, map: &str, x: f64, y: f64, radius: f64, strength: f64, texture: &str, shape: Shape) -> Result<Vec<String>> {
    if !(1.0..=120.0).contains(&radius) {
        bail!("brush radius is 1 to 120 yards");
    }
    let c = adt::to_file(x, y, 0.0);
    let (cx, cz) = (c[0] as f64, c[2] as f64);
    let s = strength.clamp(0.01, 1.0);
    let chunks = chunks_under(cx, cz, radius);
    paint_with(p, g, map, &chunks, texture, &|vx, vz| {
        let dist = ((vx - cx).powi(2) + (vz - cz).powi(2)).sqrt();
        if shape.speck(vx, vz) { s * shape.weight(dist, radius) } else { 0.0 }
    })
}

/// Paint `texture` into the given map chunks by `amount(file x, file z)` (0–1 a pixel).
pub fn paint_with(p: &Project, g: &GameData, map: &str, chunks: &[((i32, i32), usize, usize)], texture: &str, amount: &dyn Fn(f64, f64) -> f64) -> Result<Vec<String>> {
    let tex = texture.replace('/', "\\");
    let mut by_tile: BTreeMap<(i32, i32), Vec<(usize, usize)>> = BTreeMap::new();
    for (t, col, row) in chunks {
        let v = by_tile.entry(*t).or_default();
        if !v.contains(&(*col, *row)) {
            v.push((*col, *row));
        }
    }
    let mut notes = vec![];
    for ((a, b), chunks) in by_tile {
        let Ok((t, mut edits)) = current_tile(p, g, map, a, b) else { continue };
        // a texture the tile already uses brings its own flags (flowing lava, turning water) and
        // ground effect (the grass and pebbles the game scatters on it); a new one draws plain
        let mut known: BTreeMap<String, (u32, u32)> = BTreeMap::new();
        for k in 0..256 {
            for (i, l) in t.layers(k % 16, k / 16).unwrap_or_default().into_iter().enumerate() {
                let e = known.entry(l.texture.to_ascii_lowercase()).or_insert((0x100, l.effect));
                if i > 0 {
                    *e = (l.flags | 0x100, l.effect);
                }
            }
        }
        let (flags_new, effect_new) = known.get(&tex.to_ascii_lowercase()).copied().unwrap_or((0x100, 0));
        for (col, row) in chunks {
            let mut ls = t.layers(col, row).context("map chunk missing")?;
            if ls.is_empty() {
                ls.push(adt::Layer { texture: tex.clone(), flags: 0, effect: effect_new, alpha: None });
            }
            let i = match ls.iter().position(|l| l.texture.eq_ignore_ascii_case(&tex)) {
                Some(i) => i,
                None => {
                    let fresh = adt::Layer { texture: tex.clone(), flags: flags_new, effect: effect_new, alpha: Some(vec![0; 4096]) };
                    if ls.len() < 4 {
                        ls.push(fresh);
                        ls.len() - 1
                    } else {
                        // the faintest layer above the base gives way
                        let k = (1..ls.len()).min_by_key(|&k| ls[k].alpha.as_ref().map(|a| a.iter().map(|&v| v as u64).sum::<u64>()).unwrap_or(0)).unwrap();
                        notes.push(format!("chunk {col},{row} of {a}_{b} had 4 textures: {} gave way", ls[k].texture.rsplit('\\').next().unwrap_or("")));
                        ls[k] = fresh;
                        k
                    }
                }
            };
            let (x0, z0) = (a as f64 * adt::TILE + col as f64 * adt::CHUNK, b as f64 * adt::TILE + row as f64 * adt::CHUNK);
            let px = adt::CHUNK / 64.0;
            for py in 0..64 {
                for pxi in 0..64 {
                    let (vx, vz) = (x0 + (pxi as f64 + 0.5) * px, z0 + (py as f64 + 0.5) * px);
                    let amt = amount(vx, vz).clamp(0.0, 1.0);
                    if amt <= 0.0 {
                        continue;
                    }
                    let k = py * 64 + pxi;
                    if i > 0 {
                        let a = ls[i].alpha.as_mut().unwrap();
                        a[k] = (a[k] as f64 + (255.0 - a[k] as f64) * amt).round().min(255.0) as u8;
                    }
                    for l in ls.iter_mut().skip(i + 1) {
                        if let Some(a) = l.alpha.as_mut() {
                            a[k] = (a[k] as f64 * (1.0 - amt)).round() as u8;
                        }
                    }
                }
            }
            edits.entry(format!("{col}_{row}")).or_default().layers = Some(from_layers(&ls));
        }
        save_chunks(p, map, a, b, &edits)?;
    }
    notes.dedup();
    Ok(notes)
}

/// Swap a texture on every tile of `map` the pack has (its own map's tiles, and the tiles it
/// changed on the game's maps). -> (tiles, chunks) changed.
pub fn swap_texture_pack(p: &Project, g: &GameData, map: &str, from: &str, to: &str) -> Result<(usize, usize)> {
    let (mut tiles, mut chunks) = (0, 0);
    for (m, a, b) in terrain_tiles(p) {
        if !m.eq_ignore_ascii_case(map) {
            continue;
        }
        let n = swap_texture(p, g, &m, a, b, from, to, None)?;
        if n > 0 {
            tiles += 1;
            chunks += n;
        }
    }
    Ok((tiles, chunks))
}

/// Swap one ground texture for another on a tile (every chunk, or only `only` chunks): where the
/// chunk has the new one already, the two layers become one. Returns how many chunks changed.
pub fn swap_texture(p: &Project, g: &GameData, map: &str, a: i32, b: i32, from: &str, to: &str, only: Option<&[(usize, usize)]>) -> Result<usize> {
    let (from, to) = (from.replace('/', "\\"), to.replace('/', "\\"));
    if from.eq_ignore_ascii_case(&to) {
        return Ok(0);
    }
    let (t, mut edits) = current_tile(p, g, map, a, b)?;
    let mut changed = 0;
    for row in 0..16 {
        for col in 0..16 {
            if only.is_some_and(|o| !o.contains(&(col, row))) {
                continue;
            }
            let mut ls = t.layers(col, row).unwrap_or_default();
            let Some(i) = ls.iter().position(|l| l.texture.eq_ignore_ascii_case(&from)) else { continue };
            match ls.iter().position(|l| l.texture.eq_ignore_ascii_case(&to)) {
                None => ls[i].texture = to.clone(),
                Some(j) => {
                    let (lo, hi) = (i.min(j), i.max(j));
                    // the upper layer's coverage folds into the lower one, which takes the new texture
                    if lo > 0 {
                        let up = ls[hi].alpha.clone().unwrap_or_else(|| vec![0; 4096]);
                        if let Some(al) = ls[lo].alpha.as_mut() {
                            for (x, u) in al.iter_mut().zip(up) {
                                *x = (*x).max(u);
                            }
                        }
                    }
                    ls[lo].texture = to.clone();
                    ls.remove(hi);
                }
            }
            edits.entry(format!("{col}_{row}")).or_default().layers = Some(from_layers(&ls));
            changed += 1;
        }
    }
    if changed > 0 {
        save_chunks(p, map, a, b, &edits)?;
    }
    Ok(changed)
}

/// Take a texture off a tile: where it's painted over others it goes and they show; where it's
/// the base, the next layer becomes the base (over the whole chunk). A chunk with only that
/// texture keeps it. Returns the chunks changed.
pub fn remove_texture(p: &Project, g: &GameData, map: &str, a: i32, b: i32, texture: &str) -> Result<usize> {
    let texture = texture.replace('/', "\\");
    let (t, mut edits) = current_tile(p, g, map, a, b)?;
    let mut changed = 0;
    for row in 0..16 {
        for col in 0..16 {
            let mut ls = t.layers(col, row).unwrap_or_default();
            let Some(i) = ls.iter().position(|l| l.texture.eq_ignore_ascii_case(&texture)) else { continue };
            if ls.len() < 2 {
                continue;
            }
            ls.remove(i);
            if i == 0 {
                ls[0].alpha = None;
                ls[0].flags &= !0x100;
            }
            edits.entry(format!("{col}_{row}")).or_default().layers = Some(from_layers(&ls));
            changed += 1;
        }
    }
    if changed > 0 {
        save_chunks(p, map, a, b, &edits)?;
    }
    Ok(changed)
}

/// Clear the baked shadows (MCSH) of a tile's chunks: all of them, or those under a circle.
/// Returns the chunks that had a shadow.
pub fn clear_shadows(p: &Project, g: &GameData, map: &str, a: i32, b: i32, at: Option<(f64, f64, f64)>) -> Result<usize> {
    let (t, mut edits) = current_tile(p, g, map, a, b)?;
    let mut n = 0;
    let keep: Option<Vec<(usize, usize)>> = at.map(|(x, y, r)| {
        let c = adt::to_file(x, y, 0.0);
        chunks_under(c[0] as f64, c[2] as f64, r).into_iter().filter(|(tt, _, _)| *tt == (a, b)).map(|(_, c, r)| (c, r)).collect()
    });
    for row in 0..16 {
        for col in 0..16 {
            if keep.as_ref().is_some_and(|k| !k.contains(&(col, row))) || t.shadow(col, row) == 0.0 {
                continue;
            }
            edits.entry(format!("{col}_{row}")).or_default().noshadow = Some(true);
            n += 1;
        }
    }
    if n > 0 {
        save_chunks(p, map, a, b, &edits)?;
    }
    Ok(n)
}

/// Make (or fill) the hole under world (x, y): one of a chunk's 4 × 4 hole squares.
pub fn set_hole(p: &Project, g: &GameData, map: &str, x: f64, y: f64, hole: bool) -> Result<()> {
    let c = adt::to_file(x, y, 0.0);
    let (a, b) = adt::tile_of(x, y);
    let (t, mut edits) = current_tile(p, g, map, a, b)?;
    let (col, row) = adt::chunk_of((a, b), c).context("not on the tile")?;
    let fx = c[0] as f64 - (a as f64 * adt::TILE + col as f64 * adt::CHUNK);
    let fz = c[2] as f64 - (b as f64 * adt::TILE + row as f64 * adt::CHUNK);
    let (hx, hz) = (((fx / adt::CHUNK) * 4.0).floor().clamp(0.0, 3.0) as u32, ((fz / adt::CHUNK) * 4.0).floor().clamp(0.0, 3.0) as u32);
    let bit = 1u32 << (hz * 4 + hx);
    let cur = t.holes(col, row);
    let new = if hole { cur | bit } else { cur & !bit };
    edits.entry(format!("{col}_{row}")).or_default().holes = Some(new);
    save_chunks(p, map, a, b, &edits)
}

/// Water under the brush: the 8 × 8 water tiles of each chunk whose centre is inside the circle
/// get `kind` water with its surface at `level` (a chunk's water is level across it, the way the
/// game's lakes are), or lose their water with `erase`. Returns the tiles changed.
pub fn water(p: &Project, g: &GameData, map: &str, x: f64, y: f64, radius: f64, level: f64, kind: &str, erase: bool) -> Result<usize> {
    if !(1.0..=120.0).contains(&radius) {
        bail!("brush radius is 1 to 120 yards");
    }
    let kind = adt::LiquidKind::parse(kind)?;
    let c = adt::to_file(x, y, 0.0);
    let (cx, cz) = (c[0] as f64, c[2] as f64);
    let mut by_tile: BTreeMap<(i32, i32), Vec<(usize, usize)>> = BTreeMap::new();
    for (t, col, row) in chunks_under(cx, cz, radius) {
        by_tile.entry(t).or_default().push((col, row));
    }
    let mut changed = 0;
    let wt = adt::CHUNK / 8.0;
    for ((a, b), chunks) in by_tile {
        let Ok((t, mut edits)) = current_tile(p, g, map, a, b) else { continue };
        for (col, row) in chunks {
            let cur = t.liquid(col, row);
            if erase && cur.is_none() {
                continue;
            }
            let ground = t.chunk_heights(col, row).context("map chunk missing")?;
            let mut l = match cur {
                Some(l) if l.kind == kind || erase => l,
                Some(l) => {
                    // another kind of water here: it becomes this kind
                    let mut n = adt::Liquid::flat(kind, level as f32);
                    for k in 0..64 {
                        if l.shown(k) {
                            n.tiles[k] = kind.tile_type() | (l.tiles[k] & 0xC0);
                        }
                    }
                    n
                }
                None => adt::Liquid::flat(kind, level as f32),
            };
            if !erase {
                for v in l.verts.iter_mut() {
                    v.1 = level as f32;
                }
            }
            let (x0, z0) = (a as f64 * adt::TILE + col as f64 * adt::CHUNK, b as f64 * adt::TILE + row as f64 * adt::CHUNK);
            let mut n = 0;
            for ty in 0..8 {
                for tx in 0..8 {
                    let (vx, vz) = (x0 + (tx as f64 + 0.5) * wt, z0 + (ty as f64 + 0.5) * wt);
                    if (vx - cx).hypot(vz - cz) > radius {
                        continue;
                    }
                    let k = ty * 8 + tx;
                    let g4 = [ty * 17 + tx, ty * 17 + tx + 1, (ty + 1) * 17 + tx, (ty + 1) * 17 + tx + 1].map(|i| ground[i] as f64);
                    let new = if erase || level <= g4.iter().cloned().fold(f64::MAX, f64::min) {
                        // drained, or ground all above the surface here: no water tile (the game
                        // marks water only where some of it is under the surface)
                        0x0F
                    } else {
                        // deep enough to swim where the ground is 2 yards or more under the surface
                        // (the game's own water: shallow tiles to about 1.5, swimming from about 2.3)
                        let deep = level - g4.iter().sum::<f64>() / 4.0 >= 2.0;
                        kind.tile_type() | if deep { 0x40 } else { 0 }
                    };
                    if l.tiles[k] != new {
                        l.tiles[k] = new;
                        n += 1;
                    }
                }
            }
            if n > 0 || !erase {
                changed += n;
                edits.entry(format!("{col}_{row}")).or_default().water = Some(WaterData::from_liquid(&l));
            }
        }
        save_chunks(p, map, a, b, &edits)?;
    }
    Ok(changed)
}

/// A water tile's type from its four corners: none where the ground is above the surface at
/// every corner, swimming depth where the ground is 2 yards or more under it on average.
fn water_tile(kind: adt::LiquidKind, surf: [f64; 4], ground: [f64; 4]) -> u8 {
    if (0..4).all(|i| ground[i] >= surf[i]) {
        0x0F
    } else {
        let deep = (0..4).map(|i| surf[i] - ground[i]).sum::<f64>() / 4.0 >= 2.0;
        kind.tile_type() | if deep { 0x40 } else { 0 }
    }
}

/// Angled water: a strip `width` yards across from one point to another (world x, y, surface
/// height z), its surface sloping between them: rivers that run downhill, falls and rapids.
pub fn water_slope(p: &Project, g: &GameData, map: &str, from: [f64; 3], to: [f64; 3], width: f64, kind: &str) -> Result<usize> {
    if !(2.0..=200.0).contains(&width) {
        bail!("angled water is 2 to 200 yards wide");
    }
    let kind = adt::LiquidKind::parse(kind)?;
    let (a, b) = (adt::to_file(from[0], from[1], 0.0), adt::to_file(to[0], to[1], 0.0));
    let (ax, az, bx, bz) = (a[0] as f64, a[2] as f64, b[0] as f64, b[2] as f64);
    let len2 = (bx - ax).powi(2) + (bz - az).powi(2);
    if len2 < 1.0 {
        bail!("angled water needs two different points");
    }
    let half = width / 2.0;
    let along = |x: f64, z: f64| -> (f64, f64) {
        let t = (((x - ax) * (bx - ax) + (z - az) * (bz - az)) / len2).clamp(0.0, 1.0);
        let d = (x - (ax + (bx - ax) * t)).hypot(z - (az + (bz - az) * t));
        (from[2] + (to[2] - from[2]) * t, d)
    };
    let (mx, mz) = ((ax + bx) / 2.0, (az + bz) / 2.0);
    let reach = len2.sqrt() / 2.0 + half + adt::CHUNK;
    let mut by_tile: BTreeMap<(i32, i32), Vec<(usize, usize)>> = BTreeMap::new();
    for (t, col, row) in chunks_under(mx, mz, reach) {
        by_tile.entry(t).or_default().push((col, row));
    }
    let wt = adt::CHUNK / 8.0;
    let mut changed = 0;
    for ((ta, tb), chunks) in by_tile {
        let Ok((t, mut edits)) = current_tile(p, g, map, ta, tb) else { continue };
        let mut any = false;
        for (col, row) in chunks {
            let (x0, z0) = (ta as f64 * adt::TILE + col as f64 * adt::CHUNK, tb as f64 * adt::TILE + row as f64 * adt::CHUNK);
            let inside: Vec<usize> = (0..64).filter(|k| along(x0 + (k % 8) as f64 * wt + wt / 2.0, z0 + (k / 8) as f64 * wt + wt / 2.0).1 <= half).collect();
            if inside.is_empty() {
                continue;
            }
            let ground = t.chunk_heights(col, row).context("map chunk missing")?;
            let fresh = |kind| {
                let mut l = adt::Liquid::flat(kind, 0.0);
                for (k, v) in l.verts.iter_mut().enumerate() {
                    v.1 = along(x0 + (k % 9) as f64 * wt, z0 + (k / 9) as f64 * wt).0 as f32;
                }
                l
            };
            let mut l = match t.liquid(col, row) {
                Some(l) if l.kind == kind => l,
                Some(old) => {
                    let mut n = fresh(kind);
                    for k in 0..64 {
                        if old.shown(k) {
                            n.tiles[k] = kind.tile_type() | (old.tiles[k] & 0xC0);
                        }
                    }
                    n
                }
                None => fresh(kind),
            };
            // the strip's vertices take its slope (a corner of a tile in the strip counts)
            for (k, v) in l.verts.iter_mut().enumerate() {
                let (h, d) = along(x0 + (k % 9) as f64 * wt, z0 + (k / 9) as f64 * wt);
                if d <= half + wt * std::f64::consts::SQRT_2 {
                    v.1 = h as f32;
                }
            }
            for k in inside {
                let (tx, ty) = (k % 8, k / 8);
                let vi = [ty * 9 + tx, ty * 9 + tx + 1, (ty + 1) * 9 + tx, (ty + 1) * 9 + tx + 1];
                let gi = [ty * 17 + tx, ty * 17 + tx + 1, (ty + 1) * 17 + tx, (ty + 1) * 17 + tx + 1];
                let new = water_tile(kind, vi.map(|i| l.verts[i].1 as f64), gi.map(|i| ground[i] as f64));
                if l.tiles[k] != new {
                    l.tiles[k] = new;
                    changed += 1;
                }
            }
            edits.entry(format!("{col}_{row}")).or_default().water = Some(WaterData::from_liquid(&l));
            any = true;
        }
        if any {
            save_chunks(p, map, ta, tb, &edits)?;
        }
    }
    Ok(changed)
}

/// Crop water to the ground under the brush: tiles where the ground stands above the surface at
/// every corner lose their water, and the depth marks follow the ground. Returns tiles changed.
pub fn water_crop(p: &Project, g: &GameData, map: &str, x: f64, y: f64, radius: f64) -> Result<usize> {
    if !(1.0..=400.0).contains(&radius) {
        bail!("crop radius is 1 to 400 yards");
    }
    let c = adt::to_file(x, y, 0.0);
    let (cx, cz) = (c[0] as f64, c[2] as f64);
    let mut by_tile: BTreeMap<(i32, i32), Vec<(usize, usize)>> = BTreeMap::new();
    for (t, col, row) in chunks_under(cx, cz, radius) {
        by_tile.entry(t).or_default().push((col, row));
    }
    let wt = adt::CHUNK / 8.0;
    let mut changed = 0;
    for ((ta, tb), chunks) in by_tile {
        let Ok((t, mut edits)) = current_tile(p, g, map, ta, tb) else { continue };
        let mut any = false;
        for (col, row) in chunks {
            let Some(mut l) = t.liquid(col, row) else { continue };
            let ground = t.chunk_heights(col, row).context("map chunk missing")?;
            let (x0, z0) = (ta as f64 * adt::TILE + col as f64 * adt::CHUNK, tb as f64 * adt::TILE + row as f64 * adt::CHUNK);
            let mut n = 0;
            for k in 0..64 {
                let (tx, ty) = (k % 8, k / 8);
                if !l.shown(k) || (x0 + (tx as f64 + 0.5) * wt - cx).hypot(z0 + (ty as f64 + 0.5) * wt - cz) > radius {
                    continue;
                }
                let vi = [ty * 9 + tx, ty * 9 + tx + 1, (ty + 1) * 9 + tx, (ty + 1) * 9 + tx + 1];
                let gi = [ty * 17 + tx, ty * 17 + tx + 1, (ty + 1) * 17 + tx, (ty + 1) * 17 + tx + 1];
                let new = water_tile(l.kind, vi.map(|i| l.verts[i].1 as f64), gi.map(|i| ground[i] as f64));
                if l.tiles[k] != new {
                    l.tiles[k] = new;
                    n += 1;
                }
            }
            if n > 0 {
                changed += n;
                edits.entry(format!("{col}_{row}")).or_default().water = Some(WaterData::from_liquid(&l));
                any = true;
            }
        }
        if any {
            save_chunks(p, map, ta, tb, &edits)?;
        }
    }
    Ok(changed)
}

/// Paint an area (AreaTable ID: the zone name, music and rules) on the chunks under the brush.
pub fn paint_area(p: &Project, g: &GameData, map: &str, x: f64, y: f64, radius: f64, area: u32) -> Result<usize> {
    let c = adt::to_file(x, y, 0.0);
    let (cx, cz) = (c[0] as f64, c[2] as f64);
    let mut by_tile: BTreeMap<(i32, i32), Vec<(usize, usize)>> = BTreeMap::new();
    for (t, col, row) in chunks_under(cx, cz, radius) {
        let (mx, mz) = (t.0 as f64 * adt::TILE + (col as f64 + 0.5) * adt::CHUNK, t.1 as f64 * adt::TILE + (row as f64 + 0.5) * adt::CHUNK);
        let inside = (cx - mx).abs() <= adt::CHUNK / 2.0 + 1e-6 && (cz - mz).abs() <= adt::CHUNK / 2.0 + 1e-6;
        if inside || ((mx - cx).powi(2) + (mz - cz).powi(2)).sqrt() <= radius {
            by_tile.entry(t).or_default().push((col, row));
        }
    }
    let mut n = 0;
    for ((a, b), chunks) in by_tile {
        let Ok(mut edits) = load_chunks(p, map, a, b) else { continue };
        if !has_world(p, g, &adt::tile_path(map, a, b)) {
            continue;
        }
        for (col, row) in chunks {
            edits.entry(format!("{col}_{row}")).or_default().area = Some(area);
            n += 1;
        }
        save_chunks(p, map, a, b, &edits)?;
    }
    Ok(n)
}

/// Mark the chunks under the brush impassable (or passable again).
pub fn paint_impass(p: &Project, g: &GameData, map: &str, x: f64, y: f64, radius: f64, on: bool) -> Result<usize> {
    let c = adt::to_file(x, y, 0.0);
    let (cx, cz) = (c[0] as f64, c[2] as f64);
    let mut by_tile: BTreeMap<(i32, i32), Vec<(usize, usize)>> = BTreeMap::new();
    for (t, col, row) in chunks_under(cx, cz, radius) {
        let (mx, mz) = (t.0 as f64 * adt::TILE + (col as f64 + 0.5) * adt::CHUNK, t.1 as f64 * adt::TILE + (row as f64 + 0.5) * adt::CHUNK);
        let inside = (cx - mx).abs() <= adt::CHUNK / 2.0 + 1e-6 && (cz - mz).abs() <= adt::CHUNK / 2.0 + 1e-6;
        if inside || ((mx - cx).powi(2) + (mz - cz).powi(2)).sqrt() <= radius {
            by_tile.entry(t).or_default().push((col, row));
        }
    }
    let mut n = 0;
    for ((a, b), chunks) in by_tile {
        if !has_world(p, g, &adt::tile_path(map, a, b)) {
            continue;
        }
        let mut edits = load_chunks(p, map, a, b)?;
        for (col, row) in chunks {
            edits.entry(format!("{col}_{row}")).or_default().impass = Some(on);
            n += 1;
        }
        save_chunks(p, map, a, b, &edits)?;
    }
    Ok(n)
}

// ---------------------------------------------------------------- new maps

#[derive(Debug, Clone, Deserialize)]
pub struct NewMap {
    pub name: String,
    /// world (shared, like a small continent), dungeon (5) or raid (40)
    #[serde(default = "default_kind")]
    pub kind: String,
    /// tiles across (1–4): a square of them around tile 32_32
    #[serde(default = "one_i")]
    pub size: i32,
    #[serde(default)]
    pub height: f32,
    #[serde(default = "default_ground")]
    pub texture: String,
    #[serde(default = "one_i")]
    pub min_level: i32,
    #[serde(default = "sixty")]
    pub max_level: i32,
}
fn default_kind() -> String {
    "world".into()
}
fn one_i() -> i32 {
    1
}
fn sixty() -> i32 {
    60
}
fn default_ground() -> String {
    "Tileset\\Elwynn\\ElwynnGrassBase.blp".into()
}

/// The folder name a map gets: its name's letters and digits, CamelCase.
pub fn map_directory(name: &str) -> String {
    name.split(|c: char| !c.is_ascii_alphanumeric()).filter(|w| !w.is_empty()).map(|w| {
        let mut c = w.chars();
        c.next().map(|f| f.to_ascii_uppercase().to_string() + c.as_str()).unwrap_or_default()
    }).collect()
}

/// Areas by name (or the given IDs), the game's and the pack's: id, name, parent, level, own.
pub fn areas(p: &Project, g: &GameData, q: &str, ids: &[u32], limit: usize) -> Result<Vec<Value>> {
    let stock = crate::data::read_stock(g, "AreaTable")?;
    let d = crate::data::load(p);
    let own_rows = d.dbc.get("AreaTable").map(|r| r.rows.clone()).unwrap_or_default();
    let own: Vec<u32> = own_rows.iter().filter_map(|r| r.get("ID").and_then(toml::Value::as_integer)).map(|x| x as u32).collect();
    let all = if own_rows.is_empty() { stock } else { crate::data::merge("AreaTable", &stock, &own_rows)? };
    let ql = q.trim().to_ascii_lowercase();
    let mut out = vec![];
    for r in &all.records {
        // ID, ContinentID, ParentAreaID, AreaBit, Flags, …, ExplorationLevel (10), AreaName_lang (11)
        let name = all.string(r[11]);
        let hit = if !ids.is_empty() { ids.contains(&r[0]) } else { !ql.is_empty() && name.to_ascii_lowercase().contains(&ql) };
        if hit {
            out.push(json!({"id": r[0], "name": name, "map": r[1], "parent": r[2], "level": r[10], "own": own.contains(&r[0])}));
            if out.len() >= limit {
                break;
            }
        }
    }
    Ok(out)
}

/// An area's settings, as the Area editor changes them (fields left out stay).
#[derive(Debug, Clone, Default, Deserialize)]
pub struct AreaEdit {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub level: Option<u32>,
    #[serde(default)]
    pub parent: Option<u32>,
    #[serde(default)]
    pub music: Option<u32>,
    #[serde(default)]
    pub ambience: Option<u32>,
    #[serde(default)]
    pub flags: Option<u32>,
    /// FactionGroupMask: 0 contested, 2 Alliance, 4 Horde, 6 both.
    #[serde(default)]
    pub faction: Option<u32>,
}

/// Change an area: the pack's own row, or an override of the game's.
pub fn area_save(p: &Project, g: &GameData, id: u32, e: &AreaEdit) -> Result<()> {
    use toml::Value as T;
    let mut f: Vec<(&str, T)> = vec![];
    if let Some(n) = &e.name {
        if n.trim().is_empty() {
            bail!("an area needs a name");
        }
        f.push(("AreaName_lang", T::String(n.trim().to_string())));
    }
    if let Some(v) = e.level { f.push(("ExplorationLevel", T::Integer(v as i64))); }
    if let Some(v) = e.parent {
        if v == id {
            bail!("an area can't be inside itself");
        }
        f.push(("ParentAreaID", T::Integer(v as i64)));
    }
    if let Some(v) = e.music { f.push(("ZoneMusic", T::Integer(v as i64))); }
    if let Some(v) = e.ambience { f.push(("AmbienceID", T::Integer(v as i64))); }
    if let Some(v) = e.flags { f.push(("Flags", T::Integer(v as i64))); }
    if let Some(v) = e.faction { f.push(("FactionGroupMask", T::Integer(v as i64))); }
    crate::light::upsert(p, g, "AreaTable", id, f)
}

/// One area's settings (the game's merged with the pack's).
pub fn area_get(p: &Project, g: &GameData, id: u32) -> Result<Value> {
    let stock = crate::data::read_stock(g, "AreaTable")?;
    let own_rows = crate::data::load(p).dbc.get("AreaTable").map(|r| r.rows.clone()).unwrap_or_default();
    let all = if own_rows.is_empty() { stock } else { crate::data::merge("AreaTable", &stock, &own_rows)? };
    let r = all.records.get(all.find(id).with_context(|| format!("no area {id}"))?).context("no area")?;
    Ok(json!({"id": r[0], "map": r[1], "parent": r[2], "flags": r[4], "ambience": r[7], "music": r[8], "level": r[10], "name": all.string(r[11]), "faction": r[20],
              "own": own_rows.iter().any(|x| x.get("ID").and_then(toml::Value::as_integer) == Some(id as i64))}))
}

/// A new area (a subzone, or a zone of its own) on `map`: an AreaTable row with its own
/// exploration bit. Inside a `parent` area it takes the parent's music, sounds and rules (a clone),
/// with its own name and level. Returns its ID, for the Area brush.
pub fn new_area(p: &Project, map: &str, name: &str, parent: u32, level: u32) -> Result<u32> {
    let name = name.trim();
    if name.is_empty() {
        bail!("give the area a name");
    }
    let continent = map_id(p, map).with_context(|| format!("unknown map {map}"))?;
    let mut lock = IdLock::load(&p.root)?;
    let pack = p.manifest.pack.id.clone();
    let id = lock.allocate(&pack, "AreaTable", name)?;
    let bit = lock.allocate(&pack, "AreaBit", name)?;
    lock.save(&p.root)?;
    let d = crate::data::load(p);
    let mut areas = d.dbc.get("AreaTable").map(|r| r.rows.clone()).unwrap_or_default();
    use toml::Value as T;
    let mut row: toml::Table = [
        ("ID", T::Integer(id as i64)),
        ("comment", T::String(format!("area: {name}"))),
        ("ContinentID", T::Integer(continent as i64)),
        ("ParentAreaID", T::Integer(parent as i64)),
        ("AreaBit", T::Integer(bit as i64)),
        ("ExplorationLevel", T::Integer(level as i64)),
        ("AreaName_lang", T::String(name.to_string())),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v))
    .collect();
    if parent > 0 {
        row.insert("clone".into(), T::Integer(parent as i64));
    }
    areas.push(row);
    crate::data::save_rows(p, "dbc", "AreaTable", &areas)?;
    Ok(id)
}

/// A new map: its Map and AreaTable rows (IDs from the pack's ranges), flat tiles and a WDT in
/// files/World/Maps/<Dir>/, the instance row for a dungeon or raid, and a `.tele` spot in the
/// middle. Everything the World screen does then works on it.
pub fn new_map(p: &Project, g: &GameData, spec: &NewMap) -> Result<Value> {
    let dir = map_directory(&spec.name);
    if dir.len() < 3 {
        bail!("give the map a name of at least three letters");
    }
    if maps(p).iter().any(|(_, n)| n.eq_ignore_ascii_case(&dir)) || g.contains(&format!("World\\Maps\\{dir}\\{dir}.wdt")) {
        bail!("there's already a map called {dir}");
    }
    if !(1..=4).contains(&spec.size) {
        bail!("a new map is 1 to 4 tiles across");
    }
    let (itype, players, donor) = match spec.kind.as_str() {
        "world" => (0, 0, 1),
        "dungeon" => (1, 5, 33),
        "raid" => (2, 40, 409),
        k => bail!("{k}: a map is world, dungeon or raid"),
    };
    if !g.contains(&spec.texture) {
        bail!("{} isn't in your game: pick a ground texture it has", spec.texture);
    }
    let mut lock = IdLock::load(&p.root)?;
    let pack = p.manifest.pack.id.clone();
    let id = lock.allocate(&pack, "Map", &spec.name)?;
    let area = lock.allocate(&pack, "AreaTable", &spec.name)?;
    let bit = lock.allocate(&pack, "AreaBit", &spec.name)?;
    let tele = lock.allocate(&pack, "game_tele", &spec.name)?;
    lock.save(&p.root)?;

    // tiles around the middle of the world grid
    let lo = 32 - (spec.size - 1) / 2;
    let tiles: Vec<(i32, i32)> = (lo..lo + spec.size).flat_map(|a| (lo..lo + spec.size).map(move |b| (a, b))).collect();
    let folder = p.root.join("files/World/Maps").join(&dir);
    std::fs::create_dir_all(&folder)?;
    for &(a, b) in &tiles {
        std::fs::write(folder.join(format!("{dir}_{a}_{b}.adt")), adt::new_tile(a, b, spec.height, &spec.texture, area))?;
    }
    std::fs::write(folder.join(format!("{dir}.wdt")), adt::new_wdt(&tiles))?;

    let d = crate::data::load(p);
    let rows_of = |kind: &str, t: &str| -> Vec<toml::Table> {
        let m = if kind == "world" { &d.world } else { &d.dbc };
        m.get(t).map(|r| r.rows.clone()).unwrap_or_default()
    };
    let tbl = |pairs: Vec<(&str, toml::Value)>| -> toml::Table { pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect() };
    use toml::Value as T;
    let mut maps_rows = rows_of("dbc", "Map");
    // the donor (Kalimdor, Shadowfang Keep, Molten Core) gives the fields Forge doesn't set: the loading screen
    maps_rows.push(tbl(vec![
        ("ID", T::Integer(id as i64)),
        ("clone", T::Integer(donor)),
        ("comment", T::String(format!("new map: {}", spec.name))),
        ("Directory", T::String(dir.clone())),
        ("InstanceType", T::Integer(itype)),
        ("MapType", T::Integer(0)),
        ("MapName_lang", T::String(spec.name.clone())),
        ("MinLevel", T::Integer(spec.min_level as i64)),
        ("MaxLevel", T::Integer(spec.max_level as i64)),
        ("MaxPlayers", T::Integer(players)),
        ("ParentMapID", T::Integer(area as i64)),
    ]));
    crate::data::save_rows(p, "dbc", "Map", &maps_rows)?;
    let mut areas = rows_of("dbc", "AreaTable");
    areas.push(tbl(vec![
        ("ID", T::Integer(area as i64)),
        ("comment", T::String(format!("{}: the whole map", spec.name))),
        ("ContinentID", T::Integer(id as i64)),
        ("AreaBit", T::Integer(bit as i64)),
        ("ExplorationLevel", T::Integer(spec.min_level as i64)),
        ("AreaName_lang", T::String(spec.name.clone())),
    ]));
    crate::data::save_rows(p, "dbc", "AreaTable", &areas)?;
    if itype > 0 {
        let mut inst = rows_of("world", "instance_template");
        inst.push(tbl(vec![
            ("map", T::Integer(id as i64)),
            ("levelMin", T::Integer(spec.min_level as i64)),
            ("levelMax", T::Integer(spec.max_level as i64)),
            ("maxPlayers", T::Integer(players)),
            ("reset_delay", T::Integer(if itype == 2 { 7 } else { 0 })),
        ]));
        crate::data::save_rows(p, "world", "instance_template", &inst)?;
    }
    // the middle of the map, on the ground
    let (ma, mb) = tiles[tiles.len() / 2];
    let (fx, fz) = (ma as f64 * adt::TILE + 20.0, mb as f64 * adt::TILE + 20.0);
    let (x, y) = (adt::HALF - fz, adt::HALF - fx);
    let z = spec.height as f64 + 1.0;
    let mut teles = rows_of("world", "game_tele");
    teles.push(tbl(vec![
        ("id", T::Integer(tele as i64)),
        ("position_x", T::Float(x)),
        ("position_y", T::Float(y)),
        ("position_z", T::Float(z)),
        ("orientation", T::Float(0.0)),
        ("map", T::Integer(id as i64)),
        ("name", T::String(dir.clone())),
    ]));
    crate::data::save_rows(p, "world", "game_tele", &teles)?;
    Ok(json!({
        "map": dir, "id": id, "area": area, "tiles": tiles,
        "tele": format!(".tele {dir}"), "go": format!(".go xyz {x:.1} {y:.1} {z:.1} {id}"),
    }))
}

/// A picture of its own on a pack map's loading screen: the image squeezed to 1024 × 1024 (the
/// game stretches it over the screen, so a 4:3 picture comes back 4:3) into
/// art/Interface/Glues/LoadingScreens/, a LoadingScreens row, and the Map row pointed at it.
pub fn set_loading_screen(p: &Project, map: &str, image_bytes: &[u8]) -> Result<Value> {
    let mut rows = dbc_rows(p, "dbc", "Map");
    let k = rows
        .iter()
        .position(|r| r.get("Directory").and_then(toml::Value::as_str).is_some_and(|d| d.eq_ignore_ascii_case(map)))
        .with_context(|| format!("{map} isn't one of this pack's maps"))?;
    let img = image::load_from_memory(image_bytes).context("that isn't a picture Forge can read (PNG or TGA)")?;
    let img = img.resize_exact(1024, 1024, image::imageops::FilterType::Lanczos3).to_rgba8();
    let dir = rows[k]["Directory"].as_str().unwrap_or(map).to_string();
    let rel = format!("Interface/Glues/LoadingScreens/Forge_{dir}");
    let png = p.root.join("art").join(format!("{rel}.png"));
    std::fs::create_dir_all(png.parent().unwrap())?;
    // opaque: a loading screen has no see-through parts (and DXT1 is half the size)
    let mut img = img;
    for px in img.pixels_mut() {
        px[3] = 255;
    }
    img.save(&png)?;
    use toml::Value as T;
    let mut screens = dbc_rows(p, "dbc", "LoadingScreens");
    let existing = rows[k].get("LoadingScreenID").and_then(T::as_integer).filter(|id| screens.iter().any(|r| r.get("ID").and_then(T::as_integer) == Some(*id)));
    let id = match existing {
        Some(id) => id,
        None => {
            let mut lock = IdLock::load(&p.root)?;
            let id = lock.allocate(&p.manifest.pack.id, "LoadingScreens", &dir)? as i64;
            lock.save(&p.root)?;
            screens.push(toml::Table::from_iter([
                ("ID".to_string(), T::Integer(id)),
                ("Name".to_string(), T::String(dir.clone())),
                ("FileName".to_string(), T::String(format!("{}.blp", rel.replace('/', "\\")))),
            ]));
            crate::data::save_rows(p, "dbc", "LoadingScreens", &screens)?;
            id
        }
    };
    rows[k].insert("LoadingScreenID".into(), T::Integer(id));
    crate::data::save_rows(p, "dbc", "Map", &rows)?;
    Ok(json!({"id": id, "art": format!("art/{rel}.png")}))
}

/// The maps this pack adds (their folder names).
pub fn own_maps(p: &Project) -> Vec<String> {
    dbc_rows(p, "dbc", "Map").iter().filter_map(|r| r.get("Directory").and_then(toml::Value::as_str).map(str::to_string)).collect()
}

// ---------------------------------------------------------------- undo

const UNDO_DIR: &str = ".forge/undo";
const UNDO_STEPS: usize = 30;
/// What a World edit can change: terrain and placements, the data rows (spawns, portals, maps,
/// areas), and the pack's own tiles.
const UNDO_PARTS: &[&str] = &["maps", "data", "files/World/Maps", "art/Interface/Glues/LoadingScreens", ".forge/ids.lock"];

fn copy_tree(from: &std::path::Path, to: &std::path::Path) -> Result<()> {
    if from.is_file() {
        std::fs::create_dir_all(to.parent().unwrap())?;
        std::fs::copy(from, to)?;
        return Ok(());
    }
    for e in walkdir::WalkDir::new(from).into_iter().filter_map(|e| e.ok()).filter(|e| e.file_type().is_file()) {
        let dst = to.join(e.path().strip_prefix(from)?);
        std::fs::create_dir_all(dst.parent().unwrap())?;
        std::fs::copy(e.path(), dst)?;
    }
    Ok(())
}

fn undo_steps(p: &Project) -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = std::fs::read_dir(p.root.join(UNDO_DIR)).into_iter().flatten().filter_map(|e| e.ok()).map(|e| e.path()).filter(|x| x.is_dir()).collect();
    v.sort();
    v
}

const REDO_DIR: &str = ".forge/redo";

fn redo_steps(p: &Project) -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = std::fs::read_dir(p.root.join(REDO_DIR)).into_iter().flatten().filter_map(|e| e.ok()).map(|e| e.path()).filter(|x| x.is_dir()).collect();
    v.sort();
    v
}

/// Copy the pack's world (the parts undo covers) into `dir`, with what the step was.
fn snapshot(p: &Project, dir: &std::path::Path, what: &str) -> Result<()> {
    for part in UNDO_PARTS {
        let src = p.root.join(part);
        if src.exists() {
            copy_tree(&src, &dir.join(part))?;
        }
    }
    std::fs::create_dir_all(dir)?;
    std::fs::write(dir.join("what.txt"), what)?;
    Ok(())
}

/// Put the pack's world back as `dir` has it.
fn restore(p: &Project, dir: &std::path::Path) -> Result<()> {
    for part in UNDO_PARTS {
        let live = p.root.join(part);
        if live.is_dir() {
            std::fs::remove_dir_all(&live)?;
        } else if live.is_file() {
            std::fs::remove_file(&live)?;
        }
        let saved = dir.join(part);
        if saved.exists() {
            copy_tree(&saved, &live)?;
        }
    }
    Ok(())
}

fn step_what(dir: &std::path::Path) -> String {
    std::fs::read_to_string(dir.join("what.txt"))
        .ok()
        .unwrap_or_else(|| dir.file_name().and_then(|n| n.to_str()).and_then(|n| n.split_once('-')).map(|x| x.1.to_string()).unwrap_or_default())
}

fn next_dir(p: &Project, root: &str, steps: &[PathBuf], what: &str) -> PathBuf {
    let n = steps.last().and_then(|x| x.file_name()?.to_str()?.split('-').next()?.parse::<u64>().ok()).map(|n| n + 1).unwrap_or(1);
    p.root.join(root).join(format!("{n:08}-{}", what.chars().filter(|c| c.is_ascii_alphanumeric()).take(20).collect::<String>()))
}

/// Remember the pack's world as it is now, before an edit (a stroke, a click): `undo` goes back
/// to the newest of these. Keeps the last 30. A new edit forgets what could be redone.
pub fn checkpoint(p: &Project, what: &str) -> Result<usize> {
    let _ = std::fs::remove_dir_all(p.root.join(REDO_DIR));
    push_undo(p, what)
}

fn push_undo(p: &Project, what: &str) -> Result<usize> {
    let steps = undo_steps(p);
    snapshot(p, &next_dir(p, UNDO_DIR, &steps, what), what)?;
    for old in steps.iter().rev().skip(UNDO_STEPS - 1) {
        let _ = std::fs::remove_dir_all(old);
    }
    Ok(undo_steps(p).len())
}

/// Go back to the last checkpoint (what's undone can be redone). -> what that edit was, and how
/// many steps are left.
pub fn undo(p: &Project) -> Result<Value> {
    let step = undo_steps(p).pop().context("nothing to undo")?;
    let what = step_what(&step);
    let redo = redo_steps(p);
    snapshot(p, &next_dir(p, REDO_DIR, &redo, &what), &what)?;
    restore(p, &step)?;
    std::fs::remove_dir_all(&step)?;
    Ok(json!({"undone": what, "left": undo_steps(p).len(), "redo": redo_steps(p).len()}))
}

/// Do again what was last undone.
pub fn redo(p: &Project) -> Result<Value> {
    let step = redo_steps(p).pop().context("nothing to redo")?;
    let what = step_what(&step);
    push_undo(p, &what)?;
    restore(p, &step)?;
    std::fs::remove_dir_all(&step)?;
    Ok(json!({"redone": what, "left": undo_steps(p).len(), "redo": redo_steps(p).len()}))
}

/// The edits that can be undone (oldest first) and redone: what each was, and when.
pub fn history(p: &Project) -> Value {
    let when = |d: &PathBuf| std::fs::metadata(d.join("what.txt")).or_else(|_| std::fs::metadata(d)).ok().and_then(|m| m.modified().ok()).and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0);
    let list = |v: Vec<PathBuf>| v.iter().map(|d| json!({"what": step_what(d), "when": when(d)})).collect::<Vec<_>>();
    json!({"undo": list(undo_steps(p)), "redo": list(redo_steps(p))})
}

/// Go back `steps` edits at once (the history list's "back to here").
pub fn undo_many(p: &Project, steps: usize) -> Result<Value> {
    let mut last = json!({});
    for _ in 0..steps.max(1) {
        last = undo(p)?;
    }
    Ok(last)
}

// ---------------------------------------------------------------- spawns

/// What the pack can spawn: its own creatures and objects (entry, name).
pub fn spawnables(p: &Project) -> Value {
    let list = |t: &str, key: &str, name: &str, disp: &str| -> Vec<Value> {
        dbc_rows(p, "world", t)
            .iter()
            .filter_map(|r| Some(json!({"entry": r.get(key)?.as_integer()?, "name": r.get(name).and_then(toml::Value::as_str).unwrap_or(""), "display": r.get(disp).and_then(toml::Value::as_integer)})))
            .collect()
    };
    json!({"creatures": list("creature_template", "Entry", "Name", "DisplayId1"), "objects": list("gameobject_template", "entry", "name", "displayId")})
}

/// The pack's spawns on one tile, tile-local, with names where the pack knows them.
fn spawns_on(p: &Project, map: &str, a: i32, b: i32) -> Vec<Value> {
    let Some(id) = map_id(p, map) else { return vec![] };
    let names = spawnables(p);
    let name_of = |kind: &str, e: i64| {
        names[kind].as_array().and_then(|l| l.iter().find(|x| x["entry"] == e)).and_then(|x| x["name"].as_str()).filter(|n| !n.is_empty()).map(str::to_string).unwrap_or(format!("#{e}"))
    };
    let display_of = |kind: &str, e: i64| names[kind].as_array().and_then(|l| l.iter().find(|x| x["entry"] == e)).map(|x| x["display"].clone()).unwrap_or(Value::Null);
    let (x0, z0) = (a as f64 * adt::TILE, b as f64 * adt::TILE);
    let routes = crate::behaviour::paths(p);
    let mut out = vec![];
    for (table, kind) in [("creature", "creatures"), ("gameobject", "objects")] {
        for r in dbc_rows(p, "world", table) {
            let num = |k: &str| r.get(k).and_then(|v| v.as_float().or(v.as_integer().map(|i| i as f64))).unwrap_or(0.0);
            if num("map") as u32 != id || adt::tile_of(num("position_x"), num("position_y")) != (a, b) {
                continue;
            }
            let f = adt::to_file(num("position_x"), num("position_y"), 0.0);
            let e = num("id") as i64;
            let guid = num("guid") as i64;
            // its route, tile-local, when it walks one
            let path: Vec<Value> = if table == "creature" {
                routes.iter().find(|r| r.guid == guid).map(|r| r.points.iter().map(|pt| { let f = adt::to_file(pt.x, pt.y, pt.z); json!({"u": f[0] as f64 - x0, "v": f[2] as f64 - z0, "x": pt.x, "y": pt.y, "z": pt.z, "wait": pt.wait}) }).collect()).unwrap_or_default()
            } else {
                vec![]
            };
            out.push(json!({"table": table, "guid": guid, "entry": e, "name": name_of(kind, e), "display": display_of(kind, e),
                            "u": f[0] as f64 - x0, "v": f[2] as f64 - z0, "o": num("orientation"), "wander": num("spawndist"), "path": path}));
        }
    }
    out
}

// ---------------------------------------------------------------- portals

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Spot {
    pub map: String,
    pub x: f64,
    pub y: f64,
    pub z: f64,
    #[serde(default)]
    pub o: f64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NewPortal {
    pub name: String,
    pub from: Spot,
    pub to: Spot,
    /// yards around `from` that take a player through
    #[serde(default = "five")]
    pub radius: f64,
    #[serde(default)]
    pub min_level: i64,
}
fn five() -> f64 {
    5.0
}

fn dbc_rows(p: &Project, kind: &str, t: &str) -> Vec<toml::Table> {
    let d = crate::data::load(p);
    let m = if kind == "world" { &d.world } else { &d.dbc };
    m.get(t).map(|r| r.rows.clone()).unwrap_or_default()
}

/// A portal: walk into a circle on one map, arrive at a spot on another (or the same) map.
/// An AreaTrigger row (the client notices the player stepping in) and its areatrigger_teleport
/// row (where the server sends them), the ID from the pack's AreaTrigger range.
pub fn add_portal(p: &Project, spec: &NewPortal) -> Result<Value> {
    let from = map_id(p, &spec.from.map).with_context(|| format!("{}: not a map Forge knows", spec.from.map))?;
    let to = map_id(p, &spec.to.map).with_context(|| format!("{}: not a map Forge knows", spec.to.map))?;
    if !(1.0..=50.0).contains(&spec.radius) {
        bail!("a portal's radius is 1 to 50 yards");
    }
    let name = if spec.name.trim().is_empty() { format!("To {}", spec.to.map) } else { spec.name.trim().to_string() };
    let mut lock = IdLock::load(&p.root)?;
    let id = lock.allocate(&p.manifest.pack.id, "AreaTrigger", &name)?;
    lock.save(&p.root)?;
    use toml::Value as T;
    let tag = format!("portal: {name}");
    let mut trig = dbc_rows(p, "dbc", "AreaTrigger");
    trig.push(toml::Table::from_iter([
        ("ID".to_string(), T::Integer(id as i64)),
        ("comment".to_string(), T::String(tag.clone())),
        ("ContinentID".to_string(), T::Integer(from as i64)),
        ("Pos".to_string(), T::Array(vec![T::Float(spec.from.x), T::Float(spec.from.y), T::Float(spec.from.z)])),
        ("Radius".to_string(), T::Float(spec.radius)),
    ]));
    crate::data::save_rows(p, "dbc", "AreaTrigger", &trig)?;
    let mut tp = dbc_rows(p, "world", "areatrigger_teleport");
    tp.push(toml::Table::from_iter([
        ("id".to_string(), T::Integer(id as i64)),
        ("comment".to_string(), T::String(tag)),
        ("name".to_string(), T::String(name.clone())),
        ("required_level".to_string(), T::Integer(spec.min_level.clamp(0, 255))),
        ("target_map".to_string(), T::Integer(to as i64)),
        ("target_position_x".to_string(), T::Float(spec.to.x)),
        ("target_position_y".to_string(), T::Float(spec.to.y)),
        ("target_position_z".to_string(), T::Float(spec.to.z)),
        ("target_orientation".to_string(), T::Float(spec.to.o)),
    ]));
    crate::data::save_rows(p, "world", "areatrigger_teleport", &tp)?;
    Ok(json!({"id": id, "name": name}))
}

/// The pack's portals: where each one is and where it goes.
pub fn portals(p: &Project) -> Vec<Value> {
    let names: BTreeMap<u32, String> = maps(p).into_iter().map(|(i, n)| (i, n)).collect();
    let tps = dbc_rows(p, "world", "areatrigger_teleport");
    let num = |r: &toml::Table, k: &str| r.get(k).and_then(|v| v.as_float().or(v.as_integer().map(|i| i as f64))).unwrap_or(0.0);
    dbc_rows(p, "dbc", "AreaTrigger")
        .iter()
        .filter_map(|r| {
            let id = r.get("ID")?.as_integer()?;
            let t = tps.iter().find(|t| t.get("id").and_then(toml::Value::as_integer) == Some(id))?;
            let pos: Vec<f64> = r.get("Pos")?.as_array()?.iter().map(|v| v.as_float().or(v.as_integer().map(|i| i as f64)).unwrap_or(0.0)).collect();
            let fm = num(r, "ContinentID") as u32;
            let tm = num(t, "target_map") as u32;
            Some(json!({
                "id": id, "name": t.get("name").and_then(toml::Value::as_str).unwrap_or(""),
                "from": {"map": names.get(&fm).cloned().unwrap_or(fm.to_string()), "x": pos.first(), "y": pos.get(1), "z": pos.get(2)},
                "to": {"map": names.get(&tm).cloned().unwrap_or(tm.to_string()), "x": num(t, "target_position_x"), "y": num(t, "target_position_y"), "z": num(t, "target_position_z")},
                "radius": num(r, "Radius"),
            }))
        })
        .collect()
}

pub fn remove_portal(p: &Project, id: i64) -> Result<()> {
    let keep = |rows: Vec<toml::Table>, key: &str| -> Vec<toml::Table> { rows.into_iter().filter(|r| r.get(key).and_then(toml::Value::as_integer) != Some(id)).collect() };
    crate::data::save_rows(p, "dbc", "AreaTrigger", &keep(dbc_rows(p, "dbc", "AreaTrigger"), "ID"))?;
    crate::data::save_rows(p, "world", "areatrigger_teleport", &keep(dbc_rows(p, "world", "areatrigger_teleport"), "id"))?;
    Ok(())
}

/// Build one map's edited tiles: each tile the pack reshapes or places doodads on, read through
/// `read` (the game's, or a realm's), with its height delta, then its doodads.
pub fn edit_tiles(
    map: &str,
    deltas: &BTreeMap<(i32, i32), TileEdit>,
    doodads: &BTreeMap<(i32, i32), Vec<Doodad>>,
    read: &dyn Fn(&str) -> Result<Vec<u8>>,
) -> Result<Vec<(String, Vec<u8>)>> {
    let mut tiles: Vec<(i32, i32)> = deltas.keys().chain(doodads.keys()).copied().collect();
    tiles.sort();
    tiles.dedup();
    let mut out = vec![];
    for (a, b) in tiles {
        let path = adt::tile_path(map, a, b);
        let bytes = match read(&path) {
            Ok(b) => b,
            // only the edge of a building standing on a neighbour reaches here: no tile, no matter
            Err(_) if !deltas.contains_key(&(a, b))
                && doodads.get(&(a, b)).is_some_and(|ds| ds.iter().all(|d| d.extents.is_some() && adt::tile_of_file(d.pos) != (a, b))) => continue,
            Err(e) => return Err(e.context(path)),
        };
        let mut t = Adt::parse(&bytes)?;
        if let Some(e) = deltas.get(&(a, b)) {
            if let Some(d) = &e.heights {
                apply_delta(&mut t, (a, b), d)?;
            }
            apply_chunks(&mut t, &e.chunks)?;
            if !e.hidden.is_empty() {
                t.hide_objects(&e.hidden)?;
            }
        }
        if let Some(ds) = doodads.get(&(a, b)) {
            t.add_doodads((a, b), ds)?;
        }
        out.push((path, t.write()));
    }
    Ok(out)
}

/// What a build does with the World layer: the data (placements JSON, terrain deltas) always;
/// with `dev`, the edited tiles for the test patch.
pub fn emit(p: &Project, out: &std::path::Path, game: Option<&GameData>, dev: bool) -> Result<Vec<(String, Vec<u8>)>> {
    let all = load(p)?;
    let mut maps: BTreeMap<String, (BTreeMap<(i32, i32), TileEdit>, BTreeMap<(i32, i32), Vec<Doodad>>)> = BTreeMap::new();
    for (map, list) in &all {
        if !list.is_empty() {
            maps.entry(map.clone()).or_default().1 = by_tile(p, map, list)?;
        }
    }
    for (map, a, b) in terrain_tiles(p) {
        let dir = out.join("data/terrain").join(&map);
        std::fs::create_dir_all(&dir)?;
        let heights = load_delta(p, &map, a, b)?;
        if let Some(d) = &heights {
            std::fs::write(dir.join(format!("{a}_{b}.hd")), encode_delta(d))?;
        }
        let chunks = load_chunks(p, &map, a, b)?;
        if !chunks.is_empty() {
            std::fs::write(dir.join(format!("{a}_{b}.chunks.json")), serde_json::to_vec(&chunks)?)?;
        }
        let hid = hidden(p, &map, a, b);
        if !hid.is_empty() {
            std::fs::write(dir.join(format!("{a}_{b}.hidden.json")), serde_json::to_vec(&hid)?)?;
        }
        maps.entry(map).or_default().0.insert((a, b), TileEdit { heights, chunks, hidden: hid });
    }
    let mut tiles_out = vec![];
    let mut trs: Option<String> = None;
    for (map, (deltas, doodads)) in &maps {
        if !doodads.is_empty() {
            let delta: Vec<Value> = doodads.iter().flat_map(|((a, b), ds)| ds.iter().map(move |d| json!({"tile": [a, b], "doodad": d}))).collect();
            let dir = out.join("data/world");
            std::fs::create_dir_all(&dir)?;
            std::fs::write(dir.join(format!("{map}.json")), serde_json::to_vec_pretty(&json!({"map": map, "doodads": delta}))?)?;
        }
        if dev {
            let g = game.context("a dev build of map edits needs your game folder")?;
            let read = |path: &str| read_world(p, g, path);
            let edited = edit_tiles(map, deltas, doodads, &read)?;
            trs = minimaps_for(map, deltas, &edited, &read, trs, &mut tiles_out)?;
            tiles_out.extend(edited);
        }
    }
    if let Some(t) = trs {
        tiles_out.push((crate::minimap::TRS.to_string(), t.into_bytes()));
    }
    Ok(tiles_out)
}

/// New minimap pictures for the tiles whose terrain changed (`deltas`), from the edited tiles;
/// the translation table carried from map to map. Pictures go into `out`.
pub fn minimaps_for(
    map: &str,
    deltas: &BTreeMap<(i32, i32), TileEdit>,
    edited: &[(String, Vec<u8>)],
    read: &dyn Fn(&str) -> Result<Vec<u8>>,
    trs: Option<String>,
    out: &mut Vec<(String, Vec<u8>)>,
) -> Result<Option<String>> {
    let mut tiles = vec![];
    for &(a, b) in deltas.keys() {
        let path = adt::tile_path(map, a, b);
        if let Some((_, bytes)) = edited.iter().find(|(p, _)| p.eq_ignore_ascii_case(&path)) {
            tiles.push(((a, b), Adt::parse(bytes)?));
        }
    }
    if tiles.is_empty() {
        return Ok(trs);
    }
    let (files, trs) = crate::minimap::for_tiles(map, &tiles, read, trs)?;
    out.extend(files);
    Ok(trs)
}

pub fn check(p: &Project, game: Option<&GameData>) -> Vec<Finding> {
    let mut out = vec![];
    let all = match load(p) {
        Ok(a) => a,
        Err(e) => return vec![Finding::error("world.toml", "maps", format!("{e:#}"))],
    };
    let lock = IdLock::load(&p.root).unwrap_or_default();
    let reshaped = terrain_tiles(p);
    if !reshaped.is_empty() {
        out.push(Finding::info(
            "world.terrain",
            "maps",
            format!("{} edited tile(s): Test & Play and the realm build convert them for the server too; their movement maps (MoveMapGen) are the old ones until rebuilt", reshaped.len()),
        ));
    }
    for (map, list) in &all {
        let at = format!("maps/{map}/placements.toml");
        if map_id(p, map).is_none() {
            out.push(Finding::warning("world.map", &at, format!("{map} isn't one of the game's maps Forge knows")));
        }
        for pl in list {
            match model_path(p, &pl.model) {
                Err(e) => out.push(Finding::error("world.model", &at, format!("{e:#}"))),
                Ok(m) if is_wmo(&m) => {
                    if game.is_some_and(|g| !has_world(p, g, &m)) {
                        out.push(Finding::error("world.model", &at, format!("{m} isn't in your game")));
                    }
                    if pl.wmo_box.is_none() {
                        out.push(Finding::error("world.model", &at, format!("{m}: place it again from the World screen (Forge reads the building's size then)")));
                    }
                }
                Ok(m) => {
                    let m2 = format!("{}.m2", m.trim_end_matches(".mdx").trim_end_matches(".MDX"));
                    let ours = pl.model.starts_with("model:");
                    if !ours && game.is_some_and(|g| !g.contains(&m2)) {
                        out.push(Finding::error("world.model", &at, format!("{m2} isn't in your game")));
                    }
                }
            }
            if !lock.owns("MDDF", pl.uid) {
                out.push(Finding::error("world.uid", &at, format!("doodad uid {} isn't in the pack's range", pl.uid)));
            }
            if let Some(g) = game {
                let (a, b) = adt::tile_of(pl.x, pl.y);
                if !has_world(p, g, &adt::tile_path(map, a, b)) {
                    out.push(Finding::error("world.tile", &at, format!("{map} has no terrain at {:.0}, {:.0} (tile {a}_{b})", pl.x, pl.y)));
                }
            }
        }
    }
    out
}

/// One tile for the World screen: heights, areas, the doodads already there (tile-local yards),
/// and this pack's placements on it.
/// The tile's minimap picture as it would be baked now (PNG, base64).
pub fn minimap_png(p: &Project, g: &GameData, map: &str, a: i32, b: i32) -> Result<String> {
    use base64::Engine;
    let (t, _) = current_tile(p, g, map, a, b)?;
    let img = crate::minimap::bake(&t, &|path| read_world(p, g, path));
    let mut out = std::io::Cursor::new(Vec::new());
    img.write_to(&mut out, image::ImageFormat::Png)?;
    Ok(base64::engine::general_purpose::STANDARD.encode(out.into_inner()))
}

/// A tile seen from far off: heights every 4th vertex (33 × 33), each chunk's water level, and
/// the ground's colours as a small picture. What the view draws past the tiles round yours.
pub fn far_tile(p: &Project, g: &GameData, map: &str, a: i32, b: i32, size: u32) -> Result<Value> {
    let (t, _) = current_tile(p, g, map, a, b)?;
    let hm = t.heightmap();
    let heights: Vec<f32> = (0..33).flat_map(|i| (0..33).map(move |j| (i * 4, j * 4))).map(|(i, j)| hm[i * 129 + j]).collect();
    let water: Vec<Option<f32>> = (0..256)
        .map(|k| t.liquid(k % 16, k / 16).filter(|l| (0..64).any(|x| l.shown(x))).map(|l| l.verts.iter().map(|v| v.1).sum::<f32>() / 81.0))
        .collect();
    let read = |path: &str| read_world(p, g, path).with_context(|| format!("{path} isn't in the game"));
    let img = crate::trueview::ground(&t, &read, size.clamp(16, 256), true);
    Ok(json!({"heights": heights, "water": water, "png": crate::trueview::png_b64(&img)?}))
}

pub fn tile_view(p: &Project, g: &GameData, map: &str, a: i32, b: i32) -> Result<Value> {
    let (t, edits) = current_tile(p, g, map, a, b)?;
    let hid = hidden(p, map, a, b);
    let reshaped = load_delta(p, map, a, b)?.is_some() || !edits.is_empty() || !hid.is_empty();
    // the ground's look: per chunk, the strongest layer on an 8 × 8 grid (128 × 128 for the tile)
    let texnames = t.textures();
    let mut ground = vec![0u16; 128 * 128];
    let mut holes = vec![0u32; 256];
    let mut water = vec![Value::Null; 256];
    for row in 0..16 {
        for col in 0..16 {
            holes[row * 16 + col] = t.holes(col, row);
            if let Some(l) = t.liquid(col, row) {
                let tiles: String = (0..64).map(|k| if l.shown(k) { '1' } else { '0' }).collect();
                let top = l.verts.iter().map(|v| v.1).fold(f32::MIN, f32::max);
                let low = l.verts.iter().map(|v| v.1).fold(f32::MAX, f32::min);
                water[row * 16 + col] = if top - low > 0.01 {
                    json!({"kind": l.kind.name(), "tiles": tiles, "level": top, "heights": l.verts.iter().map(|v| v.1).collect::<Vec<_>>()})
                } else {
                    json!({"kind": l.kind.name(), "tiles": tiles, "level": top})
                };
            }
            let ls = t.layers(col, row).unwrap_or_default();
            for gy in 0..8 {
                for gx in 0..8 {
                    let k = (gy * 8 + 4) * 64 + gx * 8 + 4;
                    // the top layer with alpha wins (each layer covers those below by its alpha)
                    let mut best = 0usize;
                    for (i, l) in ls.iter().enumerate().skip(1) {
                        if l.alpha.as_ref().is_some_and(|a| a[k] > 127) {
                            best = i;
                        }
                    }
                    let name = ls.get(best).map(|l| l.texture.as_str()).unwrap_or("");
                    ground[(row * 8 + gy) * 128 + col * 8 + gx] = texnames.iter().position(|n| n == name).map(|i| i as u16 + 1).unwrap_or(0);
                }
            }
        }
    }
    let (x0, z0) = (a as f64 * adt::TILE, b as f64 * adt::TILE);
    let portals_here: Vec<Value> = portals(p)
        .into_iter()
        .flat_map(|pt| {
            let mut out = vec![];
            for (end, other) in [("from", "to"), ("to", "from")] {
                let e = &pt[end];
                if !e["map"].as_str().is_some_and(|m| m.eq_ignore_ascii_case(map)) {
                    continue;
                }
                let (x, y) = (e["x"].as_f64().unwrap_or(0.0), e["y"].as_f64().unwrap_or(0.0));
                if adt::tile_of(x, y) != (a, b) {
                    continue;
                }
                let f = adt::to_file(x, y, 0.0);
                out.push(json!({"u": f[0] as f64 - x0, "v": f[2] as f64 - z0, "end": end, "id": pt["id"], "name": pt["name"], "other": pt[other]["map"], "radius": pt["radius"]}));
            }
            out
        })
        .collect();
    let buildings: Vec<Value> = t
        .wmos()
        .iter()
        .map(|w| {
            let e = w.extents.unwrap_or_default();
            json!({"u": w.pos[0] as f64 - x0, "v": w.pos[2] as f64 - z0, "h": w.pos[1], "model": w.model.rsplit('\\').next().unwrap_or(""), "path": w.model, "rot": w.rot, "uid": w.uid, "hidden": hid.contains(&w.uid), "set": w.set,
                   "box": [e[0] as f64 - x0, e[2] as f64 - z0, e[3] as f64 - x0, e[5] as f64 - z0, e[1], e[4]]})
        })
        .collect();
    let stock: Vec<Value> = t
        .doodads()
        .iter()
        .map(|d| json!({"u": d.pos[0] as f64 - x0, "v": d.pos[2] as f64 - z0, "h": d.pos[1], "model": d.model.rsplit('\\').next().unwrap_or(""), "path": d.model, "rot": d.rot, "scale": d.scale as f64 / 1024.0, "uid": d.uid, "hidden": hid.contains(&d.uid)}))
        .collect();
    let mine: Vec<Value> = load(p)?
        .get(map)
        .map(|l| {
            l.iter()
                .filter(|pl| match pl.wmo_box {
                    // a building shows on every tile its box reaches
                    Some(bx) => {
                        let e = adt::wmo_extents(bx, adt::to_file(pl.x, pl.y, pl.z), pl.turn as f32);
                        (e[0] as f64) < x0 + adt::TILE && (e[3] as f64) > x0 && (e[2] as f64) < z0 + adt::TILE && (e[5] as f64) > z0
                    }
                    None => adt::tile_of(pl.x, pl.y) == (a, b),
                })
                .map(|pl| {
                    let f = adt::to_file(pl.x, pl.y, pl.z);
                    let bx = pl.wmo_box.map(|bx| {
                        let e = adt::wmo_extents(bx, f, pl.turn as f32);
                        [e[0] as f64 - x0, e[2] as f64 - z0, e[3] as f64 - x0, e[5] as f64 - z0, e[1] as f64, e[4] as f64]
                    });
                    json!({"u": f[0] as f64 - x0, "v": f[2] as f64 - z0, "h": f[1], "path": model_path(p, &pl.model).ok(), "placement": pl, "box": bx})
                })
                .collect()
        })
        .unwrap_or_default();
    Ok(json!({
        "map": map, "tile": [a, b], "size": adt::TILE,
        "heights": t.heightmap(), "areas": t.areas(),
        "impass": (0..256).map(|k| t.impass(k % 16, k / 16)).collect::<Vec<_>>(),
        "shadows": (0..256).filter(|&k| t.shadow(k % 16, k / 16) > 0.0).count(),
        "stock": stock, "mine": mine, "reshaped": reshaped, "buildings": buildings, "portals": portals_here,
        "spawns": spawns_on(p, map, a, b),
        "textures": texnames, "ground": ground, "holes": holes, "water": water,
        // tile-local (u, v) → world: x = HALF - (b·TILE + v), y = HALF - (a·TILE + u)
        "origin": {"x": adt::HALF - z0, "y": adt::HALF - x0},
    }))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    #[test]
    fn brush_falloffs() {
        let sh = |falloff, inner| Shape { falloff, inner, ..Default::default() };
        // spray: about the share asked for, the same specks for the same seed
        let sp = Shape { spray: 0.3, seed: 7, ..Default::default() };
        let hits = (0..4000).filter(|i| sp.speck(*i as f64 * 1.3, (*i / 63) as f64 * 1.7)).count();
        assert!((900..1500).contains(&hits), "{hits}");
        assert_eq!(sp.speck(10.0, 20.0), sp.speck(10.0, 20.0));
        assert!(Shape::default().speck(1.0, 1.0));
        for f in [Falloff::Flat, Falloff::Linear, Falloff::Smooth, Falloff::Quadratic, Falloff::Trigonometric, Falloff::Gaussian] {
            let s = sh(f, 0.0);
            assert!((s.weight(0.0, 10.0) - 1.0).abs() < 1e-9, "{f:?} is full in the middle");
            assert_eq!(s.weight(10.0, 10.0), 0.0, "{f:?} is nothing at the edge");
            assert!(s.weight(5.0, 10.0) <= 1.0 && s.weight(5.0, 10.0) >= 0.0);
        }
        assert_eq!(sh(Falloff::Linear, 0.0).weight(5.0, 10.0), 0.5);
        assert_eq!(sh(Falloff::Linear, 0.5).weight(4.0, 10.0), 1.0);
        assert!((sh(Falloff::Linear, 0.5).weight(7.5, 10.0) - 0.5).abs() < 1e-9);
        assert!((sh(Falloff::Smooth, 0.0).weight(3.0, 10.0) - 0.5 * (1.0 + (std::f64::consts::PI * 0.3).cos())).abs() < 1e-9);
    }
    use crate::project::{create, Template};

    /// FORGE_REAL_GAME=<1.12 folder> [FORGE_DUMP=<dir>]: every World edit on a real tile
    /// (Northshire, Azeroth 32_48), through a dev build: the result parses, keeps its stock
    /// doodads and buildings, carries every edit, and converts for the server.
    #[test]
    #[ignore]
    fn every_edit_on_a_real_tile() {
        crate::test_config();
        let g = GameData::open(std::env::var("FORGE_REAL_GAME").unwrap()).unwrap();
        let dir = tempfile::tempdir().unwrap();
        let p = create(dir.path().join("p"), "Real Edit", "Orion", Template::Empty).unwrap();
        let (a, b) = (32, 48);
        let stock = Adt::parse(&g.read(&adt::tile_path("Azeroth", a, b)).unwrap()).unwrap();
        let (sd, sw) = (stock.doodads().len(), stock.wmos().len());
        // a spot in the middle of the tile
        let at = |u: f64, v: f64| (adt::HALF - (b as f64 * adt::TILE + v), adt::HALF - (a as f64 * adt::TILE + u));
        let (x, y) = at(300.0, 330.0);
        sculpt(&p, &g, "Azeroth", x, y, 40.0, 6.0, Brush::Raise).unwrap();
        sculpt(&p, &g, "Azeroth", x, y, 60.0, 0.5, Brush::Smooth).unwrap();
        // four different textures on one spot: the fifth layer rule gets exercised
        for t in stock.textures().iter().take(5) {
            paint(&p, &g, "Azeroth", x + 20.0, y, 15.0, 1.0, t).unwrap();
        }
        let (hx, hy) = at(100.0, 100.0);
        set_hole(&p, &g, "Azeroth", hx, hy, true).unwrap();
        paint_area(&p, &g, "Azeroth", hx, hy, 40.0, 87).unwrap();
        let (wx, wy) = at(420.0, 120.0);
        let ground = stock.height_at((a, b), a as f64 * adt::TILE + 420.0, b as f64 * adt::TILE + 120.0).unwrap();
        water(&p, &g, "Azeroth", wx, wy, 25.0, ground + 3.0, "water", false).unwrap();
        let tree = stock.doodads()[0].model.clone();
        place(&p, Some(&g), "Azeroth", Placement { model: tree, x: hx + 30.0, y: hy, z: 0.0, turn: 30.0, scale: 1.2, uid: 0, wmo_box: None, tilt: [0.0; 2], set: 0 }, true).unwrap();
        let inn = stock.wmos()[0].model.clone();
        place(&p, Some(&g), "Azeroth", Placement { model: inn, x: wx + 60.0, y: wy - 60.0, z: 0.0, turn: 45.0, scale: 1.0, uid: 0, wmo_box: None, tilt: [0.0; 2], set: 0 }, true).unwrap();
        // (a sample of the game may lack the models themselves)
        let f = check(&p, Some(&g));
        assert!(f.iter().all(|x| x.level != crate::check::Level::Error || (x.code == "world.model" && x.message.contains("isn't in your game") && x.message.ends_with(".m2 isn't in your game"))), "{f:?}");
        let out = dir.path().join("out");
        let tiles = emit(&p, &out, Some(&g), true).unwrap();
        let (path, bytes) = tiles.iter().find(|(n, _)| n.eq_ignore_ascii_case(&adt::tile_path("Azeroth", a, b))).unwrap();
        let t = Adt::parse(bytes).unwrap();
        assert_eq!(t.write(), *bytes, "the edited tile reads back as written");
        assert_eq!(t.doodads().len(), sd + 1, "stock doodads kept, ours added");
        assert_eq!(t.wmos().len(), sw + 1, "stock buildings kept, ours added");
        let f2 = adt::to_file(x, y, 0.0);
        assert!(t.height_at((a, b), f2[0] as f64, f2[2] as f64).unwrap() > stock.height_at((a, b), f2[0] as f64, f2[2] as f64).unwrap() + 2.0, "the hill");
        let (col, row) = adt::chunk_of((a, b), adt::to_file(hx, hy, 0.0)).unwrap();
        assert_ne!(t.holes(col, row), 0);
        assert_eq!(t.areas()[row * 16 + col], 87);
        assert!(t.impass(col, row) && !t.impass((col + 3) % 16, row), "impassable, only there");
        let (wc, wr) = adt::chunk_of((a, b), adt::to_file(wx, wy, 0.0)).unwrap();
        assert!(t.liquid(wc, wr).is_some());
        let (pc, pr) = adt::chunk_of((a, b), adt::to_file(x + 20.0, y, 0.0)).unwrap();
        assert_eq!(t.layers(pc, pr).unwrap().len(), 4, "four layers at most");
        // painted layers carry the ground effect the texture has elsewhere on the tile
        for l in t.layers(pc, pr).unwrap() {
            let effects: Vec<u32> = (0..256).flat_map(|k| stock.layers(k % 16, k / 16).unwrap()).filter(|x| x.texture.eq_ignore_ascii_case(&l.texture)).map(|x| x.effect).collect();
            assert!(effects.contains(&l.effect), "{}: effect {} not among {effects:?}", l.texture, l.effect);
        }
        // every other chunk's layers untouched
        let far = (0..256).filter(|k| {
            let (c, r) = (k % 16, k / 16);
            (c as i64 - pc as i64).abs() > 2 && (r as i64 - pr as i64).abs() > 2
        });
        for k in far {
            let (c, r) = (k % 16, k / 16);
            assert_eq!(t.layers(c, r).unwrap().len(), stock.layers(c, r).unwrap().len(), "chunk {c},{r}");
        }
        // the server's copy: heights as the tile has them
        let at_tbl = crate::data::Dbc::parse(&g.read("DBFilesClient\\AreaTable.dbc").unwrap()).unwrap();
        let flags = crate::gridmap::area_flags(&at_tbl);
        let m = crate::gridmap::convert(&t, &|i| flags.get(&i).copied(), crate::gridmap::VERSION).unwrap();
        let hm = t.heightmap();
        let mut worst = 0f32;
        for (gx, gy) in [(0, 0), (64, 64), (100, 20), (128, 128), (75, 80)] {
            worst = worst.max((crate::gridmap::v9_height(&m, gx, gy).unwrap() - hm[gy * 129 + gx]).abs());
        }
        assert!(worst < 0.05, "server heights off by {worst}");
        if let Ok(d) = std::env::var("FORGE_DUMP") {
            std::fs::write(std::path::Path::new(&d).join("edited_32_48.adt"), bytes).unwrap();
            std::fs::write(std::path::Path::new(&d).join("0004832.map"), &m).unwrap();
        }
        println!("{path}: {} bytes (stock {}), {} doodads, {} buildings, server map {} bytes", bytes.len(), stock.write().len(), sd + 1, sw + 1, m.len());
    }

    /// A game with Map.dbc (Kalimdor, Shadowfang, Molten Core), AreaTable.dbc and a ground texture.
    pub(crate) fn map_game(dir: &std::path::Path) -> GameData {
        let game = dir.join("wow/Data");
        std::fs::create_dir_all(&game).unwrap();
        let map = |id: u32, ls: u32| {
            let mut r = vec![0u32; 42];
            r[0] = id;
            r[38] = ls; // the loading screen
            r
        };
        let maps = crate::data::Dbc { fields: 42, records: vec![map(1, 7), map(33, 11), map(409, 13)], strings: vec![0] };
        let mut at = vec![0u32; 25];
        at[0] = 12;
        at[3] = 1;
        let areas = crate::data::Dbc { fields: 25, records: vec![at], strings: vec![0] };
        let png = dir.join("g.png");
        image::RgbaImage::from_pixel(16, 16, image::Rgba([60, 120, 40, 255])).save(&png).unwrap();
        crate::mpqw::write(
            &game.join("dbc.MPQ"),
            &[
                ("DBFilesClient\\Map.dbc".into(), maps.write()),
                ("DBFilesClient\\AreaTable.dbc".into(), areas.write()),
                ("DBFilesClient\\LoadingScreens.dbc".into(), crate::data::Dbc { fields: 3, records: vec![vec![7, 0, 0]], strings: vec![0] }.write()),
                ("DBFilesClient\\AreaTrigger.dbc".into(), crate::data::Dbc { fields: 10, records: vec![vec![1; 10]], strings: vec![0] }.write()),
                ("Tileset\\Elwynn\\ElwynnGrassBase.blp".into(), crate::build::png_to_blp(&png).unwrap()),
            ],
        )
        .unwrap();
        GameData::open(dir.join("wow")).unwrap()
    }

    #[test]
    fn buildings_stand_on_every_tile_they_reach() {
        crate::test_config();
        let dir = tempfile::tempdir().unwrap();
        let p = create(dir.path().join("p"), "House Pack", "Orion", Template::Empty).unwrap();
        let g0 = map_game(dir.path());
        // a building in the game: a 60 × 40 yard root
        let mut root = b"REVM".to_vec();
        root.extend(4u32.to_le_bytes());
        root.extend(17u32.to_le_bytes());
        root.extend(b"DHOM");
        root.extend(64u32.to_le_bytes());
        let mut mohd = vec![0u8; 64];
        for (k, v) in [-30f32, -20.0, 0.0, 30.0, 20.0, 25.0].iter().enumerate() {
            mohd[36 + k * 4..40 + k * 4].copy_from_slice(&v.to_le_bytes());
        }
        root.extend(mohd);
        crate::mpqw::write(&dir.path().join("wow/Data/wmo.MPQ"), &[("World\\wmo\\Azeroth\\Buildings\\Inn\\Inn.wmo".into(), root)]).unwrap();
        drop(g0);
        let g = GameData::open(dir.path().join("wow")).unwrap();
        let spec: NewMap = serde_json::from_value(json!({"name": "Inn Isle", "size": 2, "height": 4.0})).unwrap();
        new_map(&p, &g, &spec).unwrap();
        // right on the corner where tiles 31/32 × 31/32 meet
        let (x, y) = (adt::HALF - 33.0 * adt::TILE, adt::HALF - 33.0 * adt::TILE);
        let pl = place(&p, Some(&g), "InnIsle", Placement { model: "World\\wmo\\Azeroth\\Buildings\\Inn\\Inn.wmo".into(), x, y, z: 0.0, turn: 30.0, scale: 1.0, uid: 0, wmo_box: None, tilt: [0.0; 2], set: 0 }, true).unwrap();
        assert_eq!(pl.wmo_box.unwrap()[5], 25.0);
        assert!((pl.z - 4.0).abs() < 1e-3);
        let f = check(&p, Some(&g));
        assert!(f.iter().all(|x| x.level != crate::check::Level::Error), "{f:?}");
        let tiles = emit(&p, &dir.path().join("out"), Some(&g), true).unwrap();
        let adts: Vec<&(String, Vec<u8>)> = tiles.iter().filter(|(n, _)| n.ends_with(".adt")).collect();
        assert_eq!(adts.len(), 4);
        for (n, b) in adts {
            let w = Adt::parse(b).unwrap().wmos();
            assert_eq!(w.len(), 1, "{n}");
            assert_eq!(w[0].uid, pl.uid);
        }
        let v = tile_view(&p, &g, "InnIsle", 32, 32).unwrap();
        assert_eq!(v["mine"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn portals_link_maps() {
        crate::test_config();
        let dir = tempfile::tempdir().unwrap();
        let p = create(dir.path().join("p"), "Gate Pack", "Orion", Template::Empty).unwrap();
        let g = map_game(dir.path());
        new_map(&p, &g, &serde_json::from_value(json!({"name": "Ember Isle"})).unwrap()).unwrap();
        let spec: NewPortal = serde_json::from_value(json!({
            "name": "Ferry to Ember Isle",
            "from": {"map": "Azeroth", "x": -9000.0, "y": -100.0, "z": 50.0},
            "to": {"map": "EmberIsle", "x": 10.0, "y": 20.0, "z": 5.0, "o": 1.5}, "radius": 4.0})).unwrap();
        let r = add_portal(&p, &spec).unwrap();
        let id = r["id"].as_i64().unwrap();
        assert!((10_000..15_000).contains(&id));
        let list = portals(&p);
        assert_eq!(list.len(), 1);
        assert_eq!(list[0]["to"]["map"], "EmberIsle");
        assert_eq!(list[0]["from"]["x"], -9000.0);
        assert!(crate::data::check(&p, Some(&g)).iter().all(|f| f.level != crate::check::Level::Error), "{:?}", crate::data::check(&p, Some(&g)));
        let (ins, rb) = crate::data::sql(&p, &crate::data::load(&p));
        assert!(ins.contains("areatrigger_teleport") && ins.contains("'Ferry to Ember Isle'"), "{ins}");
        assert!(rb.contains(&format!("DELETE FROM `areatrigger_teleport` WHERE `id` = {id}")), "{rb}");
        // the client's AreaTrigger.dbc gets the row (a dev build merges it into the game's)
        let mut at = crate::data::Dbc { fields: 10, records: vec![], strings: vec![0] };
        at.records.push(vec![1, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        let merged = crate::data::merge("AreaTrigger", &at, &dbc_rows(&p, "dbc", "AreaTrigger")).unwrap();
        let row = &merged.records[merged.find(id as u32).unwrap()];
        assert_eq!((row[1], f32::from_bits(row[2]), f32::from_bits(row[5])), (0, -9000.0, 4.0));
        remove_portal(&p, id).unwrap();
        assert!(portals(&p).is_empty());
    }

    #[test]
    fn undo_goes_back_a_step_at_a_time() {
        crate::test_config();
        let dir = tempfile::tempdir().unwrap();
        let p = create(dir.path().join("p"), "Undo Pack", "Orion", Template::Empty).unwrap();
        let g = map_game(dir.path());
        assert!(undo(&p).is_err(), "nothing yet");
        checkpoint(&p, "new map").unwrap();
        new_map(&p, &g, &serde_json::from_value(json!({"name": "Ember Isle"})).unwrap()).unwrap();
        let (x, y) = (adt::HALF - 32.0 * adt::TILE - 100.0, adt::HALF - 32.0 * adt::TILE - 100.0);
        checkpoint(&p, "raise").unwrap();
        sculpt(&p, &g, "EmberIsle", x, y, 30.0, 5.0, Brush::Raise).unwrap();
        let h = |p: &Project| tile_view(p, &g, "EmberIsle", 32, 32).unwrap()["heights"].as_array().unwrap().iter().map(|v| v.as_f64().unwrap()).fold(f64::MIN, f64::max);
        assert!(h(&p) > 1.0);
        let r = undo(&p).unwrap();
        assert_eq!(r["undone"], "raise");
        assert_eq!(h(&p), 0.0, "the hill is gone, the map stays");
        undo(&p).unwrap();
        assert!(map_id(&p, "EmberIsle").is_none(), "and then the map");
        assert!(!p.root.join("files/World/Maps/EmberIsle").exists());
        // and both come back with redo, in order
        assert_eq!(redo(&p).unwrap()["redone"], "new map");
        assert!(map_id(&p, "EmberIsle").is_some());
        assert_eq!(redo(&p).unwrap()["redone"], "raise");
        assert!(h(&p) > 1.0);
        assert!(redo(&p).is_err());
        let hist = history(&p);
        assert_eq!(hist["undo"].as_array().unwrap().iter().map(|s| s["what"].as_str().unwrap()).collect::<Vec<_>>(), vec!["new map", "raise"]);
        // back two at once; a new edit forgets the redo
        undo_many(&p, 2).unwrap();
        assert!(map_id(&p, "EmberIsle").is_none());
        assert_eq!(history(&p)["redo"].as_array().unwrap().len(), 2);
        checkpoint(&p, "other").unwrap();
        assert_eq!(history(&p)["redo"].as_array().unwrap().len(), 0);
        for k in 0..35 {
            checkpoint(&p, &format!("s{k}")).unwrap();
        }
        assert_eq!(undo_steps(&p).len(), 30);
    }

    #[test]
    fn spawns_from_the_map() {
        crate::test_config();
        let dir = tempfile::tempdir().unwrap();
        let p = create(dir.path().join("p"), "Spawn Pack", "Orion", Template::Empty).unwrap();
        let g = map_game(dir.path());
        new_map(&p, &g, &serde_json::from_value(json!({"name": "Ember Isle"})).unwrap()).unwrap();
        let id = map_id(&p, "EmberIsle").unwrap();
        let (x, y) = (adt::HALF - 32.0 * adt::TILE - 100.0, adt::HALF - 32.0 * adt::TILE - 50.0);
        let pos = |o| crate::data::Pos { map: id, x, y, z: 3.0, o };
        let c = crate::data::add_spawn(&p, 6, pos(0.0), 300, 5.0).unwrap();
        let o = crate::data::add_object_spawn(&p, 1617, pos(std::f64::consts::PI), 600).unwrap();
        assert!((5_000_000..6_000_000).contains(&o));
        let v = tile_view(&p, &g, "EmberIsle", 32, 32).unwrap();
        let sp = v["spawns"].as_array().unwrap();
        assert_eq!(sp.len(), 2);
        assert!((sp[0]["u"].as_f64().unwrap() - 50.0).abs() < 0.01 && (sp[0]["v"].as_f64().unwrap() - 100.0).abs() < 0.01);
        assert_eq!(sp[1]["table"], "gameobject");
        let rows = dbc_rows(&p, "world", "gameobject");
        assert!((rows[0]["rotation2"].as_float().unwrap() - 1.0).abs() < 1e-6, "turned half round");
        assert!(crate::data::check(&p, Some(&g)).iter().all(|f| f.level != crate::check::Level::Error), "{:?}", crate::data::check(&p, Some(&g)));
        let (ins, _) = crate::data::sql(&p, &crate::data::load(&p));
        assert!(ins.contains("INSERT INTO `gameobject`"), "{ins}");
        crate::data::remove_spawn(&p, "creature", c as i64).unwrap();
        assert_eq!(tile_view(&p, &g, "EmberIsle", 32, 32).unwrap()["spawns"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn a_map_gets_its_own_loading_screen() {
        crate::test_config();
        let dir = tempfile::tempdir().unwrap();
        let p = create(dir.path().join("p"), "Screen Pack", "Orion", Template::Empty).unwrap();
        let g = map_game(dir.path());
        let r = new_map(&p, &g, &serde_json::from_value(json!({"name": "Ember Isle"})).unwrap()).unwrap();
        assert_eq!(own_maps(&p), vec!["EmberIsle"]);
        let mut png = std::io::Cursor::new(vec![]);
        image::RgbaImage::from_pixel(800, 600, image::Rgba([200, 90, 30, 255])).write_to(&mut png, image::ImageFormat::Png).unwrap();
        let s1 = set_loading_screen(&p, "emberisle", png.get_ref()).unwrap();
        let s2 = set_loading_screen(&p, "EmberIsle", png.get_ref()).unwrap();
        assert_eq!(s1["id"], s2["id"], "a new picture reuses the row");
        assert!(set_loading_screen(&p, "Azeroth", png.get_ref()).is_err());
        let f = crate::check::run(&p, Some(&g));
        assert!(f.iter().all(|x| x.level != crate::check::Level::Error), "{f:?}");
        let rep = crate::build::build_with(&p, Some(&g), true).unwrap();
        let mut arc = wow_mpq::Archive::open(p.build_dir().join(&rep.mpq)).unwrap();
        let blp = arc.read_file("Interface\\Glues\\LoadingScreens\\Forge_EmberIsle.blp").unwrap();
        assert_eq!(crate::minimap::decode(&blp).unwrap().dimensions(), (1024, 1024));
        let maps = crate::data::Dbc::parse(&arc.read_file("DBFilesClient\\Map.dbc").unwrap()).unwrap();
        let row = &maps.records[maps.find(r["id"].as_u64().unwrap() as u32).unwrap()];
        assert_eq!(row[38] as i64, s1["id"].as_i64().unwrap());
    }

    #[test]
    fn a_new_map_is_a_map_like_any_other() {
        crate::test_config();
        let dir = tempfile::tempdir().unwrap();
        let p = create(dir.path().join("p"), "Isle Pack", "Orion", Template::Empty).unwrap();
        let g = map_game(dir.path());
        assert_eq!(map_directory("isle of  embers!"), "IsleOfEmbers");
        let spec: NewMap = serde_json::from_value(json!({"name": "Isle of Embers", "size": 2, "height": 10.0})).unwrap();
        let r = new_map(&p, &g, &spec).unwrap();
        assert_eq!(r["map"], "IsleOfEmbers");
        let id = r["id"].as_u64().unwrap() as u32;
        assert!((800..1000).contains(&id));
        assert_eq!(map_id(&p, "isleofembers"), Some(id));
        assert_eq!(r["tiles"].as_array().unwrap().len(), 4);
        assert!(new_map(&p, &g, &spec).is_err(), "one map by that name");
        let tiles = terrain_tiles(&p);
        assert_eq!(tiles.len(), 4, "{tiles:?}");
        // the editors work on it
        let (a, b) = (32, 32);
        let wx = adt::HALF - (b as f64 * adt::TILE + 105.0);
        let wy = adt::HALF - (a as f64 * adt::TILE + 210.0);
        let v = tile_view(&p, &g, "IsleOfEmbers", a, b).unwrap();
        assert_eq!(v["heights"][0], 10.0);
        sculpt(&p, &g, "IsleOfEmbers", wx, wy, 30.0, 5.0, Brush::Raise).unwrap();
        water(&p, &g, "IsleOfEmbers", wx + 60.0, wy, 20.0, 12.0, "ocean", false).unwrap();
        let findings = check(&p, Some(&g));
        assert!(findings.iter().all(|f| f.level != crate::check::Level::Error), "{findings:?}");
        assert!(crate::data::check(&p, Some(&g)).iter().all(|f| f.level != crate::check::Level::Error), "{:?}", crate::data::check(&p, Some(&g)));
        // a dev build: the edited tile replaces the shipped one, the rest ship as they are
        let rep = crate::build::build_with(&p, Some(&g), true).unwrap();
        let mut arc = wow_mpq::Archive::open(p.build_dir().join(&rep.mpq)).unwrap();
        let t = Adt::parse(&arc.read_file("World\\Maps\\IsleOfEmbers\\IsleOfEmbers_32_32.adt").unwrap()).unwrap();
        let f = adt::to_file(wx, wy, 0.0);
        assert!(t.height_at((a, b), f[0] as f64, f[2] as f64).unwrap() > 13.0, "the hill is in the build");
        assert!(arc.read_file("World\\Maps\\IsleOfEmbers\\IsleOfEmbers.wdt").is_ok());
        let maps = crate::data::Dbc::parse(&arc.read_file("DBFilesClient\\Map.dbc").unwrap()).unwrap();
        let row = &maps.records[maps.find(id).unwrap()];
        assert_eq!((row[2], row[38]), (0, 7), "a world map with Kalimdor's loading screen");
        assert_eq!(maps.string(row[1]), "IsleOfEmbers");
        let sql = std::fs::read_to_string(p.build_dir().join("server/sql/install.sql")).unwrap();
        assert!(sql.contains("game_tele") && sql.contains("'IsleOfEmbers'"), "{sql}");
        // a subzone inside the map's own area: found by name, the pack's, its parent kept
        let whole = areas(&p, &g, "isle of embers", &[], 5).unwrap();
        let parent = whole[0]["id"].as_u64().unwrap() as u32;
        let cove = new_area(&p, "IsleOfEmbers", "Ember Cove", parent, 12).unwrap();
        let found = areas(&p, &g, "cove", &[], 5).unwrap();
        assert_eq!(found.len(), 1);
        assert_eq!((found[0]["id"].as_u64(), found[0]["parent"].as_u64(), found[0]["own"].as_bool(), found[0]["level"].as_u64()), (Some(cove as u64), Some(parent as u64), Some(true), Some(12)));
        assert_eq!(found[0]["map"].as_u64(), Some(id as u64));
        assert_eq!(areas(&p, &g, "", &[cove], 5).unwrap().len(), 1);
        assert!(new_area(&p, "IsleOfEmbers", "  ", 0, 1).is_err());
        // its settings change; a game area gets an override
        area_save(&p, &g, cove, &AreaEdit { name: Some("Ember Bay".into()), music: Some(7), faction: Some(2), ..Default::default() }).unwrap();
        let a2 = area_get(&p, &g, cove).unwrap();
        assert_eq!((a2["name"].as_str(), a2["music"].as_u64(), a2["faction"].as_u64(), a2["level"].as_u64()), (Some("Ember Bay"), Some(7), Some(2), Some(12)));
        assert!(area_save(&p, &g, cove, &AreaEdit { parent: Some(cove), ..Default::default() }).is_err());
    }

    #[test]
    fn the_games_own_doodads_hide_and_pick_up() {
        crate::test_config();
        let dir = tempfile::tempdir().unwrap();
        let p = create(dir.path().join("p"), "Hide", "Orion", Template::Empty).unwrap();
        let (a, b) = (32, 48);
        // a game tile with two trees of its own, one leaning
        let mut t = Adt::parse(&crate::adt::tests::fake_tile(a, b, 42.0)).unwrap();
        let at = |dx: f32, dz: f32| [a as f32 * adt::TILE as f32 + dx, 42.0, b as f32 * adt::TILE as f32 + dz];
        let tree = |uid, pos, rot| adt::Doodad { model: "World\\Generic\\Tree01.mdx".into(), uid, pos, rot, scale: 1536, flags: 0, extents: None, set: 0 };
        t.add_doodads((a, b), &[tree(7, at(100.0, 100.0), [10.0, 45.0, 5.0]), tree(8, at(300.0, 300.0), [0.0, 0.0, 0.0])]).unwrap();
        let game = dir.path().join("wow/Data");
        std::fs::create_dir_all(&game).unwrap();
        crate::mpqw::write(&game.join("terrain.MPQ"), &[(adt::tile_path("Azeroth", a, b), t.write()), ("World\\Generic\\Tree01.m2".into(), b"MD20".to_vec())]).unwrap();
        let g = GameData::open(dir.path().join("wow")).unwrap();
        let v = tile_view(&p, &g, "Azeroth", a, b).unwrap();
        assert_eq!(v["stock"].as_array().unwrap().len(), 2);
        // hide one: the built tile no longer draws it, but still lists it
        assert_eq!(hide_game_objects(&p, &g, "Azeroth", a, b, &[8], true).unwrap(), 1);
        assert_eq!(tile_view(&p, &g, "Azeroth", a, b).unwrap()["stock"][1]["hidden"], true);
        let out = dir.path().join("out");
        let built = Adt::parse(&emit(&p, &out, Some(&g), true).unwrap()[0].1).unwrap();
        assert_eq!(built.doodads().len(), 2);
        assert_eq!(built.drawn_uids(), vec![7]);
        // pick up the other: ours now, same place, turn, lean and size; the game's is hidden
        let pl = pick_up(&p, &g, "Azeroth", a, b, &[7]).unwrap();
        assert_eq!((pl[0].turn, pl[0].tilt, pl[0].scale), (45.0, [10.0, 5.0], 1.5));
        let built = Adt::parse(&emit(&p, &out, Some(&g), true).unwrap()[0].1).unwrap();
        assert_eq!(built.drawn_uids(), vec![pl[0].uid], "only our copy is drawn");
        let ours = built.doodads().into_iter().find(|d| d.uid == pl[0].uid).unwrap();
        assert!((ours.pos[0] - at(100.0, 100.0)[0]).abs() < 0.01 && (ours.pos[2] - at(100.0, 100.0)[2]).abs() < 0.01 && ours.rot == [10.0, 45.0, 5.0]);
        // and back
        hide_game_objects(&p, &g, "Azeroth", a, b, &[7, 8], false).unwrap();
        assert!(hidden(&p, "Azeroth", a, b).is_empty());
    }

    #[test]
    fn placements_become_tile_edits() {
        let dir = tempfile::tempdir().unwrap();
        let p = create(dir.path().join("p"), "Map Pack", "Orion", Template::Empty).unwrap();
        // a game with one Azeroth tile
        let (a, b) = (32, 48);
        let game = dir.path().join("wow/Data");
        std::fs::create_dir_all(&game).unwrap();
        let tile = crate::adt::tests::fake_tile(a, b, 42.0);
        crate::mpqw::write(&game.join("terrain.MPQ"), &[(adt::tile_path("Azeroth", a, b), tile), ("World\\Generic\\Tree01.m2".into(), b"MD20".to_vec())]).unwrap();
        let g = GameData::open(dir.path().join("wow")).unwrap();
        let wx = adt::HALF - (b as f64 * adt::TILE + 105.0);
        let wy = adt::HALF - (a as f64 * adt::TILE + 210.0);
        let pl = place(&p, Some(&g), "Azeroth", Placement { model: "World\\Generic\\Tree01.mdx".into(), x: wx, y: wy, z: 0.0, turn: 45.0, scale: 1.5, uid: 0, wmo_box: None, tilt: [0.0; 2], set: 0 }, true).unwrap();
        assert!((pl.z - 42.0).abs() < 1e-3, "snapped to the ground: {}", pl.z);
        assert!(pl.uid >= 40_000_000);
        assert!(check(&p, Some(&g)).is_empty(), "{:?}", check(&p, Some(&g)));
        let out = dir.path().join("out");
        let tiles = emit(&p, &out, Some(&g), true).unwrap();
        assert_eq!(tiles.len(), 1);
        let t = Adt::parse(&tiles[0].1).unwrap();
        let ds = t.doodads();
        assert_eq!(ds.len(), 1);
        assert_eq!((ds[0].uid, ds[0].scale, ds[0].rot[1]), (pl.uid, 1536, 45.0));
        // move it, turn it, size it: one field at a time, the rest stays
        let m = move_placement(&p, "Azeroth", pl.uid, Some(wx + 3.0), None, None, Some(400.0), Some(2.0)).unwrap();
        assert_eq!((m.x, m.y, m.turn, m.scale), (wx + 3.0, wy, 40.0, 2.0));
        assert!(move_placement(&p, "Azeroth", 1, None, None, None, None, None).is_err());
        let m = move_placement(&p, "Azeroth", pl.uid, Some(wx), None, None, Some(45.0), Some(1.5)).unwrap();
        assert_eq!((m.x, m.turn, m.scale), (wx, 45.0, 1.5));
        // a paste of two, moved together, then deleted together
        let two = place_many(&p, Some(&g), "Azeroth", vec![Placement { x: wx + 5.0, ..pl.clone() }, Placement { x: wx + 9.0, ..pl.clone() }], true).unwrap();
        assert!(two[0].uid != pl.uid && two[1].uid != two[0].uid);
        let moved = move_many(&p, "Azeroth", &[Move { uid: two[0].uid, y: Some(wy + 2.0), ..Default::default() }, Move { uid: two[1].uid, turn: Some(-90.0), ..Default::default() }]).unwrap();
        assert_eq!((moved[0].y, moved[1].turn), (wy + 2.0, 270.0));
        assert_eq!(remove_many(&p, "Azeroth", &[two[0].uid, two[1].uid]).unwrap(), 2);
        assert_eq!(load(&p).unwrap()["Azeroth"].len(), 1);
        assert!(out.join("data/world/Azeroth.json").is_file());
        let v = tile_view(&p, &g, "Azeroth", a, b).unwrap();
        assert_eq!(v["heights"].as_array().unwrap().len(), 129 * 129);
        assert_eq!(v["mine"].as_array().unwrap().len(), 1);
        // a model that isn't a doodad is refused
        assert!(place(&p, Some(&g), "Azeroth", Placement { model: "model:Nope".into(), x: wx, y: wy, z: 0.0, turn: 0.0, scale: 1.0, uid: 0, wmo_box: None, tilt: [0.0; 2], set: 0 }, false).is_err());
        // sculpt: raise a hill at the same spot, and it shows in the build and the view
        let touched = sculpt(&p, &g, "Azeroth", wx, wy, 30.0, 8.0, Brush::Raise).unwrap();
        assert_eq!(touched, vec![(a, b)]);
        let tiles = emit(&p, &out, Some(&g), true).unwrap();
        let t = Adt::parse(&tiles[0].1).unwrap();
        let f = adt::to_file(wx, wy, 0.0);
        let hgt = t.height_at((a, b), f[0] as f64, f[2] as f64).unwrap();
        assert!((hgt - 50.0).abs() < 0.6, "the hill's top: {hgt}");
        assert_eq!(t.doodads().len(), 1, "doodads still go on the reshaped tile");
        assert!(out.join("data/terrain/Azeroth").join(format!("{a}_{b}.hd")).is_file());
        // flatten back to the surroundings: smaller than before
        sculpt(&p, &g, "Azeroth", wx, wy, 60.0, 1.0, Brush::Smooth).unwrap();
        let v = tile_view(&p, &g, "Azeroth", a, b).unwrap();
        assert_eq!(v["reshaped"], true);
        // paint dirt, cut a hole, name the area
        paint(&p, &g, "Azeroth", wx, wy, 10.0, 1.0, "Tileset\\Elwynn\\ElwynnDirtBase.blp").unwrap();
        set_hole(&p, &g, "Azeroth", wx, wy, true).unwrap();
        assert_eq!(paint_area(&p, &g, "Azeroth", wx, wy, 1.0, 87).unwrap(), 1);
        assert_eq!(paint_impass(&p, &g, "Azeroth", wx, wy, 1.0, true).unwrap(), 1);
        let tiles = emit(&p, &out, Some(&g), true).unwrap();
        let t = Adt::parse(&tiles[0].1).unwrap();
        let (col, row) = adt::chunk_of((a, b), adt::to_file(wx, wy, 0.0)).unwrap();
        let ls = t.layers(col, row).unwrap();
        assert_eq!(ls.len(), 2);
        assert!(ls[1].alpha.as_ref().unwrap().iter().any(|&v| v > 200), "dirt painted in");
        assert_ne!(t.holes(col, row), 0);
        assert_eq!(t.areas()[row * 16 + col], 87);
        assert_eq!(t.doodads().len(), 1, "the doodad's reference survives the bigger chunk");
        let v = tile_view(&p, &g, "Azeroth", a, b).unwrap();
        assert!(v["ground"].as_array().unwrap().iter().any(|x| x == 2), "the view shows the dirt");
        // swap: the dirt into the chunk's own base (the two layers become one), then the base
        // for another texture over the whole tile
        let base = ls[0].texture.clone();
        assert_eq!(swap_texture(&p, &g, "Azeroth", a, b, "Tileset\\Elwynn\\ElwynnDirtBase.blp", &base, Some(&[(col, row)])).unwrap(), 1);
        let (t2, _) = current_tile(&p, &g, "Azeroth", a, b).unwrap();
        assert_eq!(t2.layers(col, row).unwrap().len(), 1, "merged into the base");
        let n = swap_texture(&p, &g, "Azeroth", a, b, &base, "Tileset\\Barrens\\BarrensBaseDirt.blp", None).unwrap();
        assert!(n > 100, "{n} chunks");
        let (t3, _) = current_tile(&p, &g, "Azeroth", a, b).unwrap();
        assert_eq!(t3.layers(3, 3).unwrap()[0].texture, "Tileset\\Barrens\\BarrensBaseDirt.blp");
        // put it back for what follows
        swap_texture(&p, &g, "Azeroth", a, b, "Tileset\\Barrens\\BarrensBaseDirt.blp", &base, None).unwrap();
        paint(&p, &g, "Azeroth", wx, wy, 10.0, 1.0, "Tileset\\Elwynn\\ElwynnDirtBase.blp").unwrap();
        // remove it from the tile, then paint it back
        assert!(remove_texture(&p, &g, "Azeroth", a, b, "Tileset\\Elwynn\\ElwynnDirtBase.blp").unwrap() >= 1);
        assert_eq!(current_tile(&p, &g, "Azeroth", a, b).unwrap().0.layers(col, row).unwrap().len(), 1);
        paint(&p, &g, "Azeroth", wx, wy, 10.0, 1.0, "Tileset\\Elwynn\\ElwynnDirtBase.blp").unwrap();
        // a pond: water at 5 yards over the ground, then half of it taken away again
        let lvl = t.height_at((a, b), f[0] as f64, f[2] as f64).unwrap() + 5.0;
        assert!(water(&p, &g, "Azeroth", wx, wy, 12.0, lvl, "water", false).unwrap() > 0);
        let tiles = emit(&p, &out, Some(&g), true).unwrap();
        let t = Adt::parse(&tiles[0].1).unwrap();
        let l = t.liquid(col, row).expect("the pond");
        assert_eq!(l.kind, adt::LiquidKind::River);
        assert!(l.verts.iter().all(|v| (v.1 as f64 - lvl).abs() < 1e-3));
        let shown = (0..64).filter(|&k| l.shown(k)).count();
        assert!(shown > 0 && l.tiles.iter().any(|t| t & 0x40 != 0), "deep enough to swim");
        assert_eq!(t.layers(col, row).unwrap().len(), 2, "the dirt is still there under the water");
        let v = tile_view(&p, &g, "Azeroth", a, b).unwrap();
        assert_eq!(v["water"][row * 16 + col]["kind"], "water");
        // angled: a strip through the pond climbing 10 yards; its surface slopes
        assert!(water_slope(&p, &g, "Azeroth", [wx, wy - 30.0, lvl], [wx, wy + 30.0, lvl + 10.0], 12.0, "water").unwrap() > 0);
        let (ts, _) = current_tile(&p, &g, "Azeroth", a, b).unwrap();
        let l = ts.liquid(col, row).unwrap();
        let (lo, hi) = l.verts.iter().fold((f32::MAX, f32::MIN), |(x, y), v| (x.min(v.1), y.max(v.1)));
        assert!(hi - lo > 1.0, "the surface slopes: {lo}..{hi}");
        assert!(tile_view(&p, &g, "Azeroth", a, b).unwrap()["water"][row * 16 + col]["heights"].as_array().map(|h| h.len()) == Some(81));
        // crop: the ground raised well over the water, then cropped: the tiles there go
        let before = (0..64).filter(|&k| l.shown(k)).count();
        for _ in 0..6 {
            sculpt(&p, &g, "Azeroth", wx, wy, 30.0, 10.0, Brush::Raise).unwrap();
        }
        assert!(water_crop(&p, &g, "Azeroth", wx, wy, 60.0).unwrap() > 0);
        let after = (0..64).filter(|&k| current_tile(&p, &g, "Azeroth", a, b).unwrap().0.liquid(col, row).unwrap().shown(k)).count();
        assert!(after < before, "cropped {before} → {after}");
        water(&p, &g, "Azeroth", wx, wy, 60.0, 0.0, "water", true).unwrap();
        let tiles = emit(&p, &out, Some(&g), true).unwrap();
        assert!(Adt::parse(&tiles[0].1).unwrap().liquid(col, row).is_none(), "drained");
        remove(&p, "Azeroth", pl.uid).unwrap();
        assert!(load(&p).unwrap()["Azeroth"].is_empty());
    }
}
