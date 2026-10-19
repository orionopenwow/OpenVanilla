//! Model Importer (plan §4.2): a creator's own rigged, animated `.glb`/`.gltf` (or a modern
//! WoW-format `.m2` set) becomes a 1.12.1 creature in the pack.
//!
//! The conversion is Open Vanilla's Model Porter (`tools/modelport`, Python), bundled into Forge
//! and run as a sidecar. Forge keeps each model in the project:
//!
//! ```text
//! models/<Name>/model.toml      what to port and how (kind, title, height, sound, clip mapping, IDs)
//! models/<Name>/source.glb      the creator's model
//! models/<Name>/.port/game/**   the ported M2 + BLP files, at their game paths (shipped by the build)
//! models/<Name>/.port/report.json  what the porter did: warnings, animations, sizes
//! ```
//!
//! and writes the rows that make it a creature (tagged `comment = "model:<Name>"`, so a re-port
//! replaces them): CreatureModelData + CreatureDisplayInfo (copies of a stock model of the same
//! sound family, with the new file and size) and a creature_template row (a copy of a stock
//! creature with the new display).

use crate::data;
use crate::ids::IdLock;
use crate::project::Project;
use crate::vfs::GameData;
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;

const PORTER: &[(&str, &str)] = &[
    ("__init__.py", include_str!("../../../../tools/modelport/__init__.py")),
    ("__main__.py", include_str!("../../../../tools/modelport/__main__.py")),
    ("animdata.py", include_str!("../../../../tools/modelport/animdata.py")),
    ("blp.py", include_str!("../../../../tools/modelport/blp.py")),
    ("content.py", include_str!("../../../../tools/modelport/content.py")),
    ("gltf.py", include_str!("../../../../tools/modelport/gltf.py")),
    ("m2.py", include_str!("../../../../tools/modelport/m2.py")),
    ("m2modern.py", include_str!("../../../../tools/modelport/m2modern.py")),
    ("m2read.py", include_str!("../../../../tools/modelport/m2read.py")),
    ("mpq.py", include_str!("../../../../tools/modelport/mpq.py")),
    ("names.py", include_str!("../../../../tools/modelport/names.py")),
    ("port.py", include_str!("../../../../tools/modelport/port.py")),
    ("server.py", include_str!("../../../../tools/modelport/server.py")),
];

/// The stock creature a new creature row copies (faction, flags, AI ...): the same donor the
/// Model Porter uses for Open Vanilla's own creatures.
pub const CREATURE_DONOR: i64 = 308;

/// Mount spells and reins to copy: (60%, 100%): Brown Horse / Swift Brown Steed, and their items.
pub const MOUNT_SPELL: (i64, i64) = (458, 23229);
pub const MOUNT_ITEM: (i64, i64) = (5656, 18777);

pub const KINDS: &[&str] = &["creature", "mount", "doodad"];
pub const SOUNDS: &[&str] = &["humanoid", "horse", "wolf", "cat", "raptor", "kodo", "ram", "mechanical", "dragon", "bear", "spider"];

/// The porter written out under Forge's config folder (once per version); returns the
/// `modelport` package folder.
pub fn porter_dir() -> Result<PathBuf> {
    let mut h = blake3::Hasher::new();
    for (n, t) in PORTER {
        h.update(n.as_bytes());
        h.update(t.as_bytes());
    }
    let base = crate::config::config_dir().join("modelport").join(&h.finalize().to_hex()[..12]);
    let dir = base.join("modelport");
    if !base.join(".ok").exists() {
        std::fs::create_dir_all(&dir)?;
        for (n, t) in PORTER {
            std::fs::write(dir.join(n), t)?;
        }
        std::fs::write(base.join(".ok"), "")?;
    }
    Ok(dir)
}

fn split_cmd(s: &str) -> Vec<String> {
    s.split_whitespace().map(String::from).collect()
}

/// A Python 3 with numpy and Pillow: the configured one, else the usual names on PATH.
pub fn find_python(configured: Option<&str>) -> Result<Vec<String>> {
    let mut cands: Vec<Vec<String>> = vec![];
    if let Some(c) = configured.filter(|c| !c.trim().is_empty()) {
        cands.push(split_cmd(c));
    }
    // the one the installer ships (with numpy and Pillow): what most creators use
    if let Ok(b) = std::env::var("FORGE_BUNDLED_PYTHON") {
        cands.push(vec![b]);
    }
    if cfg!(windows) {
        cands.push(vec!["py".into(), "-3".into()]);
    }
    cands.push(vec!["python3".into()]);
    cands.push(vec!["python".into()]);
    let mut found_without_packages = None;
    for c in cands {
        let mut cmd = Command::new(&c[0]);
        cmd.args(&c[1..]).args(["-c", "import sys; assert sys.version_info >= (3, 8); import numpy, PIL; print('ok')"]);
        no_window(&mut cmd);
        match cmd.output() {
            Ok(o) if o.status.success() => return Ok(c),
            Ok(_) => {
                if found_without_packages.is_none() {
                    found_without_packages = Some(c.join(" "));
                }
            }
            Err(_) => {}
        }
    }
    match found_without_packages {
        Some(p) => bail!("{p} is missing what the Model Porter needs. Run:  {p} -m pip install numpy Pillow fast-simplification"),
        None => bail!("the Model Porter needs Python 3 (python.org/downloads, tick \"Add to PATH\"), then: pip install numpy Pillow fast-simplification"),
    }
}

#[cfg(windows)]
fn no_window(cmd: &mut Command) {
    use std::os::windows::process::CommandExt;
    cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
}
#[cfg(not(windows))]
fn no_window(_: &mut Command) {}

// ---------------------------------------------------------------- the project's models

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ModelIds {
    pub model: Option<u32>,
    pub display: Option<u32>,
    pub creature: Option<u32>,
    /// Mounts: the summon spell and the reins item.
    #[serde(default)]
    pub spell: Option<u32>,
    #[serde(default)]
    pub item: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelSpec {
    /// The source file in the model's folder.
    pub source: String,
    #[serde(default = "creature")]
    pub kind: String,
    #[serde(default)]
    pub title: String,
    /// Height in yards (default: the model's own metres).
    pub height: Option<f64>,
    pub facing: Option<String>,
    pub texture_max: Option<u32>,
    pub max_triangles: Option<u32>,
    /// What players bump into: "mesh" (the model's shape: doorways, roofs), "box" or "none".
    /// Default: mesh for doodads, box otherwise.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub collision: Option<String>,
    /// The stock sound family the creature borrows (and its DBC donor).
    pub sound: Option<String>,
    /// Clip -> "id", "id:speed" or "skip".
    #[serde(default)]
    pub anims: BTreeMap<String, String>,
    /// Mounts: "normal" (60%, level 40, like the Brown Horse) or "epic" (100%, level 60).
    #[serde(default)]
    pub speed: Option<String>,
    /// Mounts: the reins' name (default "Reins of the <title>").
    #[serde(default)]
    pub item_name: Option<String>,
    #[serde(default)]
    pub ids: ModelIds,
}

fn creature() -> String {
    "creature".into()
}

pub fn models_dir(p: &Project) -> PathBuf {
    p.root.join("models")
}

fn spec_path(p: &Project, name: &str) -> PathBuf {
    models_dir(p).join(name).join("model.toml")
}

pub fn load_spec(p: &Project, name: &str) -> Result<ModelSpec> {
    let t = std::fs::read_to_string(spec_path(p, name)).with_context(|| format!("models/{name} has no model.toml"))?;
    toml::from_str(&t).with_context(|| format!("models/{name}/model.toml isn't valid"))
}

pub fn save_spec(p: &Project, name: &str, s: &ModelSpec) -> Result<()> {
    std::fs::write(spec_path(p, name), toml::to_string_pretty(s)?)?;
    Ok(())
}

/// Every model folder (one with a model.toml).
pub fn names(p: &Project) -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir(models_dir(p))
        .map(|rd| rd.filter_map(|e| e.ok()).filter(|e| e.path().join("model.toml").is_file()).map(|e| e.file_name().to_string_lossy().to_string()).collect())
        .unwrap_or_default();
    v.sort();
    v
}

pub fn report(p: &Project, name: &str) -> Option<Value> {
    serde_json::from_slice(&std::fs::read(models_dir(p).join(name).join(".port/report.json")).ok()?).ok()
}

/// The list the Models screen shows.
pub fn list(p: &Project) -> Value {
    json!(names(p)
        .into_iter()
        .map(|n| {
            let spec = load_spec(p, &n).ok();
            json!({"name": n, "spec": spec, "report": report(p, &n)})
        })
        .collect::<Vec<_>>())
}

/// Turn a model name into a game-safe one (letters and digits, starting with a letter).
pub fn safe_name(s: &str) -> String {
    let mut out = String::new();
    let mut up = true;
    for c in s.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(if up { c.to_ascii_uppercase() } else { c });
            up = false;
        } else {
            up = true;
        }
    }
    if out.chars().next().is_some_and(|c| c.is_ascii_digit()) {
        out.insert(0, 'M');
    }
    out.truncate(40);
    out
}

/// Copy a model into the project and write its model.toml (not ported yet).
pub fn import(p: &Project, source: &Path, name: &str, mut spec: ModelSpec) -> Result<String> {
    let stem = source.file_stem().unwrap_or_default().to_string_lossy().to_string();
    let name = safe_name(if name.is_empty() { &stem } else { name });
    if name.is_empty() {
        bail!("the model needs a name (letters and digits)");
    }
    let ext = source.extension().map(|e| e.to_string_lossy().to_ascii_lowercase()).unwrap_or_default();
    if !["glb", "gltf", "m2"].contains(&ext.as_str()) {
        bail!("Forge imports .glb, .gltf or .m2 (with its .skin/.anim/.skel/.blp files beside it)");
    }
    let dir = models_dir(p).join(&name);
    std::fs::create_dir_all(&dir)?;
    match ext.as_str() {
        "glb" => {
            std::fs::copy(source, dir.join("source.glb")).with_context(|| format!("can't read {}", source.display()))?;
            spec.source = "source.glb".into();
        }
        _ => {
            // a .gltf or .m2 comes with files beside it: copy the folder's files that belong to it
            let src_dir = source.parent().context("no folder")?;
            let stem = source.file_stem().unwrap().to_string_lossy().to_ascii_lowercase();
            for e in std::fs::read_dir(src_dir)?.filter_map(|e| e.ok()) {
                let n = e.file_name().to_string_lossy().to_string();
                let l = n.to_ascii_lowercase();
                let belongs = l.starts_with(&stem) || l.ends_with(".bin") || l.ends_with(".png") || l.ends_with(".jpg") || l.ends_with(".blp") || l.ends_with(".skin") || l.ends_with(".anim") || l.ends_with(".skel");
                if e.path().is_file() && belongs {
                    std::fs::copy(e.path(), dir.join(&n))?;
                }
            }
            spec.source = source.file_name().unwrap().to_string_lossy().to_string();
        }
    }
    if spec.title.is_empty() {
        spec.title = name.clone();
    }
    if let Ok(old) = load_spec(p, &name) {
        spec.ids = old.ids; // re-importing keeps the IDs
    }
    save_spec(p, &name, &spec)?;
    Ok(name)
}

/// Run the porter on one model, then write its rows. `game` gives the stock donors.
pub fn port(p: &Project, name: &str, python: &[String], game: Option<&GameData>) -> Result<Value> {
    let mut spec = load_spec(p, name)?;
    if !KINDS.contains(&spec.kind.as_str()) {
        bail!("kind is creature, mount or doodad");
    }
    let dir = models_dir(p).join(name);
    let src = dir.join(&spec.source);
    if !src.is_file() {
        bail!("models/{name}/{} is missing", spec.source);
    }
    let out = dir.join(".port");
    let _ = std::fs::remove_dir_all(&out);
    std::fs::create_dir_all(&out)?;
    // doodads (props placed on the map) live under World\, like the game's own
    let doodad = spec.kind == "doodad";
    let folder = if doodad {
        format!("World\\Forge\\{}\\{}", safe_name(&p.manifest.pack.id), name)
    } else {
        format!("Creature\\{}\\{}", safe_name(&p.manifest.pack.id), name)
    };
    let porter = porter_dir()?;
    let mut cmd = Command::new(&python[0]);
    cmd.args(&python[1..]).arg(&porter).arg(&src);
    cmd.args(["--name", name, "--kind", &spec.kind, "--title", &spec.title, "--folder", &folder]);
    cmd.arg("--out").arg(out.join("game")).arg("--report").arg(out.join("report.json")).arg("--preview").arg(out.join("preview.json"));
    if let Some(h) = spec.height {
        cmd.args(["--height", &h.to_string()]);
    }
    if let Some(f) = &spec.facing {
        cmd.args(["--facing", f]);
    }
    if let Some(t) = spec.texture_max {
        cmd.args(["--texture-max", &t.to_string()]);
    }
    if let Some(t) = spec.max_triangles {
        cmd.args(["--max-triangles", &t.to_string()]);
    }
    if let Some(c) = spec.collision.as_deref().filter(|c| ["mesh", "box", "none"].contains(c)) {
        cmd.args(["--collision", c]);
    }
    if let Some(s) = &spec.sound {
        cmd.args(["--sound", s]);
    }
    for (clip, v) in &spec.anims {
        cmd.args(["--anim", &format!("{clip}={v}")]);
    }
    cmd.env("PYTHONIOENCODING", "utf-8");
    no_window(&mut cmd);
    let o = cmd.output().context("couldn't run Python")?;
    let log = format!("{}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr));
    let mut rep: Value = std::fs::read(out.join("report.json"))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .with_context(|| format!("the Model Porter stopped:\n{}", log.trim()))?;
    if rep["ok"] != json!(true) {
        bail!("{}", rep["error"].as_str().unwrap_or("the Model Porter couldn't port this model"));
    }
    if doodad {
        // a prop: no creature rows (and none left from when it was one)
        let tag = format!("model:{name}");
        for (kind, table) in [("dbc", "CreatureModelData"), ("dbc", "CreatureDisplayInfo"), ("world", "creature_template"), ("dbc", "Spell"), ("world", "item_template")] {
            replace_rows(p, kind, table, &tag, vec![])?;
        }
        rep["doodad"] = json!(rep["meta"]["model_path"]);
        rep["forge_notes"] = json!(["A doodad: place it on the World screen. Its collision mesh reaches the server too (Test in game, and the realm build)."]);
        rep["log"] = json!(log.trim());
        std::fs::write(out.join("report.json"), serde_json::to_vec_pretty(&rep)?)?;
        return Ok(rep);
    }
    // IDs: once per model, kept across re-ports
    let mut lock = IdLock::load(&p.root)?;
    let pack = p.manifest.pack.id.clone();
    let mut take = |slot: &mut Option<u32>, table: &str| -> Result<u32> {
        if let Some(id) = *slot {
            return Ok(id);
        }
        let id = lock.allocate(&pack, table, name)?;
        *slot = Some(id);
        Ok(id)
    };
    let model_id = take(&mut spec.ids.model, "CreatureModelData")?;
    let display_id = take(&mut spec.ids.display, "CreatureDisplayInfo")?;
    let creature_id = take(&mut spec.ids.creature, "creature_template")?;
    let mount = spec.kind == "mount";
    let (spell_id, item_id) = if mount {
        (Some(take(&mut spec.ids.spell, "Spell")?), Some(take(&mut spec.ids.item, "item_template")?))
    } else {
        (None, None)
    };
    lock.save(&p.root)?;
    save_spec(p, name, &spec)?;

    let meta = &rep["meta"];
    let tag = format!("model:{name}");
    let (donor_model, donor_display) = donors(game, &rep);
    let f = |x: f64| toml::Value::Float(x);
    let mut cmd_row = toml::Table::new();
    cmd_row.insert("comment".into(), tag.clone().into());
    cmd_row.insert("ID".into(), (model_id as i64).into());
    if let Some(d) = donor_model {
        cmd_row.insert("clone".into(), (d as i64).into());
    }
    cmd_row.insert("ModelName".into(), meta["model_path"].as_str().unwrap_or("").into());
    cmd_row.insert("CollisionWidth".into(), f((meta["width"].as_f64().unwrap_or(1.0) / 2.0).max(0.4)));
    cmd_row.insert("CollisionHeight".into(), f(meta["height"].as_f64().unwrap_or(1.0).max(0.5)));
    let mut cdi = toml::Table::new();
    cdi.insert("comment".into(), tag.clone().into());
    cdi.insert("ID".into(), (display_id as i64).into());
    if let Some(d) = donor_display {
        cdi.insert("clone".into(), (d as i64).into());
    }
    cdi.insert("ModelID".into(), (model_id as i64).into());
    cdi.insert("CreatureModelScale".into(), f(1.0));
    cdi.insert("CreatureModelAlpha".into(), 255i64.into());
    cdi.insert(
        "TextureVariation".into(),
        toml::Value::Array(vec![meta["texture_variation"].as_str().unwrap_or("").into(), "".into(), "".into()]),
    );
    let mut ct = toml::Table::new();
    ct.insert("comment".into(), tag.clone().into());
    ct.insert("clone".into(), CREATURE_DONOR.into());
    ct.insert("Entry".into(), (creature_id as i64).into());
    ct.insert("Name".into(), spec.title.clone().into());
    ct.insert("DisplayId1".into(), (display_id as i64).into());
    for k in ["DisplayId2", "DisplayId3", "DisplayId4", "DisplayIdProbability2", "DisplayIdProbability3", "DisplayIdProbability4"] {
        ct.insert(k.into(), 0i64.into());
    }
    ct.insert("DisplayIdProbability1".into(), 100i64.into());
    ct.insert("Scale".into(), f(1.0));
    replace_rows(p, "dbc", "CreatureModelData", &tag, vec![cmd_row])?;
    replace_rows(p, "dbc", "CreatureDisplayInfo", &tag, vec![cdi])?;
    replace_rows(p, "world", "creature_template", &tag, vec![ct])?;
    let (mut spells, mut items) = (vec![], vec![]);
    if let (Some(sp), Some(it)) = (spell_id, item_id) {
        // the summon spell and the reins, copied from the Brown Horse (60%) or Swift Brown Steed (100%)
        let epic = spec.speed.as_deref() == Some("epic");
        let desc = format!("Summons and dismisses a rideable {}.{}", spec.title, if epic { "  This is a very fast mount." } else { "" });
        let mut s = toml::Table::new();
        s.insert("comment".into(), tag.clone().into());
        s.insert("ID".into(), (sp as i64).into());
        s.insert("clone".into(), (if epic { MOUNT_SPELL.1 } else { MOUNT_SPELL.0 }).into());
        s.insert("Name_lang".into(), spec.title.clone().into());
        s.insert("Description_lang".into(), desc.clone().into());
        // effect 1 of both donors is the mount aura (78): its misc value is the creature ridden
        s.insert("EffectMiscValue".into(), toml::Value::Array(vec![(creature_id as i64).into(), 0i64.into(), 0i64.into()]));
        spells.push(s);
        let mut i = toml::Table::new();
        i.insert("comment".into(), tag.clone().into());
        i.insert("clone".into(), (if epic { MOUNT_ITEM.1 } else { MOUNT_ITEM.0 }).into());
        i.insert("entry".into(), (it as i64).into());
        i.insert("name".into(), spec.item_name.clone().filter(|n| !n.is_empty()).unwrap_or_else(|| format!("Reins of the {}", spec.title)).into());
        i.insert("spellid_1".into(), (sp as i64).into());
        i.insert("Quality".into(), (if epic { 4i64 } else { 3 }).into());
        i.insert("RequiredLevel".into(), (if epic { 60i64 } else { 40 }).into());
        i.insert("description".into(), desc.into());
        items.push(i);
    }
    replace_rows(p, "dbc", "Spell", &tag, spells)?;
    replace_rows(p, "world", "item_template", &tag, items)?;

    let mut notes = vec![];
    if game.is_none() {
        notes.push("Your game folder isn't set, so the display rows don't copy a stock model's sounds and blood: set it on Home and port again.".to_string());
    }
    rep["ids"] = json!({"model": model_id, "display": display_id, "creature": creature_id, "spell": spell_id, "item": item_id});
    rep["forge_notes"] = json!(notes);
    rep["log"] = json!(log.trim());
    std::fs::write(out.join("report.json"), serde_json::to_vec_pretty(&rep)?)?;
    Ok(rep)
}

/// The stock CreatureModelData record whose file is the first present donor path, and a
/// CreatureDisplayInfo record that shows it.
fn donors(game: Option<&GameData>, rep: &Value) -> (Option<u32>, Option<u32>) {
    let Some(g) = game else { return (None, None) };
    let (Ok(cmd), Ok(cdi)) = (data::read_stock(g, "CreatureModelData"), data::read_stock(g, "CreatureDisplayInfo")) else { return (None, None) };
    let want: Vec<String> = rep["donors"].as_array().map(|a| a.iter().filter_map(|v| v.as_str()).map(|s| s.to_ascii_lowercase()).collect()).unwrap_or_default();
    for w in &want {
        if let Some(r) = cmd.records.iter().find(|r| cmd.string(r[2]).to_ascii_lowercase() == *w) {
            let model = r[0];
            let display = cdi.records.iter().find(|d| d[1] == model).map(|d| d[0]);
            return (Some(model), display);
        }
    }
    (None, None)
}

/// Replace the rows tagged `tag` in one table's file with `rows`.
fn replace_rows(p: &Project, kind: &str, table: &str, tag: &str, rows: Vec<toml::Table>) -> Result<()> {
    let d = data::load(p);
    let m = if kind == "world" { &d.world } else { &d.dbc };
    let mut all: Vec<toml::Table> = m.get(table).map(|r| r.rows.clone()).unwrap_or_default();
    all.retain(|r| r.get("comment").and_then(toml::Value::as_str) != Some(tag));
    all.extend(rows);
    data::save_rows(p, kind, table, &all)?;
    Ok(())
}

/// The ported model for the 3D view: the porter's viewer JSON, and each texture as a PNG data URL
/// (null where the model points at a texture the pack doesn't have).
pub fn preview(p: &Project, name: &str) -> Result<Value> {
    let dir = models_dir(p).join(name).join(".port");
    let mut prev: Value = serde_json::from_slice(&std::fs::read(dir.join("preview.json")).context("port the model first")?)?;
    let rep = report(p, name).unwrap_or_default();
    let folder = rep["meta"]["model_path"].as_str().unwrap_or("").rsplit_once('\\').map(|x| x.0.to_string()).unwrap_or_default();
    let tv = rep["meta"]["texture_variation"].as_str().unwrap_or("").to_string();
    let mut urls = vec![];
    for t in prev["textures"].as_array().cloned().unwrap_or_default() {
        // type 11 is the creature skin (CreatureDisplayInfo's TextureVariation); 0 a file name
        let game_path = if t["type"] == 11 { format!("{folder}\\{tv}.blp") } else { t["file"].as_str().unwrap_or("").to_string() };
        let file = dir.join("game").join(game_path.replace('\\', "/"));
        let url = std::fs::read(&file).ok().and_then(|b| crate::vfs::preview_bytes(&game_path, &b).ok()).and_then(|pv| match pv {
            crate::vfs::Preview::Image { png, .. } => Some(format!("data:image/png;base64,{png}")),
            _ => None,
        });
        urls.push(json!(url));
    }
    prev["texture_urls"] = json!(urls);
    Ok(prev)
}

/// Remove a model: its folder and its rows (the IDs stay taken).
pub fn remove(p: &Project, name: &str) -> Result<()> {
    let dir = models_dir(p).join(name);
    if !dir.join("model.toml").is_file() {
        bail!("no model {name}");
    }
    std::fs::remove_dir_all(&dir)?;
    let tag = format!("model:{name}");
    for (kind, table) in [("dbc", "CreatureModelData"), ("dbc", "CreatureDisplayInfo"), ("world", "creature_template"), ("dbc", "Spell"), ("world", "item_template")] {
        replace_rows(p, kind, table, &tag, vec![])?;
    }
    Ok(())
}

/// The game files a model ships (its ported M2 and BLPs), for build::collect.
pub fn game_files(p: &Project) -> Vec<(String, PathBuf)> {
    let mut out = vec![];
    for n in names(p) {
        let g = models_dir(p).join(&n).join(".port/game");
        for e in walkdir::WalkDir::new(&g).into_iter().filter_map(|e| e.ok()).filter(|e| e.file_type().is_file()) {
            let rel = e.path().strip_prefix(&g).unwrap().components().map(|c| c.as_os_str().to_string_lossy().to_string()).collect::<Vec<_>>().join("\\");
            out.push((rel, e.into_path()));
        }
    }
    out.sort();
    out
}

/// Checks: unported models, and models converted from a modern WoW model (Publish refuses those).
pub fn check(p: &Project) -> Vec<crate::check::Finding> {
    use crate::check::Finding;
    let mut out = vec![];
    for n in names(p) {
        let at = format!("models/{n}");
        match load_spec(p, &n) {
            Err(e) => out.push(Finding::error("models.spec", &at, format!("{e:#}"))),
            Ok(_) => match report(p, &n) {
                None => out.push(Finding::warning("models.unported", &at, format!("{n} isn't ported yet: press Port on the Models screen"))),
                Some(r) => {
                    if r["source_format"] == "modern-m2" {
                        out.push(Finding::warning(
                            "models.retail",
                            &at,
                            format!("{n} was converted from a newer game model. Packs may only ship models you made or have the rights to: Publish refuses converted game models."),
                        ));
                    }
                    for w in r["warnings"].as_array().into_iter().flatten() {
                        out.push(Finding::info("models.porter", &at, w.as_str().unwrap_or("").to_string()));
                    }
                }
            },
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::{create, Template};

    #[test]
    fn the_porter_list_matches_the_repo() {
        let here = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../tools/modelport");
        let mut want: Vec<String> = std::fs::read_dir(here).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().to_string()).filter(|n| n.ends_with(".py")).collect();
        want.sort();
        let have: Vec<String> = PORTER.iter().map(|(n, _)| n.to_string()).collect();
        assert_eq!(have, want, "add new tools/modelport/*.py files to model::PORTER");
    }

    #[test]
    fn names_are_game_safe() {
        assert_eq!(safe_name("emberwing drake!"), "EmberwingDrake");
        assert_eq!(safe_name("3 headed dog"), "M3HeadedDog");
    }

    /// Needs Python 3 with numpy and Pillow (CI's Linux runner has them; skipped otherwise).
    #[test]
    fn a_glb_becomes_a_creature() {
        crate::test_config();
        let Ok(py) = find_python(None) else {
            eprintln!("no Python with numpy + Pillow: skipped");
            return;
        };
        let dir = tempfile::tempdir().unwrap();
        // the porter's own test model
        let glb = dir.path().join("tail.glb");
        let tests = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../tests");
        let tools = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../tools");
        let ok = Command::new(&py[0])
            .args(&py[1..])
            .arg("-c")
            .arg(format!(
                "import sys; sys.path[:0] = [{:?}, {:?}]; from test_modelport import make_glb; make_glb({:?})",
                tests.to_string_lossy(),
                tools.to_string_lossy(),
                glb.to_string_lossy()
            ))
            .status()
            .unwrap()
            .success();
        if !ok {
            eprintln!("couldn't make the test model: skipped");
            return;
        }
        let p = create(dir.path().join("p"), "Model Pack", "Orion", Template::Empty).unwrap();
        let name = import(&p, &glb, "Tail Beast", ModelSpec { source: String::new(), kind: "mount".into(), title: "Tail Beast".into(), height: Some(2.0), facing: None, texture_max: None, max_triangles: None, collision: None, sound: Some("wolf".into()), anims: Default::default(), speed: Some("epic".into()), item_name: None, ids: Default::default() }).unwrap();
        assert_eq!(name, "TailBeast");
        let rep = port(&p, &name, &py, None).unwrap();
        assert_eq!(rep["ok"], true, "{rep}");
        let files = game_files(&p);
        assert!(files.iter().any(|(g, _)| g == "Creature\\ModelPack\\TailBeast\\TailBeast.m2"), "{files:?}");
        let d = data::load(&p);
        let ct = &d.world["creature_template"].rows[0];
        assert_eq!(ct["clone"].as_integer(), Some(CREATURE_DONOR));
        assert_eq!(ct["DisplayId1"].as_integer(), Some(rep["ids"]["display"].as_i64().unwrap()));
        assert_eq!(d.dbc["CreatureModelData"].rows[0]["ModelName"].as_str(), Some("Creature\\ModelPack\\TailBeast\\TailBeast.mdx"));
        let sp = &d.dbc["Spell"].rows[0];
        assert_eq!(sp["clone"].as_integer(), Some(MOUNT_SPELL.1));
        assert_eq!(sp["EffectMiscValue"].as_array().unwrap()[0].as_integer(), rep["ids"]["creature"].as_i64());
        let it = &d.world["item_template"].rows[0];
        assert_eq!(it["spellid_1"].as_integer(), rep["ids"]["spell"].as_i64());
        assert_eq!(it["name"].as_str(), Some("Reins of the Tail Beast"));
        let f = crate::check::run(&p, None);
        assert!(!f.iter().any(|x| x.level == crate::check::Level::Error), "{f:?}");
        // re-port keeps the IDs and doesn't duplicate rows
        let pv = preview(&p, &name).unwrap();
        assert!(pv["pos"].as_array().unwrap().len() > 9 && !pv["anims"].as_array().unwrap().is_empty());
        assert!(pv["texture_urls"][0].as_str().unwrap().starts_with("data:image/png;base64,"), "{}", pv["texture_urls"]);
        let again = port(&p, &name, &py, None).unwrap();
        assert_eq!(again["ids"], rep["ids"]);
        assert_eq!(data::load(&p).world["creature_template"].rows.len(), 1);
        let r = crate::build::build(&p, None).unwrap();
        assert!(r.files >= 2 && r.data.sql);
        remove(&p, &name).unwrap();
        assert!(data::load(&p).world.get("creature_template").is_none_or(|r| r.rows.is_empty()));
    }
}
