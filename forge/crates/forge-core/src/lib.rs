//! Vanilla Forge core: everything the app and the `forge` command line share.
//!
//! * [`project`]  a Forge project on disk (`forge.toml`, the folder layout, templates)
//! * [`ids`]      per-pack ID ranges and the allocator (`.forge/ids.lock`)
//! * [`check`]    the checks every build runs (and Publish requires)
//! * [`vfs`]      the creator's own 1.12 game data (their MPQs), read-only
//! * [`build`]    a project -> `build/` (a patch MPQ, loose files, manifest, report)
//! * [`config`]   per-user settings (game folder, recent projects)
//!
//! Forge never ships Blizzard's files: it reads the creator's own install for context, and a
//! build refuses any file that is byte-identical to one in it (see `check`).

pub mod adt;
pub mod api;
pub mod behaviour;
pub mod build;
pub mod fixes;
pub mod check;
pub mod chunkclip;
pub mod config;
pub mod data;
pub mod gridmap;
pub mod ids;
pub mod kit;
pub mod light;
pub mod livelink;
pub mod minimap;
pub mod model;
pub mod mpqw;
pub mod play;
pub mod sim;
pub mod testbed;
pub mod thumbs;
pub mod trueview;
pub mod usage;
pub mod project;
pub mod sample;
pub mod publish;
pub mod realm;
pub mod vfs;
pub mod vmap;
pub mod wizards;
pub mod world;

pub use check::{Finding, Level};
pub use project::Project;

/// Game paths are case-insensitive and use backslashes in MPQs; Forge stores them that way.
pub fn game_path(p: &str) -> String {
    p.replace('/', "\\")
}

/// Tests share one config folder (set once: tests run in parallel, and the environment is
/// process-wide).
#[cfg(test)]
pub(crate) fn test_config() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| std::env::set_var("FORGE_CONFIG_DIR", std::env::temp_dir().join(format!("forge-test-cfg-{}", std::process::id()))));
}
