//! World kit: the bigger brushes.
//!
//! * **Heightmaps**: a tile's ground out as a 16-bit greyscale PNG, and a picture in as ground
//!   (one tile, or a block of tiles from one picture), for World Machine, Gaea or real elevation.
//! * **Scatter**: paint trees, rocks and props into a circle with rules (how many, how far apart,
//!   no steeper than, random turn and size); shift-click clears the pack's own doodads there.
//! * **Prefabs**: a box of the pack's doodads and spawns saved as one piece (`prefabs/<name>.json`),
//!   stamped anywhere, turned, on the ground, optionally levelling the ground under it.
//! * **Roads**: a line of points becomes a road: the ground smoothed along it and painted.

use crate::adt::{self, Adt};
use crate::project::Project;
use crate::vfs::GameData;
use crate::world::{self, load_delta, read_world, Placement};
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// A tiny, seeded random source (xorshift): the same seed scatters the same way.
pub struct Rng(u64);
impl Rng {
    pub fn new(seed: u64) -> Self {
        Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1)
    }
    pub fn next(&mut self) -> f64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        (self.0 >> 11) as f64 / (1u64 << 53) as f64
    }
    pub fn range(&mut self, lo: f64, hi: f64) -> f64 {
        lo + (hi - lo) * self.next()
    }
}

/// The tile as it is now (stock + the pack's height edits), and its height delta.
fn tile_now(p: &Project, g: &GameData, map: &str, a: i32, b: i32) -> Result<(Adt, Vec<f32>)> {
    let mut t = Adt::parse(&read_world(p, g, &adt::tile_path(map, a, b)).with_context(|| format!("{map} has no tile {a}_{b}"))?)?;
    let d = load_delta(p, map, a, b)?.unwrap_or_else(|| vec![0.0; world::DELTA_LEN]);
    world::apply_delta(&mut t, (a, b), &d)?;
    Ok((t, d))
}

/// Move every vertex of a tile toward `target(file x, file z, height now)` (None: leave it).
/// Vertices on chunk and tile edges are reached by position, so both copies move alike.
pub fn reshape_tile(p: &Project, g: &GameData, map: &str, a: i32, b: i32, target: &dyn Fn(f64, f64, f64) -> Option<f64>) -> Result<usize> {
    let (t, mut d) = tile_now(p, g, map, a, b)?;
    let mut n = 0;
    for row in 0..16 {
        for col in 0..16 {
            let hs = t.chunk_heights(col, row).context("map chunk missing")?;
            for (k, h) in hs.iter().enumerate() {
                let (vx, vz) = adt::vertex_xz((a, b), col, row, k);
                if let Some(want) = target(vx, vz, *h as f64) {
                    let change = (want - *h as f64) as f32;
                    if change.abs() > 1e-4 {
                        d[(row * 16 + col) * 145 + k] += change;
                        n += 1;
                    }
                }
            }
        }
    }
    world::save_delta_pub(p, map, a, b, &d)?;
    Ok(n)
}

// ---------------------------------------------------------------- ramps and stamps

/// The tiles a box of file coordinates reaches, that the map has.
fn tiles_in(p: &Project, g: &GameData, map: &str, x0: f64, z0: f64, x1: f64, z1: f64) -> Vec<(i32, i32)> {
    let mut v = vec![];
    for a in (x0 / adt::TILE).floor() as i32..=(x1 / adt::TILE).floor() as i32 {
        for b in (z0 / adt::TILE).floor() as i32..=(z1 / adt::TILE).floor() as i32 {
            if world::has_world(p, g, &adt::tile_path(map, a, b)) {
                v.push((a, b));
            }
        }
    }
    v
}

/// A ramp: a straight slope from one point to another (world x, y), `width` yards across with a
/// soft edge. The ends keep the ground's height there unless given (`from_z`, `to_z`).
#[derive(Debug, Clone, Deserialize)]
pub struct Ramp {
    pub map: String,
    pub from: [f64; 2],
    pub to: [f64; 2],
    #[serde(default)]
    pub from_z: Option<f64>,
    #[serde(default)]
    pub to_z: Option<f64>,
    #[serde(default = "ramp_width")]
    pub width: f64,
}

fn ramp_width() -> f64 {
    10.0
}

pub fn ramp(p: &Project, g: &GameData, r: &Ramp) -> Result<Vec<(i32, i32)>> {
    if !(2.0..=80.0).contains(&r.width) {
        bail!("a ramp is 2 to 80 yards wide");
    }
    let (a, b) = (adt::to_file(r.from[0], r.from[1], 0.0), adt::to_file(r.to[0], r.to[1], 0.0));
    let (ax, az, bx, bz) = (a[0] as f64, a[2] as f64, b[0] as f64, b[2] as f64);
    let len2 = (bx - ax).powi(2) + (bz - az).powi(2);
    if len2 < 1.0 {
        bail!("a ramp needs two different points");
    }
    let ground = |x: f64, z: f64| -> Result<f64> {
        let (ta, tb) = ((x / adt::TILE).floor() as i32, (z / adt::TILE).floor() as i32);
        tile_now(p, g, &r.map, ta, tb).ok().and_then(|(t, _)| t.height_at((ta, tb), x, z)).context("the ramp leaves the map's tiles")
    };
    let h0 = match r.from_z { Some(z) => z, None => ground(ax, az)? };
    let h1 = match r.to_z { Some(z) => z, None => ground(bx, bz)? };
    let half = r.width / 2.0;
    let feather = half.max(4.0);
    let reach = half + feather;
    let tiles = tiles_in(p, g, &r.map, ax.min(bx) - reach, az.min(bz) - reach, ax.max(bx) + reach, az.max(bz) + reach);
    for (ta, tb) in &tiles {
        reshape_tile(p, g, &r.map, *ta, *tb, &|vx, vz, now| {
            let t = ((vx - ax) * (bx - ax) + (vz - az) * (bz - az)) / len2;
            if !(-0.02..=1.02).contains(&t) {
                return None;
            }
            let tc = t.clamp(0.0, 1.0);
            let (px, pz) = (ax + (bx - ax) * tc, az + (bz - az) * tc);
            let d = (vx - px).hypot(vz - pz);
            if d > reach {
                return None;
            }
            let w = if d <= half { 1.0 } else { 0.5 * (1.0 + (std::f64::consts::PI * (d - half) / feather).cos()) };
            let want = h0 + (h1 - h0) * tc;
            Some(now + (want - now) * w)
        })?;
    }
    Ok(tiles)
}

/// A stamp: a greyscale picture pressed into the ground at (x, y), `radius` yards from its middle
/// to its sides, turned `turn` degrees; white raises (or lowers) by `strength` yards.
#[derive(Debug, Clone, Deserialize)]
pub struct Stamp {
    pub map: String,
    pub x: f64,
    pub y: f64,
    pub radius: f64,
    pub strength: f64,
    #[serde(default)]
    pub turn: f64,
    #[serde(default)]
    pub lower: bool,
    /// The picture (PNG/TGA/JPEG bytes, base64).
    pub image: String,
}

pub fn stamp_image(p: &Project, g: &GameData, s: &Stamp) -> Result<Vec<(i32, i32)>> {
    use base64::Engine;
    if !(2.0..=300.0).contains(&s.radius) {
        bail!("a stamp is 2 to 300 yards from its middle to its side");
    }
    let bytes = base64::engine::general_purpose::STANDARD.decode(s.image.trim()).context("the picture isn't base64")?;
    let img = image::load_from_memory(&bytes).context("that isn't a picture Forge can read (PNG, TGA, JPEG)")?.to_luma16();
    let (w, h) = img.dimensions();
    let lum = |u: f64, v: f64| -> f64 {
        let (x, y) = (u * (w - 1) as f64, v * (h - 1) as f64);
        let (x0, y0) = (x.floor() as u32, y.floor() as u32);
        let (x1, y1) = ((x0 + 1).min(w - 1), (y0 + 1).min(h - 1));
        let (fx, fy) = (x - x0 as f64, y - y0 as f64);
        let p = |x: u32, y: u32| img.get_pixel(x, y)[0] as f64 / 65535.0;
        (p(x0, y0) * (1.0 - fx) + p(x1, y0) * fx) * (1.0 - fy) + (p(x0, y1) * (1.0 - fx) + p(x1, y1) * fx) * fy
    };
    let c = adt::to_file(s.x, s.y, 0.0);
    let (cx, cz) = (c[0] as f64, c[2] as f64);
    let r = s.radius * std::f64::consts::SQRT_2;
    let (sn, cs) = (s.turn.to_radians().sin(), s.turn.to_radians().cos());
    let sign = if s.lower { -1.0 } else { 1.0 };
    let tiles = tiles_in(p, g, &s.map, cx - r, cz - r, cx + r, cz + r);
    for (ta, tb) in &tiles {
        reshape_tile(p, g, &s.map, *ta, *tb, &|vx, vz, now| {
            let (dx, dz) = (vx - cx, vz - cz);
            let (lx, lz) = (dx * cs + dz * sn, -dx * sn + dz * cs);
            let (u, v) = (lx / s.radius * 0.5 + 0.5, lz / s.radius * 0.5 + 0.5);
            if !(0.0..=1.0).contains(&u) || !(0.0..=1.0).contains(&v) {
                return None;
            }
            Some(now + sign * s.strength * lum(u, v))
        })?;
    }
    Ok(tiles)
}

// ---------------------------------------------------------------- fields (scripts)

/// A height field from a script: target heights on a regular grid in file coordinates (corner
/// `fx`, `fz`, `step` yards apart, `w` × `h` values row by row; NaN or null = leave the ground).
/// Each vertex in the grid moves to the field there (bilinear), `blend` of the way.
#[derive(Debug, Clone, Deserialize)]
pub struct Field {
    pub map: String,
    pub fx: f64,
    pub fz: f64,
    pub step: f64,
    pub w: usize,
    pub h: usize,
    pub values: Vec<Option<f64>>,
    #[serde(default = "one")]
    pub blend: f64,
}

pub fn field(p: &Project, g: &GameData, f: &Field) -> Result<Vec<(i32, i32)>> {
    if f.w < 2 || f.h < 2 || f.values.len() != f.w * f.h {
        bail!("a field is w × h values, 2 × 2 or more");
    }
    if f.w * f.h > 400_000 || !(0.5..=50.0).contains(&f.step) {
        bail!("a field is at most 400,000 values, 0.5 to 50 yards apart");
    }
    let blend = f.blend.clamp(0.0, 1.0);
    let (x1, z1) = (f.fx + (f.w - 1) as f64 * f.step, f.fz + (f.h - 1) as f64 * f.step);
    let tiles = tiles_in(p, g, &f.map, f.fx, f.fz, x1, z1);
    let at = |i: usize, j: usize| f.values[j * f.w + i].filter(|v| v.is_finite());
    for (ta, tb) in &tiles {
        reshape_tile(p, g, &f.map, *ta, *tb, &|vx, vz, now| {
            let (u, v) = ((vx - f.fx) / f.step, (vz - f.fz) / f.step);
            if u < -1e-6 || v < -1e-6 || u > (f.w - 1) as f64 + 1e-6 || v > (f.h - 1) as f64 + 1e-6 {
                return None;
            }
            let (i, j) = ((u.floor() as usize).min(f.w - 2), (v.floor() as usize).min(f.h - 2));
            let (du, dv) = (u - i as f64, v - j as f64);
            // the corners that count (a point right on the grid needs only its own value)
            let mut want = 0.0;
            for (ii, jj, wgt) in [(i, j, (1.0 - du) * (1.0 - dv)), (i + 1, j, du * (1.0 - dv)), (i, j + 1, (1.0 - du) * dv), (i + 1, j + 1, du * dv)] {
                if wgt > 1e-6 {
                    want += at(ii, jj)? * wgt;
                }
            }
            Some(now + (want - now) * blend)
        })?;
    }
    Ok(tiles)
}

// ---------------------------------------------------------------- scripts

/// The pack's own World scripts: `world_scripts/<name>.js`, small JavaScript that drives the
/// World tools (Forge runs them in its window; see the samples in the Script tool).
fn scripts_dir(p: &Project) -> std::path::PathBuf {
    p.root.join("world_scripts")
}

fn script_name(name: &str) -> Result<String> {
    let n: String = name.trim().chars().filter(|c| c.is_alphanumeric() || " -_".contains(*c)).collect::<String>().trim().to_string();
    if n.is_empty() || n.len() > 60 {
        bail!("a script's name is 1 to 60 letters, numbers, spaces, - or _");
    }
    Ok(n)
}

pub fn scripts(p: &Project) -> Vec<serde_json::Value> {
    let mut v: Vec<serde_json::Value> = std::fs::read_dir(scripts_dir(p))
        .into_iter()
        .flatten()
        .filter_map(|e| e.ok())
        .filter_map(|e| {
            let path = e.path();
            if path.extension()? != "js" {
                return None;
            }
            Some(serde_json::json!({"name": path.file_stem()?.to_string_lossy(), "code": std::fs::read_to_string(&path).ok()?}))
        })
        .collect();
    v.sort_by(|a, b| a["name"].as_str().cmp(&b["name"].as_str()));
    v
}

pub fn script_save(p: &Project, name: &str, code: &str) -> Result<String> {
    let n = script_name(name)?;
    if code.len() > 200_000 {
        bail!("a script is at most 200 KB");
    }
    std::fs::create_dir_all(scripts_dir(p))?;
    std::fs::write(scripts_dir(p).join(format!("{n}.js")), code)?;
    Ok(n)
}

pub fn script_remove(p: &Project, name: &str) -> Result<()> {
    std::fs::remove_file(scripts_dir(p).join(format!("{}.js", script_name(name)?))).context("no script by that name")?;
    Ok(())
}

// ---------------------------------------------------------------- bookmarks

/// Spots in the world to go back to (the map, the tile, the view): the pack's own list.
fn bookmarks_path(p: &Project) -> std::path::PathBuf {
    p.root.join(".forge").join("bookmarks.json")
}

pub fn bookmarks(p: &Project) -> serde_json::Value {
    std::fs::read(bookmarks_path(p)).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_else(|| serde_json::json!([]))
}

pub fn bookmarks_save(p: &Project, list: &serde_json::Value) -> Result<()> {
    let arr = list.as_array().context("bookmarks are a list")?;
    if arr.len() > 200 {
        bail!("200 bookmarks at most");
    }
    for b in arr {
        if b["name"].as_str().is_none_or(|n| n.trim().is_empty() || n.len() > 80) || b["map"].as_str().is_none() {
            bail!("a bookmark has a name (up to 80 letters) and a map");
        }
    }
    let f = bookmarks_path(p);
    std::fs::create_dir_all(f.parent().unwrap())?;
    std::fs::write(f, serde_json::to_vec_pretty(list)?)?;
    Ok(())
}

// ---------------------------------------------------------------- heightmaps

/// A tile's ground as a 16-bit PNG (its 129 × 129 outer vertices; black = `lo`, white = `hi`).
pub fn export_heightmap(p: &Project, g: &GameData, map: &str, a: i32, b: i32) -> Result<serde_json::Value> {
    let (t, _) = tile_now(p, g, map, a, b)?;
    let hm = t.heightmap();
    let (lo, hi) = hm.iter().fold((f32::MAX, f32::MIN), |(l, h), v| (l.min(*v), h.max(*v)));
    let span = (hi - lo).max(0.01);
    let img = image::ImageBuffer::<image::Luma<u16>, Vec<u16>>::from_fn(129, 129, |x, y| image::Luma([(((hm[(y * 129 + x) as usize] - lo) / span) * 65535.0).round() as u16]));
    let mut out = std::io::Cursor::new(Vec::new());
    image::DynamicImage::ImageLuma16(img).write_to(&mut out, image::ImageFormat::Png)?;
    use base64::Engine;
    Ok(serde_json::json!({"png": base64::engine::general_purpose::STANDARD.encode(out.into_inner()), "lo": lo, "hi": hi, "name": format!("{map}_{a}_{b}_height.png")}))
}

#[derive(Debug, Clone, Deserialize)]
pub struct HeightImport {
    pub map: String,
    /// The block of tiles the picture covers: [a0, b0] to [a1, b1] inclusive (one tile: the same).
    pub from: [i32; 2],
    pub to: [i32; 2],
    /// Heights black and white stand for.
    pub lo: f64,
    pub hi: f64,
    /// 0–1: how much of the way to go (1 = exactly the picture).
    #[serde(default = "one")]
    pub strength: f64,
}
fn one() -> f64 {
    1.0
}

/// A picture (8- or 16-bit greyscale, or colour read as grey) as the ground of a block of tiles.
pub fn import_heightmap(p: &Project, g: &GameData, png: &[u8], spec: &HeightImport) -> Result<serde_json::Value> {
    let img = image::load_from_memory(png).context("not a picture Forge can read (PNG or TGA)")?.to_luma16();
    let (w, h) = (img.width() as f64, img.height() as f64);
    let (a0, b0) = (spec.from[0].min(spec.to[0]), spec.from[1].min(spec.to[1]));
    let (a1, b1) = (spec.from[0].max(spec.to[0]), spec.from[1].max(spec.to[1]));
    if (a1 - a0 + 1) * (b1 - b0 + 1) > 64 {
        bail!("up to 8 × 8 tiles in one picture");
    }
    let (x0, z0) = (a0 as f64 * adt::TILE, b0 as f64 * adt::TILE);
    let (sx, sz) = ((a1 - a0 + 1) as f64 * adt::TILE, (b1 - b0 + 1) as f64 * adt::TILE);
    let sample = |fx: f64, fz: f64| -> f64 {
        // bilinear, the picture's corners on the block's corners
        let u = ((fx - x0) / sx * (w - 1.0)).clamp(0.0, w - 1.0);
        let v = ((fz - z0) / sz * (h - 1.0)).clamp(0.0, h - 1.0);
        let (ix, iy) = (u.floor() as u32, v.floor() as u32);
        let (jx, jy) = ((ix + 1).min(img.width() - 1), (iy + 1).min(img.height() - 1));
        let (tx, ty) = (u - ix as f64, v - iy as f64);
        let px = |x: u32, y: u32| img.get_pixel(x, y)[0] as f64 / 65535.0;
        let top = px(ix, iy) * (1.0 - tx) + px(jx, iy) * tx;
        let bot = px(ix, jy) * (1.0 - tx) + px(jx, jy) * tx;
        top * (1.0 - ty) + bot * ty
    };
    let k = spec.strength.clamp(0.0, 1.0);
    let mut tiles = 0;
    let mut missing = vec![];
    for a in a0..=a1 {
        for b in b0..=b1 {
            if !world::has_world(p, g, &adt::tile_path(&spec.map, a, b)) {
                missing.push(format!("{a}_{b}"));
                continue;
            }
            reshape_tile(p, g, &spec.map, a, b, &|fx, fz, now| Some(now + (spec.lo + (spec.hi - spec.lo) * sample(fx, fz) - now) * k))?;
            tiles += 1;
        }
    }
    if tiles == 0 {
        bail!("{} has none of those tiles", spec.map);
    }
    Ok(serde_json::json!({"tiles": tiles, "missing": missing}))
}

// ---------------------------------------------------------------- scatter

#[derive(Debug, Clone, Deserialize)]
pub struct Scatter {
    pub map: String,
    pub x: f64,
    pub y: f64,
    pub radius: f64,
    /// Models to pick from (game paths or `model:Name`).
    pub models: Vec<String>,
    /// How many to try to place.
    pub count: usize,
    /// No closer than this many yards to each other (or to the pack's other doodads).
    #[serde(default = "three")]
    pub spacing: f64,
    /// Smallest and biggest size.
    #[serde(default = "sizes")]
    pub size: [f64; 2],
    /// Steepest ground, in degrees.
    #[serde(default = "steep")]
    pub max_slope: f64,
    #[serde(default)]
    pub seed: u64,
}
fn three() -> f64 {
    3.0
}
fn sizes() -> [f64; 2] {
    [0.8, 1.2]
}
fn steep() -> f64 {
    35.0
}

/// Scatter doodads in a circle. Returns how many were placed.
pub fn scatter(p: &Project, g: &GameData, s: &Scatter) -> Result<usize> {
    if s.models.is_empty() {
        bail!("pick one or more models to scatter");
    }
    if !(1.0..=200.0).contains(&s.radius) || s.count == 0 || s.count > 500 {
        bail!("radius 1–200 yards, 1–500 at a time");
    }
    for m in &s.models {
        if world::is_wmo(m) {
            bail!("buildings aren't scattered: place them one by one");
        }
        world::model_path(p, m)?;
    }
    let mut rng = Rng::new(s.seed ^ ((s.x * 1000.0) as i64 as u64) ^ (((s.y * 1000.0) as i64 as u64) << 21));
    let mut all = world::load(p)?;
    let list = all.entry(s.map.clone()).or_default();
    let mut taken: Vec<(f64, f64)> = list.iter().filter(|q| (q.x - s.x).hypot(q.y - s.y) < s.radius + s.spacing).map(|q| (q.x, q.y)).collect();
    let mut tiles: BTreeMap<(i32, i32), Option<Adt>> = BTreeMap::new();
    let mut ground = |x: f64, y: f64| -> Option<f64> {
        let (a, b) = adt::tile_of(x, y);
        let t = tiles.entry((a, b)).or_insert_with(|| tile_now(p, g, &s.map, a, b).ok().map(|x| x.0));
        let f = adt::to_file(x, y, 0.0);
        t.as_ref()?.height_at((a, b), f[0] as f64, f[2] as f64)
    };
    let mut lock = crate::ids::IdLock::load(&p.root)?;
    let mut placed = 0;
    for _ in 0..s.count * 30 {
        if placed >= s.count {
            break;
        }
        let (r, t) = (s.radius * rng.next().sqrt(), rng.range(0.0, std::f64::consts::TAU));
        let (x, y) = (s.x + r * t.cos(), s.y + r * t.sin());
        if taken.iter().any(|(qx, qy)| (qx - x).hypot(qy - y) < s.spacing) {
            continue;
        }
        let Some(z) = ground(x, y) else { continue };
        // the slope from the ground two yards either way
        let (Some(zx), Some(zy)) = (ground(x + 2.0, y), ground(x, y + 2.0)) else { continue };
        let slope = (((zx - z) / 2.0).hypot((zy - z) / 2.0)).atan().to_degrees();
        if slope > s.max_slope {
            continue;
        }
        let model = s.models[(rng.next() * s.models.len() as f64) as usize % s.models.len()].clone();
        let uid = lock.allocate(&p.manifest.pack.id, "MDDF", &model)?;
        list.push(Placement { model, x, y, z, turn: rng.range(0.0, 360.0).round(), scale: (rng.range(s.size[0], s.size[1].max(s.size[0])) * 100.0).round() / 100.0, uid, wmo_box: None, tilt: [0.0; 2], set: 0 });
        taken.push((x, y));
        placed += 1;
    }
    lock.save(&p.root)?;
    let list = list.clone();
    world::save_placements(p, &s.map, &list)?;
    Ok(placed)
}

/// Take the pack's own doodads out of a circle. Returns how many.
pub fn clear_circle(p: &Project, map: &str, x: f64, y: f64, radius: f64) -> Result<usize> {
    let mut all = world::load(p)?;
    let Some(list) = all.get_mut(map) else { return Ok(0) };
    let before = list.len();
    list.retain(|q| q.wmo_box.is_some() || (q.x - x).hypot(q.y - y) > radius);
    let n = before - list.len();
    let list = list.clone();
    world::save_placements(p, map, &list)?;
    Ok(n)
}

// ---------------------------------------------------------------- prefabs

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PrefabObject {
    pub model: String,
    /// Yards from the prefab's middle (world x, y) and above the ground there.
    pub dx: f64,
    pub dy: f64,
    #[serde(default)]
    pub up: f64,
    #[serde(default)]
    pub turn: f64,
    #[serde(default = "one")]
    pub scale: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PrefabSpawn {
    /// creature or gameobject
    pub table: String,
    pub entry: i64,
    pub dx: f64,
    pub dy: f64,
    #[serde(default)]
    pub o: f64,
    #[serde(default)]
    pub respawn: u32,
    #[serde(default)]
    pub wander: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Prefab {
    pub name: String,
    #[serde(default)]
    pub objects: Vec<PrefabObject>,
    #[serde(default)]
    pub spawns: Vec<PrefabSpawn>,
    /// How far out it reaches (yards), for levelling the ground.
    #[serde(default)]
    pub radius: f64,
}

fn prefab_dir(p: &Project) -> std::path::PathBuf {
    p.root.join("prefabs")
}

fn slug(name: &str) -> String {
    let s: String = name.chars().map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_lowercase() } else { '-' }).collect();
    s.split('-').filter(|x| !x.is_empty()).collect::<Vec<_>>().join("-")
}

/// Save the pack's doodads and spawns inside a box (world x/y corners) as a prefab.
pub fn capture(p: &Project, g: &GameData, map: &str, name: &str, corner1: [f64; 2], corner2: [f64; 2]) -> Result<Prefab> {
    if slug(name).is_empty() {
        bail!("give the prefab a name");
    }
    let (x0, x1) = (corner1[0].min(corner2[0]), corner1[0].max(corner2[0]));
    let (y0, y1) = (corner1[1].min(corner2[1]), corner1[1].max(corner2[1]));
    let (cx, cy) = ((x0 + x1) / 2.0, (y0 + y1) / 2.0);
    let inside = |x: f64, y: f64| x >= x0 && x <= x1 && y >= y0 && y <= y1;
    let ground = |x: f64, y: f64| -> f64 {
        let (a, b) = adt::tile_of(x, y);
        let f = adt::to_file(x, y, 0.0);
        tile_now(p, g, map, a, b).ok().and_then(|(t, _)| t.height_at((a, b), f[0] as f64, f[2] as f64)).unwrap_or(0.0)
    };
    let objects: Vec<PrefabObject> = world::load(p)?
        .get(map)
        .map(|l| {
            l.iter()
                .filter(|q| inside(q.x, q.y))
                .map(|q| PrefabObject { model: q.model.clone(), dx: q.x - cx, dy: q.y - cy, up: q.z - ground(q.x, q.y), turn: q.turn, scale: q.scale })
                .collect()
        })
        .unwrap_or_default();
    let Some(mid) = world::map_id(p, map) else { bail!("unknown map {map}") };
    let d = crate::data::load(p);
    let mut spawns = vec![];
    for table in ["creature", "gameobject"] {
        for r in d.world.get(table).map(|t| t.rows.clone()).unwrap_or_default() {
            let num = |k: &str| r.get(k).and_then(|v| v.as_float().or(v.as_integer().map(|i| i as f64))).unwrap_or(0.0);
            if num("map") as u32 != mid || !inside(num("position_x"), num("position_y")) {
                continue;
            }
            spawns.push(PrefabSpawn {
                table: table.into(),
                entry: num("id") as i64,
                dx: num("position_x") - cx,
                dy: num("position_y") - cy,
                o: num("orientation"),
                respawn: num(if table == "creature" { "spawntimesecsmin" } else { "spawntimesecs" }) as u32,
                wander: num("spawndist"),
            });
        }
    }
    if objects.is_empty() && spawns.is_empty() {
        bail!("nothing of the pack's inside that box (only your own doodads and spawns go into a prefab)");
    }
    let radius = objects.iter().map(|o| o.dx.hypot(o.dy)).chain(spawns.iter().map(|s| s.dx.hypot(s.dy))).fold(0.0, f64::max) + 4.0;
    let pf = Prefab { name: name.trim().to_string(), objects, spawns, radius };
    std::fs::create_dir_all(prefab_dir(p))?;
    std::fs::write(prefab_dir(p).join(format!("{}.json", slug(name))), serde_json::to_vec_pretty(&pf)?)?;
    Ok(pf)
}

pub fn prefabs(p: &Project) -> Vec<Prefab> {
    let mut out: Vec<Prefab> = std::fs::read_dir(prefab_dir(p))
        .map(|rd| rd.flatten().filter_map(|e| std::fs::read(e.path()).ok()).filter_map(|b| serde_json::from_slice(&b).ok()).collect())
        .unwrap_or_default();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

/// Bring in a prefab file someone shared (its JSON).
pub fn add_prefab(p: &Project, json: &[u8]) -> Result<Prefab> {
    let pf: Prefab = serde_json::from_slice(json).context("not a Forge prefab")?;
    if slug(&pf.name).is_empty() {
        bail!("the prefab has no name");
    }
    std::fs::create_dir_all(prefab_dir(p))?;
    std::fs::write(prefab_dir(p).join(format!("{}.json", slug(&pf.name))), serde_json::to_vec_pretty(&pf)?)?;
    Ok(pf)
}

pub fn remove_prefab(p: &Project, name: &str) -> Result<()> {
    std::fs::remove_file(prefab_dir(p).join(format!("{}.json", slug(name)))).context("no such prefab")
}

/// Stamp a prefab at world (x, y), turned `turn` degrees (counter-clockwise from above), each
/// piece on the ground. `level`: flatten the ground under it first.
pub fn stamp(p: &Project, g: &GameData, map: &str, name: &str, x: f64, y: f64, turn: f64, level: bool) -> Result<serde_json::Value> {
    let pf = prefabs(p).into_iter().find(|q| slug(&q.name) == slug(name)).with_context(|| format!("no prefab {name:?}"))?;
    let (s, c) = turn.to_radians().sin_cos();
    let rot = |dx: f64, dy: f64| (x + dx * c - dy * s, y + dx * s + dy * c);
    if level && pf.radius > 0.0 {
        let f = adt::to_file(x, y, 0.0);
        let (a, b) = adt::tile_of(x, y);
        let mid = tile_now(p, g, map, a, b)?.0.height_at((a, b), f[0] as f64, f[2] as f64).context("no ground there")?;
        let (cx, cz) = (f[0] as f64, f[2] as f64);
        let r = pf.radius;
        let feather = 8.0;
        for ta in ((cx - r - feather) / adt::TILE).floor() as i32..=((cx + r + feather) / adt::TILE).floor() as i32 {
            for tb in ((cz - r - feather) / adt::TILE).floor() as i32..=((cz + r + feather) / adt::TILE).floor() as i32 {
                if !world::has_world(p, g, &adt::tile_path(map, ta, tb)) {
                    continue;
                }
                reshape_tile(p, g, map, ta, tb, &|vx, vz, now| {
                    let d = (vx - cx).hypot(vz - cz);
                    if d > r + feather {
                        return None;
                    }
                    let w = if d <= r { 1.0 } else { 0.5 * (1.0 + (std::f64::consts::PI * (d - r) / feather).cos()) };
                    Some(now + (mid - now) * w)
                })?;
            }
        }
    }
    let mut placed = 0;
    for o in &pf.objects {
        let (px, py) = rot(o.dx, o.dy);
        let pl = Placement { model: o.model.clone(), x: px, y: py, z: 0.0, turn: (o.turn + turn).rem_euclid(360.0), scale: o.scale, uid: 0, wmo_box: None, tilt: [0.0; 2], set: 0 };
        let pl = world::place(p, Some(g), map, pl, true)?;
        if o.up.abs() > 0.01 {
            let mut lifted = pl.clone();
            lifted.z += o.up;
            world::place(p, Some(g), map, lifted, false)?;
        }
        placed += 1;
    }
    let mid = world::map_id(p, map).context("unknown map")?;
    let mut spawned = 0;
    for sp in &pf.spawns {
        let (px, py) = rot(sp.dx, sp.dy);
        let (a, b) = adt::tile_of(px, py);
        let f = adt::to_file(px, py, 0.0);
        let z = tile_now(p, g, map, a, b)?.0.height_at((a, b), f[0] as f64, f[2] as f64).unwrap_or(0.0) + 0.1;
        let pos = crate::data::Pos { map: mid, x: px, y: py, z, o: (sp.o + turn.to_radians()).rem_euclid(std::f64::consts::TAU) };
        if sp.table == "creature" {
            crate::data::add_spawn(p, sp.entry, pos, sp.respawn, sp.wander)?;
        } else {
            crate::data::add_object_spawn(p, sp.entry, pos, sp.respawn)?;
        }
        spawned += 1;
    }
    Ok(serde_json::json!({"objects": placed, "spawns": spawned}))
}

// ---------------------------------------------------------------- roads

#[derive(Debug, Clone, Deserialize)]
pub struct Road {
    pub map: String,
    /// World (x, y) points along the road.
    pub points: Vec<[f64; 2]>,
    pub width: f64,
    /// Ground texture to paint (empty: don't paint).
    #[serde(default)]
    pub texture: String,
    /// Smooth the ground along it.
    #[serde(default = "yes")]
    pub smooth: bool,
}
fn yes() -> bool {
    true
}

/// Lay a road. Returns the tiles it touched.
pub fn road(p: &Project, g: &GameData, r: &Road) -> Result<Vec<(i32, i32)>> {
    if r.points.len() < 2 {
        bail!("a road needs two points or more");
    }
    if !(2.0..=40.0).contains(&r.width) {
        bail!("roads are 2 to 40 yards wide");
    }
    // samples every 2 yards, in file coordinates, with the ground under them
    let mut samples: Vec<(f64, f64)> = vec![];
    for w in r.points.windows(2) {
        let (a, b) = (adt::to_file(w[0][0], w[0][1], 0.0), adt::to_file(w[1][0], w[1][1], 0.0));
        let len = ((b[0] - a[0]) as f64).hypot((b[2] - a[2]) as f64);
        let n = (len / 2.0).ceil().max(1.0) as usize;
        for k in 0..n {
            let t = k as f64 / n as f64;
            samples.push((a[0] as f64 + (b[0] - a[0]) as f64 * t, a[2] as f64 + (b[2] - a[2]) as f64 * t));
        }
    }
    let last = adt::to_file(r.points.last().unwrap()[0], r.points.last().unwrap()[1], 0.0);
    samples.push((last[0] as f64, last[2] as f64));
    let mut heights: Vec<f64> = vec![];
    for (fx, fz) in &samples {
        let (a, b) = ((fx / adt::TILE).floor() as i32, (fz / adt::TILE).floor() as i32);
        heights.push(tile_now(p, g, &r.map, a, b).ok().and_then(|(t, _)| t.height_at((a, b), *fx, *fz)).context("the road leaves the map's tiles")?);
    }
    // the road's own height: the ground, smoothed over about 12 yards either way
    let win = 6usize;
    let road_h: Vec<f64> = (0..heights.len())
        .map(|i| {
            let (lo, hi) = (i.saturating_sub(win), (i + win + 1).min(heights.len()));
            heights[lo..hi].iter().sum::<f64>() / (hi - lo) as f64
        })
        .collect();
    let half = r.width / 2.0;
    let feather = half.max(3.0);
    let mut tiles: Vec<(i32, i32)> = samples.iter().map(|(fx, fz)| ((fx / adt::TILE).floor() as i32, (fz / adt::TILE).floor() as i32)).collect();
    // the neighbours the road's edge can reach
    let mut more = vec![];
    for (fx, fz) in &samples {
        for (dx, dz) in [(-1.0, 0.0), (1.0, 0.0), (0.0, -1.0), (0.0, 1.0)] {
            let (x, z) = (fx + dx * (half + feather), fz + dz * (half + feather));
            more.push(((x / adt::TILE).floor() as i32, (z / adt::TILE).floor() as i32));
        }
    }
    tiles.extend(more);
    tiles.sort();
    tiles.dedup();
    tiles.retain(|(a, b)| world::has_world(p, g, &adt::tile_path(&r.map, *a, *b)));
    if r.smooth {
        for (a, b) in &tiles {
            reshape_tile(p, g, &r.map, *a, *b, &|vx, vz, now| {
                // the nearest sample, and how far
                let (mut best, mut bi) = (f64::MAX, 0);
                for (i, (sx, sz)) in samples.iter().enumerate() {
                    let d = (vx - sx).hypot(vz - sz);
                    if d < best {
                        best = d;
                        bi = i;
                    }
                }
                if best > half + feather {
                    return None;
                }
                let w = if best <= half { 1.0 } else { 0.5 * (1.0 + (std::f64::consts::PI * (best - half) / feather).cos()) };
                Some(now + (road_h[bi] - now) * w)
            })?;
        }
    }
    if !r.texture.is_empty() {
        // one pass over the chunks along it: full inside the width, soft at the edge
        let edge = 2.0;
        let near = |vx: f64, vz: f64| samples.iter().map(|(sx, sz)| (vx - sx).hypot(vz - sz)).fold(f64::MAX, f64::min);
        let mut chunks = vec![];
        for (fx, fz) in &samples {
            for (t, col, row) in world::chunks_under_pub(*fx, *fz, half + edge) {
                if !chunks.contains(&(t, col, row)) {
                    chunks.push((t, col, row));
                }
            }
        }
        world::paint_with(p, g, &r.map, &chunks, &r.texture, &|vx, vz| {
            let d = near(vx, vz);
            if d <= half {
                1.0
            } else if d < half + edge {
                1.0 - (d - half) / edge
            } else {
                0.0
            }
        })?;
    }
    Ok(tiles)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::{create, Template};

    fn setup() -> (tempfile::TempDir, Project, GameData) {
        crate::test_config();
        let dir = tempfile::tempdir().unwrap();
        let p = create(dir.path().join("p"), "Kit Pack", "Tester", Template::Empty).unwrap();
        let game = dir.path().join("wow/Data");
        std::fs::create_dir_all(&game).unwrap();
        let tile = crate::adt::tests::fake_tile(32, 48, 42.0);
        crate::mpqw::write(&game.join("terrain.MPQ"), &[(adt::tile_path("Azeroth", 32, 48), tile), ("World\\Tree01.m2".into(), b"MD20".to_vec())]).unwrap();
        let g = GameData::open(dir.path().join("wow")).unwrap();
        (dir, p, g)
    }

    #[test]
    fn a_heightmap_goes_out_and_comes_back() {
        let (_d, p, g) = setup();
        let r = import_heightmap(&p, &g, &{
            let img = image::ImageBuffer::<image::Luma<u16>, Vec<u16>>::from_fn(64, 64, |x, _| image::Luma([(x as f64 / 63.0 * 65535.0) as u16]));
            let mut out = std::io::Cursor::new(Vec::new());
            image::DynamicImage::ImageLuma16(img).write_to(&mut out, image::ImageFormat::Png).unwrap();
            out.into_inner()
        }, &HeightImport { map: "Azeroth".into(), from: [32, 48], to: [32, 48], lo: 0.0, hi: 100.0, strength: 1.0 })
        .unwrap();
        assert_eq!(r["tiles"], 1);
        let (t, _) = tile_now(&p, &g, "Azeroth", 32, 48).unwrap();
        let hm = t.heightmap();
        assert!((hm[64 * 129] - 0.0).abs() < 0.5, "west edge {}", hm[64 * 129]);
        assert!((hm[64 * 129 + 128] - 100.0).abs() < 0.5, "east edge {}", hm[64 * 129 + 128]);
        let out = export_heightmap(&p, &g, "Azeroth", 32, 48).unwrap();
        assert!((out["hi"].as_f64().unwrap() - 100.0).abs() < 0.5);
    }

    #[test]
    fn scatter_follows_its_rules() {
        let (_d, p, g) = setup();
        let (x, y) = (adt::HALF - 48.5 * adt::TILE, adt::HALF - 32.5 * adt::TILE);
        let n = scatter(&p, &g, &Scatter { map: "Azeroth".into(), x, y, radius: 30.0, models: vec!["World\\Tree01.mdx".into()], count: 20, spacing: 4.0, size: [0.9, 1.1], max_slope: 60.0, seed: 7 }).unwrap();
        assert!(n >= 10, "{n}");
        let list = world::load(&p).unwrap()["Azeroth"].clone();
        assert_eq!(list.len(), n);
        for (i, a) in list.iter().enumerate() {
            assert!((a.x - x).hypot(a.y - y) <= 30.0 + 1e-6);
            assert!(a.scale >= 0.9 && a.scale <= 1.1);
            for b in &list[i + 1..] {
                assert!((a.x - b.x).hypot(a.y - b.y) >= 4.0 - 1e-6);
            }
        }
        assert_eq!(clear_circle(&p, "Azeroth", x, y, 50.0).unwrap(), n);
    }

    #[test]
    fn a_prefab_is_captured_and_stamped_turned() {
        let (_d, p, g) = setup();
        let (x, y) = (adt::HALF - 48.5 * adt::TILE, adt::HALF - 32.5 * adt::TILE);
        world::place(&p, Some(&g), "Azeroth", Placement { model: "World\\Tree01.mdx".into(), x: x + 5.0, y, z: 0.0, turn: 10.0, scale: 1.0, uid: 0, wmo_box: None, tilt: [0.0; 2], set: 0 }, true).unwrap();
        let pf = capture(&p, &g, "Azeroth", "Lone Tree", [x - 10.0, y - 10.0], [x + 10.0, y + 10.0]).unwrap();
        assert_eq!(pf.objects.len(), 1);
        assert!((pf.objects[0].dx - 5.0).abs() < 1e-6);
        assert_eq!(prefabs(&p).len(), 1);
        let r = stamp(&p, &g, "Azeroth", "Lone Tree", x + 100.0, y + 100.0, 90.0, true).unwrap();
        assert_eq!(r["objects"], 1);
        let list = world::load(&p).unwrap()["Azeroth"].clone();
        let new = list.last().unwrap();
        // 5 yards along x, turned 90°: 5 yards along y
        assert!((new.x - (x + 100.0)).abs() < 1e-6 && (new.y - (y + 105.0)).abs() < 1e-6, "{new:?}");
        assert!((new.turn - 100.0).abs() < 1e-6);
        assert!(capture(&p, &g, "Azeroth", "Empty", [x + 300.0, y + 300.0], [x + 310.0, y + 310.0]).is_err());
    }

    #[test]
    fn a_ramp_climbs_and_a_stamp_presses() {
        let (_d, p, g) = setup();
        let (x, y) = (adt::HALF - 48.5 * adt::TILE, adt::HALF - 32.5 * adt::TILE);
        let h = |wx: f64, wy: f64| {
            let f = adt::to_file(wx, wy, 0.0);
            tile_now(&p, &g, "Azeroth", 32, 48).unwrap().0.height_at((32, 48), f[0] as f64, f[2] as f64).unwrap()
        };
        let base = h(x, y);
        ramp(&p, &g, &Ramp { map: "Azeroth".into(), from: [x - 50.0, y], to: [x + 50.0, y], from_z: Some(base), to_z: Some(base + 40.0), width: 10.0 }).unwrap();
        let mid = h(x, y);
        assert!((mid - (base + 20.0)).abs() < 3.0, "halfway up: {mid} vs {}", base + 20.0);
        assert!(h(x + 45.0, y) > mid + 10.0);
        assert!((h(x, y + 60.0) - base).abs() < 0.01, "away from the ramp is untouched");
        // a white square pressed in raises the middle by its strength
        let png = {
            let img = image::ImageBuffer::<image::Luma<u8>, Vec<u8>>::from_pixel(8, 8, image::Luma([255]));
            let mut out = std::io::Cursor::new(Vec::new());
            image::DynamicImage::ImageLuma8(img).write_to(&mut out, image::ImageFormat::Png).unwrap();
            out.into_inner()
        };
        use base64::Engine;
        let (sx, sy) = (x, y + 120.0);
        let before = h(sx, sy);
        stamp_image(&p, &g, &Stamp { map: "Azeroth".into(), x: sx, y: sy, radius: 30.0, strength: 12.0, turn: 30.0, lower: false, image: base64::engine::general_purpose::STANDARD.encode(png) }).unwrap();
        assert!((h(sx, sy) - before - 12.0).abs() < 0.5);
        assert!((h(sx, sy + 80.0) - before).abs() < 0.01);
    }

    #[test]
    fn a_field_shapes_and_scripts_keep() {
        let (_d, p, g) = setup();
        let (x, y) = (adt::HALF - 48.5 * adt::TILE, adt::HALF - 32.5 * adt::TILE);
        let c = adt::to_file(x, y, 0.0);
        // a 3 × 3 field, 10 yards apart, all at 60 but the far corner left alone
        let mut values = vec![Some(60.0); 9];
        values[8] = None;
        field(&p, &g, &Field { map: "Azeroth".into(), fx: c[0] as f64 - 10.0, fz: c[2] as f64 - 10.0, step: 10.0, w: 3, h: 3, values, blend: 1.0 }).unwrap();
        let (t, _) = tile_now(&p, &g, "Azeroth", 32, 48).unwrap();
        let h = |dx: f64, dz: f64| t.height_at((32, 48), c[0] as f64 + dx, c[2] as f64 + dz).unwrap();
        assert!((h(-8.0, -8.0) - 60.0).abs() < 0.5, "{}", h(-8.0, -8.0));
        assert!((h(6.0, 6.0) - 42.0).abs() < 0.5, "left alone by the empty corner");
        assert!((h(30.0, 30.0) - 42.0).abs() < 0.01, "outside untouched");
        assert_eq!(script_save(&p, "Ring of stones!", "forge.log(1)").unwrap(), "Ring of stones");
        assert_eq!(scripts(&p)[0]["code"], "forge.log(1)");
        script_remove(&p, "Ring of stones").unwrap();
        assert!(scripts(&p).is_empty());
        assert!(script_save(&p, "../x", "").unwrap() == "x");
    }

    #[test]
    fn a_road_levels_and_paints() {
        let (_d, p, g) = setup();
        let (x, y) = (adt::HALF - 48.5 * adt::TILE, adt::HALF - 32.5 * adt::TILE);
        // a bump in the way first
        world::sculpt(&p, &g, "Azeroth", x, y, 20.0, 10.0, world::Brush::Raise).unwrap();
        let before = tile_now(&p, &g, "Azeroth", 32, 48).unwrap().0;
        let f = adt::to_file(x, y, 0.0);
        let bump = before.height_at((32, 48), f[0] as f64, f[2] as f64).unwrap();
        let tex = before.textures()[0].clone();
        road(&p, &g, &Road { map: "Azeroth".into(), points: vec![[x - 60.0, y], [x + 60.0, y]], width: 8.0, texture: tex, smooth: true }).unwrap();
        let after = tile_now(&p, &g, "Azeroth", 32, 48).unwrap().0;
        let flat = after.height_at((32, 48), f[0] as f64, f[2] as f64).unwrap();
        assert!(flat < bump - 1.0, "the road cut the bump: {bump} → {flat}");
    }
}
