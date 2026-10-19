//! The server's map tiles: CMaNGOS reads ground heights, area IDs, water and holes from
//! `maps/MMMYYXX.map`, which its extractor (`ad`) makes from the client's ADT tiles. A tile
//! Forge reshaped, painted with water, holed or re-zoned is converted here the same way, so
//! the realm's server gets ground that matches what players see without running the extractor
//! over the whole client.
//!
//! A port of `ConvertADT` in CMaNGOS `contrib/extractor/System.cpp` (MCLQ water, the 1.12
//! path), with the same packing rules: flat ground or water stored without a height grid,
//! heights as 8- or 16-bit steps when the range allows, area and liquid grids only when they
//! vary across the tile.

use crate::adt::{self, Adt};
use anyhow::{Context, Result};

/// The format version CMaNGOS Classic writes and checks ("z1.4"). A realm can name its own
/// (read from one of its existing .map files) when its server is older or newer.
pub const VERSION: [u8; 4] = *b"z1.4";

const CELL: usize = 8; // ADT_CELL_SIZE
const CELLS: usize = 16; // ADT_CELLS_PER_GRID
const GRID: usize = 128; // ADT_GRID_SIZE
const MIN_HEIGHT: f32 = -500.0; // CONF_use_minHeight
const INT8_LIMIT: f32 = 2.0;
const INT16_LIMIT: f32 = 2048.0;
const FLAT_HEIGHT: f32 = 0.005;
const FLAT_LIQUID: f32 = 0.001;

const AREA_NO_AREA: u16 = 0x0001;
const HEIGHT_NO_HEIGHT: u32 = 0x0001;
const HEIGHT_AS_INT16: u32 = 0x0002;
const HEIGHT_AS_INT8: u32 = 0x0004;
const LIQUID_NO_TYPE: u8 = 0x01;
const LIQUID_NO_HEIGHT: u8 = 0x02;
const LT_MAGMA: u8 = 0x01;
const LT_OCEAN: u8 = 0x02;
const LT_WATER: u8 = 0x08;
const LT_DEEP: u8 = 0x10;

/// The server file name for map `map_id`'s tile `Map_A_B.adt`.
pub fn file_name(map_id: u32, a: i32, b: i32) -> String {
    format!("{map_id:03}{b:02}{a:02}.map")
}

/// The version a server's existing .map file carries.
pub fn version_of(bytes: &[u8]) -> Option<[u8; 4]> {
    (bytes.len() >= 8 && &bytes[..4] == b"MAPS").then(|| bytes[4..8].try_into().unwrap())
}

/// AreaTable.dbc → area id → its explore flag (column 3), the value the server's grid stores.
pub fn area_flags(area_table: &crate::data::Dbc) -> std::collections::HashMap<u32, u16> {
    area_table.records.iter().filter(|r| r.len() > 3).map(|r| (r[0], r[3] as u16)).collect()
}

fn u32_le(v: u32) -> [u8; 4] {
    v.to_le_bytes()
}

/// Convert one ADT tile to the server's .map bytes.
pub fn convert(t: &Adt, flags_of: &dyn Fn(u32) -> Option<u16>, version: [u8; 4]) -> Result<Vec<u8>> {
    let mut area = [[0xFFFFu16; CELLS]; CELLS];
    let mut v9 = vec![[0f32; GRID + 1]; GRID + 1];
    let mut v8 = vec![[0f32; GRID]; GRID];
    let mut liquid_entry = [[0u16; CELLS]; CELLS];
    let mut liquid_flags = [[0u8; CELLS]; CELLS];
    let mut liquid_show = vec![[false; GRID]; GRID];
    let mut liquid_height = vec![[0f32; GRID + 1]; GRID + 1];
    let mut holes = [[0u16; CELLS]; CELLS];
    let areas = t.areas();

    for i in 0..CELLS {
        for j in 0..CELLS {
            // i: the chunk's row (MCIN order), j: its column
            let id = areas[i * CELLS + j];
            if id != 0 {
                if let Some(f) = flags_of(id) {
                    area[i][j] = f;
                }
            }
            holes[i][j] = t.holes(j, i) as u16;
            let hs = t.chunk_heights(j, i).with_context(|| format!("map chunk {j},{i} missing"))?;
            for y in 0..=CELL {
                for x in 0..=CELL {
                    v9[i * CELL + y][j * CELL + x] = hs[y * 17 + x];
                }
            }
            for y in 0..CELL {
                for x in 0..CELL {
                    v8[i * CELL + y][j * CELL + x] = hs[y * 17 + 9 + x];
                }
            }
            if let Some(l) = t.liquid(j, i) {
                let mut count = 0;
                for y in 0..CELL {
                    for x in 0..CELL {
                        let f = l.tiles[y * 8 + x];
                        if f != 0x0F {
                            liquid_show[i * CELL + y][j * CELL + x] = true;
                            if f & 0x80 != 0 {
                                liquid_flags[i][j] |= LT_DEEP;
                            }
                            count += 1;
                        }
                    }
                }
                // the extractor reads the chunk's flag bits; slime has none it knows
                match l.kind {
                    adt::LiquidKind::River => {
                        liquid_entry[i][j] = 1;
                        liquid_flags[i][j] |= LT_WATER;
                    }
                    adt::LiquidKind::Ocean => {
                        liquid_entry[i][j] = 2;
                        liquid_flags[i][j] |= LT_OCEAN;
                    }
                    adt::LiquidKind::Magma => {
                        liquid_entry[i][j] = 3;
                        liquid_flags[i][j] |= LT_MAGMA;
                    }
                    adt::LiquidKind::Slime => {}
                }
                let _ = count;
                for y in 0..=CELL {
                    for x in 0..=CELL {
                        liquid_height[i * CELL + y][j * CELL + x] = l.verts[y * 9 + x].1;
                    }
                }
            }
        }
    }

    let mut out = vec![0u8; 40];
    // ---- area
    let first = area[0][0];
    let full_area = area.iter().flatten().any(|&a| a != first);
    let area_ofs = 40u32;
    out.extend(b"AREA");
    out.extend((if full_area { 0 } else { AREA_NO_AREA }).to_le_bytes());
    out.extend((if full_area { 0 } else { first }).to_le_bytes());
    if full_area {
        for a in area.iter().flatten() {
            out.extend(a.to_le_bytes());
        }
    }
    let area_size = out.len() as u32 - area_ofs;

    // ---- heights
    let (mut lo, mut hi) = (20000f32, -20000f32);
    for h in v8.iter().flatten().chain(v9.iter().flatten()) {
        hi = hi.max(*h);
        lo = lo.min(*h);
    }
    if lo < MIN_HEIGHT {
        for h in v8.iter_mut().flatten().chain(v9.iter_mut().flatten()) {
            *h = h.max(MIN_HEIGHT);
        }
        lo = lo.max(MIN_HEIGHT);
        hi = hi.max(MIN_HEIGHT);
    }
    let height_ofs = out.len() as u32;
    let mut hflags = 0u32;
    if hi == lo || hi - lo < FLAT_HEIGHT {
        hflags |= HEIGHT_NO_HEIGHT;
    }
    let mut step = 0f32;
    if hflags & HEIGHT_NO_HEIGHT == 0 {
        let diff = hi - lo;
        if diff < INT8_LIMIT {
            hflags |= HEIGHT_AS_INT8;
            step = 255.0 / diff;
        } else if diff < INT16_LIMIT {
            hflags |= HEIGHT_AS_INT16;
            step = 65535.0 / diff;
        }
    }
    out.extend(b"MHGT");
    out.extend(u32_le(hflags));
    out.extend(lo.to_le_bytes());
    out.extend(hi.to_le_bytes());
    if hflags & HEIGHT_NO_HEIGHT == 0 {
        let rows9 = v9.iter().flatten();
        let rows8 = v8.iter().flatten();
        if hflags & HEIGHT_AS_INT16 != 0 {
            for h in rows9.chain(rows8) {
                out.extend((((h - lo) * step + 0.5) as u16).to_le_bytes());
            }
        } else if hflags & HEIGHT_AS_INT8 != 0 {
            for h in rows9.chain(rows8) {
                out.push(((h - lo) * step + 0.5) as u8);
            }
        } else {
            for h in rows9.chain(rows8) {
                out.extend(h.to_le_bytes());
            }
        }
    }
    let height_size = out.len() as u32 - height_ofs;

    // ---- water
    let (fe, ff) = (liquid_entry[0][0], liquid_flags[0][0]);
    let full_type = (0..CELLS).any(|y| (0..CELLS).any(|x| liquid_entry[y][x] != fe || liquid_flags[y][x] != ff));
    let (mut liquid_ofs, mut liquid_size) = (0u32, 0u32);
    if ff != 0 || full_type {
        let (mut min_x, mut min_y, mut max_x, mut max_y) = (255usize, 255usize, 0usize, 0usize);
        let (mut lo, mut hi) = (20000f32, -20000f32);
        for y in 0..GRID {
            for x in 0..GRID {
                if liquid_show[y][x] {
                    min_x = min_x.min(x);
                    max_x = max_x.max(x);
                    min_y = min_y.min(y);
                    max_y = max_y.max(y);
                    hi = hi.max(liquid_height[y][x]);
                    lo = lo.min(liquid_height[y][x]);
                } else {
                    liquid_height[y][x] = MIN_HEIGHT;
                    lo = lo.min(MIN_HEIGHT);
                }
            }
        }
        if min_x == 255 {
            // flagged water with no tile shown (the extractor warns; its header would overflow)
            (min_x, min_y, max_x, max_y) = (0, 0, 0, 0);
        }
        let (w, h) = (max_x - min_x + 2, max_y - min_y + 2);
        let mut lf = 0u8;
        if hi == lo || hi - lo < FLAT_LIQUID {
            lf |= LIQUID_NO_HEIGHT;
        }
        if !full_type {
            lf |= LIQUID_NO_TYPE;
        }
        liquid_ofs = out.len() as u32;
        out.extend(b"MLIQ");
        out.push(lf);
        out.push(if lf & LIQUID_NO_TYPE != 0 { ff } else { 0 });
        out.extend((if lf & LIQUID_NO_TYPE != 0 { fe } else { 0 }).to_le_bytes());
        out.extend([min_x as u8, min_y as u8, w as u8, h as u8]);
        out.extend(lo.to_le_bytes());
        if lf & LIQUID_NO_TYPE == 0 {
            for e in liquid_entry.iter().flatten() {
                out.extend(e.to_le_bytes());
            }
            out.extend(liquid_flags.iter().flatten());
        }
        if lf & LIQUID_NO_HEIGHT == 0 {
            for y in 0..h {
                for x in 0..w {
                    out.extend(liquid_height[y + min_y][x + min_x].to_le_bytes());
                }
            }
        }
        liquid_size = out.len() as u32 - liquid_ofs;
    }

    // ---- holes
    let holes_ofs = out.len() as u32;
    for hm in holes.iter().flatten() {
        out.extend(hm.to_le_bytes());
    }
    let mut head = vec![];
    head.extend(b"MAPS");
    head.extend(version);
    for v in [area_ofs, area_size, height_ofs, height_size, liquid_ofs, liquid_size, holes_ofs, 512] {
        head.extend(u32_le(v));
    }
    out[..40].copy_from_slice(&head);
    Ok(out)
}

/// Read back a .map's ground height at a grid vertex (V9), the way the server does: for tests
/// and for checking a conversion.
pub fn v9_height(map: &[u8], gx: usize, gy: usize) -> Option<f32> {
    let u = |o: usize| u32::from_le_bytes(map[o..o + 4].try_into().unwrap());
    let f = |o: usize| f32::from_le_bytes(map[o..o + 4].try_into().unwrap());
    let ho = u(16) as usize;
    let (flags, lo, hi) = (u(ho + 4), f(ho + 8), f(ho + 12));
    let k = gy * (GRID + 1) + gx;
    let d = ho + 16;
    Some(if flags & HEIGHT_NO_HEIGHT != 0 {
        lo
    } else if flags & HEIGHT_AS_INT16 != 0 {
        lo + u16::from_le_bytes(map[d + k * 2..d + k * 2 + 2].try_into().unwrap()) as f32 * ((hi - lo) / 65535.0)
    } else if flags & HEIGHT_AS_INT8 != 0 {
        lo + map[d + k] as f32 * ((hi - lo) / 255.0)
    } else {
        f(d + k * 4)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adt::tests::fake_tile;
    use crate::adt::{Liquid, LiquidKind};

    fn u(m: &[u8], o: usize) -> u32 {
        u32::from_le_bytes(m[o..o + 4].try_into().unwrap())
    }

    #[test]
    fn flat_tile_packs_small() {
        let t = Adt::parse(&fake_tile(32, 48, 50.0)).unwrap();
        let m = convert(&t, &|_| Some(7), VERSION).unwrap();
        assert_eq!(&m[..8], b"MAPSz1.4");
        // flat: no height grid; one area: no area grid; no water
        assert_eq!(u(&m, 12), 8, "area header only");
        assert_eq!(u(&m, 20), 16, "height header only");
        assert_eq!((u(&m, 24), u(&m, 28)), (0, 0), "no water");
        assert_eq!(u(&m, 36), 512);
        assert_eq!(m.len(), 40 + 8 + 16 + 512);
        assert_eq!(v9_height(&m, 10, 10), Some(50.0));
        assert_eq!(u16::from_le_bytes([m[46], m[47]]), 7, "the area's flag");
        assert_eq!(file_name(0, 32, 48), "0004832.map");
    }

    #[test]
    fn hills_water_holes_and_areas() {
        let mut t = Adt::parse(&fake_tile(32, 48, 50.0)).unwrap();
        // a 30-yard hill in one chunk: 16-bit steps
        let mut hs = t.chunk_heights(5, 6).unwrap();
        hs[4 * 17 + 4] = 80.0;
        t.set_chunk_heights(5, 6, &hs).unwrap();
        t.set_area(0, 0, 12).unwrap();
        t.set_area(1, 0, 87).unwrap();
        t.set_holes(2, 3, 0x0021).unwrap();
        let mut l = Liquid::flat(LiquidKind::River, 52.0);
        l.tiles[0] = 4 | 0x80;
        t.set_liquid(7, 9, Some(&l)).unwrap();
        let m = convert(&t, &|id| match id {
            12 => Some(1),
            87 => Some(2),
            _ => None,
        }, VERSION)
        .unwrap();
        assert_eq!(u(&m, 12), 8 + 512, "areas vary: the full grid");
        let ho = u(&m, 16) as usize;
        assert_eq!(u(&m, ho + 4), HEIGHT_AS_INT16);
        // the hill's top: V9 at chunk (5, 6) vertex (4, 4) → grid (5·8+4, 6·8+4)
        let top = v9_height(&m, 44, 52).unwrap();
        assert!((top - 80.0).abs() < 0.01, "{top}");
        assert!((v9_height(&m, 0, 0).unwrap() - 50.0).abs() < 0.01);
        // water: one tile at grid (56, 72)
        let lo = u(&m, 24) as usize;
        assert_eq!(&m[lo..lo + 4], b"MLIQ");
        // only one chunk has water: per-chunk types; the surface beside it is -500: heights stored
        assert_eq!(m[lo + 4], 0);
        assert_eq!((m[lo + 8], m[lo + 9], m[lo + 10], m[lo + 11]), (56, 72, 2, 2));
        let types = lo + 16;
        assert_eq!(u16::from_le_bytes([m[types + (9 * 16 + 7) * 2], m[types + (9 * 16 + 7) * 2 + 1]]), 1, "water");
        assert_eq!(m[types + 512 + 9 * 16 + 7], LT_WATER | LT_DEEP);
        let hgt = types + 512 + 256;
        assert_eq!(f32::from_le_bytes(m[hgt..hgt + 4].try_into().unwrap()), 52.0);
        assert_eq!(u(&m, 28) as usize, 16 + 512 + 256 + 2 * 2 * 4);
        // holes at the end, row-major (row 3, col 2)
        let hof = u(&m, 32) as usize;
        assert_eq!(u16::from_le_bytes([m[hof + (3 * 16 + 2) * 2], m[hof + (3 * 16 + 2) * 2 + 1]]), 0x0021);
        assert_eq!(hof + 512, m.len());
    }
}
