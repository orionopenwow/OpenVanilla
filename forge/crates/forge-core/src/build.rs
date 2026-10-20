//! A project -> `build/`:
//!
//! ```text
//! build/
//!   patch-<packid>.MPQ   every file at its game path (MPQ v1, zlib sectors, a listfile: mpqw), for a
//!                        desktop 1.12 client or a realm's merge (plan §5.3)
//!   files/<game path>    the same files loose, for streaming
//!   manifest.json        path -> BLAKE3, size (the content-addressed list the realm serves from)
//!   report.json          the checks, sizes and IDs: what Publish shows and the review reads
//! ```
//! A build runs the checks first and stops on any error. The same inputs always give the same
//! bytes (files are added in sorted order), so the build hash identifies a version.

use crate::check::{self, Finding, Level};
use crate::project::Project;
use crate::vfs::GameData;
use anyhow::{bail, Context, Result};
use serde::Serialize;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use walkdir::WalkDir;

/// One file the pack ships.
#[derive(Debug, Clone)]
pub struct Entry {
    /// The game path (backslashes, the case the creator used).
    pub path: String,
    /// The project file it comes from.
    pub source: PathBuf,
    /// How it is made: copied, or converted (PNG -> BLP).
    pub how: How,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum How {
    Copy,
    PngToBlp,
}

#[derive(Debug, Serialize)]
pub struct ManifestFile {
    pub path: String,
    pub blake3: String,
    pub size: u64,
}

#[derive(Debug, Serialize)]
pub struct Report {
    pub pack: String,
    pub version: String,
    pub files: usize,
    pub bytes: u64,
    pub mpq: String,
    pub mpq_bytes: u64,
    /// BLAKE3 over the manifest: the same project always builds to the same hash.
    pub build_hash: String,
    pub findings: Vec<Finding>,
    pub ids: BTreeMap<String, crate::ids::Range>,
    /// Game-data rows: SQL for the realm, DBC deltas.
    pub data: crate::data::Outputs,
    /// A dev build: the MPQ also carries DBCs merged from your own game (never published).
    pub dev: bool,
}

/// Every file the project ships, keyed by its lowercase game path (one file per game path).
pub fn collect(p: &Project) -> Result<BTreeMap<String, Entry>> {
    let mut out: BTreeMap<String, Entry> = BTreeMap::new();
    let mut add = |path: String, source: PathBuf, how: How| -> Result<()> {
        let key = path.to_ascii_lowercase();
        if let Some(prev) = out.get(&key) {
            bail!("{} and {} both ship {}", prev.source.display(), source.display(), path);
        }
        out.insert(key, Entry { path, source, how });
        Ok(())
    };
    for addon in p.addons() {
        let name = addon.file_name().unwrap().to_string_lossy().to_string();
        for f in files_under(&addon) {
            let rel = rel_game_path(&addon, &f);
            add(format!("Interface\\AddOns\\{name}\\{rel}"), f, How::Copy)?;
        }
    }
    let art = p.root.join("art");
    for f in files_under(&art) {
        let rel = rel_game_path(&art, &f);
        if rel.to_ascii_lowercase().ends_with(".png") {
            add(format!("{}.blp", &rel[..rel.len() - 4]), f, How::PngToBlp)?;
        } else {
            add(rel, f, How::Copy)?;
        }
    }
    let files = p.root.join("files");
    for f in files_under(&files) {
        add(rel_game_path(&files, &f), f, How::Copy)?;
    }
    for (game_path, f) in crate::model::game_files(p) {
        add(game_path, f, How::Copy)?;
    }
    Ok(out)
}

fn files_under(dir: &Path) -> Vec<PathBuf> {
    if !dir.is_dir() {
        return vec![];
    }
    let mut v: Vec<PathBuf> = WalkDir::new(dir)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
        .map(|e| e.into_path())
        .filter(|p| {
            let n = p.file_name().unwrap().to_string_lossy();
            !(n.starts_with('.') || n.ends_with(".forge.toml") || n == "Thumbs.db" || n == "desktop.ini")
        })
        .collect();
    v.sort();
    v
}

fn rel_game_path(base: &Path, f: &Path) -> String {
    f.strip_prefix(base).unwrap().components().map(|c| c.as_os_str().to_string_lossy().to_string()).collect::<Vec<_>>().join("\\")
}

/// The bytes an entry ships.
pub fn produce(e: &Entry) -> Result<Vec<u8>> {
    match e.how {
        How::Copy => std::fs::read(&e.source).with_context(|| format!("can't read {}", e.source.display())),
        How::PngToBlp => png_to_blp(&e.source),
    }
}

/// PNG -> BLP2 with mipmaps: DXT5 when the image has any transparency, DXT1 otherwise.
pub fn png_to_blp(src: &Path) -> Result<Vec<u8>> {
    use wow_blp::convert::{image_to_blp, Blp2Format, BlpTarget, DxtAlgorithm};
    let img = image::open(src).with_context(|| format!("{} isn't a readable PNG", src.display()))?;
    let rgba = img.to_rgba8();
    let has_alpha = rgba.pixels().any(|p| p[3] < 255);
    let fmt = if has_alpha {
        Blp2Format::Dxt5 { has_alpha: true, compress_algorithm: DxtAlgorithm::ClusterFit }
    } else {
        Blp2Format::Dxt1 { has_alpha: false, compress_algorithm: DxtAlgorithm::ClusterFit }
    };
    let blp = image_to_blp(image::DynamicImage::ImageRgba8(rgba), true, BlpTarget::Blp2(fmt), image::imageops::FilterType::Triangle)
        .map_err(|e| anyhow::anyhow!("{}: {e:?}", src.display()))?;
    wow_blp::encode::encode_blp(&blp).map_err(|e| anyhow::anyhow!("{}: {e:?}", src.display()))
}

/// Build the project. `game` (the creator's own install) lets the checks refuse stock files.
pub fn build(p: &Project, game: Option<&GameData>) -> Result<Report> {
    build_with(p, game, false)
}

/// `dev`: also merge the pack's DBC rows into the creator's own DBCs and put them in the MPQ, so
/// the local client sees new displays and spells (Test & Play). Never what Publish uploads.
pub fn build_with(p: &Project, game: Option<&GameData>, dev: bool) -> Result<Report> {
    let mut findings = check::run(p, game);
    let entries = collect(p)?;
    if findings.iter().any(|f| f.level == Level::Error) {
        let first = findings.iter().find(|f| f.level == Level::Error).unwrap();
        bail!("the checks found {} error(s); first: {}", findings.iter().filter(|f| f.level == Level::Error).count(), first.message);
    }
    let out = p.build_dir();
    let _ = std::fs::remove_dir_all(&out);
    std::fs::create_dir_all(out.join("files"))?;

    let mut manifest: Vec<ManifestFile> = Vec::new();
    let mut archive: Vec<(String, Vec<u8>)> = Vec::new();
    let mut total = 0u64;
    for e in entries.values() {
        let bytes = produce(e)?;
        total += bytes.len() as u64;
        manifest.push(ManifestFile { path: e.path.clone(), blake3: blake3::hash(&bytes).to_hex().to_string(), size: bytes.len() as u64 });
        let loose = out.join("files").join(e.path.replace('\\', "/"));
        std::fs::create_dir_all(loose.parent().unwrap())?;
        std::fs::write(&loose, &bytes)?;
        archive.push((e.path.clone(), bytes));
    }
    let data = crate::data::emit(p, &out, game, dev)?;
    for (path, bytes) in &data.dev_dbc {
        archive.push((path.clone(), bytes.clone()));
    }
    // map placements: the delta always, the edited tiles in a dev build
    // (an edited copy of a tile the pack ships itself replaces it)
    for (path, bytes) in crate::world::emit(p, &out, game, dev)? {
        archive.retain(|(n, _)| !n.eq_ignore_ascii_case(&path));
        archive.push((path, bytes));
    }
    archive.sort_by(|a, b| a.0.to_ascii_lowercase().cmp(&b.0.to_ascii_lowercase()));
    let mpq_name = format!("patch-{}.MPQ", p.manifest.pack.id);
    let mpq_path = out.join(&mpq_name);
    if archive.is_empty() {
        findings.push(Finding::info("build.empty", "", "The pack ships no client files: no MPQ was written."));
    } else {
        crate::mpqw::write(&mpq_path, &archive).with_context(|| format!("writing {mpq_name}"))?;
    }
    let manifest_json = serde_json::to_vec_pretty(&manifest)?;
    std::fs::write(out.join("manifest.json"), &manifest_json)?;
    let ids = crate::ids::IdLock::load(&p.root).map(|l| l.tables).unwrap_or_default();
    let report = Report {
        pack: p.manifest.pack.id.clone(),
        version: p.manifest.pack.version.clone(),
        files: manifest.len(),
        bytes: total,
        mpq: if archive.is_empty() { String::new() } else { mpq_name },
        mpq_bytes: std::fs::metadata(&mpq_path).map(|m| m.len()).unwrap_or(0),
        build_hash: blake3::hash(&manifest_json).to_hex().to_string(),
        findings,
        ids,
        data,
        dev,
    };
    std::fs::write(out.join("report.json"), serde_json::to_vec_pretty(&report)?)?;
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::{create, Template};

    #[test]
    fn templates_build_into_a_readable_mpq() {
        for t in [Template::Addon, Template::Pack] {
            let dir = tempfile::tempdir().unwrap();
            let p = create(dir.path().join("p"), "Build Test", "Orion", t).unwrap();
            let r = build(&p, None).unwrap();
            assert!(r.files >= 1, "{t:?} ships files");
            assert!(!r.findings.iter().any(|f| f.level == Level::Error), "{:?}", r.findings);
            let mut a = wow_mpq::Archive::open(p.build_dir().join(&r.mpq)).unwrap();
            let names: Vec<String> = a.list().unwrap().into_iter().map(|e| e.name).collect();
            for m in serde_json::from_slice::<Vec<serde_json::Value>>(&std::fs::read(p.build_dir().join("manifest.json")).unwrap()).unwrap() {
                let path = m["path"].as_str().unwrap();
                assert!(names.iter().any(|n| n.eq_ignore_ascii_case(path)), "{path} in the MPQ listfile");
                let data = a.read_file(path).unwrap();
                assert_eq!(blake3::hash(&data).to_hex().to_string(), m["blake3"].as_str().unwrap(), "{path} reads back intact");
            }
            if t == Template::Pack {
                let icon = names.iter().find(|n| n.to_ascii_lowercase().ends_with(".blp")).expect("the PNG became a BLP");
                let bytes = a.read_file(icon).unwrap();
                let blp = wow_blp::parser::load_blp_from_buf(&bytes).unwrap();
                assert_eq!((blp.header.width, blp.header.height), (64, 64));
            }
        }
    }

    #[test]
    fn same_project_same_build_hash() {
        let dir = tempfile::tempdir().unwrap();
        let p = create(dir.path().join("p"), "Hash Test", "", Template::Addon).unwrap();
        let a = build(&p, None).unwrap().build_hash;
        let b = build(&p, None).unwrap().build_hash;
        assert_eq!(a, b);
    }

    #[test]
    fn two_files_at_one_game_path_are_refused() {
        let dir = tempfile::tempdir().unwrap();
        let p = create(dir.path().join("p"), "Clash", "", Template::Empty).unwrap();
        std::fs::create_dir_all(p.root.join("files/Interface/Icons")).unwrap();
        std::fs::create_dir_all(p.root.join("art/Interface/Icons")).unwrap();
        std::fs::write(p.root.join("files/Interface/Icons/X.blp"), b"x").unwrap();
        std::fs::copy(
            p.root.join("files/Interface/Icons/X.blp"),
            p.root.join("art/Interface/Icons/X.blp"),
        ).unwrap();
        assert!(collect(&p).is_err());
    }
}
