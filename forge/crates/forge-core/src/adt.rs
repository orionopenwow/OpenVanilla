//! 1.12 terrain tiles (ADT v18): read, and change surgically (plan §5.2, Phase 3/4).
//!
//! A tile is a run of chunks: MVER MHDR MCIN MTEX MMDX MMID MWMO MWID MDDF MODF, then 256 MCNK
//! (16 × 16 map chunks, each with its own sub-chunks: MCVT heights, MCNR normals, MCLY layers,
//! MCRF object references, MCSH, MCAL, MCLQ water, MCSE sounds).
//!
//! Forge edits a tile **in place**: it keeps every byte it doesn't change and only rewrites the
//! chunks an edit touches, fixing up MHDR's and MCIN's offsets and the MCNK header's own
//! sub-chunk offsets. An unedited tile writes back byte for byte (tested on real tiles).
//!
//! Coordinates: the server/`.gps` world has X north, Y west, Z up. A tile's file coordinates are
//! `fx = 32·533⅓ − worldY`, `fz = 32·533⅓ − worldX`, `fy = worldZ`. Tile `Map_A_B.adt` covers
//! `A = ⌊fx / 533⅓⌋`, `B = ⌊fz / 533⅓⌋`; its chunk `(col, row)` is 33⅓ yards across.

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};

pub const TILE: f64 = 1600.0 / 3.0; // 533.333 yards
pub const CHUNK: f64 = TILE / 16.0; // 33.333 yards
pub const HALF: f64 = 32.0 * TILE; // 17066.666: the world's centre in file coordinates

/// MCNK header field offsets (from the start of the MCNK chunk, its 8-byte header included).
mod h {
    pub const N_DOODAD_REFS: usize = 8 + 0x10;
    pub const OFS_HEIGHT: usize = 8 + 0x14;
    pub const OFS_NORMAL: usize = 8 + 0x18;
    pub const N_LAYERS: usize = 8 + 0x0C;
    pub const OFS_LAYER: usize = 8 + 0x1C;
    pub const OFS_ALPHA: usize = 8 + 0x24;
    pub const SIZE_ALPHA: usize = 8 + 0x28;
    pub const OFS_SHADOW: usize = 8 + 0x2C;
    pub const OFS_REFS: usize = 8 + 0x20;
    pub const AREA: usize = 8 + 0x34;
    pub const N_MAPOBJ_REFS: usize = 8 + 0x38;
    pub const HOLES: usize = 8 + 0x3C;
    pub const POSITION: usize = 8 + 0x68;
    pub const FLAGS: usize = 8;
    pub const OFS_LIQUID: usize = 8 + 0x60;
    pub const SIZE_LIQUID: usize = 8 + 0x64;
    /// Every sub-chunk offset in the header (shifted when something before them grows).
    pub const OFFSETS: &[usize] = &[8 + 0x14, 8 + 0x18, 8 + 0x1C, 8 + 0x20, 8 + 0x24, 8 + 0x2C, 8 + 0x58, 8 + 0x60];
}

fn u32_at(b: &[u8], o: usize) -> u32 {
    u32::from_le_bytes(b[o..o + 4].try_into().unwrap())
}
fn f32_at(b: &[u8], o: usize) -> f32 {
    f32::from_le_bytes(b[o..o + 4].try_into().unwrap())
}
fn put_u32(b: &mut [u8], o: usize, v: u32) {
    b[o..o + 4].copy_from_slice(&v.to_le_bytes());
}

/// One top-level chunk: its magic as read forwards ("MVER"), and its whole bytes (header included).
#[derive(Debug, Clone)]
pub struct Chunk {
    pub magic: String,
    pub bytes: Vec<u8>,
    /// Its length when read (MCIN's size fields are kept relative to it).
    pub orig_len: usize,
}

impl Chunk {
    fn body(&self) -> &[u8] {
        &self.bytes[8..]
    }
    fn new(magic: &str, body: &[u8]) -> Chunk {
        let mut bytes = Vec::with_capacity(body.len() + 8);
        bytes.extend(magic.bytes().rev());
        bytes.extend((body.len() as u32).to_le_bytes());
        bytes.extend_from_slice(body);
        let orig_len = bytes.len();
        Chunk { magic: magic.into(), bytes, orig_len }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Doodad {
    /// The model as the tile names it (`World\...\Tree01.mdx`).
    pub model: String,
    pub uid: u32,
    /// File coordinates (x, height, z).
    pub pos: [f32; 3],
    /// Degrees.
    pub rot: [f32; 3],
    /// 1024 = 1.0.
    pub scale: u16,
    pub flags: u16,
    /// A building (WMO, in MODF): its bounding box in file coordinates (lower x, y, z, upper
    /// x, y, z). None: a doodad (M2, in MDDF).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub extents: Option<[f32; 6]>,
    /// A building's doodad set (its furniture, beside the default set every copy shows).
    #[serde(default)]
    pub set: u16,
}

#[derive(Debug, Clone)]
pub struct Adt {
    pub chunks: Vec<Chunk>,
    /// Bytes after the last chunk (kept as they were).
    pub tail: Vec<u8>,
}

/// World (server) X, Y → (tile A, tile B).
pub fn tile_of(world_x: f64, world_y: f64) -> (i32, i32) {
    (((HALF - world_y) / TILE).floor() as i32, ((HALF - world_x) / TILE).floor() as i32)
}

/// World X, Y, Z → file coordinates.
pub fn to_file(world_x: f64, world_y: f64, world_z: f64) -> [f32; 3] {
    [(HALF - world_y) as f32, world_z as f32, (HALF - world_x) as f32]
}

pub fn tile_path(map: &str, a: i32, b: i32) -> String {
    format!("World\\Maps\\{map}\\{map}_{a}_{b}.adt")
}

/// A new, flat 1.12 tile: ground at `height`, one texture, every sub-chunk the game and the
/// server's extractor expect (heights, up-pointing normals, one layer, shadows, empty alpha and
/// water), the chunks' positions in world coordinates, area `area`.
pub fn new_tile(a: i32, b: i32, height: f32, texture: &str, area: u32) -> Vec<u8> {
    fn chunk(magic: &str, body: &[u8]) -> Vec<u8> {
        let mut v: Vec<u8> = magic.bytes().rev().collect();
        v.extend((body.len() as u32).to_le_bytes());
        v.extend_from_slice(body);
        v
    }
    let mut mcnks: Vec<Vec<u8>> = vec![];
    for row in 0..16u32 {
        for col in 0..16u32 {
            let mut normals = vec![0u8; 145 * 3 + 13];
            for k in 0..145 {
                normals[k * 3 + 2] = 127; // up (the 1.12 layout: -z, -x, up)
            }
            let subs = [
                chunk("MCVT", &[0u8; 145 * 4]),
                chunk("MCNR", &normals),
                chunk("MCLY", &[0u8; 16]),
                chunk("MCRF", &[]),
                chunk("MCSH", &[0u8; 512]),
                chunk("MCAL", &[]),
                chunk("MCLQ", &[]),
            ];
            let mut hdr = vec![0u8; 128];
            let mut offs = vec![];
            let mut o = 8 + 128;
            for sc in &subs {
                offs.push(o as u32);
                o += sc.len();
            }
            let put = |h: &mut Vec<u8>, at: usize, v: u32| h[at..at + 4].copy_from_slice(&v.to_le_bytes());
            put(&mut hdr, 0x00, 1); // has MCSH
            put(&mut hdr, 0x04, col);
            put(&mut hdr, 0x08, row);
            put(&mut hdr, 0x0C, 1);
            for (f, k) in [(0x14, 0), (0x18, 1), (0x1C, 2), (0x20, 3), (0x2C, 4), (0x24, 5), (0x60, 6)] {
                put(&mut hdr, f, offs[k]);
            }
            put(&mut hdr, 0x28, 8);
            put(&mut hdr, 0x30, 512);
            put(&mut hdr, 0x34, area);
            put(&mut hdr, 0x64, 8);
            let (fx0, fz0) = (a as f64 * TILE + col as f64 * CHUNK, b as f64 * TILE + row as f64 * CHUNK);
            for (k, v) in [(HALF - fz0) as f32, (HALF - fx0) as f32, height].iter().enumerate() {
                hdr[0x68 + k * 4..0x6C + k * 4].copy_from_slice(&v.to_le_bytes());
            }
            let mut body = hdr;
            for sc in subs {
                body.extend(sc);
            }
            mcnks.push(chunk("MCNK", &body));
        }
    }
    let mut tex = texture.as_bytes().to_vec();
    tex.push(0);
    let tops = [
        chunk("MVER", &18u32.to_le_bytes()),
        chunk("MHDR", &[0u8; 64]),
        chunk("MCIN", &[0u8; 256 * 16]),
        chunk("MTEX", &tex),
        chunk("MMDX", &[]),
        chunk("MMID", &[]),
        chunk("MWMO", &[]),
        chunk("MWID", &[]),
        chunk("MDDF", &[]),
        chunk("MODF", &[]),
    ];
    let mut out = vec![];
    let mut at = vec![];
    for t in &tops {
        at.push(out.len());
        out.extend(t);
    }
    let mhdr_data = at[1] + 8;
    for k in 0..8 {
        put_u32(&mut out, mhdr_data + 4 + k * 4, (at[2 + k] - mhdr_data) as u32);
    }
    let mcin = at[2] + 8;
    for (k, m) in mcnks.iter().enumerate() {
        let here = out.len() as u32;
        put_u32(&mut out, mcin + k * 16, here);
        put_u32(&mut out, mcin + k * 16 + 4, m.len() as u32);
        out.extend(m);
    }
    out
}

/// A map's WDT: which of the 64 × 64 tiles exist (`Map_A_B.adt` at MAIN[B·64 + A]).
pub fn new_wdt(tiles: &[(i32, i32)]) -> Vec<u8> {
    let mut main = vec![0u8; 64 * 64 * 8];
    for &(a, b) in tiles {
        if (0..64).contains(&a) && (0..64).contains(&b) {
            put_u32(&mut main, (b as usize * 64 + a as usize) * 8, 1);
        }
    }
    let mut out = vec![];
    for (m, body) in [("MVER", 18u32.to_le_bytes().to_vec()), ("MPHD", vec![0u8; 32]), ("MAIN", main), ("MWMO", vec![])] {
        out.extend(m.bytes().rev());
        out.extend((body.len() as u32).to_le_bytes());
        out.extend(body);
    }
    out
}

/// The tiles a WDT says exist.
pub fn wdt_tiles(wdt: &[u8]) -> Vec<(i32, i32)> {
    let mut pos = 0;
    while pos + 8 <= wdt.len() {
        let n = u32_at(wdt, pos + 4) as usize;
        if &wdt[pos..pos + 4] == b"NIAM" {
            return (0..64 * 64).filter(|k| pos + 8 + k * 8 + 4 <= wdt.len() && u32_at(wdt, pos + 8 + k * 8) & 1 != 0).map(|k| ((k % 64) as i32, (k / 64) as i32)).collect();
        }
        pos += 8 + n;
    }
    vec![]
}

impl Adt {
    pub fn parse(b: &[u8]) -> Result<Adt> {
        let mut chunks = vec![];
        let mut o = 0usize;
        while o + 8 <= b.len() {
            let magic: String = b[o..o + 4].iter().rev().map(|&c| c as char).collect();
            if !magic.chars().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit()) {
                break;
            }
            let size = u32_at(b, o + 4) as usize;
            let end = o + 8 + size;
            if end > b.len() {
                bail!("{magic} at {o} runs past the end of the file");
            }
            chunks.push(Chunk { magic, bytes: b[o..end].to_vec(), orig_len: end - o });
            o = end;
        }
        let a = Adt { chunks, tail: b[o..].to_vec() };
        if a.chunks.first().map(|c| c.magic.as_str()) != Some("MVER") || a.find("MHDR").is_none() {
            bail!("not an ADT tile");
        }
        if a.mcnk_indices().len() != 256 {
            bail!("an ADT has 256 map chunks, this one {}", a.mcnk_indices().len());
        }
        Ok(a)
    }

    pub fn find(&self, magic: &str) -> Option<usize> {
        self.chunks.iter().position(|c| c.magic == magic)
    }

    fn mcnk_indices(&self) -> Vec<usize> {
        self.chunks.iter().enumerate().filter(|(_, c)| c.magic == "MCNK").map(|(i, _)| i).collect()
    }

    /// The map chunk at (col, row), by its own header indices.
    pub fn mcnk(&self, col: usize, row: usize) -> Option<usize> {
        self.mcnk_indices().into_iter().find(|&i| {
            let b = &self.chunks[i].bytes;
            u32_at(b, 8 + 4) as usize == col && u32_at(b, 8 + 8) as usize == row
        })
    }

    /// Write the tile: chunks in order, MHDR and MCIN offsets recomputed from where things are now.
    pub fn write(&self) -> Vec<u8> {
        let mut offsets = vec![];
        let mut o = 0usize;
        for c in &self.chunks {
            offsets.push(o);
            o += c.bytes.len();
        }
        let mut out = Vec::with_capacity(o + self.tail.len());
        for c in &self.chunks {
            out.extend_from_slice(&c.bytes);
        }
        out.extend_from_slice(&self.tail);
        // MHDR: offsets of the top chunks, relative to MHDR's data
        if let Some(mh) = self.find("MHDR") {
            let base = offsets[mh] + 8;
            let names = ["MCIN", "MTEX", "MMDX", "MMID", "MWMO", "MWID", "MDDF", "MODF"];
            for (k, n) in names.iter().enumerate() {
                let field = base + 4 + k * 4;
                if u32_at(&out, field) == 0 {
                    continue; // absent stays absent
                }
                if let Some(ci) = self.find(n) {
                    put_u32(&mut out, field, (offsets[ci] - base) as u32);
                }
            }
        }
        // MCIN: each MCNK's absolute offset and size
        if let Some(mi) = self.find("MCIN") {
            let base = offsets[mi] + 8;
            for (k, ci) in self.mcnk_indices().into_iter().enumerate() {
                let old_size = u32_at(&self.chunks[mi].bytes, 8 + k * 16 + 4) as i64;
                let old_chunk = self.chunks[ci].orig_len as i64;
                let now = self.chunks[ci].bytes.len() as i64;
                put_u32(&mut out, base + k * 16, offsets[ci] as u32);
                put_u32(&mut out, base + k * 16 + 4, (old_size + now - old_chunk) as u32);
            }
        }
        out
    }

    // ------------------------------------------------------------ doodads

    fn strings(&self, magic: &str) -> Vec<(u32, String)> {
        let Some(i) = self.find(magic) else { return vec![] };
        let body = self.chunks[i].body();
        let mut out = vec![];
        let mut start = 0;
        for (k, &c) in body.iter().enumerate() {
            if c == 0 {
                if k > start {
                    out.push((start as u32, String::from_utf8_lossy(&body[start..k]).to_string()));
                }
                start = k + 1;
            }
        }
        out
    }

    pub fn doodads(&self) -> Vec<Doodad> {
        let names = self.strings("MMDX");
        let ids: Vec<u32> = self.find("MMID").map(|i| self.chunks[i].body().chunks(4).map(|c| u32::from_le_bytes(c.try_into().unwrap())).collect()).unwrap_or_default();
        let Some(i) = self.find("MDDF") else { return vec![] };
        self.chunks[i]
            .body()
            .chunks_exact(36)
            .map(|e| {
                let name_off = ids.get(u32_at(e, 0) as usize).copied().unwrap_or(u32::MAX);
                Doodad {
                    model: names.iter().find(|(o, _)| *o == name_off).map(|x| x.1.clone()).unwrap_or_default(),
                    uid: u32_at(e, 4),
                    pos: [f32_at(e, 8), f32_at(e, 12), f32_at(e, 16)],
                    rot: [f32_at(e, 20), f32_at(e, 24), f32_at(e, 28)],
                    scale: u16::from_le_bytes([e[32], e[33]]),
                    flags: u16::from_le_bytes([e[34], e[35]]),
                    extents: None,
                    set: 0,
                }
            })
            .collect()
    }

    /// The buildings (WMOs) placed on the tile (MODF), with their bounding boxes.
    pub fn wmos(&self) -> Vec<Doodad> {
        let names = self.strings("MWMO");
        let ids: Vec<u32> = self.find("MWID").map(|i| self.chunks[i].body().chunks(4).map(|c| u32::from_le_bytes(c.try_into().unwrap())).collect()).unwrap_or_default();
        let Some(i) = self.find("MODF") else { return vec![] };
        self.chunks[i]
            .body()
            .chunks_exact(64)
            .map(|e| {
                let name_off = ids.get(u32_at(e, 0) as usize).copied().unwrap_or(u32::MAX);
                let f = |k: usize| f32_at(e, 8 + k * 4);
                Doodad {
                    model: names.iter().find(|(o, _)| *o == name_off).map(|x| x.1.clone()).unwrap_or_default(),
                    uid: u32_at(e, 4),
                    pos: [f(0), f(1), f(2)],
                    rot: [f(3), f(4), f(5)],
                    scale: 1024,
                    flags: u16::from_le_bytes([e[56], e[57]]),
                    extents: Some([f(6), f(7), f(8), f(9), f(10), f(11)]),
                    set: u16::from_le_bytes([e[58], e[59]]),
                }
            })
            .collect()
    }

    /// A name's index in a name table (MMDX/MMID or MWMO/MWID), adding it when it's new.
    fn name_index(&mut self, names_chunk: &str, ids_chunk: &str, name: &str) -> Result<u32> {
        let (nc, ic) = (self.find(names_chunk).with_context(|| format!("no {names_chunk}"))?, self.find(ids_chunk).with_context(|| format!("no {ids_chunk}"))?);
        let names = self.strings(names_chunk);
        let ids: Vec<u32> = self.chunks[ic].body().chunks(4).map(|c| u32::from_le_bytes(c.try_into().unwrap())).collect();
        let off = match names.iter().find(|(_, n)| n.eq_ignore_ascii_case(name)) {
            Some((o, _)) => *o,
            None => {
                let mut body = self.chunks[nc].body().to_vec();
                let o = body.len() as u32;
                body.extend(name.as_bytes());
                body.push(0);
                self.chunks[nc] = Chunk::new(names_chunk, &body);
                o
            }
        };
        Ok(match ids.iter().position(|&x| x == off) {
            Some(k) => k as u32,
            None => {
                let mut body = self.chunks[ic].body().to_vec();
                body.extend(off.to_le_bytes());
                self.chunks[ic] = Chunk::new(ids_chunk, &body);
                ids.len() as u32
            }
        })
    }

    /// Add buildings: MWMO/MWID names, MODF placements, and a reference in every map chunk of
    /// the tile their bounding box covers (the client draws a building from the chunks that
    /// name it). A building over several tiles goes into each of them with the same uid.
    pub fn add_wmos(&mut self, tile: (i32, i32), list: &[Doodad]) -> Result<()> {
        let modf = self.find("MODF").context("no MODF")?;
        for d in list {
            let e = d.extents.context("a building needs its bounding box")?;
            let name_id = self.name_index("MWMO", "MWID", &d.model)?;
            let mut body = self.chunks[modf].body().to_vec();
            let index = (body.len() / 64) as u32;
            body.extend(name_id.to_le_bytes());
            body.extend(d.uid.to_le_bytes());
            for v in d.pos.iter().chain(d.rot.iter()).chain(e.iter()) {
                body.extend(v.to_le_bytes());
            }
            body.extend(d.flags.to_le_bytes());
            body.extend(d.set.to_le_bytes());
            body.extend([0u8; 4]); // name set 0, padding
            self.chunks[modf] = Chunk::new("MODF", &body);
            let (x0, z0) = (tile.0 as f64 * TILE, tile.1 as f64 * TILE);
            let c0 = (((e[0] as f64 - x0) / CHUNK).floor().max(0.0) as usize).min(15);
            let c1 = (((e[3] as f64 - x0) / CHUNK).floor().max(0.0) as usize).min(15);
            let r0 = (((e[2] as f64 - z0) / CHUNK).floor().max(0.0) as usize).min(15);
            let r1 = (((e[5] as f64 - z0) / CHUNK).floor().max(0.0) as usize).min(15);
            if e[3] as f64 <= x0 || e[0] as f64 >= x0 + TILE || e[5] as f64 <= z0 || e[2] as f64 >= z0 + TILE {
                bail!("{} doesn't reach tile {}_{}", d.model, tile.0, tile.1);
            }
            for row in r0..=r1 {
                for col in c0..=c1 {
                    let ci = self.mcnk(col, row).context("map chunk missing")?;
                    add_wmo_ref(&mut self.chunks[ci].bytes, index)?;
                }
            }
        }
        Ok(())
    }

    /// Add doodads: their model names (once each) to MMDX/MMID, the placements to MDDF, and a
    /// reference in the map chunk under each one (so the client draws it there). Buildings
    /// (with extents) go to `add_wmos`.
    pub fn add_doodads(&mut self, tile: (i32, i32), list: &[Doodad]) -> Result<()> {
        let (wmos, list): (Vec<Doodad>, Vec<Doodad>) = list.iter().cloned().partition(|d| d.extents.is_some());
        self.add_wmos(tile, &wmos)?;
        let list = &list[..];
        let (mmdx, mmid, mddf) = (
            self.find("MMDX").context("no MMDX")?,
            self.find("MMID").context("no MMID")?,
            self.find("MDDF").context("no MDDF")?,
        );
        for d in list {
            // the model's name index
            let names = self.strings("MMDX");
            let ids: Vec<u32> = self.chunks[mmid].body().chunks(4).map(|c| u32::from_le_bytes(c.try_into().unwrap())).collect();
            let off = match names.iter().find(|(_, n)| n.eq_ignore_ascii_case(&d.model)) {
                Some((o, _)) => *o,
                None => {
                    let mut body = self.chunks[mmdx].body().to_vec();
                    let o = body.len() as u32;
                    body.extend(d.model.as_bytes());
                    body.push(0);
                    self.chunks[mmdx] = Chunk::new("MMDX", &body);
                    o
                }
            };
            let name_id = match ids.iter().position(|&x| x == off) {
                Some(k) => k as u32,
                None => {
                    let mut body = self.chunks[mmid].body().to_vec();
                    body.extend(off.to_le_bytes());
                    self.chunks[mmid] = Chunk::new("MMID", &body);
                    ids.len() as u32
                }
            };
            // the placement
            let mut body = self.chunks[mddf].body().to_vec();
            let index = (body.len() / 36) as u32;
            body.extend(name_id.to_le_bytes());
            body.extend(d.uid.to_le_bytes());
            for v in d.pos.iter().chain(d.rot.iter()) {
                body.extend(v.to_le_bytes());
            }
            body.extend(d.scale.to_le_bytes());
            body.extend(d.flags.to_le_bytes());
            self.chunks[mddf] = Chunk::new("MDDF", &body);
            // the map chunk it stands in
            let (col, row) = chunk_of(tile, d.pos).with_context(|| format!("{} isn't on tile {}_{}", d.model, tile.0, tile.1))?;
            let ci = self.mcnk(col, row).context("map chunk missing")?;
            add_ref(&mut self.chunks[ci].bytes, index)?;
        }
        Ok(())
    }

    /// Stop the client drawing the doodads and buildings with these uids: their references come
    /// out of every map chunk (the placements stay listed, unreferenced). Returns how many.
    pub fn hide_objects(&mut self, uids: &[u32]) -> Result<usize> {
        let dh: Vec<u32> = self.doodads().iter().enumerate().filter(|(_, d)| uids.contains(&d.uid)).map(|(i, _)| i as u32).collect();
        let wh: Vec<u32> = self.wmos().iter().enumerate().filter(|(_, d)| uids.contains(&d.uid)).map(|(i, _)| i as u32).collect();
        if dh.is_empty() && wh.is_empty() {
            return Ok(0);
        }
        for ci in self.mcnk_indices() {
            let b = &self.chunks[ci].bytes;
            let refs = u32_at(b, h::OFS_REFS) as usize;
            if refs == 0 || refs + 8 > b.len() {
                continue;
            }
            let (nd, nw) = (u32_at(b, h::N_DOODAD_REFS) as usize, u32_at(b, h::N_MAPOBJ_REFS) as usize);
            let all: Vec<u32> = (0..nd + nw).map(|k| u32_at(b, refs + 8 + k * 4)).collect();
            let d: Vec<u32> = all[..nd].iter().copied().filter(|x| !dh.contains(x)).collect();
            let w: Vec<u32> = all[nd..].iter().copied().filter(|x| !wh.contains(x)).collect();
            if d.len() != nd || w.len() != nw {
                set_refs(&mut self.chunks[ci].bytes, &d, &w)?;
            }
        }
        Ok(dh.len() + wh.len())
    }

    /// Which uids the map chunks still reference (what the client draws).
    pub fn drawn_uids(&self) -> Vec<u32> {
        let (ds, ws) = (self.doodads(), self.wmos());
        let mut out = vec![];
        for ci in self.mcnk_indices() {
            let b = &self.chunks[ci].bytes;
            let refs = u32_at(b, h::OFS_REFS) as usize;
            if refs == 0 || refs + 8 > b.len() {
                continue;
            }
            let (nd, nw) = (u32_at(b, h::N_DOODAD_REFS) as usize, u32_at(b, h::N_MAPOBJ_REFS) as usize);
            for k in 0..nd + nw {
                let i = u32_at(b, refs + 8 + k * 4) as usize;
                if let Some(x) = if k < nd { ds.get(i) } else { ws.get(i) } {
                    if !out.contains(&x.uid) {
                        out.push(x.uid);
                    }
                }
            }
        }
        out
    }

    // ------------------------------------------------------------ heights

    /// Ground height at file (x, z), from the map chunk's outer height grid (bilinear).
    pub fn height_at(&self, tile: (i32, i32), fx: f64, fz: f64) -> Option<f64> {
        let (col, row) = chunk_of(tile, [fx as f32, 0.0, fz as f32])?;
        let b = &self.chunks[self.mcnk(col, row)?].bytes;
        let base = f32_at(b, h::POSITION + 8) as f64;
        let mcvt = u32_at(b, h::OFS_HEIGHT) as usize + 8;
        let x0 = tile.0 as f64 * TILE + col as f64 * CHUNK;
        let z0 = tile.1 as f64 * TILE + row as f64 * CHUNK;
        let step = CHUNK / 8.0;
        let (gx, gz) = (((fx - x0) / step).clamp(0.0, 7.999), ((fz - z0) / step).clamp(0.0, 7.999));
        let (i, j) = (gz.floor() as usize, gx.floor() as usize);
        let (u, v) = (gx - j as f64, gz - i as f64);
        let at = |i: usize, j: usize| f32_at(b, mcvt + (i * 17 + j) * 4) as f64;
        let hgt = at(i, j) * (1.0 - u) * (1.0 - v) + at(i, j + 1) * u * (1.0 - v) + at(i + 1, j) * (1.0 - u) * v + at(i + 1, j + 1) * u * v;
        Some(base + hgt)
    }

    /// The tile's outer height grid as 129 × 129 heights (row-major, file z then x), for the World
    /// screen's map.
    pub fn heightmap(&self) -> Vec<f32> {
        let mut out = vec![0f32; 129 * 129];
        for ci in self.mcnk_indices() {
            let b = &self.chunks[ci].bytes;
            let (col, row) = (u32_at(b, 8 + 4) as usize, u32_at(b, 8 + 8) as usize);
            if col > 15 || row > 15 {
                continue;
            }
            let base = f32_at(b, h::POSITION + 8);
            let mcvt = u32_at(b, h::OFS_HEIGHT) as usize + 8;
            for i in 0..9 {
                for j in 0..9 {
                    out[(row * 8 + i) * 129 + col * 8 + j] = base + f32_at(b, mcvt + (i * 17 + j) * 4);
                }
            }
        }
        out
    }

    /// Area IDs per map chunk (16 × 16).
    pub fn areas(&self) -> Vec<u32> {
        let mut out = vec![0; 256];
        for ci in self.mcnk_indices() {
            let b = &self.chunks[ci].bytes;
            let (col, row) = (u32_at(b, 8 + 4) as usize, u32_at(b, 8 + 8) as usize);
            if col < 16 && row < 16 {
                out[row * 16 + col] = u32_at(b, h::AREA);
            }
        }
        out
    }

    pub fn holes(&self, col: usize, row: usize) -> u32 {
        self.mcnk(col, row).map(|i| u32_at(&self.chunks[i].bytes, h::HOLES)).unwrap_or(0)
    }

    pub fn object_refs(&self, col: usize, row: usize) -> (u32, u32) {
        self.mcnk(col, row).map(|i| {
            let b = &self.chunks[i].bytes;
            (u32_at(b, h::N_DOODAD_REFS), u32_at(b, h::N_MAPOBJ_REFS))
        }).unwrap_or((0, 0))
    }
}

/// File (x, z) of height vertex `k` (0..145: rows of 9 outer, then 8 inner) of chunk (col, row).
pub fn vertex_xz(tile: (i32, i32), col: usize, row: usize, k: usize) -> (f64, f64) {
    let step = CHUNK / 8.0;
    let x0 = tile.0 as f64 * TILE + col as f64 * CHUNK;
    let z0 = tile.1 as f64 * TILE + row as f64 * CHUNK;
    let (i, j) = (k / 17, k % 17);
    if j < 9 {
        (x0 + j as f64 * step, z0 + i as f64 * step)
    } else {
        (x0 + (j - 9) as f64 * step + step / 2.0, z0 + i as f64 * step + step / 2.0)
    }
}

/// How a tile stores its normals: which byte holds which axis (0 file x, 1 up, 2 file z), and the
/// sign each byte carries.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NormalLayout {
    pub axis: [usize; 3],
    pub sign: [f64; 3],
}

/// The 1.12 layout, as every real tile measured has it (35 Azeroth, 6 Kalimdor tiles): byte 0
/// is −file z, byte 1 −file x, byte 2 up. Used when a tile can't tell (a flat one).
impl Default for NormalLayout {
    fn default() -> Self {
        NormalLayout { axis: [2, 0, 1], sign: [-1.0, -1.0, 1.0] }
    }
}

impl Adt {
    /// Absolute heights of a map chunk's 145 vertices.
    pub fn chunk_heights(&self, col: usize, row: usize) -> Option<[f32; 145]> {
        let b = &self.chunks[self.mcnk(col, row)?].bytes;
        let base = f32_at(b, h::POSITION + 8);
        let o = u32_at(b, h::OFS_HEIGHT) as usize + 8;
        let mut out = [0f32; 145];
        for (k, v) in out.iter_mut().enumerate() {
            *v = base + f32_at(b, o + k * 4);
        }
        Some(out)
    }

    /// Set a map chunk's absolute heights (stored relative to the chunk's base, which stays).
    pub fn set_chunk_heights(&mut self, col: usize, row: usize, hs: &[f32; 145]) -> Result<()> {
        let ci = self.mcnk(col, row).context("no such map chunk")?;
        let b = &mut self.chunks[ci].bytes;
        let base = f32_at(b, h::POSITION + 8);
        let o = u32_at(b, h::OFS_HEIGHT) as usize + 8;
        for (k, v) in hs.iter().enumerate() {
            b[o + k * 4..o + k * 4 + 4].copy_from_slice(&(v - base).to_le_bytes());
        }
        Ok(())
    }

    /// The height-field normal at a vertex, from the heights around it (file x, up, file z).
    /// The tile's whole height mesh: outer vertices (129 × 129) and inner ones (128 × 128).
    fn grid(&self) -> (Vec<f64>, Vec<f64>) {
        let (mut outer, mut inner) = (vec![0f64; 129 * 129], vec![0f64; 128 * 128]);
        for row in 0..16 {
            for col in 0..16 {
                let Some(hs) = self.chunk_heights(col, row) else { continue };
                for k in 0..145 {
                    let (i, j) = (k / 17, k % 17);
                    if j < 9 {
                        outer[(row * 8 + i) * 129 + col * 8 + j] = hs[k] as f64;
                    } else {
                        inner[(row * 8 + i) * 128 + col * 8 + j - 9] = hs[k] as f64;
                    }
                }
            }
        }
        (outer, inner)
    }

    /// A vertex's normal as the game draws the ground: the mesh's triangles around it (each
    /// square of outer vertices is four triangles meeting at its inner vertex), area-weighted.
    fn mesh_normal(grid: &(Vec<f64>, Vec<f64>), col: usize, row: usize, k: usize) -> [f64; 3] {
        let d = CHUNK / 8.0;
        let (outer, inner) = grid;
        let o = |i: usize, j: usize| [j as f64 * d, outer[i * 129 + j], i as f64 * d];
        let c = |i: usize, j: usize| [(j as f64 + 0.5) * d, inner[i * 128 + j], (i as f64 + 0.5) * d];
        let mut n = [0f64; 3];
        let mut add = |a: [f64; 3], b: [f64; 3], cc: [f64; 3]| {
            let (u, v) = ([b[0] - a[0], b[1] - a[1], b[2] - a[2]], [cc[0] - a[0], cc[1] - a[1], cc[2] - a[2]]);
            let mut x = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]];
            if x[1] < 0.0 {
                x = [-x[0], -x[1], -x[2]];
            }
            for i in 0..3 {
                n[i] += x[i];
            }
        };
        let (i, j) = (k / 17, k % 17);
        if j < 9 {
            // an outer vertex: the two triangles it has in each of the (up to) four squares around it
            let (gi, gj) = (row * 8 + i, col * 8 + j);
            for (qi, qj) in [(gi.wrapping_sub(1), gj.wrapping_sub(1)), (gi.wrapping_sub(1), gj), (gi, gj.wrapping_sub(1)), (gi, gj)] {
                if qi >= 128 || qj >= 128 {
                    continue;
                }
                let corners = [o(qi, qj), o(qi, qj + 1), o(qi + 1, qj + 1), o(qi + 1, qj)];
                let me = corners.iter().position(|p| (p[0] - gj as f64 * d).abs() < 1e-9 && (p[2] - gi as f64 * d).abs() < 1e-9).unwrap();
                let ctr = c(qi, qj);
                add(corners[me], corners[(me + 1) % 4], ctr);
                add(corners[(me + 3) % 4], corners[me], ctr);
            }
        } else {
            let (qi, qj) = (row * 8 + i, col * 8 + j - 9);
            let corners = [o(qi, qj), o(qi, qj + 1), o(qi + 1, qj + 1), o(qi + 1, qj)];
            let ctr = c(qi, qj);
            for e in 0..4 {
                add(corners[e], corners[(e + 1) % 4], ctr);
            }
        }
        let l = (n[0] * n[0] + n[1] * n[1] + n[2] * n[2]).sqrt().max(1e-12);
        [n[0] / l, n[1] / l, n[2] / l]
    }

    #[allow(dead_code)]
    fn computed_normal(&self, tile: (i32, i32), fx: f64, fz: f64) -> [f64; 3] {
        let d = CHUNK / 8.0;
        let at = |x: f64, z: f64| {
            let tx = TILE * tile.0 as f64;
            let tz = TILE * tile.1 as f64;
            let x = x.clamp(tx, tx + TILE - 1e-3);
            let z = z.clamp(tz, tz + TILE - 1e-3);
            self.height_at(tile, x, z).unwrap_or(0.0)
        };
        let dx = (at(fx + d, fz) - at(fx - d, fz)) / (2.0 * d);
        let dz = (at(fx, fz + d) - at(fx, fz - d)) / (2.0 * d);
        let n = [-dx, 1.0, -dz];
        let l = (n[0] * n[0] + n[1] * n[1] + n[2] * n[2]).sqrt();
        [n[0] / l, n[1] / l, n[2] / l]
    }

    /// Work out the tile's normal layout by comparing stored normals with the terrain's slopes.
    pub fn normal_layout(&self, tile: (i32, i32)) -> NormalLayout {
        let perms = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]];
        let mut samples = vec![];
        let grid = self.grid();
        for row in (0..16).step_by(3) {
            for col in (0..16).step_by(3) {
                let Some(ci) = self.mcnk(col, row) else { continue };
                let b = &self.chunks[ci].bytes;
                let o = u32_at(b, h::OFS_NORMAL) as usize + 8;
                for k in (0..145).step_by(7) {
                    let _ = tile;
                    let c = Self::mesh_normal(&grid, col, row, k);
                    let s = [b[o + k * 3] as i8 as f64 / 127.0, b[o + k * 3 + 1] as i8 as f64 / 127.0, b[o + k * 3 + 2] as i8 as f64 / 127.0];
                    samples.push((c, s));
                }
            }
        }
        // the 1.12 layout first: another one has to fit strictly better (a flat tile fits many)
        let score_of = |l: &NormalLayout| -> f64 { samples.iter().map(|(c, s)| (0..3).map(|i| s[i] * l.sign[i] * c[l.axis[i]]).sum::<f64>()).sum() };
        let mut best = (score_of(&NormalLayout::default()) + 1e-6, NormalLayout::default());
        for p in perms {
            for signs in 0..8 {
                let sign = [if signs & 1 != 0 { -1.0 } else { 1.0 }, if signs & 2 != 0 { -1.0 } else { 1.0 }, if signs & 4 != 0 { -1.0 } else { 1.0 }];
                // byte i holds axis p[i] times sign[i]
                let score: f64 = samples.iter().map(|(c, s)| (0..3).map(|i| s[i] * sign[i] * c[p[i]]).sum::<f64>()).sum();
                if score > best.0 + 1e-9 {
                    best = (score, NormalLayout { axis: p, sign });
                }
            }
        }
        if samples.iter().all(|(_, s)| s.iter().all(|v| *v == 0.0)) {
            return NormalLayout::default();
        }
        best.1
    }

    /// Recompute a map chunk's normals from its (edited) heights.
    pub fn recompute_normals(&mut self, tile: (i32, i32), col: usize, row: usize, layout: NormalLayout) -> Result<()> {
        let ci = self.mcnk(col, row).context("no such map chunk")?;
        let grid = self.grid();
        let _ = tile;
        let ns: Vec<[f64; 3]> = (0..145).map(|k| Self::mesh_normal(&grid, col, row, k)).collect();
        let b = &mut self.chunks[ci].bytes;
        let o = u32_at(b, h::OFS_NORMAL) as usize + 8;
        for (k, n) in ns.iter().enumerate() {
            for i in 0..3 {
                b[o + k * 3 + i] = ((n[layout.axis[i]] * layout.sign[i] * 127.0).round().clamp(-127.0, 127.0) as i8) as u8;
            }
        }
        Ok(())
    }
}

/// One texture layer of a map chunk: the texture, its MCLY flags and ground effect, and (for every
/// layer but the first) its 64 × 64 alpha map, 0–255 (stored at 4 bits).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[derive(Default)]
pub struct Layer {
    pub texture: String,
    #[serde(default)]
    pub flags: u32,
    #[serde(default)]
    pub effect: u32,
    #[serde(default)]
    pub alpha: Option<Vec<u8>>,
}

/// Replace (or add) a sub-chunk of a MCNK: `ofs_field` is the header field holding its offset.
/// Everything the header points to after it moves by the size change. Returns the change.
fn replace_sub(mcnk: &mut Vec<u8>, ofs_field: usize, magic: &str, body: &[u8], insert_after: &[usize]) -> Result<i64> {
    let mut sub = Vec::with_capacity(body.len() + 8);
    sub.extend(magic.bytes().rev());
    sub.extend((body.len() as u32).to_le_bytes());
    sub.extend_from_slice(body);
    let at = u32_at(mcnk, ofs_field) as usize;
    let rev: Vec<u8> = magic.bytes().rev().collect();
    let (pos, old_len) = if at != 0 && at + 8 <= mcnk.len() && mcnk[at..at + 4] == rev[..] {
        (at, 8 + u32_at(mcnk, at + 4) as usize)
    } else {
        // not there: put it after the last present sub-chunk of `insert_after`
        let mut pos = 0;
        for &f in insert_after {
            let o = u32_at(mcnk, f) as usize;
            if o != 0 && o + 8 <= mcnk.len() {
                pos = pos.max(o + 8 + u32_at(mcnk, o + 4) as usize);
            }
        }
        if pos == 0 {
            bail!("nowhere to put {magic}");
        }
        (pos, 0)
    };
    let delta = sub.len() as i64 - old_len as i64;
    mcnk.splice(pos..pos + old_len, sub);
    for &f in h::OFFSETS {
        if f == ofs_field {
            continue;
        }
        let v = u32_at(mcnk, f) as usize;
        // after the replaced sub-chunk (or at/after the insertion point) → moves
        let moves = v != 0 && if old_len > 0 { v > pos } else { v >= pos };
        if moves {
            put_u32(mcnk, f, (v as i64 + delta) as u32);
        }
    }
    put_u32(mcnk, ofs_field, pos as u32);
    let total = u32_at(mcnk, 4) as i64;
    put_u32(mcnk, 4, (total + delta) as u32);
    Ok(delta)
}

impl Adt {
    pub fn textures(&self) -> Vec<String> {
        self.strings("MTEX").into_iter().map(|x| x.1).collect()
    }

    /// The index of a texture in MTEX, adding it when it's new.
    fn texture_index(&mut self, name: &str) -> Result<u32> {
        let names = self.textures();
        if let Some(i) = names.iter().position(|n| n.eq_ignore_ascii_case(name)) {
            return Ok(i as u32);
        }
        let mt = self.find("MTEX").context("no MTEX")?;
        let mut body = self.chunks[mt].body().to_vec();
        body.extend(name.as_bytes());
        body.push(0);
        self.chunks[mt] = Chunk { orig_len: self.chunks[mt].orig_len, ..Chunk::new("MTEX", &body) };
        Ok(names.len() as u32)
    }

    pub fn layers(&self, col: usize, row: usize) -> Option<Vec<Layer>> {
        let b = &self.chunks[self.mcnk(col, row)?].bytes;
        let names = self.textures();
        let n = u32_at(b, h::N_LAYERS) as usize;
        let ly = u32_at(b, h::OFS_LAYER) as usize + 8;
        let al = u32_at(b, h::OFS_ALPHA) as usize;
        let mut out = vec![];
        for i in 0..n.min(4) {
            let e = ly + i * 16;
            let (tex, flags, ofs, effect) = (u32_at(b, e), u32_at(b, e + 4), u32_at(b, e + 8) as usize, u32_at(b, e + 12));
            let alpha = (i > 0 && al != 0).then(|| {
                let start = al + 8 + ofs;
                (0..4096).map(|p| {
                    let byte = b.get(start + p / 2).copied().unwrap_or(0);
                    let nib = if p % 2 == 0 { byte & 0x0F } else { byte >> 4 };
                    nib * 17
                }).collect()
            });
            out.push(Layer { texture: names.get(tex as usize).cloned().unwrap_or_default(), flags, effect, alpha });
        }
        Some(out)
    }

    /// Set a map chunk's texture layers (1–4): MCLY and MCAL rebuilt, MTEX extended as needed.
    pub fn set_layers(&mut self, col: usize, row: usize, layers: &[Layer]) -> Result<()> {
        if layers.is_empty() || layers.len() > 4 {
            bail!("a map chunk has 1 to 4 texture layers");
        }
        let ids: Vec<u32> = layers.iter().map(|l| self.texture_index(&l.texture)).collect::<Result<_>>()?;
        let ci = self.mcnk(col, row).context("no such map chunk")?;
        let mut mcly = vec![];
        let mut mcal = vec![];
        for (i, l) in layers.iter().enumerate() {
            let ofs = if i == 0 { 0 } else { mcal.len() as u32 };
            if i > 0 {
                let a = l.alpha.as_ref().filter(|a| a.len() == 4096).context("layers after the first need a 64×64 alpha map")?;
                for p in (0..4096).step_by(2) {
                    let lo = ((a[p] as u32 + 8) / 17).min(15) as u8;
                    let hi = ((a[p + 1] as u32 + 8) / 17).min(15) as u8;
                    mcal.push(lo | (hi << 4));
                }
            }
            mcly.extend(ids[i].to_le_bytes());
            mcly.extend(l.flags.to_le_bytes());
            mcly.extend(ofs.to_le_bytes());
            mcly.extend(l.effect.to_le_bytes());
        }
        let b = &mut self.chunks[ci].bytes;
        replace_sub(b, h::OFS_LAYER, "MCLY", &mcly, &[h::OFS_NORMAL])?;
        let old_size_alpha = u32_at(b, h::SIZE_ALPHA) as i64;
        let had_alpha = u32_at(b, h::OFS_ALPHA) != 0 && old_size_alpha != 0;
        let d = replace_sub(b, h::OFS_ALPHA, "MCAL", &mcal, &[h::OFS_SHADOW, h::OFS_REFS, h::OFS_LAYER])?;
        // the header's alpha size counts the chunk with its 8-byte header
        let size = if had_alpha { old_size_alpha + d } else { mcal.len() as i64 + 8 };
        put_u32(b, h::SIZE_ALPHA, size as u32);
        put_u32(b, h::N_LAYERS, layers.len() as u32);
        Ok(())
    }

    /// A map chunk's water (MCLQ, the 1.12 liquid): the first liquid it has, if any.
    pub fn liquid(&self, col: usize, row: usize) -> Option<Liquid> {
        let b = &self.chunks[self.mcnk(col, row)?].bytes;
        let kind = LiquidKind::from_flags(u32_at(b, h::FLAGS))?;
        let (o, n) = (u32_at(b, h::OFS_LIQUID) as usize, u32_at(b, h::SIZE_LIQUID) as usize);
        if o == 0 || n < 8 + LIQUID_LEN || o + 8 + LIQUID_LEN > b.len() {
            return None;
        }
        let d = &b[o + 8..o + 8 + LIQUID_LEN];
        let verts = (0..81).map(|k| (d[8 + k * 8..12 + k * 8].try_into().unwrap(), f32_at(d, 12 + k * 8))).collect();
        let tiles = d[8 + 648..8 + 648 + 64].try_into().unwrap();
        Some(Liquid { kind, verts, tiles, flow: d[8 + 648 + 64..].to_vec() })
    }

    /// Give a map chunk water (or take it away with `None`): MCLQ rewritten, the chunk's liquid
    /// flag set, the vertices' depth bytes from the ground under them.
    pub fn set_liquid(&mut self, col: usize, row: usize, l: Option<&Liquid>) -> Result<()> {
        let ground = self.chunk_heights(col, row).context("no such map chunk")?;
        let ci = self.mcnk(col, row).context("no such map chunk")?;
        let b = &mut self.chunks[ci].bytes;
        let mut body = vec![];
        if let Some(l) = l {
            if l.verts.len() != 81 || l.flow.len() != 84 {
                bail!("water needs 9×9 vertices and the flow block");
            }
            let (lo, hi) = l.verts.iter().fold((f32::MAX, f32::MIN), |(a, z), v| (a.min(v.1), z.max(v.1)));
            body.extend(lo.to_le_bytes());
            body.extend(hi.to_le_bytes());
            for (k, (info, hgt)) in l.verts.iter().enumerate() {
                let mut info = *info;
                if l.kind != LiquidKind::Magma {
                    // depth: how far the ground is below the surface (the client shades by it);
                    // about 8 a yard, as the game's own lakes and rivers measure
                    let g = ground[(k / 9) * 17 + k % 9];
                    info[0] = ((hgt - g).max(0.0) * 8.0).min(255.0) as u8;
                }
                body.extend(info);
                body.extend(hgt.to_le_bytes());
            }
            body.extend(l.tiles);
            body.extend(&l.flow);
        }
        // the 1.12 files' MCLQ size field isn't reliable: the header's sizeLiquid is
        let (o, n) = (u32_at(b, h::OFS_LIQUID) as usize, u32_at(b, h::SIZE_LIQUID) as usize);
        if o != 0 && o + 8 <= b.len() && &b[o..o + 4] == b"QLCM" && n >= 8 && o + n <= b.len() {
            put_u32(b, o + 4, (n - 8) as u32);
        }
        replace_sub(b, h::OFS_LIQUID, "MCLQ", &body, &[h::OFS_ALPHA, h::OFS_SHADOW, h::OFS_REFS, h::OFS_LAYER])?;
        put_u32(b, h::SIZE_LIQUID, (body.len() + 8) as u32);
        // as the game's own tiles have it: MCLQ's own size field 0, the header's sizeLiquid counts
        let lq = u32_at(b, h::OFS_LIQUID) as usize;
        put_u32(b, lq + 4, 0);
        let flags = u32_at(b, h::FLAGS) & !0x3C;
        put_u32(b, h::FLAGS, flags | l.map(|l| l.kind.flag()).unwrap_or(0));
        Ok(())
    }

    pub fn set_holes(&mut self, col: usize, row: usize, holes: u32) -> Result<()> {
        let ci = self.mcnk(col, row).context("no such map chunk")?;
        put_u32(&mut self.chunks[ci].bytes, h::HOLES, holes & 0xFFFF);
        Ok(())
    }

    /// Whether a chunk is impassable (MCNK flag 0x2: the server keeps players off it).
    pub fn impass(&self, col: usize, row: usize) -> bool {
        self.mcnk(col, row).map(|ci| u32_at(&self.chunks[ci].bytes, h::FLAGS) & 0x2 != 0).unwrap_or(false)
    }

    pub fn set_impass(&mut self, col: usize, row: usize, on: bool) -> Result<()> {
        let ci = self.mcnk(col, row).context("no such map chunk")?;
        let f = u32_at(&self.chunks[ci].bytes, h::FLAGS);
        put_u32(&mut self.chunks[ci].bytes, h::FLAGS, if on { f | 0x2 } else { f & !0x2 });
        Ok(())
    }

/// The chunk's baked shadow (MCSH, 64 × 64 bits): its bytes, if it has one.
    fn shadow_span(&self, col: usize, row: usize) -> Option<(usize, std::ops::Range<usize>)> {
        let ci = self.mcnk(col, row)?;
        let b = &self.chunks[ci].bytes;
        let o = u32_at(b, h::OFS_SHADOW) as usize;
        if o == 0 || o + 8 > b.len() || &b[o..o + 4] != b"HSCM" {
            return None;
        }
        let n = (u32_at(b, o + 4) as usize).min(b.len() - o - 8);
        Some((ci, o + 8..o + 8 + n))
    }

    /// How much of the chunk the baked shadow darkens (0 to 1).
    pub fn shadow(&self, col: usize, row: usize) -> f32 {
        let Some((ci, r)) = self.shadow_span(col, row) else { return 0.0 };
        let b = &self.chunks[ci].bytes[r.clone()];
        if b.is_empty() {
            return 0.0;
        }
        b.iter().map(|x| x.count_ones()).sum::<u32>() as f32 / (b.len() * 8) as f32
    }

    /// The chunk's baked shadow as 64 × 64 values (1 = in shadow), if it has one.
    pub fn shadow_map(&self, col: usize, row: usize) -> Option<Vec<u8>> {
        let (ci, r) = self.shadow_span(col, row)?;
        let b = &self.chunks[ci].bytes[r];
        if b.len() < 512 || b.iter().all(|&x| x == 0) {
            return None;
        }
        Some((0..4096).map(|i| (b[(i / 64) * 8 + (i % 64) / 8] >> (i % 8)) & 1).collect())
    }

    /// Clear the chunk's baked shadow (the ground lit all over, as after its trees are gone).
    pub fn clear_shadow(&mut self, col: usize, row: usize) {
        if let Some((ci, r)) = self.shadow_span(col, row) {
            self.chunks[ci].bytes[r].fill(0);
        }
    }

    pub fn set_area(&mut self, col: usize, row: usize, area: u32) -> Result<()> {
        let ci = self.mcnk(col, row).context("no such map chunk")?;
        put_u32(&mut self.chunks[ci].bytes, h::AREA, area);
        Ok(())
    }
}

/// Bytes of one MCLQ liquid: height range, 9×9 vertices, 8×8 tiles, the flow block.
pub const LIQUID_LEN: usize = 8 + 81 * 8 + 64 + 84;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LiquidKind {
    River,
    Ocean,
    Magma,
    Slime,
}

impl LiquidKind {
    pub fn from_flags(f: u32) -> Option<Self> {
        [(0x04, Self::River), (0x08, Self::Ocean), (0x10, Self::Magma), (0x20, Self::Slime)].into_iter().find(|(b, _)| f & b != 0).map(|x| x.1)
    }
    pub fn flag(self) -> u32 {
        match self {
            Self::River => 0x04,
            Self::Ocean => 0x08,
            Self::Magma => 0x10,
            Self::Slime => 0x20,
        }
    }
    /// The type in a tile's low nibble.
    pub fn tile_type(self) -> u8 {
        match self {
            Self::River => 4,
            Self::Ocean => 1,
            Self::Magma => 6,
            Self::Slime => 3,
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            Self::River => "water",
            Self::Ocean => "ocean",
            Self::Magma => "magma",
            Self::Slime => "slime",
        }
    }
    pub fn parse(s: &str) -> Result<Self> {
        Ok(match s.to_ascii_lowercase().as_str() {
            "water" | "river" | "lake" => Self::River,
            "ocean" | "sea" => Self::Ocean,
            "magma" | "lava" => Self::Magma,
            "slime" => Self::Slime,
            _ => bail!("water is water, ocean, magma or slime"),
        })
    }
}

/// One chunk's liquid. `tiles[y*8+x]`: low nibble the type (0x0F = none there), 0x40 deep
/// enough to swim, 0x80 fatigue. Vertex info bytes: depth, flow, flow, 0 (magma: texture s, t).
#[derive(Debug, Clone, PartialEq)]
pub struct Liquid {
    pub kind: LiquidKind,
    pub verts: Vec<([u8; 4], f32)>,
    pub tiles: [u8; 64],
    pub flow: Vec<u8>,
}

impl Liquid {
    pub fn flat(kind: LiquidKind, height: f32) -> Self {
        Liquid { kind, verts: vec![([0; 4], height); 81], tiles: [0x0F; 64], flow: vec![0; 84] }
    }
    pub fn shown(&self, k: usize) -> bool {
        self.tiles[k] & 0x0F != 0x0F
    }
}

/// The tile a file position is on.
pub fn tile_of_file(pos: [f32; 3]) -> (i32, i32) {
    ((pos[0] as f64 / TILE).floor() as i32, (pos[2] as f64 / TILE).floor() as i32)
}

/// Which map chunk (col, row) of `tile` holds file position `pos`.
pub fn chunk_of(tile: (i32, i32), pos: [f32; 3]) -> Option<(usize, usize)> {
    let cx = ((pos[0] as f64 - tile.0 as f64 * TILE) / CHUNK).floor();
    let cz = ((pos[2] as f64 - tile.1 as f64 * TILE) / CHUNK).floor();
    ((0.0..16.0).contains(&cx) && (0.0..16.0).contains(&cz)).then_some((cx as usize, cz as usize))
}

/// Add doodad reference `index` to a MCNK's MCRF (doodad refs come before map object refs),
/// shifting every sub-chunk the header says lies after it.
/// A building reference: after the doodad references and the other buildings'.
fn add_wmo_ref(mcnk: &mut Vec<u8>, index: u32) -> Result<()> {
    let refs = u32_at(mcnk, h::OFS_REFS) as usize;
    if refs == 0 || refs + 8 > mcnk.len() || &mcnk[refs..refs + 4] != b"FRCM" {
        bail!("map chunk has no MCRF where its header says");
    }
    let (n_d, n_w) = (u32_at(mcnk, h::N_DOODAD_REFS) as usize, u32_at(mcnk, h::N_MAPOBJ_REFS) as usize);
    let at = refs + 8 + (n_d + n_w) * 4;
    mcnk.splice(at..at, index.to_le_bytes());
    let size = u32_at(mcnk, refs + 4);
    put_u32(mcnk, refs + 4, size + 4);
    put_u32(mcnk, h::N_MAPOBJ_REFS, n_w as u32 + 1);
    for &f in h::OFFSETS {
        let v = u32_at(mcnk, f) as usize;
        if v > refs {
            put_u32(mcnk, f, (v + 4) as u32);
        }
    }
    let total = u32_at(mcnk, 4);
    put_u32(mcnk, 4, total + 4);
    Ok(())
}

/// A WMO root file's bounding box in the model's own coordinates (z up): the union of its
/// groups' boxes (MOGI), which is what the game's own placements measure (MOHD's box leaves out
/// parts such as chimneys); MOHD when there are no groups.
pub fn wmo_bounds(root: &[u8]) -> Result<[f32; 6]> {
    let mut pos = 0;
    let mut mohd = None;
    let mut groups: Option<[f32; 6]> = None;
    while pos + 8 <= root.len() {
        let n = u32_at(root, pos + 4) as usize;
        let body = pos + 8;
        if &root[pos..pos + 4] == b"DHOM" && n >= 60 && body + 60 <= root.len() {
            let o = body + 36;
            mohd = Some([f32_at(root, o), f32_at(root, o + 4), f32_at(root, o + 8), f32_at(root, o + 12), f32_at(root, o + 16), f32_at(root, o + 20)]);
        }
        if &root[pos..pos + 4] == b"IGOM" && body + n <= root.len() {
            for g in 0..n / 32 {
                let o = body + g * 32 + 4;
                let b: [f32; 6] = std::array::from_fn(|k| f32_at(root, o + k * 4));
                groups = Some(match groups {
                    None => b,
                    Some(u) => std::array::from_fn(|k| if k < 3 { u[k].min(b[k]) } else { u[k].max(b[k]) }),
                });
            }
        }
        pos += 8 + n;
    }
    groups.or(mohd).context("not a WMO root file (no MOHD)")
}

/// A building's box in file coordinates, placed at `pos` turned `yaw` degrees: the model's box
/// corners turned the way the game turns them (file x = sin·x + cos·y, file z = cos·x − sin·y,
/// up = z; matches all 128 level buildings on 41 real tiles to a hundredth of a yard).
pub fn wmo_extents(local: [f32; 6], pos: [f32; 3], yaw: f32) -> [f32; 6] {
    let (s, c) = (yaw as f64).to_radians().sin_cos();
    let mut e = [f32::MAX, f32::MAX, f32::MAX, f32::MIN, f32::MIN, f32::MIN];
    for x in [local[0], local[3]] {
        for y in [local[1], local[4]] {
            for z in [local[2], local[5]] {
                let (x, y) = (x as f64, y as f64);
                let p = [pos[0] + (s * x + c * y) as f32, pos[1] + z, pos[2] + (c * x - s * y) as f32];
                for k in 0..3 {
                    e[k] = e[k].min(p[k]);
                    e[k + 3] = e[k + 3].max(p[k]);
                }
            }
        }
    }
    e
}

/// Replace a map chunk's object references (doodads, then buildings) with these.
fn set_refs(mcnk: &mut Vec<u8>, d: &[u32], w: &[u32]) -> Result<()> {
    let refs = u32_at(mcnk, h::OFS_REFS) as usize;
    if refs == 0 || refs + 8 > mcnk.len() || &mcnk[refs..refs + 4] != b"FRCM" {
        bail!("map chunk has no MCRF where its header says");
    }
    let old = (u32_at(mcnk, h::N_DOODAD_REFS) + u32_at(mcnk, h::N_MAPOBJ_REFS)) as usize;
    let new: Vec<u8> = d.iter().chain(w.iter()).flat_map(|x| x.to_le_bytes()).collect();
    let delta = new.len() as i64 - (old * 4) as i64;
    mcnk.splice(refs + 8..refs + 8 + old * 4, new);
    let size = u32_at(mcnk, refs + 4) as i64;
    put_u32(mcnk, refs + 4, (size + delta) as u32);
    put_u32(mcnk, h::N_DOODAD_REFS, d.len() as u32);
    put_u32(mcnk, h::N_MAPOBJ_REFS, w.len() as u32);
    for &f in h::OFFSETS {
        let v = u32_at(mcnk, f) as i64;
        if v > refs as i64 {
            put_u32(mcnk, f, (v + delta) as u32);
        }
    }
    let total = u32_at(mcnk, 4) as i64;
    put_u32(mcnk, 4, (total + delta) as u32);
    Ok(())
}

fn add_ref(mcnk: &mut Vec<u8>, index: u32) -> Result<()> {
    let refs = u32_at(mcnk, h::OFS_REFS) as usize;
    if refs == 0 || refs + 8 > mcnk.len() || &mcnk[refs..refs + 4] != b"FRCM" {
        bail!("map chunk has no MCRF where its header says");
    }
    let n_d = u32_at(mcnk, h::N_DOODAD_REFS) as usize;
    let at = refs + 8 + n_d * 4;
    mcnk.splice(at..at, index.to_le_bytes());
    let size = u32_at(mcnk, refs + 4);
    put_u32(mcnk, refs + 4, size + 4);
    put_u32(mcnk, h::N_DOODAD_REFS, n_d as u32 + 1);
    for &f in h::OFFSETS {
        let v = u32_at(mcnk, f) as usize;
        if v > refs {
            put_u32(mcnk, f, (v + 4) as u32);
        }
    }
    let total = u32_at(mcnk, 4);
    put_u32(mcnk, 4, total + 4);
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    #[test]
    fn baked_shadows_read_and_clear() {
        let mut t = Adt::parse(&fake_tile(32, 48, 10.0)).unwrap();
        assert_eq!(t.shadow(3, 4), 0.0);
        let (ci, r) = t.shadow_span(3, 4).expect("the fake tile has MCSH");
        let half = r.start..r.start + (r.end - r.start) / 2;
        t.chunks[ci].bytes[half].fill(0xFF);
        assert!((t.shadow(3, 4) - 0.5).abs() < 1e-6);
        t.clear_shadow(3, 4);
        let back = Adt::parse(&t.write()).unwrap();
        assert_eq!(back.shadow(3, 4), 0.0);
        assert_eq!(back.heightmap(), Adt::parse(&fake_tile(32, 48, 10.0)).unwrap().heightmap());
    }

    /// A small valid tile: flat ground at height `h0`, no textures, one doodad name.
    pub(crate) fn fake_tile(a: i32, b: i32, h0: f32) -> Vec<u8> {
        let mut chunks: Vec<Chunk> = vec![Chunk::new("MVER", &18u32.to_le_bytes()), Chunk::new("MHDR", &[0u8; 64]), Chunk::new("MCIN", &vec![0u8; 256 * 16])];
        chunks.push(Chunk::new("MTEX", b"Tileset\\Elwynn\\ElwynnGrassBase.blp\0"));
        chunks.push(Chunk::new("MMDX", b"World\\Generic\\Tree01.mdx\0"));
        chunks.push(Chunk::new("MMID", &0u32.to_le_bytes()));
        chunks.push(Chunk::new("MWMO", &[]));
        chunks.push(Chunk::new("MWID", &[]));
        chunks.push(Chunk::new("MDDF", &[]));
        chunks.push(Chunk::new("MODF", &[]));
        for row in 0..16u32 {
            for col in 0..16u32 {
                let mut hdr = vec![0u8; 128];
                hdr[4..8].copy_from_slice(&col.to_le_bytes());
                hdr[8..12].copy_from_slice(&row.to_le_bytes());
                let mut sub = vec![];
                let mcvt = Chunk::new("MCVT", &[0u8; 145 * 4]);
                let mcnr = Chunk::new("MCNR", &[0u8; 145 * 3 + 13]);
                let mcly = Chunk::new("MCLY", &[0u8; 16]); // one layer: MTEX[0], the base
                let mcrf = Chunk::new("MCRF", &[]);
                let mcsh = Chunk::new("MCSH", &[0u8; 512]);
                let mut o = 8 + 128;
                let mut offs = vec![];
                for c in [&mcvt, &mcnr, &mcly, &mcrf, &mcsh] {
                    offs.push(o as u32);
                    o += c.bytes.len();
                    sub.extend_from_slice(&c.bytes);
                }
                hdr[0x14..0x18].copy_from_slice(&offs[0].to_le_bytes());
                hdr[0x18..0x1C].copy_from_slice(&offs[1].to_le_bytes());
                hdr[0x1C..0x20].copy_from_slice(&offs[2].to_le_bytes());
                hdr[0x20..0x24].copy_from_slice(&offs[3].to_le_bytes());
                hdr[0x2C..0x30].copy_from_slice(&offs[4].to_le_bytes());
                hdr[0x34..0x38].copy_from_slice(&12u32.to_le_bytes());
                hdr[0x0C..0x10].copy_from_slice(&1u32.to_le_bytes());
                hdr[0x70..0x74].copy_from_slice(&h0.to_le_bytes());
                let _ = (a, b);
                let mut body = hdr;
                body.extend(sub);
                chunks.push(Chunk::new("MCNK", &body));
            }
        }
        // offsets as a real tile has them (MCIN size = chunk + 8)
        let mut adt = Adt { chunks, tail: vec![] };
        let mut tmp = adt.write();
        let mh = 20;
        for (k, n) in ["MCIN", "MTEX", "MMDX", "MMID", "MWMO", "MWID", "MDDF", "MODF"].iter().enumerate() {
            let mut o = 0;
            for c in &adt.chunks {
                if c.magic == *n {
                    break;
                }
                o += c.bytes.len();
            }
            put_u32(&mut tmp, mh + 4 + k * 4, (o - mh) as u32);
        }
        adt = Adt::parse(&tmp).unwrap();
        let mut o = 0;
        let mcin_at: usize = adt.chunks.iter().take_while(|c| c.magic != "MCIN").map(|c| c.bytes.len()).sum::<usize>() + 8;
        let mut k = 0;
        for c in adt.chunks.iter() {
            if c.magic == "MCNK" {
                put_u32(&mut tmp, mcin_at + k * 16, o as u32);
                put_u32(&mut tmp, mcin_at + k * 16 + 4, c.bytes.len() as u32);
                k += 1;
            }
            o += c.bytes.len();
        }
        tmp
    }

    #[test]
    fn heights_and_normals_edit_in_place() {
        let t = fake_tile(32, 48, 50.0);
        let mut adt = Adt::parse(&t).unwrap();
        let mut hs = adt.chunk_heights(3, 4).unwrap();
        for (k, v) in hs.iter_mut().enumerate() {
            let (fx, _) = vertex_xz((32, 48), 3, 4, k);
            *v += (fx - 32.0 * TILE - 3.0 * CHUNK) as f32 * 0.5; // a slope rising toward +x
        }
        adt.set_chunk_heights(3, 4, &hs).unwrap();
        let lay = NormalLayout::default();
        adt.recompute_normals((32, 48), 3, 4, lay).unwrap();
        let out = adt.write();
        assert_eq!(out.len(), t.len(), "heights and normals change no sizes");
        let back = Adt::parse(&out).unwrap();
        assert_eq!(back.chunk_heights(3, 4).unwrap(), hs);
        // the layout comes back out of the normals it wrote
        assert_eq!(back.normal_layout((32, 48)).axis, lay.axis);
        // a slope up toward +x leans the normal toward -x
        let ci = back.mcnk(3, 4).unwrap();
        let b = &back.chunks[ci].bytes;
        let o = u32_at(b, h::OFS_NORMAL) as usize + 8 + 40 * 3;
        let xb = lay.axis.iter().position(|&a| a == 0).unwrap();
        let nx = b[o + xb] as i8 as f64 * lay.sign[xb];
        assert!(nx < -20.0, "normal x {nx}");
    }

    #[test]
    fn layers_holes_and_areas() {
        let t = fake_tile(32, 48, 50.0);
        let mut adt = Adt::parse(&t).unwrap();
        assert_eq!(adt.layers(2, 2).unwrap().len(), 1, "the fake tile starts with its base texture");
        let mut alpha = vec![0u8; 4096];
        for (p, v) in alpha.iter_mut().enumerate() {
            *v = ((p % 64) * 4).min(255) as u8;
        }
        let ls = vec![
            Layer { texture: "Tileset\\Elwynn\\ElwynnGrassBase.blp".into(), flags: 0, effect: 0, alpha: None },
            Layer { texture: "Tileset\\Elwynn\\ElwynnDirtBase.blp".into(), flags: 0x100, effect: 0, alpha: Some(alpha.clone()) },
        ];
        adt.set_layers(2, 2, &ls).unwrap();
        adt.set_holes(5, 5, 0b1001).unwrap();
        adt.set_area(7, 7, 87).unwrap();
        let back = Adt::parse(&adt.write()).unwrap();
        let got = back.layers(2, 2).unwrap();
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].texture, ls[0].texture);
        assert_eq!(got[1].texture, "Tileset\\Elwynn\\ElwynnDirtBase.blp");
        let ga = got[1].alpha.as_ref().unwrap();
        assert!(ga.iter().zip(&alpha).all(|(a, b)| (*a as i32 - *b as i32).abs() <= 9), "alpha survives at 4 bits");
        assert_eq!(back.textures().len(), 2, "MTEX gained the dirt");
        assert_eq!(back.holes(5, 5), 0b1001);
        assert_eq!(back.areas()[7 * 16 + 7], 87);
        // everything after MCAL still where the header says
        let ci = back.mcnk(2, 2).unwrap();
        let b = &back.chunks[ci].bytes;
        for (f, m) in [(h::OFS_SHADOW, b"HSCM"), (h::OFS_REFS, b"FRCM"), (h::OFS_ALPHA, b"LACM"), (h::OFS_LAYER, b"YLCM"), (h::OFS_HEIGHT, b"TVCM")] {
            let o = u32_at(b, f) as usize;
            assert_eq!(&b[o..o + 4], m, "field {f:#x}");
        }
        // doodads still work after the chunk grew
        let mut again = back.clone();
        let pos = [(32.0 * TILE + 70.0) as f32, 50.0, (48.0 * TILE + 70.0) as f32];
        again.add_doodads((32, 48), &[Doodad { model: "World\\X.mdx".into(), uid: 1, pos, rot: [0.0; 3], scale: 1024, flags: 0, extents: None, set: 0 }]).unwrap();
        assert_eq!(Adt::parse(&again.write()).unwrap().doodads().len(), 1);
    }

    #[test]
    fn new_tiles_and_wdts() {
        let t = Adt::parse(&new_tile(31, 32, 12.5, "Tileset\\Generic\\Grass.blp", 7)).unwrap();
        assert_eq!(t.write(), new_tile(31, 32, 12.5, "Tileset\\Generic\\Grass.blp", 7), "writes back the same");
        assert_eq!(t.textures(), vec!["Tileset\\Generic\\Grass.blp"]);
        let f = to_file(0.0, 0.0, 0.0);
        let (fx, fz) = (31.0 * TILE + 100.0, 32.0 * TILE + 200.0);
        let _ = f;
        assert_eq!(t.height_at((31, 32), fx, fz), Some(12.5));
        assert!(t.areas().iter().all(|&x| x == 7));
        assert_eq!(t.layers(4, 4).unwrap().len(), 1);
        assert!(t.liquid(4, 4).is_none());
        // and every editor works on it: water, textures, doodads
        let mut t2 = t.clone();
        t2.set_liquid(1, 1, Some(&Liquid::flat(LiquidKind::Ocean, 20.0))).unwrap();
        t2.set_layers(2, 2, &[Layer { texture: "A.blp".into(), flags: 0, effect: 0, alpha: None }, Layer { texture: "B.blp".into(), flags: 0x100, effect: 0, alpha: Some(vec![9; 4096]) }]).unwrap();
        let pos = [fx as f32, 12.5, fz as f32];
        t2.add_doodads((31, 32), &[Doodad { model: "World\\X.mdx".into(), uid: 5, pos, rot: [0.0; 3], scale: 1024, flags: 0, extents: None, set: 0 }]).unwrap();
        let back = Adt::parse(&t2.write()).unwrap();
        assert_eq!(back.doodads().len(), 1);
        assert_eq!(back.liquid(1, 1).unwrap().kind, LiquidKind::Ocean);
        // the chunk's position: world x, world y of its corner, then the height
        let ci = back.mcnk(0, 0).unwrap();
        let p0 = f32_at(&back.chunks[ci].bytes, h::POSITION);
        assert!((p0 as f64 - (HALF - 32.0 * TILE)).abs() < 0.01);
        let w = new_wdt(&[(31, 32), (32, 32)]);
        assert_eq!(wdt_tiles(&w), vec![(31, 32), (32, 32)]);
        assert_eq!(w.len(), 8 + 4 + 8 + 32 + 8 + 64 * 64 * 8 + 8);
    }

    #[test]
    fn buildings_go_in_modf_and_every_chunk_they_cover() {
        let mut t = Adt::parse(&new_tile(32, 48, 10.0, "T.blp", 1)).unwrap();
        // a doodad first, so the building's reference has to go after it
        let pos = [(32.0 * TILE + 50.0) as f32, 10.0, (48.0 * TILE + 50.0) as f32];
        t.add_doodads((32, 48), &[Doodad { model: "World\\Tree.mdx".into(), uid: 9, pos, rot: [0.0; 3], scale: 1024, flags: 0, extents: None, set: 0 }]).unwrap();
        // a 40-yard house at the same spot: chunk 1 ± 1 in both directions
        let mut root = b"REVM".to_vec();
        root.extend(4u32.to_le_bytes());
        root.extend(17u32.to_le_bytes());
        root.extend(b"DHOM");
        root.extend(64u32.to_le_bytes());
        let mut mohd = vec![0u8; 64];
        for (k, v) in [-20f32, -14.0, -2.0, 20.0, 14.0, 18.0].iter().enumerate() {
            mohd[36 + k * 4..40 + k * 4].copy_from_slice(&v.to_le_bytes());
        }
        root.extend(mohd);
        let local = wmo_bounds(&root).unwrap();
        assert_eq!(local[3], 20.0);
        let ext = wmo_extents(local, pos, 0.0);
        // unturned: model x (40 long) runs along file z, model y (28) along file x
        assert!((ext[3] - ext[0] - 28.0).abs() < 0.01 && (ext[5] - ext[2] - 40.0).abs() < 0.01, "{ext:?}");
        let turned = wmo_extents(local, pos, 90.0);
        assert!((turned[3] - turned[0] - 40.0).abs() < 0.01 && (turned[5] - turned[2] - 28.0).abs() < 0.01, "{turned:?}");
        assert_eq!((ext[1], ext[4]), (8.0, 28.0));
        let w = Doodad { model: "World\\wmo\\House.wmo".into(), uid: 77, pos, rot: [0.0, 90.0, 0.0], scale: 1024, flags: 0, extents: Some(ext), set: 2 };
        t.add_doodads((32, 48), &[w.clone()]).unwrap();
        let back = Adt::parse(&t.write()).unwrap();
        assert_eq!(back.wmos(), vec![w], "its doodad set (2) comes back too");
        assert_eq!(back.doodads().len(), 1);
        let refs = |c: usize, r: usize| {
            let b = &back.chunks[back.mcnk(c, r).unwrap()].bytes;
            (u32_at(b, h::N_DOODAD_REFS), u32_at(b, h::N_MAPOBJ_REFS))
        };
        assert_eq!(refs(1, 1), (1, 1), "the doodad's chunk has both, the doodad first");
        // 28 yards across file x (chunk column 1 only), 40 along file z (rows 0 to 2)
        assert_eq!(refs(1, 0), (0, 1));
        assert_eq!(refs(1, 2), (0, 1));
        assert_eq!(refs(0, 0), (0, 0));
        assert_eq!(refs(2, 2), (0, 0));
        // the doodad reference is still the doodad's (index 0 in MDDF), the building's is MODF 0
        let b = &back.chunks[back.mcnk(1, 1).unwrap()].bytes;
        let o = u32_at(b, h::OFS_REFS) as usize + 8;
        assert_eq!((u32_at(b, o), u32_at(b, o + 4)), (0, 0));
        assert!(t.add_wmos((33, 48), &[back.wmos()[0].clone()]).is_err(), "not on that tile");
    }

    #[test]
    fn water_round_trips() {
        let mut adt = Adt::parse(&fake_tile(32, 48, 30.0)).unwrap();
        assert!(adt.liquid(3, 3).is_none());
        let mut l = Liquid::flat(LiquidKind::River, 40.0);
        for k in [0, 1, 9, 63] {
            l.tiles[k] = LiquidKind::River.tile_type() | 0x40;
        }
        adt.set_liquid(3, 3, Some(&l)).unwrap();
        let back = Adt::parse(&adt.write()).unwrap();
        let got = back.liquid(3, 3).unwrap();
        assert_eq!(got.kind, LiquidKind::River);
        assert_eq!(got.tiles, l.tiles);
        assert!(got.verts.iter().all(|v| v.1 == 40.0 && v.0[0] == 80), "flat at 40, 10 yards deep: {:?}", got.verts[0]);
        assert_eq!(back.chunks[back.mcnk(3, 3).unwrap()].bytes.len() as u32, u32_at(&back.chunks[back.mcnk(3, 3).unwrap()].bytes, 4) + 8);
        // a 1.12 file's MCLQ says size 0; replacing it still takes out the whole old liquid
        let mut v = back.clone();
        let ci = v.mcnk(3, 3).unwrap();
        let o = u32_at(&v.chunks[ci].bytes, h::OFS_LIQUID) as usize;
        put_u32(&mut v.chunks[ci].bytes, o + 4, 0);
        let len0 = v.chunks[ci].bytes.len();
        v.set_liquid(3, 3, Some(&Liquid { kind: LiquidKind::Magma, ..l.clone() })).unwrap();
        assert_eq!(v.chunks[ci].bytes.len(), len0, "same size liquid, same size chunk");
        // textures growing before it move it along
        let ls = vec![
            Layer { texture: "Tileset\\A.blp".into(), flags: 0, effect: 0, alpha: None },
            Layer { texture: "Tileset\\B.blp".into(), flags: 0x100, effect: 0, alpha: Some(vec![200; 4096]) },
        ];
        v.set_layers(3, 3, &ls).unwrap();
        let v = Adt::parse(&v.write()).unwrap();
        assert_eq!(v.liquid(3, 3).unwrap().kind, LiquidKind::Magma);
        assert_eq!(v.layers(3, 3).unwrap().len(), 2);
        // and away again
        let mut w = v.clone();
        w.set_liquid(3, 3, None).unwrap();
        let w = Adt::parse(&w.write()).unwrap();
        assert!(w.liquid(3, 3).is_none());
        assert_eq!(u32_at(&w.chunks[w.mcnk(3, 3).unwrap()].bytes, h::SIZE_LIQUID), 8);
        assert_eq!(u32_at(&w.chunks[w.mcnk(3, 3).unwrap()].bytes, h::FLAGS) & 0x3C, 0);
    }

    #[test]
    fn unedited_tiles_write_back_byte_for_byte() {
        let t = fake_tile(32, 48, 50.0);
        assert_eq!(Adt::parse(&t).unwrap().write(), t);
    }

    #[test]
    fn doodads_go_in_with_their_references() {
        let (a, b) = (32, 48);
        let t = fake_tile(a, b, 50.0);
        let mut adt = Adt::parse(&t).unwrap();
        // a spot in the middle of the tile, in world coordinates
        let wx = HALF - (b as f64 * TILE + 100.0);
        let wy = HALF - (a as f64 * TILE + 210.0);
        assert_eq!(tile_of(wx, wy), (a, b));
        let pos = to_file(wx, wy, 52.0);
        let d = Doodad { model: "World\\Forge\\Lantern.mdx".into(), uid: 40_000_001, pos, rot: [0.0, 90.0, 0.0], scale: 1024, flags: 0, extents: None, set: 0 };
        let d2 = Doodad { model: "World\\Generic\\Tree01.mdx".into(), uid: 40_000_002, pos, rot: [0.0; 3], scale: 2048, flags: 0, extents: None, set: 0 };
        adt.add_doodads((a, b), &[d.clone(), d2.clone()]).unwrap();
        let bytes = adt.write();
        let back = Adt::parse(&bytes).unwrap();
        assert_eq!(back.doodads(), vec![d, d2]);
        let (col, row) = chunk_of((a, b), pos).unwrap();
        assert_eq!((col, row), (6, 3));
        assert_eq!(back.object_refs(col, row), (2, 0));
        // MCIN still points at every MCNK
        let mcin_at = back.chunks.iter().take_while(|c| c.magic != "MCIN").map(|c| c.bytes.len()).sum::<usize>() + 8;
        for k in 0..256 {
            let off = u32_at(&bytes, mcin_at + k * 16) as usize;
            assert_eq!(&bytes[off..off + 4], b"KNCM", "MCIN entry {k}");
            assert_eq!(u32_at(&bytes, mcin_at + k * 16 + 4) as usize, u32_at(&bytes, off + 4) as usize + 8);
        }
        // MHDR's MDDF offset still lands on MDDF
        let mddf = u32_at(&bytes, 20 + 4 + 6 * 4) as usize + 20;
        assert_eq!(&bytes[mddf..mddf + 4], b"FDDM");
        // the shadow map moved with the grown MCRF
        let ci = back.mcnk(col, row).unwrap();
        let sh = u32_at(&back.chunks[ci].bytes, 8 + 0x2C) as usize;
        assert_eq!(&back.chunks[ci].bytes[sh..sh + 4], b"HSCM");
        assert!((back.height_at((a, b), pos[0] as f64, pos[2] as f64).unwrap() - 50.0).abs() < 1e-3);
    }
}

/// Against a real 1.12.1 install: every tile of a map reads, writes back byte for byte, and takes
/// a doodad. `FORGE_REAL_GAME=<game folder> FORGE_REAL_MAP=Azeroth cargo test real_tiles -- --ignored --nocapture`
#[cfg(test)]
mod real {
    use super::*;

    #[test]
    #[ignore]
    fn real_tiles_round_trip() {
        let game = crate::vfs::GameData::open(std::env::var("FORGE_REAL_GAME").expect("FORGE_REAL_GAME")).unwrap();
        let map = std::env::var("FORGE_REAL_MAP").unwrap_or_else(|_| "Azeroth".into());
        let prefix = format!("world\\maps\\{}\\", map.to_ascii_lowercase());
        let tiles: Vec<String> = game.files().iter().filter(|f| f.to_ascii_lowercase().starts_with(&prefix) && f.to_ascii_lowercase().ends_with(".adt")).cloned().collect();
        assert!(!tiles.is_empty(), "no {map} tiles");
        let (mut ok, mut layouts) = (0, std::collections::BTreeMap::new());
        let (mut waters, mut compared, mut same) = (0, 0, 0);
        let mut normal_err = 0f64;
        let mut buildings = 0;
        for path in &tiles {
            let bytes = game.read(path).unwrap();
            let t = Adt::parse(&bytes).unwrap_or_else(|e| panic!("{path}: {e:#}"));
            assert!(t.write() == bytes, "{path} doesn't write back byte for byte");
            let stem = path.rsplit('\\').next().unwrap().trim_end_matches(".adt");
            let mut parts = stem.rsplitn(3, '_');
            let b: i32 = parts.next().unwrap().parse().unwrap();
            let a: i32 = parts.next().unwrap().parse().unwrap();
            *layouts.entry(format!("{:?}", t.normal_layout((a, b)))).or_insert(0) += 1;
            // chunk positions are world x, world y of the chunk's corner (new tiles write them so)
            let ci = t.mcnk(3, 5).unwrap();
            let (px, py) = (f32_at(&t.chunks[ci].bytes, h::POSITION) as f64, f32_at(&t.chunks[ci].bytes, h::POSITION + 4) as f64);
            assert!((px - (HALF - (b as f64 * TILE + 5.0 * CHUNK))).abs() < 0.1 && (py - (HALF - (a as f64 * TILE + 3.0 * CHUNK))).abs() < 0.1, "{path}: chunk position {px}, {py}");
            let mut t2 = t.clone();
            let pos = [(a as f64 * TILE + 100.0) as f32, 0.0, (b as f64 * TILE + 100.0) as f32];
            t2.add_doodads((a, b), &[Doodad { model: "World\\Generic\\Tree01.mdx".into(), uid: 40_000_000, pos, rot: [0.0; 3], scale: 1024, flags: 0, extents: None, set: 0 }]).unwrap();
            let back = Adt::parse(&t2.write()).unwrap();
            assert_eq!(back.doodads().len(), t.doodads().len() + 1, "{path}");
            // normals Forge computes for untouched ground match the game's own (a reshaped tile
            // lights the way its neighbours do)
            let lay = t.normal_layout((a, b));
            let mut t4 = t.clone();
            let (mut diff, mut n) = (0f64, 0f64);
            for k in [17usize, 85, 136, 200] {
                let (c, r) = (k % 16, k / 16);
                t4.recompute_normals((a, b), c, r, lay).unwrap();
                let (b0, b1) = (&t.chunks[t.mcnk(c, r).unwrap()].bytes, &t4.chunks[t4.mcnk(c, r).unwrap()].bytes);
                let o = u32_at(b0, h::OFS_NORMAL) as usize + 8;
                for i in 0..145 * 3 {
                    diff += (b0[o + i] as i8 as f64 - b1[o + i] as i8 as f64).abs();
                    n += 1.0;
                }
            }
            normal_err = normal_err.max(diff / n);
            assert!(diff / n < 3.5, "{path}: recomputed normals are off by {:.1}/127 on average", diff / n);
            // textures and water rewritten as they are read come back the same
            let mut t3 = t.clone();
            for k in [0usize, 37, 128, 255] {
                let (c, r) = (k % 16, k / 16);
                let ls = t.layers(c, r).unwrap();
                if !ls.is_empty() {
                    t3.set_layers(c, r, &ls).unwrap();
                }
                if let Some(l) = t.liquid(c, r) {
                    waters += 1;
                    t3.set_liquid(c, r, Some(&l)).unwrap();
                }
            }
            let back = Adt::parse(&t3.write()).unwrap();
            for k in [0usize, 37, 128, 255] {
                let (c, r) = (k % 16, k / 16);
                let (a1, a2) = (t.layers(c, r).unwrap(), back.layers(c, r).unwrap());
                assert_eq!(a1.iter().map(|l| (&l.texture, l.flags)).collect::<Vec<_>>(), a2.iter().map(|l| (&l.texture, l.flags)).collect::<Vec<_>>(), "{path} {k}");
                let (w1, w2) = (t.liquid(c, r), back.liquid(c, r));
                assert_eq!(w1.as_ref().map(|w| (w.kind, w.tiles, w.verts.iter().map(|v| v.1).collect::<Vec<_>>())), w2.as_ref().map(|w| (w.kind, w.tiles, w.verts.iter().map(|v| v.1).collect::<Vec<_>>())), "{path} {k}");
            }
            // buildings: the box Forge works out for a game building where the tile places it is
            // the box the tile itself stores
            for w in t.wmos() {
                if w.rot[0].abs() > 0.1 || w.rot[2].abs() > 0.1 {
                    continue; // tilted: Forge places buildings level
                }
                if let Some(local) = game.read(&w.model).ok().and_then(|root| wmo_bounds(&root).ok()) {
                    let ours = wmo_extents(local, w.pos, w.rot[1]);
                    let real = w.extents.unwrap();
                    let err = (0..6).map(|k| (ours[k] - real[k]).abs()).fold(0f32, f32::max);
                    assert!(err < 0.05, "{path}: {} box {ours:?} vs the tile's {real:?}", w.model);
                    buildings += 1;
                }
            }
            // the server's own .map for this tile, when given: Forge's conversion matches it
            if let Ok(sm) = std::env::var("FORGE_REAL_SERVER_MAPS") {
                let id = crate::world::MAPS.iter().find(|(_, n)| n.eq_ignore_ascii_case(&map)).unwrap().0;
                if let Ok(theirs) = std::fs::read(std::path::Path::new(&sm).join(crate::gridmap::file_name(id, a, b))) {
                    let at = crate::data::Dbc::parse(&game.read("DBFilesClient\\AreaTable.dbc").unwrap()).unwrap();
                    let flags = crate::gridmap::area_flags(&at);
                    let ours = crate::gridmap::convert(&t, &|i| flags.get(&i).copied(), crate::gridmap::version_of(&theirs).unwrap()).unwrap();
                    // header, area and heights byte for byte; water and holes as well unless the
                    // extractor's leftover liquid heights at the tile's far edge differ
                    let hend = u32::from_le_bytes(theirs[16..20].try_into().unwrap()) as usize + u32::from_le_bytes(theirs[20..24].try_into().unwrap()) as usize;
                    assert_eq!(&ours[..hend], &theirs[..hend.min(theirs.len())], "{path}: server map differs");
                    if ours == theirs {
                        same += 1;
                    }
                    compared += 1;
                }
            }
            ok += 1;
        }
        println!("{map}: {ok} tiles round-trip ({waters} water chunks rewritten); normal layouts: {layouts:?}; worst normal error {normal_err:.2}/127; {buildings} building boxes match; server maps compared {compared}, identical {same}");
    }
}
