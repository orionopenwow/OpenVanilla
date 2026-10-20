//! Per-user settings: where the creator's 1.12 game is, and the projects they opened lately.
//! Stored as `forge/config.toml` under the user's config folder (%APPDATA% on Windows).

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct Config {
    /// The 1.12.1 game folder (the one holding `Data\` and `WoW.exe`).
    pub game_dir: Option<PathBuf>,
    /// Most recent first.
    #[serde(default)]
    pub recent: Vec<PathBuf>,
    /// The Python that runs the Model Porter ("py -3", "python3", a full path). None: found on PATH.
    #[serde(default)]
    pub python: Option<String>,
    /// The Open Vanilla folder (play_local.py, solo\): where Test & Play finds the solo realm.
    /// None: the game folder, if it is one.
    #[serde(default)]
    pub openvanilla_dir: Option<PathBuf>,
}

pub fn config_dir() -> PathBuf {
    if let Ok(d) = std::env::var("FORGE_CONFIG_DIR") {
        return PathBuf::from(d);
    }
    #[cfg(windows)]
    if let Ok(a) = std::env::var("APPDATA") {
        return PathBuf::from(a).join("OpenVanilla").join("Forge");
    }
    if let Ok(x) = std::env::var("XDG_CONFIG_HOME") {
        return PathBuf::from(x).join("openvanilla-forge");
    }
    let home = std::env::var("HOME").or_else(|_| std::env::var("USERPROFILE")).unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join(".config").join("openvanilla-forge")
}

impl Config {
    pub fn path() -> PathBuf {
        config_dir().join("config.toml")
    }

    pub fn load() -> Config {
        std::fs::read_to_string(Self::path()).ok().and_then(|t| toml::from_str(&t).ok()).unwrap_or_default()
    }

    pub fn save(&self) -> anyhow::Result<()> {
        let p = Self::path();
        if let Some(d) = p.parent() {
            std::fs::create_dir_all(d)?;
        }
        std::fs::write(p, toml::to_string_pretty(self)?)?;
        Ok(())
    }

    /// Put a project at the top of the recent list (at most 12 kept).
    pub fn touch_recent(&mut self, dir: &Path) {
        let dir = dir.canonicalize().unwrap_or_else(|_| dir.to_path_buf());
        self.recent.retain(|p| p != &dir);
        self.recent.insert(0, dir);
        self.recent.truncate(12);
    }
}
