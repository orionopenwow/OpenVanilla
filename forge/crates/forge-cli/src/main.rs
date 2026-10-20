//! `forge`: Vanilla Forge from the command line (and for CI). The desktop app runs the same
//! core; everything here also prints JSON with `--json`.
//!
//! ```text
//! forge new <dir> [--template addon|pack|empty] [--name "My Pack"] [--author Me]
//! forge check [dir] [--json]
//! forge build [dir] [--json]
//! forge ids <table> [--name "what it is"] [--dir <project>]
//! forge game set <folder> | forge game status
//! forge assets search <words> [--limit N] | ls [folder] | cat <path> | export <path> <file>
//! forge serve [--port 8777]          the API + app UI in a browser (dev, no desktop shell)
//! forge mcp [--project DIR]           an MCP server on stdio for the creator's own AI assistant
//! ```

use anyhow::{bail, Context, Result};
use forge_core::config::Config;
use forge_core::project::{self, Project, Template};
use forge_core::vfs::{GameData, Preview};
use forge_core::{build, check, ids, Level};
use std::path::PathBuf;

mod mcp;
mod serve;

const HELP: &str = "Vanilla Forge

  forge new <dir> [--template addon|pack|empty] [--name NAME] [--author NAME]
  forge check [dir] [--json]
  forge build [dir] [--json]
  forge ids <table> [--name WHAT] [--dir DIR]     tables: creature_template item_template quest_template
                                                   gameobject_template CreatureDisplayInfo CreatureModelData
                                                   ItemDisplayInfo Spell SpellIcon
  forge game set <folder> | forge game status     your own game install (read-only)
  forge assets search <words> [--limit N] | ls [folder] | cat <path> | export <path> <file>
  forge publish [dir] [--json]                    release build -> build/publish/<pack>-<ver>.ovpack, signed
  forge verify <file.ovpack>                      check a package's signature and contents
  forge key                                       your creator public key (the Workshop pins it)
  forge realm build <realm.toml> [--json]         merge approved packs into a realm's patch, DBCs and SQL
  forge sim [dir] [--class C] [--level N]         run the project's addons in the sim (a console)
  forge serve [--port 8777]                       the app in a browser (development)
  forge mcp [--project DIR]                       Forge for your own AI assistant (an MCP server on stdio)
";

struct Args {
    pos: Vec<String>,
    flags: std::collections::HashMap<String, String>,
    json: bool,
}

fn parse(raw: Vec<String>) -> Args {
    let mut a = Args { pos: vec![], flags: Default::default(), json: false };
    let mut it = raw.into_iter().peekable();
    while let Some(x) = it.next() {
        if x == "--json" {
            a.json = true;
        } else if let Some(k) = x.strip_prefix("--") {
            let v = it.next().unwrap_or_default();
            a.flags.insert(k.to_string(), v);
        } else {
            a.pos.push(x);
        }
    }
    a
}

fn main() {
    let raw: Vec<String> = std::env::args().skip(1).collect();
    if raw.is_empty() || raw[0] == "-h" || raw[0] == "--help" || raw[0] == "help" {
        print!("{HELP}");
        return;
    }
    if let Err(e) = run(parse(raw)) {
        eprintln!("forge: {e:#}");
        std::process::exit(1);
    }
}

fn game(cfg: &Config) -> Option<GameData> {
    let dir = cfg.game_dir.as_ref()?;
    match GameData::open(dir) {
        Ok(g) => Some(g),
        Err(e) => {
            eprintln!("note: game data not used ({e:#})");
            None
        }
    }
}

fn need_game(cfg: &Config) -> Result<GameData> {
    let dir = cfg.game_dir.as_ref().context("Forge doesn't know where your game is: forge game set <folder>")?;
    GameData::open(dir)
}

fn run(a: Args) -> Result<()> {
    let cmd = a.pos[0].as_str();
    let mut cfg = Config::load();
    match cmd {
        "new" => {
            let dir = PathBuf::from(a.pos.get(1).context("forge new <dir>")?);
            let t = a.flags.get("template").map(String::as_str).unwrap_or("addon");
            let t = Template::parse(t).with_context(|| format!("unknown template {t} (addon, pack, empty)"))?;
            let name = a.flags.get("name").cloned().unwrap_or_else(|| dir.file_name().unwrap().to_string_lossy().to_string());
            let author = a.flags.get("author").cloned().unwrap_or_default();
            let p = project::create(&dir, &name, &author, t)?;
            cfg.touch_recent(&p.root);
            cfg.save()?;
            println!("made {} ({}) in {}", p.manifest.pack.name, t.label(), dir.display());
        }
        "check" => {
            let p = Project::open(a.pos.get(1).map(String::as_str).unwrap_or("."))?;
            let f = check::run(&p, game(&cfg).as_ref());
            if a.json {
                println!("{}", serde_json::to_string_pretty(&f)?);
            } else {
                print_findings(&f);
            }
            if f.iter().any(|x| x.level == Level::Error) {
                std::process::exit(2);
            }
        }
        "build" => {
            let p = Project::open(a.pos.get(1).map(String::as_str).unwrap_or("."))?;
            let r = build::build(&p, game(&cfg).as_ref())?;
            if a.json {
                println!("{}", serde_json::to_string_pretty(&r)?);
            } else {
                print_findings(&r.findings);
                println!("built {} {}: {} file(s), {} bytes -> build/{} ({} bytes)", r.pack, r.version, r.files, r.bytes, r.mpq, r.mpq_bytes);
                println!("build hash {}", &r.build_hash[..16]);
            }
        }
        "publish" => {
            let p = Project::open(a.pos.get(1).map(String::as_str).unwrap_or("."))?;
            let g = game(&cfg);
            match forge_core::publish::package(&p, g.as_ref()) {
                Ok(r) if a.json => println!("{}", serde_json::to_string_pretty(&r)?),
                Ok(r) => {
                    print_findings(&r.findings);
                    println!("packed {} ({} bytes), signed by {}", r.package.display(), r.bytes, &r.signature.public_key[..16]);
                }
                Err(e) => {
                    print_findings(&forge_core::publish::gate(&p, g.as_ref()));
                    return Err(e);
                }
            }
        }
        "verify" => {
            let f = PathBuf::from(a.pos.get(1).context("forge verify <file.ovpack>")?);
            let s = forge_core::publish::verify(&f)?;
            println!("ok: {} {} (build {}), signed by {}", s.pack, s.version, &s.build_hash[..12], s.public_key);
        }
        "realm" => {
            let sub = a.pos.get(1).map(String::as_str).unwrap_or("");
            if sub != "build" {
                bail!("forge realm build <realm.toml>");
            }
            let f = PathBuf::from(a.pos.get(2).context("forge realm build <realm.toml>")?);
            let r = forge_core::realm::build(&f)?;
            if a.json {
                println!("{}", serde_json::to_string_pretty(&r)?);
            } else {
                for w in &r.warnings {
                    println!("warn  {w}");
                }
                for p in &r.packs {
                    println!("pack  {} {} ({})", p["id"].as_str().unwrap_or(""), p["version"].as_str().unwrap_or(""), &p["build_hash"].as_str().unwrap_or("")[..12]);
                }
                println!("{}: {} client files, {} bytes; DBCs merged: {}", r.patch, r.client_files, r.client_bytes, if r.dbc_tables.is_empty() { "none".into() } else { r.dbc_tables.join(", ") });
            }
        }
        "key" => println!("{}", forge_core::publish::public_key_hex()?),
        "sim" => {
            use std::io::BufRead;
            let p = Project::open(a.pos.get(1).map(String::as_str).unwrap_or("."))?;
            let mut o = forge_core::sim::Options::default();
            if let Some(c) = a.flags.get("class") {
                o.class = c.to_ascii_uppercase();
            }
            if let Some(l) = a.flags.get("level") {
                o.level = l.parse().context("--level N")?;
            }
            let (mut s, snap) = forge_core::sim::Session::start(&p.root, &[], &o)?;
            let show = |snap: &forge_core::sim::Snapshot| {
                for l in &snap.chat {
                    println!("{l}");
                }
                if let Some(r) = &snap.result {
                    println!("= {r}");
                }
                for e in &snap.errors {
                    println!("ERROR {e}");
                }
                for w in &snap.windows {
                    println!("[{}] {}", w.name, w.texts.join(" | "));
                }
            };
            println!("logged in with {} — /slash, Lua, :tick N, :click TEXT, :quit", s.addons.join(", "));
            show(&snap);
            for line in std::io::stdin().lock().lines() {
                let line = line?;
                let l = line.trim();
                let snap = if l == ":quit" || l == ":q" {
                    break;
                } else if let Some(n) = l.strip_prefix(":tick") {
                    s.tick(n.trim().parse().unwrap_or(1.0))?
                } else if let Some(t) = l.strip_prefix(":click ") {
                    s.click(t)?
                } else if l.starts_with('/') {
                    s.slash(l)?
                } else if l.is_empty() {
                    continue;
                } else {
                    s.run(l)?
                };
                show(&snap);
            }
        }
        "ids" => {
            let table = a.pos.get(1).context("forge ids <table>")?;
            let p = Project::open(a.flags.get("dir").map(String::as_str).unwrap_or("."))?;
            let mut l = ids::IdLock::load(&p.root)?;
            let id = l.allocate(&p.manifest.pack.id, table, a.flags.get("name").map(String::as_str).unwrap_or(""))?;
            l.save(&p.root)?;
            println!("{id}");
        }
        "game" => match a.pos.get(1).map(String::as_str) {
            Some("set") => {
                let dir = PathBuf::from(a.pos.get(2).context("forge game set <folder>")?);
                let g = GameData::open(&dir)?;
                cfg.game_dir = Some(dir);
                cfg.save()?;
                let s = g.status();
                println!("game data: {} files in {} archive(s)", s.files, s.archives.len());
            }
            _ => {
                let g = need_game(&cfg)?;
                let s = g.status();
                if a.json {
                    println!("{}", serde_json::to_string_pretty(&s)?);
                } else {
                    println!("{}: {} files\n  {}", s.dir, s.files, s.archives.join("\n  "));
                }
            }
        },
        "assets" => {
            let g = need_game(&cfg)?;
            match a.pos.get(1).map(String::as_str) {
                Some("search") => {
                    let q = a.pos[2..].join(" ");
                    let limit = a.flags.get("limit").and_then(|x| x.parse().ok()).unwrap_or(50);
                    for n in g.search(&q, limit) {
                        println!("{n}");
                    }
                }
                Some("ls") => {
                    for (n, dir) in g.children(a.pos.get(2).map(String::as_str).unwrap_or("")) {
                        println!("{}{}", n, if dir { "\\" } else { "" });
                    }
                }
                Some("cat") => match g.preview(a.pos.get(2).context("forge assets cat <path>")?)? {
                    Preview::Text { text, .. } => print!("{text}"),
                    Preview::Image { width, height, format, .. } => println!("image {width}x{height} ({format})"),
                    Preview::Binary { size, head } => println!("{size} bytes: {head}"),
                },
                Some("export") => {
                    let path = a.pos.get(2).context("forge assets export <path> <file>")?;
                    let out = a.pos.get(3).context("forge assets export <path> <file>")?;
                    std::fs::write(out, g.read(path)?)?;
                    println!("wrote {out} (for your own reference; never ship the game's files)");
                }
                _ => bail!("forge assets search|ls|cat|export"),
            }
        }
        "mcp" => mcp::run(a.flags.get("project").cloned().or_else(|| a.pos.get(1).cloned()))?,
        "serve" => {
            let port = a.flags.get("port").and_then(|x| x.parse().ok()).unwrap_or(8777);
            serve::serve(port)?;
        }
        _ => bail!("unknown command {cmd}\n\n{HELP}"),
    }
    Ok(())
}

fn print_findings(f: &[forge_core::Finding]) {
    if f.is_empty() {
        println!("checks: all clear");
        return;
    }
    for x in f {
        let tag = match x.level {
            Level::Error => "ERROR",
            Level::Warning => "warn ",
            Level::Info => "info ",
        };
        let at = if x.path.is_empty() { String::new() } else { format!("{}: ", x.path) };
        println!("{tag} {at}{} [{}]", x.message, x.code);
    }
}
