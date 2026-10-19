//! The sample project: Ember Isle, made in one go with Forge's own tools, so a new creator opens
//! something finished and changes it rather than starting from nothing. A small island map with a
//! volcano, a road, trees and a camp from the creator's own game, two creatures (a whelp with a
//! fight plan and a ferrymaster with dialogue and a quest), spawns, a patrol and a ferry back to
//! the mainland. Pieces the creator's game doesn't have (a tree, a texture) are left out.

use crate::adt;
use crate::behaviour::{self, Behaviour, Card, Choice, Dialogue, Do, Page, Point, When};
use crate::data::{self, Dbc};
use crate::kit::{self, Scatter};
use crate::project::{create, Project, Template};
use crate::vfs::GameData;
use crate::wizards::{self, CreatureSpec, Pair, QuestSpec};
use crate::world::{self, Placement};
use anyhow::{Context, Result};
use serde_json::json;
use std::path::Path;

/// A CreatureDisplayInfo whose model's path has `needle` in it (the first plain one).
fn display_for(g: &GameData, needle: &str) -> Option<i64> {
    let md = Dbc::parse(&g.read("DBFilesClient\\CreatureModelData.dbc").ok()?).ok()?;
    let di = Dbc::parse(&g.read("DBFilesClient\\CreatureDisplayInfo.dbc").ok()?).ok()?;
    let n = needle.to_ascii_lowercase();
    let models: Vec<u32> = md.records.iter().filter(|r| md.string(r[2]).to_ascii_lowercase().contains(&n)).map(|r| r[0]).collect();
    di.records.iter().find(|r| models.contains(&r[1]) && r.get(3) == Some(&0)).or_else(|| di.records.iter().find(|r| models.contains(&r[1]))).map(|r| r[0] as i64)
}

/// The first of these doodads the game has (tile names, `.mdx`).
fn have(p: &Project, g: &GameData, names: &[&str]) -> Vec<String> {
    names
        .iter()
        .filter(|n| {
            let m2 = format!("{}.m2", &n[..n.len() - 4]);
            world::has_world(p, g, &m2)
        })
        .map(|s| s.to_string())
        .collect()
}

pub fn create_sample(parent: &Path, g: &GameData) -> Result<Project> {
    let mut dir = parent.join("Ember Isle (sample)");
    let mut k = 2;
    while dir.exists() {
        dir = parent.join(format!("Ember Isle (sample {k})"));
        k += 1;
    }
    let mut p = create(&dir, "Ember Isle", "Vanilla Forge sample", Template::Pack)?;
    p.manifest.pack.description = "A sample from Vanilla Forge: a volcano island with a whelp that fights back, a ferrymaster with a quest, and a ferry home.".into();
    p.save()?;
    let p = p;
    let grass = ["Tileset\\Elwynn\\ElwynnGrassBase.blp", "Tileset\\Elwynn\\ElwynnGrass01.blp"].into_iter().find(|t| world::has_world(&p, g, t)).unwrap_or("Tileset\\Elwynn\\ElwynnGrassBase.blp");
    let m = world::new_map(&p, g, &serde_json::from_value(json!({"name": "Ember Isle", "size": 1, "height": -14.0, "texture": grass}))?)?;
    let map = m["map"].as_str().unwrap_or("EmberIsle").to_string();
    let (a, b) = (m["tiles"][0][0].as_i64().unwrap_or(32) as i32, m["tiles"][0][1].as_i64().unwrap_or(32) as i32);
    let tile = adt::TILE;
    // tile-local (u, v) yards → world (x, y)
    let w = |u: f64, v: f64| (adt::HALF - (b as f64 * tile + v), adt::HALF - (a as f64 * tile + u));
    // the island in one pass: a rolling oval of land, a volcano cone with a crater
    let (x0, z0) = (a as f64 * tile, b as f64 * tile);
    kit::reshape_tile(&p, g, &map, a, b, &|fx, fz, _| {
        let (u, v) = (fx - x0, fz - z0);
        let d = (((u - 266.0) / 190.0).powi(2) + ((v - 280.0) / 165.0).powi(2)).sqrt();
        let land = (1.0 - d).clamp(0.0, 1.0);
        let land = land * land * (3.0 - 2.0 * land);
        let roll = (u * 0.031).sin() * (v * 0.027).cos() * 4.0 + (u * 0.011 + v * 0.017).sin() * 3.0;
        let r = (u - 300.0).hypot(v - 220.0);
        let cone = (1.0 - r / 75.0).max(0.0).powf(1.6) * 48.0;
        let crater = (1.0 - r / 17.0).max(0.0) * 14.0;
        Some(-14.0 + land * (30.0 + roll) + cone - crater)
    })?;
    let ground = |u: f64, v: f64| -> f64 {
        let (x, y) = w(u, v);
        let f = adt::to_file(x, y, 0.0);
        world::current_tile(&p, g, &map, a, b).ok().and_then(|(t, _)| t.height_at((a, b), f[0] as f64, f[2] as f64)).unwrap_or(0.0)
    };
    // paint
    for (u, v, r, tex) in [(300.0, 220.0, 70.0, "ElwynnRockBase"), (300.0, 220.0, 40.0, "ElwynnRockBase"), (150.0, 240.0, 40.0, "ElwynnFlowerBase"), (380.0, 350.0, 40.0, "ElwynnFlowerBase")] {
        let t = format!("Tileset\\Elwynn\\{tex}.blp");
        if world::has_world(&p, g, &t) {
            let (x, y) = w(u, v);
            world::paint(&p, g, &map, x, y, r, 1.0, &t)?;
        }
    }
    // the sea all round, and magma in the crater
    for u in (60..533).step_by(150) {
        for v in (60..533).step_by(150) {
            let (x, y) = w(u as f64, v as f64);
            world::water(&p, g, &map, x, y, 115.0, 0.0, "ocean", false)?;
        }
    }
    let crater = ground(300.0, 220.0);
    let (x, y) = w(300.0, 220.0);
    world::water(&p, g, &map, x, y, 16.0, crater + 5.0, "magma", false)?;
    // a road from the landing to the volcano
    let dirt = ["Tileset\\Elwynn\\ElwynnDirtBase2.blp", "Tileset\\Elwynn\\ElwynnDirtBase.blp"].into_iter().find(|t| world::has_world(&p, g, t)).unwrap_or("");
    let road: Vec<[f64; 2]> = [(160.0, 345.0), (215.0, 315.0), (262.0, 282.0), (285.0, 245.0)].iter().map(|(u, v)| { let (x, y) = w(*u, *v); [x, y] }).collect();
    kit::road(&p, g, &kit::Road { map: map.clone(), points: road, width: 6.0, texture: dirt.into(), smooth: true })?;
    // trees and a camp, from the game's own doodads
    let trees = have(&p, g, &[
        "World\\Azeroth\\Elwynn\\PassiveDoodads\\Trees\\ElwynnTreeCanopy01.mdx",
        "World\\Azeroth\\Elwynn\\PassiveDoodads\\Trees\\ElwynnTreeCanopy02.mdx",
        "World\\Azeroth\\Elwynn\\PassiveDoodads\\Trees\\ElwynnTreeCanopy03.mdx",
        "World\\Azeroth\\Elwynn\\PassiveDoodads\\Trees\\ElwynnTreeMid01.mdx",
        "World\\Generic\\Tree01.mdx",
    ]);
    let mut notes = vec![];
    if !trees.is_empty() {
        for (u, v) in [(160.0, 250.0), (360.0, 360.0), (230.0, 380.0)] {
            let (x, y) = w(u, v);
            kit::scatter(&p, g, &Scatter { map: map.clone(), x, y, radius: 45.0, models: trees.clone(), count: 7, spacing: 12.0, size: [0.7, 1.0], max_slope: 30.0, seed: (u * v) as u64 })?;
        }
    } else {
        notes.push("no Elwynn trees in your game: the island has none".to_string());
    }
    let camp = have(&p, g, &[
        "World\\Generic\\PassiveDoodads\\Barrel\\Barrel01.mdx",
        "World\\Generic\\PassiveDoodads\\Crate01\\Crate01.mdx",
        "World\\Generic\\PassiveDoodads\\Crate02\\Crate02.mdx",
        "World\\Azeroth\\Westfall\\PassiveDoodads\\Barrel\\WestfallBarrel01.mdx",
    ]);
    if !camp.is_empty() {
        for (i, (du, dv)) in [(0.0, 0.0), (3.0, 1.5), (-2.0, 3.0), (1.0, -3.0)].iter().enumerate() {
            let (x, y) = w(175.0 + du, 335.0 + dv);
            world::place(&p, Some(g), &map, Placement { model: camp[i % camp.len()].clone(), x, y, z: 0.0, turn: (i * 47) as f64, scale: 1.0, uid: 0, wmo_box: None, tilt: [0.0; 2], set: 0 }, true)?;
        }
        let (c1, c2) = (w(165.0, 325.0), w(185.0, 345.0));
        kit::capture(&p, g, &map, "Supply camp", [c1.0, c1.1], [c2.0, c2.1])?;
    }
    // creatures
    let whelp_look = display_for(g, "whelp").or_else(|| display_for(g, "dragon")).unwrap_or(1);
    let whelp = wizards::creature(&p, &CreatureSpec { name: "Ember Whelp".into(), display: whelp_look, min_level: 8, max_level: 9, attitude: "hostile".into(), scale: 1.0, health: 1.0, damage: 1.0, ..Default::default() })?.id;
    let human = display_for(g, "humanmale").or_else(|| display_for(g, "human")).unwrap_or(whelp_look);
    let ferry = wizards::creature(&p, &CreatureSpec { name: "Ferrymaster Hale".into(), subname: "Ember Isle Ferry".into(), display: human, min_level: 20, max_level: 20, attitude: "friendly".into(), scale: 1.0, health: 1.0, damage: 1.0, ..Default::default() })?.id;
    behaviour::save_behaviour(&p, &Behaviour {
        entry: whelp,
        cards: vec![
            Card { when: When::Aggro, actions: vec![Do::Say { text: "%s screeches and spits embers!".into(), style: "emote".into() }], chance: 50, phase: None, note: String::new() },
            Card { when: When::CombatTimer { first: [4.0, 6.0], every: [9.0, 12.0] }, actions: vec![Do::Cast { spell: 133, target: "victim".into(), interrupt: false, triggered: false }], chance: 100, phase: None, note: String::new() },
            Card { when: When::HealthBelow { below: 20, every: [0.0, 0.0] }, actions: vec![Do::Flee], chance: 100, phase: None, note: String::new() },
        ],
    })?;
    behaviour::save_dialogue(&p, &Dialogue {
        entry: ferry,
        pages: vec![
            Page { key: "hello".into(), text: "Mind the embers, $N. The isle's been restless since the whelps came.".into(), choices: vec![Choice { text: "What happened here?".into(), to: "story".into() }, Choice { text: "Take me back to the mainland.".into(), to: "close".into() }] },
            Page { key: "story".into(), text: "Something stirs under the volcano. The whelps hatched in the crater, and now they own the island.".into(), choices: vec![Choice { text: "I'll see to them.".into(), to: "close".into() }] },
        ],
    })?;
    wizards::quest(&p, &QuestSpec {
        title: "Embers on the Wind".into(),
        level: 9,
        min_level: 6,
        giver: ferry,
        details: "Those whelps have run of the isle, $N. Thin them out before they burn my ferry to the waterline.".into(),
        objectives: "Kill 6 Ember Whelps on Ember Isle, then return to Ferrymaster Hale.".into(),
        reward_text: "You smell of smoke. Good work.".into(),
        kill: vec![Pair { id: whelp, count: 6 }],
        money: 250,
        ..Default::default()
    })?;
    // spawns: whelps near the crater, one on patrol; the ferrymaster at the landing
    let mid = world::map_id(&p, &map).context("the new map")?;
    let pos = |u: f64, v: f64, o: f64| {
        let (x, y) = w(u, v);
        data::Pos { map: mid, x, y, z: ground(u, v) + 0.2, o }
    };
    let mut patrol = 0;
    for (i, (u, v)) in [(275.0, 250.0), (320.0, 255.0), (255.0, 225.0), (330.0, 200.0), (290.0, 270.0)].iter().enumerate() {
        let g2 = data::add_spawn(&p, whelp, pos(*u, *v, i as f64), 120, if i == 0 { 0.0 } else { 8.0 })?;
        if i == 0 {
            patrol = g2;
        }
    }
    let pts: Vec<Point> = [(275.0, 250.0), (262.0, 282.0), (215.0, 315.0), (262.0, 282.0)]
        .iter()
        .map(|(u, v)| {
            let (x, y) = w(*u, *v);
            Point { x, y, z: ground(*u, *v) + 0.2, wait: 2.0 }
        })
        .collect();
    behaviour::save_path(&p, &behaviour::Path { guid: patrol as i64, points: pts })?;
    data::add_spawn(&p, ferry, pos(150.0, 350.0, 2.4), 60, 0.0)?;
    // the ferry home
    let (x, y) = w(140.0, 362.0);
    world::add_portal(&p, &serde_json::from_value(json!({"name": "Ferry to the mainland", "from": {"map": map, "x": x, "y": y, "z": ground(140.0, 362.0)}, "to": {"map": "Azeroth", "x": -9464.8, "y": 62.1, "z": 56.7, "o": 0}, "radius": 6}))?)?;
    std::fs::write(
        p.root.join("README.md"),
        format!(
            "# Ember Isle (sample)\n\nMade by Vanilla Forge as a sample: a small island map, a creature with a fight plan, a ferrymaster with dialogue and a quest, a patrol, a camp prefab and a ferry back. Change anything; Test & Play to walk it; `.tele EmberIsle` takes you there.\n{}",
            notes.iter().map(|n| format!("\n- {n}")).collect::<String>()
        ),
    )?;
    Ok(p)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Slow in a debug build (it makes a whole map): `cargo test --release -p forge-core sample -- --ignored`.
    #[test]
    #[ignore]
    fn the_sample_builds_and_checks_clean() {
        crate::test_config();
        let dir = tempfile::tempdir().unwrap();
        let g = crate::world::tests::map_game(dir.path());
        let p = create_sample(&dir.path().join("projects"), &g).unwrap();
        assert!(p.root.join("README.md").is_file());
        let d = data::load(&p);
        assert!(d.world["creature_template"].rows.len() >= 2);
        assert!(!d.world["creature_ai_scripts"].rows.is_empty());
        assert!(!d.world["gossip_menu"].rows.is_empty());
        assert!(!d.world["quest_template"].rows.is_empty());
        assert!(d.world["creature"].rows.len() >= 6);
        assert_eq!(behaviour::paths(&p).len(), 1);
        let errors: Vec<_> = crate::check::run(&p, Some(&g)).into_iter().filter(|f| f.level == crate::check::Level::Error).collect();
        assert!(errors.is_empty(), "{errors:?}");
        let report = crate::build::build_with(&p, Some(&g), true).unwrap();
        assert!(!report.mpq.is_empty());
        // a second sample doesn't overwrite the first
        let p2 = create_sample(&dir.path().join("projects"), &g).unwrap();
        assert_ne!(p.root, p2.root);
    }
}
