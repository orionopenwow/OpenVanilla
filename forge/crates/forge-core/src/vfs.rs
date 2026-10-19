//! The creator's own 1.12 game data, read-only: every MPQ in their `Data\` folder as one patch
//! chain (base archives first, then `patch.MPQ`, `patch-2.MPQ` ... in the client's order), with a
//! sorted index of every file name for the Asset Browser, and previews.
//!
//! Nothing read here is ever written into a pack; the build only uses it to refuse files that are
//! byte-identical to the game's (see `check`).

use anyhow::{bail, Context, Result};
use base64::Engine;
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use wow_mpq::PatchChain;

pub struct GameData {
    pub dir: PathBuf,
    /// The archives in load order, lowest priority first: (path, priority).
    pub archives: Vec<(PathBuf, i32)>,
    chain: Mutex<PatchChain>,
    /// Every file name in the chain, sorted case-insensitively, deduplicated.
    index: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct Status {
    pub dir: String,
    pub archives: Vec<String>,
    pub files: usize,
}

#[derive(Debug, Serialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Preview {
    /// A texture: PNG bytes (base64) of the largest mip at most 512 px wide.
    Image { width: u32, height: u32, png: String, format: String },
    Text { text: String, truncated: bool },
    Binary { size: usize, head: String },
}

/// The 1.12 client's base archives (any case) and their order among themselves.
const BASE: &[&str] = &["base", "dbc", "fonts", "interface", "misc", "model", "sound", "speech", "terrain", "texture", "wmo"];

/// Find the `Data` folder of a game install (the folder itself, or one holding `Data\`).
pub fn find_data_dir(game: &Path) -> Option<PathBuf> {
    let has_mpq = |d: &Path| {
        std::fs::read_dir(d).map(|rd| rd.filter_map(|e| e.ok()).any(|e| is_mpq(&e.path()))).unwrap_or(false)
    };
    for cand in [game.join("Data"), game.join("data"), game.to_path_buf()] {
        if cand.is_dir() && has_mpq(&cand) {
            return Some(cand);
        }
    }
    None
}

/// Where a creator's 1.12 game probably is: the folder the Open Vanilla launcher was given
/// (its settings), then the usual install places. Only folders with a Data folder of MPQs.
pub fn detect_games() -> Vec<PathBuf> {
    let mut cands: Vec<PathBuf> = vec![];
    let mut data_dirs = vec![];
    for var in ["LOCALAPPDATA", "APPDATA"] {
        if let Ok(b) = std::env::var(var) {
            for name in ["OpenVanilla", "OpenWoW"] {
                data_dirs.push(PathBuf::from(&b).join(name));
            }
        }
    }
    for d in data_dirs {
        for f in [d.join("Settings").join("settings.json"), d.join("settings.json")] {
            let Some(v) = std::fs::read(&f).ok().and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok()) else { continue };
            if let Some(w) = v.get("wow_folder").and_then(|x| x.as_str()) {
                cands.push(PathBuf::from(w));
            }
            if let Some(cl) = v.get("clients").and_then(|x| x.as_object()) {
                for c in cl.values() {
                    if let Some(p) = c.get("path").and_then(|x| x.as_str()) {
                        cands.push(PathBuf::from(p));
                    }
                }
            }
        }
    }
    if cfg!(windows) {
        let home = std::env::var("USERPROFILE").unwrap_or_default();
        for drive in ["C:", "D:", "E:"] {
            for rel in ["Games\\World of Warcraft", "World of Warcraft", "Program Files (x86)\\World of Warcraft", "Program Files\\World of Warcraft", "Games\\WoW-1.12.1", "WoW-1.12.1", "Games\\WoW"] {
                cands.push(PathBuf::from(format!("{drive}\\{rel}")));
            }
        }
        for rel in ["Desktop\\World of Warcraft", "Desktop\\WoW-1.12.1", "Games\\World of Warcraft", "Documents\\World of Warcraft"] {
            cands.push(PathBuf::from(&home).join(rel));
        }
    }
    let mut out: Vec<PathBuf> = vec![];
    for c in cands {
        if find_data_dir(&c).is_some() && !out.contains(&c) {
            out.push(c);
        }
    }
    out
}

fn is_mpq(p: &Path) -> bool {
    p.extension().is_some_and(|e| e.eq_ignore_ascii_case("mpq"))
}

/// Load priority for an archive name: base archives 0..10, then patch.MPQ = 100, then each
/// patch-?.MPQ at 100 + its (lowercase) character code (the client loads them in that order;
/// later ones win).
pub fn priority(name: &str) -> i32 {
    let stem = name.to_ascii_lowercase();
    let stem = stem.trim_end_matches(".mpq");
    if let Some(i) = BASE.iter().position(|b| *b == stem) {
        return i as i32;
    }
    if stem == "patch" {
        return 100;
    }
    // `patch-?.MPQ`: exactly one character, in case-folded byte order (the client's glob and
    // sort), so patch-z outranks patch-9 and Forge's patch-~ outranks patch-z
    if let Some(rest) = stem.strip_prefix("patch-") {
        let mut cs = rest.chars();
        if let (Some(c), None) = (cs.next(), cs.next()) {
            if c.is_ascii() {
                return 100 + c as i32;
            }
        }
    }
    50 // something else (a locale archive): above base, below patches
}

impl GameData {
    pub fn open(game_dir: impl AsRef<Path>) -> Result<GameData> {
        let game = game_dir.as_ref();
        let data = find_data_dir(game).with_context(|| format!("no MPQ files in {} or its Data folder", game.display()))?;
        let mut archives: Vec<(PathBuf, i32)> = Vec::new();
        let mut dirs = vec![data.clone()];
        // locale folders (Data\enUS\...) hold archives too on some installs
        if let Ok(rd) = std::fs::read_dir(&data) {
            dirs.extend(rd.filter_map(|e| e.ok()).map(|e| e.path()).filter(|p| p.is_dir()));
        }
        for d in dirs {
            if let Ok(rd) = std::fs::read_dir(&d) {
                for e in rd.filter_map(|e| e.ok()) {
                    let p = e.path();
                    // Forge's own Test & Play archive is the pack, not the game
                    if is_mpq(&p) && !p.file_name().unwrap().to_string_lossy().eq_ignore_ascii_case(crate::play::DEV_ARCHIVE) {
                        let name = p.file_name().unwrap().to_string_lossy().to_string();
                        archives.push((p, priority(&name)));
                    }
                }
            }
        }
        if archives.is_empty() {
            bail!("no MPQ files in {}", data.display());
        }
        archives.sort_by(|a, b| a.1.cmp(&b.1).then(a.0.cmp(&b.0)));
        let mut chain = PatchChain::new();
        for (p, pri) in &archives {
            chain.add_archive(p, *pri).with_context(|| format!("can't open {}", p.display()))?;
        }
        let mut names: Vec<String> = chain.list().context("can't list the game's files")?.into_iter().map(|e| e.name)
            .filter(|n| !n.starts_with('(')) // (listfile), (attributes), (signature): the archive's own
            .collect();
        names.sort_by_key(|n| n.to_ascii_lowercase());
        names.dedup_by(|a, b| a.eq_ignore_ascii_case(b));
        Ok(GameData { dir: game.to_path_buf(), archives, chain: Mutex::new(chain), index: names })
    }

    pub fn status(&self) -> Status {
        Status {
            dir: self.dir.display().to_string(),
            archives: self.archives.iter().map(|(p, _)| p.file_name().unwrap().to_string_lossy().to_string()).collect(),
            files: self.index.len(),
        }
    }

    pub fn files(&self) -> &[String] {
        &self.index
    }

    /// Files whose path contains every word of the query (case-insensitive), up to `limit`.
    pub fn search(&self, query: &str, limit: usize) -> Vec<String> {
        let words: Vec<String> = query.split_whitespace().map(|w| w.to_ascii_lowercase().replace('/', "\\")).collect();
        self.index
            .iter()
            .filter(|n| {
                let l = n.to_ascii_lowercase();
                words.iter().all(|w| l.contains(w.as_str()))
            })
            .take(limit)
            .cloned()
            .collect()
    }

    /// The immediate children of a folder (`""` = the root): (name, is_folder), folders first.
    pub fn children(&self, folder: &str) -> Vec<(String, bool)> {
        let prefix = if folder.is_empty() { String::new() } else { format!("{}\\", folder.trim_end_matches('\\').to_ascii_lowercase()) };
        let mut out: Vec<(String, bool)> = Vec::new();
        for n in &self.index {
            let l = n.to_ascii_lowercase();
            if !l.starts_with(&prefix) {
                continue;
            }
            let rest = &n[prefix.len()..];
            match rest.find('\\') {
                Some(i) => {
                    let d = &rest[..i];
                    if !out.last().is_some_and(|(x, f)| *f && x.eq_ignore_ascii_case(d)) && !out.iter().any(|(x, f)| *f && x.eq_ignore_ascii_case(d)) {
                        out.push((d.to_string(), true));
                    }
                }
                None => out.push((rest.to_string(), false)),
            }
        }
        out.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.to_ascii_lowercase().cmp(&b.0.to_ascii_lowercase())));
        out
    }

    pub fn read(&self, path: &str) -> Result<Vec<u8>> {
        let mut c = self.chain.lock().unwrap();
        c.read_file(&crate::game_path(path)).with_context(|| format!("{path} isn't in the game data"))
    }

    pub fn contains(&self, path: &str) -> bool {
        self.chain.lock().unwrap().contains_file(&crate::game_path(path))
    }

    pub fn preview(&self, path: &str) -> Result<Preview> {
        preview_bytes(path, &self.read(path)?)
    }
}

/// A preview of any file's bytes by its extension (used for game files and pack files alike).
pub fn preview_bytes(path: &str, bytes: &[u8]) -> Result<Preview> {
    let ext = path.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    match ext.as_str() {
        "blp" => blp_preview(bytes),
        "tga" | "png" => {
            let fmt = if ext == "png" { image::ImageFormat::Png } else { image::ImageFormat::Tga };
            let img = image::load_from_memory_with_format(bytes, fmt)?.to_rgba8();
            png_preview(img, ext.to_uppercase())
        }
        "lua" | "xml" | "toc" | "txt" | "wtf" | "trs" | "ini" | "html" | "htm" | "toml" | "json" | "md" | "sql" => {
            let max = 64 * 1024;
            let text = String::from_utf8_lossy(&bytes[..bytes.len().min(max)]).to_string();
            Ok(Preview::Text { text, truncated: bytes.len() > max })
        }
        _ => Ok(Preview::Binary {
            size: bytes.len(),
            head: bytes.iter().take(64).map(|b| format!("{b:02x}")).collect::<Vec<_>>().join(" "),
        }),
    }
}

fn blp_preview(bytes: &[u8]) -> Result<Preview> {
    let blp = wow_blp::parser::load_blp_from_buf(bytes).map_err(|e| anyhow::anyhow!("not a readable BLP: {e:?}"))?;
    // the first mip at most 512 px wide
    let mut level = 0;
    while (blp.header.width >> level) > 512 && level < 8 {
        level += 1;
    }
    let img = wow_blp::convert::blp_to_image(&blp, level).map_err(|e| anyhow::anyhow!("can't decode the BLP: {e:?}"))?;
    let format = format!("{:?}", blp.header.content);
    png_preview(img.to_rgba8(), format)
}

fn png_preview(img: image::RgbaImage, format: String) -> Result<Preview> {
    let (w, h) = img.dimensions();
    let mut out = std::io::Cursor::new(Vec::new());
    img.write_to(&mut out, image::ImageFormat::Png)?;
    Ok(Preview::Image { width: w, height: h, png: base64::engine::general_purpose::STANDARD.encode(out.into_inner()), format })
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// A tiny fake install: Data/texture.MPQ with an icon and a Lua file, Data/patch.MPQ that
    /// replaces the Lua file. The chain must show the patch's copy and preview the icon.
    pub(crate) fn fake_game(dir: &Path) -> PathBuf {
        let data = dir.join("Data");
        std::fs::create_dir_all(&data).unwrap();
        let png = dir.join("icon.png");
        image::RgbaImage::from_pixel(32, 32, image::Rgba([200, 40, 40, 255])).save(&png).unwrap();
        let blp = crate::build::png_to_blp(&png).unwrap();
        wow_mpq::ArchiveBuilder::new()
            .add_file_data(blp, "Interface\\Icons\\INV_Misc_Test.blp")
            .add_file_data(b"-- base\n".to_vec(), "Interface\\FrameXML\\Test.lua")
            .build(data.join("texture.MPQ")).unwrap();
        wow_mpq::ArchiveBuilder::new()
            .add_file_data(b"-- patched\n".to_vec(), "Interface\\FrameXML\\Test.lua")
            .build(data.join("patch.MPQ")).unwrap();
        dir.to_path_buf()
    }

    #[test]
    fn finds_the_game_the_launcher_was_given() {
        let dir = tempfile::tempdir().unwrap();
        let game = fake_game(&dir.path().join("My WoW"));
        let settings = dir.path().join("appdata/OpenVanilla/Settings");
        std::fs::create_dir_all(&settings).unwrap();
        std::fs::write(settings.join("settings.json"), serde_json::to_vec(&serde_json::json!({"wow_folder": game, "clients": {"vanilla": {"path": "/nowhere"}}})).unwrap()).unwrap();
        std::env::set_var("LOCALAPPDATA", dir.path().join("appdata"));
        let found = detect_games();
        std::env::remove_var("LOCALAPPDATA");
        assert_eq!(found, vec![game], "the launcher's folder, and nothing that isn't a game");
    }

    #[test]
    fn reads_a_game_install_as_one_patch_chain() {
        let dir = tempfile::tempdir().unwrap();
        let g = GameData::open(fake_game(dir.path())).unwrap();
        assert_eq!(g.status().archives, vec!["texture.MPQ", "patch.MPQ"]);
        assert_eq!(g.search("icons test", 10), vec!["Interface\\Icons\\INV_Misc_Test.blp"]);
        assert_eq!(g.read("Interface/FrameXML/Test.lua").unwrap(), b"-- patched\n", "the patch wins");
        let root = g.children("");
        assert_eq!(root, vec![("Interface".to_string(), true)]);
        let kids = g.children("Interface");
        assert!(kids.contains(&("Icons".to_string(), true)) && kids.contains(&("FrameXML".to_string(), true)));
        match g.preview("Interface\\Icons\\INV_Misc_Test.blp").unwrap() {
            Preview::Image { width, height, .. } => assert_eq!((width, height), (32, 32)),
            other => panic!("{other:?}"),
        }
        match g.preview("Interface\\FrameXML\\Test.lua").unwrap() {
            Preview::Text { text, .. } => assert!(text.contains("patched")),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn archive_order_matches_the_client() {
        let mut v = vec!["patch-2.MPQ", "texture.MPQ", "patch.MPQ", "dbc.MPQ", "patch-~.MPQ", "patch-Z.MPQ", "patch-3.mpq"];
        v.sort_by_key(|n| priority(n));
        assert_eq!(v, vec!["dbc.MPQ", "texture.MPQ", "patch.MPQ", "patch-2.MPQ", "patch-3.mpq", "patch-Z.MPQ", "patch-~.MPQ"]);
    }
}
