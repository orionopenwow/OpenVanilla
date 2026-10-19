//! "Fix it" for Check findings that have one safe answer: Forge changes the file, the creator
//! sees the result in the next Check. Everything else gets a "Go there" in the app instead.

use crate::project::Project;
use anyhow::{bail, Context, Result};

/// Codes Forge can fix by itself.
pub const FIXABLE: &[&str] = &["addon.interface", "addon.title", "credits.missing", "manifest.version"];

pub fn fix(p: &mut Project, code: &str, path: &str) -> Result<String> {
    match code {
        "addon.interface" | "addon.title" => {
            let file = p.root.join(path);
            if file.extension().and_then(|e| e.to_str()).map(|e| !e.eq_ignore_ascii_case("toc")).unwrap_or(true) || !file.starts_with(&p.root) {
                bail!("that isn't an addon's .toc");
            }
            let text = std::fs::read_to_string(&file).context("can't read the .toc")?;
            let crlf = text.contains("\r\n");
            let mut lines: Vec<String> = text.lines().map(str::to_string).collect();
            let (tag, value) = if code == "addon.interface" {
                ("Interface", "11200".to_string())
            } else {
                ("Title", file.file_stem().and_then(|s| s.to_str()).unwrap_or("Addon").to_string())
            };
            let at = lines.iter().position(|l| l.trim_start().trim_start_matches('#').trim_start().to_ascii_lowercase().starts_with(&format!("{}:", tag.to_ascii_lowercase())) && l.trim_start().starts_with("##"));
            let line = format!("## {tag}: {value}");
            match at {
                Some(i) => lines[i] = line,
                None => lines.insert(0, line),
            }
            let mut out = lines.join(if crlf { "\r\n" } else { "\n" });
            out.push_str(if crlf { "\r\n" } else { "\n" });
            std::fs::write(&file, out)?;
            Ok(format!("{path}: ## {tag}: {value}"))
        }
        "credits.missing" => {
            let f = p.root.join("credits.toml");
            if f.exists() {
                bail!("credits.toml is already there");
            }
            std::fs::write(&f, "# Every asset in this pack you didn't make yourself: where it's from, who made it, its licence.\n# [[asset]]\n# file = \"models/Dragon/source.glb\"\n# author = \"Someone\"\n# source = \"https://…\"\n# license = \"CC-BY-4.0\"\n")?;
            Ok("Made credits.toml (empty: add a line for anything you didn't make yourself)".into())
        }
        "manifest.version" => {
            p.manifest.pack.version = "0.1.0".into();
            p.save()?;
            Ok("Version set to 0.1.0".into())
        }
        _ => bail!("Forge has no fix for {code}: use Go there"),
    }
}

/// The screen a finding belongs to, for "Go there".
pub fn screen(code: &str) -> &'static str {
    let head = code.split('.').next().unwrap_or("");
    match head {
        "addon" | "lua" | "lua50" => "code",
        "data" | "ids" => "data",
        "world" => "world",
        "models" => "models",
        "art" | "files" | "build" => "project",
        "publish" => "publish",
        _ => "project",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::{create, Template};

    #[test]
    fn fixes_a_toc_and_the_credits() {
        let dir = tempfile::tempdir().unwrap();
        let mut p = create(dir.path().join("p"), "Fix Pack", "Me", Template::Addon).unwrap();
        let toc = crate::check::run(&p, None).len();
        let addon = p.addons()[0].clone();
        let name = addon.file_name().unwrap().to_string_lossy().to_string();
        let rel = format!("addons/{name}/{name}.toc");
        std::fs::write(p.root.join(&rel), "## Interface: 11300\r\n## Notes: x\r\nCore.lua\r\n").unwrap();
        assert!(crate::check::run(&p, None).iter().any(|f| f.code == "addon.interface"));
        fix(&mut p, "addon.interface", &rel).unwrap();
        fix(&mut p, "addon.title", &rel).unwrap();
        let t = std::fs::read_to_string(p.root.join(&rel)).unwrap();
        assert!(t.starts_with("## Title: ") && t.contains("## Interface: 11200\r\n") && !t.contains("11300"), "{t}");
        assert!(!crate::check::run(&p, None).iter().any(|f| f.code == "addon.interface" || f.code == "addon.title"));
        std::fs::remove_file(p.root.join("credits.toml")).unwrap();
        fix(&mut p, "credits.missing", "credits.toml").unwrap();
        assert!(!crate::check::run(&p, None).iter().any(|f| f.code.starts_with("credits")));
        assert!(fix(&mut p, "addon.interface", "forge.toml").is_err());
        let _ = toc;
        assert_eq!(screen("data.range"), "data");
    }
}
