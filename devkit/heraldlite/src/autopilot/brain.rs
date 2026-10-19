//! The brain: a ~150 ms tick over a fixed priority list, in the spirit of CMaNGOS playerbots'
//! strategy -> trigger -> action design, kept small:
//!
//! 1. survive: dead -> release spirit, corpse run, reclaim;
//! 2. combat: anything attacking us, or the target we pulled;
//! 3. loot: lootable corpses we may loot nearby;
//! 4. rest: eat / drink / sit below the thresholds;
//! 5. buffs: Aspect of the Monkey / Hawk when known and missing;
//! 6. quest step: the route's current step (accept, objectives, turn in, travel);
//! 7. done: route complete or time limit -> stop.
//!
//! Pure apart from the [`RunLog`] writer: `tick(now)` reads the [`World`] and returns packets.

use std::collections::{HashMap, HashSet};

use super::combat::{self, Fight, FightInput, Intent, Phase, AUTO_SHOT};
use super::geom::{dist2, facing, step as step_toward, Vec3};
use super::loot::{LootPhase, Looter, LOOT_REACH};
use super::movement::{Follow, Mover, Navigator, PathFollower, Recovery};
use super::out::{OutCmd, STAND_STATE_SIT, STAND_STATE_STAND};
use super::quest::{Goal, Route, Step, StepKind, Talk, TalkInput, TalkResult};
use super::runlog::{RunLog, Stamp};
use super::tactics::Tactics;
use super::world::{
    Note, World, GO_TYPE_CHEST, GO_TYPE_GOOBER, UNIT_FLAG_IMMUNE_TO_PLAYER,
    UNIT_FLAG_UNINTERACTIBLE, UNIT_FLAG_UNTARGETABLE, UNIT_NPC_FLAG_QUESTGIVER,
};

pub const TICK_MS: u64 = 150;
/// Food and drink auras (classic-db `spell_template`: "Food" 433/434/435, "Drink" 430/431/432,
/// the item spells of the default food/drink lists).
const FOOD_AURAS: &[u32] = &[433, 434, 435, 1127, 1129, 1131];
const DRINK_AURAS: &[u32] = &[430, 431, 432, 1133, 1135, 1137];
const SLOW_AURAS: &[u32] = &[5116, 2974, 14267, 14268];
/// The CMaNGOS default corpse reclaim delay for a first death.
const DEFAULT_RECLAIM_MS: u64 = 30_000;

#[derive(Debug, Clone)]
pub struct BrainConfig {
    pub tactics: Tactics,
    pub route: Route,
    pub max_minutes: f32,
}

#[derive(Debug, Default)]
struct StepRun {
    started_ms: u64,
    talk: Option<Talk>,
    arrived_ms: Option<u64>,
    kills_at_start: u32,
    search_i: usize,
    used_gos: HashSet<u64>,
    chest: Option<Looter>,
    trigger_sent: bool,
    giver: Option<u64>,
}

#[derive(Debug, Default)]
struct Death {
    released_ms: Option<u64>,
    ghost_since: Option<u64>,
    query_ms: Option<u64>,
    reclaim_ms: Option<u64>,
    delay_ms: Option<u64>,
}

#[derive(Debug)]
struct Rest {
    since: u64,
    used_food: bool,
    used_drink: bool,
    sat: bool,
}

pub struct Brain {
    pub world: World,
    pub mover: Mover,
    pub log: RunLog,
    nav: Box<dyn Navigator + Send>,
    follower: Option<PathFollower>,
    tactics: Tactics,
    route: Route,
    max_ms: u64,
    pub step_idx: usize,
    run: StepRun,
    fight: Option<Fight>,
    looter: Option<Looter>,
    looted: HashSet<u64>,
    rest: Option<Rest>,
    death: Death,
    blacklist: HashMap<u64, u64>,
    pub kills_by_entry: HashMap<u32, u32>,
    counted: HashSet<u64>,
    fought: HashSet<u64>,
    quest_refusal: Option<(u64, String)>,
    pub finished: Option<String>,
    initialised: bool,
    auto_shot: bool,
    melee: bool,
    target: Option<u64>,
    loot_error: Option<u64>,
}

impl Brain {
    pub fn new(
        world: World,
        cfg: BrainConfig,
        nav: Box<dyn Navigator + Send>,
        log: RunLog,
    ) -> Brain {
        let mover = Mover::new(world.pos, world.orientation, world.run_speed);
        Brain {
            world,
            mover,
            log,
            nav,
            follower: None,
            tactics: cfg.tactics,
            route: cfg.route,
            max_ms: (cfg.max_minutes.max(0.0) * 60_000.0) as u64,
            step_idx: 0,
            run: StepRun::default(),
            fight: None,
            looter: None,
            looted: HashSet::new(),
            rest: None,
            death: Death::default(),
            blacklist: HashMap::new(),
            kills_by_entry: HashMap::new(),
            counted: HashSet::new(),
            fought: HashSet::new(),
            quest_refusal: None,
            finished: None,
            initialised: false,
            auto_shot: false,
            melee: false,
            target: None,
            loot_error: None,
        }
    }

    pub fn route(&self) -> &Route {
        &self.route
    }

    fn stamp(&self, now: u64) -> Stamp {
        Stamp {
            now_ms: now,
            pos: self.mover.pos,
            level: self.world.level(),
            xp: self.world.xp(),
            hp: self.world.health(),
            max_hp: self.world.max_health(),
            mana: self.world.mana(),
        }
    }

    fn cur_step(&self) -> Option<&Step> {
        self.route.steps.get(self.step_idx)
    }

    fn step_tag(&self) -> Option<(usize, &'static str)> {
        self.cur_step().map(|s| (s.index, s.kind_name()))
    }

    fn decide(&mut self, now: u64, action: impl AsRef<str>) {
        let s = self.stamp(now);
        let tag = self.step_tag();
        self.log.decision(&s, tag, action.as_ref());
    }

    fn outcome(&mut self, now: u64, action: impl AsRef<str>, result: impl AsRef<str>) {
        let s = self.stamp(now);
        let tag = self.step_tag();
        self.log.outcome(&s, tag, action.as_ref(), result.as_ref());
    }

    fn goal3(&self, p: [f32; 2]) -> Vec3 {
        let z = self.world.ground_z(p[0], p[1]).unwrap_or(self.mover.pos[2]);
        [p[0], p[1], z]
    }

    // ── movement helpers ──────────────────────────────────────────────────────────────────────

    /// Walk toward `goal` with the navigator and stuck recovery.
    fn navigate(&mut self, now: u64, goal: Vec3, radius: f32, out: &mut Vec<OutCmd>) -> Follow {
        let rebuild = self
            .follower
            .as_ref()
            .is_none_or(|f| dist2(f.goal, goal) > 2.0 || (f.arrive_radius - radius).abs() > 0.01);
        if rebuild {
            match self.nav.route(self.mover.pos, goal) {
                Ok(wps) => self.follower = Some(PathFollower::new(goal, wps, radius, now)),
                Err(e) => return Follow::GaveUp(format!("{}: {e}", self.nav.name())),
            }
        }
        let mut f = self.follower.take().expect("follower");
        let g = |x: f32, y: f32| self.world.ground_z(x, y);
        let (cmds, state) = f.tick(now, &mut self.mover, &g);
        out.extend(cmds);
        if let Some(r) = f.last_recovery.take() {
            self.log.stuck += 1;
            let what = match r {
                Recovery::Sidestep(p) => format!("sidestep to ({:.1}, {:.1})", p[0], p[1]),
                Recovery::Backtrack(p) => format!("backtrack to ({:.1}, {:.1})", p[0], p[1]),
            };
            self.outcome(now, "stuck", what);
        }
        match &state {
            Follow::Moving => self.follower = Some(f),
            Follow::Arrived => {}
            Follow::GaveUp(why) => {
                self.log.stuck += 1;
                let why = why.clone();
                self.outcome(now, "stuck", format!("gave up: {why}"));
            }
        }
        state
    }

    fn stop(&mut self, now: u64, out: &mut Vec<OutCmd>) {
        self.follower = None;
        let g = |x: f32, y: f32| self.world.ground_z(x, y);
        out.extend(self.mover.stop(now, &g));
    }

    fn face_point(&mut self, now: u64, p: Vec3, out: &mut Vec<OutCmd>) {
        let o = facing(self.mover.pos, p);
        let g = |x: f32, y: f32| self.world.ground_z(x, y);
        out.extend(self.mover.face(now, o, &g));
    }

    fn stop_attacks(&mut self, out: &mut Vec<OutCmd>) {
        if self.auto_shot {
            out.push(OutCmd::CancelAutoRepeat);
            self.auto_shot = false;
        }
        if self.melee {
            out.push(OutCmd::AttackStop);
            self.melee = false;
        }
    }

    // ── the tick ──────────────────────────────────────────────────────────────────────────────

    pub fn tick(&mut self, now: u64) -> Vec<OutCmd> {
        let mut out = Vec::new();
        if !self.initialised {
            self.initialised = true;
            self.mover.set_pos(self.world.pos, self.world.orientation);
            let s = self.stamp(now);
            self.log.write(
                super::runlog::Kind::Start,
                &s,
                None,
                "start",
                &format!(
                    "{} route steps, strategy {}, navigator {}, run speed {:.2}",
                    self.route.steps.len(),
                    self.tactics.strategy,
                    self.nav.name(),
                    self.world.run_speed
                ),
                serde_json::Value::Null,
            );
        }
        self.mover.speed = self.world.run_speed;
        self.drain_notes(now);
        let s = self.stamp(now);
        self.log.progress(&s, self.world.next_level_xp());
        if self.finished.is_some() {
            return out;
        }
        if let Some(why) = self.world.closed.clone() {
            self.finish(now, &format!("connection closed: {why}"));
            return out;
        }
        if self.max_ms > 0 && now >= self.max_ms {
            self.stop(now, &mut out);
            self.stop_attacks(&mut out);
            self.finish(now, "time limit");
            return out;
        }
        // 1. survive
        if self.world.is_dead_body() || self.world.is_ghost() {
            self.death_tick(now, &mut out);
            return out;
        }
        self.death = Death::default();
        // 2. combat
        if self.combat_tick(now, &mut out) {
            return out;
        }
        // 3. loot
        if self.loot_tick(now, &mut out) {
            return out;
        }
        // 4. rest
        if self.rest_tick(now, &mut out) {
            return out;
        }
        // 5. buffs
        if self.buff_tick(now, &mut out) {
            return out;
        }
        // 6. quest step
        self.step_tick(now, &mut out);
        out
    }

    /// Log an outcome from outside the brain (the driver's logout).
    pub fn outcome_public(&mut self, now: u64, action: &str, result: &str) {
        self.outcome(now, action, result);
    }

    fn finish(&mut self, now: u64, why: &str) {
        if self.finished.is_none() {
            self.finished = Some(why.to_string());
            self.outcome(now, "finish", why);
        }
    }

    /// The packets to stop cleanly before logging out.
    pub fn shutdown(&mut self, now: u64) -> Vec<OutCmd> {
        let mut out = vec![];
        self.stop(now, &mut out);
        self.stop_attacks(&mut out);
        if self.world.is_sitting() {
            out.push(OutCmd::StandState(STAND_STATE_STAND));
        }
        out
    }

    /// The end-of-run summary (and its line in the log).
    pub fn summarize(&mut self, now: u64) -> serde_json::Value {
        let reason = self.finished.clone().unwrap_or_else(|| "stopped".into());
        self.log.last_step = Some(self.step_idx.min(self.route.steps.len()));
        let mut v = self.log.summary(
            now,
            &reason,
            &self.route.predicted_minutes_per_level,
            &self.route.predicted_quest_minutes,
            self.route.steps.len(),
        );
        v["kills_by_entry"] = serde_json::json!(self
            .kills_by_entry
            .iter()
            .map(|(k, v)| (k.to_string(), *v))
            .collect::<std::collections::BTreeMap<_, _>>());
        let s = self.stamp(now);
        self.log.finish(&s, &v);
        v
    }

    fn drain_notes(&mut self, now: u64) {
        while let Some(n) = self.world.notes.pop_front() {
            match n {
                Note::XpGain {
                    amount,
                    victim,
                    kill,
                } => {
                    if kill {
                        self.count_kill(now, victim);
                    }
                    self.outcome(
                        now,
                        "xp",
                        format!("+{amount}{}", if kill { " (kill)" } else { "" }),
                    );
                }
                Note::LevelUp(l) => self.outcome(now, "level up", format!("level {l}")),
                Note::QuestObjective {
                    quest,
                    entry,
                    count,
                    required,
                } => self.outcome(
                    now,
                    "quest progress",
                    format!("quest {quest}: {entry} {count}/{required}"),
                ),
                Note::QuestItem { item, count } => {
                    self.outcome(now, "quest progress", format!("item {item} x{count}"))
                }
                Note::QuestObjectivesComplete(q) => self.outcome(
                    now,
                    "quest progress",
                    format!("quest {q} objectives complete"),
                ),
                Note::QuestRewarded { quest, xp, money } => {
                    self.log.quest_rewarded(quest, now);
                    self.outcome(
                        now,
                        "quest rewarded",
                        format!("quest {quest} (+{xp} xp, {money} copper)"),
                    );
                }
                Note::QuestInvalid(r) => {
                    self.quest_refusal =
                        Some((now, format!("SMSG_QUESTGIVER_QUEST_INVALID reason {r}")))
                }
                Note::QuestFailed { quest, reason } => {
                    self.quest_refusal = Some((
                        now,
                        format!("SMSG_QUESTGIVER_QUEST_FAILED quest {quest} reason {reason}"),
                    ))
                }
                Note::QuestLogFull => self.quest_refusal = Some((now, "quest log full".into())),
                Note::CastFailed { spell, reason } => {
                    self.outcome(
                        now,
                        format!("cast {spell}"),
                        format!("failed (SpellCastResult {reason})"),
                    );
                    if spell == AUTO_SHOT {
                        self.auto_shot = false;
                    }
                }
                Note::AttackError(e) => self.outcome(now, "melee", format!("refused: {e}")),
                Note::LootError { guid, error } => {
                    self.loot_error = Some(guid);
                    self.outcome(now, "loot", format!("{guid:#x}: LOOT_ERROR {error}"));
                }
                Note::ItemReceived { entry, count } => {
                    self.outcome(now, "item", format!("received {entry} x{count}"))
                }
                Note::Money(c) => self.outcome(now, "loot", format!("{c} copper")),
                Note::Teleported(p) => {
                    self.mover.set_pos(p, self.world.orientation);
                    self.follower = None;
                    self.outcome(
                        now,
                        "server moved us",
                        format!("({:.1}, {:.1}, {:.1})", p[0], p[1], p[2]),
                    );
                }
                Note::Died => {
                    self.log.deaths += 1;
                    self.fight = None;
                    self.looter = None;
                    self.rest = None;
                    self.auto_shot = false;
                    self.melee = false;
                    self.outcome(now, "died", "");
                }
                Note::Ghost => self.outcome(now, "released", "ghost"),
                Note::Resurrected => {
                    self.outcome(now, "resurrected", "");
                    self.death = Death::default();
                }
                Note::CorpseAt(p) => self.outcome(
                    now,
                    "corpse",
                    format!("({:.1}, {:.1}, {:.1})", p[0], p[1], p[2]),
                ),
                Note::ReclaimDelay(ms) => self.death.delay_ms = Some(u64::from(ms)),
                Note::Closed(why) => self.outcome(now, "connection", why),
            }
        }
    }

    fn count_kill(&mut self, now: u64, victim: u64) {
        if victim == 0 || !self.counted.insert(victim) {
            return;
        }
        let entry = self.world.unit(victim).map(|u| u.entry()).unwrap_or(0);
        *self.kills_by_entry.entry(entry).or_default() += 1;
        self.log.kills += 1;
        self.outcome(now, "kill", format!("{entry} ({victim:#x})"));
    }

    // ── 1. death ──────────────────────────────────────────────────────────────────────────────

    fn death_tick(&mut self, now: u64, out: &mut Vec<OutCmd>) {
        self.fight = None;
        self.looter = None;
        if self.world.is_dead_body() {
            if self.mover.is_moving() {
                self.stop(now, out);
            }
            if self.death.released_ms.is_none_or(|t| now >= t + 5_000) {
                self.death.released_ms = Some(now);
                self.decide(now, "release spirit");
                out.push(OutCmd::RepopRequest);
            }
            return;
        }
        // Ghost: find the corpse, run there, wait out the delay, reclaim.
        let since = *self.death.ghost_since.get_or_insert(now);
        let corpse = self.world.corpse_pos.or_else(|| {
            self.world
                .corpses
                .values()
                .find(|(o, _)| *o == self.world.me)
                .map(|(_, p)| *p)
        });
        let Some(cp) = corpse else {
            if self.death.query_ms.is_none_or(|t| now >= t + 5_000) {
                self.death.query_ms = Some(now);
                self.decide(now, "ask where the corpse is");
                out.push(OutCmd::CorpseQuery);
            }
            return;
        };
        if dist2(self.mover.pos, cp) > 6.0 {
            self.decide(now, format!("corpse run to ({:.1}, {:.1})", cp[0], cp[1]));
            if let Follow::GaveUp(_) = self.navigate(now, cp, 5.0, out) {
                self.follower = None;
            }
            return;
        }
        if self.mover.is_moving() {
            self.stop(now, out);
        }
        let delay = self.death.delay_ms.unwrap_or(DEFAULT_RECLAIM_MS);
        if now < since + delay {
            self.decide(now, "wait for the reclaim delay");
            return;
        }
        if self.death.reclaim_ms.is_none_or(|t| now >= t + 3_000) {
            self.death.reclaim_ms = Some(now);
            let guid = self
                .world
                .corpses
                .iter()
                .find(|(_, (o, _))| *o == self.world.me)
                .map(|(g, _)| *g)
                .unwrap_or(0);
            self.decide(now, "reclaim corpse");
            out.push(OutCmd::ReclaimCorpse(guid));
        }
    }

    // ── 2. combat ─────────────────────────────────────────────────────────────────────────────

    /// Start a fight against `target` (logged as a pull).
    fn engage(&mut self, now: u64, target: u64, why: &str) {
        let (entry, lvl) = self
            .world
            .unit(target)
            .map(|u| (u.entry(), u.level()))
            .unwrap_or((0, 0));
        self.fight = Some(Fight::new(target, now));
        self.fought.insert(target);
        self.follower = None;
        self.outcome(
            now,
            "pull",
            format!("{why}: entry {entry} level {lvl} guid {target:#x}"),
        );
    }

    fn combat_tick(&mut self, now: u64, out: &mut Vec<OutCmd>) -> bool {
        let attackers = self.world.live_attackers(now);
        // Keep the current fight unless its target is gone; otherwise take the nearest attacker.
        let current_ok = self.fight.as_ref().is_some_and(|f| {
            self.world.unit(f.target).is_some_and(|u| !u.is_dead()) && f.phase != Phase::Done
        });
        if !current_ok {
            if let Some(f) = self.fight.take() {
                self.end_fight(now, f, out);
            }
            let me = self.mover.pos;
            if let Some(t) = attackers.iter().copied().min_by(|a, b| {
                let d = |g: &u64| {
                    self.world
                        .unit(*g)
                        .map(|u| dist2(me, u.pos_at(now)))
                        .unwrap_or(f32::MAX)
                };
                d(a).total_cmp(&d(b))
            }) {
                if let Some(r) = self.rest.take() {
                    if r.sat || self.world.is_sitting() {
                        out.push(OutCmd::StandState(STAND_STATE_STAND));
                    }
                }
                self.looter = None;
                self.engage(now, t, "attacked");
            } else {
                return false;
            }
        }
        let Some(mut f) = self.fight.take() else {
            return false;
        };
        let Some(u) = self.world.unit(f.target).cloned() else {
            self.end_fight(now, f, out);
            return true;
        };
        let tactics = self
            .tactics
            .for_fight(self.world.level(), u.entry())
            .unwrap_or_else(|_| self.tactics.clone());
        // Give up on a target we cannot hurt (evading, unreachable, immune).
        if now > f.started_ms + (tactics.pull.give_up_s * 1000.0) as u64
            && u.hp_pct() >= 0.999
            && !attackers.contains(&f.target)
        {
            self.blacklist.insert(f.target, now + 120_000);
            self.outcome(
                now,
                "fight",
                format!(
                    "gave up on {:#x}: no damage in {} s",
                    f.target, tactics.pull.give_up_s
                ),
            );
            self.stop_attacks(out);
            self.fight = None;
            return true;
        }
        let tpos = u.pos_at(now);
        let known = self.world.spells.clone();
        let world = &self.world;
        let ready = |sp: u32| world.spell_ready(sp, now);
        let ranged_ms = u64::from(
            self.world
                .fields
                .unit_ranged_attack_time()
                .unwrap_or(2_300)
                .max(1_000),
        );
        let inp = FightInput {
            now,
            me: self.mover.pos,
            my_speed: self.mover.speed,
            moving: self.mover.is_moving(),
            target: f.target,
            tpos,
            t_dead: u.is_dead(),
            t_hp_pct: u.hp_pct(),
            t_speed: u.run_speed,
            t_slowed: SLOW_AURAS.iter().any(|a| u.has_aura(*a)),
            t_has_sting: combat::ranks("sting").iter().any(|a| u.has_aura(*a)),
            t_has_mark: combat::ranks("mark").iter().any(|a| u.has_aura(*a)),
            mana: self.world.mana(),
            base_mana: self
                .world
                .fields
                .unit_base_mana()
                .unwrap_or(self.world.max_mana()),
            ranged_speed_ms: ranged_ms,
            last_shot_ms: self.world.last_shot_ms,
            known: &known,
            ready: &ready,
        };
        let phase_before = f.phase;
        let intents = f.tick(&inp, &tactics);
        if f.phase != phase_before {
            self.decide(now, format!("fight {:#x}: {:?}", f.target, f.phase));
        }
        for i in intents {
            self.apply_intent(now, f.target, tpos, i, out);
        }
        if f.phase == Phase::Done {
            self.end_fight(now, f, out);
        } else {
            self.fight = Some(f);
        }
        true
    }

    fn apply_intent(
        &mut self,
        now: u64,
        target: u64,
        tpos: Vec3,
        i: Intent,
        out: &mut Vec<OutCmd>,
    ) {
        let g = |x: f32, y: f32| self.world.ground_z(x, y);
        match i {
            Intent::Select(t) => {
                self.target = Some(t);
                out.push(OutCmd::SetSelection(t));
            }
            Intent::MoveTo(p) => {
                self.follower = None;
                if !self.mover.is_moving() || self.mover.dest().is_none_or(|d| dist2(d, p) > 1.0) {
                    out.extend(self.mover.go(now, p, &g));
                } else {
                    out.extend(self.mover.tick(now, &g));
                }
            }
            Intent::Stop => out.extend(self.mover.stop(now, &g)),
            Intent::FaceTarget => {
                let o = facing(self.mover.pos, tpos);
                out.extend(self.mover.face(now, o, &g));
            }
            Intent::AutoShotOn => {
                if self.melee {
                    out.push(OutCmd::AttackStop);
                    self.melee = false;
                }
                out.push(OutCmd::CastSpell {
                    spell: AUTO_SHOT,
                    target: Some(target),
                });
                self.auto_shot = true;
            }
            Intent::AutoShotOff => {
                if self.auto_shot {
                    out.push(OutCmd::CancelAutoRepeat);
                    self.auto_shot = false;
                }
            }
            Intent::MeleeOn => {
                out.push(OutCmd::AttackSwing(target));
                self.melee = true;
            }
            Intent::MeleeOff => {
                if self.melee {
                    out.push(OutCmd::AttackStop);
                    self.melee = false;
                }
            }
            Intent::Cast { spell, target } => {
                let cd = combat::cooldown_ms(spell);
                if cd > 0 {
                    self.world.cooldowns.insert(spell, now + cd);
                }
                self.outcome(now, format!("cast {spell}"), "sent");
                out.push(OutCmd::CastSpell { spell, target });
            }
        }
    }

    fn end_fight(&mut self, now: u64, f: Fight, out: &mut Vec<OutCmd>) {
        self.stop_attacks(out);
        let dead = self.world.unit(f.target).is_some_and(|u| u.is_dead());
        if dead {
            // Count kills that gave no XP (grey mobs) too, once.
            if self
                .world
                .unit(f.target)
                .is_some_and(|u| !u.tapped_by_other())
            {
                self.count_kill(now, f.target);
            }
            self.outcome(
                now,
                "fight",
                format!(
                    "{:#x} dead after {:.1} s",
                    f.target,
                    (now - f.started_ms) as f64 / 1000.0
                ),
            );
        } else {
            self.outcome(now, "fight", format!("{:#x} gone", f.target));
        }
    }

    // ── 3. loot ───────────────────────────────────────────────────────────────────────────────

    fn loot_tick(&mut self, now: u64, out: &mut Vec<OutCmd>) -> bool {
        if self.looter.is_none() {
            let me = self.mover.pos;
            let radius = self.tactics.loot_radius;
            let cand = self
                .world
                .units
                .values()
                .filter(|u| u.is_dead() && u.lootable() && !self.looted.contains(&u.guid))
                // Anything lootable close by, and our own kills further out (shot at 35 yd).
                .filter(|u| {
                    let d = dist2(me, u.pos);
                    d <= radius || (self.fought.contains(&u.guid) && d <= radius.max(60.0))
                })
                .min_by(|a, b| dist2(me, a.pos).total_cmp(&dist2(me, b.pos)))
                .map(|u| u.guid);
            let Some(g) = cand else {
                return false;
            };
            self.looter = Some(Looter::new(g, false));
            self.loot_error = None;
        }
        let mut l = self.looter.take().unwrap();
        let pos = if l.chest {
            self.world.gos.get(&l.guid).map(|g| g.pos)
        } else {
            self.world.unit(l.guid).map(|u| u.pos)
        };
        let Some(pos) = pos else {
            self.looted.insert(l.guid);
            return false;
        };
        if matches!(l.phase, LootPhase::Open { sent_ms: None })
            && dist2(self.mover.pos, pos) > LOOT_REACH
        {
            self.decide(now, format!("walk to loot {:#x}", l.guid));
            if let Follow::GaveUp(_) = self.navigate(now, pos, LOOT_REACH - 0.5, out) {
                self.looted.insert(l.guid);
                return false;
            }
            self.looter = Some(l);
            return true;
        }
        if self.mover.is_moving() {
            self.stop(now, out);
        }
        let released = self.world.loot_released == Some(l.guid);
        let error = self.loot_error == Some(l.guid);
        let cmds = l.tick(now, self.world.loot.as_ref(), released, error);
        if !cmds.is_empty() {
            self.decide(now, format!("loot {:#x}", l.guid));
        }
        out.extend(cmds);
        if let LootPhase::Done { items, money, ok } = l.phase {
            self.looted.insert(l.guid);
            if ok {
                self.log.loot_corpses += 1;
                self.log.loot_items += items;
                self.log.loot_money += money;
            }
            self.outcome(
                now,
                format!("loot {:#x}", l.guid),
                format!(
                    "{} items, {money} copper{}",
                    items,
                    if ok { "" } else { " (failed)" }
                ),
            );
            return true;
        }
        self.looter = Some(l);
        true
    }

    // ── 4. rest ───────────────────────────────────────────────────────────────────────────────

    fn find_consumable(&self, ids: &[u32]) -> Option<(u8, u8, u32)> {
        let bags = self.world.bag_items();
        ids.iter()
            .find_map(|id| bags.iter().find(|b| b.entry == *id))
            .map(|b| (b.bag, b.slot, b.entry))
    }

    fn rest_tick(&mut self, now: u64, out: &mut Vec<OutCmd>) -> bool {
        let r = self
            .tactics
            .for_level(self.world.level())
            .unwrap_or_else(|_| self.tactics.clone())
            .rest;
        let hp = self.world.hp_pct();
        let mana = self.world.mana_pct();
        if self.rest.is_none() {
            if hp >= r.eat_below && mana >= r.drink_below {
                return false;
            }
            self.stop(now, out);
            self.rest = Some(Rest {
                since: now,
                used_food: false,
                used_drink: false,
                sat: false,
            });
            self.decide(
                now,
                format!("rest (hp {:.0}%, mana {:.0}%)", hp * 100.0, mana * 100.0),
            );
        }
        let mut rest = self.rest.take().unwrap();
        let done = (hp >= r.stand_hp && mana >= r.stand_mana)
            || now >= rest.since + (r.max_rest_s * 1000.0) as u64;
        if done {
            if rest.sat || self.world.is_sitting() {
                out.push(OutCmd::StandState(STAND_STATE_STAND));
            }
            self.outcome(
                now,
                "rest",
                format!(
                    "done after {:.0} s (hp {:.0}%, mana {:.0}%)",
                    (now - rest.since) as f64 / 1000.0,
                    hp * 100.0,
                    mana * 100.0
                ),
            );
            return true;
        }
        if hp < r.stand_hp && !rest.used_food && !FOOD_AURAS.iter().any(|a| self.world.has_aura(*a))
        {
            rest.used_food = true;
            if let Some((bag, slot, entry)) = self.find_consumable(&self.tactics.food_items) {
                self.decide(now, format!("eat {entry}"));
                out.push(OutCmd::UseItem { bag, slot });
                self.rest = Some(rest);
                return true;
            }
        }
        if mana < r.stand_mana
            && self.world.max_mana() > 0
            && !rest.used_drink
            && !DRINK_AURAS.iter().any(|a| self.world.has_aura(*a))
        {
            rest.used_drink = true;
            if let Some((bag, slot, entry)) = self.find_consumable(&self.tactics.drink_items) {
                self.decide(now, format!("drink {entry}"));
                out.push(OutCmd::UseItem { bag, slot });
                self.rest = Some(rest);
                return true;
            }
        }
        if !rest.sat && !self.world.is_sitting() && now >= rest.since + 1_500 {
            rest.sat = true;
            self.decide(now, "sit");
            out.push(OutCmd::StandState(STAND_STATE_SIT));
        }
        self.rest = Some(rest);
        true
    }

    // ── 5. buffs ──────────────────────────────────────────────────────────────────────────────

    fn buff_tick(&mut self, now: u64, out: &mut Vec<OutCmd>) -> bool {
        let t = &self.tactics;
        // Hawk once known (L10+), else Monkey (L4+): combat_sim's assumptions.
        for name in ["hawk", "monkey"] {
            if !t.uses(name) {
                continue;
            }
            let Some(spell) = combat::best_rank(&self.world.spells, name) else {
                continue;
            };
            if self.world.has_aura(spell) {
                return false;
            }
            if !self.world.spell_ready(spell, now)
                || self.world.mana() < combat::mana_cost(spell, 0)
            {
                return false;
            }
            self.world.cooldowns.insert(spell, now + 3_000); // don't spam while the aura streams in
            self.decide(now, format!("buff {spell}"));
            out.push(OutCmd::CastSpell {
                spell,
                target: None,
            });
            return true;
        }
        false
    }

    // ── 6. quest steps ────────────────────────────────────────────────────────────────────────

    fn next_step(&mut self, now: u64, result: &str, kind: StepEnd) {
        let desc = self.cur_step().map(|s| s.desc.clone()).unwrap_or_default();
        match kind {
            StepEnd::Done => self.log.steps_done += 1,
            StepEnd::Skipped => self.log.steps_skipped += 1,
            StepEnd::Failed => self.log.steps_failed += 1,
        }
        self.outcome(now, format!("step: {desc}"), format!("{kind:?}: {result}"));
        self.step_idx += 1;
        self.run = StepRun {
            started_ms: now,
            ..Default::default()
        };
        self.follower = None;
        self.quest_refusal = None;
        self.log.last_step = Some(self.step_idx);
    }

    fn step_tick(&mut self, now: u64, out: &mut Vec<OutCmd>) {
        let Some(step) = self.cur_step().cloned() else {
            self.stop(now, out);
            self.finish(now, "route complete");
            return;
        };
        if self.run.started_ms == 0 {
            self.run.started_ms = now.max(1);
            self.run.kills_at_start = match step.kind {
                StepKind::Kill { entry, .. } | StepKind::Grind { entry, .. } => {
                    self.kills_by_entry.get(&entry).copied().unwrap_or(0)
                }
                _ => 0,
            };
            self.decide(now, format!("step {}: {}", step.index, step.desc));
        }
        // A generous timeout per step: 3x the plan, at least 5 minutes, plus 2 minutes.
        let budget = ((step.planned_minutes() * 3.0 * 60_000.0) as u64).max(300_000) + 120_000;
        if now > self.run.started_ms + budget {
            self.stop(now, out);
            self.next_step(
                now,
                &format!("timed out after {} s", budget / 1000),
                StepEnd::Failed,
            );
            return;
        }
        let goal = self.goal3(step.pos);
        match step.kind.clone() {
            StepKind::Travel => {
                self.decide(now, format!("travel to ({:.1}, {:.1})", goal[0], goal[1]));
                match self.navigate(now, goal, 3.0, out) {
                    Follow::Arrived => self.next_step(now, "arrived", StepEnd::Done),
                    Follow::GaveUp(why) => self.next_step(now, &why, StepEnd::Failed),
                    Follow::Moving => {}
                }
            }
            StepKind::Accept { quest } => {
                if self.world.quest(quest).is_some() && self.run.talk.is_none() {
                    self.log.quest_taken(quest, &step.desc, now);
                    self.next_step(now, "already in the quest log", StepEnd::Done);
                    return;
                }
                self.talk_step(now, &step, quest, Goal::Accept, goal, out);
            }
            StepKind::TurnIn { quest } => {
                if self.world.quest(quest).is_none() && self.run.talk.is_none() {
                    let why = if self.log.rewarded(quest) {
                        "already rewarded"
                    } else {
                        "not in the quest log"
                    };
                    self.next_step(now, why, StepEnd::Skipped);
                    return;
                }
                self.talk_step(now, &step, quest, Goal::TurnIn, goal, out);
            }
            StepKind::Kill {
                entry,
                count,
                quests,
            } => {
                // Done when every listed quest that is in our log is complete (kill credit and
                // item drops alike); with none of them in the log, when the planned kills are in.
                let in_log: Vec<_> = quests.iter().filter_map(|q| self.world.quest(*q)).collect();
                let done = if in_log.is_empty() {
                    self.kills_since_start(entry) >= count
                } else {
                    in_log.iter().all(|q| q.complete)
                };
                if done {
                    self.stop(now, out);
                    self.next_step(
                        now,
                        &format!("{} kill(s) of {entry}", self.kills_since_start(entry)),
                        StepEnd::Done,
                    );
                    return;
                }
                self.hunt(now, entry, goal, out);
            }
            StepKind::Grind { entry, count } => {
                if self.kills_since_start(entry) >= count {
                    self.stop(now, out);
                    self.next_step(now, &format!("{count} kill(s) of {entry}"), StepEnd::Done);
                    return;
                }
                self.hunt(now, entry, goal, out);
            }
            StepKind::Objects { quest, go_entry } => {
                if self.world.quest(quest).is_some_and(|q| q.complete) {
                    self.stop(now, out);
                    self.next_step(now, "objectives complete", StepEnd::Done);
                    return;
                }
                if self.world.quest(quest).is_none() {
                    self.next_step(now, "quest not in the log", StepEnd::Skipped);
                    return;
                }
                self.objects(now, go_entry, goal, out);
            }
            StepKind::Explore { quest, trigger } => {
                if self.world.quest(quest).is_some_and(|q| q.complete) {
                    self.next_step(now, "explored", StepEnd::Done);
                    return;
                }
                match self.navigate(now, goal, 3.0, out) {
                    Follow::Arrived | Follow::GaveUp(_) => {
                        let at = *self.run.arrived_ms.get_or_insert(now);
                        if let (Some(t), false) = (trigger, self.run.trigger_sent) {
                            self.run.trigger_sent = true;
                            out.push(OutCmd::AreaTrigger(t));
                        }
                        if now >= at + 5_000 {
                            let r = if trigger.is_some() {
                                "visited, AreaTrigger sent, no credit seen"
                            } else {
                                "visited; no AreaTrigger id in the route, credit not verified"
                            };
                            self.next_step(now, r, StepEnd::Skipped);
                        }
                    }
                    Follow::Moving => self.decide(now, "travel to explore"),
                }
            }
            StepKind::Unsupported(k) => {
                self.next_step(
                    now,
                    &format!("step kind {k:?} is not supported in v1"),
                    StepEnd::Skipped,
                );
            }
        }
    }

    fn kills_since_start(&self, entry: u32) -> u32 {
        self.kills_by_entry
            .get(&entry)
            .copied()
            .unwrap_or(0)
            .saturating_sub(self.run.kills_at_start)
    }

    fn talk_step(
        &mut self,
        now: u64,
        step: &Step,
        quest: u32,
        goal_kind: Goal,
        goal: Vec3,
        out: &mut Vec<OutCmd>,
    ) {
        // The giver: the step's npc entry if given, else the nearest quest giver to the step.
        let giver = self
            .run
            .giver
            .filter(|g| self.world.unit(*g).is_some())
            .or_else(|| {
                self.world
                    .units
                    .values()
                    .filter(|u| !u.is_player && u.npc_flags() & UNIT_NPC_FLAG_QUESTGIVER != 0)
                    .filter(|u| step.npc.is_none_or(|e| u.entry() == e))
                    // A named giver may stand a little off the planner's point; a guessed one may not.
                    .filter(|u| dist2(u.pos, goal) <= if step.npc.is_some() { 60.0 } else { 25.0 })
                    .min_by(|a, b| dist2(a.pos, goal).total_cmp(&dist2(b.pos, goal)))
                    .map(|u| u.guid)
            });
        let Some(npc) = giver else {
            self.decide(now, format!("go to the quest giver for {quest}"));
            match self.navigate(now, goal, 4.0, out) {
                Follow::Arrived | Follow::GaveUp(_) => {
                    let at = *self.run.arrived_ms.get_or_insert(now);
                    if now >= at + 8_000 {
                        self.next_step(
                            now,
                            "no quest giver within 25 yd of the step",
                            StepEnd::Failed,
                        );
                    }
                }
                Follow::Moving => {}
            }
            return;
        };
        self.run.giver = Some(npc);
        let npos = self.world.unit(npc).map(|u| u.pos_at(now)).unwrap_or(goal);
        if dist2(self.mover.pos, npos) > 4.0 && self.run.talk.is_none() {
            self.decide(now, format!("walk to quest giver {npc:#x}"));
            if let Follow::GaveUp(why) = self.navigate(now, npos, 3.0, out) {
                self.next_step(now, &why, StepEnd::Failed);
            }
            return;
        }
        if self.mover.is_moving() {
            self.stop(now, out);
        }
        self.face_point(now, npos, out);
        // Refusals are cleared at every step change, so any refusal here is about this talk.
        let refused = self.quest_refusal.as_ref().map(|(_, w)| w.clone());
        let talk = self
            .run
            .talk
            .get_or_insert_with(|| Talk::new(npc, quest, goal_kind));
        let inp = TalkInput {
            now,
            dialog: self.world.dialog.as_ref(),
            in_log: self.world.quest(quest).map(|q| q.complete),
            rewarded: self.log.rewarded(quest),
            refused,
        };
        let (cmds, res) = talk.tick(&inp);
        if let Some(c) = cmds.first() {
            let label = c.label();
            self.decide(now, format!("{label} {npc:#x} quest {quest}"));
        }
        out.extend(cmds);
        match res {
            TalkResult::Pending => {}
            TalkResult::Done(r) => {
                if goal_kind == Goal::Accept {
                    self.log
                        .quest_taken(quest, step.desc.trim_start_matches("accept "), now);
                }
                self.world.dialog = None;
                self.next_step(now, &r, StepEnd::Done);
            }
            TalkResult::Failed(r) => {
                self.world.dialog = None;
                self.next_step(now, &r, StepEnd::Failed);
            }
        }
    }

    /// Find and pull the nearest suitable mob of `entry` near `center`, or search for one.
    fn hunt(&mut self, now: u64, entry: u32, center: Vec3, out: &mut Vec<OutCmd>) {
        let t = self
            .tactics
            .for_level(self.world.level())
            .unwrap_or_else(|_| self.tactics.clone());
        let me = self.mover.pos;
        let my_level = self.world.level();
        self.blacklist.retain(|_, until| *until > now);
        let target = self
            .world
            .units
            .values()
            .filter(|u| !u.is_player && u.entry() == entry && !u.is_dead())
            .filter(|u| !u.tapped_by_other() && !self.blacklist.contains_key(&u.guid))
            .filter(|u| {
                u.unit_flags()
                    & (UNIT_FLAG_UNTARGETABLE
                        | UNIT_FLAG_UNINTERACTIBLE
                        | UNIT_FLAG_IMMUNE_TO_PLAYER)
                    == 0
            })
            .filter(|u| u.level() <= my_level + t.pull.max_level_above)
            .filter(|u| dist2(u.pos_at(now), center) <= t.pull.search_radius)
            .min_by(|a, b| dist2(me, a.pos_at(now)).total_cmp(&dist2(me, b.pos_at(now))))
            .map(|u| u.guid);
        if let Some(g) = target {
            self.engage(now, g, &format!("step target {entry}"));
            return;
        }
        // Nothing in view: go to the camp, then walk a ring around it.
        let ring: Vec<Vec3> = (0..6)
            .map(|i| {
                let p = step_toward(center, i as f32 * std::f32::consts::TAU / 6.0, 25.0);
                self.goal3([p[0], p[1]])
            })
            .collect();
        let goal = if self.run.arrived_ms.is_none() {
            center
        } else {
            ring[self.run.search_i % ring.len()]
        };
        self.decide(
            now,
            format!(
                "search for {entry} near ({:.0}, {:.0})",
                center[0], center[1]
            ),
        );
        match self.navigate(now, goal, 3.0, out) {
            Follow::Arrived | Follow::GaveUp(_) => {
                if self.run.arrived_ms.is_some() {
                    self.run.search_i += 1;
                }
                self.run.arrived_ms.get_or_insert(now);
            }
            Follow::Moving => {}
        }
    }

    fn objects(&mut self, now: u64, go_entry: Option<u32>, center: Vec3, out: &mut Vec<OutCmd>) {
        if let Some(mut l) = self.run.chest.take() {
            let pos = self.world.gos.get(&l.guid).map(|g| g.pos);
            let Some(pos) = pos else {
                self.run.used_gos.insert(l.guid);
                return;
            };
            if matches!(l.phase, LootPhase::Open { sent_ms: None })
                && dist2(self.mover.pos, pos) > LOOT_REACH
            {
                if let Follow::GaveUp(_) = self.navigate(now, pos, LOOT_REACH - 0.5, out) {
                    self.run.used_gos.insert(l.guid);
                    return;
                }
                self.run.chest = Some(l);
                return;
            }
            if self.mover.is_moving() {
                self.stop(now, out);
            }
            let released = self.world.loot_released == Some(l.guid);
            let error = self.loot_error == Some(l.guid);
            out.extend(l.tick(now, self.world.loot.as_ref(), released, error));
            if let LootPhase::Done { items, ok, .. } = l.phase {
                self.run.used_gos.insert(l.guid);
                self.outcome(
                    now,
                    format!("use object {:#x}", l.guid),
                    format!("{items} items{}", if ok { "" } else { " (failed)" }),
                );
            } else {
                self.run.chest = Some(l);
            }
            return;
        }
        let me = self.mover.pos;
        let used = &self.run.used_gos;
        let go = self
            .world
            .gos
            .values()
            .filter(|g| !used.contains(&g.guid))
            .filter(|g| match go_entry {
                Some(e) => g.entry == e,
                None => matches!(g.go_type(), GO_TYPE_CHEST | GO_TYPE_GOOBER),
            })
            .filter(|g| dist2(g.pos, center) <= 60.0)
            .min_by(|a, b| dist2(me, a.pos).total_cmp(&dist2(me, b.pos)))
            .map(|g| g.guid);
        if let Some(g) = go {
            self.decide(now, format!("use object {g:#x}"));
            self.run.chest = Some(Looter::new(g, true));
            return;
        }
        self.decide(now, "search for quest objects");
        let goal = if self.run.arrived_ms.is_none() {
            center
        } else {
            let p = step_toward(
                center,
                self.run.search_i as f32 * std::f32::consts::TAU / 6.0,
                20.0,
            );
            self.goal3([p[0], p[1]])
        };
        match self.navigate(now, goal, 3.0, out) {
            Follow::Arrived | Follow::GaveUp(_) => {
                if self.run.arrived_ms.is_some() {
                    self.run.search_i += 1;
                }
                self.run.arrived_ms.get_or_insert(now);
            }
            Follow::Moving => {}
        }
    }
}

#[derive(Debug, Clone, Copy)]
enum StepEnd {
    Done,
    Skipped,
    Failed,
}
