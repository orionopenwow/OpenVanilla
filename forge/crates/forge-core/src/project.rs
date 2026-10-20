//! A Forge project: a plain folder (meant to be a git repo) with a `forge.toml` at its root.
//!
//! ```text
//! MyPack/
//!   forge.toml          id, name, version, authors, licence, targets, depends
//!   credits.toml        every third-party asset: source, author, licence
//!   README.md
//!   addons/<Name>/      .toc .lua .xml, exactly as shipped (-> Interface\AddOns\<Name>\)
//!   art/<game path>.png source images; built to <game path>.blp (BLP2, DXT1 or DXT5)
//!   files/<game path>   any other file, shipped as-is at that game path
//!   .forge/ids.lock     the IDs this pack has allocated, per table
//!   build/              output (git-ignored)
//! ```
//! Later phases add `models/`, `data/`, `maps/`, `scripts/`, `sounds/`, `server/` (see the plan).

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub const MANIFEST: &str = "forge.toml";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Manifest {
    pub pack: Pack,
    #[serde(default)]
    pub targets: Targets,
    /// Other packs this one needs, e.g. `["classicplus >=1.30"]`.
    #[serde(default)]
    pub depends: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Pack {
    /// Lowercase slug: letters, digits and dashes (`emberwing-mounts`).
    pub id: String,
    pub name: String,
    /// Semver (`1.2.0`).
    pub version: String,
    #[serde(default)]
    pub authors: Vec<String>,
    /// SPDX identifier (`MIT`, `CC-BY-4.0`, ...).
    pub license: String,
    #[serde(default)]
    pub description: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Targets {
    /// Realms the pack is meant for (`classicplus`, `warfront`, `community`).
    #[serde(default)]
    pub realms: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct Project {
    pub root: PathBuf,
    pub manifest: Manifest,
}

impl Project {
    pub fn open(dir: impl AsRef<Path>) -> Result<Project> {
        let root = dir.as_ref().to_path_buf();
        let path = root.join(MANIFEST);
        let text = std::fs::read_to_string(&path).with_context(|| format!("no {} in {}", MANIFEST, root.display()))?;
        let manifest: Manifest = toml::from_str(&text).with_context(|| format!("{} is not valid", path.display()))?;
        Ok(Project { root, manifest })
    }

    pub fn save(&self) -> Result<()> {
        std::fs::write(self.root.join(MANIFEST), toml::to_string_pretty(&self.manifest)?)?;
        Ok(())
    }

    pub fn build_dir(&self) -> PathBuf {
        self.root.join("build")
    }

    /// The addon folders under `addons/`.
    pub fn addons(&self) -> Vec<PathBuf> {
        let mut out: Vec<PathBuf> = std::fs::read_dir(self.root.join("addons"))
            .map(|rd| rd.filter_map(|e| e.ok()).map(|e| e.path()).filter(|p| p.is_dir()).collect())
            .unwrap_or_default();
        out.sort();
        out
    }
}

/// What `forge new` can start from. Every template builds and checks clean as made.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Template {
    /// One addon that says hello and opens a small window (`/hello`).
    Addon,
    /// A content pack: an icon (art), a loose file, room for models and data later.
    Pack,
    /// Only `forge.toml`, `credits.toml` and a README.
    Empty,
}

impl Template {
    pub fn parse(s: &str) -> Option<Template> {
        match s.to_ascii_lowercase().as_str() {
            "addon" => Some(Template::Addon),
            "pack" | "content" => Some(Template::Pack),
            "empty" => Some(Template::Empty),
            _ => None,
        }
    }
    pub const ALL: [Template; 3] = [Template::Addon, Template::Pack, Template::Empty];
    pub fn label(self) -> &'static str {
        match self {
            Template::Addon => "Addon",
            Template::Pack => "Content pack",
            Template::Empty => "Empty project",
        }
    }
}

/// `My Cool Pack` -> `my-cool-pack`.
pub fn slug(name: &str) -> String {
    let mut s = String::new();
    for c in name.chars() {
        if c.is_ascii_alphanumeric() {
            s.push(c.to_ascii_lowercase());
        } else if !s.ends_with('-') && !s.is_empty() {
            s.push('-');
        }
    }
    s.trim_end_matches('-').to_string()
}

/// `my-cool-pack` -> `MyCoolPack` (an addon folder name).
fn camel(id: &str) -> String {
    id.split('-').filter(|w| !w.is_empty()).map(|w| {
        let mut c = w.chars();
        match c.next() {
            Some(f) => f.to_ascii_uppercase().to_string() + c.as_str(),
            None => String::new(),
        }
    }).collect()
}

/// Make a new project in `dir` (created; must be empty or missing).
pub fn create(dir: impl AsRef<Path>, name: &str, author: &str, template: Template) -> Result<Project> {
    let root = dir.as_ref().to_path_buf();
    if root.exists() && std::fs::read_dir(&root)?.next().is_some() {
        bail!("{} is not empty", root.display());
    }
    let id = slug(name);
    if id.is_empty() {
        bail!("give the project a name with letters or digits");
    }
    std::fs::create_dir_all(&root)?;
    let manifest = Manifest {
        pack: Pack {
            id: id.clone(),
            name: name.to_string(),
            version: "0.1.0".into(),
            authors: if author.is_empty() { vec![] } else { vec![author.to_string()] },
            license: "MIT".into(),
            description: String::new(),
        },
        targets: Targets { realms: vec!["classicplus".into()] },
        depends: vec![],
    };
    let p = Project { root: root.clone(), manifest };
    p.save()?;
    std::fs::write(root.join("credits.toml"), CREDITS)?;
    std::fs::write(root.join(".gitignore"), "build/\n.forge/undo/\n")?;
    std::fs::write(root.join("README.md"), format!("# {name}\n\nMade with Vanilla Forge.\n"))?;
    match template {
        Template::Empty => {}
        Template::Addon => {
            let addon = camel(&id);
            let d = root.join("addons").join(&addon);
            std::fs::create_dir_all(&d)?;
            std::fs::write(d.join(format!("{addon}.toc")), format!(
                "## Interface: 11200\n## Title: {name}\n## Notes: Made with Vanilla Forge.\n## Author: {author}\n## Version: 0.1.0\n## SavedVariables: {addon}DB\n\nCore.lua\n"))?;
            std::fs::write(d.join("Core.lua"), HELLO_LUA.replace("{{ADDON}}", &addon).replace("{{NAME}}", name))?;
        }
        Template::Pack => {
            let art = root.join("art").join("Interface").join("Icons");
            std::fs::create_dir_all(&art)?;
            std::fs::write(art.join(format!("INV_{}.png", camel(&id))), sample_icon_png()?)?;
            let files = root.join("files").join("Interface").join("AddOns").join(camel(&id));
            std::fs::create_dir_all(&files)?;
            std::fs::write(files.join("readme.txt"), format!("{name}: files under files/ ship at the same game path.\n"))?;
            for d in ["models", "data"] {
                std::fs::create_dir_all(root.join(d))?;
                std::fs::write(root.join(d).join(".keep"), "")?;
            }
        }
    }
    Ok(p)
}

const CREDITS: &str = r#"# Every file in this pack that you did not make yourself, with where it came from and its licence.
# The Workshop review checks this. Your own work needs no entry.
#
# [[asset]]
# path = "art/Interface/Icons/INV_Example.png"
# source = "https://example.com/my-icon"
# author = "Someone"
# license = "CC-BY-4.0"
"#;

const HELLO_LUA: &str = r#"-- {{NAME}}: made with Vanilla Forge. Lua 5.0 rules (1.12): no #, no %, use this/arg1 in scripts.
{{ADDON}}DB = {{ADDON}}DB or { opened = 0 }

local f = CreateFrame("Frame", "{{ADDON}}Frame", UIParent)
f:SetWidth(240)
f:SetHeight(90)
f:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
f:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 24,
    insets = { left = 7, right = 7, top = 7, bottom = 7 } })
f:EnableMouse(true)
f:Hide()
local text = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
text:SetPoint("CENTER", f, "CENTER", 0, 0)

SLASH_{{ADDON}}1 = "/hello"
SlashCmdList["{{ADDON}}"] = function()
    {{ADDON}}DB.opened = {{ADDON}}DB.opened + 1
    text:SetText("Hello, " .. (UnitName("player") or "adventurer") .. "!\nOpened " .. {{ADDON}}DB.opened .. " times.")
    if f:IsShown() then f:Hide() else f:Show() end
end

DEFAULT_CHAT_FRAME:AddMessage("{{NAME}} loaded: type /hello")
"#;

/// A 64x64 placeholder icon: a gold ring on dark stone (made here, so the template ships no one's art).
fn sample_icon_png() -> Result<Vec<u8>> {
    let mut img = image::RgbaImage::new(64, 64);
    for (x, y, p) in img.enumerate_pixels_mut() {
        let dx = x as f32 - 31.5;
        let dy = y as f32 - 31.5;
        let d = (dx * dx + dy * dy).sqrt();
        let base = 30 + ((x * 7 + y * 13) % 11) as u8;
        *p = if (18.0..24.0).contains(&d) {
            image::Rgba([230, 186, 80, 255])
        } else if d < 18.0 {
            image::Rgba([base + 40, base + 20, base + 70, 255])
        } else {
            image::Rgba([base, base, base + 4, 255])
        };
    }
    let mut out = std::io::Cursor::new(Vec::new());
    img.write_to(&mut out, image::ImageFormat::Png)?;
    Ok(out.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugs_and_names() {
        assert_eq!(slug("Emberwing Mounts!"), "emberwing-mounts");
        assert_eq!(slug("  CP  Raid -- Frames "), "cp-raid-frames");
        assert_eq!(camel("emberwing-mounts"), "EmberwingMounts");
    }

    #[test]
    fn every_template_creates_and_reopens() {
        for t in Template::ALL {
            let dir = tempfile::tempdir().unwrap();
            let root = dir.path().join("p");
            let p = create(&root, "My Test Pack", "Orion", t).unwrap();
            let q = Project::open(&root).unwrap();
            assert_eq!(p.manifest.pack.id, "my-test-pack");
            assert_eq!(q.manifest.pack.version, "0.1.0");
            assert!(create(&root, "Again", "", t).is_err(), "a folder with files is refused");
        }
    }
}
