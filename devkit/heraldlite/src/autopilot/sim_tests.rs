//! End-to-end brain tests against the in-process [`super::sim::FakeServer`], on simulated time.

use std::io::Write;
use std::sync::{Arc, Mutex};

use benilla_protocol::messages::opcode;

use super::brain::{Brain, BrainConfig, TICK_MS};
use super::movement::StraightLine;
use super::out::OutCmd;
use super::quest::Route;
use super::runlog::RunLog;
use super::sim::{FakeServer, QState, GRAVEYARD, ME, MOB_ENTRY, QUEST};
use super::tactics::Tactics;
use super::world::World;

#[derive(Clone, Default)]
struct Shared(Arc<Mutex<Vec<u8>>>);
impl Write for Shared {
    fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(b);
        Ok(b.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}
impl Shared {
    fn lines(&self) -> Vec<serde_json::Value> {
        String::from_utf8(self.0.lock().unwrap().clone())
            .unwrap()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect()
    }
}

const NPC_POS: [f32; 3] = [-8902.6, -162.6, 82.0];
const START: [f32; 3] = [-8920.0, -150.0, 82.0];
const CAMP: [f32; 3] = [-8850.0, -170.0, 82.0];

fn route_json(kills: u32) -> String {
    format!(
        r#"{{"minutes_per_level": {{"1": 3.0}}, "quest_minutes": {{"7": 4.0}}, "steps": [
        {{"kind": "accept", "quest": 7, "desc": "accept 7 Kobold Camp Cleanup", "pos": [{}, {}], "level": 1, "start_min": 0, "end_min": 0.1}},
        {{"kind": "kill", "entry": {MOB_ENTRY}, "kills": {kills}, "desc": "quest 7: {kills} x Kobold Vermin", "pos": [{}, {}], "level": 1, "start_min": 0.1, "end_min": 2.0}},
        {{"kind": "turnin", "quest": 7, "desc": "turn in 7 Kobold Camp Cleanup", "pos": [{}, {}], "level": 1, "start_min": 2.0, "end_min": 2.1}}
        ]}}"#,
        NPC_POS[0], NPC_POS[1], CAMP[0], CAMP[1], NPC_POS[0], NPC_POS[1]
    )
}

fn setup(server: &mut FakeServer, tactics: Tactics, kills: u32, minutes: f32) -> (Brain, Shared) {
    let mut world = World::new(ME, START, 0);
    while let Some(ev) = server.events.pop_front() {
        world.apply(&ev, 0);
    }
    let buf = Shared::default();
    let brain = Brain::new(
        world,
        BrainConfig {
            tactics,
            route: Route::parse(&route_json(kills)).unwrap(),
            max_minutes: minutes,
        },
        Box::new(StraightLine),
        RunLog::new(Box::new(buf.clone())),
    );
    (brain, buf)
}

/// Run until `stop` or `until_ms`; returns every command sent with its time.
fn run(
    server: &mut FakeServer,
    brain: &mut Brain,
    until_ms: u64,
    stop: impl Fn(&FakeServer, &Brain) -> bool,
) -> Vec<(u64, OutCmd)> {
    let mut sent = vec![];
    let mut t = 0;
    while t <= until_ms {
        server.update(t);
        while let Some(ev) = server.events.pop_front() {
            brain.world.apply(&ev, t);
        }
        for c in brain.tick(t) {
            server.handle(t, &c);
            sent.push((t, c));
        }
        if stop(server, brain) || brain.finished.is_some() {
            break;
        }
        t += TICK_MS;
    }
    sent
}

#[test]
fn northshire_quest_accept_kill_loot_turn_in() {
    let mut server = FakeServer::new(START, NPC_POS, &[CAMP]);
    let (mut brain, buf) = setup(&mut server, Tactics::default(), 1, 10.0);
    let sent = run(&mut server, &mut brain, 300_000, |_, _| false);

    assert!(
        server.violations.is_empty(),
        "{:?}\n{:#?}",
        server.violations,
        server.log
    );
    assert_eq!(server.quest, QState::Rewarded, "{:#?}", server.log);
    assert_eq!(brain.finished.as_deref(), Some("route complete"));
    assert!(
        server.mobs[0].dead && server.mobs[0].looted,
        "killed and looted"
    );

    // The conversation and fight went over the wire in the right order.
    let ops: Vec<u16> = sent
        .iter()
        .map(|(_, c)| c.opcode())
        .filter(|o| !(0xB5..=0xEE).contains(o))
        .collect();
    let pos = |op: u16| {
        ops.iter()
            .position(|o| *o == op)
            .unwrap_or_else(|| panic!("{op:#x} never sent: {ops:x?}"))
    };
    assert!(pos(opcode::CMSG_QUESTGIVER_HELLO) < pos(opcode::CMSG_QUESTGIVER_ACCEPT_QUEST));
    assert!(pos(opcode::CMSG_QUESTGIVER_ACCEPT_QUEST) < pos(opcode::CMSG_SET_SELECTION));
    assert!(pos(opcode::CMSG_SET_SELECTION) < pos(opcode::CMSG_CAST_SPELL));
    assert!(pos(opcode::CMSG_CAST_SPELL) < pos(opcode::CMSG_LOOT));
    assert!(pos(opcode::CMSG_LOOT) < pos(opcode::CMSG_AUTOSTORE_LOOT_ITEM));
    assert!(pos(opcode::CMSG_AUTOSTORE_LOOT_ITEM) < pos(opcode::CMSG_LOOT_RELEASE));
    assert!(pos(opcode::CMSG_LOOT_RELEASE) < pos(opcode::CMSG_QUESTGIVER_CHOOSE_REWARD));

    // Heartbeats while running: never closer than 500 ms apart.
    for w in server.heartbeats.windows(2) {
        assert!(w[1] - w[0] >= 500, "heartbeats {} and {} ms", w[0], w[1]);
    }
    assert!(
        server.heartbeats.len() >= 4,
        "it ran somewhere: {:?}",
        server.heartbeats
    );

    // Every START_FORWARD is eventually followed by a STOP.
    let moves: Vec<u16> = sent
        .iter()
        .filter_map(|(_, c)| match c {
            OutCmd::Move { opcode: o, .. }
                if *o != opcode::MSG_MOVE_HEARTBEAT && *o != opcode::MSG_MOVE_SET_FACING =>
            {
                Some(*o)
            }
            _ => None,
        })
        .collect();
    assert_eq!(moves.first(), Some(&opcode::MSG_MOVE_START_FORWARD));
    assert_eq!(moves.last(), Some(&opcode::MSG_MOVE_STOP));

    // Summary and log.
    let s = brain.summarize(server.heartbeats.last().copied().unwrap_or(0) + 1_000);
    assert_eq!(s["end_reason"], "route complete");
    assert_eq!(s["kills"], 1);
    assert_eq!(s["steps"]["done"], 3);
    assert_eq!(s["steps"]["failed"], 0);
    assert_eq!(s["loot"]["corpses"], 1);
    assert_eq!(s["loot"]["money_copper"], 7);
    assert_eq!(s["xp_gained"], 50 + 170);
    assert!(s["quests"]["7"]["minutes"].is_number(), "{s:#}");
    assert_eq!(s["quests"]["7"]["predicted_minutes"], 4.0);
    let lines = buf.lines();
    assert!(lines.iter().any(|l| l["action"] == "pull"));
    assert!(lines.iter().any(|l| l["action"] == "quest rewarded"));
    assert_eq!(lines.last().unwrap()["event"], "summary");
    assert!(lines
        .iter()
        .all(|l| l["pos"].is_array() && l["level"].is_number()));
}

#[test]
fn a_kill_step_counts_each_kill_once_and_kites() {
    let mut server = FakeServer::new(
        START,
        NPC_POS,
        &[CAMP, [CAMP[0] + 20.0, CAMP[1] + 25.0, 82.0]],
    );
    server.kills_needed = 2;
    server.shot_dmg = 10; // four shots each: the mob reaches us, so the kite cycle runs
    let mut t = Tactics::default();
    t.kite.trigger = 20.0;
    let (mut brain, buf) = setup(&mut server, t, 2, 10.0);
    let sent = run(&mut server, &mut brain, 400_000, |_, _| false);
    assert!(server.violations.is_empty(), "{:?}", server.violations);
    assert_eq!(server.quest, QState::Rewarded, "{:#?}", server.log);
    assert_eq!(brain.kills_by_entry.get(&MOB_ENTRY), Some(&2));
    // The kite cycle ran: after a shot with the mob inside 20 yd we ran during the reload,
    // stopped, turned and shot again.
    let lines = buf.lines();
    let phases: Vec<&str> = lines
        .iter()
        .filter_map(|l| l["action"].as_str())
        .filter(|a| a.starts_with("fight 0x"))
        .collect();
    assert!(phases.iter().any(|a| a.contains("KiteRun")), "{phases:?}");
    assert!(phases.iter().any(|a| a.contains("Turn")), "{phases:?}");
    assert!(sent.iter().filter(|(_, c)| matches!(c, OutCmd::Move { opcode: o, .. } if *o == opcode::MSG_MOVE_START_FORWARD)).count() >= 3);
}

#[test]
fn death_release_corpse_run_and_reclaim() {
    let mut server = FakeServer::new(START, NPC_POS, &[CAMP]);
    server.shot_dmg = 1; // we cannot win this one
    server.mob_dmg = 31; // two hits
    let (mut brain, buf) = setup(&mut server, Tactics::default(), 1, 10.0);
    run(&mut server, &mut brain, 300_000, |s, b| {
        s.died_at.is_some() && !s.ghost && s.hp > 0 && b.world.hp_pct() > 0.0 && !b.world.is_ghost()
    });
    assert!(server.died_at.is_some(), "{:#?}", server.log);
    assert!(!server.ghost, "resurrected: {:#?}", server.log);
    assert!(server.violations.is_empty(), "{:?}", server.violations);
    let lines = buf.lines();
    let actions: Vec<&str> = lines.iter().filter_map(|l| l["action"].as_str()).collect();
    for want in [
        "died",
        "release spirit",
        "server moved us",
        "ask where the corpse is",
        "reclaim corpse",
    ] {
        assert!(
            actions.iter().any(|a| a.starts_with(want)),
            "{want} missing: {actions:?}"
        );
    }
    // The corpse run started from the graveyard.
    let moved = lines
        .iter()
        .find(|l| l["action"] == "server moved us")
        .unwrap();
    assert!((moved["pos"][0].as_f64().unwrap() - f64::from(GRAVEYARD[0])).abs() < 1.0);
    assert_eq!(brain.log.deaths, 1);
    let _ = QUEST;
}

#[test]
fn the_time_limit_stops_the_run() {
    let mut server = FakeServer::new(START, NPC_POS, &[CAMP]);
    let (mut brain, _) = setup(&mut server, Tactics::default(), 1, 0.05); // 3 s
    run(&mut server, &mut brain, 60_000, |_, _| false);
    assert_eq!(brain.finished.as_deref(), Some("time limit"));
}

#[test]
fn step_executor_order_skips_and_rest() {
    let mut server = FakeServer::new(START, NPC_POS, &[CAMP]);
    server.set_hp(20); // a third of 60: rest first
    let route = format!(
        r#"{{"steps": [
        {{"kind": "travel", "desc": "to the giver", "pos": [{}, {}], "level": 1}},
        {{"kind": "pet", "desc": "tame a pet", "pos": [0, 0], "level": 1}},
        {{"kind": "turnin", "quest": 99, "desc": "turn in 99 Nothing", "pos": [{}, {}], "level": 1}},
        {{"kind": "accept", "quest": 7, "desc": "accept 7 Kobold Camp Cleanup", "pos": [{}, {}], "level": 1}}
        ]}}"#,
        NPC_POS[0] - 3.0,
        NPC_POS[1],
        NPC_POS[0],
        NPC_POS[1],
        NPC_POS[0],
        NPC_POS[1]
    );
    let mut world = World::new(ME, START, 0);
    while let Some(ev) = server.events.pop_front() {
        world.apply(&ev, 0);
    }
    let buf = Shared::default();
    let mut brain = Brain::new(
        world,
        BrainConfig {
            tactics: Tactics::default(),
            route: Route::parse(&route).unwrap(),
            max_minutes: 5.0,
        },
        Box::new(StraightLine),
        RunLog::new(Box::new(buf.clone())),
    );
    let sent = run(&mut server, &mut brain, 120_000, |_, _| false);
    assert_eq!(brain.finished.as_deref(), Some("route complete"));
    assert_eq!(server.quest, QState::Taken);
    // Rested before anything else: sat down, stood up, then moved.
    let first_sit = sent
        .iter()
        .position(|(_, c)| *c == OutCmd::StandState(1))
        .expect("sat");
    let stand = sent
        .iter()
        .position(|(_, c)| *c == OutCmd::StandState(0))
        .expect("stood");
    let first_move = sent
        .iter()
        .position(|(_, c)| matches!(c, OutCmd::Move { .. }))
        .unwrap();
    assert!(first_sit < stand && stand < first_move);
    let results: Vec<String> = buf
        .lines()
        .iter()
        .filter(|l| {
            l["action"]
                .as_str()
                .is_some_and(|a| a.starts_with("step: "))
        })
        .map(|l| {
            format!(
                "{} => {}",
                l["action"].as_str().unwrap(),
                l["result"].as_str().unwrap()
            )
        })
        .collect();
    assert_eq!(results.len(), 4, "{results:#?}");
    assert!(results[0].contains("to the giver") && results[0].contains("Done: arrived"));
    assert!(results[1].contains("Skipped") && results[1].contains("not supported"));
    assert!(results[2].contains("Skipped: not in the quest log"));
    assert!(results[3].contains("Done: quest 7 in the log"));
    let s = brain.summarize(120_000);
    assert_eq!(s["steps"]["done"], 2);
    assert_eq!(s["steps"]["skipped"], 2);
}

#[test]
#[ignore]
fn print_a_run() {
    let mut server = FakeServer::new(
        START,
        NPC_POS,
        &[CAMP, [CAMP[0] + 20.0, CAMP[1] + 25.0, 82.0]],
    );
    server.kills_needed = 2;
    server.shot_dmg = 10;
    let mut t = Tactics::default();
    t.kite.trigger = 20.0;
    let (mut brain, buf) = setup(&mut server, t, 2, 10.0);
    run(&mut server, &mut brain, 400_000, |_, _| false);
    for l in buf.lines() {
        println!(
            "{} {} {} | {} | {:?}",
            l["t"], l["event"], l["action"], l["result"], l["pos"]
        );
    }
    for (t, l) in &server.log {
        println!("SERVER {t} {l}");
    }
}
