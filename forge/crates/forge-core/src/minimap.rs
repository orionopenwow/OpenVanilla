//! Minimap tiles for edited terrain: the corner map and the zoomed minimap draw
//! `Textures\Minimap\<file>.blp`, found through `textures\Minimap\md5translate.trs`
//! (`Azeroth\map32_48.blp` → its file). A tile Forge reshaped, painted or watered gets a new
//! 256 × 256 picture, baked from what the tile now is: each ground texture's colour blended by
//! its alpha map (a texture repeats eight times across a chunk, so at 16 pixels a chunk its
//! colour is what shows), shaded by the slopes under a north-west sun, with water over it.
//! Doodads and buildings aren't drawn (the game's own tiles show them faintly from above).

use crate::adt::{Adt, LiquidKind, CHUNK};
use anyhow::{Context, Result};
use image::{Rgba, RgbaImage};
use std::collections::HashMap;

pub const SIZE: u32 = 256;
pub const TRS: &str = "textures\\Minimap\\md5translate.trs";

/// A texture's average colour (its smallest useful mip level).
fn mean_colour(blp: &[u8]) -> Result<[f32; 3]> {
    let b = wow_blp::parser::load_blp_from_buf(blp).map_err(|e| anyhow::anyhow!("not a readable BLP: {e:?}"))?;
    let mut level = 0;
    while (b.header.width >> (level + 1)) >= 4 && level < 6 {
        level += 1;
    }
    let img = wow_blp::convert::blp_to_image(&b, level).map_err(|e| anyhow::anyhow!("can't decode: {e:?}"))?.to_rgba8();
    let n = (img.width() * img.height()).max(1) as f32;
    let mut s = [0f32; 3];
    for p in img.pixels() {
        for c in 0..3 {
            s[c] += p[c] as f32;
        }
    }
    Ok([s[0] / n, s[1] / n, s[2] / n])
}

fn water_colour(k: LiquidKind) -> [f32; 3] {
    match k {
        // muted, as the game's own pictures have their lakes and rivers (compared on Northshire)
        LiquidKind::River => [62.0, 92.0, 88.0],
        LiquidKind::Ocean => [40.0, 70.0, 96.0],
        LiquidKind::Magma => [214.0, 96.0, 30.0],
        LiquidKind::Slime => [80.0, 140.0, 50.0],
    }
}

/// Bake one tile's minimap picture. `read` gives game files (the ground textures).
pub fn bake(t: &Adt, read: &dyn Fn(&str) -> Result<Vec<u8>>) -> RgbaImage {
    let mut colours: HashMap<String, [f32; 3]> = HashMap::new();
    let mut colour_of = |name: &str| -> [f32; 3] {
        *colours.entry(name.to_ascii_lowercase()).or_insert_with(|| read(name).and_then(|b| mean_colour(&b)).unwrap_or([110.0, 120.0, 80.0]))
    };
    let hm = t.heightmap();
    let h = |x: usize, z: usize| hm[z.min(128) * 129 + x.min(128)] as f64;
    let step = CHUNK / 8.0;
    let sun = {
        let v = [-1.0f64, 1.4, -1.0]; // from the north-west (−file x is west, −file z north), up
        let n = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
        [v[0] / n, v[1] / n, v[2] / n]
    };
    let mut img = RgbaImage::new(SIZE, SIZE);
    for row in 0..16 {
        for col in 0..16 {
            let layers = t.layers(col, row).unwrap_or_default();
            let cols: Vec<[f32; 3]> = layers.iter().map(|l| colour_of(&l.texture)).collect();
            let water = t.liquid(col, row);
            for py in 0..16u32 {
                for px in 0..16u32 {
                    // ground colour: the layers over each other by their alpha
                    let (ax, ay) = (px as usize * 4 + 2, py as usize * 4 + 2);
                    let mut c = cols.first().copied().unwrap_or([110.0, 120.0, 80.0]);
                    for (l, lc) in layers.iter().zip(&cols).skip(1) {
                        let a = l.alpha.as_ref().map(|a| a[ay * 64 + ax] as f32 / 255.0).unwrap_or(0.0);
                        for k in 0..3 {
                            c[k] += (lc[k] - c[k]) * a;
                        }
                    }
                    // light: the slope at the nearest vertex
                    let (gx, gz) = (col * 8 + (px as usize) / 2, row * 8 + (py as usize) / 2);
                    let dx = (h(gx + 1, gz) - h(gx.saturating_sub(1), gz)) / (step * if gx == 0 { 1.0 } else { 2.0 });
                    let dz = (h(gx, gz + 1) - h(gx, gz.saturating_sub(1))) / (step * if gz == 0 { 1.0 } else { 2.0 });
                    let n = {
                        let v = [-dx, 1.0, -dz];
                        let l = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
                        [v[0] / l, v[1] / l, v[2] / l]
                    };
                    let lit = (0.5 + 0.62 * (n[0] * sun[0] + n[1] * sun[1] + n[2] * sun[2]).max(0.0)) as f32;
                    for v in c.iter_mut() {
                        *v *= lit;
                    }
                    // water over it, where the surface is above the ground
                    if let Some(w) = &water {
                        let k = ((py / 2) * 8 + px / 2) as usize;
                        let top = w.verts.iter().map(|v| v.1).fold(f32::MIN, f32::max) as f64;
                        if w.shown(k) && top > h(gx, gz) {
                            let wc = water_colour(w.kind);
                            let depth = ((top - h(gx, gz)) / 6.0).clamp(0.0, 1.0) as f32;
                            let a = match w.kind {
                                LiquidKind::Magma => 0.92,
                                LiquidKind::Ocean => 0.45 + 0.4 * depth,
                                _ => 0.25 + 0.25 * depth,
                            };
                            for k in 0..3 {
                                c[k] += (wc[k] - c[k]) * a;
                            }
                        }
                    }
                    img.put_pixel(col as u32 * 16 + px, row as u32 * 16 + py, Rgba([c[0].clamp(0.0, 255.0) as u8, c[1].clamp(0.0, 255.0) as u8, c[2].clamp(0.0, 255.0) as u8, 255]));
                }
            }
        }
    }
    img
}

/// A picture as a BLP2 (DXT1 with mipmaps, as the game's minimap tiles are).
pub fn encode(img: RgbaImage) -> Result<Vec<u8>> {
    use wow_blp::convert::{image_to_blp, Blp2Format, BlpTarget, DxtAlgorithm};
    let blp = image_to_blp(
        image::DynamicImage::ImageRgba8(img),
        true,
        BlpTarget::Blp2(Blp2Format::Dxt1 { has_alpha: false, compress_algorithm: DxtAlgorithm::RangeFit }),
        image::imageops::FilterType::Triangle,
    )
    .map_err(|e| anyhow::anyhow!("minimap BLP: {e:?}"))?;
    wow_blp::encode::encode_blp(&blp).map_err(|e| anyhow::anyhow!("minimap BLP: {e:?}"))
}

/// Point `map`'s tile (a, b) at `file` (a name inside Textures\Minimap) in the translation table.
pub fn trs_set(trs: &str, map: &str, a: i32, b: i32, file: &str) -> String {
    let key = format!("{map}\\map{a}_{b}.blp");
    let line = format!("{key}\t{file}");
    let mut out = vec![];
    let mut done = false;
    let mut in_dir = false;
    let lines: Vec<&str> = trs.lines().collect();
    for (i, l) in lines.iter().enumerate() {
        if let Some(d) = l.strip_prefix("dir: ") {
            // leaving our map's section without having found the tile: add it there
            if in_dir && !done {
                out.push(line.clone());
                done = true;
            }
            in_dir = d.trim().eq_ignore_ascii_case(map);
        }
        if l.split('\t').next().is_some_and(|k| k.eq_ignore_ascii_case(&key)) {
            out.push(line.clone());
            done = true;
            continue;
        }
        out.push(l.to_string());
        if in_dir && !done && i + 1 == lines.len() {
            out.push(line.clone());
            done = true;
        }
    }
    if !done {
        out.push(format!("dir: {map}"));
        out.push(line);
    }
    let mut s = out.join("\r\n");
    s.push_str("\r\n");
    s
}

/// The minimap files for edited tiles of `map`: a BLP per tile and the updated translation
/// table. Nothing when the game has no table (a patch with a partial one would blank the rest).
pub fn for_tiles(map: &str, tiles: &[((i32, i32), Adt)], read: &dyn Fn(&str) -> Result<Vec<u8>>, trs: Option<String>) -> Result<(Vec<(String, Vec<u8>)>, Option<String>)> {
    let Some(mut trs) = trs.or_else(|| read(TRS).ok().map(|b| String::from_utf8_lossy(&b).to_string())) else {
        return Ok((vec![], None));
    };
    let mut files = vec![];
    for ((a, b), t) in tiles {
        let blp = encode(bake(t, read))?;
        let h = blake3::hash(&blp).to_hex();
        let name = format!("forge_{}{}.blp", map.to_ascii_lowercase(), &h[..20]);
        trs = trs_set(&trs, map, *a, *b, &name);
        files.push((format!("Textures\\Minimap\\{name}"), blp));
    }
    Ok((files, Some(trs)))
}

/// Decode a minimap tile back to an image (for previews and tests).
pub fn decode(blp: &[u8]) -> Result<RgbaImage> {
    let b = wow_blp::parser::load_blp_from_buf(blp).map_err(|e| anyhow::anyhow!("{e:?}"))?;
    Ok(wow_blp::convert::blp_to_image(&b, 0).map_err(|e| anyhow::anyhow!("{e:?}")).context("minimap")?.to_rgba8())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adt::tests::fake_tile;
    use crate::adt::{Layer, Liquid};

    fn solid(c: [u8; 3]) -> Vec<u8> {
        encode(RgbaImage::from_pixel(64, 64, Rgba([c[0], c[1], c[2], 255]))).unwrap()
    }

    /// FORGE_REAL_GAME=<1.12 folder> FORGE_DUMP=<out dir> [FORGE_REAL_TILE=Azeroth_32_48]: bake a
    /// real tile and save it beside the game's own minimap picture, to compare by eye.
    #[test]
    #[ignore]
    fn bake_a_real_tile() {
        let g = crate::vfs::GameData::open(std::env::var("FORGE_REAL_GAME").unwrap()).unwrap();
        let out = std::path::PathBuf::from(std::env::var("FORGE_DUMP").unwrap());
        let tile = std::env::var("FORGE_REAL_TILE").unwrap_or_else(|_| "Azeroth_32_48".into());
        let mut it = tile.rsplitn(3, '_');
        let (b, a, map): (i32, i32, &str) = (it.next().unwrap().parse().unwrap(), it.next().unwrap().parse().unwrap(), it.next().unwrap());
        let t = Adt::parse(&g.read(&crate::adt::tile_path(map, a, b)).unwrap()).unwrap();
        let img = bake(&t, &|p| g.read(p));
        img.save(out.join(format!("{tile}_forge.png"))).unwrap();
        decode(&encode(img).unwrap()).unwrap().save(out.join(format!("{tile}_forge_blp.png"))).unwrap();
        if let Ok(trs) = g.read(TRS) {
            let key = format!("{map}\\map{a}_{b}.blp").to_ascii_lowercase();
            if let Some(f) = String::from_utf8_lossy(&trs).lines().find_map(|l| l.split_once('\t').filter(|(k, _)| k.to_ascii_lowercase() == key).map(|x| x.1.to_string())) {
                decode(&g.read(&format!("Textures\\Minimap\\{f}")).unwrap()).unwrap().save(out.join(format!("{tile}_game.png"))).unwrap();
            }
        }
    }

    #[test]
    fn bakes_ground_water_and_the_table() {
        let mut t = Adt::parse(&fake_tile(32, 48, 20.0)).unwrap();
        // red base everywhere; blue painted fully over chunk (2, 3); water in chunk (8, 8)
        let mut alpha = vec![255u8; 4096];
        alpha[0] = 0;
        t.set_layers(2, 3, &[
            Layer { texture: "Tileset\\Elwynn\\ElwynnGrassBase.blp".into(), flags: 0, effect: 0, alpha: None },
            Layer { texture: "Tileset\\X\\Blue.blp".into(), flags: 0x100, effect: 0, alpha: Some(alpha) },
        ])
        .unwrap();
        let mut w = Liquid::flat(LiquidKind::River, 30.0);
        w.tiles = [4; 64];
        t.set_liquid(8, 8, Some(&w)).unwrap();
        let (red, blue) = (solid([200, 30, 30]), solid([30, 30, 200]));
        let read = |p: &str| -> Result<Vec<u8>> {
            Ok(match p.to_ascii_lowercase().as_str() {
                "tileset\\elwynn\\elwynngrassbase.blp" => red.clone(),
                "tileset\\x\\blue.blp" => blue.clone(),
                "textures\\minimap\\md5translate.trs" => b"dir: Azeroth\r\nAzeroth\\map32_48.blp\told.blp\r\nAzeroth\\map32_49.blp\tother.blp\r\ndir: Kalimdor\r\nKalimdor\\map1_1.blp\tk.blp\r\n".to_vec(),
                _ => anyhow::bail!("no {p}"),
            })
        };
        let img = bake(&t, &read);
        let at = |x: u32, y: u32| *img.get_pixel(x, y);
        let p = at(5, 5);
        assert!(p[0] > p[2] * 3, "base is red: {p:?}");
        let p = at(2 * 16 + 8, 3 * 16 + 8);
        assert!(p[2] > p[0] * 3, "the painted chunk is blue: {p:?}");
        let (p, dry) = (at(8 * 16 + 8, 8 * 16 + 8), at(10 * 16 + 8, 8 * 16 + 8));
        assert!(p[2] > dry[2] + 20 && p[0] + 40 < dry[0], "water over the red: {p:?} (dry {dry:?})");
        let (files, trs) = for_tiles("Azeroth", &[((32, 48), t)], &read, None).unwrap();
        assert_eq!(files.len(), 1);
        let trs = trs.unwrap();
        let name = files[0].0.rsplit('\\').next().unwrap();
        assert!(trs.contains(&format!("Azeroth\\map32_48.blp\t{name}")), "{trs}");
        assert!(!trs.contains("old.blp") && trs.contains("other.blp") && trs.contains("k.blp"));
        assert_eq!(decode(&files[0].1).unwrap().dimensions(), (256, 256));
        // a tile the table didn't have goes into its map's section
        let t2 = trs_set(&trs, "Kalimdor", 5, 6, "new.blp");
        let lines: Vec<&str> = t2.lines().collect();
        let k = lines.iter().position(|l| *l == "dir: Kalimdor").unwrap();
        assert!(lines[k + 1..].contains(&"Kalimdor\\map5_6.blp\tnew.blp"));
        assert!(trs_set("", "Test", 1, 2, "x.blp").contains("dir: Test\r\nTest\\map1_2.blp\tx.blp"));
    }
}
