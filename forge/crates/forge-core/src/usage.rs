//! What a project uses, gathered for the pictures panels: the models it places (game and
//! its own), the ground textures it paints, its creatures, objects and items, and its own
//! models with where they're used. Read-only.

use crate::project::Project;
use serde_json::{json, Value};
use std::collections::BTreeMap;

fn int(r: &toml::Table, k: &str) -> i64 {
    r.get(k).and_then(|v| v.as_integer().or(v.as_float().map(|f| f as i64))).unwrap_or(0)
}
fn text(r: &toml::Table, k: &str) -> String {
    r.get(k).and_then(toml::Value::as_str).unwrap_or("").to_string()
}

pub fn usage(p: &Project) -> Value {
    // placed models: model → (count, maps)
    let mut models: BTreeMap<String, (usize, Vec<String>)> = BTreeMap::new();
    for (map, list) in crate::world::load(p).unwrap_or_default() {
        for pl in list {
            let e = models.entry(pl.model.clone()).or_default();
            e.0 += 1;
            if !e.1.contains(&map) {
                e.1.push(map.clone());
            }
        }
    }
    // painted textures: texture → (chunks, tiles), from the tiles' chunk edits
    let mut textures: BTreeMap<String, (usize, usize)> = BTreeMap::new();
    let tiles = crate::world::terrain_tiles(p);
    for (map, a, b) in &tiles {
        let Ok(edits) = crate::world::load_chunks(p, map, *a, *b) else { continue };
        let mut on_tile: Vec<String> = vec![];
        for e in edits.values() {
            for l in e.layers.iter().flatten() {
                textures.entry(l.texture.clone()).or_default().0 += 1;
                if !on_tile.contains(&l.texture) {
                    on_tile.push(l.texture.clone());
                }
            }
        }
        for t in on_tile {
            textures.entry(t).or_default().1 += 1;
        }
    }
    let d = crate::data::load(p);
    let rows = |t: &str| d.world.get(t).map(|r| r.rows.clone()).unwrap_or_default();
    let spawns = |t: &str| -> BTreeMap<i64, usize> {
        let mut m = BTreeMap::new();
        for r in rows(t) {
            *m.entry(int(&r, "id")).or_default() += 1;
        }
        m
    };
    let (cs, os) = (spawns("creature"), spawns("gameobject"));
    let creatures: Vec<Value> = rows("creature_template")
        .iter()
        .filter(|r| r.get("override").is_none())
        .map(|r| {
            let e = int(r, "Entry");
            json!({"entry": e, "name": text(r, "Name"), "display": int(r, "DisplayId1"), "level": int(r, "MinLevel"), "spawns": cs.get(&e).copied().unwrap_or(0)})
        })
        .collect();
    let objects: Vec<Value> = rows("gameobject_template")
        .iter()
        .filter(|r| r.get("override").is_none())
        .map(|r| {
            let e = int(r, "entry");
            json!({"entry": e, "name": text(r, "name"), "display": int(r, "displayId"), "spawns": os.get(&e).copied().unwrap_or(0)})
        })
        .collect();
    let items: Vec<Value> = rows("item_template")
        .iter()
        .filter(|r| r.get("override").is_none())
        .map(|r| json!({"entry": int(r, "entry"), "name": text(r, "name"), "display": int(r, "displayid"), "quality": int(r, "Quality")}))
        .collect();
    // the pack's own models, and where each is used (placed, or as a creature's look)
    let own: Vec<Value> = crate::model::names(p)
        .into_iter()
        .map(|n| {
            let spec = crate::model::load_spec(p, &n).ok();
            let rep = crate::model::report(p, &n).unwrap_or_default();
            let placed = models.get(&format!("model:{n}")).map(|x| x.0).unwrap_or(0);
            let display = rep["display_id"].as_i64().or(rep["ids"]["display"].as_i64());
            let as_look = display.map(|disp| creatures.iter().filter(|c| c["display"] == disp).count()).unwrap_or(0);
            json!({"name": n, "kind": spec.map(|s| s.kind), "ported": !rep.is_null(), "placed": placed, "creatures": as_look})
        })
        .collect();
    let mut placed: Vec<Value> = models
        .into_iter()
        .map(|(m, (count, maps))| {
            let own = m.starts_with("model:");
            let label = m.strip_prefix("model:").map(str::to_string).unwrap_or_else(|| m.rsplit(['\\', '/']).next().unwrap_or(&m).to_string());
            json!({"model": m, "label": label, "count": count, "maps": maps, "own": own, "building": crate::world::is_wmo(&m)})
        })
        .collect();
    placed.sort_by(|a, b| b["count"].as_u64().cmp(&a["count"].as_u64()));
    let mut painted: Vec<Value> = textures
        .into_iter()
        .map(|(t, (chunks, tiles))| json!({"texture": t, "label": t.rsplit(['\\', '/']).next().unwrap_or(&t).trim_end_matches(".blp").to_string(), "chunks": chunks, "tiles": tiles}))
        .collect();
    painted.sort_by(|a, b| b["chunks"].as_u64().cmp(&a["chunks"].as_u64()));
    json!({
        "models": placed, "textures": painted, "creatures": creatures, "objects": objects, "items": items, "own_models": own,
        "tiles": tiles.len(), "maps": crate::world::own_maps(p),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::{create, Template};
    use crate::world::Placement;

    #[test]
    fn counts_what_the_pack_places_and_makes() {
        crate::test_config();
        let dir = tempfile::tempdir().unwrap();
        let p = create(dir.path().join("p"), "Use", "Orion", Template::Empty).unwrap();
        let pl = |m: &str, uid| Placement { model: m.into(), x: 0.0, y: 0.0, z: 0.0, turn: 0.0, scale: 1.0, uid, wmo_box: None, tilt: [0.0; 2], set: 0 };
        crate::world::save_placements(&p, "Azeroth", &[pl("World\\Tree.mdx", 1), pl("World\\Tree.mdx", 2), pl("World\\Hut.wmo", 3)]).unwrap();
        crate::world::save_placements(&p, "Kalimdor", &[pl("World\\Tree.mdx", 4)]).unwrap();
        let u = usage(&p);
        assert_eq!(u["models"][0]["label"], "Tree.mdx");
        assert_eq!(u["models"][0]["count"], 3);
        assert_eq!(u["models"][0]["maps"].as_array().unwrap().len(), 2);
        assert_eq!(u["models"][1]["building"], true);
        assert_eq!(u["creatures"].as_array().unwrap().len(), 0);
    }
}
