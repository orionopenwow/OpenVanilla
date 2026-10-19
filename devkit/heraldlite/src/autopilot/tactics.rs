//! Combat and rest parameters, loaded from a JSON file (`--tactics`). Every field has a default,
//! so `{}` is a valid file. The kite fields are the ones `tools/autopilot/combat_sim.py` searches
//! (`trigger`, `cycles`, `spells`, plus `turn` and `clip_run`), so a `params` object from
//! `combat_costs.json` can be pasted into `kite` (or into a `by_level` entry) as is.

use std::collections::BTreeMap;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Tactics {
    /// "kite" (hunter: shoot, step back during reload, melee fallback), "stand" (hunter: shoot,
    /// then melee, never run) or "melee" (any class: walk in and auto-attack).
    pub strategy: String,
    pub kite: KiteParams,
    pub rest: RestParams,
    pub pull: PullParams,
    /// Item entries the bot eats / drinks when resting (first one found in the bags is used).
    pub food_items: Vec<u32>,
    pub drink_items: Vec<u32>,
    /// Loot corpses within this many yards of us.
    pub loot_radius: f32,
    /// Partial overrides by character level, merged over the rest: `{"6": {"kite": {"cycles": 1}}}`.
    pub by_level: BTreeMap<String, serde_json::Value>,
    /// Partial overrides by target creature entry, merged last (combat_sim picks per mob):
    /// `{"38": {"kite": {"cycles": 1, "trigger": 15.0}}}`.
    pub by_entry: BTreeMap<String, serde_json::Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct KiteParams {
    /// Pull distance (yd) at which we stop and open fire.
    pub open: f32,
    /// After a shot, run if the mob is closer than this (yd) ...
    pub trigger: f32,
    /// ... at most this many times per fight (then fight it out in melee).
    pub cycles: u32,
    /// Seconds spent turning back to face the mob after a run.
    pub turn: f32,
    /// Seconds to run after a Wing Clip.
    pub clip_run: f32,
    /// Run even when the mob is not slowed and not slower than us.
    pub unslowed: bool,
    /// Which abilities to use: sting, arcane, mark, conc, raptor, wingclip, monkey, hawk.
    pub spells: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct RestParams {
    /// Rest (eat, or sit) below this health fraction when out of combat.
    pub eat_below: f32,
    /// Rest (drink, or sit) below this mana fraction when out of combat.
    pub drink_below: f32,
    /// Stand up again at or above these fractions ...
    pub stand_hp: f32,
    pub stand_mana: f32,
    /// ... or after this many seconds.
    pub max_rest_s: f32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct PullParams {
    /// Look for targets this far from the step position.
    pub search_radius: f32,
    /// Skip mobs more than this many levels above us.
    pub max_level_above: u32,
    /// Give up on a target we have not hurt within this many seconds (evade, unreachable).
    pub give_up_s: f32,
}

impl Default for Tactics {
    fn default() -> Self {
        Tactics {
            strategy: "kite".into(),
            kite: KiteParams::default(),
            rest: RestParams::default(),
            pull: PullParams::default(),
            // Tough Jerky, Tough Hunk of Bread, Shiny Red Apple, Darnassian Bleu, Slitherskin
            // Mackerel, Forest Mushroom Cap, Haunch of Meat, Freshly Baked Bread, Dalaran Sharp,
            // Tel'Abim Banana, Mutton Chop, Moist Cornbread (item_template entries, classic-db).
            food_items: vec![
                117, 4540, 4536, 2070, 787, 4604, 2287, 4541, 414, 4537, 3770, 4542,
            ],
            // Refreshing Spring Water, Ice Cold Milk, Melon Juice, Sweet Nectar.
            drink_items: vec![159, 1179, 1205, 1708],
            loot_radius: 30.0,
            by_level: BTreeMap::new(),
            by_entry: BTreeMap::new(),
        }
    }
}

impl Default for KiteParams {
    fn default() -> Self {
        // combat_sim.py's most common winner for levels 1-5 (out/predictions.txt: "kite").
        KiteParams {
            open: 35.0,
            trigger: 15.0,
            cycles: 2,
            turn: 0.3,
            clip_run: 2.5,
            unslowed: false,
            spells: ["sting", "arcane", "mark", "conc", "raptor", "wingclip"]
                .map(String::from)
                .to_vec(),
        }
    }
}

impl Default for RestParams {
    fn default() -> Self {
        RestParams {
            eat_below: 0.55,
            drink_below: 0.35,
            stand_hp: 0.95,
            stand_mana: 0.9,
            max_rest_s: 45.0,
        }
    }
}

impl Default for PullParams {
    fn default() -> Self {
        PullParams {
            search_radius: 80.0,
            max_level_above: 3,
            give_up_s: 25.0,
        }
    }
}

fn merge(base: &mut serde_json::Value, over: &serde_json::Value) {
    match (base, over) {
        (serde_json::Value::Object(b), serde_json::Value::Object(o)) => {
            for (k, v) in o {
                merge(b.entry(k.clone()).or_insert(serde_json::Value::Null), v);
            }
        }
        (b, o) => *b = o.clone(),
    }
}

impl Tactics {
    pub fn load(path: &std::path::Path) -> Result<Tactics> {
        let text = std::fs::read_to_string(path)
            .with_context(|| format!("reading tactics {}", path.display()))?;
        Self::parse(&text).with_context(|| format!("parsing tactics {}", path.display()))
    }

    pub fn parse(text: &str) -> Result<Tactics> {
        let t: Tactics = serde_json::from_str(text)?;
        if !["kite", "stand", "melee"].contains(&t.strategy.as_str()) {
            anyhow::bail!(
                "strategy must be kite, stand or melee, not {:?}",
                t.strategy
            );
        }
        // Validate every override now rather than mid-run.
        for lvl in t.by_level.keys() {
            let n: u32 = lvl
                .parse()
                .with_context(|| format!("by_level key {lvl:?} is not a level"))?;
            t.for_level(n)?;
        }
        for e in t.by_entry.keys() {
            let n: u32 = e
                .parse()
                .with_context(|| format!("by_entry key {e:?} is not a creature entry"))?;
            t.for_fight(1, n)?;
        }
        Ok(t)
    }

    /// [`Self::for_level`], then the `by_entry` override for the target.
    pub fn for_fight(&self, level: u32, entry: u32) -> Result<Tactics> {
        let t = self.for_level(level)?;
        let Some(o) = self.by_entry.get(&entry.to_string()) else {
            return Ok(t);
        };
        let mut v = serde_json::to_value(&t)?;
        merge(&mut v, o);
        let mut out: Tactics = serde_json::from_value(v)?;
        out.by_level = self.by_level.clone();
        out.by_entry = self.by_entry.clone();
        Ok(out)
    }

    /// These tactics with the `by_level` overrides for levels <= `level` applied in order.
    pub fn for_level(&self, level: u32) -> Result<Tactics> {
        let mut levels: Vec<(u32, &serde_json::Value)> = self
            .by_level
            .iter()
            .filter_map(|(k, v)| k.parse::<u32>().ok().map(|n| (n, v)))
            .filter(|(n, _)| *n <= level)
            .collect();
        if levels.is_empty() {
            return Ok(self.clone());
        }
        levels.sort_by_key(|(n, _)| *n);
        let mut v = serde_json::to_value(self)?;
        for (_, o) in levels {
            merge(&mut v, o);
        }
        let mut t: Tactics = serde_json::from_value(v)?;
        t.by_level = self.by_level.clone();
        t.by_entry = self.by_entry.clone();
        Ok(t)
    }

    pub fn uses(&self, spell: &str) -> bool {
        self.kite.spells.iter().any(|s| s == spell)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_file_is_all_defaults() {
        let t = Tactics::parse("{}").unwrap();
        assert_eq!(t, Tactics::default());
        assert_eq!(t.kite.trigger, 15.0);
        assert!(t.uses("raptor"));
    }

    #[test]
    fn combat_costs_params_paste_in_and_levels_override() {
        let t = Tactics::parse(
            r#"{"kite": {"cycles": 3, "spells": ["sting","arcane","mark","conc","raptor","wingclip"], "trigger": 20.0},
                "by_level": {"4": {"kite": {"cycles": 1}}, "6": {"strategy": "stand"}}}"#,
        )
        .unwrap();
        assert_eq!(t.kite.cycles, 3);
        assert_eq!(t.kite.trigger, 20.0);
        let l5 = t.for_level(5).unwrap();
        assert_eq!(l5.kite.cycles, 1);
        assert_eq!(l5.kite.trigger, 20.0, "untouched fields stay");
        assert_eq!(l5.strategy, "kite");
        assert_eq!(t.for_level(7).unwrap().strategy, "stand");
        assert_eq!(t.for_level(2).unwrap().kite.cycles, 3);
    }

    #[test]
    fn per_mob_overrides_apply_last() {
        let t = Tactics::parse(
            r#"{"kite": {"cycles": 3, "trigger": 20.0}, "by_level": {"4": {"kite": {"cycles": 2}}},
                "by_entry": {"38": {"kite": {"cycles": 1, "trigger": 15.0}}}}"#,
        )
        .unwrap();
        let thug = t.for_fight(4, 38).unwrap();
        assert_eq!((thug.kite.cycles, thug.kite.trigger), (1, 15.0));
        let vermin = t.for_fight(4, 6).unwrap();
        assert_eq!((vermin.kite.cycles, vermin.kite.trigger), (2, 20.0));
        assert!(Tactics::parse(r#"{"by_entry": {"kobold": {}}}"#).is_err());
    }

    #[test]
    fn the_shipped_tactics_files_parse() {
        for f in ["tactics_hunter.json", "tactics_melee.json"] {
            let p = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("autopilot")
                .join(f);
            Tactics::load(&p).unwrap_or_else(|e| panic!("{f}: {e:#}"));
        }
    }

    #[test]
    fn bad_values_are_rejected_up_front() {
        assert!(Tactics::parse(r#"{"strategy": "dance"}"#).is_err());
        assert!(Tactics::parse(r#"{"by_level": {"x": {}}}"#).is_err());
        assert!(Tactics::parse(r#"{"by_level": {"3": {"kite": {"cycles": "many"}}}}"#).is_err());
    }
}
