//! Herald Autopilot v1: a headless bot that plays a route from `tools/autopilot` (accept quests,
//! kill, loot, turn in, rest, recover from death) against our own CMaNGOS 1.12.1 realm, as a QA
//! tool. See `AUTOPILOT.md`.
//!
//! - [`world`]: object manager and own state from decoded server events
//! - [`movement`]: the `MSG_MOVE_*` stream, the [`movement::Navigator`] seam, stuck recovery
//! - [`combat`]: hunter kite / stand and plain melee fights
//! - [`loot`], [`quest`]: looting and quest-giver conversations, route parsing
//! - [`brain`]: the priority loop; [`runlog`]: the JSONL run log and summary
//! - [`out`]: every packet the bot sends; [`guard`]: the hard-coded host allowlist

pub mod brain;
pub mod combat;
pub mod geom;
pub mod guard;
pub mod loot;
pub mod movement;
pub mod out;
pub mod quest;
pub mod runlog;
#[cfg(test)]
mod sim;
#[cfg(test)]
mod sim_tests;
pub mod tactics;
pub mod world;

use std::path::PathBuf;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};

use crate::client::{Check, Client, ClientConfig, Mode};
use brain::{Brain, BrainConfig, TICK_MS};
use movement::StraightLine;
use out::{Sink, WriterSink};
use quest::Route;
use runlog::RunLog;
use tactics::Tactics;
use world::World;

#[derive(Debug, Clone)]
pub struct AutopilotArgs {
    pub route: PathBuf,
    pub tactics: Option<PathBuf>,
    pub minutes: f32,
    /// Stop after the route steps planned up to this level.
    pub max_level: Option<u32>,
    /// Start at this route step (0-based), e.g. to resume.
    pub start_step: usize,
    pub log: PathBuf,
    pub logout_timeout: Duration,
}

/// Check every address the run would contact against the allowlist.
pub fn check_targets(mode: &Mode, world: Option<&str>) -> Result<()> {
    let t = match mode {
        Mode::Tcp { auth_host } => auth_host.as_str(),
        Mode::Web { url } => url.as_str(),
    };
    guard::check(t).map_err(anyhow::Error::msg)?;
    if let Some(w) = world {
        guard::check(w).map_err(anyhow::Error::msg)?;
    }
    Ok(())
}

/// Connect, play the route until done or the time limit, log out. Returns the summary JSON.
pub fn run(cfg: ClientConfig, args: &AutopilotArgs) -> Result<serde_json::Value> {
    check_targets(&cfg.mode, cfg.world.as_deref())?;
    let mut route = Route::load(&args.route)?;
    if let Some(l) = args.max_level {
        route = route.up_to_level(l);
    }
    let tactics = match &args.tactics {
        Some(p) => Tactics::load(p)?,
        None => Tactics::default(),
    };
    let log_file = std::fs::File::create(&args.log)
        .with_context(|| format!("creating the run log {}", args.log.display()))?;
    let verbose = cfg.verbose;

    let mut client = Client::connect_guarded(cfg, &guard::check).context("could not get in")?;
    client.enable_tap();
    let name = client
        .enter_world(None)
        .context("could not enter the world")?;
    let started = Instant::now();
    let now = || started.elapsed().as_millis() as u64;
    let me = client.model.self_guid;
    let mut world = World::new(
        me,
        client.model.self_pos.unwrap_or_default(),
        client.model.map.unwrap_or(0),
    );
    // Let the login burst (spells, our own descriptor, nearby objects) arrive.
    client.pump(Instant::now() + Duration::from_millis(1_500))?;
    for ev in client.take_events() {
        world.apply(&ev, now());
    }
    if verbose {
        eprintln!(
            "[autopilot] in the world as {name}: level {}, class {}, {} spells, {} units in view",
            world.level(),
            world.class(),
            world.spells.len(),
            world.units.len()
        );
    }
    let mut brain = Brain::new(
        world,
        BrainConfig {
            tactics,
            route,
            max_minutes: args.minutes,
        },
        Box::new(StraightLine),
        RunLog::new(Box::new(std::io::BufWriter::new(log_file))),
    );
    brain.step_idx = args.start_step;

    let mut next_tick = Instant::now();
    loop {
        if let Err(e) = client.pump(next_tick) {
            brain.world.closed.get_or_insert_with(|| format!("{e:#}"));
        }
        next_tick += Duration::from_millis(TICK_MS);
        let t = now();
        for ev in client.take_events() {
            brain.world.apply(&ev, t);
        }
        if let Some(why) = client.closed() {
            brain.world.closed.get_or_insert_with(|| why.to_string());
        }
        let cmds = brain.tick(t);
        if !cmds.is_empty() && client.closed().is_none() {
            let sent = client.writer_mut().and_then(|w| {
                let mut sink = WriterSink(w);
                for c in &cmds {
                    if verbose && !matches!(c, out::OutCmd::Move { .. }) {
                        eprintln!("[autopilot] {t:>8} ms  {}  {c:?}", c.label());
                    }
                    sink.send(c)?;
                }
                Ok(())
            });
            if let Err(e) = sent {
                brain
                    .world
                    .closed
                    .get_or_insert_with(|| format!("send failed: {e:#}"));
            }
        }
        // Keep the client's acks (speed change, mover modes) in step with our dead reckoning.
        client.model.self_pos = Some(brain.mover.pos);
        client.model.orientation = brain.mover.orientation;
        client.model.move_flags = brain.mover.flags();
        if brain.finished.is_some() {
            break;
        }
        if Instant::now() > next_tick + Duration::from_secs(2) {
            next_tick = Instant::now(); // we fell behind (debugger, slow host): don't burst
        }
    }

    // Clean stop and logout.
    let t = now();
    if client.closed().is_none() {
        let cmds = brain.shutdown(t);
        if let Ok(w) = client.writer_mut() {
            let mut sink = WriterSink(w);
            for c in &cmds {
                let _ = sink.send(c);
            }
        }
        client.model.move_flags = 0;
        let deadline = Instant::now() + args.logout_timeout;
        let mut retry = Instant::now();
        let mut outcome = String::from("logout timed out");
        while Instant::now() < deadline {
            if Instant::now() >= retry {
                client.model.logout_refused = None;
                if client.logout_start().is_err() {
                    break;
                }
                retry = Instant::now() + Duration::from_secs(5);
            }
            if client
                .pump(Instant::now() + Duration::from_millis(200))
                .is_err()
            {
                outcome = "connection lost during logout".into();
                break;
            }
            for ev in client.take_events() {
                brain.world.apply(&ev, now());
            }
            match client.logout_state() {
                Check::Met(_) => {
                    outcome = "logged out".into();
                    break;
                }
                Check::Failed(why) => outcome = why, // in combat: retry in 5 s
                Check::Pending => {}
            }
            if client.closed().is_some() {
                outcome = "connection closed".into();
                break;
            }
        }
        brain.outcome_public(now(), "logout", &outcome);
    }
    client.close();
    let mut summary = brain.summarize(now());
    summary["character"] = serde_json::json!(name);
    summary["log"] = serde_json::json!(args.log.display().to_string());
    Ok(summary)
}

/// Exit code for a finished run: 0 when the route (or the time limit) was reached with no
/// failed step, 1 otherwise.
pub fn exit_code(summary: &serde_json::Value) -> i32 {
    let failed = summary["steps"]["failed"].as_u64().unwrap_or(0);
    let reason = summary["end_reason"].as_str().unwrap_or("");
    if failed == 0 && (reason == "route complete" || reason == "time limit") {
        0
    } else {
        1
    }
}
