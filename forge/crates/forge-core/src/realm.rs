//! Realm build (plan §5.3, Phase 2): a realm owner's list of approved packs becomes what the
//! realm actually runs, the way `sync_patchz.py` + `apply_models_dbc.py` do it for Classic+ today,
//! generalised to any number of packs.
//!
//! ```toml
//! # realm.toml
//! [realm]
//! id = "classicplus"
//! name = "Classic+"
//! patch = "patch-Z.MPQ"               # the one realm patch the clients load
//! base_patch = "../patch-Z.MPQ"       # optional: the realm's own patch the packs go on top of
//! server_dbc = "../server/dbc"        # optional: the server's DBC folder (packs' rows merged in)
//! server_vmaps = "../server/vmaps"    # optional: the server's vmaps (placed buildings get collision)
//!
//! [[pack]]
//! file = "packs/emberwing-mounts-1.2.0.ovpack"
//! key = "b8a43e31…"                   # optional: the creator's pinned key
//! ```
//!
//! `forge realm build realm.toml` verifies every pack, orders them by `depends`, refuses
//! conflicts (two packs shipping one file differently, overlapping ID ranges, one DBC record
//! from two packs), and writes into `<realm dir>/build/`:
//!
//! ```text
//! client/<patch>                  base patch files + every pack's files + DBCs with all rows merged
//! client/manifest.json            path -> sha256, size, the pack it came from
//! cas/<aa>/<sha256>               every client file by content (immutable URLs for streaming)
//! server/dbc/*.dbc                the server's DBCs with the packs' rows (when server_dbc is set)
//! server/sql/install.sql          the packs' SQL in dependency order
//! server/sql/rollback.sql         ... and back, in reverse
//! server/maps/MMMYYXX.map         the server's ground for every tile packs reshaped, holed,
//!                                 watered or re-zoned (CMaNGOS's extractor format)
//! server/vmaps/                   the server's collision for the tiles packs place or hide
//!                                 doodads and buildings on (when server_vmaps is set)
//! server/movemaps.txt             the MoveMapGen runs that rebuild those tiles' movement maps
//!                                 (and in the patch: new minimap pictures for those tiles)
//! realm-report.json               packs, versions, build hashes, keys, counts, warnings
//! ```

use crate::data::{self, Dbc};
use crate::publish;
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap};
use std::io::Read;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct RealmFile {
    pub realm: RealmSpec,
    #[serde(default, rename = "pack")]
    pub packs: Vec<PackRef>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct RealmSpec {
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default = "default_patch")]
    pub patch: String,
    pub base_patch: Option<PathBuf>,
    pub server_dbc: Option<PathBuf>,
    /// The realm's 1.12 game folder: the terrain tiles packs place doodads on.
    pub game: Option<PathBuf>,
    /// The server's maps folder: Forge reads the .map format version its server uses from it.
    pub server_maps: Option<PathBuf>,
    /// The server's vmaps folder (as vmap_extractor + vmap_assembler made it): with it, the
    /// buildings and props packs place get the server's collision in server/vmaps.
    #[serde(default)]
    pub server_vmaps: Option<PathBuf>,
    /// Pack ids the realm provides itself (its own content), so `depends` on them are met.
    #[serde(default)]
    pub provides: Vec<String>,
}

fn default_patch() -> String {
    "patch-Z.MPQ".into()
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct PackRef {
    pub file: PathBuf,
    pub key: Option<String>,
}

/// One verified pack, read into memory.
pub struct Pack {
    pub sig: publish::Signature,
    pub manifest: crate::project::Manifest,
    pub files: BTreeMap<String, Vec<u8>>,
}

impl Pack {
    pub fn open(path: &Path, key: Option<&str>) -> Result<Pack> {
        let sig = publish::verify(path).with_context(|| format!("{}", path.display()))?;
        if let Some(k) = key {
            if !k.eq_ignore_ascii_case(&sig.public_key) {
                bail!("{}: signed with a different key than the one this realm pinned", path.display());
            }
        }
        let mut z = zip::ZipArchive::new(std::fs::File::open(path)?)?;
        let mut files = BTreeMap::new();
        for i in 0..z.len() {
            let mut f = z.by_index(i)?;
            let mut b = vec![];
            f.read_to_end(&mut b)?;
            files.insert(f.name().to_string(), b);
        }
        let manifest: crate::project::Manifest =
            toml::from_str(std::str::from_utf8(files.get("forge.toml").context("no forge.toml in the pack")?)?)?;
        Ok(Pack { sig, manifest, files })
    }

    fn id(&self) -> &str {
        &self.manifest.pack.id
    }

    /// The client files inside the pack's MPQ.
    fn client_files(&self, scratch: &Path) -> Result<Vec<(String, Vec<u8>)>> {
        let Some((name, bytes)) = self.files.iter().find(|(n, _)| n.to_ascii_lowercase().ends_with(".mpq") && !n.contains('/')) else {
            return Ok(vec![]);
        };
        let tmp = scratch.join(format!("{}-{name}", self.id()));
        std::fs::write(&tmp, bytes)?;
        let out = read_mpq(&tmp)?;
        let _ = std::fs::remove_file(&tmp);
        Ok(out)
    }

    fn ids(&self) -> BTreeMap<String, crate::ids::Range> {
        self.files
            .get("report.json")
            .and_then(|b| serde_json::from_slice::<Value>(b).ok())
            .and_then(|r| serde_json::from_value(r["ids"].clone()).ok())
            .unwrap_or_default()
    }

    /// DBC row deltas: table -> rows.
    fn dbc_rows(&self) -> Result<BTreeMap<String, Vec<toml::Table>>> {
        let mut out = BTreeMap::new();
        for (n, b) in &self.files {
            if let Some(t) = n.strip_prefix("data/dbc/").and_then(|x| x.strip_suffix(".json")) {
                let v: Value = serde_json::from_slice(b)?;
                let rows: Vec<toml::Table> = v["rows"]
                    .as_array()
                    .context("rows")?
                    .iter()
                    .map(|r| toml::Value::try_from(r).map_err(anyhow::Error::from).and_then(|x| x.as_table().cloned().context("a row")))
                    .collect::<Result<_>>()?;
                if data::dbc_schema().contains_key(t) {
                    out.insert(t.to_string(), rows);
                }
            }
        }
        Ok(out)
    }

    fn sql(&self, which: &str) -> String {
        self.files.get(&format!("server/sql/{which}.sql")).map(|b| String::from_utf8_lossy(b).to_string()).unwrap_or_default()
    }
}

/// Every file in an MPQ (by its listfile).
pub fn read_mpq(path: &Path) -> Result<Vec<(String, Vec<u8>)>> {
    let mut a = wow_mpq::Archive::open(path).with_context(|| format!("can't open {}", path.display()))?;
    let names: Vec<String> = a.list()?.into_iter().map(|e| e.name).filter(|n| !n.starts_with('(')).collect();
    let mut out = vec![];
    for n in names {
        let b = a.read_file(&n).with_context(|| format!("{}: {n}", path.display()))?;
        out.push((n, b));
    }
    Ok(out)
}

#[derive(Debug, Default, Serialize)]
pub struct Report {
    pub realm: String,
    pub patch: String,
    pub packs: Vec<Value>,
    pub client_files: usize,
    pub client_bytes: u64,
    pub dbc_tables: Vec<String>,
    pub server_dbc: Vec<String>,
    /// Terrain tiles packs placed doodads on or edited.
    pub tiles: Vec<String>,
    /// Server map tiles (server/maps) rebuilt from the edited terrain.
    pub server_maps: Vec<String>,
    /// Minimap pictures baked for the edited terrain.
    pub minimaps: Vec<String>,
    /// Collision files (server/vmaps) rewritten for placed doodads and buildings.
    #[serde(default)]
    pub server_vmaps: Vec<String>,
    pub warnings: Vec<String>,
}

/// Dependency order: a pack after the packs it depends on (`id` or `id <constraint>`).
fn order(packs: &[Pack], provides: &[String]) -> Result<Vec<usize>> {
    let by_id: HashMap<&str, usize> = packs.iter().enumerate().map(|(i, p)| (p.id(), i)).collect();
    let mut out = vec![];
    let mut state = vec![0u8; packs.len()]; // 0 new, 1 visiting, 2 done
    fn visit(i: usize, packs: &[Pack], by_id: &HashMap<&str, usize>, provides: &[String], state: &mut [u8], out: &mut Vec<usize>) -> Result<()> {
        match state[i] {
            2 => return Ok(()),
            1 => bail!("packs depend on each other in a circle (through {})", packs[i].id()),
            _ => {}
        }
        state[i] = 1;
        for d in &packs[i].manifest.depends {
            let dep = d.split_whitespace().next().unwrap_or("");
            match by_id.get(dep) {
                Some(&j) => visit(j, packs, by_id, provides, state, out)?,
                None if provides.iter().any(|p| p == dep) => {}
                None => bail!("{} needs {dep}, which this realm doesn't have", packs[i].id()),
            }
        }
        state[i] = 2;
        out.push(i);
        Ok(())
    }
    let mut idx: Vec<usize> = (0..packs.len()).collect();
    idx.sort_by(|a, b| packs[*a].id().cmp(packs[*b].id()));
    for i in idx {
        visit(i, packs, &by_id, provides, &mut state, &mut out)?;
    }
    Ok(out)
}

fn sha256(b: &[u8]) -> String {
    use sha2::Digest;
    hex::encode(sha2::Sha256::digest(b))
}

pub fn build(realm_toml: &Path) -> Result<Report> {
    let dir = realm_toml.parent().map(Path::to_path_buf).unwrap_or_else(|| PathBuf::from("."));
    let rf: RealmFile = toml::from_str(&std::fs::read_to_string(realm_toml)?).with_context(|| format!("{} isn't valid", realm_toml.display()))?;
    let r = &rf.realm;
    let mut patch_ok = r.patch.to_ascii_lowercase().starts_with("patch-") && r.patch.to_ascii_lowercase().ends_with(".mpq");
    patch_ok &= r.patch.len() == "patch-Z.MPQ".len();
    if !patch_ok {
        bail!("patch must be patch-?.MPQ (one character), as the client loads it");
    }
    // packs, verified, in dependency order
    let mut packs = vec![];
    for p in &rf.packs {
        packs.push(Pack::open(&dir.join(&p.file), p.key.as_deref())?);
    }
    {
        let mut seen = HashMap::new();
        for p in &packs {
            if let Some(prev) = seen.insert(p.id().to_string(), p.manifest.pack.version.clone()) {
                bail!("{} is listed twice ({prev} and {})", p.id(), p.manifest.pack.version);
            }
        }
    }
    let ord = order(&packs, &r.provides)?;
    let mut report = Report { realm: r.id.clone(), patch: r.patch.clone(), ..Default::default() };

    // ID ranges never overlap between packs
    let mut ranges: Vec<(String, String, u32, u32)> = vec![];
    for p in &packs {
        for (t, rg) in p.ids() {
            for (pid, pt, s, e) in &ranges {
                if pt == &t && rg.start < *e && *s < rg.end {
                    bail!("{} and {pid} both use {t} IDs {}..{}: one of them needs a new range", p.id(), rg.start.max(*s), rg.end.min(*e));
                }
            }
            ranges.push((p.id().to_string(), t, rg.start, rg.end));
        }
    }

    let out = dir.join("build");
    let _ = std::fs::remove_dir_all(&out);
    std::fs::create_dir_all(out.join("client"))?;

    // client files: the base patch, then each pack's files on top
    let mut files: BTreeMap<String, (String, Vec<u8>, String)> = BTreeMap::new(); // lower -> (path, bytes, from)
    if let Some(b) = &r.base_patch {
        for (n, bytes) in read_mpq(&dir.join(b))? {
            files.insert(n.to_ascii_lowercase(), (n, bytes, "base".into()));
        }
    }
    for &i in &ord {
        let p = &packs[i];
        for (n, bytes) in p.client_files(&out)? {
            let key = n.to_ascii_lowercase();
            if key.starts_with("dbfilesclient\\") {
                report.warnings.push(format!("{}: ignored {n} (DBC changes come from row deltas, not files)", p.id()));
                continue;
            }
            match files.get(&key) {
                Some((_, prev, from)) if from != "base" && prev != &bytes => bail!("{} and {from} both ship {n}, differently", p.id()),
                Some((_, _, from)) if from == "base" => report.warnings.push(format!("{} replaces the realm's own {n}", p.id())),
                _ => {}
            }
            files.insert(key, (n, bytes, p.id().to_string()));
        }
    }

    // DBCs: each table's rows from every pack, merged once onto the realm's copy
    let mut rows_by_table: BTreeMap<String, Vec<(String, toml::Table)>> = BTreeMap::new();
    for &i in &ord {
        for (t, rows) in packs[i].dbc_rows()? {
            for row in rows {
                rows_by_table.entry(t.clone()).or_default().push((packs[i].id().to_string(), row));
            }
        }
    }
    for (t, rows) in &rows_by_table {
        let mut owner: HashMap<i64, &str> = HashMap::new();
        for (pid, row) in rows {
            let id = row.get("ID").and_then(toml::Value::as_integer).with_context(|| format!("{pid}: a {t} row without ID"))?;
            if let Some(o) = owner.insert(id, pid) {
                if o != pid {
                    bail!("{o} and {pid} both change {t} {id}");
                }
            }
        }
        let plain: Vec<toml::Table> = rows.iter().map(|(_, r)| r.clone()).collect();
        let client_path = format!("DBFilesClient\\{t}.dbc");
        let base = match files.get(&client_path.to_ascii_lowercase()) {
            Some((_, b, _)) => Dbc::parse(b)?,
            None => match &r.server_dbc {
                Some(sd) => Dbc::parse(&std::fs::read(find_ci(&dir.join(sd), &format!("{t}.dbc")).with_context(|| format!("no {t}.dbc in the base patch or {}", sd.display()))?)?)?,
                None => bail!("packs add {t} rows, but the base patch has no {t}.dbc and server_dbc isn't set"),
            },
        };
        let merged = data::merge(t, &base, &plain)?;
        files.insert(client_path.to_ascii_lowercase(), (client_path, merged.write(), "merged".into()));
        report.dbc_tables.push(t.clone());
        // the server's copy gets the same rows (on top of its own table, which may differ from the client's)
        if let Some(sd) = &r.server_dbc {
            if let Some(src) = find_ci(&dir.join(sd), &format!("{t}.dbc")) {
                let m = data::merge(t, &Dbc::parse(&std::fs::read(&src)?)?, &plain)?;
                let dst = out.join("server/dbc").join(src.file_name().unwrap());
                std::fs::create_dir_all(dst.parent().unwrap())?;
                std::fs::write(dst, m.write())?;
                report.server_dbc.push(t.clone());
            }
        }
    }

    // map placements: every pack's doodads, added to the realm's own tiles (base patch first)
    let mut placed: BTreeMap<(String, (i32, i32)), Vec<crate::adt::Doodad>> = BTreeMap::new();
    let mut uids: HashMap<u32, String> = HashMap::new();
    for &i in &ord {
        for (n, b) in &packs[i].files {
            if !(n.starts_with("data/world/") && n.ends_with(".json")) {
                continue;
            }
            let v: Value = serde_json::from_slice(b)?;
            let map = v["map"].as_str().context("map")?.to_string();
            for e in v["doodads"].as_array().cloned().unwrap_or_default() {
                let d: crate::adt::Doodad = serde_json::from_value(e["doodad"].clone())?;
                let t = (e["tile"][0].as_i64().unwrap_or(0) as i32, e["tile"][1].as_i64().unwrap_or(0) as i32);
                if let Some(o) = uids.insert(d.uid, packs[i].id().to_string()) {
                    // (a building over several tiles is in each of them with its one uid)
                    if o != packs[i].id() {
                        bail!("{o} and {} both place doodad uid {}", packs[i].id(), d.uid);
                    }
                }
                placed.entry((map.clone(), t)).or_default().push(d);
            }
        }
    }
    // terrain: one pack per reshaped tile (a reshaped tile is that pack's)
    let mut reshaped: BTreeMap<(String, (i32, i32)), (crate::world::TileEdit, String)> = BTreeMap::new();
    for &i in &ord {
        for (n, b) in &packs[i].files {
            let Some(rest) = n.strip_prefix("data/terrain/") else { continue };
            let (rest, kind) = match (rest.strip_suffix(".hd"), rest.strip_suffix(".chunks.json"), rest.strip_suffix(".hidden.json")) {
                (Some(x), _, _) => (x, 0),
                (_, Some(x), _) => (x, 1),
                (_, _, Some(x)) => (x, 2),
                _ => continue,
            };
            let Some((map, ab)) = rest.split_once('/') else { continue };
            let Some((a, bb)) = ab.split_once('_') else { continue };
            let key = (map.to_string(), (a.parse::<i32>()?, bb.parse::<i32>()?));
            let pid = packs[i].id().to_string();
            let entry = reshaped.entry(key).or_insert_with(|| (Default::default(), pid.clone()));
            if entry.1 != pid {
                bail!("{} and {pid} both reshape {map} tile {ab}", entry.1);
            }
            match kind {
                0 => entry.0.heights = Some(crate::world::decode_delta(b)?),
                1 => entry.0.chunks = serde_json::from_slice(b)?,
                _ => entry.0.hidden = serde_json::from_slice(b)?,
            }
        }
    }
    let mut server_maps: Option<(HashMap<u32, u16>, [u8; 4])> = None;
    let mut movemaps: Vec<String> = vec![];
    let mut trs: Option<String> = None;
    // tiles packs ship whole (a new map's): the server and the minimap need them too
    for (key, (path, _, from)) in &files {
        if from == "base" || !key.starts_with("world\\maps\\") || !key.ends_with(".adt") {
            continue;
        }
        let parts: Vec<&str> = path.split('\\').collect();
        if parts.len() != 4 {
            continue;
        }
        if let Some((a, b)) = tile_numbers(path) {
            reshaped.entry((parts[2].to_string(), (a, b))).or_insert_with(|| (Default::default(), from.clone()));
        }
    }
    if !placed.is_empty() || !reshaped.is_empty() {
        let game = r.game.as_ref().map(|g| crate::vfs::GameData::open(dir.join(g))).transpose()?;
        let mut maps: BTreeMap<String, (BTreeMap<(i32, i32), crate::world::TileEdit>, BTreeMap<(i32, i32), Vec<crate::adt::Doodad>>)> = BTreeMap::new();
        for ((map, t), (d, _)) in reshaped {
            maps.entry(map).or_default().0.insert(t, d);
        }
        for ((map, t), ds) in placed {
            maps.entry(map).or_default().1.insert(t, ds);
        }
        for (map, (deltas, doodads)) in &maps {
            let read = |path: &str| -> Result<Vec<u8>> {
                match files.get(&path.to_ascii_lowercase()) {
                    Some((_, b, _)) => Ok(b.clone()),
                    None => game.as_ref().with_context(|| format!("packs edit {path}: set game in realm.toml to the realm's game folder"))?.read(path),
                }
            };
            let edited: Vec<String> = deltas.keys().map(|&(a, b)| crate::adt::tile_path(map, a, b).to_ascii_lowercase()).collect();
            let map_id = crate::world::MAPS.iter().find(|(_, n)| n.eq_ignore_ascii_case(map)).map(|x| x.0).or_else(|| {
                // a map a pack adds: its Map row
                rows_by_table.get("Map").and_then(|rows| rows.iter().find(|(_, r)| r.get("Directory").and_then(toml::Value::as_str).is_some_and(|d| d.eq_ignore_ascii_case(map)))).and_then(|(_, r)| r.get("ID").and_then(toml::Value::as_integer)).map(|i| i as u32)
            });
            let edited_tiles = crate::world::edit_tiles(map, deltas, doodads, &read)?;
            let mut pictures = vec![];
            trs = crate::world::minimaps_for(map, deltas, &edited_tiles, &read, trs.take(), &mut pictures)?;
            for (path, bytes) in pictures {
                report.minimaps.push(path.clone());
                files.insert(path.to_ascii_lowercase(), (path, bytes, "merged".into()));
            }
            // the server's collision for the tiles whose models changed
            let coll: Vec<((u32, u32), Vec<u8>)> = edited_tiles
                .iter()
                .filter_map(|(path, bytes)| {
                    let t = tile_numbers(path)?;
                    let models = doodads.contains_key(&t) || deltas.get(&t).is_some_and(|d| !d.hidden.is_empty());
                    (models && t.0 >= 0 && t.1 >= 0).then(|| ((t.0 as u32, t.1 as u32), bytes.clone()))
                })
                .collect();
            if !coll.is_empty() {
                match (&r.server_vmaps, map_id) {
                    (Some(v), Some(id)) => {
                        let read_file = |path: &str| -> Option<Vec<u8>> {
                            match files.get(&path.to_ascii_lowercase()) {
                                Some((_, b, _)) => Some(b.clone()),
                                None => game.as_ref().and_then(|g| g.read(path).ok()),
                            }
                        };
                        let done = crate::vmap::rebuild(&dir.join(v), &out.join("server/vmaps"), id, &coll, &read_file).with_context(|| format!("collision for {map}"))?;
                        report.warnings.extend(done.warnings);
                        report.server_vmaps.extend(done.files);
                        for (a, b) in coll.iter().map(|x| x.0) {
                            movemaps.push(format!("MoveMapGen {id} --tile {a},{b} --workdir <the server's data folder> --silent"));
                        }
                    }
                    (None, _) => report.warnings.push(format!(
                        "Packs place or hide doodads and buildings on {} {map} tile(s): set server_vmaps in realm.toml to the server's vmaps folder, and Forge writes their collision (server/vmaps); until then players walk through them.",
                        coll.len()
                    )),
                    (Some(_), None) => report.warnings.push(format!("{map}: not a map Forge knows the id of, so its collision isn't written")),
                }
            }
            for (path, bytes) in edited_tiles {
                // the server's ground for the tiles whose terrain changed
                if edited.contains(&path.to_ascii_lowercase()) {
                    let id = map_id.with_context(|| format!("{map}: not a map Forge knows the id of"))?;
                    let (a, b) = tile_numbers(&path).context("tile name")?;
                    if server_maps.is_none() {
                        server_maps = Some(server_map_inputs(r, &dir, &files, game.as_ref())?);
                    }
                    let (flags, version) = server_maps.as_ref().unwrap();
                    let m = crate::gridmap::convert(&crate::adt::Adt::parse(&bytes)?, &|id| flags.get(&id).copied(), *version)?;
                    let name = crate::gridmap::file_name(id, a, b);
                    std::fs::create_dir_all(out.join("server/maps"))?;
                    std::fs::write(out.join("server/maps").join(&name), m)?;
                    movemaps.push(format!("MoveMapGen {id} --tile {a},{b} --workdir <the server's data folder> --silent"));
                    report.server_maps.push(name);
                }
                files.insert(path.to_ascii_lowercase(), (path.clone(), bytes, "merged".into()));
                report.tiles.push(path);
            }
        }
        if let Some(t) = trs.take() {
            let path = crate::minimap::TRS.to_string();
            files.insert(path.to_ascii_lowercase(), (path, t.into_bytes(), "merged".into()));
        } else if !report.server_maps.is_empty() {
            report.warnings.push("No minimap translation table (md5translate.trs) in the realm's patch or game: the edited tiles keep their old minimap pictures.".into());
        }
        movemaps.sort();
        movemaps.dedup();
        if !movemaps.is_empty() {
            let mut txt = String::from("# Movement maps for the tiles packs edited (after copying server/maps and server/vmaps into the server's folders).\n# Run from the server's tools folder; each takes a minute or so.\n");
            for m in &movemaps {
                txt.push_str(m);
                txt.push('\n');
            }
            std::fs::create_dir_all(out.join("server"))?;
            std::fs::write(out.join("server/movemaps.txt"), txt)?;
            if !report.server_maps.is_empty() {
                report.warnings.push(format!(
                    "{} server map tile(s) rebuilt in server/maps: copy them into the server's maps folder, then rebuild their movement maps (server/movemaps.txt)",
                    report.server_maps.len()
                ));
            }
        }
        if !report.server_vmaps.is_empty() {
            report.warnings.push(format!(
                "{} collision file(s) rewritten in server/vmaps: copy them into the server's vmaps folder (and rebuild those tiles' movement maps, server/movemaps.txt)",
                report.server_vmaps.len()
            ));
        }
    }

    // the patch, the manifest and the content-addressed copies
    let archive: Vec<(String, Vec<u8>)> = files.values().map(|(n, b, _)| (n.clone(), b.clone())).collect();
    crate::mpqw::write(&out.join("client").join(&r.patch), &archive)?;
    let mut manifest = vec![];
    for (n, b, from) in files.values() {
        let h = sha256(b);
        let cas = out.join("cas").join(&h[..2]).join(&h);
        if !cas.exists() {
            std::fs::create_dir_all(cas.parent().unwrap())?;
            std::fs::write(&cas, b)?;
        }
        report.client_bytes += b.len() as u64;
        manifest.push(serde_json::json!({"path": n, "sha256": h, "size": b.len(), "from": from}));
    }
    report.client_files = manifest.len();
    std::fs::write(out.join("client/manifest.json"), serde_json::to_vec_pretty(&manifest)?)?;

    // SQL in dependency order, rollback in reverse
    let sqld = out.join("server/sql");
    std::fs::create_dir_all(&sqld)?;
    let head = format!("-- {} realm build (Vanilla Forge): {} pack(s)\n", r.id, packs.len());
    let mut ins = head.clone();
    let mut rb = head;
    for &i in &ord {
        let p = &packs[i];
        ins.push_str(&format!("\n-- ===== {} {} =====\n{}", p.id(), p.manifest.pack.version, p.sql("install")));
    }
    for &i in ord.iter().rev() {
        let p = &packs[i];
        rb.push_str(&format!("\n-- ===== {} {} =====\n{}", p.id(), p.manifest.pack.version, p.sql("rollback")));
    }
    std::fs::write(sqld.join("install.sql"), ins)?;
    std::fs::write(sqld.join("rollback.sql"), rb)?;

    for &i in &ord {
        let p = &packs[i];
        report.packs.push(serde_json::json!({
            "id": p.id(), "name": p.manifest.pack.name, "version": p.manifest.pack.version,
            "build_hash": p.sig.build_hash, "key": p.sig.public_key,
        }));
    }
    std::fs::write(out.join("realm-report.json"), serde_json::to_vec_pretty(&report)?)?;
    Ok(report)
}

/// `World\Maps\X\X_32_48.adt` → (32, 48).
fn tile_numbers(path: &str) -> Option<(i32, i32)> {
    let stem = path.rsplit('\\').next()?.strip_suffix(".adt").or_else(|| path.rsplit('\\').next()?.strip_suffix(".ADT"))?;
    let mut it = stem.rsplitn(3, '_');
    let b = it.next()?.parse().ok()?;
    let a = it.next()?.parse().ok()?;
    Some((a, b))
}

/// What converting tiles for the server needs: AreaTable's explore flags (the realm's patch,
/// else the server's DBCs, else the game's) and the .map version the server reads.
fn server_map_inputs(
    r: &RealmSpec,
    dir: &Path,
    files: &BTreeMap<String, (String, Vec<u8>, String)>,
    game: Option<&crate::vfs::GameData>,
) -> Result<(HashMap<u32, u16>, [u8; 4])> {
    let at = match files.get("dbfilesclient\\areatable.dbc") {
        Some((_, b, _)) => b.clone(),
        None => match r.server_dbc.as_ref().and_then(|sd| find_ci(&dir.join(sd), "AreaTable.dbc")) {
            Some(f) => std::fs::read(f)?,
            None => game
                .context("converting edited tiles for the server needs AreaTable.dbc: set server_dbc or game in realm.toml")?
                .read("DBFilesClient\\AreaTable.dbc")?,
        },
    };
    let flags = crate::gridmap::area_flags(&Dbc::parse(&at)?);
    let mut version = crate::gridmap::VERSION;
    if let Some(sm) = &r.server_maps {
        if let Some(f) = std::fs::read_dir(dir.join(sm)).ok().into_iter().flatten().filter_map(|e| e.ok()).map(|e| e.path()).find(|p| p.extension().is_some_and(|e| e == "map")) {
            if let Some(v) = std::fs::read(&f).ok().and_then(|b| crate::gridmap::version_of(&b)) {
                version = v;
            }
        }
    }
    Ok((flags, version))
}

fn find_ci(dir: &Path, name: &str) -> Option<PathBuf> {
    std::fs::read_dir(dir).ok()?.filter_map(|e| e.ok()).map(|e| e.path()).find(|p| p.file_name().is_some_and(|n| n.to_string_lossy().eq_ignore_ascii_case(name)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::{create, Template};
    use crate::vfs::GameData;

    fn pack_with_icon(root: &Path, name: &str, icon_clone: i64, depends: &[&str]) -> PathBuf {
        let mut p = create(root.join(name), name, "Orion", Template::Pack).unwrap();
        p.manifest.depends = depends.iter().map(|s| s.to_string()).collect();
        p.save().unwrap();
        let mut lock = crate::ids::IdLock::load(&p.root).unwrap();
        let id = lock.allocate(&p.manifest.pack.id, "SpellIcon", "").unwrap();
        lock.save(&p.root).unwrap();
        std::fs::create_dir_all(p.root.join("data/dbc")).unwrap();
        std::fs::write(p.root.join("data/dbc/SpellIcon.toml"), format!("[[row]]\nID = {id}\nclone = {icon_clone}\n")).unwrap();
        std::fs::create_dir_all(p.root.join("data/world")).unwrap();
        let ct = lock.allocate(&p.manifest.pack.id, "creature_template", "").unwrap();
        lock.save(&p.root).unwrap();
        std::fs::write(p.root.join("data/world/creature_template.toml"), format!("[[row]]\nEntry = {ct}\nName = \"{name}\"\n")).unwrap();
        let game = GameData::open(crate::vfs::tests::fake_game(&root.join("wow"))).unwrap();
        publish::package(&p, Some(&game)).unwrap().package
    }

    #[test]
    fn two_packs_merge_into_one_realm() {
        crate::test_config();
        let d = tempfile::tempdir().unwrap();
        let a = pack_with_icon(d.path(), "Alpha Pack", 1, &[]);
        let b = pack_with_icon(d.path(), "Beta Pack", 2, &["alpha-pack >=0.1", "classicplus"]);
        // the realm's own patch, with a SpellIcon.dbc
        let base = d.path().join("patch-Z.MPQ");
        crate::mpqw::write(&base, &[("DBFilesClient\\SpellIcon.dbc".into(), data::tests::fake_dbc().write()), ("Interface\\Own.txt".into(), b"own".to_vec())]).unwrap();
        let toml = d.path().join("realm.toml");
        std::fs::write(
            &toml,
            format!(
                "[realm]\nid = \"classicplus\"\nbase_patch = \"patch-Z.MPQ\"\nprovides = [\"classicplus\"]\n\n[[pack]]\nfile = {:?}\n\n[[pack]]\nfile = {:?}\n",
                b.strip_prefix(d.path()).unwrap(),
                a.strip_prefix(d.path()).unwrap()
            ),
        )
        .unwrap();
        let r = build(&toml).unwrap();
        assert_eq!(r.packs.iter().map(|p| p["id"].as_str().unwrap()).collect::<Vec<_>>(), vec!["alpha-pack", "beta-pack"], "dependency order");
        assert_eq!(r.dbc_tables, vec!["SpellIcon"]);
        let out = d.path().join("build");
        let files = read_mpq(&out.join("client/patch-Z.MPQ")).unwrap();
        assert!(files.iter().any(|(n, _)| n == "Interface\\Own.txt"), "the base patch's files stay");
        assert!(files.iter().any(|(n, _)| n == "Interface\\Icons\\INV_AlphaPack.blp") && files.iter().any(|(n, _)| n == "Interface\\Icons\\INV_BetaPack.blp"));
        let icons = Dbc::parse(&files.iter().find(|(n, _)| n.ends_with("SpellIcon.dbc")).unwrap().1).unwrap();
        assert_eq!(icons.records.len(), 4, "2 stock + one row from each pack");
        let ins = std::fs::read_to_string(out.join("server/sql/install.sql")).unwrap();
        assert!(ins.find("===== alpha-pack").unwrap() < ins.find("===== beta-pack").unwrap());
        let rb = std::fs::read_to_string(out.join("server/sql/rollback.sql")).unwrap();
        assert!(rb.find("===== beta-pack").unwrap() < rb.find("===== alpha-pack").unwrap(), "rollback in reverse");
        // content-addressed copies
        let m: Vec<Value> = serde_json::from_slice(&std::fs::read(out.join("client/manifest.json")).unwrap()).unwrap();
        let h = m[0]["sha256"].as_str().unwrap();
        assert!(out.join("cas").join(&h[..2]).join(h).is_file());

        // a missing dependency is refused
        std::fs::write(&toml, format!("[realm]\nid = \"x\"\nbase_patch = \"patch-Z.MPQ\"\n[[pack]]\nfile = {:?}\n", b.strip_prefix(d.path()).unwrap())).unwrap();
        assert!(build(&toml).unwrap_err().to_string().contains("needs alpha-pack"));
    }

    #[test]
    fn a_pack_s_new_map_reaches_the_realm() {
        crate::test_config();
        let d = tempfile::tempdir().unwrap();
        let g = crate::world::tests::map_game(d.path());
        let p = create(d.path().join("isle"), "Isle Pack", "Orion", Template::Pack).unwrap();
        let spec: crate::world::NewMap = serde_json::from_value(serde_json::json!({"name": "Ember Isle", "size": 2})).unwrap();
        let r = crate::world::new_map(&p, &g, &spec).unwrap();
        let id = r["id"].as_u64().unwrap();
        let pk = publish::package(&p, Some(&g)).unwrap().package;
        let toml = d.path().join("realm.toml");
        std::fs::write(&toml, format!("[realm]\nid = \"r\"\ngame = \"wow\"\nserver_dbc = \"sdbc\"\n[[pack]]\nfile = {:?}\n", pk.strip_prefix(d.path()).unwrap())).unwrap();
        // the server's DBCs: the game's
        std::fs::create_dir_all(d.path().join("sdbc")).unwrap();
        for t in ["Map", "AreaTable"] {
            std::fs::write(d.path().join("sdbc").join(format!("{t}.dbc")), g.read(&format!("DBFilesClient\\{t}.dbc")).unwrap()).unwrap();
        }
        let rep = build(&toml).unwrap();
        assert_eq!(rep.server_maps.len(), 4, "{:?}", rep.server_maps);
        assert!(rep.server_maps.contains(&format!("{id:03}3232.map")));
        let server_map = Dbc::parse(&std::fs::read(d.path().join("build/server/dbc/Map.dbc")).unwrap()).unwrap();
        assert!(server_map.find(id as u32).is_some(), "the server knows the map");
        let files = read_mpq(&d.path().join("build/client/patch-Z.MPQ")).unwrap();
        assert!(files.iter().any(|(n, _)| n.eq_ignore_ascii_case("World\\Maps\\EmberIsle\\EmberIsle.wdt")));
        let sql = std::fs::read_to_string(d.path().join("build/server/sql/install.sql")).unwrap();
        assert!(sql.contains("game_tele"));
    }

    #[test]
    fn edited_terrain_reaches_the_server() {
        crate::test_config();
        let d = tempfile::tempdir().unwrap();
        let p = create(d.path().join("t"), "Terra Pack", "Orion", Template::Pack).unwrap();
        let t = p.root.join("maps/Azeroth/terrain");
        std::fs::create_dir_all(&t).unwrap();
        std::fs::write(t.join("32_48.chunks.json"), r#"{"3_4":{"area":87,"holes":1}}"#).unwrap();
        let game = GameData::open(crate::vfs::tests::fake_game(&d.path().join("wow"))).unwrap();
        let pk = publish::package(&p, Some(&game)).unwrap().package;
        // the realm's patch carries the tile and AreaTable (87's explore flag: 5)
        let at = Dbc { fields: 4, records: vec![vec![12, 0, 0, 1], vec![87, 0, 0, 5]], strings: vec![0] };
        crate::mpqw::write(
            &d.path().join("patch-Z.MPQ"),
            &[("World\\Maps\\Azeroth\\Azeroth_32_48.adt".into(), crate::adt::tests::fake_tile(32, 48, 20.0)), ("DBFilesClient\\AreaTable.dbc".into(), at.write())],
        )
        .unwrap();
        let toml = d.path().join("realm.toml");
        std::fs::write(&toml, format!("[realm]\nid = \"r\"\nbase_patch = \"patch-Z.MPQ\"\n[[pack]]\nfile = {:?}\n", pk.strip_prefix(d.path()).unwrap())).unwrap();
        let r = build(&toml).unwrap();
        assert_eq!(r.server_maps, vec!["0004832.map"]);
        let m = std::fs::read(d.path().join("build/server/maps/0004832.map")).unwrap();
        assert_eq!(&m[..8], b"MAPSz1.4");
        // the area grid (it varies now): row 4, col 3 has 87's flag
        let k = 40 + 8 + (4 * 16 + 3) * 2;
        assert_eq!(u16::from_le_bytes([m[k], m[k + 1]]), 5);
        assert_eq!(u16::from_le_bytes([m[48], m[49]]), 1, "the rest is area 12");
        let holes = u32::from_le_bytes(m[32..36].try_into().unwrap()) as usize;
        assert_eq!(m[holes + (4 * 16 + 3) * 2], 1);
        let mm = std::fs::read_to_string(d.path().join("build/server/movemaps.txt")).unwrap();
        assert!(mm.contains("MoveMapGen 0 --tile 32,48"), "{mm}");
    }

    #[test]
    fn placed_models_get_the_server_s_collision() {
        crate::test_config();
        let d = tempfile::tempdir().unwrap();
        let p = create(d.path().join("t"), "Crate Pack", "Orion", Template::Pack).unwrap();
        let wow = crate::vfs::tests::fake_game(&d.path().join("wow"));
        wow_mpq::ArchiveBuilder::new()
            .add_file_data(crate::adt::tests::fake_tile(32, 48, 20.0), "World\\Maps\\Azeroth\\Azeroth_32_48.adt")
            .add_file_data(crate::vmap::box_m2(), "World\\Generic\\ForgeTest\\Crate.m2")
            .build(wow.join("Data/patch-2.MPQ"))
            .unwrap();
        let game = GameData::open(wow).unwrap();
        let pl = crate::world::Placement { model: "World\\Generic\\ForgeTest\\Crate.mdx".into(), x: -8800.0, y: -250.0, z: 20.0, turn: 0.0, scale: 1.0, uid: 0, wmo_box: None, tilt: [0.0; 2], set: 0 };
        crate::world::place(&p, Some(&game), "Azeroth", pl, false).unwrap();
        let pk = publish::package(&p, Some(&game)).unwrap().package;
        crate::mpqw::write(
            &d.path().join("patch-Z.MPQ"),
            &[("World\\Maps\\Azeroth\\Azeroth_32_48.adt".into(), crate::adt::tests::fake_tile(32, 48, 20.0)), ("World\\Generic\\ForgeTest\\Crate.m2".into(), crate::vmap::box_m2())],
        )
        .unwrap();
        crate::vmap::stock_vmaps(&d.path().join("vmaps"));
        let toml = d.path().join("realm.toml");
        let pack = format!("[[pack]]\nfile = {:?}\n", pk.strip_prefix(d.path()).unwrap());
        // without the server's vmaps: said, not done
        std::fs::write(&toml, format!("[realm]\nid = \"r\"\nbase_patch = \"patch-Z.MPQ\"\n{pack}")).unwrap();
        let r = build(&toml).unwrap();
        assert!(r.server_vmaps.is_empty());
        assert!(r.warnings.iter().any(|w| w.contains("server_vmaps")), "{:?}", r.warnings);
        std::fs::write(&toml, format!("[realm]\nid = \"r\"\nbase_patch = \"patch-Z.MPQ\"\nserver_vmaps = \"vmaps\"\n{pack}")).unwrap();
        let r = build(&toml).unwrap();
        let mut got = r.server_vmaps.clone();
        got.sort();
        assert_eq!(got, vec!["000.vmtree", "000_32_48.vmtile", "Crate.m2.vmo"], "{:?}", r.warnings);
        let tile = crate::vmap::parse_tile(&std::fs::read(d.path().join("build/server/vmaps/000_32_48.vmtile")).unwrap()).unwrap();
        assert_eq!(tile.iter().map(|t| t.0.name.as_str()).collect::<Vec<_>>(), vec!["Crate.m2"]);
        assert!(!d.path().join("vmaps/Crate.m2.vmo").exists(), "the realm's own vmaps are only read");
        let mm = std::fs::read_to_string(d.path().join("build/server/movemaps.txt")).unwrap();
        assert!(mm.contains("MoveMapGen 0 --tile 32,48"), "{mm}");
    }
}
