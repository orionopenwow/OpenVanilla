//! Addon Studio's engine: the Open Vanilla Lua sim (`devkit/sim`), bundled into Forge, so a
//! creator can lint an addon for the 1.12 client's Lua 5.0 and run it in a fake client without
//! starting the game (plan §4.4).
//!
//! * `lint` — syntax (the Lua parser) and the sim's Lua 5.0 guard (`#`, `%`, `select`, `gmatch` ...).
//! * `Session` — one fake 1.12.1 client with the project's addons loaded and logged in. Type
//!   slash commands, click buttons by their text, fire events, advance time or run Lua inside the
//!   client, and see the chat, the windows on screen and every Lua error.
//!
//! The sim kit is the same code the repo's 481 addon tests run on; Forge writes it to its config
//! folder once per version and runs it in an embedded Lua 5.1 (with the sim's 5.0 rules on top).

use anyhow::{bail, Context, Result};
use mlua::{Function, Lua, LuaSerdeExt, RegistryKey, Table, Value as LV};
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// The sim kit, as it is in the repo.
const KIT: &[(&str, &str)] = &[
    ("wow_api.lua", include_str!("../../../../devkit/sim/wow_api.lua")),
    ("lua50_guard.lua", include_str!("../../../../devkit/sim/lua50_guard.lua")),
    ("ext/combatlog.lua", include_str!("../../../../devkit/sim/ext/combatlog.lua")),
    ("ext/guildhub.lua", include_str!("../../../../devkit/sim/ext/guildhub.lua")),
    ("ext/loot_aoe.lua", include_str!("../../../../devkit/sim/ext/loot_aoe.lua")),
    ("ext/mail_loot_talents.lua", include_str!("../../../../devkit/sim/ext/mail_loot_talents.lua")),
    ("ext/plates_pos.lua", include_str!("../../../../devkit/sim/ext/plates_pos.lua")),
    ("ext/quests.lua", include_str!("../../../../devkit/sim/ext/quests.lua")),
    ("ext/social.lua", include_str!("../../../../devkit/sim/ext/social.lua")),
    ("ext/units_actions.lua", include_str!("../../../../devkit/sim/ext/units_actions.lua")),
    ("ext/world.lua", include_str!("../../../../devkit/sim/ext/world.lua")),
    ("data/events_112.txt", include_str!("../../../../devkit/sim/data/events_112.txt")),
    ("data/globals_112.tsv", include_str!("../../../../devkit/sim/data/globals_112.tsv")),
    ("data/widget_methods_112.txt", include_str!("../../../../devkit/sim/data/widget_methods_112.txt")),
];

/// The kit written out (once per kit version) under Forge's config folder; returns its folder.
pub fn kit_dir() -> Result<PathBuf> {
    let mut h = blake3::Hasher::new();
    for (n, t) in KIT {
        h.update(n.as_bytes());
        h.update(t.as_bytes());
    }
    let dir = crate::config::config_dir().join("simkit").join(&h.finalize().to_hex()[..12]);
    if !dir.join(".ok").exists() {
        for (n, t) in KIT {
            let p = dir.join(n);
            std::fs::create_dir_all(p.parent().unwrap())?;
            std::fs::write(&p, t)?;
        }
        std::fs::write(dir.join(".ok"), "")?;
    }
    Ok(dir)
}

fn slash(p: &Path) -> String {
    let s = p.to_string_lossy().replace('\\', "/");
    if s.ends_with('/') { s } else { s + "/" }
}

/// A Lua with the sim's directory lister (no `ls` on Windows).
fn new_lua() -> Result<Lua> {
    // the sim reads its own path through `debug.getinfo` (mlua leaves `debug` out of a safe Lua).
    // The code it runs is the creator's own addon, on their own machine.
    let lua = unsafe { Lua::unsafe_new_with(mlua::StdLib::ALL, mlua::LuaOptions::default()) };
    let list = lua.create_function(|_, dir: String| {
        let mut v: Vec<String> = std::fs::read_dir(&dir)
            .map(|rd| rd.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().to_string()).collect())
            .unwrap_or_default();
        v.sort();
        Ok(v)
    })?;
    lua.globals().set("SIM_LIST_DIR", list)?;
    Ok(lua)
}

#[derive(Debug, Clone, Serialize)]
pub struct LintIssue {
    pub line: u32,
    /// syntax | lua50
    pub kind: String,
    pub message: String,
}

/// Lint one Lua file's text: does it parse, and does it stay inside Lua 5.0?
pub fn lint(name: &str, src: &str) -> Result<Vec<LintIssue>> {
    let lua = new_lua()?;
    let kit = slash(&kit_dir()?);
    let mut out = vec![];
    if let Err(e) = lua.load(src).set_name(format!("={name}")).into_function() {
        let msg = match &e {
            mlua::Error::SyntaxError { message, .. } => message.clone(),
            other => other.to_string(),
        };
        // "name:12: unexpected symbol near 'x'"
        let (line, text) = msg
            .strip_prefix(&format!("{name}:"))
            .and_then(|r| r.split_once(':'))
            .and_then(|(l, t)| l.parse::<u32>().ok().map(|l| (l, t.trim().to_string())))
            .unwrap_or((0, msg.clone()));
        out.push(LintIssue { line, kind: "syntax".into(), message: text });
    }
    let guard: Table = lua.load(format!("return dofile({:?})", kit.clone() + "lua50_guard.lua")).eval()?;
    let scan: Function = guard.get("scan")?;
    let issues: Table = scan.call(src)?;
    for it in issues.sequence_values::<Table>() {
        let it = it?;
        out.push(LintIssue { line: it.get::<Option<u32>>("line")?.unwrap_or(0), kind: "lua50".into(), message: it.get::<Option<String>>("msg")?.unwrap_or_default() });
    }
    out.sort_by_key(|i| i.line);
    Ok(out)
}

// ---------------------------------------------------------------- a running client

pub struct Session {
    lua: Lua,
    api: RegistryKey,
    env: RegistryKey,
    /// The project's addons, copied to a scratch AddOns folder the sim loads from.
    _scratch: tempfile_lite::Dir,
    pub addons: Vec<String>,
    errors_seen: usize,
    chat_seen: usize,
    /// Frames the stock client already had: "windows" lists only what the addons made.
    stock: HashSet<String>,
}

/// What the client shows after a step.
#[derive(Debug, Serialize)]
pub struct Snapshot {
    /// Lua errors since the last step (and what the sim knows about them).
    pub errors: Vec<String>,
    /// Chat lines since the last step.
    pub chat: Vec<String>,
    /// The addons' named top-level frames that are on screen, with their visible text.
    pub windows: Vec<Window>,
    /// What a `run` returned.
    pub result: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct Window {
    pub name: String,
    pub texts: Vec<String>,
}

pub struct Options {
    pub name: String,
    pub class: String,
    pub race: String,
    pub level: u32,
}

impl Default for Options {
    fn default() -> Self {
        Options { name: "Forgehand".into(), class: "WARRIOR".into(), race: "Human".into(), level: 60 }
    }
}

mod tempfile_lite {
    //! A scratch folder removed on drop (no dev-dependency in the library).
    use std::path::{Path, PathBuf};
    pub struct Dir(pub PathBuf);
    impl Dir {
        pub fn new(tag: &str) -> std::io::Result<Dir> {
            let n = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
            let p = std::env::temp_dir().join(format!("forge-{tag}-{}-{n}", std::process::id()));
            std::fs::create_dir_all(&p)?;
            Ok(Dir(p))
        }
        pub fn path(&self) -> &Path {
            &self.0
        }
    }
    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}

fn copy_tree(from: &Path, to: &Path) -> Result<()> {
    for e in walkdir::WalkDir::new(from).into_iter().filter_map(|e| e.ok()) {
        let rel = e.path().strip_prefix(from).unwrap();
        let dst = to.join(rel);
        if e.file_type().is_dir() {
            std::fs::create_dir_all(&dst)?;
        } else {
            std::fs::copy(e.path(), &dst)?;
        }
    }
    Ok(())
}

const START: &str = r#"
local KIT, REPO, NAMES, O = ...
local api = dofile(KIT .. "wow_api.lua")
api.repo = REPO
local env = api.new_client{ name = O.name, class = O.class, race = O.race, level = O.level, repo = REPO, art = true }
local stock = {}
for _, f in ipairs(env.__frames) do local s = api.state(f); if s.name then stock[s.name] = true end end
for _, n in ipairs(NAMES) do api.load_with_deps(env, n) end
api.login(env)
return api, env, stock
"#;

const SNAP: &str = r#"
local api, env, eseen, cseen = ...
local errors, chat, wins = {}, {}, {}
for i = eseen + 1, table.getn(env.__errors) do table.insert(errors, tostring(env.__errors[i])) end
for i = 1, table.getn(env.__pcall_errors or {}) do table.insert(errors, "swallowed by pcall: " .. tostring(env.__pcall_errors[i])) end
env.__pcall_errors = {}
local lines = api.chat_lines(env)
for i = cseen + 1, table.getn(lines) do table.insert(chat, lines[i]) end
for _, f in ipairs(env.__frames) do
    local s = api.state(f)
    local top = not s.parent or (api.state(s.parent) and api.state(s.parent).name == "UIParent")
    if s.name and top and api.is_visible(f) then
        table.insert(wins, { name = s.name, texts = api.visible_texts(env, f) })
    end
end
return errors, chat, wins, table.getn(env.__errors), table.getn(lines)
"#;

impl Session {
    /// Load `addons` (default: all of them) from the project's `addons/` and log in.
    pub fn start(project_root: &Path, addons: &[String], o: &Options) -> Result<(Session, Snapshot)> {
        let src = project_root.join("addons");
        let mut names: Vec<String> = std::fs::read_dir(&src)
            .with_context(|| "the project has no addons/ folder")?
            .filter_map(|e| e.ok())
            .filter(|e| e.path().is_dir())
            .map(|e| e.file_name().to_string_lossy().to_string())
            .collect();
        names.sort();
        if !addons.is_empty() {
            names.retain(|n| addons.iter().any(|a| a.eq_ignore_ascii_case(n)));
        }
        if names.is_empty() {
            bail!("no addons to run: put one in addons/<Name>/ with a <Name>.toc");
        }
        let scratch = tempfile_lite::Dir::new("sim")?;
        let root = scratch.path().join("Data/Interface/AddOns");
        std::fs::create_dir_all(&root)?;
        for n in &names {
            copy_tree(&src.join(n), &root.join(n))?;
        }
        let lua = new_lua()?;
        let kit = slash(&kit_dir()?);
        let opts = lua.create_table()?;
        opts.set("name", o.name.as_str())?;
        opts.set("class", o.class.as_str())?;
        opts.set("race", o.race.as_str())?;
        opts.set("level", o.level)?;
        let (api, env, stock): (Table, Table, Table) = lua
            .load(START)
            .set_name("=forge-sim")
            .call((kit, slash(scratch.path()).trim_end_matches('/').to_string(), names.clone(), opts))
            .map_err(|e| anyhow::anyhow!("the sim didn't start: {e}"))?;
        let stock: HashSet<String> = stock.pairs::<String, bool>().filter_map(|p| p.ok()).map(|(k, _)| k).collect();
        let mut s = Session {
            api: lua.create_registry_value(api)?,
            env: lua.create_registry_value(env)?,
            lua,
            _scratch: scratch,
            addons: names,
            errors_seen: 0,
            chat_seen: 0,
            stock,
        };
        let snap = s.snapshot(None)?;
        Ok((s, snap))
    }

    fn api(&self) -> Result<Table> {
        Ok(self.lua.registry_value(&self.api)?)
    }
    fn env(&self) -> Result<Table> {
        Ok(self.lua.registry_value(&self.env)?)
    }

    fn snapshot(&mut self, result: Option<String>) -> Result<Snapshot> {
        let (errors, chat, wins, ne, nc): (Vec<String>, Vec<String>, Table, usize, usize) =
            self.lua.load(SNAP).set_name("=forge-snap").call((self.api()?, self.env()?, self.errors_seen, self.chat_seen))?;
        self.errors_seen = ne;
        self.chat_seen = nc;
        let mut windows = vec![];
        for w in wins.sequence_values::<Table>() {
            let w = w?;
            let name: String = w.get("name")?;
            if self.stock.contains(&name) {
                continue;
            }
            windows.push(Window { name, texts: w.get::<Vec<String>>("texts")? });
        }
        Ok(Snapshot { errors, chat, windows, result })
    }

    /// Run a step that may fail inside the client: the failure is an error in the snapshot, not
    /// an error of the call.
    fn step(&mut self, f: impl FnOnce(&Lua, &Table, &Table) -> mlua::Result<Option<String>>) -> Result<Snapshot> {
        let (api, env) = (self.api()?, self.env()?);
        let r = match f(&self.lua, &api, &env) {
            Ok(r) => r,
            Err(e) => {
                let errs: Table = env.get("__errors")?;
                errs.push(format!("{e}"))?;
                None
            }
        };
        self.snapshot(r)
    }

    pub fn slash(&mut self, line: &str) -> Result<Snapshot> {
        let line = line.to_string();
        self.step(move |_, api, env| {
            let f: Function = env.get("__slash")?;
            f.call::<()>(line)?;
            api.get::<Function>("pump")?.call::<()>(env.clone())?;
            Ok(None)
        })
    }

    pub fn tick(&mut self, seconds: f64) -> Result<Snapshot> {
        self.step(move |_, api, env| {
            api.get::<Function>("tick")?.call::<()>((env.clone(), seconds))?;
            Ok(None)
        })
    }

    pub fn click(&mut self, text: &str) -> Result<Snapshot> {
        let text = text.to_string();
        self.step(move |_, api, env| {
            api.get::<Function>("click_text")?.call::<()>((env.clone(), text))?;
            api.get::<Function>("pump")?.call::<()>(env.clone())?;
            Ok(None)
        })
    }

    pub fn fire(&mut self, event: &str, args: &[String]) -> Result<Snapshot> {
        let (event, args) = (event.to_string(), args.to_vec());
        self.step(move |lua, api, env| {
            let mut v: Vec<LV> = vec![LV::Table(env.clone()), LV::String(lua.create_string(&event)?)];
            for a in args {
                v.push(match a.parse::<f64>() {
                    Ok(n) => LV::Number(n),
                    Err(_) => LV::String(lua.create_string(&a)?),
                });
            }
            api.get::<Function>("fire")?.call::<()>(mlua::MultiValue::from_vec(v))?;
            Ok(None)
        })
    }

    /// Run Lua inside the client (its globals are the addon's globals); returns what it returned.
    pub fn run(&mut self, code: &str) -> Result<Snapshot> {
        let code = code.to_string();
        self.step(move |lua, _, env| {
            let src = if code.trim_start().starts_with("return") || code.contains('\n') || code.contains('=') && !code.contains("==") {
                code.clone()
            } else {
                format!("return {code}")
            };
            let f = lua.load(&src).set_name("=console").set_environment(env.clone()).into_function().or_else(|_| lua.load(&code).set_name("=console").set_environment(env.clone()).into_function())?;
            let vals: mlua::MultiValue = f.call(())?;
            let shown: Vec<String> = vals.iter().map(show).collect();
            Ok(Some(if shown.is_empty() { "(nothing)".into() } else { shown.join(", ") }))
        })
    }

    /// The addons' SavedVariables as the client would write them on logout.
    pub fn saved(&self) -> Result<Value> {
        let t: LV = self.api()?.get::<Function>("saved")?.call(self.env()?)?;
        Ok(self.lua.from_value::<Value>(t).unwrap_or(json!(null)))
    }
}

fn show(v: &LV) -> String {
    match v {
        LV::Nil => "nil".into(),
        LV::Boolean(b) => b.to_string(),
        LV::Integer(i) => i.to_string(),
        LV::Number(n) => {
            if n.fract() == 0.0 && n.abs() < 1e15 { format!("{}", *n as i64) } else { n.to_string() }
        }
        LV::String(s) => format!("{:?}", s.to_string_lossy()),
        LV::Table(t) => {
            let mut parts = vec![];
            for (i, p) in t.clone().pairs::<LV, LV>().enumerate() {
                if i == 8 {
                    parts.push("…".into());
                    break;
                }
                if let Ok((k, v)) = p {
                    let k = match k {
                        LV::String(s) => s.to_string_lossy().to_string(),
                        other => format!("[{}]", show(&other)),
                    };
                    let v = match v {
                        LV::Table(_) => "{…}".into(),
                        other => show(&other),
                    };
                    parts.push(format!("{k} = {v}"));
                }
            }
            format!("{{ {} }}", parts.join(", "))
        }
        LV::Function(_) => "function".into(),
        other => other.type_name().into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::{create, Template};

    #[test]
    fn the_kit_list_matches_the_repo() {
        let here = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../devkit/sim");
        let mut want: Vec<String> = ["wow_api.lua", "lua50_guard.lua"].iter().map(|s| s.to_string()).collect();
        for sub in ["ext", "data"] {
            for e in std::fs::read_dir(here.join(sub)).unwrap() {
                want.push(format!("{sub}/{}", e.unwrap().file_name().to_string_lossy()));
            }
        }
        want.sort();
        let mut have: Vec<String> = KIT.iter().map(|(n, _)| n.to_string()).collect();
        have.sort();
        assert_eq!(have, want, "add new devkit/sim files to sim::KIT");
    }

    #[test]
    fn lint_finds_syntax_and_lua51() {
        crate::test_config();
        let i = lint("A.lua", "local t = {}\nlocal n = #t\nif n then\n").unwrap();
        assert!(i.iter().any(|x| x.kind == "lua50" && x.line == 2), "{i:?}");
        assert!(i.iter().any(|x| x.kind == "syntax" && x.line == 4 || x.line == 3), "{i:?}");
        assert!(lint("B.lua", "local x = math.mod(5, 2)\n").unwrap().is_empty());
    }

    #[test]
    fn the_addon_template_runs_in_the_sim() {
        crate::test_config();
        let dir = tempfile::tempdir().unwrap();
        let p = create(dir.path().join("p"), "Sim Test", "Orion", Template::Addon).unwrap();
        let (mut s, snap) = Session::start(&p.root, &[], &Options::default()).unwrap();
        assert!(snap.errors.is_empty(), "{:?}", snap.errors);
        let after = s.slash("/hello").unwrap();
        assert!(after.errors.is_empty(), "{:?}", after.errors);
        assert!(!after.chat.is_empty() || !after.windows.is_empty(), "/hello shows something: {after:?}");
        let r = s.run("UnitName('player')").unwrap();
        assert_eq!(r.result.as_deref(), Some("\"Forgehand\""));
        let bad = s.run("error('boom')").unwrap();
        assert!(bad.errors.iter().any(|e| e.contains("boom")), "{bad:?}");
        s.tick(1.0).unwrap();
    }
}
