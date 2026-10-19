//! The checks every build runs and Publish requires (plan §5.5, the Phase 0/1 part):
//!
//! * the manifest: id, name, semver version, an SPDX licence, known realm targets
//! * credits: `credits.toml` is there and readable
//! * addons: a `.toc` named like the folder, `## Interface: 11200`, a title, every listed file
//!   present; Lua 5.0 pitfalls (`#`, `%`, `string.match`, `select`) the 1.12 client can't run
//! * shipped files: allowed game roots only, no client DBCs (data comes as row deltas later),
//!   art PNGs a power of two and at most 1024 px
//! * the creator's own game data (when Forge knows where it is): a file byte-identical to the
//!   game's is refused (packs ship only the creator's work); one that replaces a game file is noted
//! * IDs: `.forge/ids.lock` is readable

use crate::build::{collect, How};
use crate::project::Project;
use crate::vfs::GameData;
use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Level {
    Error,
    Warning,
    Info,
}

#[derive(Debug, Clone, Serialize)]
pub struct Finding {
    pub level: Level,
    /// Stable code (`addon.interface`), for filters and docs.
    pub code: String,
    /// The project file it is about (relative), or "".
    pub path: String,
    pub message: String,
}

impl Finding {
    fn new(level: Level, code: &str, path: &str, message: impl Into<String>) -> Finding {
        Finding { level, code: code.into(), path: path.into(), message: message.into() }
    }
    pub fn error(code: &str, path: &str, m: impl Into<String>) -> Finding {
        Self::new(Level::Error, code, path, m)
    }
    pub fn warning(code: &str, path: &str, m: impl Into<String>) -> Finding {
        Self::new(Level::Warning, code, path, m)
    }
    pub fn info(code: &str, path: &str, m: impl Into<String>) -> Finding {
        Self::new(Level::Info, code, path, m)
    }
}

/// SPDX ids the Workshop accepts without a second look.
pub const LICENSES: &[&str] = &[
    "MIT", "BSD-2-Clause", "BSD-3-Clause", "Apache-2.0", "GPL-2.0-only", "GPL-2.0-or-later", "GPL-3.0-only",
    "GPL-3.0-or-later", "LGPL-2.1-or-later", "LGPL-3.0-or-later", "MPL-2.0", "Unlicense", "CC0-1.0", "CC-BY-4.0",
    "CC-BY-SA-4.0", "CC-BY-NC-4.0", "CC-BY-NC-SA-4.0",
];
pub const REALMS: &[&str] = &["classicplus", "warfront", "vanilla", "community"];
/// Game folders a pack may ship files into in Phase 0/1.
pub const ROOTS: &[&str] = &[
    "interface", "textures", "creature", "item", "character", "world", "sound", "spells", "environments",
    "particles", "fonts",
];

pub fn run(p: &Project, game: Option<&GameData>) -> Vec<Finding> {
    let mut out = Vec::new();
    manifest(p, &mut out);
    credits(p, &mut out);
    for a in p.addons() {
        addon(p, &a, &mut out);
    }
    files(p, game, &mut out);
    out.extend(crate::data::check(p, game));
    out.extend(crate::model::check(p));
    out.extend(crate::world::check(p, game));
    if let Err(e) = crate::ids::IdLock::load(&p.root) {
        out.push(Finding::error("ids.lock", crate::ids::LOCK, format!("{e:#}")));
    }
    out
}

fn manifest(p: &Project, out: &mut Vec<Finding>) {
    let m = &p.manifest.pack;
    let ok_id = !m.id.is_empty() && m.id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-') && !m.id.starts_with('-');
    if !ok_id {
        out.push(Finding::error("manifest.id", "forge.toml", format!("pack id \"{}\" must be lowercase letters, digits and dashes", m.id)));
    }
    if m.name.trim().is_empty() {
        out.push(Finding::error("manifest.name", "forge.toml", "the pack needs a name"));
    }
    let parts: Vec<&str> = m.version.split('.').collect();
    if parts.len() != 3 || parts.iter().any(|x| x.is_empty() || x.parse::<u32>().is_err()) {
        out.push(Finding::error("manifest.version", "forge.toml", format!("version \"{}\" must be major.minor.patch, like 1.2.0", m.version)));
    }
    if !LICENSES.iter().any(|l| l.eq_ignore_ascii_case(&m.license)) {
        out.push(Finding::warning("manifest.license", "forge.toml", format!("licence \"{}\" isn't one the Workshop knows; reviewers will check it by hand", m.license)));
    }
    if m.authors.is_empty() {
        out.push(Finding::warning("manifest.authors", "forge.toml", "no author: the Workshop shows the pack with no name on it"));
    }
    for r in &p.manifest.targets.realms {
        if !REALMS.contains(&r.as_str()) {
            out.push(Finding::warning("manifest.realm", "forge.toml", format!("unknown realm target \"{r}\" (known: {})", REALMS.join(", "))));
        }
    }
}

fn credits(p: &Project, out: &mut Vec<Finding>) {
    match std::fs::read_to_string(p.root.join("credits.toml")) {
        Err(_) => out.push(Finding::warning("credits.missing", "credits.toml", "no credits.toml: add one listing every asset you didn't make yourself")),
        Ok(t) => {
            if let Err(e) = t.parse::<toml::Table>() {
                out.push(Finding::error("credits.invalid", "credits.toml", format!("credits.toml isn't valid TOML: {e}")));
            }
        }
    }
}

fn rel(p: &Project, f: &std::path::Path) -> String {
    f.strip_prefix(&p.root).unwrap_or(f).to_string_lossy().replace('\\', "/")
}

fn addon(p: &Project, dir: &std::path::Path, out: &mut Vec<Finding>) {
    let name = dir.file_name().unwrap().to_string_lossy().to_string();
    let toc = std::fs::read_dir(dir).ok().and_then(|rd| {
        rd.filter_map(|e| e.ok()).map(|e| e.path()).find(|f| {
            f.file_name().unwrap().to_string_lossy().eq_ignore_ascii_case(&format!("{name}.toc"))
        })
    });
    let Some(toc) = toc else {
        out.push(Finding::error("addon.toc", &rel(p, dir), format!("addon {name} has no {name}.toc (the client finds an addon by it)")));
        return;
    };
    let text = std::fs::read_to_string(&toc).unwrap_or_default();
    let tag = |k: &str| {
        text.lines().find_map(|l| {
            let l = l.trim();
            let rest = l.strip_prefix("##")?.trim();
            let (key, val) = rest.split_once(':')?;
            key.trim().eq_ignore_ascii_case(k).then(|| val.trim().to_string())
        })
    };
    match tag("Interface").as_deref() {
        Some("11200") => {}
        Some(v) => out.push(Finding::error("addon.interface", &rel(p, &toc), format!("## Interface: {v} — the game client loads only 11200"))),
        None => out.push(Finding::error("addon.interface", &rel(p, &toc), "no ## Interface: line (use 11200)")),
    }
    if tag("Title").is_none() {
        out.push(Finding::warning("addon.title", &rel(p, &toc), "no ## Title: (the AddOns list shows the folder name)"));
    }
    for line in text.lines().map(str::trim).filter(|l| !l.is_empty() && !l.starts_with('#')) {
        let f = dir.join(line.replace('\\', "/"));
        if !f.exists() {
            out.push(Finding::error("addon.missing", &rel(p, &toc), format!("lists {line}, which isn't in the folder")));
        } else if line.to_ascii_lowercase().ends_with(".lua") {
            lua50(p, &f, out);
        }
    }
}

/// Does the file parse, and does it stay inside Lua 5.0? Uses the sim's Lua parser and 5.0 guard
/// (sim::lint); if that can't run, a rough line scan.
fn lua50(p: &Project, f: &std::path::Path, out: &mut Vec<Finding>) {
    let Ok(text) = std::fs::read_to_string(f) else { return };
    let name = rel(p, f);
    if let Ok(issues) = crate::sim::lint(&name, &text) {
        for i in issues {
            let at = format!("{name}:{}", i.line);
            out.push(if i.kind == "syntax" {
                Finding::error("lua.syntax", &at, format!("Lua syntax: {}", i.message))
            } else {
                Finding::warning("lua50", &at, format!("{} — the game client runs Lua 5.0", i.message))
            });
        }
        return;
    }
    lua50_scan(p, f, &text, out);
}

fn lua50_scan(p: &Project, f: &std::path::Path, text: &str, out: &mut Vec<Finding>) {
    let mut in_long = false;
    for (n, raw) in text.lines().enumerate() {
        let mut line = raw.to_string();
        if in_long {
            match line.find("]]") {
                Some(i) => { line = line[i + 2..].to_string(); in_long = false; }
                None => continue,
            }
        }
        if let Some(i) = line.find("--[[") {
            in_long = !line[i..].contains("]]");
            line.truncate(i);
        }
        if let Some(i) = line.find("--") {
            line.truncate(i);
        }
        let code = strip_strings(&line);
        let at = format!("{}:{}", rel(p, f), n + 1);
        let hint = |what: &str, use_: &str| Finding::warning("lua50", &at, format!("{what} isn't in the game's Lua 5.0: use {use_}"));
        if code.contains('#') {
            out.push(hint("the # length operator", "table.getn(t) or string.len(s)"));
        }
        if code.contains('%') {
            out.push(hint("the % operator", "math.mod(a, b)"));
        }
        if code.contains("string.match") || code.contains(":match(") {
            out.push(hint("string.match", "string.find with captures"));
        }
        if code.contains("string.gmatch") || code.contains(":gmatch(") {
            out.push(hint("string.gmatch", "string.gfind"));
        }
        if code.contains("select(") {
            out.push(hint("select()", "the arg table"));
        }
    }
}

fn strip_strings(s: &str) -> String {
    let mut out = String::new();
    let mut q: Option<char> = None;
    let mut esc = false;
    for c in s.chars() {
        match q {
            Some(qc) => {
                if esc { esc = false } else if c == '\\' { esc = true } else if c == qc { q = None }
            }
            None => {
                if c == '"' || c == '\'' { q = Some(c) } else { out.push(c) }
            }
        }
    }
    out
}

fn files(p: &Project, game: Option<&GameData>, out: &mut Vec<Finding>) {
    let entries = match collect(p) {
        Ok(e) => e,
        Err(e) => {
            out.push(Finding::error("files.clash", "", format!("{e:#}")));
            return;
        }
    };
    for e in entries.values() {
        let src = rel(p, &e.source);
        let lower = e.path.to_ascii_lowercase();
        let root = lower.split('\\').next().unwrap_or("");
        if root == "dbfilesclient" {
            out.push(Finding::error("files.dbc", &src, "client DBCs aren't shipped whole: add rows on the Data screen (data/dbc/), which ship as deltas"));
            continue;
        }
        if !ROOTS.contains(&root) {
            out.push(Finding::error("files.root", &src, format!("{} isn't a game folder packs ship into ({})", e.path, ROOTS.join(", "))));
        }
        if e.path.len() > 240 {
            out.push(Finding::error("files.path", &src, "game path longer than 240 characters"));
        }
        if e.how == How::PngToBlp {
            if let Ok((w, h)) = image::image_dimensions(&e.source) {
                if !w.is_power_of_two() || !h.is_power_of_two() || w > 1024 || h > 1024 {
                    out.push(Finding::error("art.size", &src, format!("{w}x{h}: textures must be a power of two (64, 128, 256 ...) and at most 1024")));
                }
            } else {
                out.push(Finding::error("art.png", &src, "isn't a readable PNG"));
            }
        }
        if let Some(g) = game {
            if g.contains(&e.path) {
                let same = g.read(&e.path).ok().zip(crate::build::produce(e).ok()).is_some_and(|(a, b)| a == b);
                if same {
                    out.push(Finding::error("files.stock", &src, format!("{} is the game's own file: packs ship only your work", e.path)));
                } else {
                    out.push(Finding::info("files.override", &src, format!("replaces the game's {}", e.path)));
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::{create, Template};

    fn codes(f: &[Finding]) -> Vec<String> {
        f.iter().map(|x| x.code.clone()).collect()
    }

    #[test]
    fn templates_check_clean() {
        for t in Template::ALL {
            let dir = tempfile::tempdir().unwrap();
            let p = create(dir.path().join("p"), "Clean", "Orion", t).unwrap();
            let f = run(&p, None);
            assert!(f.iter().all(|x| x.level != Level::Error), "{t:?}: {f:?}");
        }
    }

    #[test]
    fn refuses_the_games_own_files() {
        let dir = tempfile::tempdir().unwrap();
        let game = crate::vfs::GameData::open(crate::vfs::tests::fake_game(&dir.path().join("wow"))).unwrap();
        let p = create(dir.path().join("p"), "Copycat", "Orion", Template::Empty).unwrap();
        std::fs::create_dir_all(p.root.join("files/Interface/FrameXML")).unwrap();
        std::fs::write(p.root.join("files/Interface/FrameXML/Test.lua"), b"-- patched\n").unwrap();
        assert!(run(&p, Some(&game)).iter().any(|f| f.code == "files.stock" && f.level == Level::Error));
        std::fs::write(p.root.join("files/Interface/FrameXML/Test.lua"), b"-- mine\n").unwrap();
        let f = run(&p, Some(&game));
        assert!(f.iter().any(|f| f.code == "files.override" && f.level == Level::Info), "{f:?}");
        assert!(crate::build::build(&p, Some(&game)).is_ok());
    }

    #[test]
    fn catches_the_usual_mistakes() {
        let dir = tempfile::tempdir().unwrap();
        let mut p = create(dir.path().join("p"), "Broken", "", Template::Addon).unwrap();
        p.manifest.pack.version = "1.2".into();
        p.manifest.pack.license = "Proprietary".into();
        let addon = p.addons()[0].clone();
        let toc = std::fs::read_dir(&addon).unwrap().map(|e| e.unwrap().path()).find(|f| f.extension().unwrap() == "toc").unwrap();
        std::fs::write(&toc, "## Interface: 30300\n## Title: X\nCore.lua\nMissing.lua\n").unwrap();
        std::fs::write(addon.join("Core.lua"), "local n = #t -- # in a comment is fine\nlocal m = a % 2\nlocal s = \"50%\"\n").unwrap();
        std::fs::create_dir_all(p.root.join("files/DBFilesClient")).unwrap();
        std::fs::write(p.root.join("files/DBFilesClient/Spell.dbc"), b"WDBC").unwrap();
        std::fs::create_dir_all(p.root.join("files/Logs")).unwrap();
        std::fs::write(p.root.join("files/Logs/x.txt"), b"x").unwrap();
        std::fs::create_dir_all(p.root.join("art/Interface/Icons")).unwrap();
        image::RgbaImage::new(100, 64).save(p.root.join("art/Interface/Icons/Odd.png")).unwrap();
        let f = run(&p, None);
        let c = codes(&f);
        for want in ["manifest.version", "manifest.license", "addon.interface", "addon.missing", "files.dbc", "files.root", "art.size"] {
            assert!(c.contains(&want.to_string()), "expected {want} in {c:?}");
        }
        let lua: Vec<&Finding> = f.iter().filter(|x| x.code == "lua50").collect();
        assert_eq!(lua.len(), 2, "# and % in code, not in the comment or the string: {lua:?}");
    }
}
