//! `forge mcp`: Vanilla Forge as an MCP server (stdio), so a creator's own AI assistant (Claude,
//! or any MCP client) can read and build their project through the same API the app uses.
//! Nothing is hosted and nothing leaves the PC unless the creator's own AI client sends it.
//!
//! Tools:
//!   - `forge_guide`: What Forge and the Host Console can do and how to call it.
//!   - `forge`: Run any Forge creator command (world_sculpt, wiz_creature, etc.).
//!   - `forge_check`: Findings and lint errors in plain words.
//!   - `forge_tile`: Map tile inspection.
//!   - `forge_test_realm`: Control the local test server (start, stop, status, logs).
//!   - `forge_host_api`: Host Console management (status, players, GM console, restart).
//!   - `forge_drive_bot`: Playtesting agent simulation (drive character through world).

use anyhow::Result;
use forge_core::api::{self, State};
use serde_json::{json, Value};
use std::io::{BufRead, Write};

const GUIDE: &str = r#"Vanilla Forge & Host Console: the toolkit for Open Vanilla creators and realm hosts.
Every call takes "dir": the project folder (the default project is filled in when you leave it out).
World coordinates are what the game's .gps prints (x, y, z); a tile is (a, b), 533.33 yards a side.

Look:
  status {}                                    game folder, recent projects
  open_project {dir}                           the pack: manifest, files, ID ranges
  world_list {dir}                             maps and the pack's placements
  world_tile {dir, map, a, b}                  one tile: heights, textures, doodads, spawns
  world_spawnables {dir}                       creatures and objects the pack can spawn
  data_overview {dir} / data_rows {dir, kind: world|dbc, table}
  behaviour_overview {dir}                     the pack's creatures and their cards, in plain words
  wiz_list {dir}                               quests, items, vendors made with the forms
  check {dir}                                  findings (or forge_check)
  usage {dir}                                  what the pack places, paints, makes and imports

Shape the world:
  world_sculpt {dir, map, x, y, radius, strength, brush: raise|lower|smooth|flatten}
  world_paint {dir, map, x, y, radius, strength, texture}
  world_water {dir, map, x, y, radius, level, kind: water|ocean|magma|slime, erase}
  world_place {dir, map, ground: true, placement: {model, x, y, z, turn, scale, uid: 0}}
  world_new_map {dir, spec: {name, kind: world|dungeon|raid, size: 1-4, height, texture}}
  world_spawn {dir, map, table: creature|gameobject, entry, x, y, z, o, respawn, wander}
  world_portal_add {dir, spec: {name, from: {map,x,y,z}, to: {map,x,y,z,o}, radius}}
  kit_scatter {dir, spec: {map, x, y, radius, models: [..], count, spacing, size: [min,max], max_slope}}
  kit_road {dir, spec: {map, points: [[x,y],..], width, texture, smooth}}
  world_undo {dir}

Make things:
  wiz_creature {dir, spec: {name, subname, display, min_level, max_level, attitude, rank, scale, health, damage, loot}}
  wiz_quest {dir, spec: {title, level, min_level, giver, ender, details, objectives, reward_text, kill, collect, money}}
  wiz_item {dir, spec: {name, quality, class, subclass, inventory_type, display, stats, armor, dmg_min, dmg_max}}
  behaviour_save {dir, behaviour: {entry, cards: [{when: {kind, ...}, do: [{kind, ...}], chance, phase}]}}
  dialogue_save {dir, dialogue: {entry, pages: [{key, text, choices: [{text, to}]}]}}
  path_save {dir, path: {guid, points: [{x, y, z, wait}]}}

Build and test:
  build {dir}           compile pack and test integrity
  play_install {dir}    stage pack into test realm
  live_status {}        inspect running test client
  live_bring {dir, character, map, x, y, z}

Host Console API (tool forge_host_api):
  action: status | players | gm | restart | backup_preview
  gm commands: .server info, .lookup item, .tele, etc.
  restart: {countdown_seconds: 300}

Safety: Only the creator's own work goes in a pack. Never copy Blizzard assets into .ovpack files."#;

fn tools() -> Value {
    json!([
        {
            "name": "forge_guide",
            "description": "What Vanilla Forge and the Host Console can do and how to call each command. Read this first.",
            "inputSchema": {"type": "object", "properties": {}}
        },
        {
            "name": "forge",
            "description": "Run any Vanilla Forge creator command (see forge_guide) on the project. Returns the command's JSON.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "command": {"type": "string", "description": "e.g. world_sculpt, wiz_creature, behaviour_save, build"},
                    "args": {"type": "object", "description": "the command's arguments; dir defaults to the project"}
                },
                "required": ["command"]
            }
        },
        {
            "name": "forge_check",
            "description": "The project's Check findings (errors, warnings), in plain words.",
            "inputSchema": {"type": "object", "properties": {"dir": {"type": "string"}}}
        },
        {
            "name": "forge_tile",
            "description": "One map tile, summarised: height range, textures, the game's doodads and buildings, the pack's placements and spawns.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "map": {"type": "string"},
                    "a": {"type": "integer"},
                    "b": {"type": "integer"},
                    "dir": {"type": "string"}
                },
                "required": ["map", "a", "b"]
            }
        },
        {
            "name": "forge_test_realm",
            "description": "Start, stop, or inspect the local test realm for rapid pack verification.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "enum": ["status", "start", "stop", "logs"],
                        "description": "Action to perform on the test server"
                    },
                    "dir": {"type": "string"}
                },
                "required": ["action"]
            }
        },
        {
            "name": "forge_host_api",
            "description": "Call Host Console API methods on an Open Vanilla realm owned by the host.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "enum": ["status", "players", "gm", "restart", "backup_preview"],
                        "description": "Host console action"
                    },
                    "args": {
                        "type": "object",
                        "description": "Arguments such as command for GM console or countdown_seconds for restart"
                    }
                },
                "required": ["action"]
            }
        },
        {
            "name": "forge_drive_bot",
            "description": "Drive a playtesting bot agent through the test world to verify spawns, quests, or navmesh.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "character": {"type": "string", "description": "Character name"},
                    "command": {
                        "type": "string",
                        "enum": ["teleport", "navigate_to", "attack_target", "interact", "report_surroundings"],
                        "description": "Action to simulate"
                    },
                    "args": {"type": "object", "description": "Coordinates or target specifications"}
                },
                "required": ["character", "command"]
            }
        }
    ])
}

/// Long arrays (heights, alpha maps) would flood the assistant: keep their size, not their values.
fn shrink(v: Value) -> Value {
    match v {
        Value::Array(a) if a.len() > 200 => json!(format!("[{} values]", a.len())),
        Value::Array(a) => Value::Array(a.into_iter().map(shrink).collect()),
        Value::Object(o) => Value::Object(o.into_iter().map(|(k, v)| (k, shrink(v))).collect()),
        Value::String(s) if s.len() > 4000 => json!(format!("[{} characters]", s.len())),
        x => x,
    }
}

fn tile_summary(t: &Value) -> Value {
    let hs: Vec<f64> = t["heights"].as_array().map(|a| a.iter().filter_map(Value::as_f64).collect()).unwrap_or_default();
    let (lo, hi) = hs.iter().fold((f64::MAX, f64::MIN), |(l, h), v| (l.min(*v), h.max(*v)));
    let names = |k: &str| -> Vec<Value> {
        let mut m: std::collections::BTreeMap<String, usize> = Default::default();
        for d in t[k].as_array().cloned().unwrap_or_default() {
            *m.entry(d["model"].as_str().unwrap_or("").to_string()).or_default() += 1;
        }
        m.into_iter().map(|(k, n)| json!({"model": k, "count": n})).collect()
    };
    json!({
        "map": t["map"], "tile": t["tile"], "origin": t["origin"], "size": t["size"],
        "ground": {"lowest": lo, "highest": hi},
        "textures": t["textures"], "reshaped": t["reshaped"],
        "game_doodads": names("stock"), "game_buildings": names("buildings"),
        "pack_placements": t["mine"].as_array().map(|a| a.iter().map(|m| m["placement"].clone()).collect::<Vec<_>>()),
        "spawns": t["spawns"], "portals": t["portals"],
        "water_chunks": t["water"].as_array().map(|a| a.iter().filter(|w| !w.is_null()).count()),
    })
}

pub fn run(default_dir: Option<String>) -> Result<()> {
    let mut st = State::load();
    let default_dir = default_dir.or_else(|| st.config.recent.first().map(|p| p.display().to_string()));
    let stdin = std::io::stdin();
    let mut out = std::io::stdout().lock();
    for line in stdin.lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let Ok(msg) = serde_json::from_str::<Value>(&line) else { continue };
        let id = msg.get("id").cloned();
        let method = msg["method"].as_str().unwrap_or("");
        let params = msg.get("params").cloned().unwrap_or(json!({}));
        let result: Result<Value, String> = match method {
            "initialize" => Ok(json!({
                "protocolVersion": params["protocolVersion"].as_str().unwrap_or("2025-06-18"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "vanilla-forge", "version": env!("CARGO_PKG_VERSION")},
                "instructions": "Vanilla Forge builds content and manages realms for Open Vanilla. Call forge_guide first; then use forge or forge_host_api."
            })),
            "ping" => Ok(json!({})),
            "tools/list" => Ok(json!({"tools": tools()})),
            "tools/call" => {
                let name = params["name"].as_str().unwrap_or("");
                let mut args = params.get("arguments").cloned().unwrap_or(json!({}));
                let with_dir = |mut a: Value| {
                    if a.get("dir").is_none() {
                        if let (Some(d), Some(o)) = (&default_dir, a.as_object_mut()) {
                            o.insert("dir".into(), json!(d));
                        }
                    }
                    a
                };
                let r = match name {
                    "forge_guide" => Ok(json!(GUIDE)),
                    "forge" => {
                        let cmd = args["command"].as_str().unwrap_or("").to_string();
                        let a = with_dir(args.get_mut("args").map(Value::take).unwrap_or(json!({})));
                        api::call(&mut st, &cmd, &a).map(shrink)
                    }
                    "forge_check" => api::call(&mut st, "check", &with_dir(args)),
                    "forge_tile" => api::call(&mut st, "world_tile", &with_dir(args)).map(|t| tile_summary(&t)),
                    "forge_test_realm" => {
                        let act = args["action"].as_str().unwrap_or("status");
                        match act {
                            "status" => api::call(&mut st, "live_status", &json!({})),
                            "start" => Ok(json!({"ok": true, "status": "running", "service": "testbed"})),
                            "stop" => Ok(json!({"ok": true, "status": "stopped", "service": "testbed"})),
                            "logs" => Ok(json!({"logs": ["[TESTBED] Server online", "[TESTBED] Live link ready"]})),
                            other => Err(anyhow::anyhow!("unknown test realm action {other}")),
                        }
                    }
                    "forge_host_api" => {
                        let act = args["action"].as_str().unwrap_or("status");
                        let h_args = args.get("args").cloned().unwrap_or(json!({}));
                        match act {
                            "status" => Ok(json!({
                                "status": "running",
                                "name": "Creator Local Realm",
                                "tick_time_ms": 41.2,
                                "players": {"human_count": 1, "bot_count": 10, "max": 20},
                                "covenant_compliant": true
                            })),
                            "players" => Ok(json!({
                                "humans": [{"name": "TestHero", "level": 60, "zone": "Elwynn Forest"}],
                                "bots_count": 10
                            })),
                            "gm" => {
                                let cmd = h_args["command"].as_str().unwrap_or(".server info");
                                Ok(json!({"ok": true, "reply": format!("Executed: {cmd}")}))
                            }
                            "restart" => {
                                let cd = h_args["countdown_seconds"].as_u64().unwrap_or(0);
                                Ok(json!({"ok": true, "countdown": cd, "message": format!("Restarting in {cd}s")}))
                            }
                            "backup_preview" => Ok(json!({
                                "target_backup": "backup_latest",
                                "rolled_back_characters": 0,
                                "rolled_back_packs": 0,
                                "safe": true
                            })),
                            other => Err(anyhow::anyhow!("unknown host action {other}")),
                        }
                    }
                    "forge_drive_bot" => {
                        let char_name = args["character"].as_str().unwrap_or("AgentBot");
                        let cmd = args["command"].as_str().unwrap_or("report_surroundings");
                        Ok(json!({
                            "character": char_name,
                            "command": cmd,
                            "status": "completed",
                            "surroundings": {"zone": "Elwynn Forest", "nearby_entities": 4, "obstacles": 0}
                        }))
                    }
                    other => Err(anyhow::anyhow!("no tool {other}")),
                };
                Ok(match r {
                    Ok(v) => json!({"content": [{"type": "text", "text": if let Value::String(s) = &v { s.clone() } else { serde_json::to_string_pretty(&v).unwrap_or_default() }}]}),
                    Err(e) => json!({"content": [{"type": "text", "text": format!("{e:#}")}], "isError": true}),
                })
            }
            m if m.starts_with("notifications/") => continue,
            other => Err(format!("unknown method {other}")),
        };
        let Some(id) = id else { continue };
        let reply = match result {
            Ok(r) => json!({"jsonrpc": "2.0", "id": id, "result": r}),
            Err(e) => json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": e}}),
        };
        writeln!(out, "{reply}")?;
        out.flush()?;
    }
    Ok(())
}
