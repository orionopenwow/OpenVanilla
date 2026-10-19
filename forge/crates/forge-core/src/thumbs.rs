//! Small pictures for Forge's lists and pickers, made on this PC from the creator's own install:
//!
//! - a model (doodad, building, the pack's own) drawn three-quarter from the front with its
//!   textures, lit, on a transparent ground: [`model`];
//! - a creature by its look (CreatureDisplayInfo → model and skins) and an object by its
//!   GameObjectDisplayInfo: [`display`], [`object`];
//! - a ground texture swatch, and an item's icon: [`texture`], [`icon`].
//!
//! Everything is cached as PNG under the config folder (never in the project: renders of the
//! game's art stay on this PC). The key hashes the source bytes, so a re-ported model redraws.

use crate::project::Project;
use crate::vfs::GameData;
use anyhow::{bail, Context, Result};
use base64::Engine;
use image::{Rgba, RgbaImage};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::path::PathBuf;

/// Bump when the drawing changes, so old cached pictures are redrawn.
const STYLE: u32 = 3;

fn b64d(v: &Value) -> Vec<u8> {
    v.as_str().and_then(|s| base64::engine::general_purpose::STANDARD.decode(s).ok()).unwrap_or_default()
}

fn f32s(b: &[u8]) -> Vec<f32> {
    b.chunks_exact(4).map(|c| f32::from_le_bytes(c.try_into().unwrap())).collect()
}

fn cache_dir() -> PathBuf {
    crate::config::config_dir().join("thumbs")
}

fn key_of(parts: &[&[u8]]) -> String {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    STYLE.hash(&mut h);
    for p in parts {
        p.hash(&mut h);
    }
    format!("{:016x}", h.finish())
}

/// The cached PNG for `key`, or draw it with `make` and keep it.
fn cached(key: &str, make: impl FnOnce() -> Result<RgbaImage>) -> Result<Vec<u8>> {
    let f = cache_dir().join(format!("{key}.png"));
    if let Ok(b) = std::fs::read(&f) {
        return Ok(b);
    }
    let img = make()?;
    let mut out = std::io::Cursor::new(Vec::new());
    img.write_to(&mut out, image::ImageFormat::Png)?;
    let bytes = out.into_inner();
    let _ = std::fs::create_dir_all(cache_dir());
    let _ = std::fs::write(&f, &bytes);
    Ok(bytes)
}

/// A texture for a batch: a file's name, or a replaceable slot (11–13: the creature's skins).
pub type TexFn<'a> = dyn Fn(&Value) -> Option<RgbaImage> + 'a;

/// Draw a mesh (as [`crate::trueview::mesh`] packs it) at `size` × `size`.
pub fn render(mesh: &Value, tex: &TexFn, size: u32) -> Result<RgbaImage> {
    Ok(render_frames(mesh, tex, size, 1)?.remove(0))
}

/// `frames` pictures of a mesh turning once round (one: the usual three-quarter view), framed
/// alike so they play as a turntable.
pub fn render_frames(mesh: &Value, tex: &TexFn, size: u32, frames: u32) -> Result<Vec<RgbaImage>> {
    let pos = f32s(&b64d(&mesh["pos"]));
    let nrm = f32s(&b64d(&mesh["normal"]));
    let uv = f32s(&b64d(&mesh["uv"]));
    let index: Vec<u32> = if mesh["index32"].is_string() {
        b64d(&mesh["index32"]).chunks_exact(4).map(|c| u32::from_le_bytes(c.try_into().unwrap())).collect()
    } else {
        b64d(&mesh["index"]).chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]]) as u32).collect()
    };
    let nv = pos.len() / 3;
    let batches = mesh["batches"].as_array().cloned().unwrap_or_default();
    // a character model carries every hairstyle and every piece of clothing: keep the defaults
    // (the body, and the first of each group), as the game shows a bare character
    let character = batches.iter().any(|b| b["replace"] == 1);
    let default_geoset = |b: &Value| match b["geoset"].as_u64() {
        Some(g) if character => g == 0 || g == 1 || (g >= 100 && g % 100 == 1),
        _ => true,
    };
    // only what's drawn: glows and additive effects (blend 3+) are left out of a thumbnail
    let drawn: Vec<&Value> = batches.iter().filter(|b| b["blend"].as_u64().unwrap_or(0) <= 2 && default_geoset(b)).collect();
    // the camera: in front (+x), a little to the right and above, looking at the model; for a
    // turntable it goes round, the light with it
    let pitch = 0.38f32;
    let yaws: Vec<f32> = (0..frames.max(1)).map(|i| 0.55 + i as f32 * std::f32::consts::TAU / frames.max(1) as f32).collect();
    let view = |yaw: f32| {
        let d = [-(yaw.cos() * pitch.cos()), -(yaw.sin() * pitch.cos()), -pitch.sin()];
        let right = norm([d[1], -d[0], 0.0]);
        let up = cross(right, d);
        let (ly, l0) = (yaw - 0.55, [0.45f32, 0.35, 0.82]);
        let light = norm([l0[0] * ly.cos() - l0[1] * ly.sin(), l0[0] * ly.sin() + l0[1] * ly.cos(), l0[2]]);
        (d, right, up, light)
    };
    let at3 = |i: usize| [pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2]];
    // one framing for every frame: the drawn vertices' extent from every side
    let (mut lo, mut hi) = ([f32::MAX; 2], [f32::MIN; 2]);
    let mut any = false;
    for &yaw in &yaws {
        let (_, right, up, _) = view(yaw);
        for b in &drawn {
            let (s, c) = (b["start"].as_u64().unwrap_or(0) as usize, b["count"].as_u64().unwrap_or(0) as usize);
            for &k in index.get(s..s + c).unwrap_or(&[]) {
                if (k as usize) < nv {
                    let p = at3(k as usize);
                    let q = [dot(p, right), dot(p, up)];
                    lo = [lo[0].min(q[0]), lo[1].min(q[1])];
                    hi = [hi[0].max(q[0]), hi[1].max(q[1])];
                    any = true;
                }
            }
        }
    }
    if !any {
        bail!("nothing to draw");
    }
    let ss = 2u32;
    let w = size * ss;
    let span = (hi[0] - lo[0]).max(hi[1] - lo[1]).max(1e-3);
    let scale = w as f32 * 0.88 / span;
    let (cx, cy) = ((lo[0] + hi[0]) / 2.0, (lo[1] + hi[1]) / 2.0);
    let mut texcache: HashMap<String, Option<RgbaImage>> = HashMap::new();
    for b in &drawn {
        texcache.entry(b.to_string()).or_insert_with(|| tex(b));
    }
    let mut pictures = vec![];
    for &yaw in &yaws {
        let (d, right, up, light) = view(yaw);
        let proj = |i: usize| -> [f32; 3] {
            let p = at3(i);
            [dot(p, right), dot(p, up), -dot(p, d)]
        };
        let to_px = |q: [f32; 3]| -> [f32; 3] { [w as f32 / 2.0 + (q[0] - cx) * scale, w as f32 / 2.0 - (q[1] - cy) * scale, q[2]] };
        let mut color = vec![[0f32; 4]; (w * w) as usize];
        let mut depth = vec![f32::MIN; (w * w) as usize];
        for b in &drawn {
            let t = texcache.get(&b.to_string()).and_then(|t| t.as_ref());
            let blend = b["blend"].as_u64().unwrap_or(0);
            let (s, c) = (b["start"].as_u64().unwrap_or(0) as usize, b["count"].as_u64().unwrap_or(0) as usize);
            for tri in index.get(s..s + c).unwrap_or(&[]).chunks_exact(3) {
                let ids = [tri[0] as usize, tri[1] as usize, tri[2] as usize];
                if ids.iter().any(|&i| i >= nv) {
                    continue;
                }
                let v = ids.map(|i| to_px(proj(i)));
                let area = (v[1][0] - v[0][0]) * (v[2][1] - v[0][1]) - (v[2][0] - v[0][0]) * (v[1][1] - v[0][1]);
                if area.abs() < 1e-6 {
                    continue;
                }
                // the face's own normal (for models whose vertex normals are missing), towards the camera
                let p3 = ids.map(|i| [pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2]]);
                let mut fnrm = norm(cross(sub(p3[1], p3[0]), sub(p3[2], p3[0])));
                if dot(fnrm, d) > 0.0 {
                    fnrm = [-fnrm[0], -fnrm[1], -fnrm[2]];
                }
                let x0 = v.iter().map(|p| p[0]).fold(f32::MAX, f32::min).floor().max(0.0) as i32;
                let x1 = v.iter().map(|p| p[0]).fold(f32::MIN, f32::max).ceil().min(w as f32 - 1.0) as i32;
                let y0 = v.iter().map(|p| p[1]).fold(f32::MAX, f32::min).floor().max(0.0) as i32;
                let y1 = v.iter().map(|p| p[1]).fold(f32::MIN, f32::max).ceil().min(w as f32 - 1.0) as i32;
                for y in y0..=y1 {
                    for x in x0..=x1 {
                        let (px, py) = (x as f32 + 0.5, y as f32 + 0.5);
                        let w0 = ((v[1][0] - px) * (v[2][1] - py) - (v[2][0] - px) * (v[1][1] - py)) / area;
                        let w1 = ((v[2][0] - px) * (v[0][1] - py) - (v[0][0] - px) * (v[2][1] - py)) / area;
                        let w2 = 1.0 - w0 - w1;
                        if w0 < 0.0 || w1 < 0.0 || w2 < 0.0 {
                            continue;
                        }
                        let z = w0 * v[0][2] + w1 * v[1][2] + w2 * v[2][2];
                        let at = (y as u32 * w + x as u32) as usize;
                        if z <= depth[at] {
                            continue;
                        }
                        let mut base = [0.78f32, 0.74, 0.66, 1.0];
                        if let Some(t) = t {
                            let uvat = |i: usize| -> [f32; 2] { [uv.get(i * 2).copied().unwrap_or(0.0), uv.get(i * 2 + 1).copied().unwrap_or(0.0)] };
                            let (a, bb, cc) = (uvat(ids[0]), uvat(ids[1]), uvat(ids[2]));
                            let (u, vv) = (w0 * a[0] + w1 * bb[0] + w2 * cc[0], w0 * a[1] + w1 * bb[1] + w2 * cc[1]);
                            let tx = ((u.rem_euclid(1.0)) * t.width() as f32) as u32 % t.width();
                            let ty = ((vv.rem_euclid(1.0)) * t.height() as f32) as u32 % t.height();
                            let p = t.get_pixel(tx, ty).0;
                            base = [p[0] as f32 / 255.0, p[1] as f32 / 255.0, p[2] as f32 / 255.0, p[3] as f32 / 255.0];
                            if blend != 0 && base[3] < 0.5 {
                                continue;
                            }
                        }
                        let mut n = [0f32; 3];
                        for (k, &i) in ids.iter().enumerate() {
                            let wk = [w0, w1, w2][k];
                            for c in 0..3 {
                                n[c] += wk * nrm.get(i * 3 + c).copied().unwrap_or(0.0);
                            }
                        }
                        let n = if dot(n, n) < 1e-6 { fnrm } else { let n = norm(n); if dot(n, d) > 0.0 { [-n[0], -n[1], -n[2]] } else { n } };
                        let lit = 0.52 + 0.62 * dot(n, light).max(0.0);
                        depth[at] = z;
                        color[at] = [(base[0] * lit).min(1.0), (base[1] * lit).min(1.0), (base[2] * lit).min(1.0), 1.0];
                    }
                }
            }
        }
        // down to size (each pixel the average of its 2 × 2), then a soft dark edge so light models read on light tiles
        let mut out = RgbaImage::new(size, size);
        for y in 0..size {
            for x in 0..size {
                let mut acc = [0f32; 4];
                for dy in 0..ss {
                    for dx in 0..ss {
                        let c = color[((y * ss + dy) * w + x * ss + dx) as usize];
                        for k in 0..3 {
                            acc[k] += c[k] * c[3];
                        }
                        acc[3] += c[3];
                    }
                }
                let n = (ss * ss) as f32;
                let a = acc[3] / n;
                let px = if a > 0.0 { [acc[0] / acc[3], acc[1] / acc[3], acc[2] / acc[3], a] } else { [0.0; 4] };
                out.put_pixel(x, y, Rgba([(px[0] * 255.0) as u8, (px[1] * 255.0) as u8, (px[2] * 255.0) as u8, (px[3] * 255.0) as u8]));
            }
        }
        pictures.push(outline(out));
    }
    Ok(pictures)
}

/// A one-pixel dark rim around the drawn shape.
fn outline(img: RgbaImage) -> RgbaImage {
    let (w, h) = img.dimensions();
    let mut out = img.clone();
    for y in 0..h {
        for x in 0..w {
            if img.get_pixel(x, y)[3] > 0 {
                continue;
            }
            let near = [(-1i32, 0i32), (1, 0), (0, -1), (0, 1)].iter().any(|(dx, dy)| {
                let (nx, ny) = (x as i32 + dx, y as i32 + dy);
                nx >= 0 && ny >= 0 && (nx as u32) < w && (ny as u32) < h && img.get_pixel(nx as u32, ny as u32)[3] > 128
            });
            if near {
                out.put_pixel(x, y, Rgba([10, 8, 6, 150]));
            }
        }
    }
    out
}

fn dot(a: [f32; 3], b: [f32; 3]) -> f32 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}
fn cross(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}
fn sub(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}
fn norm(a: [f32; 3]) -> [f32; 3] {
    let l = dot(a, a).sqrt().max(1e-9);
    [a[0] / l, a[1] / l, a[2] / l]
}

/// Read art the way the World screen does: the pack's files, its ported models, then the game.
fn art(p: &Project, g: Option<&GameData>, path: &str) -> Result<Vec<u8>> {
    crate::world::read_art(p, g, path)
}

fn blp_image(bytes: &[u8], want: u32) -> Option<RgbaImage> {
    crate::trueview::texture_image(bytes, want).ok()
}

/// The game path a picker's model name stands for (`model:Name` → the pack's ported file).
fn resolve(p: &Project, model: &str) -> Result<String> {
    match model.strip_prefix("model:") {
        Some(name) => {
            let rep = crate::model::report(p, name).with_context(|| format!("model {name} isn't ported yet"))?;
            rep["meta"]["model_path"].as_str().filter(|s| !s.is_empty()).map(str::to_string).context("the port has no model path")
        }
        None => Ok(model.to_string()),
    }
}

/// A model's picture. `skins` fill its replaceable textures (a creature's TextureVariations,
/// in the model's folder). With `frames` > 1, a turntable: that many pictures side by side.
pub fn model(p: &Project, g: Option<&GameData>, model: &str, skins: &[String], size: u32, frames: u32) -> Result<Vec<u8>> {
    let path = resolve(p, model)?;
    // the pack's own creature models carry their skin in the port's report
    let own_skin: Vec<String>;
    let skins = match model.strip_prefix("model:") {
        Some(name) if skins.is_empty() => {
            own_skin = crate::model::report(p, name).and_then(|r| r["meta"]["texture_variation"].as_str().map(|s| vec![s.to_string()])).unwrap_or_default();
            &own_skin[..]
        }
        _ => skins,
    };
    let lower = path.to_ascii_lowercase();
    let main = if lower.ends_with(".mdx") || lower.ends_with(".mdl") { format!("{}.m2", &path[..path.len() - 4]) } else { path.clone() };
    let bytes = art(p, g, &main).with_context(|| format!("can't read {main}"))?;
    let skin_key = skins.join("|");
    let key = key_of(&[&bytes, skin_key.as_bytes(), &size.to_le_bytes(), &frames.to_le_bytes()]);
    cached(&key, || {
        let mesh = crate::trueview::mesh(&path, &|f| art(p, g, f))?;
        let folder = path.rsplit_once('\\').map(|x| x.0.to_string()).unwrap_or_default();
        let tex = |b: &Value| -> Option<RgbaImage> {
            let name = match b["replace"].as_u64() {
                Some(r @ 11..=13) => {
                    let s = skins.get(r as usize - 11).filter(|s| !s.is_empty())?;
                    format!("{folder}\\{s}.blp")
                }
                Some(_) => return None,
                None => b["texture"].as_str()?.to_string(),
            };
            blp_image(&art(p, g, &name).ok()?, 64)
        };
        let pics = render_frames(&mesh, &tex, size, frames.clamp(1, 24))?;
        let mut sheet = RgbaImage::new(size * pics.len() as u32, size);
        for (i, pic) in pics.iter().enumerate() {
            image::imageops::overlay(&mut sheet, pic, (i as u32 * size) as i64, 0);
        }
        Ok(sheet)
    })
}

/// The creature looks: CreatureDisplayInfo and CreatureModelData with the pack's rows merged in.
pub struct Looks {
    cdi: crate::data::Dbc,
    cmd: crate::data::Dbc,
    idi: Option<crate::data::Dbc>,
}

impl Looks {
    pub fn load(p: &Project, g: &GameData) -> Result<Looks> {
        let d = crate::data::load(p);
        let merged = |t: &str| -> Result<crate::data::Dbc> {
            let stock = crate::data::read_stock(g, t)?;
            match d.dbc.get(t) {
                Some(rows) if !rows.rows.is_empty() => crate::data::merge(t, &stock, &rows.rows),
                _ => Ok(stock),
            }
        };
        Ok(Looks { cdi: merged("CreatureDisplayInfo")?, cmd: merged("CreatureModelData")?, idi: merged("ItemDisplayInfo").ok() })
    }

    /// An item look → its icon's name (ItemDisplayInfo's InventoryIcon).
    pub fn icon(&self, id: u32) -> Result<String> {
        let d = self.idi.as_ref().context("can't read ItemDisplayInfo")?;
        let r = &d.records[d.find(id).with_context(|| format!("no item look {id}"))?];
        let n = d.string(r[5]);
        if n.is_empty() {
            bail!("item look {id} has no icon");
        }
        Ok(n)
    }

    /// A look → (the model's path, its three skin names).
    pub fn parts(&self, id: u32) -> Result<(String, Vec<String>)> {
        let r = &self.cdi.records[self.cdi.find(id).with_context(|| format!("no creature look {id}"))?];
        let m = &self.cmd.records[self.cmd.find(r[1]).with_context(|| format!("look {id}'s model {} isn't in CreatureModelData", r[1]))?];
        Ok((self.cmd.string(m[2]), (6..9).map(|i| self.cdi.string(r[i])).collect()))
    }
}

/// A creature's picture by its look (CreatureDisplayInfo ID, the pack's rows included).
pub fn display(p: &Project, g: &GameData, looks: &Looks, id: u32, size: u32, frames: u32) -> Result<Vec<u8>> {
    let (model_path, skins) = looks.parts(id)?;
    model(p, Some(g), &model_path, &skins, size, frames)
}

/// An object's picture by its GameObjectDisplayInfo ID.
pub fn object(p: &Project, g: &GameData, id: u32, size: u32, frames: u32) -> Result<Vec<u8>> {
    let d = crate::data::Dbc::parse(&g.read("DBFilesClient\\GameObjectDisplayInfo.dbc")?)?;
    let r = d.records.get(d.find(id).with_context(|| format!("no object look {id}"))?).context("no record")?;
    let path = d.string(r[1]);
    if path.is_empty() {
        bail!("object look {id} has no model");
    }
    model(p, Some(g), &path, &[], size, frames)
}

/// A texture as a square swatch (ground textures tile, so the top-left of a mip is enough).
pub fn texture(p: &Project, g: Option<&GameData>, path: &str, size: u32) -> Result<Vec<u8>> {
    let bytes = own_png_or(p, g, path)?;
    let key = key_of(&[&bytes, &size.to_le_bytes(), b"tex"]);
    cached(&key, || {
        let img = match image::load_from_memory(&bytes) {
            Ok(i) => i.to_rgba8(),
            Err(_) => crate::trueview::texture_image(&bytes, size)?,
        };
        Ok(image::imageops::resize(&img, size, size, image::imageops::FilterType::Triangle))
    })
}

/// The pack's cover: its start tile's ground, as the game paints it (lit), with the pack's edits.
pub fn cover(p: &Project, g: &GameData, size: u32) -> Result<Vec<u8>> {
    let (map, a, b) = crate::world::start_tile(p).context("the pack has no world yet")?;
    let edits = crate::world::tile_edit_bytes(p, &map, a, b);
    let key = key_of(&[map.as_bytes(), &a.to_le_bytes(), &b.to_le_bytes(), &edits, &size.to_le_bytes(), b"cover"]);
    cached(&key, || {
        let png = crate::world::true_ground_png(p, g, &map, a, b, 256, true)?;
        let img = image::load_from_memory(&base64::engine::general_purpose::STANDARD.decode(png)?)?.to_rgba8();
        // square textures fill the picture; others keep their shape, centred
        let (w, h) = img.dimensions();
        if w == h {
            return Ok(image::imageops::resize(&img, size, size, image::imageops::FilterType::Triangle));
        }
        let k = size as f32 / w.max(h) as f32;
        let (nw, nh) = (((w as f32 * k) as u32).max(1), ((h as f32 * k) as u32).max(1));
        let small = image::imageops::resize(&img, nw, nh, image::imageops::FilterType::Triangle);
        let mut out = RgbaImage::new(size, size);
        image::imageops::overlay(&mut out, &small, ((size - nw) / 2) as i64, ((size - nh) / 2) as i64);
        Ok(out)
    })
}

/// An item's icon: the pack's own (`art/Interface/Icons/<name>.png`) or the game's.
pub fn icon(p: &Project, g: Option<&GameData>, name: &str, size: u32) -> Result<Vec<u8>> {
    let n = name.rsplit(['\\', '/']).next().unwrap_or(name);
    texture(p, g, &format!("Interface\\Icons\\{n}.blp"), size)
}

/// The pack's `art/` PNG for a game path (art is converted to BLP at build), else the file.
fn own_png_or(p: &Project, g: Option<&GameData>, path: &str) -> Result<Vec<u8>> {
    let rel = path.replace('\\', "/");
    let stem = rel.strip_suffix(".blp").or_else(|| rel.strip_suffix(".BLP")).unwrap_or(&rel);
    for ext in ["png", "PNG"] {
        let f = p.root.join("art").join(format!("{stem}.{ext}"));
        if f.is_file() {
            return Ok(std::fs::read(f)?);
        }
    }
    art(p, g, path)
}

/// Many pictures in one call (`spin: n` on a model, look or object: a turntable strip of n
/// pictures): each item is `{key, model, skins?}`, `{key, display}`,
/// `{key, object}`, `{key, item_display}`, `{key, texture}` or `{key, icon}`. Returns key → PNG (base64), or null when it
/// couldn't be drawn (missing file, not a model …), with the reason under `why`.
pub fn many(p: &Project, g: Option<&GameData>, items: &[Value], size: u32) -> Value {
    let size = size.clamp(24, 256);
    let mut out = serde_json::Map::new();
    let mut why = serde_json::Map::new();
    let mut looks: Option<Result<Looks>> = None;
    for it in items {
        let key = it["key"].as_str().unwrap_or("").to_string();
        // `spin`: a turntable of that many frames (models, creatures, objects)
        let frames = it["spin"].as_u64().unwrap_or(1) as u32;
        let r: Result<Vec<u8>> = (|| {
            if let Some(m) = it["model"].as_str() {
                let skins: Vec<String> = it["skins"].as_array().map(|a| a.iter().filter_map(|s| s.as_str().map(str::to_string)).collect()).unwrap_or_default();
                return model(p, g, m, &skins, size, frames);
            }
            if let Some(t) = it["texture"].as_str() {
                return texture(p, g, t, size);
            }
            if let Some(t) = it["icon"].as_str() {
                return icon(p, g, t, size);
            }
            let g = g.context("Forge doesn't know where your game is")?;
            if let Some(d) = it["display"].as_u64() {
                let l = looks.get_or_insert_with(|| Looks::load(p, g)).as_ref().map_err(|e| anyhow::anyhow!("{e:#}"))?;
                return display(p, g, l, d as u32, size, frames);
            }
            if it["cover"].as_bool() == Some(true) {
                return cover(p, g, size);
            }
            if let Some(d) = it["item_display"].as_u64() {
                let l = looks.get_or_insert_with(|| Looks::load(p, g)).as_ref().map_err(|e| anyhow::anyhow!("{e:#}"))?;
                return icon(p, Some(g), &l.icon(d as u32)?, size);
            }
            if let Some(d) = it["object"].as_u64() {
                return object(p, g, d as u32, size, frames);
            }
            bail!("nothing to draw")
        })();
        match r {
            Ok(b) => {
                out.insert(key, json!(base64::engine::general_purpose::STANDARD.encode(b)));
            }
            Err(e) => {
                why.insert(key.clone(), json!(format!("{e:#}")));
                out.insert(key, Value::Null);
            }
        }
    }
    json!({"pics": out, "why": why})
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A unit cube's mesh as trueview packs it.
    fn cube() -> Value {
        let e = |b: &[u8]| base64::engine::general_purpose::STANDARD.encode(b);
        let mut pos = vec![];
        let mut nrm = vec![];
        let mut uv = vec![];
        let mut idx: Vec<u8> = vec![];
        let faces: [([f32; 3], [f32; 3], [f32; 3]); 6] = [
            ([1., 0., 0.], [0., 1., 0.], [0., 0., 1.]),
            ([-1., 0., 0.], [0., 1., 0.], [0., 0., 1.]),
            ([0., 1., 0.], [1., 0., 0.], [0., 0., 1.]),
            ([0., -1., 0.], [1., 0., 0.], [0., 0., 1.]),
            ([0., 0., 1.], [1., 0., 0.], [0., 1., 0.]),
            ([0., 0., -1.], [1., 0., 0.], [0., 1., 0.]),
        ];
        for (f, (n, u, v)) in faces.iter().enumerate() {
            for (su, sv) in [(-1., -1.), (1., -1.), (1., 1.), (-1., 1.)] {
                for c in 0..3 {
                    pos.extend_from_slice(&(n[c] + u[c] * su + v[c] * sv).to_le_bytes());
                    nrm.extend_from_slice(&n[c].to_le_bytes());
                }
                uv.extend_from_slice(&((su + 1.) / 2.0f32).to_le_bytes());
                uv.extend_from_slice(&((sv + 1.) / 2.0f32).to_le_bytes());
            }
            let b = (f * 4) as u16;
            for k in [0, 1, 2, 0, 2, 3] {
                idx.extend_from_slice(&(b + k).to_le_bytes());
            }
        }
        json!({"pos": e(&pos), "normal": e(&nrm), "uv": e(&uv), "index": e(&idx),
               "batches": [{"start": 0, "count": 36, "texture": "x.blp", "blend": 0}, {"start": 0, "count": 36, "texture": "glow.blp", "blend": 4}]})
    }

    #[test]
    fn draws_a_textured_cube() {
        let red = RgbaImage::from_pixel(4, 4, Rgba([200, 30, 30, 255]));
        let img = render(&cube(), &|b| (b["texture"] == "x.blp").then(|| red.clone()), 64).unwrap();
        assert_eq!(img.dimensions(), (64, 64));
        // the middle is the cube, red and lit; the corners are clear
        let mid = img.get_pixel(32, 32);
        assert_eq!(mid[3], 255);
        assert!(mid[0] > mid[1] * 2, "red: {mid:?}");
        assert_eq!(img.get_pixel(0, 0)[3], 0);
        // three faces are seen, lit differently
        let shades: std::collections::BTreeSet<u8> = (8..56).step_by(4).flat_map(|y| (8..56).step_by(4).map(move |x| (x, y))).map(|(x, y)| img.get_pixel(x, y)).filter(|p| p[3] == 255).map(|p| p[0] / 8).collect();
        assert!(shades.len() >= 2, "{shades:?}");
    }

    #[test]
    fn a_turntable_goes_round() {
        let red = RgbaImage::from_pixel(4, 4, Rgba([200, 30, 30, 255]));
        let pics = render_frames(&cube(), &|_| Some(red.clone()), 48, 8).unwrap();
        assert_eq!(pics.len(), 8);
        // a cube's height sets its frame, so the first frame is the usual picture; a quarter turn
        // of a cube looks the same again
        assert_eq!(pics[0], render(&cube(), &|_| Some(red.clone()), 48).unwrap());
        assert_ne!(pics[0], pics[1]);
        assert_eq!(pics[0], pics[2]);
    }

    #[test]
    fn nothing_drawn_is_an_error() {
        let mut m = cube();
        m["batches"] = json!([{"start": 0, "count": 36, "texture": null, "blend": 4}]);
        assert!(render(&m, &|_| None, 32).is_err());
    }

    #[test]
    fn cache_keys_follow_the_bytes() {
        assert_eq!(key_of(&[b"a", b"b"]), key_of(&[b"a", b"b"]));
        assert_ne!(key_of(&[b"a", b"b"]), key_of(&[b"a", b"c"]));
    }
}
