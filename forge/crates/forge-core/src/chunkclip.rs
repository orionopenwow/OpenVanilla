//! Copy a block of map chunks (the ground's shape, its textures, water, holes, zone and
//! impassable marks) and paste it anywhere, turned a quarter at a time or mirrored. The clip
//! lives in the project (`.forge/chunkclip.json`) so it survives a restart and crosses maps.

use crate::adt;
use crate::project::Project;
use crate::vfs::GameData;
use crate::world::{self, ChunkEdit, LayerData, WaterData};
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

const CLIP: &str = ".forge/chunkclip.json";
/// Half a vertex step: outer vertices sit on even half-steps, inner ones on odd.
const HS: f64 = adt::CHUNK / 16.0;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Clip {
    pub map: String,
    /// The block's size in chunks.
    pub w: usize,
    pub h: usize,
    /// Heights over the block in half-steps, row by row: (w·16 + 1) × (h·16 + 1); only the
    /// vertex positions (both even or both odd) mean anything.
    pub heights: Vec<f32>,
    /// Per chunk, row by row: w × h.
    pub chunks: Vec<ClipChunk>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ClipChunk {
    pub layers: Vec<LayerData>,
    pub holes: u32,
    pub area: u32,
    pub impass: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub water: Option<WaterData>,
}

/// What to paste, how the block is turned, and how its heights sit.
#[derive(Debug, Clone, Deserialize)]
pub struct Paste {
    pub map: String,
    /// The world point the block's middle lands on (snapped to whole chunks).
    pub x: f64,
    pub y: f64,
    /// Quarter turns (0–3) and a mirror (left for right).
    #[serde(default)]
    pub turn: u8,
    #[serde(default)]
    pub mirror: bool,
    #[serde(default = "yes")]
    pub heights: bool,
    #[serde(default = "yes")]
    pub textures: bool,
    #[serde(default = "yes")]
    pub water: bool,
    #[serde(default = "yes")]
    pub holes: bool,
    #[serde(default)]
    pub area: bool,
    #[serde(default)]
    pub impass: bool,
    /// Heights as they were (true) or fitted to the ground here: the block's average height
    /// moved to the average of the ground it lands on (false, the default).
    #[serde(default)]
    pub absolute: bool,
}

fn yes() -> bool {
    true
}

/// Where a point of the pasted block (x, z in a box w × h) comes from in the copied block:
/// undo the quarter turns, then the mirror. Works for half-steps and for cells alike.
fn source(mut x: i64, mut z: i64, mut w: i64, mut h: i64, turn: u8, mirror: bool) -> (i64, i64) {
    for _ in 0..turn % 4 {
        // one turn took (x, z) in W × H to (H − z, x) in H × W
        let (sx, sz) = (z, w - x);
        (x, z, w, h) = (sx, sz, h, w);
    }
    if mirror {
        x = w - x;
    }
    (x, z)
}

/// The same for a cell of an n × n grid (alpha maps, water tiles, holes): cells are boxes, so
/// their far edge is n − 1.
fn cell(x: usize, z: usize, n: usize, turn: u8, mirror: bool) -> (usize, usize) {
    let (sx, sz) = source(x as i64, z as i64, n as i64 - 1, n as i64 - 1, turn, mirror);
    (sx as usize, sz as usize)
}

fn clip_path(p: &Project) -> std::path::PathBuf {
    p.root.join(CLIP)
}

pub fn load(p: &Project) -> Result<Clip> {
    Ok(serde_json::from_slice(&std::fs::read(clip_path(p)).context("nothing copied yet: select chunks and Copy first")?)?)
}

/// What's on the clipboard, without the bulk.
pub fn info(p: &Project) -> serde_json::Value {
    match load(p) {
        Ok(c) => serde_json::json!({"map": c.map, "w": c.w, "h": c.h, "water": c.chunks.iter().any(|x| x.water.is_some()), "holes": c.chunks.iter().any(|x| x.holes != 0)}),
        Err(_) => serde_json::Value::Null,
    }
}

/// Copy the chunks of a box between two world points (both corners included).
pub fn copy(p: &Project, g: &GameData, map: &str, from: [f64; 2], to: [f64; 2]) -> Result<Clip> {
    let (fa, fb) = (adt::to_file(from[0], from[1], 0.0), adt::to_file(to[0], to[1], 0.0));
    let gc = |v: f32| (v as f64 / adt::CHUNK).floor() as i64;
    let (cx0, cx1) = (gc(fa[0]).min(gc(fb[0])), gc(fa[0]).max(gc(fb[0])));
    let (cz0, cz1) = (gc(fa[2]).min(gc(fb[2])), gc(fa[2]).max(gc(fb[2])));
    let (w, h) = ((cx1 - cx0 + 1) as usize, (cz1 - cz0 + 1) as usize);
    if w * h > 256 {
        bail!("copy up to 256 chunks at a time (that's {w} × {h})");
    }
    let (gw, gh) = (w * 16 + 1, h * 16 + 1);
    let mut heights = vec![0f32; gw * gh];
    let mut chunks = vec![ClipChunk::default(); w * h];
    let mut tiles: BTreeMap<(i32, i32), adt::Adt> = BTreeMap::new();
    for cz in cz0..=cz1 {
        for cx in cx0..=cx1 {
            let (ta, tb) = (cx.div_euclid(16) as i32, cz.div_euclid(16) as i32);
            let (col, row) = (cx.rem_euclid(16) as usize, cz.rem_euclid(16) as usize);
            if !tiles.contains_key(&(ta, tb)) {
                let (t, _) = world::current_tile(p, g, map, ta, tb).with_context(|| format!("{map} has no tile {ta}_{tb} there"))?;
                tiles.insert((ta, tb), t);
            }
            let t = &tiles[&(ta, tb)];
            let hs = t.chunk_heights(col, row).context("map chunk missing")?;
            let (ox, oz) = (((cx - cx0) * 16) as usize, ((cz - cz0) * 16) as usize);
            for (k, v) in hs.iter().enumerate() {
                let (i, j) = (k / 17, k % 17);
                let (hx, hz) = if j < 9 { (j * 2, i * 2) } else { ((j - 9) * 2 + 1, i * 2 + 1) };
                heights[(oz + hz) * gw + ox + hx] = *v;
            }
            let c = &mut chunks[(cz - cz0) as usize * w + (cx - cx0) as usize];
            c.layers = world::from_layers_pub(&t.layers(col, row).unwrap_or_default());
            c.holes = t.holes(col, row);
            c.area = t.areas()[row * 16 + col];
            c.impass = t.impass(col, row);
            c.water = t.liquid(col, row).map(|l| WaterData::from_liquid_pub(&l));
        }
    }
    let clip = Clip { map: map.into(), w, h, heights, chunks };
    let f = clip_path(p);
    std::fs::create_dir_all(f.parent().unwrap())?;
    std::fs::write(f, serde_json::to_vec(&clip)?)?;
    Ok(clip)
}

fn turn_alpha(a: &[u8], turn: u8, mirror: bool) -> Vec<u8> {
    let mut out = vec![0u8; 4096];
    for z in 0..64 {
        for x in 0..64 {
            let (sx, sz) = cell(x, z, 64, turn, mirror);
            out[z * 64 + x] = a[sz * 64 + sx];
        }
    }
    out
}

fn turn_holes(hl: u32, turn: u8, mirror: bool) -> u32 {
    let mut out = 0;
    for z in 0..4 {
        for x in 0..4 {
            let (sx, sz) = cell(x, z, 4, turn, mirror);
            if hl & (1 << (sz * 4 + sx)) != 0 {
                out |= 1 << (z * 4 + x);
            }
        }
    }
    out
}

/// Paste the clip with its middle at (x, y). Returns the tiles changed.
pub fn paste(p: &Project, g: &GameData, ps: &Paste) -> Result<Vec<(i32, i32)>> {
    use base64::Engine;
    let b64 = base64::engine::general_purpose::STANDARD;
    let clip = load(p)?;
    let (turn, mirror) = (ps.turn % 4, ps.mirror);
    let (w, h) = if turn % 2 == 1 { (clip.h, clip.w) } else { (clip.w, clip.h) };
    let gw = clip.w * 16 + 1;
    // the block's corner chunk, so its middle is nearest the point
    let c = adt::to_file(ps.x, ps.y, 0.0);
    let cx0 = (c[0] as f64 / adt::CHUNK - w as f64 / 2.0).round() as i64;
    let cz0 = (c[2] as f64 / adt::CHUNK - h as f64 / 2.0).round() as i64;
    let (x0, z0) = (cx0 as f64 * adt::CHUNK, cz0 as f64 * adt::CHUNK);
    let (bw, bh) = ((w * 16) as i64, (h * 16) as i64);
    let src_h = |hx: i64, hz: i64| -> f32 {
        let (sx, sz) = source(hx, hz, bw, bh, turn, mirror);
        clip.heights[sz as usize * gw + sx as usize]
    };
    let mut tiles: Vec<(i32, i32)> = vec![];
    for cz in cz0..cz0 + h as i64 {
        for cx in cx0..cx0 + w as i64 {
            let t = (cx.div_euclid(16) as i32, cz.div_euclid(16) as i32);
            if !tiles.contains(&t) {
                tiles.push(t);
            }
        }
    }
    tiles.retain(|(a, b)| world::has_world(p, g, &adt::tile_path(&ps.map, *a, *b)));
    if tiles.is_empty() {
        bail!("{} has no tiles there", ps.map);
    }
    // the height shift: the block's average onto the average of the ground it lands on
    let mut shift = 0.0f64;
    if !ps.absolute {
        let (mut src, mut dst, mut n) = (0.0, 0.0, 0usize);
        for (ta, tb) in &tiles {
            let (t, _) = world::current_tile(p, g, &ps.map, *ta, *tb)?;
            for row in 0..16 {
                for col in 0..16 {
                    let (gx, gz) = (*ta as i64 * 16 + col as i64, *tb as i64 * 16 + row as i64);
                    if gx < cx0 || gz < cz0 || gx >= cx0 + w as i64 || gz >= cz0 + h as i64 {
                        continue;
                    }
                    let hs = t.chunk_heights(col, row).context("map chunk missing")?;
                    for k in (0..145).step_by(4) {
                        let (vx, vz) = adt::vertex_xz((*ta, *tb), col, row, k);
                        let (hx, hz) = (((vx - x0) / HS).round() as i64, ((vz - z0) / HS).round() as i64);
                        dst += hs[k] as f64;
                        src += src_h(hx, hz) as f64;
                        n += 1;
                    }
                }
            }
        }
        if n > 0 {
            shift = (dst - src) / n as f64;
        }
    }
    for (ta, tb) in &tiles {
        if ps.heights {
            crate::kit::reshape_tile(p, g, &ps.map, *ta, *tb, &|vx, vz, _now| {
                let (fx, fz) = ((vx - x0) / HS, (vz - z0) / HS);
                let (hx, hz) = (fx.round() as i64, fz.round() as i64);
                if hx < 0 || hz < 0 || hx > bw || hz > bh || (fx - hx as f64).abs() > 0.01 || (fz - hz as f64).abs() > 0.01 {
                    return None;
                }
                Some(src_h(hx, hz) as f64 + shift)
            })?;
        }
        let (t, mut edits) = world::current_tile(p, g, &ps.map, *ta, *tb)?;
        let mut any = false;
        for row in 0..16 {
            for col in 0..16 {
                let (gx, gz) = (*ta as i64 * 16 + col as i64, *tb as i64 * 16 + row as i64);
                if gx < cx0 || gz < cz0 || gx >= cx0 + w as i64 || gz >= cz0 + h as i64 {
                    continue;
                }
                // the chunk's source: its middle, taken back through the turn
                let (mx, mz) = source((gx - cx0) * 16 + 8, (gz - cz0) * 16 + 8, bw, bh, turn, mirror);
                let src = &clip.chunks[(mz / 16) as usize * clip.w + (mx / 16) as usize];
                let e: &mut ChunkEdit = edits.entry(format!("{col}_{row}")).or_default();
                if ps.textures {
                    let mut ls = src.layers.clone();
                    for l in ls.iter_mut() {
                        if let Some(a) = l.alpha.as_ref().and_then(|a| b64.decode(a).ok()).filter(|a| a.len() == 4096) {
                            l.alpha = Some(b64.encode(turn_alpha(&a, turn, mirror)));
                        }
                    }
                    e.layers = Some(ls);
                }
                if ps.holes {
                    e.holes = Some(turn_holes(src.holes, turn, mirror));
                }
                if ps.area {
                    e.area = Some(src.area);
                }
                if ps.impass {
                    e.impass = Some(src.impass);
                }
                if ps.water {
                    e.water = match &src.water {
                        Some(wd) => {
                            let mut n = wd.clone();
                            let hs: Vec<f32> = (0..81).map(|k| {
                                let (sx, sz) = cell(k % 9, k / 9, 9, turn, mirror);
                                wd.heights[sz * 9 + sx] + shift as f32
                            }).collect();
                            let tl: Vec<String> = (0..64).map(|k| {
                                let (sx, sz) = cell(k % 8, k / 8, 8, turn, mirror);
                                wd.tiles[(sz * 8 + sx) * 2..(sz * 8 + sx) * 2 + 2].to_string()
                            }).collect();
                            n.heights = hs;
                            n.tiles = tl.concat();
                            n.info = None;
                            n.flow = None;
                            Some(n)
                        }
                        // no water in the copy: none here either (all tiles off)
                        None => t.liquid(col, row).map(|l| {
                            let mut d = WaterData::from_liquid_pub(&l);
                            d.tiles = "0f".repeat(64);
                            d
                        }),
                    };
                }
                any = true;
            }
        }
        if any {
            world::save_chunks_pub(p, &ps.map, *ta, *tb, &edits)?;
        }
    }
    Ok(tiles)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn turns_undo_and_round_trip() {
        // a quarter turn of a 2 × 1 box: (0,0) lands at (1,0), so the source of (1,0) is (0,0)
        assert_eq!(source(1, 0, 1, 2, 1, false), (0, 0));
        // four turns are none
        for (x, z) in [(0, 0), (3, 1), (5, 7)] {
            assert_eq!(source(x, z, 8, 8, 4, false), (x, z));
        }
        assert_eq!(source(0, 3, 8, 5, 0, true), (8, 3));
        let holes = 0b0000_0000_0000_0001; // the first cell
        assert_eq!(turn_holes(holes, 2, false), 1 << 15, "a half turn takes the first cell to the last");
        assert_eq!(turn_holes(turn_holes(holes, 1, true), 1, true), holes, "mirrored quarter turns twice: back");
    }

    #[test]
    fn a_block_copies_and_pastes_turned() {
        crate::test_config();
        let dir = tempfile::tempdir().unwrap();
        let p = crate::project::create(dir.path().join("p"), "Clip", "Tester", crate::project::Template::Empty).unwrap();
        let game = dir.path().join("wow/Data");
        std::fs::create_dir_all(&game).unwrap();
        crate::mpqw::write(&game.join("terrain.MPQ"), &[(adt::tile_path("Azeroth", 32, 48), crate::adt::tests::fake_tile(32, 48, 42.0))]).unwrap();
        let g = GameData::open(dir.path().join("wow")).unwrap();
        // the tile's corner chunk in world terms, and a world point at chunk (cx, cz) + (fx, fz)
        let at = |cx: f64, cz: f64| (adt::HALF - (48.0 * adt::TILE + cz * adt::CHUNK), adt::HALF - (32.0 * adt::TILE + cx * adt::CHUNK));
        // a bump in chunk (2, 2), then a hole there
        let (bx, by) = at(2.5, 2.5);
        world::sculpt(&p, &g, "Azeroth", bx, by, 12.0, 30.0, world::Brush::Raise).unwrap();
        world::set_hole(&p, &g, "Azeroth", bx, by, true).unwrap();
        let ground = |cx: f64, cz: f64| {
            let (t, _) = world::current_tile(&p, &g, "Azeroth", 32, 48).unwrap();
            t.height_at((32, 48), 32.0 * adt::TILE + cx * adt::CHUNK, 48.0 * adt::TILE + cz * adt::CHUNK).unwrap()
        };
        let bump = ground(2.5, 2.5);
        assert!(bump > 45.0);
        // copy chunks (2..=3, 2..=2): two wide, one deep
        let (a0, a1) = (at(2.2, 2.2), at(3.8, 2.8));
        let c = copy(&p, &g, "Azeroth", [a0.0, a0.1], [a1.0, a1.1]).unwrap();
        assert_eq!((c.w, c.h), (2, 1));
        assert_eq!(info(&p)["holes"], true);
        // paste a quarter turn round at chunk (8..9, 8..10): one wide, two deep; heights as they were
        let (px, py) = at(9.0, 9.0);
        paste(&p, &g, &Paste { map: "Azeroth".into(), x: px, y: py, turn: 1, mirror: false, heights: true, textures: true, water: true, holes: true, area: false, impass: false, absolute: true }).unwrap();
        let tops: Vec<f64> = [(8.5, 8.5), (8.5, 9.5)].iter().map(|(x, z)| ground(*x, *z)).collect();
        assert!(tops.iter().any(|h| (h - bump).abs() < 1.0), "the bump came along: {tops:?} vs {bump}");
        assert!(tops.iter().any(|h| (h - 42.0).abs() < 1.0), "and the flat chunk beside it");
        let (t, _) = world::current_tile(&p, &g, "Azeroth", 32, 48).unwrap();
        assert!(t.holes(8, 8) != 0 || t.holes(8, 9) != 0, "the hole came along");
        assert_eq!(ground(12.5, 12.5), 42.0, "nothing else moved");
    }
}
