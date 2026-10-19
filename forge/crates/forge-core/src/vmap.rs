//! The server's collision for what packs place: CMaNGOS's vmaps.
//!
//! The server knows the shape of trees, rocks and buildings from its `vmaps` folder (made once by
//! `vmap_extractor` + `vmap_assembler` from the client). Without new vmaps, a building a pack places
//! is walked through, shot through and seen through on the server. Re-running the extractor over a
//! whole client takes long and needs the pack inside the client; this writes the same files for just
//! the tiles a pack edits, from the realm's own vmaps:
//!
//! * `MMM.vmtree`: the map's tree. Its leaves point into one list of every model spawn on the map;
//!   the tiles name their spawns by index into that list. Spawns the pack adds go on the end, so the
//!   tiles a pack doesn't touch stay valid as they are, and the tree is rebuilt over the longer list
//!   (a port of the server's own BIH builder).
//! * `MMM_AA_BB.vmtile` for each edited tile: its spawns, worked out from the tile the way the
//!   extractor does (doodads with a collision mesh, buildings, and the furniture of a building's
//!   doodad set), keeping the index of every spawn that was already there.
//! * `Name.m2.vmo`: the collision mesh of a model no spawn on the realm used yet (the game's, or a
//!   pack's own from Models), from the model's bounding triangles.
//!
//! Formats and maths follow CMaNGOS (`src/game/vmap`, `contrib/vmap_extractor`), so the files load in
//! the server like the assembler's; `tests::rebuild_matches_the_assembler` compares with real ones.

use anyhow::{bail, Context, Result};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};

pub const MAGIC: &[u8; 8] = b"VMAP_7.0";
const MOD_M2: u32 = 1;
const MOD_WORLDSPAWN: u32 = 2;
const MOD_HAS_BOUND: u32 = 4;
/// 32 tiles of 533.33333 yards: where the extractor puts a building placed at 0, 0.
const MAP_MID: f32 = 533.33333 * 32.0;

// ---------------------------------------------------------------------------------------------
// maths, as G3D does it (f32, the same order of operations)

pub type V3 = [f32; 3];

#[derive(Clone, Copy, Debug)]
struct M3([[f32; 3]; 3]);

impl M3 {
    fn mul(&self, o: &M3) -> M3 {
        let mut r = [[0f32; 3]; 3];
        for (i, row) in r.iter_mut().enumerate() {
            for (j, v) in row.iter_mut().enumerate() {
                *v = self.0[i][0] * o.0[0][j] + self.0[i][1] * o.0[1][j] + self.0[i][2] * o.0[2][j];
            }
        }
        M3(r)
    }
    fn apply(&self, v: V3) -> V3 {
        let e = &self.0;
        [
            e[0][0] * v[0] + e[0][1] * v[1] + e[0][2] * v[2],
            e[1][0] * v[0] + e[1][1] * v[1] + e[1][2] * v[2],
            e[2][0] * v[0] + e[2][1] * v[1] + e[2][2] * v[2],
        ]
    }
    /// G3D's Matrix3::fromEulerAnglesZYX(yaw, pitch, roll) = Z · (Y · X).
    fn euler_zyx(y: f32, p: f32, r: f32) -> M3 {
        let (c, s) = (y.cos(), y.sin());
        let z = M3([[c, -s, 0.0], [s, c, 0.0], [0.0, 0.0, 1.0]]);
        let (c, s) = (p.cos(), p.sin());
        let ym = M3([[c, 0.0, s], [0.0, 1.0, 0.0], [-s, 0.0, c]]);
        let (c, s) = (r.cos(), r.sin());
        let x = M3([[1.0, 0.0, 0.0], [0.0, c, -s], [0.0, s, c]]);
        z.mul(&ym.mul(&x))
    }
    /// G3D's Matrix3(Quat): the quaternion made unit first.
    fn quat(x: f32, y: f32, z: f32, w: f32) -> M3 {
        let k = 1.0f32 / (x * x + y * y + z * z + w * w).sqrt();
        let (x, y, z, w) = (x * k, y * k, z * k, w * k);
        let (xx, xy, xz, xw) = (2.0 * x * x, 2.0 * x * y, 2.0 * x * z, 2.0 * x * w);
        let (yy, yz, yw) = (2.0 * y * y, 2.0 * y * z, 2.0 * y * w);
        let (zz, zw) = (2.0 * z * z, 2.0 * z * w);
        M3([[1.0 - yy - zz, xy - zw, xz + yw], [xy + zw, 1.0 - xx - zz, yz - xw], [xz - yw, yz + xw, 1.0 - xx - yy]])
    }
    /// G3D's toEulerAnglesXYZ (with its aSin, which answers -pi/2 at 1 and pi/2 at -1).
    fn to_euler_xyz(&self) -> (f32, f32, f32) {
        let e = &self.0;
        let half = std::f64::consts::FRAC_PI_2;
        if e[0][2] < 1.0 {
            if e[0][2] > -1.0 {
                let asin = |v: f64| if -1.0 < v { if v < 1.0 { v.asin() } else { -half } } else { half };
                ((-e[1][2] as f64).atan2(e[2][2] as f64) as f32, asin(e[0][2] as f64) as f32, (-e[0][1] as f64).atan2(e[0][0] as f64) as f32)
            } else {
                (-(e[1][0] as f64).atan2(e[1][1] as f64) as f32, -half as f32, 0.0)
            }
        } else {
            ((e[1][0] as f64).atan2(e[1][1] as f64) as f32, half as f32, 0.0)
        }
    }
}

fn add(a: V3, b: V3) -> V3 {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}
fn vmin(a: V3, b: V3) -> V3 {
    [if a[0] < b[0] { a[0] } else { b[0] }, if a[1] < b[1] { a[1] } else { b[1] }, if a[2] < b[2] { a[2] } else { b[2] }]
}
fn vmax(a: V3, b: V3) -> V3 {
    [if a[0] > b[0] { a[0] } else { b[0] }, if a[1] > b[1] { a[1] } else { b[1] }, if a[2] > b[2] { a[2] } else { b[2] }]
}

/// The rotation the server gives a spawn (degrees, as the spawn stores them).
fn spawn_rotation(rot: V3) -> M3 {
    let pi = std::f64::consts::PI;
    M3::euler_zyx((pi * rot[1] as f64 / 180.0) as f32, (pi * rot[0] as f64 / 180.0) as f32, (pi * rot[2] as f64 / 180.0) as f32)
}

// ---------------------------------------------------------------------------------------------
// the bounding interval hierarchy (src/game/vmap/BIH.cpp)

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Bih {
    pub lo: V3,
    pub hi: V3,
    pub tree: Vec<u32>,
    pub objects: Vec<u32>,
}

const MAX_STACK: i32 = 64;

fn fuzzy_eq(a: f64, b: f64) -> bool {
    let eps = 0.00001f32 as f64;
    let aa = a.abs() + 1.0;
    a == b || (a - b).abs() <= if aa == f64::INFINITY { eps } else { eps * aa }
}

impl Bih {
    fn empty() -> Bih {
        Bih { lo: [0.0; 3], hi: [0.0; 3], tree: vec![3 << 30, 0, 0], objects: vec![] }
    }

    pub fn build(bounds: &[(V3, V3)], leaf: i32) -> Bih {
        if bounds.is_empty() {
            return Bih::empty();
        }
        let (mut lo, mut hi) = bounds[0];
        for b in bounds {
            lo = vmin(lo, b.0);
            hi = vmax(hi, b.1);
        }
        let mut idx: Vec<u32> = (0..bounds.len() as u32).collect();
        let mut tree = vec![3u32 << 30, 0, 0];
        let mut grid = (lo, hi);
        let mut node = (lo, hi);
        subdivide(0, bounds.len() as i32 - 1, &mut tree, &mut idx, bounds, leaf, &mut grid, &mut node, 0, 1);
        Bih { lo, hi, tree, objects: idx }
    }

    pub fn write(&self, out: &mut Vec<u8>) {
        for v in self.lo.iter().chain(self.hi.iter()) {
            out.extend_from_slice(&v.to_le_bytes());
        }
        out.extend_from_slice(&(self.tree.len() as u32).to_le_bytes());
        for t in &self.tree {
            out.extend_from_slice(&t.to_le_bytes());
        }
        out.extend_from_slice(&(self.objects.len() as u32).to_le_bytes());
        for o in &self.objects {
            out.extend_from_slice(&o.to_le_bytes());
        }
    }

    fn read(r: &mut Reader) -> Result<Bih> {
        let lo = r.v3()?;
        let hi = r.v3()?;
        let n = r.u32()? as usize;
        let tree = (0..n).map(|_| r.u32()).collect::<Result<_>>()?;
        let c = r.u32()? as usize;
        let objects = (0..c).map(|_| r.u32()).collect::<Result<_>>()?;
        Ok(Bih { lo, hi, tree, objects })
    }
}

fn leaf_node(tree: &mut [u32], at: usize, left: i32, right: i32) {
    tree[at] = (3 << 30) | left as u32;
    tree[at + 1] = (right - left + 1) as u32;
}

#[allow(clippy::too_many_arguments)]
fn subdivide(left: i32, mut right: i32, tree: &mut Vec<u32>, idx: &mut [u32], prim: &[(V3, V3)], max_prims: i32, grid: &mut (V3, V3), node: &mut (V3, V3), mut at: usize, mut depth: i32) {
    if right - left + 1 <= max_prims || depth >= MAX_STACK {
        leaf_node(tree, at, left, right);
        return;
    }
    let mut axis: i32 = -1;
    let mut right_orig;
    let mut clip_l;
    let mut clip_r;
    let mut prev_clip = f32::NAN;
    let mut split = f32::NAN;
    let mut was_left = true;
    loop {
        let prev_axis = axis;
        let prev_split = split;
        let d = [grid.1[0] - grid.0[0], grid.1[1] - grid.0[1], grid.1[2] - grid.0[2]];
        // G3D's primaryAxis
        let (nx, ny, nz) = (d[0].abs() as f64, d[1].abs() as f64, d[2].abs() as f64);
        axis = if nx > ny { if nx > nz { 0 } else { 2 } } else if ny > nz { 1 } else { 2 };
        let a = axis as usize;
        split = 0.5f32 * (grid.0[a] + grid.1[a]);
        clip_l = f32::NEG_INFINITY;
        clip_r = f32::INFINITY;
        right_orig = right;
        let mut node_l = f32::INFINITY;
        let mut node_r = f32::NEG_INFINITY;
        let mut i = left;
        while i <= right {
            let obj = idx[i as usize] as usize;
            let minb = prim[obj].0[a];
            let maxb = prim[obj].1[a];
            let center = (minb + maxb) * 0.5f32;
            if center <= split {
                i += 1;
                if clip_l < maxb {
                    clip_l = maxb;
                }
            } else {
                idx.swap(i as usize, right as usize);
                right -= 1;
                if clip_r > minb {
                    clip_r = minb;
                }
            }
            node_l = if minb < node_l { minb } else { node_l };
            node_r = if node_r < maxb { maxb } else { node_r };
        }
        if node_l > node.0[a] && node_r < node.1[a] {
            let node_box_w = node.1[a] - node.0[a];
            let node_new_w = node_r - node_l;
            if 1.3f32 * node_new_w < node_box_w {
                let next = tree.len();
                tree.extend_from_slice(&[0, 0, 0]);
                tree[at] = ((axis as u32) << 30) | (1 << 29) | next as u32;
                tree[at + 1] = node_l.to_bits();
                tree[at + 2] = node_r.to_bits();
                node.0[a] = node_l;
                node.1[a] = node_r;
                subdivide(left, right_orig, tree, idx, prim, max_prims, grid, node, next, depth + 1);
                return;
            }
        }
        if right == right_orig {
            if prev_axis == axis && fuzzy_eq(prev_split as f64, split as f64) {
                leaf_node(tree, at, left, right);
                return;
            }
            if clip_l <= split {
                grid.1[a] = split;
                prev_clip = clip_l;
                was_left = true;
                continue;
            }
            grid.1[a] = split;
            prev_clip = f32::NAN;
        } else if left > right {
            right = right_orig;
            if prev_axis == axis && fuzzy_eq(prev_split as f64, split as f64) {
                leaf_node(tree, at, left, right);
                return;
            }
            if clip_r >= split {
                grid.0[a] = split;
                prev_clip = clip_r;
                was_left = false;
                continue;
            }
            grid.0[a] = split;
            prev_clip = f32::NAN;
        } else {
            if prev_axis != -1 && !prev_clip.is_nan() {
                let next = tree.len();
                tree.extend_from_slice(&[0, 0, 0]);
                if was_left {
                    tree[at] = ((prev_axis as u32) << 30) | next as u32;
                    tree[at + 1] = prev_clip.to_bits();
                    tree[at + 2] = f32::INFINITY.to_bits();
                } else {
                    tree[at] = ((prev_axis as u32) << 30) | (next as u32 - 3);
                    tree[at + 1] = f32::NEG_INFINITY.to_bits();
                    tree[at + 2] = prev_clip.to_bits();
                }
                depth += 1;
                at = next;
            }
            break;
        }
    }
    let a = axis as usize;
    let mut next = tree.len();
    let nl = right - left + 1;
    let nr = right_orig - (right + 1) + 1;
    if nl > 0 {
        tree.extend_from_slice(&[0, 0, 0]);
    } else {
        next -= 3;
    }
    if nr > 0 {
        tree.extend_from_slice(&[0, 0, 0]);
    }
    tree[at] = ((axis as u32) << 30) | next as u32;
    tree[at + 1] = clip_l.to_bits();
    tree[at + 2] = clip_r.to_bits();
    let (mut grid_l, mut grid_r) = (*grid, *grid);
    let (mut node_l, mut node_r) = (*node, *node);
    grid_l.1[a] = split;
    grid_r.0[a] = split;
    node_l.1[a] = clip_l;
    node_r.0[a] = clip_r;
    if nl > 0 {
        subdivide(left, right, tree, idx, prim, max_prims, &mut grid_l, &mut node_l, next, depth + 1);
    }
    if nr > 0 {
        subdivide(right + 1, right_orig, tree, idx, prim, max_prims, &mut grid_r, &mut node_r, next + 3, depth + 1);
    }
}

// ---------------------------------------------------------------------------------------------
// files

struct Reader<'a> {
    b: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    fn new(b: &'a [u8]) -> Self {
        Reader { b, at: 0 }
    }
    fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        let s = self.b.get(self.at..self.at + n).context("vmap file ends early")?;
        self.at += n;
        Ok(s)
    }
    fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into()?))
    }
    fn u16(&mut self) -> Result<u16> {
        Ok(u16::from_le_bytes(self.take(2)?.try_into()?))
    }
    fn f32(&mut self) -> Result<f32> {
        Ok(f32::from_le_bytes(self.take(4)?.try_into()?))
    }
    fn v3(&mut self) -> Result<V3> {
        Ok([self.f32()?, self.f32()?, self.f32()?])
    }
    fn tag(&mut self, t: &[u8]) -> Result<()> {
        let got = self.take(t.len())?;
        if got != t {
            bail!("vmap file: expected {} here", String::from_utf8_lossy(t));
        }
        Ok(())
    }
    fn done(&self) -> bool {
        self.at >= self.b.len()
    }
}

/// One model on the map, as the server stores it (`ModelSpawn`).
#[derive(Clone, Debug, PartialEq)]
pub struct Spawn {
    pub flags: u32,
    pub adt_id: u16,
    pub id: u32,
    pub pos: V3,
    pub rot: V3,
    pub scale: f32,
    pub bound: Option<(V3, V3)>,
    pub name: String,
}

impl Spawn {
    fn read(r: &mut Reader) -> Result<Spawn> {
        let flags = r.u32()?;
        let adt_id = r.u16()?;
        let id = r.u32()?;
        let pos = r.v3()?;
        let rot = r.v3()?;
        let scale = r.f32()?;
        let bound = if flags & MOD_HAS_BOUND != 0 { Some((r.v3()?, r.v3()?)) } else { None };
        let n = r.u32()? as usize;
        if n > 500 {
            bail!("vmap spawn name too long");
        }
        let name = String::from_utf8_lossy(r.take(n)?).to_string();
        Ok(Spawn { flags, adt_id, id, pos, rot, scale, bound, name })
    }
    fn write(&self, out: &mut Vec<u8>) {
        out.extend_from_slice(&self.flags.to_le_bytes());
        out.extend_from_slice(&self.adt_id.to_le_bytes());
        out.extend_from_slice(&self.id.to_le_bytes());
        for v in self.pos.iter().chain(self.rot.iter()) {
            out.extend_from_slice(&v.to_le_bytes());
        }
        out.extend_from_slice(&self.scale.to_le_bytes());
        if self.flags & MOD_HAS_BOUND != 0 {
            let (lo, hi) = self.bound.unwrap_or(([0.0; 3], [0.0; 3]));
            for v in lo.iter().chain(hi.iter()) {
                out.extend_from_slice(&v.to_le_bytes());
            }
        }
        out.extend_from_slice(&(self.name.len() as u32).to_le_bytes());
        out.extend_from_slice(self.name.as_bytes());
    }
    /// Same model in the same place (an edited tile keeps the index of what was there).
    fn same_place(&self, o: &Spawn) -> bool {
        let near = |a: V3, b: V3, e: f32| (0..3).all(|i| (a[i] - b[i]).abs() <= e);
        self.name.eq_ignore_ascii_case(&o.name) && near(self.pos, o.pos, 0.01) && near(self.rot, o.rot, 0.01) && (self.scale - o.scale).abs() <= 0.001
    }
}

pub fn tree_name(map: u32) -> String {
    format!("{map:03}.vmtree")
}
pub fn tile_name(map: u32, a: u32, b: u32) -> String {
    format!("{map:03}_{a:02}_{b:02}.vmtile")
}

/// A map's tree file.
pub struct Tree {
    pub tiled: bool,
    pub bih: Bih,
    /// the GOBJ part (global spawns of maps without tiles), kept as it is
    pub gobj: Vec<u8>,
}

impl Tree {
    pub fn parse(b: &[u8]) -> Result<Tree> {
        let mut r = Reader::new(b);
        r.tag(MAGIC).context("not a vmtree of this server (VMAP_7.0)")?;
        let tiled = r.take(1)?[0] != 0;
        r.tag(b"NODE")?;
        let bih = Bih::read(&mut r)?;
        r.tag(b"GOBJ")?;
        Ok(Tree { tiled, bih, gobj: b[r.at..].to_vec() })
    }
    pub fn write(&self) -> Vec<u8> {
        let mut out = MAGIC.to_vec();
        out.push(self.tiled as u8);
        out.extend_from_slice(b"NODE");
        self.bih.write(&mut out);
        out.extend_from_slice(b"GOBJ");
        out.extend_from_slice(&self.gobj);
        out
    }
}

/// A tile file: its spawns and each one's index in the map's list.
pub fn parse_tile(b: &[u8]) -> Result<Vec<(Spawn, u32)>> {
    let mut r = Reader::new(b);
    r.tag(MAGIC)?;
    let n = r.u32()?;
    let mut out = Vec::with_capacity(n as usize);
    for _ in 0..n {
        let s = Spawn::read(&mut r)?;
        let i = r.u32()?;
        out.push((s, i));
    }
    Ok(out)
}

pub fn write_tile(spawns: &[(Spawn, u32)]) -> Vec<u8> {
    let mut out = MAGIC.to_vec();
    out.extend_from_slice(&(spawns.len() as u32).to_le_bytes());
    for (s, i) in spawns {
        s.write(&mut out);
        out.extend_from_slice(&i.to_le_bytes());
    }
    out
}

/// The vertices of a `.vmo` (every group), for a spawn's bounds.
pub fn vmo_vertices(b: &[u8]) -> Result<Vec<V3>> {
    let mut r = Reader::new(b);
    r.tag(MAGIC)?;
    r.tag(b"WMOD")?;
    r.take(8)?; // chunk size, root WMO id
    if r.done() {
        return Ok(vec![]);
    }
    r.tag(b"GMOD")?;
    let groups = r.u32()?;
    let mut out = vec![];
    for _ in 0..groups {
        r.take(24 + 8)?; // bounds, flags, group id
        r.tag(b"VERT")?;
        r.u32()?;
        let n = r.u32()?;
        if n == 0 {
            continue; // a group without geometry ends here
        }
        for _ in 0..n {
            out.push(r.v3()?);
        }
        r.tag(b"TRIM")?;
        r.u32()?;
        let t = r.u32()? as usize;
        r.take(t * 12)?;
        r.tag(b"MBIH")?;
        Bih::read(&mut r)?;
        r.tag(b"LIQU")?;
        let l = r.u32()? as usize;
        r.take(l)?;
    }
    Ok(out)
}

/// A `.vmo` for an M2 with a collision mesh (its bounding triangles), as the extractor and
/// assembler make one: None when the model has none (players walk through it, as in the game).
pub fn m2_vmo(m2: &[u8]) -> Option<Vec<u8>> {
    let u = |o: usize| m2.get(o..o + 4).map(|b| u32::from_le_bytes(b.try_into().unwrap()));
    if m2.get(0..4)? != b"MD20" {
        return None;
    }
    let (n_tri, o_tri, n_vert, o_vert) = (u(236)? as usize, u(240)? as usize, u(244)? as usize, u(248)? as usize);
    if n_tri == 0 || n_vert == 0 {
        return None;
    }
    let mut verts = Vec::with_capacity(n_vert);
    for i in 0..n_vert {
        let o = o_vert + i * 12;
        let f = |k: usize| m2.get(o + k..o + k + 4).map(|b| f32::from_le_bytes(b.try_into().unwrap()));
        verts.push([f(0)?, f(4)?, f(8)?]);
    }
    let mut ind: Vec<u16> = (0..n_tri).map(|i| m2.get(o_tri + i * 2..o_tri + i * 2 + 2).map(|b| u16::from_le_bytes([b[0], b[1]]))).collect::<Option<_>>()?;
    // the extractor turns each triangle over (b and c swapped)
    for i in 0..n_tri {
        if i % 3 == 1 && i + 1 < n_tri {
            ind.swap(i, i + 1);
        }
    }
    let tris: Vec<[u32; 3]> = ind.chunks_exact(3).map(|t| [t[0] as u32, t[1] as u32, t[2] as u32]).collect();
    if tris.iter().any(|t| t.iter().any(|&i| i as usize >= n_vert)) {
        return None;
    }
    Some(world_model(0, &[(0, 0, ([0.0; 3], [0.0; 3]), verts, tris)]))
}

/// WorldModel::writeFile: groups of (flags, group id, bounds, vertices, triangles), no liquid.
fn world_model(root_id: u32, groups: &[(u32, u32, (V3, V3), Vec<V3>, Vec<[u32; 3]>)]) -> Vec<u8> {
    let mut out = MAGIC.to_vec();
    out.extend_from_slice(b"WMOD");
    out.extend_from_slice(&8u32.to_le_bytes());
    out.extend_from_slice(&root_id.to_le_bytes());
    if groups.is_empty() {
        return out;
    }
    out.extend_from_slice(b"GMOD");
    out.extend_from_slice(&(groups.len() as u32).to_le_bytes());
    for (flags, gid, (lo, hi), verts, tris) in groups {
        for v in lo.iter().chain(hi.iter()) {
            out.extend_from_slice(&v.to_le_bytes());
        }
        out.extend_from_slice(&flags.to_le_bytes());
        out.extend_from_slice(&gid.to_le_bytes());
        out.extend_from_slice(b"VERT");
        out.extend_from_slice(&(4 + 12 * verts.len() as u32).to_le_bytes());
        out.extend_from_slice(&(verts.len() as u32).to_le_bytes());
        if verts.is_empty() {
            continue;
        }
        for v in verts {
            for c in v {
                out.extend_from_slice(&c.to_le_bytes());
            }
        }
        out.extend_from_slice(b"TRIM");
        out.extend_from_slice(&(4 + 12 * tris.len() as u32).to_le_bytes());
        out.extend_from_slice(&(tris.len() as u32).to_le_bytes());
        for t in tris {
            for i in t {
                out.extend_from_slice(&i.to_le_bytes());
            }
        }
        let tb: Vec<(V3, V3)> = tris
            .iter()
            .map(|t| {
                let (a, b, c) = (verts[t[0] as usize], verts[t[1] as usize], verts[t[2] as usize]);
                (vmin(vmin(a, b), c), vmax(vmax(a, b), c))
            })
            .collect();
        out.extend_from_slice(b"MBIH");
        Bih::build(&tb, 3).write(&mut out);
        out.extend_from_slice(b"LIQU");
        out.extend_from_slice(&0u32.to_le_bytes());
    }
    out.extend_from_slice(b"GBIH");
    let gb: Vec<(V3, V3)> = groups.iter().map(|g| g.2).collect();
    Bih::build(&gb, 1).write(&mut out);
    out
}

// ---------------------------------------------------------------------------------------------
// the spawns of a tile, as the extractor finds them

/// The extractor's file names: the plain name, each word capitalised and the rest lower case,
/// spaces as underscores, the extension lower case (`fixnamen` + `fixname2`); `.mdx` as `.m2`.
pub fn model_name(path: &str) -> String {
    let plain = path.rsplit(['\\', '/']).next().unwrap_or(path);
    let mut b: Vec<u8> = plain.as_bytes().to_vec();
    let n = b.len();
    if n >= 3 {
        for i in 0..n - 3 {
            let prev_alpha = i > 0 && b[i - 1].is_ascii_alphabetic();
            if i > 0 && b[i].is_ascii_uppercase() && prev_alpha {
                b[i] |= 0x20;
            } else if !prev_alpha && b[i].is_ascii_lowercase() {
                b[i] &= !0x20;
            }
        }
        for c in &mut b[n - 3..] {
            *c |= 0x20;
        }
        for c in &mut b[..n - 3] {
            if *c == b' ' {
                *c = b'_';
            }
        }
    }
    let mut s = String::from_utf8_lossy(&b).to_string();
    if s.ends_with(".mdx") || s.ends_with(".mdl") {
        s.truncate(s.len() - 2);
        s.push('2');
    }
    s
}

/// The file a spawn's model is read from: `Name.vmo`, or for a name ending in NUL the name
/// before it (C strings end there).
pub fn vmo_file(name: &str) -> String {
    match name.find('\0') {
        Some(p) => name[..p].to_string(),
        None => format!("{name}.vmo"),
    }
}

/// What the spawns need to know of models.
pub trait Models {
    /// The vertices of a model's collision (from its `.vmo`, or worked out), None if it has none.
    fn collision(&mut self, name: &str, path: &str) -> Option<Vec<V3>>;
    /// A game or pack file (WMO roots and groups).
    fn read(&mut self, path: &str) -> Option<Vec<u8>>;
}

fn chunks(b: &[u8]) -> Vec<([u8; 4], &[u8])> {
    let mut out = vec![];
    let mut at = 0;
    while at + 8 <= b.len() {
        let mut id: [u8; 4] = b[at..at + 4].try_into().unwrap();
        id.reverse();
        let size = u32::from_le_bytes(b[at + 4..at + 8].try_into().unwrap()) as usize;
        let end = (at + 8 + size).min(b.len());
        out.push((id, &b[at + 8..end]));
        at = at + 8 + size;
    }
    out
}

fn names(b: &[u8]) -> Vec<(usize, String)> {
    let mut out = vec![];
    let mut at = 0;
    while at < b.len() {
        let end = b[at..].iter().position(|&c| c == 0).map(|p| at + p).unwrap_or(b.len());
        out.push((at, String::from_utf8_lossy(&b[at..end]).to_string()));
        at = end + 1;
    }
    out
}

fn f32s(b: &[u8], at: usize, n: usize) -> Vec<f32> {
    (0..n).map(|i| b.get(at + i * 4..at + i * 4 + 4).map(|x| f32::from_le_bytes(x.try_into().unwrap())).unwrap_or(0.0)).collect()
}
fn u16at(b: &[u8], at: usize) -> u16 {
    b.get(at..at + 2).map(|x| u16::from_le_bytes([x[0], x[1]])).unwrap_or(0)
}
fn u32at(b: &[u8], at: usize) -> u32 {
    b.get(at..at + 4).map(|x| u32::from_le_bytes(x.try_into().unwrap())).unwrap_or(0)
}

/// fixCoords: the file's (x, y, z) as the server's (z, x, y).
fn fix(v: &[f32]) -> V3 {
    [v[2], v[0], v[1]]
}

/// A placed M2's bounds: its collision vertices turned, sized and moved (calculateTransformedBound).
fn m2_bound(verts: &[V3], pos: V3, rot: V3, scale: f32) -> (V3, V3) {
    let m = spawn_rotation(rot);
    let mut b: Option<(V3, V3)> = None;
    for v in verts {
        let w = m.apply([v[0] * scale, v[1] * scale, v[2] * scale]);
        b = Some(match b {
            None => (w, w),
            Some((lo, hi)) => (vmin(lo, w), vmax(hi, w)),
        });
    }
    let (lo, hi) = b.unwrap_or(([0.0; 3], [0.0; 3]));
    (add(lo, pos), add(hi, pos))
}

/// The doodads of a building's doodad set that have a collision mesh (Doodad::ExtractSet).
fn set_spawns(models: &mut dyn Models, wmo_path: &str, pos: V3, rot: V3, set: u16, out: &mut Vec<Spawn>) {
    let Some(root) = models.read(wmo_path) else { return };
    let (mut sets, mut paths, mut spawns, mut group_names, mut n_groups) = (vec![], vec![], vec![], vec![], 0u32);
    for (id, c) in chunks(&root) {
        match &id {
            b"MOHD" => n_groups = u32at(c, 4),
            b"MODS" => sets = c.chunks_exact(32).map(|s| (u32at(s, 20), u32at(s, 24))).collect(),
            b"MODN" => paths = names(c),
            b"MODD" => spawns = c.chunks_exact(40).map(|d| d.to_vec()).collect(),
            b"MOGN" => group_names = c.to_vec(),
            _ => {}
        }
    }
    let Some(&(start, count)) = sets.get(set as usize) else { return };
    // the doodads the building's groups refer to (MODR), skipping unreachable groups and antiportals
    let mut refs = std::collections::BTreeSet::new();
    let stem = &wmo_path[..wmo_path.len() - 4];
    for g in 0..n_groups {
        let Some(gb) = models.read(&format!("{stem}_{g:03}.wmo")) else { return };
        let mut at = 0;
        let (mut flags, mut gname) = (0u32, -1i32);
        let mut modr: Vec<u16> = vec![];
        while at + 8 <= gb.len() {
            let mut id: [u8; 4] = gb[at..at + 4].try_into().unwrap();
            id.reverse();
            let mut size = u32::from_le_bytes(gb[at + 4..at + 8].try_into().unwrap()) as usize;
            let body = at + 8;
            if &id == b"MOGP" {
                size = 68;
                gname = u32at(&gb, body) as i32;
                flags = u32at(&gb, body + 8);
            } else if &id == b"MODR" {
                modr = (0..size / 2).map(|k| u16at(&gb, body + k * 2)).collect();
            }
            at = body + size;
        }
        let antiportal = gname >= 0 && (gname as usize) < group_names.len() && group_names[gname as usize..].split(|&c| c == 0).next() == Some(b"antiportal".as_slice());
        if flags & 0x80 != 0 || flags & 0x400_0000 != 0 || antiportal {
            continue;
        }
        refs.extend(modr);
    }
    let wmo_rot = M3::euler_zyx(rot[1] * std::f32::consts::PI / 180.0, rot[0] * std::f32::consts::PI / 180.0, rot[2] * std::f32::consts::PI / 180.0);
    for r in refs {
        let r = r as u32;
        if r < start || r >= start + count {
            continue;
        }
        let Some(d) = spawns.get(r as usize) else { continue };
        let name_index = u32at(d, 0) & 0xFF_FFFF;
        let Some((_, path)) = paths.iter().find(|(o, _)| *o == name_index as usize) else { continue };
        // the extractor's quirk, kept: a furniture .mdx's name keeps its old length, so it ends in a
        // NUL (and the server, like the assembler, reads its mesh from "Name.m2", without .vmo)
        let mut name = model_name(path);
        if path.len() > 3 && [".mdx", ".mdl"].contains(&path[path.len() - 4..].to_ascii_lowercase().as_str()) {
            name.push('\0');
        }
        let Some(verts) = models.collision(&name, path) else { continue };
        let p = f32s(d, 4, 3);
        let q = f32s(d, 16, 4);
        let scale = f32s(d, 32, 1)[0];
        let position = add(pos, wmo_rot.apply([p[0], p[1], p[2]]));
        let (ex, ey, ez) = M3::quat(q[0], q[1], q[2], q[3]).mul(&wmo_rot).to_euler_xyz();
        // toEulerAnglesXYZ(rotation.z, rotation.x, rotation.y), then degrees
        let deg = |r: f32| r * 180.0f32 / std::f64::consts::PI as f32;
        let rotation = [deg(ey), deg(ez), deg(ex)];
        out.push(Spawn { flags: MOD_M2 | MOD_HAS_BOUND, adt_id: 0, id: 0, pos: position, rot: rotation, scale, bound: Some(m2_bound(&verts, position, rotation, scale)), name });
    }
}

/// Every collision spawn of a tile (ADT bytes), as the extractor writes them to dir_bin and the
/// assembler bounds them; ids 0 (given when they join a map).
pub fn tile_spawns(adt: &[u8], models: &mut dyn Models) -> Vec<Spawn> {
    let mut out = vec![];
    let (mut mmdx, mut mwmo) = (vec![], vec![]);
    for (id, c) in chunks(adt) {
        match &id {
            b"MMDX" => mmdx = names(c).into_iter().map(|(_, n)| n).collect(),
            b"MWMO" => mwmo = names(c).into_iter().map(|(_, n)| n).collect(),
            b"MDDF" => {
                for d in c.chunks_exact(36) {
                    let Some(path) = mmdx.get(u32at(d, 0) as usize) else { continue };
                    let name = model_name(path);
                    let Some(verts) = models.collision(&name, path) else { continue };
                    let pos = fix(&f32s(d, 8, 3));
                    let r = f32s(d, 20, 3);
                    let rot = [r[0], r[1], r[2]];
                    let scale = u16at(d, 32) as f32 / 1024.0;
                    out.push(Spawn { flags: MOD_M2 | MOD_HAS_BOUND, adt_id: 0, id: 0, pos, rot, scale, bound: Some(m2_bound(&verts, pos, rot, scale)), name });
                }
            }
            b"MODF" => {
                for d in c.chunks_exact(64) {
                    let Some(path) = mwmo.get(u32at(d, 0) as usize) else { continue };
                    let name = model_name(path);
                    let mut p = f32s(d, 8, 3);
                    let r = f32s(d, 20, 3);
                    let rot = [r[0], r[1], r[2]];
                    let (lo, hi) = (f32s(d, 32, 3), f32s(d, 44, 3));
                    let flags = u16at(d, 56);
                    let set = u16at(d, 58);
                    let adt_id = u16at(d, 60);
                    // a destructible building isn't static collision; its furniture still is, placed
                    // where the file says (the extractor doesn't turn those coordinates)
                    if flags & 1 != 0 {
                        set_spawns(models, path, [p[0], p[1], p[2]], rot, set, &mut out);
                        continue;
                    }
                    if p[0] == 0.0 && p[2] == 0.0 {
                        p[0] = MAP_MID;
                        p[2] = MAP_MID;
                    }
                    let pos = fix(&p);
                    if models.collision(&name, path).is_some() {
                        let bound = (fix(&lo), fix(&hi));
                        out.push(Spawn { flags: MOD_HAS_BOUND, adt_id, id: 0, pos, rot, scale: 1.0, bound: Some(bound), name });
                    }
                    set_spawns(models, path, pos, rot, set, &mut out);
                }
            }
            _ => {}
        }
    }
    let _ = MOD_WORLDSPAWN;
    out
}

// ---------------------------------------------------------------------------------------------
// putting edited tiles into a map's vmaps

/// What `rebuild` wrote.
#[derive(Debug, Default)]
pub struct Rebuilt {
    /// files written into the output folder (names)
    pub files: Vec<String>,
    /// spawns on the edited tiles: kept, added, gone
    pub kept: usize,
    pub added: usize,
    pub removed: usize,
    pub warnings: Vec<String>,
}

/// Models from the realm's vmaps (their `.vmo`), else from the game or pack files (M2s: a new
/// `.vmo` is made for each, written with the rest).
pub struct VmapModels<'a> {
    pub base: PathBuf,
    pub read_file: &'a dyn Fn(&str) -> Option<Vec<u8>>,
    pub new_vmo: BTreeMap<String, Vec<u8>>,
    pub missing: Vec<String>,
    cache: HashMap<String, Option<Vec<V3>>>,
}

impl<'a> VmapModels<'a> {
    pub fn new(base: &Path, read_file: &'a dyn Fn(&str) -> Option<Vec<u8>>) -> Self {
        VmapModels { base: base.to_path_buf(), read_file, new_vmo: BTreeMap::new(), missing: vec![], cache: HashMap::new() }
    }
}

impl Models for VmapModels<'_> {
    fn collision(&mut self, name: &str, path: &str) -> Option<Vec<V3>> {
        if let Some(c) = self.cache.get(name) {
            return c.clone();
        }
        let vmo = self.base.join(vmo_file(name));
        let got = if let Ok(b) = std::fs::read(&vmo) {
            vmo_vertices(&b).ok().filter(|v| !v.is_empty())
        } else if name.trim_end_matches('\0').ends_with(".m2") {
            let m2 = (self.read_file)(&format!("{}.m2", &path[..path.rfind('.').unwrap_or(path.len())]));
            match m2.as_deref().and_then(m2_vmo) {
                Some(v) => {
                    let verts = vmo_vertices(&v).ok();
                    self.new_vmo.insert(vmo_file(name), v);
                    verts
                }
                None => None,
            }
        } else {
            // a building no spawn on the realm uses: its collision isn't in the vmaps
            if (self.read_file)(path).is_some() {
                self.missing.push(name.trim_end_matches('\0').to_string());
            }
            None
        };
        self.cache.insert(name.to_string(), got.clone());
        got
    }
    fn read(&mut self, path: &str) -> Option<Vec<u8>> {
        (self.read_file)(path)
    }
}

/// Rewrite map `map`'s vmaps for `tiles` (ADT x, y, the tile's final bytes): read from `base` (the
/// realm's vmaps as extracted), written into `out` (may be the same folder): the map's tree, each
/// edited tile, and `.vmo`s for models the realm's vmaps lack.
pub fn rebuild(base: &Path, out: &Path, map: u32, tiles: &[((u32, u32), Vec<u8>)], read_file: &dyn Fn(&str) -> Option<Vec<u8>>) -> Result<Rebuilt> {
    let tree_path = base.join(tree_name(map));
    let tree = Tree::parse(&std::fs::read(&tree_path).with_context(|| format!("no {} in the server's vmaps", tree_path.display()))?)?;
    let n = tree.bih.objects.len();
    // every spawn on the map, by index (from all its tiles)
    let mut all: Vec<Option<Spawn>> = vec![None; n];
    let prefix = format!("{map:03}_");
    let mut max_id = 0u32;
    for e in std::fs::read_dir(base)?.flatten() {
        let fname = e.file_name().to_string_lossy().to_string();
        if !(fname.starts_with(&prefix) && fname.ends_with(".vmtile")) {
            continue;
        }
        for (s, i) in parse_tile(&std::fs::read(e.path())?).with_context(|| fname.clone())? {
            max_id = max_id.max(s.id);
            if let Some(slot) = all.get_mut(i as usize) {
                if slot.is_none() {
                    *slot = Some(s);
                }
            }
        }
    }
    let mut models = VmapModels::new(base, read_file);
    let mut done = Rebuilt::default();
    let mut new_tiles: Vec<(String, Vec<(Spawn, u32)>)> = vec![];
    let mut added: Vec<Spawn> = vec![];
    for ((a, b), adt) in tiles {
        let name = tile_name(map, *a, *b);
        let old = std::fs::read(base.join(&name)).ok().map(|b| parse_tile(&b)).transpose()?.unwrap_or_default();
        let mut list: Vec<(Spawn, u32)> = vec![];
        for s in tile_spawns(adt, &mut models) {
            if list.iter().any(|(o, _)| o.same_place(&s)) {
                continue;
            }
            if let Some((o, i)) = old.iter().find(|(o, _)| o.same_place(&s)) {
                list.push((o.clone(), *i));
                done.kept += 1;
            } else if let Some(k) = added.iter().position(|o| o.same_place(&s)) {
                // a building on two edited tiles: one spawn
                list.push((added[k].clone(), (n + k) as u32));
            } else {
                let mut s = s;
                max_id += 1;
                s.id = max_id;
                list.push((s.clone(), (n + added.len()) as u32));
                added.push(s);
                done.added += 1;
            }
        }
        done.removed += old.iter().filter(|(_, i)| !list.iter().any(|(_, j)| j == i)).count();
        new_tiles.push((name, list));
    }
    // the tree over the longer list (spawns no tile names any more keep their place, unused)
    let mut bounds: Vec<(V3, V3)> = Vec::with_capacity(n + added.len());
    let fallback = (tree.bih.lo, tree.bih.lo);
    for s in &all {
        bounds.push(s.as_ref().and_then(|s| s.bound).unwrap_or(fallback));
    }
    for s in &added {
        bounds.push(s.bound.unwrap_or(fallback));
    }
    std::fs::create_dir_all(out)?;
    if !added.is_empty() {
        let t = Tree { tiled: tree.tiled, bih: Bih::build(&bounds, 3), gobj: tree.gobj.clone() };
        crate::testbed::write_own(&out.join(tree_name(map)), &t.write())?;
        done.files.push(tree_name(map));
    }
    for (name, list) in &new_tiles {
        crate::testbed::write_own(&out.join(name), &write_tile(list))?;
        done.files.push(name.clone());
    }
    for (name, b) in &models.new_vmo {
        crate::testbed::write_own(&out.join(name), b)?;
        done.files.push(name.clone());
    }
    models.missing.sort();
    models.missing.dedup();
    for m in &models.missing {
        done.warnings.push(format!("{m}: no building of this kind stands anywhere on the realm, so its walls aren't in the server's vmaps; re-extract them (vmap_extractor) for its collision."));
    }
    Ok(done)
}

/// A test model: a unit box (x, y -0.5..0.5, z 0..1) whose collision mesh is the box.
#[cfg(test)]
pub(crate) fn box_m2() -> Vec<u8> {
    let mut m = vec![0u8; 300];
    m[0..4].copy_from_slice(b"MD20");
    let verts: Vec<[f32; 3]> = (0..8).map(|i| [(i & 1) as f32 - 0.5, ((i >> 1) & 1) as f32 - 0.5, ((i >> 2) & 1) as f32]).collect();
    let tris: Vec<u16> = vec![0, 1, 2, 1, 3, 2, 4, 6, 5, 5, 6, 7, 0, 4, 1, 1, 4, 5, 2, 3, 6, 3, 7, 6, 0, 2, 4, 2, 6, 4, 1, 5, 3, 3, 5, 7];
    let ov = m.len();
    for v in &verts {
        for c in v {
            m.extend_from_slice(&c.to_le_bytes());
        }
    }
    let ot = m.len();
    for t in &tris {
        m.extend_from_slice(&t.to_le_bytes());
    }
    m[236..240].copy_from_slice(&(tris.len() as u32).to_le_bytes());
    m[240..244].copy_from_slice(&(ot as u32).to_le_bytes());
    m[244..248].copy_from_slice(&8u32.to_le_bytes());
    m[248..252].copy_from_slice(&(ov as u32).to_le_bytes());
    m
}

/// A test realm's vmaps for map 0: one stock rock on tile 31_48 (its tree, tile and mesh).
#[cfg(test)]
pub(crate) fn stock_vmaps(dir: &Path) {
    std::fs::create_dir_all(dir).unwrap();
    let vmo = m2_vmo(&box_m2()).unwrap();
    let rock = Spawn { flags: MOD_M2 | MOD_HAS_BOUND, adt_id: 0, id: 1, pos: [25700.0, 16700.0, 10.0], rot: [0.0; 3], scale: 2.0, bound: None, name: "Rock.m2".into() };
    let rock = Spawn { bound: Some(m2_bound(&vmo_vertices(&vmo).unwrap(), rock.pos, rock.rot, rock.scale)), ..rock };
    let tree = Tree { tiled: true, bih: Bih::build(&[rock.bound.unwrap()], 3), gobj: vec![] };
    std::fs::write(dir.join("000.vmtree"), tree.write()).unwrap();
    std::fs::write(dir.join("000_31_48.vmtile"), write_tile(&[(rock, 0)])).unwrap();
    std::fs::write(dir.join("Rock.m2.vmo"), vmo).unwrap();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn real() -> Option<PathBuf> {
        std::env::var_os("FORGE_VMAPS").map(PathBuf::from).filter(|p| p.join("000.vmtree").is_file())
    }

    #[test]
    fn names_like_the_extractor() {
        assert_eq!(model_name("World\\Azeroth\\Elwynn\\PassiveDoodads\\Trees\\ElwynnTreeCanopy01.mdx"), "Elwynntreecanopy01.m2");
        assert_eq!(model_name("World\\wmo\\Azeroth\\Buildings\\Stormwind\\NSabbey.wmo"), "Nsabbey.wmo");
        assert_eq!(model_name("World\\Generic\\Human\\Passive Doodads\\Lampposts\\GeneralLamppost01.MDX"), "Generallamppost01.m2");
        assert_eq!(model_name("x\\my barn.m2"), "My_Barn.m2");
    }

    #[test]
    fn a_tree_over_boxes_finds_them_all() {
        let mut bs = vec![];
        for i in 0..200 {
            let x = (i * 37 % 101) as f32 * 3.0;
            let y = (i * 11 % 53) as f32 * 2.0;
            bs.push(([x, y, 0.0], [x + 2.0, y + 1.0, 4.0]));
        }
        let t = Bih::build(&bs, 3);
        let mut seen = t.objects.clone();
        seen.sort();
        assert_eq!(seen, (0..200).collect::<Vec<u32>>());
        assert!(t.tree.len() >= 3 && t.tree.len() % 3 == 0);
    }

    #[test]
    fn m2_collision_becomes_a_vmo() {
        // a box of 8 vertices, 12 triangles
        let mut m = vec![0u8; 300];
        m[0..4].copy_from_slice(b"MD20");
        let verts: Vec<[f32; 3]> = (0..8).map(|i| [(i & 1) as f32, ((i >> 1) & 1) as f32, ((i >> 2) & 1) as f32]).collect();
        let tris: Vec<u16> = vec![0, 1, 2, 1, 3, 2, 4, 6, 5, 5, 6, 7, 0, 4, 1, 1, 4, 5, 2, 3, 6, 3, 7, 6, 0, 2, 4, 2, 6, 4, 1, 5, 3, 3, 5, 7];
        let ov = m.len();
        for v in &verts {
            for c in v {
                m.extend_from_slice(&c.to_le_bytes());
            }
        }
        let ot = m.len();
        for t in &tris {
            m.extend_from_slice(&t.to_le_bytes());
        }
        m[236..240].copy_from_slice(&(tris.len() as u32).to_le_bytes());
        m[240..244].copy_from_slice(&(ot as u32).to_le_bytes());
        m[244..248].copy_from_slice(&8u32.to_le_bytes());
        m[248..252].copy_from_slice(&(ov as u32).to_le_bytes());
        let vmo = m2_vmo(&m).unwrap();
        assert_eq!(vmo_vertices(&vmo).unwrap(), verts);
        let mut none = m.clone();
        none[236..240].copy_from_slice(&0u32.to_le_bytes());
        assert!(m2_vmo(&none).is_none(), "no bounding triangles: no collision");
    }

    /// FORGE_VMAPS=<vmaps made by vmap_assembler>: the tree rebuilt from the tiles' own spawns is
    /// the assembler's, byte for byte.
    #[test]
    #[ignore]
    fn rebuild_matches_the_assembler() {
        let Some(dir) = real() else { return };
        for map in [0u32, 1] {
            let Ok(b) = std::fs::read(dir.join(tree_name(map))) else { continue };
            let tree = Tree::parse(&b).unwrap();
            let n = tree.bih.objects.len();
            let mut all: Vec<Option<(V3, V3)>> = vec![None; n];
            for e in std::fs::read_dir(&dir).unwrap().flatten() {
                let f = e.file_name().to_string_lossy().to_string();
                if f.starts_with(&format!("{map:03}_")) && f.ends_with(".vmtile") {
                    for (s, i) in parse_tile(&std::fs::read(e.path()).unwrap()).unwrap() {
                        all[i as usize] = s.bound;
                    }
                }
            }
            let bounds: Vec<(V3, V3)> = all.into_iter().map(|b| b.expect("every spawn is on a tile")).collect();
            let again = Tree { tiled: tree.tiled, bih: Bih::build(&bounds, 3), gobj: tree.gobj.clone() }.write();
            assert_eq!(again, b, "map {map}: tree differs");
        }
    }

    /// FORGE_VMAPS + FORGE_GAME (the client those vmaps were extracted from): every tile's spawns
    /// worked out from its ADT are the ones the extractor and assembler wrote.
    #[test]
    #[ignore]
    fn tile_spawns_match_the_extractor() {
        let (Some(dir), Some(game)) = (real(), std::env::var_os("FORGE_GAME")) else { return };
        let g = crate::vfs::GameData::open(PathBuf::from(game)).unwrap();
        let read = |p: &str| g.read(p).ok();
        let mut models = VmapModels::new(&dir, &read);
        let (mut tiles, mut total) = (0, 0);
        for e in std::fs::read_dir(&dir).unwrap().flatten() {
            let f = e.file_name().to_string_lossy().to_string();
            let Some(rest) = f.strip_prefix("000_").and_then(|r| r.strip_suffix(".vmtile")) else { continue };
            let (a, b) = rest.split_once('_').unwrap();
            let adt = g.read(&crate::adt::tile_path("Azeroth", a.parse().unwrap(), b.parse().unwrap())).unwrap();
            let official: Vec<Spawn> = parse_tile(&std::fs::read(e.path()).unwrap()).unwrap().into_iter().map(|x| x.0).collect();
            let mine = tile_spawns(&adt, &mut models);
            let mut left = official.clone();
            for s in &mine {
                let k = left.iter().position(|o| {
                    let near = |x: V3, y: V3| (0..3).all(|i| (x[i] - y[i]).abs() <= 0.002 * (1.0 + x[i].abs().max(y[i].abs()) / 1000.0));
                    o.name == s.name && o.flags == s.flags && near(o.pos, s.pos) && near(o.rot, s.rot) && (o.scale - s.scale).abs() < 1e-5
                        && near(o.bound.unwrap().0, s.bound.unwrap().0) && near(o.bound.unwrap().1, s.bound.unwrap().1)
                });
                match k {
                    Some(k) => {
                        left.remove(k);
                    }
                    None => panic!("{f}: Forge has {s:?}, the extractor doesn't"),
                }
            }
            assert!(left.is_empty(), "{f}: the extractor has {} more, first {:?}", left.len(), left.first());
            tiles += 1;
            total += mine.len();
        }
        eprintln!("{tiles} tiles, {total} spawns, all as the extractor's");
        assert!(tiles > 0);
    }

    /// FORGE_VMAPS + FORGE_GAME + FORGE_VMAP_OUT: Azeroth 32_48 with an inn and a pack's own box
    /// added, its vmaps rewritten into FORGE_VMAP_OUT (a copy of FORGE_VMAPS); prints the world
    /// coordinates of a line through each, for the server's own loader to test (scratch harness).
    #[test]
    #[ignore]
    fn placed_buildings_get_collision() {
        let (Some(dir), Some(game), Some(out)) = (real(), std::env::var_os("FORGE_GAME"), std::env::var_os("FORGE_VMAP_OUT")) else { return };
        let out = PathBuf::from(out);
        let g = crate::vfs::GameData::open(PathBuf::from(game)).unwrap();
        let path = crate::adt::tile_path("Azeroth", 32, 48);
        let mut t = crate::adt::Adt::parse(&g.read(&path).unwrap()).unwrap();
        let tile = (32, 48);
        let t0 = crate::adt::TILE as f32;
        let (ix, iz) = (32.5 * t0, 48.3 * t0);
        let (bx, bz) = (32.7 * t0, 48.7 * t0);
        let ih = t.height_at(tile, ix as f64, iz as f64).unwrap() as f32;
        let bh = t.height_at(tile, bx as f64, bz as f64).unwrap() as f32;
        let inn = "World\\wmo\\Azeroth\\Buildings\\GoldshireInn\\GoldshireInn.wmo";
        let r = 60.0;
        t.add_doodads(tile, &[
            crate::adt::Doodad { model: inn.into(), uid: 9_000_001, pos: [ix, ih, iz], rot: [0.0, 30.0, 0.0], scale: 1024, flags: 0, extents: Some([ix - r, ih - 20.0, iz - r, ix + r, ih + 40.0, iz + r]), set: 0 },
            crate::adt::Doodad { model: "World\\Forge\\Test\\ForgeBox.m2".into(), uid: 9_000_002, pos: [bx, bh, bz], rot: [0.0, 0.0, 0.0], scale: 8 * 1024, flags: 0, extents: None, set: 0 },
        ]).unwrap();
        // the pack's own model: a unit box with a collision mesh
        let mut m = vec![0u8; 300];
        m[0..4].copy_from_slice(b"MD20");
        let verts: Vec<[f32; 3]> = (0..8).map(|i| [(i & 1) as f32 - 0.5, ((i >> 1) & 1) as f32 - 0.5, ((i >> 2) & 1) as f32]).collect();
        let tris: Vec<u16> = vec![0, 1, 2, 1, 3, 2, 4, 6, 5, 5, 6, 7, 0, 4, 1, 1, 4, 5, 2, 3, 6, 3, 7, 6, 0, 2, 4, 2, 6, 4, 1, 5, 3, 3, 5, 7];
        let ov = m.len();
        for v in &verts { for c in v { m.extend_from_slice(&c.to_le_bytes()); } }
        let ot = m.len();
        for x in &tris { m.extend_from_slice(&x.to_le_bytes()); }
        m[236..240].copy_from_slice(&(tris.len() as u32).to_le_bytes());
        m[240..244].copy_from_slice(&(ot as u32).to_le_bytes());
        m[244..248].copy_from_slice(&8u32.to_le_bytes());
        m[248..252].copy_from_slice(&(ov as u32).to_le_bytes());
        let read = |p: &str| if p.to_ascii_lowercase().ends_with("forgebox.m2") { Some(m.clone()) } else { g.read(p).ok() };
        let done = rebuild(&dir, &out, 0, &[((32, 48), t.write())], &read).unwrap();
        eprintln!("{done:?}");
        assert!(done.added >= 2 && done.files.iter().any(|f| f == "Forgebox.m2.vmo"));
        // world coordinates (the server's): x = mid - file z, y = mid - file x
        let w = |fx: f32, fz: f32| (MAP_MID - fz, MAP_MID - fx);
        let (a, b) = (w(ix - 45.0, iz), w(ix + 45.0, iz));
        let (c, d) = (w(bx - 10.0, bz), w(bx + 10.0, bz));
        std::fs::write(out.join("lines.txt"), format!("{} {} {} {} {} {}\n{} {} {} {} {} {}\n", a.0, a.1, ih + 3.0, b.0, b.1, ih + 3.0, c.0, c.1, bh + 2.0, d.0, d.1, bh + 2.0)).unwrap();
    }
}
