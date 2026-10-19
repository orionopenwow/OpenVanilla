//! `heraldlite`: run scenarios against a 1.12.1 realm and print one JSON report.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use clap::Parser;
use heraldlite::client::{ClientConfig, Mode};
use heraldlite::runner::{self, RunConfig, Runner, EXIT_NO_ENTRY};
use heraldlite::scenario;

/// Headless WoW 1.12.1 test bot (wenilla protocol crates). Prints a JSON report on stdout and exits
/// 0 (all passed), 1 (a check failed) or 2 (could not get in).
#[derive(Parser, Debug)]
#[command(name = "heraldlite", version, about)]
struct Cli {
    /// Direct mode: realmd `host[:port]` (default port 3724). The world address comes from the
    /// realm list unless --world is given.
    #[arg(long, env = "HL_HOST", conflicts_with = "web")]
    host: Option<String>,
    /// Web mode: the realm service URL (e.g. https://staging.openvanilla.app); --user/--pass are then
    /// the web login, and the game goes through the service's /ws relay.
    #[arg(long, env = "HL_WEB")]
    web: Option<String>,
    /// Game account (direct mode) or web username (web mode).
    #[arg(long, env = "HL_USER")]
    user: Option<String>,
    /// Password for --user. Prefer the HL_PASS environment variable over the command line.
    #[arg(long, env = "HL_PASS", hide_env_values = true)]
    pass: Option<String>,
    /// Character to log in when a `login` line names none [default: the web preset, else Herald
    /// if the account has one, else the first character].
    #[arg(long = "char", env = "HL_CHAR")]
    character: Option<String>,
    /// Realm name to pick from the realm list [default: the web credential's realm, else the first].
    #[arg(long, env = "HL_REALM")]
    realm: Option<String>,
    /// Override the world server address `host:port` (direct mode only).
    #[arg(long, env = "HL_WORLD")]
    world: Option<String>,
    /// Scenario file(s), run in order. Without one: log in and log out.
    #[arg(long, short = 's')]
    scenario: Vec<PathBuf>,
    /// Seconds for connects and for each `expect` without its own `within`.
    #[arg(long, default_value_t = 10.0)]
    timeout: f64,
    /// Seconds `logout` waits (a logout outside a rested area takes 20 s).
    #[arg(long, default_value_t = 30.0)]
    logout_timeout: f64,
    /// Log progress, chat and packets to stderr.
    #[arg(long, short = 'v')]
    verbose: bool,
    /// Pretty-print the JSON report.
    #[arg(long)]
    pretty: bool,
}

/// `heraldlite autopilot`: play a tools/autopilot route on our own realm (QA bot). Refuses any
/// host but play/staging.openvanilla.app, localhost, 127.0.0.1, *.test and *.localhost.
#[derive(Parser, Debug)]
#[command(
    name = "heraldlite autopilot",
    version,
    about = "Herald Autopilot: play a tools/autopilot route (accept, kill, loot, turn in) on our own realm, as a QA bot. Writes a JSONL run log and prints a JSON summary."
)]
struct AutopilotCli {
    /// Direct mode: realmd `host[:port]`.
    #[arg(long, env = "HL_HOST", conflicts_with = "web")]
    host: Option<String>,
    /// Web mode: the realm service URL.
    #[arg(long, env = "HL_WEB")]
    web: Option<String>,
    /// Game account (direct mode) or web username (web mode). Use a flagged bot account.
    #[arg(long, env = "HL_USER")]
    user: Option<String>,
    /// Password for --user (prefer HL_PASS).
    #[arg(long, env = "HL_PASS", hide_env_values = true)]
    pass: Option<String>,
    /// Character to play [default: the web preset, else Herald, else the first character].
    #[arg(long = "char", env = "HL_CHAR")]
    character: Option<String>,
    #[arg(long, env = "HL_REALM")]
    realm: Option<String>,
    /// Override the world server address `host:port` (direct mode only).
    #[arg(long, env = "HL_WORLD")]
    world: Option<String>,
    /// The planner's route (tools/autopilot/out/route_elwynn.json).
    #[arg(long, default_value = "tools/autopilot/out/route_elwynn.json")]
    route: PathBuf,
    /// Tactics JSON (kite/stand/melee parameters, rest thresholds, food); defaults if omitted.
    #[arg(long)]
    tactics: Option<PathBuf>,
    /// Stop after this many minutes (then log out).
    #[arg(long, default_value_t = 30.0)]
    minutes: f32,
    /// Only play route steps planned up to this level.
    #[arg(long)]
    max_level: Option<u32>,
    /// Start at this route step (0-based).
    #[arg(long, default_value_t = 0)]
    start_step: usize,
    /// JSONL run log.
    #[arg(long, default_value = "autopilot_run.jsonl")]
    log: PathBuf,
    /// Seconds for connects.
    #[arg(long, default_value_t = 10.0)]
    timeout: f64,
    /// Seconds the final logout may take (retried while in combat).
    #[arg(long, default_value_t = 60.0)]
    logout_timeout: f64,
    #[arg(long, short = 'v')]
    verbose: bool,
    #[arg(long)]
    pretty: bool,
}

fn autopilot_main() -> ! {
    let cli = AutopilotCli::parse_from(std::env::args().skip(1));
    let pretty = cli.pretty;
    let usage = |m: &str| -> ! { fail_early(format!("usage: {m}"), 1, pretty) };
    let mode = match (&cli.web, &cli.host) {
        (Some(url), _) => Mode::Web { url: url.clone() },
        (None, Some(h)) => Mode::Tcp {
            auth_host: h.clone(),
        },
        (None, None) => usage("give --host <realmd> or --web <url> (or HL_HOST / HL_WEB)"),
    };
    if let Err(e) = heraldlite::autopilot::check_targets(&mode, cli.world.as_deref()) {
        fail_early(format!("{e:#}"), 1, pretty);
    }
    let Some(user) = cli.user.clone() else {
        usage("--user / HL_USER is required")
    };
    let Some(pass) = cli.pass.clone() else {
        usage("--pass / HL_PASS is required")
    };
    if cli.world.is_some() && matches!(mode, Mode::Web { .. }) {
        usage("--world only applies to direct (--host) mode");
    }
    let cfg = ClientConfig {
        label: "a".into(),
        mode,
        user,
        pass,
        realm: cli.realm.clone(),
        world: cli.world.clone(),
        character: cli.character.clone(),
        fallback_character: Some("Herald".into()),
        timeout: Duration::from_secs_f64(cli.timeout.clamp(1.0, 600.0)),
        verbose: cli.verbose,
    };
    let args = heraldlite::autopilot::AutopilotArgs {
        route: cli.route.clone(),
        tactics: cli.tactics.clone(),
        minutes: cli.minutes,
        max_level: cli.max_level,
        start_step: cli.start_step,
        log: cli.log.clone(),
        logout_timeout: Duration::from_secs_f64(cli.logout_timeout.clamp(1.0, 600.0)),
    };
    match heraldlite::autopilot::run(cfg, &args) {
        Ok(summary) => {
            let code = heraldlite::autopilot::exit_code(&summary);
            let report = serde_json::json!({
                "tool": "heraldlite autopilot", "version": env!("CARGO_PKG_VERSION"),
                "ok": code == 0, "exit": code, "summary": summary,
            });
            let out = if pretty {
                serde_json::to_string_pretty(&report)
            } else {
                serde_json::to_string(&report)
            };
            println!("{}", out.unwrap_or_default());
            std::process::exit(code);
        }
        Err(e) => {
            let msg = format!("{e:#}");
            let code = if msg.starts_with("could not") {
                EXIT_NO_ENTRY
            } else {
                1
            };
            fail_early(msg, code, pretty);
        }
    }
}

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}

/// Accounts for clients other than `a`: `HL_USER_<X>`/`HL_PASS_<X>`/`HL_CHAR_<X>`, and for `b`
/// also `HL_USER2`/`HL_PASS2`/`HL_CHAR2`.
fn other_accounts() -> BTreeMap<String, (String, String, Option<String>)> {
    let mut out = BTreeMap::new();
    if let (Some(u), Some(p)) = (env("HL_USER2"), env("HL_PASS2")) {
        out.insert("b".to_string(), (u, p, env("HL_CHAR2")));
    }
    for (k, v) in std::env::vars() {
        if let Some(label) = k.strip_prefix("HL_USER_") {
            let l = label.to_ascii_uppercase();
            if let Some(p) = env(&format!("HL_PASS_{l}")) {
                out.insert(l.to_ascii_lowercase(), (v, p, env(&format!("HL_CHAR_{l}"))));
            }
        }
    }
    out
}

fn fail_early(msg: String, code: i32, pretty: bool) -> ! {
    let report = serde_json::json!({
        "tool": "heraldlite", "version": env!("CARGO_PKG_VERSION"),
        "ok": false, "exit": code, "pass": 0, "fail": 1, "failures": [msg],
    });
    let out = if pretty {
        serde_json::to_string_pretty(&report)
    } else {
        serde_json::to_string(&report)
    };
    println!("{}", out.unwrap_or_default());
    std::process::exit(code);
}

fn main() {
    if std::env::args().nth(1).as_deref() == Some("autopilot") {
        autopilot_main();
    }
    let cli = Cli::parse();
    let started = Instant::now();
    let pretty = cli.pretty;
    let usage = |m: &str| -> ! { fail_early(format!("usage: {m}"), 1, pretty) };

    let (mode, mode_name, target) = match (&cli.web, &cli.host) {
        (Some(url), _) => (Mode::Web { url: url.clone() }, "web", url.clone()),
        (None, Some(h)) => (
            Mode::Tcp {
                auth_host: h.clone(),
            },
            "tcp",
            h.clone(),
        ),
        (None, None) => usage("give --host <realmd> or --web <url> (or HL_HOST / HL_WEB)"),
    };
    let Some(user) = cli.user.clone() else {
        usage("--user / HL_USER is required")
    };
    let Some(pass) = cli.pass.clone() else {
        usage("--pass / HL_PASS is required")
    };
    if cli.world.is_some() && matches!(mode, Mode::Web { .. }) {
        usage("--world only applies to direct (--host) mode");
    }
    let timeout = Duration::from_secs_f64(cli.timeout.clamp(1.0, 600.0));

    let mut scenarios = Vec::new();
    for path in &cli.scenario {
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            Err(e) => fail_early(format!("{}: {e}", path.display()), 1, cli.pretty),
        };
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.display().to_string());
        match scenario::parse(&name, &text, &|k| std::env::var(k).ok()) {
            Ok(s) => scenarios.push(s),
            Err(e) => fail_early(format!("{e:#}"), 1, cli.pretty),
        }
    }
    if scenarios.is_empty() {
        scenarios.push(runner::default_scenario());
    }

    let primary = ClientConfig {
        label: "a".into(),
        mode,
        user,
        pass,
        realm: cli.realm.clone(),
        world: cli.world.clone(),
        character: cli.character.clone(),
        fallback_character: Some("Herald".into()),
        timeout,
        verbose: cli.verbose,
    };
    let mut runner = Runner::new(RunConfig {
        primary,
        others: other_accounts(),
        step_timeout: timeout,
        logout_timeout: Duration::from_secs_f64(cli.logout_timeout.clamp(1.0, 600.0)),
        mode_name: mode_name.into(),
        target,
    });
    let mut reports = Vec::new();
    for sc in &scenarios {
        reports.push(runner.run(sc));
    }
    let mut report = runner.finish(reports, started);
    if report.exit == EXIT_NO_ENTRY {
        report.ok = false;
    }
    let out = if cli.pretty {
        serde_json::to_string_pretty(&report)
    } else {
        serde_json::to_string(&report)
    };
    println!(
        "{}",
        out.unwrap_or_else(|e| format!("{{\"ok\":false,\"error\":\"{e}\"}}"))
    );
    std::process::exit(report.exit);
}
