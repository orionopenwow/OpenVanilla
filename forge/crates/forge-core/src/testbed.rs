//! Forge's own test copies of the game and of Play Solo, so Test & Play never writes into the
//! creator's real game folder or their Play Solo realm.
//!
//! * **The test client** sits beside the game folder (`<game> (Forge test)`, or in Forge's config
//!   folder when that isn't writable). Big files (the game's archives, the exe) are hard links:
//!   no extra disk space, and the game only ever reads them. Small files (settings, addons) are
//!   copies, so whatever the test game writes stays in the copy. Each sync follows the real game
//!   (a patched archive is linked again) and never touches Forge's own files in the copy.
//! * **The test realm** is a copy of Play Solo (`<Forge config>/test-solo`): the server programs
//!   and maps linked the same way, the database copied once (so your solo characters come along,
//!   and what testing does to them stays in the copy). Forge's DBC and map changes replace the
//!   copy's links with files of their own; the real realm's files are never written.

use anyhow::{bail, Context, Result};
use std::path::{Path, PathBuf};

/// Files this big or bigger are linked; smaller ones are copied.
const LINK_FROM: u64 = 4 << 20;

#[cfg(test)]
thread_local! {
    static OVERRIDE: std::cell::RefCell<(Option<PathBuf>, Option<PathBuf>)> = const { std::cell::RefCell::new((None, None)) };
}

/// Tests: where this thread's test copies go (tests run side by side).
#[cfg(test)]
pub fn override_dirs(client: Option<PathBuf>, solo: Option<PathBuf>) {
    OVERRIDE.with(|o| *o.borrow_mut() = (client, solo));
}

/// The client folder for a game path (also when the game path is its Data folder).
pub fn client_root(game: &Path) -> PathBuf {
    let is_data = game.file_name().is_some_and(|n| n.to_string_lossy().eq_ignore_ascii_case("data"));
    if is_data && !game.join("Data").is_dir() {
        game.parent().map(Path::to_path_buf).unwrap_or_else(|| game.to_path_buf())
    } else {
        game.to_path_buf()
    }
}

fn writable(dir: &Path) -> bool {
    let probe = dir.join(".forge-write-test");
    let ok = std::fs::write(&probe, b"ok").is_ok();
    let _ = std::fs::remove_file(&probe);
    ok
}

/// Where the test client goes for this game: beside it (same drive, so the links work), or in
/// Forge's config folder.
pub fn client_dir(game: &Path) -> PathBuf {
    #[cfg(test)]
    if let Some(d) = OVERRIDE.with(|o| o.borrow().0.clone()) {
        return d;
    }
    if let Ok(d) = std::env::var("FORGE_TEST_CLIENT") {
        return PathBuf::from(d);
    }
    let root = client_root(game);
    let fallback = crate::config::config_dir().join("test-client");
    let (Some(parent), Some(name)) = (root.parent(), root.file_name()) else { return fallback };
    let beside = parent.join(format!("{} (Forge test)", name.to_string_lossy()));
    // already made: keep using it (no probing the drive on every look)
    if beside.is_dir() {
        return beside;
    }
    if fallback.is_dir() || !writable(parent) {
        return fallback;
    }
    beside
}

/// Where the test realm goes.
pub fn solo_dir() -> PathBuf {
    #[cfg(test)]
    if let Some(d) = OVERRIDE.with(|o| o.borrow().1.clone()) {
        return d;
    }
    if let Ok(d) = std::env::var("FORGE_TEST_SOLO") {
        return PathBuf::from(d);
    }
    crate::config::config_dir().join("test-solo")
}

/// Whether `inner` is inside (or is) `outer`.
fn within(inner: &Path, outer: &Path) -> bool {
    let (a, b) = (inner.canonicalize().unwrap_or_else(|_| inner.to_path_buf()), outer.canonicalize().unwrap_or_else(|_| outer.to_path_buf()));
    a.starts_with(&b)
}

#[derive(Debug, Default, Clone, serde::Serialize)]
pub struct Synced {
    pub linked: usize,
    pub copied: usize,
    pub copied_bytes: u64,
    pub removed: usize,
}

/// How a file of the source is mirrored.
#[derive(PartialEq)]
enum How {
    Skip,
    /// Copied when the copy doesn't have it yet (the test game or realm writes it after).
    Seed,
    /// Linked when big, else copied; again when the source changes.
    Follow,
}

/// Put `src`'s file `rel` into `dst`: a hard link when big (falling back to a copy), else a copy.
fn put(src: &Path, dst: &Path, len: u64, out: &mut Synced) -> Result<()> {
    if let Some(p) = dst.parent() {
        std::fs::create_dir_all(p)?;
    }
    // never write through an old link into the source: take the old entry away first
    let _ = std::fs::remove_file(dst);
    if len >= LINK_FROM && std::fs::hard_link(src, dst).is_ok() {
        out.linked += 1;
        return Ok(());
    }
    std::fs::copy(src, dst).with_context(|| format!("copying {} for testing", src.display()))?;
    out.copied += 1;
    out.copied_bytes += len;
    Ok(())
}

fn same(a: &std::fs::Metadata, b: &std::fs::Metadata) -> bool {
    a.len() == b.len() && a.modified().ok() <= b.modified().ok()
}

/// Mirror `src` into `dst` by `how(relative path, is_dir)`. Entries `dst` has that `src` doesn't
/// are left alone unless `prune` says they may go.
fn mirror(src: &Path, dst: &Path, how: &dyn Fn(&Path, bool) -> How, prune: &dyn Fn(&Path) -> bool, out: &mut Synced) -> Result<()> {
    if within(dst, src) {
        bail!("the test copy can't be inside the folder it copies ({})", src.display());
    }
    let mut seen = std::collections::HashSet::new();
    let mut stack = vec![PathBuf::new()];
    while let Some(rel) = stack.pop() {
        for e in std::fs::read_dir(src.join(&rel)).with_context(|| format!("reading {}", src.join(&rel).display()))?.flatten() {
            let r = rel.join(e.file_name());
            let meta = std::fs::metadata(e.path()); // follows junctions and links
            let Ok(meta) = meta else { continue };
            let h = how(&r, meta.is_dir());
            if h == How::Skip {
                continue;
            }
            seen.insert(r.to_string_lossy().to_lowercase());
            if meta.is_dir() {
                std::fs::create_dir_all(dst.join(&r))?;
                stack.push(r);
                continue;
            }
            let d = dst.join(&r);
            match std::fs::metadata(&d) {
                Ok(_) if h == How::Seed => {}
                Ok(dm) if same(&meta, &dm) => {}
                _ => put(&e.path(), &d, meta.len(), out)?,
            }
        }
    }
    // what the source no longer has
    let mut stack = vec![PathBuf::new()];
    while let Some(rel) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(dst.join(&rel)) else { continue };
        for e in rd.flatten() {
            let r = rel.join(e.file_name());
            let is_dir = e.file_type().map(|t| t.is_dir()).unwrap_or(false);
            if seen.contains(&r.to_string_lossy().to_lowercase()) {
                if is_dir {
                    stack.push(r);
                }
                continue;
            }
            if how(&r, is_dir) == How::Follow && prune(&r) {
                if is_dir {
                    let _ = std::fs::remove_dir_all(e.path());
                } else {
                    let _ = std::fs::remove_file(e.path());
                }
                out.removed += 1;
            }
        }
    }
    Ok(())
}

fn first(rel: &Path) -> String {
    rel.components().next().map(|c| c.as_os_str().to_string_lossy().to_lowercase()).unwrap_or_default()
}

/// The test client: the game, mirrored. Forge's own files in it (the dev archive, its marker,
/// test addons) are kept; what the game writes (settings, caches) stays in the copy.
pub fn sync_client(game: &Path) -> Result<(PathBuf, Synced)> {
    let src = client_root(game);
    let dst = client_dir(game);
    std::fs::create_dir_all(&dst).with_context(|| format!("making the test copy of your game at {}", dst.display()))?;
    let mut out = Synced::default();
    let how = |rel: &Path, _dir: bool| -> How {
        let top = first(rel);
        let name = rel.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
        if ["wdb", "cache", "logs", "errors", "screenshots"].contains(&top.as_str()) || name.ends_with(" (forge test)") {
            return How::Skip;
        }
        // an older Forge's test files in the real game: not copied
        if name == crate::play::DEV_ARCHIVE.to_lowercase() || name == "forge-dev.json" {
            return How::Skip;
        }
        if top == "wtf" || name == "realmlist.wtf" || (top == "interface" && rel.components().count() >= 3) {
            return How::Seed;
        }
        How::Follow
    };
    let prune = |rel: &Path| -> bool {
        let name = rel.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default();
        name != crate::play::DEV_ARCHIVE.to_lowercase() && name != "forge-dev.json"
    };
    mirror(&src, &dst, &how, &prune, &mut out)?;
    pin_local(&dst)?;
    Ok((dst, out))
}

/// The address every test copy of the game signs in to: this PC (Forge's test realm). A pack being
/// tested never reaches Open Vanilla's realms or anyone else's server, even when the copy is
/// started by hand.
pub const TEST_REALMLIST: &str = "set realmlist 127.0.0.1";

/// Point the test copy at this PC: its realmlist.wtf files say 127.0.0.1 (Play Solo's own start
/// puts in its port for the session and back to this after), and Config.wtf names no other realm.
pub fn pin_local(copy: &Path) -> Result<()> {
    let mut lists = vec![copy.join("realmlist.wtf")];
    for d in std::fs::read_dir(copy.join("Data")).into_iter().flatten().flatten() {
        let f = d.path().join("realmlist.wtf");
        if f.is_file() {
            lists.push(f);
        }
    }
    for f in lists {
        let now = std::fs::read_to_string(&f).unwrap_or_default();
        let local = now.lines().filter(|l| !l.trim().is_empty()).all(|l| {
            let l = l.trim().to_ascii_lowercase();
            l.starts_with("set realmlist 127.0.0.1") || l.starts_with("set realmlist localhost") || !l.starts_with("set realmlist")
        }) && now.to_ascii_lowercase().contains("set realmlist");
        if !local {
            write_own(&f, format!("{TEST_REALMLIST}\r\n").as_bytes())?;
        }
    }
    let cfg = copy.join("WTF").join("Config.wtf");
    if let Ok(text) = std::fs::read_to_string(&cfg) {
        let keep: Vec<&str> = text.lines().filter(|l| !l.trim_start().to_ascii_lowercase().starts_with("set realmlist")).collect();
        if keep.len() != text.lines().count() {
            write_own(&cfg, (keep.join("\r\n") + "\r\n").as_bytes())?;
        }
    }
    Ok(())
}

/// The test realm: Play Solo, mirrored. The database is copied the first time only (from then on
/// it's the test realm's own); the real realm must be stopped for that copy.
pub fn sync_solo(real: &Path, solo_running: bool) -> Result<(PathBuf, Synced)> {
    let dst = solo_dir();
    let fresh = !dst.join("state.json").is_file();
    if fresh && solo_running {
        bail!("Play Solo is running: stop it (close the game, or 'Play Solo.bat' solo-stop) so Forge can make its test realm from a quiet copy, then try again.");
    }
    std::fs::create_dir_all(&dst)?;
    let mut out = Synced::default();
    let how = |rel: &Path, _dir: bool| -> How {
        let top = first(rel);
        if ["logs", "download", "forge-dev"].contains(&top.as_str()) || rel == Path::new("run.json") {
            return How::Skip;
        }
        // the test realm's own from the first copy on: its database, settings and passwords
        if top == "data" || rel == Path::new("state.json") || top == "etc" {
            return How::Seed;
        }
        // the server's data: Forge writes some of these (DBCs, map tiles) in the copy
        if top == "gamedata" {
            return How::Seed;
        }
        How::Follow
    };
    mirror(real, &dst, &how, &|_| false, &mut out)?;
    Ok((dst, out))
}

/// Write `bytes` to `path` in a test copy, first taking away whatever is there (it may be a link
/// into the real folder, which must never be written through).
pub fn write_own(path: &Path, bytes: &[u8]) -> Result<()> {
    let _ = std::fs::remove_file(path);
    std::fs::write(path, bytes)?;
    Ok(())
}

/// Copy `from` to `to` in a test copy, the same way.
pub fn copy_own(from: &Path, to: &Path) -> Result<()> {
    let bytes = std::fs::read(from)?;
    write_own(to, &bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_real_game_is_never_written() {
        let dir = tempfile::tempdir().unwrap();
        let game = dir.path().join("Game");
        std::fs::create_dir_all(game.join("Data")).unwrap();
        std::fs::create_dir_all(game.join("WTF")).unwrap();
        std::fs::create_dir_all(game.join("Interface/AddOns/Theirs")).unwrap();
        let big = vec![7u8; (LINK_FROM + 10) as usize];
        std::fs::write(game.join("Data/base.MPQ"), &big).unwrap();
        std::fs::write(game.join("WoW.exe"), b"exe").unwrap();
        std::fs::write(game.join("WTF/Config.wtf"), b"SET a 1").unwrap();
        std::fs::write(game.join("Interface/AddOns/Theirs/Theirs.toc"), b"toc").unwrap();
        std::fs::write(game.join("Data/patch-~.MPQ"), b"an old forge archive").unwrap();
        override_dirs(Some(dir.path().join("TestCopy")), None);
        let (copy, s) = sync_client(&game).unwrap();
        assert_eq!(copy, dir.path().join("TestCopy"));
        assert!(s.linked + s.copied >= 4, "{s:?}");
        assert!(!copy.join("Data/patch-~.MPQ").exists(), "an old test archive isn't carried over");
        // the test writes in its copy: the real game's files stay as they were
        write_own(&copy.join("Data/base.MPQ"), b"changed").unwrap();
        std::fs::write(copy.join("WTF/Config.wtf"), b"SET a 2").unwrap();
        std::fs::write(copy.join("Data/patch-~.MPQ"), b"the pack").unwrap();
        assert_eq!(std::fs::read(game.join("Data/base.MPQ")).unwrap(), big);
        assert_eq!(std::fs::read(game.join("WTF/Config.wtf")).unwrap(), b"SET a 1");
        assert_eq!(std::fs::read(game.join("Data/patch-~.MPQ")).unwrap(), b"an old forge archive");
        // a second sync: the game's archive comes back (as the real one), the copy's settings and Forge's archive stay
        sync_client(&game).unwrap();
        assert_eq!(std::fs::read(copy.join("Data/base.MPQ")).unwrap(), big);
        assert_eq!(std::fs::read(copy.join("WTF/Config.wtf")).unwrap(), b"SET a 2");
        assert_eq!(std::fs::read(copy.join("Data/patch-~.MPQ")).unwrap(), b"the pack");
        assert!(mirror(&game, &game.join("Data"), &|_, _| How::Follow, &|_| false, &mut Synced::default()).is_err(), "never inside the source");
    }

    #[test]
    fn the_test_copy_only_signs_in_on_this_pc() {
        let dir = tempfile::tempdir().unwrap();
        let game = dir.path().join("Game");
        std::fs::create_dir_all(game.join("Data/enUS")).unwrap();
        std::fs::create_dir_all(game.join("WTF")).unwrap();
        std::fs::write(game.join("WoW.exe"), b"exe").unwrap();
        std::fs::write(game.join("realmlist.wtf"), b"set realmlist play.openvanilla.app\r\n").unwrap();
        std::fs::write(game.join("Data/enUS/realmlist.wtf"), b"set realmlist logon.example.org\r\n").unwrap();
        std::fs::write(game.join("WTF/Config.wtf"), b"SET realmList \"play.openvanilla.app\"\r\nSET gxResolution \"1024x768\"\r\n").unwrap();
        override_dirs(Some(dir.path().join("TestCopy")), None);
        let (copy, _) = sync_client(&game).unwrap();
        assert_eq!(std::fs::read_to_string(copy.join("realmlist.wtf")).unwrap().trim(), TEST_REALMLIST);
        assert_eq!(std::fs::read_to_string(copy.join("Data/enUS/realmlist.wtf")).unwrap().trim(), TEST_REALMLIST);
        let cfg = std::fs::read_to_string(copy.join("WTF/Config.wtf")).unwrap();
        assert!(!cfg.to_lowercase().contains("realmlist") && cfg.contains("gxResolution"), "{cfg}");
        // the real game keeps its own realm
        assert_eq!(std::fs::read_to_string(game.join("realmlist.wtf")).unwrap(), "set realmlist play.openvanilla.app\r\n");
        assert!(std::fs::read_to_string(game.join("WTF/Config.wtf")).unwrap().contains("play.openvanilla.app"));
        // a copy someone pointed elsewhere goes back to this PC on the next test
        std::fs::write(copy.join("realmlist.wtf"), b"set realmlist play.openvanilla.app").unwrap();
        sync_client(&game).unwrap();
        assert_eq!(std::fs::read_to_string(copy.join("realmlist.wtf")).unwrap().trim(), TEST_REALMLIST);
        // Play Solo's own session line (with its port) is left alone
        std::fs::write(copy.join("realmlist.wtf"), b"set realmlist 127.0.0.1:3725").unwrap();
        sync_client(&game).unwrap();
        assert_eq!(std::fs::read_to_string(copy.join("realmlist.wtf")).unwrap(), "set realmlist 127.0.0.1:3725");
    }
}
