//! Per-pack ID ranges. Every row a pack adds (a creature, an item, a display, a spell ...) takes an
//! ID from the pack's own range for that table, so two packs never collide and a realm can merge
//! them. The ranges and what has been handed out live in `.forge/ids.lock` (commit it).
//!
//! Until the Workshop's registry hands out ranges (plan, Phase 2), a new pack takes a **local**
//! range: a block of `BLOCK` IDs per table inside the table's community area, picked from the
//! pack id so two packs on one machine rarely overlap. The blocks Open Vanilla's own content
//! already uses (Classic+, Warfront, the Model Porter's bases) are reserved and never handed out.

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub const LOCK: &str = ".forge/ids.lock";
pub const BLOCK: u32 = 1000;

/// A table Forge allocates IDs for: where community packs take their blocks from.
pub struct TableSpec {
    pub table: &'static str,
    pub what: &'static str,
    /// The community area: [start, end).
    pub area: (u32, u32),
}

/// The tables Phase 0/1 allocates for. The areas stay clear of every stock 1.12 ID and of the
/// reserved blocks below, and inside what the client and server fields can hold.
pub const TABLES: &[TableSpec] = &[
    TableSpec { table: "creature_template", what: "creature (NPC) entry", area: (1_100_000, 2_100_000) },
    TableSpec { table: "item_template", what: "item entry", area: (1_100_000, 2_100_000) },
    TableSpec { table: "quest_template", what: "quest ID", area: (110_000, 210_000) },
    TableSpec { table: "gameobject_template", what: "gameobject entry", area: (1_100_000, 2_100_000) },
    TableSpec { table: "CreatureDisplayInfo", what: "creature display", area: (40_000, 60_000) },
    TableSpec { table: "CreatureModelData", what: "creature model", area: (5_000, 9_000) },
    TableSpec { table: "ItemDisplayInfo", what: "item display", area: (60_000, 90_000) },
    TableSpec { table: "Spell", what: "spell ID", area: (60_000, 90_000) },
    TableSpec { table: "SpellIcon", what: "spell icon", area: (5_000, 9_000) },
    TableSpec { table: "creature", what: "creature spawn (guid)", area: (5_000_000, 6_000_000) },
    TableSpec { table: "gameobject", what: "object spawn (guid)", area: (5_000_000, 6_000_000) },
    TableSpec { table: "npc_text", what: "NPC gossip text", area: (200_000, 300_000) },
    TableSpec { table: "MDDF", what: "doodad placement (unique id)", area: (40_000_000, 41_000_000) },
    // gossip_menu.entry is a smallint: room for 25 local blocks until the registry hands them out
    TableSpec { table: "gossip_menu", what: "gossip menu", area: (40_000, 65_000) },
    // new maps and zones (small tables: small blocks, see `block_size`)
    TableSpec { table: "Map", what: "map ID", area: (800, 1_000) },
    TableSpec { table: "AreaTable", what: "area (zone) ID", area: (6_000, 9_000) },
    TableSpec { table: "AreaTrigger", what: "area trigger", area: (10_000, 15_000) },
    TableSpec { table: "LoadingScreens", what: "loading screen", area: (500, 700) },
    // an area's explore bit: the server keeps 64 × 32 of them per character
    TableSpec { table: "AreaBit", what: "area explore bit", area: (1_800, 2_048) },
    TableSpec { table: "game_tele", what: "teleport name (.tele)", area: (10_000, 60_000) },
    // Behaviour Studio: lines creatures say (custom_texts entries are negative: −2,100,000 and down)
    TableSpec { table: "custom_texts", what: "creature line (say/yell)", area: (2_100_000, 3_000_000) },
    TableSpec { table: "game_event", what: "world event", area: (1_000, 6_000) },
    // lights: their weathers' bands take IDs from the weather's (×18, ×6): stock ends near 430
    TableSpec { table: "Light", what: "light", area: (2_000, 3_000) },
    TableSpec { table: "LightParams", what: "light weather", area: (1_000, 1_400) },
];

/// IDs in one local block: BLOCK, or fewer for the small tables.
pub fn block_size(table: &str) -> u32 {
    match table {
        "Map" | "LoadingScreens" => 10,
        "AreaTable" | "AreaTrigger" => 50,
        "AreaBit" => 8,
        "game_event" => 50,
        "Light" | "LightParams" => 50,
        _ => BLOCK,
    }
}

/// Blocks Open Vanilla's own content holds (Model Porter bases in content/models/registry.json,
/// Classic+ and Warfront SQL). Never handed to a pack.
pub const RESERVED: &[(&str, u32, u32, &str)] = &[
    ("creature_template", 990_000, 1_000_000, "Classic+ / Warfront NPCs and Model Porter creatures"),
    ("item_template", 990_000, 1_000_000, "Classic+ items and Model Porter reins"),
    ("CreatureDisplayInfo", 20_000, 21_000, "Model Porter displays"),
    ("CreatureModelData", 3_000, 4_000, "Model Porter models"),
    ("Spell", 40_000, 41_000, "Model Porter mount spells"),
];

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Range {
    pub start: u32,
    /// Exclusive.
    pub end: u32,
    /// The next ID to hand out.
    pub next: u32,
    /// Where the range came from: "local" (picked on this machine) or "workshop" (registered).
    #[serde(default = "local")]
    pub source: String,
}

fn local() -> String {
    "local".into()
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct IdLock {
    #[serde(default)]
    pub tables: BTreeMap<String, Range>,
    /// What each handed-out ID is for (`"creature_template:1100003" = "Emberwing Drake"`).
    #[serde(default)]
    pub names: BTreeMap<String, String>,
}

pub fn spec(table: &str) -> Option<&'static TableSpec> {
    TABLES.iter().find(|t| t.table.eq_ignore_ascii_case(table))
}

fn lock_path(root: &Path) -> PathBuf {
    root.join(LOCK)
}

impl IdLock {
    pub fn load(root: &Path) -> Result<IdLock> {
        match std::fs::read_to_string(lock_path(root)) {
            Ok(t) => toml::from_str(&t).context("ids.lock is not valid"),
            Err(_) => Ok(IdLock::default()),
        }
    }

    pub fn save(&self, root: &Path) -> Result<()> {
        let p = lock_path(root);
        std::fs::create_dir_all(p.parent().unwrap())?;
        std::fs::write(p, toml::to_string_pretty(self)?)?;
        Ok(())
    }

    /// The pack's range for a table, picking a local one the first time.
    pub fn range(&mut self, pack_id: &str, table: &str) -> Result<Range> {
        let s = spec(table).with_context(|| format!("Forge doesn't allocate IDs for {table} (yet)"))?;
        if let Some(r) = self.tables.get(s.table) {
            return Ok(r.clone());
        }
        let r = pick_block(pack_id, s);
        self.tables.insert(s.table.to_string(), r.clone());
        Ok(r)
    }

    /// Hand out the next ID for a table.
    pub fn allocate(&mut self, pack_id: &str, table: &str, name: &str) -> Result<u32> {
        let s = spec(table).with_context(|| format!("Forge doesn't allocate IDs for {table} (yet)"))?;
        self.range(pack_id, table)?;
        let r = self.tables.get_mut(s.table).unwrap();
        if r.next >= r.end {
            bail!("the pack's {} range {}..{} is used up", s.table, r.start, r.end);
        }
        let id = r.next;
        r.next += 1;
        if !name.is_empty() {
            self.names.insert(format!("{}:{}", s.table, id), name.to_string());
        }
        Ok(id)
    }

    /// Is this ID inside the pack's range for the table?
    pub fn owns(&self, table: &str, id: u32) -> bool {
        spec(table)
            .and_then(|s| self.tables.get(s.table))
            .is_some_and(|r| id >= r.start && id < r.end)
    }
}

/// A block of BLOCK IDs in the table's community area, chosen from a hash of the pack id, moved
/// off any reserved block.
fn pick_block(pack_id: &str, s: &TableSpec) -> Range {
    let size = block_size(s.table);
    let blocks = (s.area.1 - s.area.0) / size;
    let h = blake3::hash(format!("{}:{}", pack_id, s.table).as_bytes());
    let mut n = u32::from_le_bytes(h.as_bytes()[..4].try_into().unwrap()) % blocks;
    loop {
        let start = s.area.0 + n * size;
        let end = start + size;
        let clash = RESERVED.iter().any(|(t, a, b, _)| t.eq_ignore_ascii_case(s.table) && start < *b && *a < end);
        if !clash {
            return Range { start, end, next: start, source: local() };
        }
        n = (n + 1) % blocks;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allocates_in_order_inside_the_pack_range_and_persists() {
        let dir = tempfile::tempdir().unwrap();
        let mut l = IdLock::load(dir.path()).unwrap();
        let a = l.allocate("emberwing", "creature_template", "Emberwing Drake").unwrap();
        let b = l.allocate("emberwing", "creature_template", "").unwrap();
        assert_eq!(b, a + 1);
        assert!(l.owns("creature_template", a));
        assert!(!l.owns("creature_template", 12));
        l.save(dir.path()).unwrap();
        let mut back = IdLock::load(dir.path()).unwrap();
        assert_eq!(back.allocate("emberwing", "creature_template", "").unwrap(), b + 1, "continues after a reload");
        assert_eq!(back.names.get(&format!("creature_template:{a}")).unwrap(), "Emberwing Drake");
    }

    #[test]
    fn ranges_avoid_reserved_blocks_and_stay_in_the_area() {
        for pack in ["a", "b", "emberwing", "classicplus", "x-y-z", "warfront"] {
            for s in TABLES {
                let r = pick_block(pack, s);
                assert!(r.start >= s.area.0 && r.end <= s.area.1, "{pack} {}", s.table);
                for (t, a, b, _) in RESERVED {
                    if t.eq_ignore_ascii_case(s.table) {
                        assert!(r.end <= *a || r.start >= *b, "{pack} {} overlaps reserved", s.table);
                    }
                }
            }
        }
    }

    #[test]
    fn unknown_tables_and_used_up_ranges_are_refused() {
        let mut l = IdLock::default();
        assert!(l.allocate("p", "realmd_account", "").is_err());
        l.range("p", "Spell").unwrap();
        l.tables.get_mut("Spell").unwrap().next = l.tables["Spell"].end;
        assert!(l.allocate("p", "Spell", "").is_err());
    }
}
