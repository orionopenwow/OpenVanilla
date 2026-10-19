//! True View: the World screen drawn with the game's own art, read from the creator's own
//! install (nothing is copied into the project or shipped).
//!
//! - [`ground`]: a tile's ground as the game paints it: every layer's real texture, repeating
//!   eight times across a map chunk, blended by its alpha map (optionally lit by the slopes for
//!   the 2D view; the 3D view lights its own mesh).
//! - [`m2_mesh`] / [`wmo_mesh`]: a doodad's or building's rest-pose mesh, its batches and their
//!   textures, packed for the 3D view (positions in the model's own space, z up).
//! - [`texture_png`]: a BLP as a PNG (a mip level no wider than asked), for those meshes.

use crate::adt::{Adt, CHUNK};
use anyhow::{bail, Context, Result};
use base64::Engine;
use image::{Rgba, RgbaImage};
use serde_json::{json, Value};
use std::collections::HashMap;

fn b64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

/// A decoded texture at about `want` pixels across (the mip level closest from above).
fn texture_level(blp: &[u8], want: u32) -> Result<RgbaImage> {
    let b = wow_blp::parser::load_blp_from_buf(blp).map_err(|e| anyhow::anyhow!("not a readable BLP: {e:?}"))?;
    let mut level = 0;
    while (b.header.width >> (level + 1)) >= want.max(1) && level < 8 {
        level += 1;
    }
    loop {
        match wow_blp::convert::blp_to_image(&b, level) {
            Ok(img) => return Ok(img.to_rgba8()),
            Err(_) if level > 0 => level -= 1,
            Err(e) => bail!("can't decode: {e:?}"),
        }
    }
}

/// A BLP decoded at about `want` pixels across.
pub fn texture_image(blp: &[u8], want: u32) -> Result<RgbaImage> {
    texture_level(blp, want)
}

/// A BLP as a PNG no wider than `max` (base64).
pub fn texture_png(blp: &[u8], max: u32) -> Result<String> {
    let img = texture_level(blp, max)?;
    let img = if img.width() > max { image::imageops::resize(&img, max, max * img.height() / img.width().max(1), image::imageops::FilterType::Triangle) } else { img };
    let mut out = std::io::Cursor::new(Vec::new());
    img.write_to(&mut out, image::ImageFormat::Png)?;
    Ok(b64(&out.into_inner()))
}

/// The ground of a tile at `size` × `size` pixels (a multiple of 16), painted with the real
/// ground textures. `shade` lights it by the slopes under a north-west sun (for the 2D map).
pub fn ground(t: &Adt, read: &dyn Fn(&str) -> Result<Vec<u8>>, size: u32, shade: bool) -> RgbaImage {
    let size = (size / 16).max(4) * 16;
    let per_chunk = size / 16; // pixels a chunk
    let per_repeat = (per_chunk / 8).max(2); // a texture repeats 8 times across a chunk
    let mut cache: HashMap<String, Option<RgbaImage>> = HashMap::new();
    let mut tex = |name: &str| -> Option<RgbaImage> {
        cache
            .entry(name.to_ascii_lowercase())
            .or_insert_with(|| read(name).ok().and_then(|b| texture_level(&b, per_repeat).ok()).map(|i| if i.width() == per_repeat { i } else { image::imageops::resize(&i, per_repeat, per_repeat, image::imageops::FilterType::Triangle) }))
            .clone()
    };
    let hm = t.heightmap();
    let h = |x: usize, z: usize| hm[z.min(128) * 129 + x.min(128)] as f64;
    let step = CHUNK / 8.0;
    let sun = {
        let v = [-1.0f64, 1.4, -1.0];
        let n = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
        [v[0] / n, v[1] / n, v[2] / n]
    };
    let mut img = RgbaImage::new(size, size);
    for row in 0..16usize {
        for col in 0..16usize {
            let layers = t.layers(col, row).unwrap_or_default();
            let texs: Vec<Option<RgbaImage>> = layers.iter().map(|l| tex(&l.texture)).collect();
            for py in 0..per_chunk {
                for px in 0..per_chunk {
                    // alpha maps are 64 × 64 a chunk: sample them smoothly
                    let fx = (px as f32 + 0.5) / per_chunk as f32 * 64.0 - 0.5;
                    let fy = (py as f32 + 0.5) / per_chunk as f32 * 64.0 - 0.5;
                    let alpha = |a: &Vec<u8>| -> f32 {
                        let (x0, y0) = (fx.floor().clamp(0.0, 63.0) as usize, fy.floor().clamp(0.0, 63.0) as usize);
                        let (x1, y1) = ((x0 + 1).min(63), (y0 + 1).min(63));
                        let (tx, ty) = ((fx - x0 as f32).clamp(0.0, 1.0), (fy - y0 as f32).clamp(0.0, 1.0));
                        let g = |x: usize, y: usize| a.get(y * 64 + x).copied().unwrap_or(0) as f32;
                        let top = g(x0, y0) * (1.0 - tx) + g(x1, y0) * tx;
                        let bot = g(x0, y1) * (1.0 - tx) + g(x1, y1) * tx;
                        (top * (1.0 - ty) + bot * ty) / 255.0
                    };
                    let (sx, sy) = (px % per_repeat, py % per_repeat);
                    let texel = |i: &Option<RgbaImage>| -> [f32; 3] {
                        match i {
                            Some(im) => {
                                let p = im.get_pixel(sx.min(im.width() - 1), sy.min(im.height() - 1));
                                [p[0] as f32, p[1] as f32, p[2] as f32]
                            }
                            None => [110.0, 120.0, 80.0],
                        }
                    };
                    let mut c = texs.first().map(texel).unwrap_or([110.0, 120.0, 80.0]);
                    for (l, ti) in layers.iter().zip(&texs).skip(1) {
                        let a = l.alpha.as_ref().map(alpha).unwrap_or(0.0);
                        if a <= 0.0 {
                            continue;
                        }
                        let lc = texel(ti);
                        for k in 0..3 {
                            c[k] += (lc[k] - c[k]) * a;
                        }
                    }
                    if shade {
                        let (gx, gz) = (col * 8 + (px * 8 / per_chunk) as usize, row * 8 + (py * 8 / per_chunk) as usize);
                        let dx = (h(gx + 1, gz) - h(gx.saturating_sub(1), gz)) / (step * if gx == 0 { 1.0 } else { 2.0 });
                        let dz = (h(gx, gz + 1) - h(gx, gz.saturating_sub(1))) / (step * if gz == 0 { 1.0 } else { 2.0 });
                        let n = {
                            let v = [-dx, 1.0, -dz];
                            let l = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
                            [v[0] / l, v[1] / l, v[2] / l]
                        };
                        let lit = (0.55 + 0.6 * (n[0] * sun[0] + n[1] * sun[1] + n[2] * sun[2]).max(0.0)) as f32;
                        for v in c.iter_mut() {
                            *v *= lit;
                        }
                    }
                    img.put_pixel(col as u32 * per_chunk + px, row as u32 * per_chunk + py, Rgba([c[0].clamp(0.0, 255.0) as u8, c[1].clamp(0.0, 255.0) as u8, c[2].clamp(0.0, 255.0) as u8, 255]));
                }
            }
        }
    }
    img
}

/// What the 3D view needs to paint a tile's ground as the game does, on the graphics card:
/// - `textures`: the tile's ground textures, each `tex` × `tex`, stacked top to bottom (`atlas`);
/// - `index`: 32 × 16, two pixels a chunk: its layers' textures (1-based; 0 = no layer), layers
///   0–2 in the first pixel's R, G, B and layer 3 in the second's R (alpha stays opaque: a browser
///   canvas would premultiply it away);
/// - `alpha`: 1024 × 1024, a chunk's 64 × 64 alpha maps: layer 1 in R, 2 in G, 3 in B.
pub fn splat(t: &Adt, read: &dyn Fn(&str) -> Result<Vec<u8>>, tex: u32) -> Result<Value> {
    let names = t.textures();
    let mut atlas = RgbaImage::new(tex, tex * names.len().max(1) as u32);
    for (i, n) in names.iter().enumerate() {
        let img = read(n).ok().and_then(|b| texture_level(&b, tex).ok()).map(|im| if im.width() == tex && im.height() == tex { im } else { image::imageops::resize(&im, tex, tex, image::imageops::FilterType::Triangle) });
        let mut img = img.unwrap_or_else(|| RgbaImage::from_pixel(tex, tex, Rgba([110, 120, 80, 255])));
        for p in img.pixels_mut() {
            p[3] = 255;
        }
        image::imageops::overlay(&mut atlas, &img, 0, (i as u32 * tex) as i64);
    }
    let mut index = RgbaImage::from_pixel(32, 16, Rgba([0, 0, 0, 255]));
    let mut alpha = RgbaImage::from_pixel(1024, 1024, Rgba([0, 0, 0, 255]));
    for row in 0..16usize {
        for col in 0..16usize {
            let layers = t.layers(col, row).unwrap_or_default();
            let mut px = [0u8; 4];
            for (k, l) in layers.iter().take(4).enumerate() {
                px[k] = names.iter().position(|n| n == &l.texture).map(|i| i as u8 + 1).unwrap_or(0);
                if k == 0 {
                    continue;
                }
                if let Some(a) = &l.alpha {
                    for y in 0..64u32 {
                        for x in 0..64u32 {
                            let p = alpha.get_pixel_mut(col as u32 * 64 + x, row as u32 * 64 + y);
                            p[k - 1] = a.get((y * 64 + x) as usize).copied().unwrap_or(0);
                        }
                    }
                }
            }
            index.put_pixel(col as u32 * 2, row as u32, Rgba([px[0], px[1], px[2], 255]));
            index.put_pixel(col as u32 * 2 + 1, row as u32, Rgba([px[3], 0, 0, 255]));
        }
    }
    // the shadows the game bakes into the ground (under trees and buildings): white is shadow
    let mut shadow: Option<RgbaImage> = None;
    for row in 0..16usize {
        for col in 0..16usize {
            let Some(m) = t.shadow_map(col, row) else { continue };
            let img = shadow.get_or_insert_with(|| RgbaImage::from_pixel(1024, 1024, Rgba([0, 0, 0, 255])));
            for (i, v) in m.iter().enumerate() {
                if *v != 0 {
                    img.put_pixel(col as u32 * 64 + (i % 64) as u32, row as u32 * 64 + (i / 64) as u32, Rgba([255, 255, 255, 255]));
                }
            }
        }
    }
    let shadow = shadow.map(|s| png_b64(&s)).transpose()?;
    Ok(json!({"textures": names, "size": tex, "atlas": png_b64(&atlas)?, "index": png_b64(&index)?, "alpha": png_b64(&alpha)?, "shadow": shadow}))
}

/// A picture as JPEG-free PNG base64 (the app shows it as a data URL).
pub fn png_b64(img: &RgbaImage) -> Result<String> {
    let mut out = std::io::Cursor::new(Vec::new());
    img.write_to(&mut out, image::ImageFormat::Png)?;
    Ok(b64(&out.into_inner()))
}

fn u16_at(b: &[u8], o: usize) -> Result<u16> {
    Ok(u16::from_le_bytes(b.get(o..o + 2).context("short file")?.try_into()?))
}
fn u32_at(b: &[u8], o: usize) -> Result<u32> {
    Ok(u32::from_le_bytes(b.get(o..o + 4).context("short file")?.try_into()?))
}
fn arr(b: &[u8], at: usize) -> Result<(usize, usize)> {
    Ok((u32_at(b, at)? as usize, u32_at(b, at + 4)? as usize))
}

/// A doodad's mesh (1.12 M2, version 256: views inside the file), in its rest pose.
pub fn m2_mesh(b: &[u8]) -> Result<Value> {
    if b.get(..4) != Some(b"MD20") {
        bail!("not an M2");
    }
    let (vn, vo) = arr(b, 0x44)?;
    if vo + vn * 48 > b.len() {
        bail!("vertices run past the file");
    }
    let mut pos = Vec::with_capacity(vn * 12);
    let mut nrm = Vec::with_capacity(vn * 12);
    let mut uv = Vec::with_capacity(vn * 8);
    for i in 0..vn {
        let o = vo + i * 48;
        pos.extend_from_slice(&b[o..o + 12]);
        nrm.extend_from_slice(&b[o + 20..o + 32]);
        uv.extend_from_slice(&b[o + 32..o + 40]);
    }
    let (tn, to) = arr(b, 0x5c)?;
    let mut textures = vec![];
    for i in 0..tn {
        let o = to + i * 16;
        let (ttype, n, at) = (u32_at(b, o)?, u32_at(b, o + 8)? as usize, u32_at(b, o + 12)? as usize);
        let name = if ttype == 0 && n > 0 { b.get(at..at + n).map(|s| String::from_utf8_lossy(s).trim_end_matches('\0').to_string()) } else { None };
        textures.push((ttype, name));
    }
    let (mn, mo) = arr(b, 0x84)?;
    let mats: Vec<(u16, u16)> = (0..mn).map(|i| Ok((u16_at(b, mo + i * 4)?, u16_at(b, mo + i * 4 + 2)?))).collect::<Result<_>>()?;
    let (tln, tlo) = arr(b, 0x94)?;
    let tlookup: Vec<u16> = (0..tln).map(|i| u16_at(b, tlo + i * 2)).collect::<Result<_>>()?;
    let (nviews, vwo) = arr(b, 0x4c)?;
    if nviews == 0 {
        bail!("the model has no views");
    }
    let (ni, oi) = arr(b, vwo)?;
    let (nt, ot) = arr(b, vwo + 8)?;
    let (ns, os) = arr(b, vwo + 24)?;
    let (nb, ob) = arr(b, vwo + 32)?;
    let lookup: Vec<u16> = (0..ni).map(|i| u16_at(b, oi + i * 2)).collect::<Result<_>>()?;
    let mut index = Vec::with_capacity(nt * 2);
    for i in 0..nt {
        let k = u16_at(b, ot + i * 2)? as usize;
        index.extend_from_slice(&lookup.get(k).copied().unwrap_or(0).to_le_bytes());
    }
    let subs: Vec<(u32, u32, u16)> = (0..ns).map(|i| Ok((u16_at(b, os + i * 32 + 8)? as u32, u16_at(b, os + i * 32 + 10)? as u32, u16_at(b, os + i * 32)?))).collect::<Result<_>>()?;
    let mut batches = vec![];
    for i in 0..nb {
        let o = ob + i * 24;
        let (sub, mat, tcombo) = (u16_at(b, o + 4)? as usize, u16_at(b, o + 0x0a)? as usize, u16_at(b, o + 0x10)? as usize);
        let Some(&(start, count, geoset)) = subs.get(sub) else { continue };
        let (flags, blend) = mats.get(mat).copied().unwrap_or((0, 0));
        let (ttype, tex) = tlookup.get(tcombo).and_then(|&t| textures.get(t as usize).cloned()).unwrap_or((0, None));
        // replaceable textures (1 skin, 2 cape, 6 hair, 11-13 a creature's skins) come from the display
        let replace = (ttype != 0).then_some(ttype);
        batches.push(json!({"start": start, "count": count, "geoset": geoset, "texture": tex, "replace": replace, "blend": blend, "two_sided": flags & 4 != 0, "unlit": flags & 1 != 0}));
    }
    let mut out = json!({"kind": "m2", "verts": vn, "pos": b64(&pos), "normal": b64(&nrm), "uv": b64(&uv), "index": b64(&index), "batches": batches});
    // particle emitters (fires, smoke, sparks): the view runs them simply
    if let Ok(ps) = m2_particles(b, &textures) {
        if !ps.is_empty() {
            out["particles"] = json!(ps);
        }
    }
    // the bones and how they move standing (and running, for characters): the view plays them
    if let Ok(Some(anim)) = m2_anim(b) {
        let mut skin = Vec::with_capacity(vn * 8);
        for i in 0..vn {
            let o = vo + i * 48;
            skin.extend_from_slice(&b[o + 12..o + 20]);
        }
        out["anim"] = anim;
        out["skin"] = json!(b64(&skin));
    }
    Ok(out)
}

/// A 1.12 M2's particle emitters (504 bytes each): where, what texture, and the first value of
/// each of their tracks (speed, spread, gravity, life, rate, area), colours and sizes over a life.
fn m2_particles(b: &[u8], textures: &[(u32, Option<String>)]) -> Result<Vec<Value>> {
    let (n, o) = arr(b, 0x13c)?;
    if n == 0 || n > 64 || o + n * 504 > b.len() {
        return Ok(vec![]);
    }
    let first = |t: usize| -> Result<f32> {
        let (vn, vo) = arr(b, t + 20)?;
        if vn == 0 { Ok(0.0) } else { f32_at(b, vo) }
    };
    let mut out = vec![];
    for i in 0..n {
        let e = o + i * 504;
        let tracks: Vec<f32> = (0..10).map(|k| first(e + 52 + k * 28)).collect::<Result<_>>()?;
        let tex = textures.get(u16_at(b, e + 22)? as usize).and_then(|t| t.1.clone());
        let colors: Vec<[u8; 4]> = (0..3).map(|k| { let c = &b[e + 336 + k * 4..e + 340 + k * 4]; [c[2], c[1], c[0], c[3]] }).collect();
        let scales: Vec<f32> = (0..3).map(|k| f32_at(b, e + 348 + k * 4)).collect::<Result<_>>()?;
        out.push(json!({
            "pos": [f32_at(b, e + 8)?, f32_at(b, e + 12)?, f32_at(b, e + 16)?], "bone": u16_at(b, e + 20)?, "texture": tex,
            "blend": b[e + 40], "type": b[e + 41], "rows": u16_at(b, e + 48)?.max(1), "cols": u16_at(b, e + 50)?.max(1),
            "speed": tracks[0], "var": tracks[1], "vrange": tracks[2], "hrange": tracks[3], "gravity": tracks[4], "life": tracks[5],
            "rate": tracks[6], "len": tracks[7], "wid": tracks[8], "mid": f32_at(b, e + 332)?, "colors": colors, "scales": scales,
        }));
    }
    Ok(out)
}

fn f32_at(b: &[u8], o: usize) -> Result<f32> {
    Ok(f32::from_le_bytes(b.get(o..o + 4).context("short file")?.try_into()?))
}

/// One of a bone's tracks over one sequence (pre-2.0 M2Track: interpolation, global sequence,
/// ranges per sequence, then timestamps and values for the whole file): times relative to the
/// sequence's start (or the global loop's) and the values flattened.
fn m2_track(b: &[u8], at: usize, seq: usize, start: u32, globals: &[u32], width: usize) -> Result<Option<Value>> {
    let interp = u16_at(b, at)?;
    let gs = u16_at(b, at + 2)? as i16;
    let (rn, ro) = arr(b, at + 4)?;
    let (tn, to) = arr(b, at + 12)?;
    let (vn, vo) = arr(b, at + 20)?;
    if tn == 0 || vn == 0 || tn != vn {
        return Ok(None);
    }
    let (lo, hi, base, global) = if gs >= 0 {
        (0, tn - 1, 0, globals.get(gs as usize).copied())
    } else {
        if seq >= rn {
            return Ok(None);
        }
        let (a, z) = (u32_at(b, ro + seq * 8)? as usize, u32_at(b, ro + seq * 8 + 4)? as usize);
        if a >= tn || z >= tn || z < a {
            return Ok(None);
        }
        (a, z, start, None)
    };
    let mut times = vec![];
    let mut vals = vec![];
    for k in lo..=hi {
        times.push(u32_at(b, to + k * 4)?.saturating_sub(base));
        for c in 0..width {
            vals.push(f32_at(b, vo + k * width * 4 + c * 4)?);
        }
    }
    let mut v = json!({"t": times, "v": vals, "i": interp});
    if let Some(g) = global {
        v["loop"] = json!(g);
    }
    Ok(Some(v))
}

/// The bones of a 1.12 M2 and their Stand (and Run) animation, or None when nothing moves.
pub fn m2_anim(b: &[u8]) -> Result<Option<Value>> {
    let (gn, go) = arr(b, 0x14)?;
    let globals: Vec<u32> = (0..gn).map(|i| u32_at(b, go + i * 4)).collect::<Result<_>>()?;
    let (sn, so) = arr(b, 0x1c)?;
    let (bn, bo) = arr(b, 0x34)?;
    if bn == 0 || bn > 256 || bo + bn * 108 > b.len() || so + sn * 68 > b.len() {
        return Ok(None);
    }
    let bones: Vec<Value> = (0..bn)
        .map(|i| {
            let o = bo + i * 108;
            Ok(json!({"p": u16_at(b, o + 8)? as i16, "pv": [f32_at(b, o + 96)?, f32_at(b, o + 100)?, f32_at(b, o + 104)?]}))
        })
        .collect::<Result<_>>()?;
    let mut seqs = serde_json::Map::new();
    let mut moves = false;
    for (name, id) in [("stand", 0u16), ("run", 5u16)] {
        let Some(si) = (0..sn).find(|&i| u16_at(b, so + i * 68).ok() == Some(id)) else { continue };
        let (start, end) = (u32_at(b, so + si * 68 + 4)?, u32_at(b, so + si * 68 + 8)?);
        let mut tracks = vec![];
        for i in 0..bn {
            let o = bo + i * 108;
            let t = m2_track(b, o + 12, si, start, &globals, 3)?;
            let r = m2_track(b, o + 40, si, start, &globals, 4)?;
            let s = m2_track(b, o + 68, si, start, &globals, 3)?;
            for x in [&t, &r, &s].into_iter().flatten() {
                if x["t"].as_array().map(|a| a.len()).unwrap_or(0) > 1 {
                    moves = true;
                }
            }
            tracks.push(json!({"t": t, "r": r, "s": s}));
        }
        seqs.insert(name.into(), json!({"len": end.saturating_sub(start).max(1), "bones": tracks}));
    }
    if !moves {
        return Ok(None);
    }
    Ok(Some(json!({"bones": bones, "seqs": seqs})))
}

/// Chunks of a WMO file (magic as written, reversed in the file) → (magic, body).
fn wmo_chunks(b: &[u8]) -> Vec<(String, &[u8])> {
    let mut out = vec![];
    let mut o = 0;
    while o + 8 <= b.len() {
        let magic: String = b[o..o + 4].iter().rev().map(|&c| c as char).collect();
        let n = u32::from_le_bytes(b[o + 4..o + 8].try_into().unwrap()) as usize;
        let end = (o + 8 + n).min(b.len());
        out.push((magic, &b[o + 8..end]));
        o = end;
    }
    out
}

/// A building's mesh: every group's render batches, with their textures (1.12 WMO, v17). The
/// root's doodad sets (furniture) aren't drawn.
pub fn wmo_mesh(root: &[u8], read: &dyn Fn(&str) -> Result<Vec<u8>>, root_path: &str) -> Result<Value> {
    let ch = wmo_chunks(root);
    let get = |m: &str| ch.iter().find(|c| c.0 == m).map(|c| c.1);
    let mohd = get("MOHD").context("not a WMO root (no MOHD)")?;
    let groups = u32_at(mohd, 4)? as usize;
    let motx = get("MOTX").unwrap_or(&[]);
    let momt = get("MOMT").unwrap_or(&[]);
    let tex_at = |off: u32| -> Option<String> {
        let s = motx.get(off as usize..)?;
        let end = s.iter().position(|&c| c == 0)?;
        (end > 0).then(|| String::from_utf8_lossy(&s[..end]).to_string())
    };
    let materials: Vec<Value> = momt
        .chunks_exact(64)
        .map(|m| {
            let flags = u32::from_le_bytes(m[0..4].try_into().unwrap());
            let blend = u32::from_le_bytes(m[8..12].try_into().unwrap());
            let t1 = u32::from_le_bytes(m[12..16].try_into().unwrap());
            json!({"texture": tex_at(t1), "blend": blend, "two_sided": flags & 4 != 0, "unlit": flags & 1 != 0})
        })
        .collect();
    let base = root_path.strip_suffix(".wmo").or_else(|| root_path.strip_suffix(".WMO")).unwrap_or(root_path);
    let (mut pos, mut nrm, mut uv, mut index) = (Vec::<u8>::new(), Vec::<u8>::new(), Vec::<u8>::new(), Vec::<u8>::new());
    let mut batches = vec![];
    let mut verts = 0u32;
    for gi in 0..groups.min(512) {
        let Ok(gb) = read(&format!("{base}_{gi:03}.wmo")) else { continue };
        let top = wmo_chunks(&gb);
        let Some(mogp) = top.iter().find(|c| c.0 == "MOGP").map(|c| c.1) else { continue };
        if mogp.len() < 0x44 {
            continue;
        }
        let sub = wmo_chunks(&mogp[0x44..]);
        let sg = |m: &str| sub.iter().find(|c| c.0 == m).map(|c| c.1);
        let (Some(movt), Some(movi), Some(moba)) = (sg("MOVT"), sg("MOVI"), sg("MOBA")) else { continue };
        let n = (movt.len() / 12) as u32;
        let first_index = (index.len() / 4) as u32;
        pos.extend_from_slice(&movt[..n as usize * 12]);
        match sg("MONR") {
            Some(m) if m.len() >= n as usize * 12 => nrm.extend_from_slice(&m[..n as usize * 12]),
            _ => nrm.extend(std::iter::repeat_n(0u8, n as usize * 12)),
        }
        match sg("MOTV") {
            Some(m) if m.len() >= n as usize * 8 => uv.extend_from_slice(&m[..n as usize * 8]),
            _ => uv.extend(std::iter::repeat_n(0u8, n as usize * 8)),
        }
        for c in movi.chunks_exact(2) {
            index.extend_from_slice(&(u16::from_le_bytes([c[0], c[1]]) as u32 + verts).to_le_bytes());
        }
        for bt in moba.chunks_exact(24) {
            let start = u32::from_le_bytes(bt[12..16].try_into().unwrap());
            let count = u16::from_le_bytes([bt[16], bt[17]]) as u32;
            let mat = bt[23] as usize;
            let m = materials.get(mat).cloned().unwrap_or(json!({"texture": null, "blend": 0}));
            batches.push(json!({"start": first_index + start, "count": count, "texture": m["texture"], "blend": m["blend"], "two_sided": m["two_sided"], "unlit": m["unlit"]}));
        }
        verts += n;
    }
    if verts == 0 {
        bail!("none of the building's group files could be read");
    }
    Ok(json!({"kind": "wmo", "verts": verts, "pos": b64(&pos), "normal": b64(&nrm), "uv": b64(&uv), "index32": b64(&index), "batches": batches, "sets": wmo_sets(&ch)}))
}

/// A building's doodad sets (MODS) with their doodads (MODD, named in MODN): the furniture. Set
/// 0 shows in every copy; a placement picks one more.
fn wmo_sets(ch: &[(String, &[u8])]) -> Vec<Value> {
    let get = |m: &str| ch.iter().find(|c| c.0 == m).map(|c| c.1).unwrap_or(&[]);
    let (mods, modn, modd) = (get("MODS"), get("MODN"), get("MODD"));
    let name_at = |off: usize| -> Option<String> {
        let s = modn.get(off..)?;
        let end = s.iter().position(|&c| c == 0)?;
        (end > 0).then(|| String::from_utf8_lossy(&s[..end]).to_string())
    };
    let f = |b: &[u8], o: usize| f32::from_le_bytes(b[o..o + 4].try_into().unwrap());
    mods.chunks_exact(32)
        .map(|m| {
            let name = String::from_utf8_lossy(&m[..20]).trim_end_matches('\0').to_string();
            let (start, count) = (u32::from_le_bytes(m[20..24].try_into().unwrap()) as usize, u32::from_le_bytes(m[24..28].try_into().unwrap()) as usize);
            let doodads: Vec<Value> = (start..start + count.min(600))
                .filter_map(|i| {
                    let d = modd.get(i * 40..i * 40 + 40)?;
                    let model = name_at((u32::from_le_bytes(d[0..4].try_into().unwrap()) & 0xFF_FFFF) as usize)?;
                    Some(json!({"model": model, "pos": [f(d, 4), f(d, 8), f(d, 12)], "rot": [f(d, 16), f(d, 20), f(d, 24), f(d, 28)], "scale": f(d, 32)}))
                })
                .collect();
            json!({"name": name, "doodads": doodads})
        })
        .collect()
}

/// The mesh for a model path as written in a tile (`.mdx` names are read as `.m2`, as the game does).
pub fn mesh(path: &str, read: &dyn Fn(&str) -> Result<Vec<u8>>) -> Result<Value> {
    let lower = path.to_ascii_lowercase();
    if lower.ends_with(".wmo") {
        let root = read(path)?;
        return wmo_mesh(&root, read, path);
    }
    let p = if lower.ends_with(".mdx") || lower.ends_with(".mdl") { format!("{}.m2", &path[..path.len() - 4]) } else { path.to_string() };
    m2_mesh(&read(&p).with_context(|| format!("can't read {p}"))?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adt::tests::fake_tile;
    use crate::adt::Layer;

    fn solid(c: [u8; 3]) -> Vec<u8> {
        crate::minimap::encode(RgbaImage::from_pixel(64, 64, Rgba([c[0], c[1], c[2], 255]))).unwrap()
    }

    #[test]
    fn ground_blends_the_real_textures_by_their_alpha() {
        let mut t = Adt::parse(&fake_tile(32, 48, 0.0)).unwrap();
        let mut alpha = vec![0u8; 4096];
        for y in 0..64 {
            for x in 32..64 {
                alpha[y * 64 + x] = 255;
            }
        }
        t.set_layers(0, 0, &[Layer { texture: "red.blp".into(), ..Default::default() }, Layer { texture: "blue.blp".into(), alpha: Some(alpha), ..Default::default() }]).unwrap();
        let read = |p: &str| -> Result<Vec<u8>> { Ok(if p.contains("red") { solid([200, 0, 0]) } else { solid([0, 0, 200]) }) };
        let img = ground(&t, &read, 512, false);
        assert_eq!(img.width(), 512);
        let left = img.get_pixel(4, 16);
        let right = img.get_pixel(28, 16);
        assert!(left[0] > 150 && left[2] < 50, "{left:?}");
        assert!(right[2] > 150 && right[0] < 50, "{right:?}");
    }

    /// A tiny M2 in the porter's layout: one triangle, one batch, one named texture.
    pub(crate) fn tiny_m2() -> Vec<u8> {
        let mut b = vec![0u8; 0x130];
        b[..4].copy_from_slice(b"MD20");
        b[4..8].copy_from_slice(&256u32.to_le_bytes());
        let put = |b: &mut Vec<u8>, at: usize, n: u32, o: u32| {
            b[at..at + 4].copy_from_slice(&n.to_le_bytes());
            b[at + 4..at + 8].copy_from_slice(&o.to_le_bytes());
        };
        // vertices
        let vo = b.len() as u32;
        for p in [[0f32, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 2.0]] {
            let mut v = vec![0u8; 48];
            for k in 0..3 {
                v[k * 4..k * 4 + 4].copy_from_slice(&p[k].to_le_bytes());
            }
            b.extend(v);
        }
        put(&mut b, 0x44, 3, vo);
        // texture
        let name = b"World\\Tree.blp\0";
        let no = b.len() as u32;
        b.extend(name);
        let to = b.len() as u32;
        let mut t = vec![0u8; 16];
        t[8..12].copy_from_slice(&(name.len() as u32).to_le_bytes());
        t[12..16].copy_from_slice(&no.to_le_bytes());
        b.extend(t);
        put(&mut b, 0x5c, 1, to);
        let mo = b.len() as u32;
        b.extend([4u8, 0, 1, 0]); // two-sided, alpha key
        put(&mut b, 0x84, 1, mo);
        let tlo = b.len() as u32;
        b.extend([0u8, 0]);
        put(&mut b, 0x94, 1, tlo);
        // the view
        let li = b.len() as u32;
        b.extend([0u8, 0, 1, 0, 2, 0]);
        let tr = b.len() as u32;
        b.extend([0u8, 0, 1, 0, 2, 0]);
        let so = b.len() as u32;
        let mut s = vec![0u8; 32];
        s[10..12].copy_from_slice(&3u16.to_le_bytes());
        b.extend(s);
        let bo = b.len() as u32;
        b.extend(vec![0u8; 24]);
        let vw = b.len() as u32;
        let mut v = vec![0u8; 44];
        for (k, (n, o)) in [(3u32, li), (3, tr), (0, 0), (1, so), (1, bo)].iter().enumerate() {
            v[k * 8..k * 8 + 4].copy_from_slice(&n.to_le_bytes());
            v[k * 8 + 4..k * 8 + 8].copy_from_slice(&o.to_le_bytes());
        }
        b.extend(v);
        put(&mut b, 0x4c, 1, vw);
        b
    }

    #[test]
    fn reads_an_m2s_mesh_and_batches() {
        let m = m2_mesh(&tiny_m2()).unwrap();
        assert_eq!(m["verts"], 3);
        assert_eq!(m["batches"][0]["texture"], "World\\Tree.blp");
        assert_eq!(m["batches"][0]["blend"], 1);
        assert_eq!(m["batches"][0]["two_sided"], true);
        let idx = base64::engine::general_purpose::STANDARD.decode(m["index"].as_str().unwrap()).unwrap();
        assert_eq!(idx, vec![0, 0, 1, 0, 2, 0]);
        // .mdx names are read as .m2
        let m = mesh("World\\Tree.mdx", &|p: &str| if p == "World\\Tree.m2" { Ok(tiny_m2()) } else { bail!("no {p}") }).unwrap();
        assert_eq!(m["kind"], "m2");
    }

    fn wchunk(magic: &str, body: &[u8]) -> Vec<u8> {
        let mut v: Vec<u8> = magic.bytes().rev().collect();
        v.extend((body.len() as u32).to_le_bytes());
        v.extend(body);
        v
    }

    #[test]
    fn reads_a_buildings_groups() {
        let mut mohd = vec![0u8; 64];
        mohd[4..8].copy_from_slice(&1u32.to_le_bytes());
        let mut momt = vec![0u8; 64];
        momt[12..16].copy_from_slice(&0u32.to_le_bytes());
        let mut root = wchunk("MVER", &17u32.to_le_bytes());
        root.extend(wchunk("MOHD", &mohd));
        root.extend(wchunk("MOTX", b"Wall.blp\0\0\0\0"));
        root.extend(wchunk("MOMT", &momt));
        let mut sub = vec![0u8; 0x44];
        let movt: Vec<u8> = [0f32, 0.0, 0.0, 4.0, 0.0, 0.0, 0.0, 4.0, 3.0].iter().flat_map(|f| f.to_le_bytes()).collect();
        sub.extend(wchunk("MOVT", &movt));
        sub.extend(wchunk("MOVI", &[0, 0, 1, 0, 2, 0]));
        let mut moba = vec![0u8; 24];
        moba[16..18].copy_from_slice(&3u16.to_le_bytes());
        sub.extend(wchunk("MOBA", &moba));
        let mut group = wchunk("MVER", &17u32.to_le_bytes());
        group.extend(wchunk("MOGP", &sub));
        let read = |p: &str| -> Result<Vec<u8>> { if p == "World\\Hut_000.wmo" { Ok(group.clone()) } else { bail!("no {p}") } };
        let m = wmo_mesh(&root, &read, "World\\Hut.wmo").unwrap();
        assert_eq!(m["verts"], 3);
        assert_eq!(m["batches"][0]["texture"], "Wall.blp");
        assert_eq!(m["batches"][0]["count"], 3);
    }
}

#[cfg(test)]
mod real {
    /// FORGE_REAL_GAME=<game folder> [FORGE_DUMP=<dir>] [FORGE_REAL_TILE=Azeroth_32_48]: every
    /// doodad and building on a real tile reads as a mesh with textures that exist, and the ground
    /// paints (saved to FORGE_DUMP to look at).
    #[test]
    #[ignore]
    fn true_view_of_a_real_tile() {
        let g = crate::vfs::GameData::open(std::env::var("FORGE_REAL_GAME").unwrap()).unwrap();
        let tile = std::env::var("FORGE_REAL_TILE").unwrap_or_else(|_| "Azeroth_32_48".into());
        let mut it = tile.rsplitn(3, '_');
        let (b, a, map): (i32, i32, &str) = (it.next().unwrap().parse().unwrap(), it.next().unwrap().parse().unwrap(), it.next().unwrap());
        let t = crate::adt::Adt::parse(&g.read(&crate::adt::tile_path(map, a, b)).unwrap()).unwrap();
        let read = |p: &str| g.read(p);
        let img = super::ground(&t, &read, 1024, true);
        if let Ok(d) = std::env::var("FORGE_DUMP") {
            img.save(std::path::Path::new(&d).join(format!("{tile}_trueground.png"))).unwrap();
        }
        let mut names: Vec<String> = t.doodads().into_iter().chain(t.wmos()).map(|d| d.model).collect();
        names.sort();
        names.dedup();
        let (mut ok, mut bad, mut tex_missing, mut tris) = (0, vec![], 0, 0u64);
        for n in &names {
            match super::mesh(n, &read) {
                Ok(m) => {
                    ok += 1;
                    for bt in m["batches"].as_array().unwrap() {
                        tris += bt["count"].as_u64().unwrap() / 3;
                        if let Some(tx) = bt["texture"].as_str() {
                            if g.read(tx).is_err() {
                                tex_missing += 1;
                            }
                        }
                    }
                }
                Err(e) => bad.push(format!("{n}: {e:#}")),
            }
        }
        println!("{tile}: {ok} models read, {} not, {tex_missing} missing textures, {tris} triangles", bad.len());
        for b in &bad {
            println!("  {b}");
        }
        assert!(bad.len() * 10 <= names.len(), "too many models didn't read");
    }
}
