//! The one command surface the app's UI talks to: the desktop shell (Tauri) and `forge serve`
//! (the same UI in a browser) both pass `(command, JSON args)` here and hand back the JSON.
//! Keeping it in one place means the two can't drift apart.

use crate::config::Config;
use crate::project::{self, Manifest, Project, Template};
use crate::vfs::{self, GameData};
use crate::{build, check, data, ids, model, play, publish, sim};
use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::path::PathBuf;

/// What the app keeps between calls: the settings and the opened game data (indexing a full
/// install takes a moment, so it is opened once).
#[derive(Default)]
pub struct State {
    pub config: Config,
    pub game: Option<GameData>,
    pub game_error: Option<String>,
    /// Addon Studio's running fake client, if one is started.
    pub sim: Option<sim::Session>,
}

impl State {
    pub fn load() -> State {
        let mut s = State { config: Config::load(), ..Default::default() };
        s.reopen_game();
        s
    }

    fn reopen_game(&mut self) {
        self.game = None;
        self.game_error = None;
        if let Some(d) = self.config.game_dir.clone() {
            match GameData::open(&d) {
                Ok(g) => self.game = Some(g),
                Err(e) => self.game_error = Some(format!("{e:#}")),
            }
        }
    }
}

fn s<'a>(args: &'a Value, k: &str) -> Result<&'a str> {
    args.get(k).and_then(Value::as_str).with_context(|| format!("missing \"{k}\""))
}

fn project(args: &Value) -> Result<Project> {
    Project::open(s(args, "dir")?)
}

pub fn call(st: &mut State, cmd: &str, args: &Value) -> Result<Value> {
    Ok(match cmd {
        "status" => json!({
            "config": st.config,
            "game": st.game.as_ref().map(|g| g.status()),
            "gameError": st.game_error,
            "templates": Template::ALL.iter().map(|t| json!({"id": t, "label": t.label()})).collect::<Vec<_>>(),
            "idTables": ids::TABLES.iter().map(|t| json!({"table": t.table, "what": t.what})).collect::<Vec<_>>(),
            "version": env!("CARGO_PKG_VERSION"),
            "cli": std::env::var("FORGE_CLI").ok(),
        }),
        "detect_game" => json!(crate::vfs::detect_games()),
        "set_game" => {
            let dir = PathBuf::from(s(args, "dir")?);
            let g = GameData::open(&dir)?;
            let status = g.status();
            st.config.game_dir = Some(dir);
            st.config.save()?;
            st.game = Some(g);
            st.game_error = None;
            json!(status)
        }
        "recent" => {
            let list: Vec<Value> = st
                .config
                .recent
                .iter()
                .map(|d| match Project::open(d) {
                    Ok(p) => json!({"dir": d, "ok": true, "id": p.manifest.pack.id, "name": p.manifest.pack.name,
                        "version": p.manifest.pack.version, "kind": kind(&p)}),
                    Err(_) => json!({"dir": d, "ok": false}),
                })
                .collect();
            json!(list)
        }
        "suggest_dir" => {
            // Documents\Vanilla Forge\<slug>, a fresh name if that one is taken
            let home = std::env::var("USERPROFILE").or_else(|_| std::env::var("HOME")).unwrap_or_else(|_| ".".into());
            let base = PathBuf::from(home).join("Documents").join("Vanilla Forge");
            let slug = project::slug(args.get("name").and_then(Value::as_str).unwrap_or("my-pack"));
            let slug = if slug.is_empty() { "my-pack".to_string() } else { slug };
            let mut dir = base.join(&slug);
            let mut n = 2;
            while dir.exists() {
                dir = base.join(format!("{slug}-{n}"));
                n += 1;
            }
            json!(dir)
        }
        "forget_recent" => {
            let dir = PathBuf::from(s(args, "dir")?);
            st.config.recent.retain(|d| d != &dir);
            st.config.save()?;
            json!(true)
        }
        "new_project" => {
            let t = Template::parse(s(args, "template")?).context("unknown template")?;
            let p = project::create(s(args, "dir")?, s(args, "name")?, args.get("author").and_then(Value::as_str).unwrap_or(""), t)?;
            st.config.touch_recent(&p.root);
            st.config.save()?;
            open(st, &p)?
        }
        "sample_create" => {
            let home = std::env::var("USERPROFILE").or_else(|_| std::env::var("HOME")).unwrap_or_else(|_| ".".into());
            let base = args.get("parent").and_then(Value::as_str).map(PathBuf::from).unwrap_or_else(|| PathBuf::from(home).join("Documents").join("Vanilla Forge"));
            std::fs::create_dir_all(&base)?;
            let p = crate::sample::create_sample(&base, need(st)?)?;
            st.config.touch_recent(&p.root);
            st.config.save()?;
            open(st, &p)?
        }
        "fix" => {
            let mut p = project(args)?;
            json!(crate::fixes::fix(&mut p, s(args, "code")?, args.get("path").and_then(Value::as_str).unwrap_or(""))?)
        }
        "open_project" => {
            let p = project(args)?;
            st.config.touch_recent(&p.root);
            st.config.save()?;
            open(st, &p)?
        }
        "save_manifest" => {
            let mut p = project(args)?;
            p.manifest = serde_json::from_value::<Manifest>(args.get("manifest").cloned().context("missing manifest")?)?;
            p.save()?;
            open(st, &p)?
        }
        "check" => json!(check::run(&project(args)?, st.game.as_ref())),
        "build" => json!(build::build_with(&project(args)?, st.game.as_ref(), args.get("dev").and_then(Value::as_bool).unwrap_or(false))?),
        "data_overview" => data::overview(&project(args)?),
        "data_rows" => data::rows_json(&project(args)?, s(args, "kind")?, s(args, "table")?)?,
        "data_save" => {
            let p = project(args)?;
            let (kind, table) = (s(args, "kind")?, s(args, "table")?);
            let rows = data::rows_from_json(kind, table, args.get("rows").context("missing rows")?)?;
            data::save_rows(&p, kind, table, &rows)?;
            json!({"rows": data::rows_json(&p, kind, table)?, "findings": check::run(&p, st.game.as_ref())})
        }
        "data_sql" => {
            let p = project(args)?;
            let (i, r) = data::sql(&p, &data::load(&p));
            json!({"install": i, "rollback": r})
        }
        "spawn_add" => {
            let p = project(args)?;
            let pos = data::parse_gps(s(args, "where")?).context("couldn't read a position: paste what .gps prints, or map x y z o")?;
            let entry = args.get("entry").and_then(Value::as_i64).context("missing entry")?;
            let guid = data::add_spawn(&p, entry, pos, args.get("respawn").and_then(Value::as_u64).unwrap_or(300) as u32, args.get("wander").and_then(Value::as_f64).unwrap_or(0.0))?;
            json!({"guid": guid, "pos": pos})
        }
        "world_checkpoint" => json!(crate::world::checkpoint(&project(args)?, args.get("what").and_then(Value::as_str).unwrap_or("edit"))?),
        "world_undo" => crate::world::undo_many(&project(args)?, args.get("steps").and_then(Value::as_u64).unwrap_or(1) as usize)?,
        "world_redo" => crate::world::redo(&project(args)?)?,
        "world_history" => crate::world::history(&project(args)?),
        "world_spawnables" => crate::world::spawnables(&project(args)?),
        "world_spawn" => {
            let p = project(args)?;
            let map = s(args, "map")?;
            let f = |k: &str| args.get(k).and_then(Value::as_f64).with_context(|| format!("missing {k}"));
            let pos = data::Pos { map: crate::world::map_id(&p, map).with_context(|| format!("{map}: not a map Forge knows"))?, x: f("x")?, y: f("y")?, z: f("z")?, o: args.get("o").and_then(Value::as_f64).unwrap_or(0.0) };
            let entry = args.get("entry").and_then(Value::as_i64).context("missing entry")?;
            let respawn = args.get("respawn").and_then(Value::as_u64).unwrap_or(300) as u32;
            let guid = match s(args, "table")? {
                "gameobject" => data::add_object_spawn(&p, entry, pos, respawn)?,
                _ => data::add_spawn(&p, entry, pos, respawn, args.get("wander").and_then(Value::as_f64).unwrap_or(0.0))?,
            };
            json!({"guid": guid})
        }
        "world_spawn_remove" => {
            let p = project(args)?;
            data::remove_spawn(&p, s(args, "table")?, args.get("guid").and_then(Value::as_i64).context("missing guid")?)?;
            json!(true)
        }
        "wiz_list" => crate::wizards::list(&project(args)?),
        "wiz_quest" => json!(crate::wizards::quest(&project(args)?, &serde_json::from_value(args.get("spec").cloned().context("missing spec")?)?)?),
        "wiz_item" => json!(crate::wizards::item(&project(args)?, &serde_json::from_value(args.get("spec").cloned().context("missing spec")?)?)?),
        "wiz_creature" => json!(crate::wizards::creature(&project(args)?, &serde_json::from_value(args.get("spec").cloned().context("missing spec")?)?)?),
        "behaviour_overview" => crate::behaviour::overview(&project(args)?),
        "behaviour_get" => json!(crate::behaviour::get_behaviour(&project(args)?, args.get("entry").and_then(Value::as_i64).context("missing entry")?)),
        "behaviour_save" => crate::behaviour::save_behaviour(&project(args)?, &serde_json::from_value(args.get("behaviour").cloned().context("missing behaviour")?)?)?,
        "behaviour_describe" => {
            let cards: Vec<crate::behaviour::Card> = serde_json::from_value(args.get("cards").cloned().unwrap_or(json!([])))?;
            json!(cards.iter().map(crate::behaviour::describe).collect::<Vec<_>>())
        }
        "dialogue_get" => json!(crate::behaviour::get_dialogue(&project(args)?, args.get("entry").and_then(Value::as_i64).context("missing entry")?)),
        "dialogue_save" => crate::behaviour::save_dialogue(&project(args)?, &serde_json::from_value(args.get("dialogue").cloned().context("missing dialogue")?)?)?,
        "path_save" => crate::behaviour::save_path(&project(args)?, &serde_json::from_value(args.get("path").cloned().context("missing path")?)?)?,
        "wiz_item_icon" => {
            use base64::Engine;
            let png = base64::engine::general_purpose::STANDARD.decode(s(args, "png")?)?;
            json!(crate::wizards::item_icon(&project(args)?, args.get("base").and_then(Value::as_i64).unwrap_or(0), s(args, "name")?, &png)?)
        }
        "wiz_vendor" => {
            let items: Vec<crate::wizards::Pair> = serde_json::from_value(args.get("items").cloned().unwrap_or(json!([])))?;
            json!(crate::wizards::vendor(&project(args)?, args.get("creature").and_then(Value::as_i64).unwrap_or(0), &items)?)
        }
        "wiz_get" => {
            let p = project(args)?;
            let id = args.get("id").and_then(Value::as_i64).context("missing id")?;
            match s(args, "kind")? {
                "quest" => json!(crate::wizards::get_quest(&p, id)?),
                "item" => json!(crate::wizards::get_item(&p, id)?),
                "creature" => json!(crate::wizards::get_creature(&p, id)?),
                _ => json!(crate::wizards::get_vendor(&p, id)),
            }
        }
        "world_list" => {
            let p = project(args)?;
            let models: Vec<Value> = model::names(&p)
                .into_iter()
                .filter(|n| model::report(&p, n).is_some_and(|r| !r["doodad"].is_null()))
                .map(|n| json!({"model": format!("model:{n}"), "name": n}))
                .collect();
            json!({"maps": crate::world::maps(&p).iter().map(|(i, n)| json!({"id": i, "name": n})).collect::<Vec<_>>(),
                   "own_maps": crate::world::own_maps(&p),
                   // where to open the World screen: a tile the pack has changed, or its own map
                   "start": crate::world::start_tile(&p).map(|(m, a, b)| json!({"map": m, "a": a, "b": b})),
                   "placements": crate::world::load(&p)?, "doodads": models})
        }
        "world_tile" => {
            let p = project(args)?;
            let a = args.get("a").and_then(Value::as_i64).context("missing a")? as i32;
            let b = args.get("b").and_then(Value::as_i64).context("missing b")? as i32;
            crate::world::tile_view(&p, need(st)?, s(args, "map")?, a, b)?
        }
        "world_locate" => {
            let pos = data::parse_gps(s(args, "where")?).context("paste what .gps prints, or map x y z")?;
            let (a, b) = crate::adt::tile_of(pos.x, pos.y);
            json!({"map": crate::world::map_name(pos.map), "a": a, "b": b, "pos": pos})
        }
        "world_place" => {
            let p = project(args)?;
            let pl: crate::world::Placement = serde_json::from_value(args.get("placement").cloned().context("missing placement")?)?;
            let ground = args.get("ground").and_then(Value::as_bool).unwrap_or(true);
            json!(crate::world::place(&p, st.game.as_ref(), s(args, "map")?, pl, ground)?)
        }
        "world_sculpt" => {
            let p = project(args)?;
            let brush: crate::world::Brush = serde_json::from_value(args.get("brush").cloned().context("missing brush")?)?;
            let f = |k: &str| args.get(k).and_then(Value::as_f64).with_context(|| format!("missing {k}"));
            let shape: crate::world::Shape = args.get("shape").cloned().map(serde_json::from_value).transpose()?.unwrap_or_default();
            json!(crate::world::sculpt_shaped(&p, need(st)?, s(args, "map")?, f("x")?, f("y")?, f("radius")?, f("strength")?, brush, shape)?)
        }
        "world_paint" => {
            let p = project(args)?;
            let f = |k: &str| args.get(k).and_then(Value::as_f64).with_context(|| format!("missing {k}"));
            let shape: crate::world::Shape = args.get("shape").cloned().map(serde_json::from_value).transpose()?.unwrap_or_default();
            json!(crate::world::paint_shaped(&p, need(st)?, s(args, "map")?, f("x")?, f("y")?, f("radius")?, f("strength")?, s(args, "texture")?, shape)?)
        }
        "light_list" => {
            let p = project(args)?;
            let map = crate::world::map_id(&p, s(args, "map")?).context("unknown map")?;
            let near = match (args.get("x").and_then(Value::as_f64), args.get("y").and_then(Value::as_f64)) { (Some(x), Some(y)) => Some((x, y)), _ => None };
            json!(crate::light::lights(&p, need(st)?, map, near)?)
        }
        "light_get" => crate::light::light_detail(&project(args)?, need(st)?, args.get("id").and_then(Value::as_u64).context("missing id")? as u32)?,
        "light_set" => {
            let p = project(args)?;
            let e: crate::light::LightEdit = serde_json::from_value(args.clone())?;
            crate::light::light_set(&p, need(st)?, args.get("id").and_then(Value::as_u64).context("missing id")? as u32, &e)?;
            json!(true)
        }
        "light_band" => {
            let p = project(args)?;
            let v = |k: &str| -> Result<Vec<u32>> { Ok(serde_json::from_value(args.get(k).cloned().with_context(|| format!("missing {k}"))?)?) };
            crate::light::band_set(&p, need(st)?, args.get("params").and_then(Value::as_u64).context("missing params")? as u32, args.get("band").and_then(Value::as_u64).context("missing band")? as usize, &v("times")?, &v("colors")?)?;
            json!(true)
        }
        "light_new" => {
            let p = project(args)?;
            let map = crate::world::map_id(&p, s(args, "map")?).context("unknown map")?;
            let f = |k: &str| args.get(k).and_then(Value::as_f64).with_context(|| format!("missing {k}"));
            json!({"id": crate::light::light_new(&p, need(st)?, map, f("x")?, f("y")?, f("z")?, f("start")?, f("end")?, args.get("from").and_then(Value::as_u64).context("missing from")? as u32)?})
        }
        "light_remove" => { crate::light::light_remove(&project(args)?, need(st)?, args.get("id").and_then(Value::as_u64).context("missing id")? as u32)?; json!(true) }
        "area_list" => {
            let p = project(args)?;
            let ids: Vec<u32> = args.get("ids").and_then(Value::as_array).map(|a| a.iter().filter_map(Value::as_u64).map(|x| x as u32).collect()).unwrap_or_default();
            json!(crate::world::areas(&p, need(st)?, args.get("q").and_then(Value::as_str).unwrap_or(""), &ids, args.get("limit").and_then(Value::as_u64).unwrap_or(40) as usize)?)
        }
        "area_get" => crate::world::area_get(&project(args)?, need(st)?, args.get("id").and_then(Value::as_u64).context("missing id")? as u32)?,
        "area_save" => {
            let p = project(args)?;
            let e: crate::world::AreaEdit = serde_json::from_value(args.clone())?;
            crate::world::area_save(&p, need(st)?, args.get("id").and_then(Value::as_u64).context("missing id")? as u32, &e)?;
            json!(true)
        }
        "area_new" => {
            let p = project(args)?;
            let n = |k: &str| args.get(k).and_then(Value::as_u64).unwrap_or(0) as u32;
            json!({"id": crate::world::new_area(&p, s(args, "map")?, s(args, "name")?, n("parent"), n("level"))?})
        }
        "world_swap" => {
            let p = project(args)?;
            let n = |k: &str| args.get(k).and_then(Value::as_i64).with_context(|| format!("missing {k}"));
            let (map, a, b) = (s(args, "map")?, n("a")? as i32, n("b")? as i32);
            // with a brush (x, y, radius): only the chunks it reaches on this tile
            let only: Option<Vec<(usize, usize)>> = match (args.get("x").and_then(Value::as_f64), args.get("y").and_then(Value::as_f64), args.get("radius").and_then(Value::as_f64)) {
                (Some(x), Some(y), Some(r)) => {
                    let c = crate::adt::to_file(x, y, 0.0);
                    Some(crate::world::chunks_under_pub(c[0] as f64, c[2] as f64, r).into_iter().filter(|(t, _, _)| *t == (a, b)).map(|(_, col, row)| (col, row)).collect())
                }
                _ => None,
            };
            if args.get("scope").and_then(Value::as_str) == Some("pack") {
                let (tiles, chunks) = crate::world::swap_texture_pack(&p, need(st)?, map, s(args, "from")?, s(args, "to")?)?;
                return Ok(json!({"chunks": chunks, "tiles": tiles}));
            }
            json!({"chunks": crate::world::swap_texture(&p, need(st)?, map, a, b, s(args, "from")?, s(args, "to")?, only.as_deref())?})
        }
        "world_impass" => {
            let p = project(args)?;
            let f = |k: &str| args.get(k).and_then(Value::as_f64).with_context(|| format!("missing {k}"));
            json!(crate::world::paint_impass(&p, need(st)?, s(args, "map")?, f("x")?, f("y")?, f("radius")?, args.get("on").and_then(Value::as_bool).unwrap_or(true))?)
        }
        "world_hole" => {
            let p = project(args)?;
            let f = |k: &str| args.get(k).and_then(Value::as_f64).with_context(|| format!("missing {k}"));
            crate::world::set_hole(&p, need(st)?, s(args, "map")?, f("x")?, f("y")?, args.get("hole").and_then(Value::as_bool).unwrap_or(true))?;
            json!(true)
        }
        "world_water" => {
            let p = project(args)?;
            let f = |k: &str| args.get(k).and_then(Value::as_f64).with_context(|| format!("missing {k}"));
            let erase = args.get("erase").and_then(Value::as_bool).unwrap_or(false);
            json!(crate::world::water(&p, need(st)?, s(args, "map")?, f("x")?, f("y")?, f("radius")?, if erase { 0.0 } else { f("level")? }, args.get("kind").and_then(Value::as_str).unwrap_or("water"), erase)?)
        }
        "world_chunk_copy" => {
            let p = project(args)?;
            let pt = |k: &str| -> Result<[f64; 2]> { serde_json::from_value(args.get(k).cloned().with_context(|| format!("missing {k}"))?).with_context(|| format!("{k} is [x, y]")) };
            let c = crate::chunkclip::copy(&p, need(st)?, s(args, "map")?, pt("from")?, pt("to")?)?;
            json!({"w": c.w, "h": c.h, "map": c.map})
        }
        "world_chunk_paste" => {
            let p = project(args)?;
            json!(crate::chunkclip::paste(&p, need(st)?, &serde_json::from_value(args.get("spec").cloned().context("missing spec")?)?)?)
        }
        "world_chunk_clip" => json!(crate::chunkclip::info(&project(args)?)),
        "world_remove_texture" => {
            let p = project(args)?;
            let n = |k: &str| args.get(k).and_then(Value::as_i64).with_context(|| format!("missing {k}"));
            json!(crate::world::remove_texture(&p, need(st)?, s(args, "map")?, n("a")? as i32, n("b")? as i32, s(args, "texture")?)?)
        }
        "world_shadows_clear" => {
            let p = project(args)?;
            let n = |k: &str| args.get(k).and_then(Value::as_i64).with_context(|| format!("missing {k}"));
            let f = |k: &str| args.get(k).and_then(Value::as_f64);
            let at = match (f("x"), f("y"), f("radius")) { (Some(x), Some(y), Some(r)) => Some((x, y, r)), _ => None };
            json!(crate::world::clear_shadows(&p, need(st)?, s(args, "map")?, n("a")? as i32, n("b")? as i32, at)?)
        }
        "world_hide" => {
            let p = project(args)?;
            let n = |k: &str| args.get(k).and_then(Value::as_i64).with_context(|| format!("missing {k}"));
            let uids: Vec<u32> = serde_json::from_value(args.get("uids").cloned().context("missing uids")?)?;
            json!(crate::world::hide_game_objects(&p, need(st)?, s(args, "map")?, n("a")? as i32, n("b")? as i32, &uids, args.get("hide").and_then(Value::as_bool).unwrap_or(true))?)
        }
        "world_pickup" => {
            let p = project(args)?;
            let n = |k: &str| args.get(k).and_then(Value::as_i64).with_context(|| format!("missing {k}"));
            let uids: Vec<u32> = serde_json::from_value(args.get("uids").cloned().context("missing uids")?)?;
            json!(crate::world::pick_up(&p, need(st)?, s(args, "map")?, n("a")? as i32, n("b")? as i32, &uids)?)
        }
        "world_water_slope" => {
            let p = project(args)?;
            let pt = |k: &str| -> Result<[f64; 3]> { serde_json::from_value(args.get(k).cloned().with_context(|| format!("missing {k}"))?).with_context(|| format!("{k} is [x, y, height]")) };
            let width = args.get("width").and_then(Value::as_f64).unwrap_or(20.0);
            json!(crate::world::water_slope(&p, need(st)?, s(args, "map")?, pt("from")?, pt("to")?, width, args.get("kind").and_then(Value::as_str).unwrap_or("water"))?)
        }
        "world_water_crop" => {
            let p = project(args)?;
            let f = |k: &str| args.get(k).and_then(Value::as_f64).with_context(|| format!("missing {k}"));
            json!(crate::world::water_crop(&p, need(st)?, s(args, "map")?, f("x")?, f("y")?, f("radius")?)?)
        }
        "world_far" => {
            let p = project(args)?;
            let n = |k: &str| args.get(k).and_then(Value::as_i64).with_context(|| format!("missing {k}"));
            crate::world::far_tile(&p, need(st)?, s(args, "map")?, n("a")? as i32, n("b")? as i32, args.get("size").and_then(Value::as_u64).unwrap_or(128) as u32)?
        }
        "world_trueground" => {
            let p = project(args)?;
            let n = |k: &str| args.get(k).and_then(Value::as_i64).with_context(|| format!("missing {k}"));
            let size = args.get("size").and_then(Value::as_u64).unwrap_or(1024) as u32;
            let shade = args.get("shade").and_then(Value::as_bool).unwrap_or(false);
            json!({"png": crate::world::true_ground_png(&p, need(st)?, s(args, "map")?, n("a")? as i32, n("b")? as i32, size, shade)?})
        }
        "world_splat" => {
            let p = project(args)?;
            let n = |k: &str| args.get(k).and_then(Value::as_i64).with_context(|| format!("missing {k}"));
            crate::world::splat(&p, need(st)?, s(args, "map")?, n("a")? as i32, n("b")? as i32)?
        }
        "world_mesh" => {
            let p = project(args)?;
            let g = st.game.as_ref();
            crate::trueview::mesh(s(args, "path")?, &|path| crate::world::read_art(&p, g, path))?
        }
        "thumbs" => {
            let p = project(args)?;
            let items = args.get("items").and_then(Value::as_array).cloned().unwrap_or_default();
            crate::thumbs::many(&p, st.game.as_ref(), &items, args.get("size").and_then(Value::as_u64).unwrap_or(96) as u32)
        }
        "usage" => crate::usage::usage(&project(args)?),
        "world_texture" => {
            let p = project(args)?;
            let max = args.get("max").and_then(Value::as_u64).unwrap_or(256) as u32;
            let bytes = crate::world::read_art(&p, st.game.as_ref(), s(args, "path")?)?;
            json!({"png": crate::trueview::texture_png(&bytes, max.clamp(8, 1024))?})
        }
        "kit_scatter" => {
            let p = project(args)?;
            json!({"placed": crate::kit::scatter(&p, need(st)?, &serde_json::from_value(args.get("spec").cloned().context("missing spec")?)?)?})
        }
        "kit_clear" => {
            let p = project(args)?;
            let f = |k: &str| args.get(k).and_then(Value::as_f64).with_context(|| format!("missing {k}"));
            json!({"removed": crate::kit::clear_circle(&p, s(args, "map")?, f("x")?, f("y")?, f("radius")?)?})
        }
        "kit_heightmap_export" => {
            let p = project(args)?;
            let n = |k: &str| args.get(k).and_then(Value::as_i64).with_context(|| format!("missing {k}"));
            let mut v = crate::kit::export_heightmap(&p, need(st)?, s(args, "map")?, n("a")? as i32, n("b")? as i32)?;
            // also a file in the project's exports folder (the desktop app has no downloads)
            use base64::Engine;
            let bytes = base64::engine::general_purpose::STANDARD.decode(v["png"].as_str().unwrap_or(""))?;
            let dir = p.root.join("exports");
            std::fs::create_dir_all(&dir)?;
            let file = dir.join(v["name"].as_str().unwrap_or("heightmap.png"));
            std::fs::write(&file, bytes)?;
            v["file"] = json!(file.display().to_string());
            v
        }
        "kit_heightmap_import" => {
            let p = project(args)?;
            use base64::Engine;
            let png = base64::engine::general_purpose::STANDARD.decode(s(args, "png")?)?;
            crate::kit::import_heightmap(&p, need(st)?, &png, &serde_json::from_value(args.get("spec").cloned().context("missing spec")?)?)?
        }
        "kit_prefabs" => json!(crate::kit::prefabs(&project(args)?)),
        "kit_prefab_capture" => {
            let p = project(args)?;
            let c = |k: &str| -> Result<[f64; 2]> { serde_json::from_value(args.get(k).cloned().with_context(|| format!("missing {k}"))?).map_err(Into::into) };
            json!(crate::kit::capture(&p, need(st)?, s(args, "map")?, s(args, "name")?, c("a")?, c("b")?)?)
        }
        "kit_prefab_stamp" => {
            let p = project(args)?;
            let f = |k: &str| args.get(k).and_then(Value::as_f64).with_context(|| format!("missing {k}"));
            crate::kit::stamp(&p, need(st)?, s(args, "map")?, s(args, "name")?, f("x")?, f("y")?, f("turn").unwrap_or(0.0), args.get("level").and_then(Value::as_bool).unwrap_or(false))?
        }
        "kit_prefab_add" => json!(crate::kit::add_prefab(&project(args)?, s(args, "json")?.as_bytes())?),
        "kit_prefab_remove" => {
            crate::kit::remove_prefab(&project(args)?, s(args, "name")?)?;
            json!(true)
        }
        "kit_ramp" => {
            let p = project(args)?;
            json!(crate::kit::ramp(&p, need(st)?, &serde_json::from_value(args.get("spec").cloned().context("missing spec")?)?)?)
        }
        "kit_stamp" => {
            let p = project(args)?;
            json!(crate::kit::stamp_image(&p, need(st)?, &serde_json::from_value(args.get("spec").cloned().context("missing spec")?)?)?)
        }
        "kit_field" => {
            let p = project(args)?;
            json!(crate::kit::field(&p, need(st)?, &serde_json::from_value(args.get("spec").cloned().context("missing spec")?)?)?)
        }
        "world_scripts" => json!(crate::kit::scripts(&project(args)?)),
        "world_bookmarks" => crate::kit::bookmarks(&project(args)?),
        "world_bookmarks_save" => {
            crate::kit::bookmarks_save(&project(args)?, args.get("list").context("missing list")?)?;
            json!(true)
        }
        "world_script_save" => json!(crate::kit::script_save(&project(args)?, s(args, "name")?, s(args, "code")?)?),
        "world_script_remove" => {
            crate::kit::script_remove(&project(args)?, s(args, "name")?)?;
            json!(true)
        }
        "kit_road" => {
            let p = project(args)?;
            json!({"tiles": crate::kit::road(&p, need(st)?, &serde_json::from_value(args.get("spec").cloned().context("missing spec")?)?)?})
        }
        "world_minimap" => {
            let p = project(args)?;
            let n = |k: &str| args.get(k).and_then(Value::as_i64).with_context(|| format!("missing {k}"));
            json!({"png": crate::world::minimap_png(&p, need(st)?, s(args, "map")?, n("a")? as i32, n("b")? as i32)?})
        }
        "world_new_map" => {
            let p = project(args)?;
            let spec: crate::world::NewMap = serde_json::from_value(args.get("spec").cloned().context("missing spec")?)?;
            crate::world::new_map(&p, need(st)?, &spec)?
        }
        "world_loading_screen" => {
            use base64::Engine;
            let p = project(args)?;
            let bytes = base64::engine::general_purpose::STANDARD.decode(s(args, "image")?)?;
            crate::world::set_loading_screen(&p, s(args, "map")?, &bytes)?
        }
        "world_portals" => json!(crate::world::portals(&project(args)?)),
        "world_portal_add" => {
            let p = project(args)?;
            let spec: crate::world::NewPortal = serde_json::from_value(args.get("spec").cloned().context("missing spec")?)?;
            crate::world::add_portal(&p, &spec)?
        }
        "world_portal_remove" => {
            let p = project(args)?;
            crate::world::remove_portal(&p, args.get("id").and_then(Value::as_i64).context("missing id")?)?;
            json!(true)
        }
        "world_area" => {
            let p = project(args)?;
            let f = |k: &str| args.get(k).and_then(Value::as_f64).with_context(|| format!("missing {k}"));
            json!(crate::world::paint_area(&p, need(st)?, s(args, "map")?, f("x")?, f("y")?, f("radius")?, args.get("area").and_then(Value::as_u64).context("missing area")? as u32)?)
        }
        "world_reset_tile" => {
            let p = project(args)?;
            let dir = p.root.join("maps").join(s(args, "map")?).join("terrain");
            for ext in ["hd", "chunks.json"] {
                let _ = std::fs::remove_file(dir.join(format!("{}_{}.{ext}", args["a"], args["b"])));
            }
            json!(true)
        }
        "world_move_many" => {
            let p = project(args)?;
            let moves: Vec<crate::world::Move> = serde_json::from_value(args.get("moves").cloned().context("missing moves")?)?;
            json!(crate::world::move_many(&p, s(args, "map")?, &moves)?)
        }
        "world_place_many" => {
            let p = project(args)?;
            let list: Vec<crate::world::Placement> = serde_json::from_value(args.get("placements").cloned().context("missing placements")?)?;
            json!(crate::world::place_many(&p, st.game.as_ref(), s(args, "map")?, list, args.get("ground").and_then(Value::as_bool).unwrap_or(true))?)
        }
        "world_remove_many" => {
            let p = project(args)?;
            let uids: Vec<u32> = serde_json::from_value(args.get("uids").cloned().context("missing uids")?)?;
            json!(crate::world::remove_many(&p, s(args, "map")?, &uids)?)
        }
        "world_move" => {
            let p = project(args)?;
            let o = |k: &str| args.get(k).and_then(Value::as_f64);
            let uid = args.get("uid").and_then(Value::as_u64).context("missing uid")? as u32;
            let tilt: Option<[f64; 2]> = args.get("tilt").cloned().map(serde_json::from_value).transpose()?;
            let set = args.get("set").and_then(Value::as_u64).map(|v| v as u16);
            let m = crate::world::Move { uid, x: o("x"), y: o("y"), z: o("z"), turn: o("turn"), scale: o("scale"), tilt, set };
            json!(crate::world::move_many(&p, s(args, "map")?, &[m])?.remove(0))
        }
        "world_remove" => {
            let p = project(args)?;
            crate::world::remove(&p, s(args, "map")?, args.get("uid").and_then(Value::as_u64).context("missing uid")? as u32)?;
            json!(true)
        }
        "data_search" => {
            let t = s(args, "table")?;
            let d = data::read_stock(need(st)?, t)?;
            json!(data::search_stock(t, &d, s(args, "q")?, args.get("limit").and_then(Value::as_u64).unwrap_or(40) as usize))
        }
        "data_stock" => {
            // a stock DBC record (to clone from or override), by ID
            let t = s(args, "table")?;
            let id = args.get("id").and_then(Value::as_u64).context("missing id")? as u32;
            let d = data::read_stock(need(st)?, t)?;
            match d.find(id) {
                Some(i) => data::record_json(t, &d, i),
                None => bail!("no {t} {id} in your game"),
            }
        }
        "allocate_id" => {
            let p = project(args)?;
            let mut l = ids::IdLock::load(&p.root)?;
            let id = l.allocate(&p.manifest.pack.id, s(args, "table")?, args.get("name").and_then(Value::as_str).unwrap_or(""))?;
            l.save(&p.root)?;
            json!({"id": id, "lock": l})
        }
        "pack_preview" => {
            let p = project(args)?;
            let path = s(args, "path")?.to_ascii_lowercase();
            let e = build::collect(&p)?.remove(&path).context("not in the pack")?;
            json!(vfs::preview_bytes(&e.path, &build::produce(&e)?)?)
        }
        "code_files" => {
            let p = project(args)?;
            json!(code_files(&p))
        }
        "code_read" => {
            let p = project(args)?;
            let f = code_path(&p, s(args, "path")?)?;
            let text = std::fs::read_to_string(&f).with_context(|| format!("can't read {}", s(args, "path").unwrap_or("")))?;
            json!({"text": text, "lint": lint_of(s(args, "path")?, &text)})
        }
        "code_write" => {
            let p = project(args)?;
            let rel = s(args, "path")?;
            let f = code_path(&p, rel)?;
            let text = s(args, "text")?;
            let new = !f.exists();
            std::fs::create_dir_all(f.parent().unwrap())?;
            std::fs::write(&f, text)?;
            let added = if new { add_to_toc(&p, &f)? } else { None };
            json!({"lint": lint_of(rel, text), "addedToToc": added, "files": code_files(&p)})
        }
        "code_lint" => lint_of(s(args, "path")?, s(args, "text")?),
        "code_delete" => {
            let p = project(args)?;
            let f = code_path(&p, s(args, "path")?)?;
            std::fs::remove_file(&f)?;
            json!({"files": code_files(&p)})
        }
        "sim_start" => {
            let p = project(args)?;
            let addons: Vec<String> = args.get("addons").and_then(|a| serde_json::from_value(a.clone()).ok()).unwrap_or_default();
            let mut o = sim::Options::default();
            if let Some(v) = args.get("class").and_then(Value::as_str) { o.class = v.to_ascii_uppercase(); }
            if let Some(v) = args.get("race").and_then(Value::as_str) { o.race = v.to_string(); }
            if let Some(v) = args.get("name").and_then(Value::as_str).filter(|v| !v.is_empty()) { o.name = v.to_string(); }
            if let Some(v) = args.get("level").and_then(Value::as_u64) { o.level = v as u32; }
            st.sim = None;
            let (sess, snap) = sim::Session::start(&p.root, &addons, &o)?;
            let names = sess.addons.clone();
            st.sim = Some(sess);
            json!({"addons": names, "snap": snap})
        }
        "sim_slash" => json!(running(st)?.slash(s(args, "line")?)?),
        "sim_tick" => json!(running(st)?.tick(args.get("seconds").and_then(Value::as_f64).unwrap_or(1.0))?),
        "sim_click" => json!(running(st)?.click(s(args, "text")?)?),
        "sim_run" => json!(running(st)?.run(s(args, "code")?)?),
        "sim_fire" => {
            let a: Vec<String> = args.get("args").and_then(|a| serde_json::from_value(a.clone()).ok()).unwrap_or_default();
            json!(running(st)?.fire(s(args, "event")?, &a)?)
        }
        "sim_saved" => running(st)?.saved()?,
        "sim_stop" => {
            st.sim = None;
            json!(true)
        }
        "models_list" => json!({"models": model::list(&project(args)?), "kinds": model::KINDS, "sounds": model::SOUNDS, "python": st.config.python}),
        "model_import" => {
            let p = project(args)?;
            let spec = model::ModelSpec {
                source: String::new(),
                kind: args.get("kind").and_then(Value::as_str).unwrap_or("creature").to_string(),
                title: args.get("title").and_then(Value::as_str).unwrap_or("").to_string(),
                height: args.get("height").and_then(Value::as_f64).filter(|h| *h > 0.0),
                facing: None,
                texture_max: None,
                max_triangles: None,
                collision: None,
                sound: args.get("sound").and_then(Value::as_str).filter(|v| !v.is_empty()).map(String::from),
                anims: Default::default(),
                speed: args.get("speed").and_then(Value::as_str).filter(|v| !v.is_empty()).map(String::from),
                item_name: None,
                ids: Default::default(),
            };
            let name = model::import(&p, std::path::Path::new(s(args, "source")?), args.get("name").and_then(Value::as_str).unwrap_or(""), spec)?;
            let py = model::find_python(st.config.python.as_deref())?;
            let report = model::port(&p, &name, &py, st.game.as_ref())?;
            json!({"name": name, "report": report})
        }
        "model_save" => {
            let p = project(args)?;
            let name = s(args, "name")?;
            let old = model::load_spec(&p, name)?;
            let mut spec: model::ModelSpec = serde_json::from_value(args.get("spec").cloned().context("missing spec")?)?;
            spec.source = old.source;
            spec.ids = old.ids;
            model::save_spec(&p, name, &spec)?;
            json!(spec)
        }
        "model_port" => {
            let p = project(args)?;
            let py = model::find_python(st.config.python.as_deref())?;
            model::port(&p, s(args, "name")?, &py, st.game.as_ref())?
        }
        "model_preview" => model::preview(&project(args)?, s(args, "name")?)?,
        "model_remove" => {
            let p = project(args)?;
            model::remove(&p, s(args, "name")?)?;
            json!(true)
        }
        "set_python" => {
            let v = args.get("python").and_then(Value::as_str).unwrap_or("").trim().to_string();
            let py = model::find_python(Some(&v).filter(|v| !v.is_empty()).map(|x| x.as_str()))?;
            st.config.python = if v.is_empty() { None } else { Some(v) };
            st.config.save()?;
            json!(py.join(" "))
        }
        "live_status" => {
            let mut v = crate::livelink::status(ov_dir(st).as_deref());
            v["mark"] = json!(st.config.game_dir.as_deref().map(crate::testbed::client_dir).as_deref().and_then(crate::livelink::last_mark));
            v
        }
        "live_gm" => json!(crate::livelink::make_gm(&ov_dir(st).context("set your Open Vanilla folder first")?)?),
        "live_bring" => {
            let p = project(args)?;
            let ov = ov_dir(st).context("set your Open Vanilla folder first")?;
            let map = s(args, "map")?;
            let id = crate::world::map_id(&p, map).with_context(|| format!("unknown map {map}"))?;
            let f = |k: &str| args.get(k).and_then(Value::as_f64).with_context(|| format!("missing {k}"));
            json!(crate::livelink::bring_me(&ov, s(args, "character")?, id, f("x")?, f("y")?, f("z")?, f("o").unwrap_or(0.0))?)
        }
        "live_apply" => crate::livelink::apply_now(&project(args)?, &ov_dir(st).context("set your Open Vanilla folder first")?)?,
        "play_status" => {
            let p = project(args)?;
            let ov = ov_dir(st);
            play::status(&p, st.config.game_dir.as_deref(), ov.as_deref())
        }
        "play_install" => {
            let p = project(args)?;
            let ov = ov_dir(st);
            let g = need(st)?;
            json!(play::install(&p, g, ov.as_deref())?)
        }
        "play_remove" => {
            let p = project(args)?;
            let ov = ov_dir(st);
            json!(play::remove(&p, st.config.game_dir.as_deref(), ov.as_deref())?)
        }
        "play_cleanup_real" => {
            let g = st.config.game_dir.clone().context("set your game folder first")?;
            json!(play::cleanup_real(&g, ov_dir(st).as_deref())?)
        }
        "play_solo" => {
            let ov = ov_dir(st).context("set your Open Vanilla folder first")?;
            let py = model::find_python(st.config.python.as_deref()).or_else(|_| {
                // play_local.py needs only the standard library
                Ok::<_, anyhow::Error>(if cfg!(windows) { vec!["py".to_string(), "-3".to_string()] } else { vec!["python3".to_string()] })
            })?;
            play::play_solo(&ov, &py, st.config.game_dir.as_deref())?;
            json!(true)
        }
        "set_openvanilla" => {
            let d = PathBuf::from(s(args, "dir")?);
            if !d.join("play_local.py").is_file() {
                bail!("{} isn't an Open Vanilla folder (no play_local.py)", d.display());
            }
            st.config.openvanilla_dir = Some(d.clone());
            st.config.save()?;
            json!(d)
        }
        "publish_gate" => {
            let p = project(args)?;
            let d = data::load(&p);
            json!({
                "findings": publish::gate(&p, st.game.as_ref()),
                "key": publish::public_key_hex()?,
                "license": p.manifest.pack.license,
                "realms": p.manifest.targets.realms,
                "models": model::names(&p).len(),
                "worldRows": d.world.values().map(|r| r.rows.len()).sum::<usize>(),
                "dbcRows": d.dbc.values().map(|r| r.rows.len()).sum::<usize>(),
                "addons": p.addons().len(),
            })
        }
        "publish" => json!(publish::package(&project(args)?, st.game.as_ref())?),
        "assets_children" => json!(need(st)?.children(args.get("folder").and_then(Value::as_str).unwrap_or(""))
            .into_iter().map(|(n, d)| json!({"name": n, "folder": d})).collect::<Vec<_>>()),
        "assets_search" => {
            let limit = args.get("limit").and_then(Value::as_u64).unwrap_or(200) as usize;
            json!(need(st)?.search(s(args, "q")?, limit))
        }
        "assets_preview" => json!(need(st)?.preview(s(args, "path")?)?),
        _ => bail!("unknown command {cmd}"),
    })
}

fn ov_dir(st: &State) -> Option<PathBuf> {
    play::openvanilla_dir(st.config.openvanilla_dir.as_deref(), st.config.game_dir.as_deref())
}

fn running(st: &mut State) -> Result<&mut sim::Session> {
    st.sim.as_mut().context("the sim isn't running: press Run")
}

/// Text files under addons/ (what the Code screen edits).
fn code_files(p: &Project) -> Vec<Value> {
    let root = p.root.join("addons");
    let mut v: Vec<Value> = walkdir::WalkDir::new(&root)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file())
        .filter(|e| {
            let n = e.file_name().to_string_lossy().to_ascii_lowercase();
            [".lua", ".toc", ".xml", ".txt", ".md"].iter().any(|x| n.ends_with(x))
        })
        .map(|e| {
            let rel = e.path().strip_prefix(&p.root).unwrap().to_string_lossy().replace('\\', "/");
            json!({"path": rel, "size": e.metadata().map(|m| m.len()).unwrap_or(0)})
        })
        .collect();
    v.sort_by(|a, b| a["path"].as_str().unwrap().to_ascii_lowercase().cmp(&b["path"].as_str().unwrap().to_ascii_lowercase()));
    v
}

/// A project path the Code screen may touch: under addons/, no `..`.
fn code_path(p: &Project, rel: &str) -> Result<PathBuf> {
    let rel = rel.replace('\\', "/");
    let ok = rel.starts_with("addons/") && !rel.split('/').any(|c| c == ".." || c.is_empty());
    if !ok {
        bail!("the Code screen edits files under addons/ only");
    }
    Ok(p.root.join(rel))
}

fn lint_of(rel: &str, text: &str) -> Value {
    if rel.to_ascii_lowercase().ends_with(".lua") {
        json!(sim::lint(rel, text).unwrap_or_default())
    } else {
        json!([])
    }
}

/// A new .lua in addons/<Name>/ goes on the end of <Name>.toc (the client only loads listed files).
fn add_to_toc(p: &Project, f: &std::path::Path) -> Result<Option<String>> {
    if !f.extension().is_some_and(|e| e.eq_ignore_ascii_case("lua")) {
        return Ok(None);
    }
    let addons = p.root.join("addons");
    let rel = f.strip_prefix(&addons)?;
    let mut parts = rel.components();
    let Some(name) = parts.next().map(|c| c.as_os_str().to_string_lossy().to_string()) else { return Ok(None) };
    let inner: Vec<String> = parts.map(|c| c.as_os_str().to_string_lossy().to_string()).collect();
    if inner.is_empty() {
        return Ok(None);
    }
    let toc = addons.join(&name).join(format!("{name}.toc"));
    let Ok(mut text) = std::fs::read_to_string(&toc) else { return Ok(None) };
    let line = inner.join("\\");
    if text.lines().any(|l| l.trim().eq_ignore_ascii_case(&line)) {
        return Ok(None);
    }
    if !text.ends_with('\n') && !text.is_empty() {
        text.push('\n');
    }
    text.push_str(&line);
    text.push('\n');
    std::fs::write(&toc, text)?;
    Ok(Some(format!("{name}.toc")))
}

fn need(st: &State) -> Result<&GameData> {
    st.game.as_ref().context("Forge doesn't know where your game is yet: choose your game folder on the Home page")
}

/// A short label for what a project mostly is.
fn kind(p: &Project) -> &'static str {
    let has = |d: &str| p.root.join(d).is_dir() && std::fs::read_dir(p.root.join(d)).map(|mut r| r.next().is_some()).unwrap_or(false);
    if has("maps") {
        "zone"
    } else if has("art") || has("files") || has("models") || has("data") {
        "pack"
    } else if has("addons") {
        "addon"
    } else {
        "empty"
    }
}

/// Everything the Project screen shows.
fn open(st: &State, p: &Project) -> Result<Value> {
    let files: Vec<Value> = build::collect(p)
        .map(|m| m.values().map(|e| json!({"path": e.path, "source": e.source.strip_prefix(&p.root).unwrap_or(&e.source), "how": e.how})).collect())
        .unwrap_or_default();
    let lock = ids::IdLock::load(&p.root).unwrap_or_default();
    let last = std::fs::read(p.build_dir().join("report.json")).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok());
    Ok(json!({
        "dir": p.root,
        "manifest": p.manifest,
        "kind": kind(p),
        "addons": p.addons().iter().map(|a| a.file_name().unwrap().to_string_lossy().to_string()).collect::<Vec<_>>(),
        "files": files,
        "ids": lock,
        "findings": check::run(p, st.game.as_ref()),
        "lastBuild": last,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_app_flow_end_to_end() {
        let dir = tempfile::tempdir().unwrap();
        crate::test_config();
        let mut st = State::load();
        let game = crate::vfs::tests::fake_game(&dir.path().join("wow"));
        call(&mut st, "set_game", &json!({"dir": game})).unwrap();
        assert_eq!(call(&mut st, "status", &json!({})).unwrap()["game"]["files"], 2);
        let pdir = dir.path().join("Pack");
        let opened = call(&mut st, "new_project", &json!({"dir": pdir, "name": "Flow Pack", "template": "pack", "author": "Orion"})).unwrap();
        assert_eq!(opened["manifest"]["pack"]["id"], "flow-pack");
        assert_eq!(opened["kind"], "pack");
        let r = call(&mut st, "build", &json!({"dir": pdir})).unwrap();
        assert!(r["files"].as_u64().unwrap() >= 2);
        let id = call(&mut st, "allocate_id", &json!({"dir": pdir, "table": "item_template", "name": "Test"})).unwrap();
        assert!(id["id"].as_u64().unwrap() >= 1_100_000);
        let recent = call(&mut st, "recent", &json!({})).unwrap();
        assert_eq!(recent[0]["name"], "Flow Pack");
        let hits = call(&mut st, "assets_search", &json!({"q": "test"})).unwrap();
        assert_eq!(hits.as_array().unwrap().len(), 2);
        let pv = call(&mut st, "pack_preview", &json!({"dir": pdir, "path": "Interface\\Icons\\INV_FlowPack.blp"})).unwrap();
        assert_eq!(pv["kind"], "image");
    }
}
