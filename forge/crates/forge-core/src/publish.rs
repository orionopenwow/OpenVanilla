//! Publish (plan §5.6, §6.8, §7): the release build of a pack, held to stricter rules than a
//! test build, packed into one signed file for the Workshop's review queue.
//!
//! ```text
//! build/publish/<pack>-<version>.ovpack     (a zip)
//!   forge.toml  credits.toml  README.md
//!   patch-<pack>.MPQ  manifest.json  report.json
//!   server/sql/install.sql  server/sql/rollback.sql
//!   data/dbc/<Table>.json                   DBC row deltas (never whole tables)
//!   data/world/<Map>.json                   doodads placed on the stock tiles
//!   data/terrain/<Map>/<A>_<B>.hd|.chunks.json   terrain edits (heights; textures, holes, areas)
//!   SIGNATURE.json                          Ed25519 over the contents digest
//! ```
//!
//! The signature is the creator's own key (`creator_ed25519.key` in Forge's config folder, made
//! on first use, never uploaded); the Workshop pins the public key to their account. The
//! contents digest is SHA-256 over the sorted `path sha256` lines of every other file, so a
//! reviewer (or `tools/forge_verify.py`) can check nothing changed after signing.

use crate::build;
use crate::check::{Finding, Level};
use crate::project::Project;
use crate::vfs::GameData;
use anyhow::{bail, Context, Result};
use ed25519_dalek::{Signer, SigningKey, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

pub const FORMAT: &str = "openvanilla-forge-pack/1";
const SIGNED_PREFIX: &[u8] = b"openvanilla-forge-pack/1\n";

/// SHA-256 (not BLAKE3) so the Workshop can check a package with the standard library alone.
fn sha256(b: &[u8]) -> String {
    use sha2::Digest;
    hex::encode(sha2::Sha256::digest(b))
}

/// The creator's signing key: made once, kept in Forge's config folder.
pub fn creator_key() -> Result<SigningKey> {
    let path = crate::config::config_dir().join("creator_ed25519.key");
    if let Ok(t) = std::fs::read_to_string(&path) {
        let b = hex::decode(t.trim()).context("creator_ed25519.key is damaged")?;
        let seed: [u8; 32] = b.try_into().map_err(|_| anyhow::anyhow!("creator_ed25519.key is damaged"))?;
        return Ok(SigningKey::from_bytes(&seed));
    }
    let k = SigningKey::generate(&mut rand_core::OsRng);
    std::fs::create_dir_all(path.parent().unwrap())?;
    std::fs::write(&path, hex::encode(k.to_bytes()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(k)
}

pub fn public_key_hex() -> Result<String> {
    Ok(hex::encode(creator_key()?.verifying_key().to_bytes()))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Signature {
    pub format: String,
    pub pack: String,
    pub version: String,
    pub build_hash: String,
    /// SHA-256 over the sorted "path sha256" lines (joined by \n) of every other file.
    pub contents: String,
    pub public_key: String,
    pub signature: String,
}

/// The rules a published pack must pass on top of the build's checks.
pub fn gate(p: &Project, game: Option<&GameData>) -> Vec<Finding> {
    let mut out = vec![];
    if game.is_none() {
        out.push(Finding::error("publish.game", "", "Set your game folder first: Publish checks that the pack ships none of the game's own files."));
    }
    for f in crate::check::run(p, game) {
        // what a test build lets through, a published pack may not
        if f.code == "models.retail" || f.code == "models.unported" || f.code == "credits.missing" || f.code == "manifest.authors" {
            out.push(Finding::error(&f.code, &f.path, f.message.clone()));
        } else {
            out.push(f);
        }
    }
    if p.manifest.pack.description.trim().is_empty() {
        out.push(Finding::warning("publish.description", "forge.toml", "no description: the Workshop page will be empty"));
    }
    if let Ok(t) = std::fs::read_to_string(p.root.join("credits.toml")) {
        // every model needs a line in the credits (its maker, even if that's you)
        for m in crate::model::names(p) {
            if !t.to_ascii_lowercase().contains(&m.to_ascii_lowercase()) {
                out.push(Finding::error("publish.credits", "credits.toml", format!("credits.toml doesn't mention model {m}: say who made it and under what licence")));
            }
        }
    }
    out
}

fn add_file(zw: &mut zip::ZipWriter<std::fs::File>, name: &str, bytes: &[u8], lines: &mut Vec<String>) -> Result<()> {
    let opts = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated)
        .last_modified_time(zip::DateTime::default()); // fixed: the same pack zips to the same bytes
    zw.start_file(name, opts)?;
    zw.write_all(bytes)?;
    lines.push(format!("{name} {}", sha256(bytes)));
    Ok(())
}

#[derive(Debug, Serialize)]
pub struct Published {
    pub package: PathBuf,
    pub bytes: u64,
    pub signature: Signature,
    pub findings: Vec<Finding>,
    pub contents: Vec<String>,
}

/// Gate, release build, package, sign.
pub fn package(p: &Project, game: Option<&GameData>) -> Result<Published> {
    let findings = gate(p, game);
    let errors: Vec<&Finding> = findings.iter().filter(|f| f.level == Level::Error).collect();
    if !errors.is_empty() {
        bail!("{} thing(s) to fix before publishing; first: {}", errors.len(), errors[0].message);
    }
    let report = build::build_with(p, game, false)?;
    let out_dir = p.build_dir().join("publish");
    std::fs::create_dir_all(&out_dir)?;
    let pack = &p.manifest.pack;
    let path = out_dir.join(format!("{}-{}.ovpack", pack.id, pack.version));
    let mut zw = zip::ZipWriter::new(std::fs::File::create(&path)?);
    let mut lines = vec![];
    let mut files: Vec<(String, PathBuf)> = vec![];
    for n in ["forge.toml", "credits.toml", "README.md", "LICENSE", "CHANGELOG.md"] {
        if p.root.join(n).is_file() {
            files.push((n.to_string(), p.root.join(n)));
        }
    }
    let b = p.build_dir();
    for n in ["manifest.json", "report.json"] {
        files.push((n.to_string(), b.join(n)));
    }
    if !report.mpq.is_empty() {
        files.push((report.mpq.clone(), b.join(&report.mpq)));
    }
    // server SQL, DBC deltas, doodad placements (data/world) and terrain edits (data/terrain/<Map>/)
    for sub in ["server/sql", "data"] {
        let d = b.join(sub);
        if d.is_dir() {
            for f in walkdir::WalkDir::new(&d).sort_by_file_name().into_iter().filter_map(|e| e.ok()).filter(|e| e.file_type().is_file()) {
                let rel = f.path().strip_prefix(&b)?.to_string_lossy().replace('\\', "/");
                files.push((rel, f.path().to_path_buf()));
            }
        }
    }
    files.sort_by(|a, b| a.0.cmp(&b.0));
    for (name, f) in &files {
        add_file(&mut zw, name, &std::fs::read(f).with_context(|| format!("reading {}", f.display()))?, &mut lines)?;
    }
    lines.sort();
    let contents = sha256(lines.join("\n").as_bytes());
    let key = creator_key()?;
    let sig = key.sign(&[SIGNED_PREFIX, contents.as_bytes()].concat());
    let signature = Signature {
        format: FORMAT.into(),
        pack: pack.id.clone(),
        version: pack.version.clone(),
        build_hash: report.build_hash.clone(),
        contents,
        public_key: hex::encode(key.verifying_key().to_bytes()),
        signature: hex::encode(sig.to_bytes()),
    };
    let mut ignore = vec![];
    add_file(&mut zw, "SIGNATURE.json", &serde_json::to_vec_pretty(&signature)?, &mut ignore)?;
    zw.finish()?;
    Ok(Published { bytes: std::fs::metadata(&path)?.len(), package: path, signature, findings, contents: files.into_iter().map(|f| f.0).collect() })
}

/// Check a package: every file matches the signed digest and the signature is good.
pub fn verify(package: &Path) -> Result<Signature> {
    let mut z = zip::ZipArchive::new(std::fs::File::open(package)?)?;
    let mut lines = vec![];
    let mut sig: Option<Signature> = None;
    for i in 0..z.len() {
        let mut f = z.by_index(i)?;
        let name = f.name().to_string();
        let mut b = vec![];
        f.read_to_end(&mut b)?;
        if name == "SIGNATURE.json" {
            sig = Some(serde_json::from_slice(&b)?);
        } else {
            lines.push(format!("{name} {}", sha256(&b)));
        }
    }
    let sig = sig.context("no SIGNATURE.json")?;
    lines.sort();
    let digest = sha256(lines.join("\n").as_bytes());
    if digest != sig.contents {
        bail!("the package's files changed after it was signed");
    }
    let pk: [u8; 32] = hex::decode(&sig.public_key)?.try_into().map_err(|_| anyhow::anyhow!("bad public key"))?;
    let sb: [u8; 64] = hex::decode(&sig.signature)?.try_into().map_err(|_| anyhow::anyhow!("bad signature"))?;
    VerifyingKey::from_bytes(&pk)?
        .verify(&[SIGNED_PREFIX, digest.as_bytes()].concat(), &ed25519_dalek::Signature::from_bytes(&sb))
        .map_err(|_| anyhow::anyhow!("the signature doesn't match"))?;
    Ok(sig)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::{create, Template};

    #[test]
    fn package_signs_and_verifies_and_tampering_shows() {
        let dir = tempfile::tempdir().unwrap();
        crate::test_config();
        let game = crate::vfs::tests::fake_game(&dir.path().join("wow"));
        let g = GameData::open(&game).unwrap();
        let p = create(dir.path().join("p"), "Pub Pack", "Orion", Template::Pack).unwrap();
        // a terrain edit (an area id) ships in the package, where the realm build reads it
        let t = p.root.join("maps/Azeroth/terrain");
        std::fs::create_dir_all(&t).unwrap();
        std::fs::write(t.join("32_48.chunks.json"), r#"{"3_4":{"area":87}}"#).unwrap();
        let r = package(&p, Some(&g)).unwrap();
        assert!(r.contents.iter().any(|c| c == "patch-pub-pack.MPQ"));
        assert!(r.contents.iter().any(|c| c == "data/terrain/Azeroth/32_48.chunks.json"), "{:?}", r.contents);
        let s = verify(&r.package).unwrap();
        assert_eq!(s.pack, "pub-pack");
        assert_eq!(s.public_key, public_key_hex().unwrap(), "the same key every time");
        // the same project packs to the same bytes
        let first = std::fs::read(&r.package).unwrap();
        let again = package(&p, Some(&g)).unwrap();
        assert_eq!(std::fs::read(&again.package).unwrap(), first);
        // tamper: rewrite one file inside the zip
        let mut src = zip::ZipArchive::new(std::fs::File::open(&r.package).unwrap()).unwrap();
        let bad = dir.path().join("bad.ovpack");
        let mut zw = zip::ZipWriter::new(std::fs::File::create(&bad).unwrap());
        for i in 0..src.len() {
            let mut f = src.by_index(i).unwrap();
            let name = f.name().to_string();
            let mut b = vec![];
            f.read_to_end(&mut b).unwrap();
            if name == "forge.toml" {
                b.extend_from_slice(b"\n# changed\n");
            }
            zw.start_file(name, zip::write::SimpleFileOptions::default()).unwrap();
            zw.write_all(&b).unwrap();
        }
        zw.finish().unwrap();
        assert!(verify(&bad).unwrap_err().to_string().contains("changed after"));
    }

    #[test]
    fn the_gate_is_stricter_than_a_build() {
        let dir = tempfile::tempdir().unwrap();
        crate::test_config();
        let p = create(dir.path().join("p"), "Gate Pack", "", Template::Addon).unwrap();
        std::fs::remove_file(p.root.join("credits.toml")).unwrap();
        let f = gate(&p, None);
        for want in ["publish.game", "credits.missing", "manifest.authors"] {
            assert!(f.iter().any(|x| x.code == want && x.level == Level::Error), "{want}: {f:?}");
        }
        assert!(package(&p, None).is_err());
    }
}
