//! Fighting one target: the hunter kite cycle from `tools/autopilot/combat_sim.py` as a state
//! machine, a stand-and-shoot variant, and plain melee for other classes. Pure: a fight reads a
//! [`FightInput`] snapshot and returns [`Intent`]s; the brain turns those into packets.
//!
//! Spell ids, ranks, levels, mana costs and cooldowns are from classic-db `spell_template`
//! (checked 2026-10-16): Auto Shot 75; Raptor Strike 2973/14260/... (6 s, next melee swing, no
//! GCD); Serpent Sting 1978/13549/...; Arcane Shot 3044/14281/... (6 s); Hunter's Mark 1130/...;
//! Concussive Shot 5116 (12 s, 8% base mana); Wing Clip 2974/14267/14268; Aspect of the Monkey
//! 13163; Aspect of the Hawk 13165/...; the instants share a 1.5 s GCD (`StartRecoveryTime`).

use std::collections::BTreeSet;

use super::geom::{dist2, facing, step, Band, RangeBands, Vec3};
use super::tactics::Tactics;

pub const AUTO_SHOT: u32 = 75;
pub const GCD_MS: u64 = 1_500;
/// Auto Shot's wind-up that needs us standing still (CMaNGOS `_UpdateAutoRepeatSpell`: 500 ms).
pub const AIM_MS: u64 = 500;

/// Ascending ranks of each ability the strategies use.
pub fn ranks(name: &str) -> &'static [u32] {
    match name {
        "raptor" => &[2973, 14260, 14261, 14262, 14263, 14264, 14265, 14266],
        "sting" => &[1978, 13549, 13550, 13551, 13552, 13553, 13554, 13555, 25295],
        "arcane" => &[3044, 14281, 14282, 14283, 14284, 14285, 14286, 14287],
        "mark" => &[1130, 14323, 14324, 14325],
        "conc" => &[5116],
        "wingclip" => &[2974, 14267, 14268],
        "monkey" => &[13163],
        "hawk" => &[13165, 14318, 14319, 14320, 14321, 14322, 25296],
        _ => &[],
    }
}

/// The highest rank of `name` in the spell book.
pub fn best_rank(known: &BTreeSet<u32>, name: &str) -> Option<u32> {
    ranks(name)
        .iter()
        .rev()
        .find(|s| known.contains(s))
        .copied()
}

/// Mana cost (`spell_template.ManaCost`, or `ManaCostPercentage` of base mana).
pub fn mana_cost(spell: u32, base_mana: u32) -> u32 {
    match spell {
        2973 => 15,
        14260 => 25,
        14261 => 35,
        1978 => 15,
        13549 => 30,
        13550 => 50,
        3044 => 25,
        14281 => 35,
        14282 => 50,
        1130 => 15,
        5116 => base_mana * 8 / 100,
        2974 => 40,
        13163 | 13165 => 20,
        _ => 0,
    }
}

/// Own cooldown (ms) we record at cast time; the server's `SMSG_SPELL_COOLDOWN` refines it.
pub fn cooldown_ms(spell: u32) -> u64 {
    if ranks("raptor").contains(&spell) || ranks("arcane").contains(&spell) {
        6_000
    } else if spell == 5116 {
        12_000
    } else {
        0
    }
}

/// Whether the spell triggers the global cooldown.
pub fn on_gcd(spell: u32) -> bool {
    !ranks("raptor").contains(&spell) && spell != AUTO_SHOT
}

/// What one tick knows about us and the target.
#[derive(Clone)]
pub struct FightInput<'a> {
    pub now: u64,
    pub me: Vec3,
    pub my_speed: f32,
    pub moving: bool,
    pub target: u64,
    pub tpos: Vec3,
    pub t_dead: bool,
    pub t_hp_pct: f32,
    pub t_speed: f32,
    /// Concussive Shot / Wing Clip on it.
    pub t_slowed: bool,
    pub t_has_sting: bool,
    pub t_has_mark: bool,
    pub mana: u32,
    pub base_mana: u32,
    /// Weapon speed of the ranged weapon (ms, `UNIT_FIELD_RANGEDATTACKTIME`).
    pub ranged_speed_ms: u64,
    pub last_shot_ms: Option<u64>,
    pub known: &'a BTreeSet<u32>,
    pub ready: &'a dyn Fn(u32) -> bool,
}

impl FightInput<'_> {
    pub fn dist(&self) -> f32 {
        dist2(self.me, self.tpos)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Intent {
    Select(u64),
    MoveTo(Vec3),
    Stop,
    FaceTarget,
    AutoShotOn,
    AutoShotOff,
    MeleeOn,
    MeleeOff,
    Cast { spell: u32, target: Option<u64> },
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Phase {
    Approach,
    Ranged,
    /// Running away from the target until `until` (the reload plus the turn).
    KiteRun {
        until: u64,
    },
    /// Standing, turning back to the target.
    Turn {
        until: u64,
    },
    Melee,
    Done,
}

/// One fight against one target.
#[derive(Debug, Clone)]
pub struct Fight {
    pub target: u64,
    pub phase: Phase,
    pub cycles: u32,
    pub started_ms: u64,
    pub bands: RangeBands,
    auto_shot: bool,
    melee: bool,
    selected: bool,
    gcd_until: u64,
    last_shot_seen: Option<u64>,
    run_from: Option<Vec3>,
}

impl Fight {
    pub fn new(target: u64, now: u64) -> Fight {
        Fight {
            target,
            phase: Phase::Approach,
            cycles: 0,
            started_ms: now,
            bands: RangeBands::default(),
            auto_shot: false,
            melee: false,
            selected: false,
            gcd_until: 0,
            last_shot_seen: None,
            run_from: None,
        }
    }

    pub fn auto_shot_on(&self) -> bool {
        self.auto_shot
    }
    pub fn melee_on(&self) -> bool {
        self.melee
    }

    fn cast(&mut self, out: &mut Vec<Intent>, spell: u32, target: Option<u64>, now: u64) {
        if on_gcd(spell) {
            self.gcd_until = now + GCD_MS;
        }
        out.push(Intent::Cast { spell, target });
    }

    fn try_cast(
        &mut self,
        out: &mut Vec<Intent>,
        inp: &FightInput,
        t: &Tactics,
        name: &str,
        target: Option<u64>,
    ) -> bool {
        if !t.uses(name) {
            return false;
        }
        let Some(spell) = best_rank(inp.known, name) else {
            return false;
        };
        if on_gcd(spell) && inp.now < self.gcd_until {
            return false;
        }
        if !(inp.ready)(spell) || inp.mana < mana_cost(spell, inp.base_mana) {
            return false;
        }
        self.cast(out, spell, target, inp.now);
        true
    }

    fn set_auto_shot(&mut self, out: &mut Vec<Intent>, on: bool) {
        if self.auto_shot != on {
            self.auto_shot = on;
            out.push(if on {
                Intent::AutoShotOn
            } else {
                Intent::AutoShotOff
            });
        }
    }

    fn set_melee(&mut self, out: &mut Vec<Intent>, on: bool) {
        if self.melee != on {
            self.melee = on;
            out.push(if on {
                Intent::MeleeOn
            } else {
                Intent::MeleeOff
            });
        }
    }

    fn stop_attacks(&mut self, out: &mut Vec<Intent>) {
        self.set_auto_shot(out, false);
        self.set_melee(out, false);
    }

    fn away_point(&self, inp: &FightInput) -> Vec3 {
        let from = self.run_from.unwrap_or(inp.tpos);
        step(inp.me, facing(from, inp.me), 12.0)
    }

    fn enter_melee(&mut self, out: &mut Vec<Intent>) {
        self.phase = Phase::Melee;
        self.set_auto_shot(out, false);
        self.set_melee(out, true);
    }

    fn kite_allowed(&self, inp: &FightInput, t: &Tactics) -> bool {
        t.strategy == "kite"
            && self.cycles < t.kite.cycles
            && (inp.t_slowed || t.kite.unslowed || inp.t_speed < inp.my_speed - 0.05)
    }

    /// One decision step.
    pub fn tick(&mut self, inp: &FightInput, t: &Tactics) -> Vec<Intent> {
        let mut out = Vec::new();
        if inp.t_dead {
            self.stop_attacks(&mut out);
            if inp.moving {
                out.push(Intent::Stop);
            }
            self.phase = Phase::Done;
            return out;
        }
        if !self.selected {
            self.selected = true;
            out.push(Intent::Select(inp.target));
        }
        if t.strategy == "melee" {
            return self.melee_tick(inp, out);
        }
        let d = inp.dist();
        let band = self.bands.band(d);
        let new_shot = inp.last_shot_ms.is_some() && inp.last_shot_ms != self.last_shot_seen;
        if new_shot {
            self.last_shot_seen = inp.last_shot_ms;
        }
        let open = t
            .kite
            .open
            .clamp(self.bands.min_ranged + 1.0, self.bands.max_ranged);
        match self.phase {
            Phase::Approach => {
                if band == Band::Melee || band == Band::DeadZone {
                    if inp.moving {
                        out.push(Intent::Stop);
                    }
                    self.enter_melee(&mut out);
                    out.push(Intent::FaceTarget);
                } else if d > open - 1.0 {
                    out.push(Intent::MoveTo(inp.tpos));
                } else {
                    out.push(Intent::Stop);
                    out.push(Intent::FaceTarget);
                    // Hunter's Mark goes up before the first shot.
                    if !inp.t_has_mark {
                        self.try_cast(&mut out, inp, t, "mark", Some(inp.target));
                    }
                    self.phase = Phase::Ranged;
                    self.set_auto_shot(&mut out, true);
                }
            }
            Phase::Ranged => match band {
                Band::OutOfRange => {
                    self.phase = Phase::Approach;
                    out.push(Intent::MoveTo(inp.tpos));
                }
                Band::Melee | Band::DeadZone => {
                    if self.kite_allowed(inp, t) && new_shot {
                        self.start_run(&mut out, inp, t);
                    } else {
                        if inp.moving {
                            out.push(Intent::Stop);
                        }
                        out.push(Intent::FaceTarget);
                        self.enter_melee(&mut out);
                        self.melee_abilities(&mut out, inp, t);
                    }
                }
                Band::Ranged => {
                    if inp.moving {
                        out.push(Intent::Stop);
                    }
                    out.push(Intent::FaceTarget);
                    self.set_auto_shot(&mut out, true);
                    if new_shot && d < t.kite.trigger && self.kite_allowed(inp, t) {
                        self.start_run(&mut out, inp, t);
                    } else {
                        self.ranged_abilities(&mut out, inp, t);
                    }
                }
            },
            Phase::KiteRun { until } => {
                if inp.now >= until {
                    out.push(Intent::Stop);
                    out.push(Intent::FaceTarget);
                    self.phase = Phase::Turn {
                        until: inp.now + (t.kite.turn * 1000.0) as u64,
                    };
                    self.run_from = None;
                } else {
                    // Instants work while running (combat_sim: "usable while moving").
                    out.push(Intent::MoveTo(self.away_point(inp)));
                    if band == Band::Ranged {
                        self.ranged_abilities(&mut out, inp, t);
                    }
                }
            }
            Phase::Turn { until } => {
                out.push(Intent::FaceTarget);
                if inp.now >= until {
                    if band == Band::Melee || band == Band::DeadZone {
                        self.enter_melee(&mut out);
                    } else {
                        self.phase = Phase::Ranged;
                        self.set_auto_shot(&mut out, true);
                    }
                }
            }
            Phase::Melee => {
                if band == Band::Ranged && !inp.moving && d >= self.bands.min_ranged + 1.0 {
                    // It fled or we got distance: back to shooting.
                    self.phase = Phase::Ranged;
                    self.set_melee(&mut out, false);
                    self.set_auto_shot(&mut out, true);
                    out.push(Intent::FaceTarget);
                } else if d > self.bands.melee - 0.5 {
                    out.push(Intent::MoveTo(inp.tpos));
                } else {
                    if inp.moving {
                        out.push(Intent::Stop);
                    }
                    out.push(Intent::FaceTarget);
                    self.set_melee(&mut out, true);
                    // Wing Clip, then run (combat_sim: "Wing Clip at L12 gives another run").
                    if t.strategy == "kite"
                        && self.cycles < t.kite.cycles
                        && !inp.t_slowed
                        && self.try_cast(&mut out, inp, t, "wingclip", Some(inp.target))
                    {
                        self.cycles += 1;
                        self.set_melee(&mut out, false);
                        self.set_auto_shot(&mut out, true);
                        self.run_from = Some(inp.tpos);
                        self.phase = Phase::KiteRun {
                            until: inp.now + (t.kite.clip_run * 1000.0) as u64,
                        };
                        out.push(Intent::MoveTo(self.away_point(inp)));
                    } else {
                        self.melee_abilities(&mut out, inp, t);
                    }
                }
            }
            Phase::Done => {}
        }
        out
    }

    fn start_run(&mut self, out: &mut Vec<Intent>, inp: &FightInput, t: &Tactics) {
        let shot = inp.last_shot_ms.unwrap_or(inp.now);
        let reload = inp.ranged_speed_ms.saturating_sub(AIM_MS);
        self.cycles += 1;
        self.run_from = Some(inp.tpos);
        self.phase = Phase::KiteRun {
            until: (shot + reload).max(inp.now) + (t.kite.turn * 1000.0) as u64,
        };
        // Keep Auto Shot on: the server pauses it while we move and resumes after the 0.5 s aim.
        self.set_auto_shot(out, true);
        out.push(Intent::MoveTo(self.away_point(inp)));
    }

    fn ranged_abilities(&mut self, out: &mut Vec<Intent>, inp: &FightInput, t: &Tactics) {
        let tg = Some(inp.target);
        // Same order as combat_sim.py: Sting (if the mob will live through it), Concussive, Arcane.
        if !inp.t_has_sting && inp.t_hp_pct > 0.3 && self.try_cast(out, inp, t, "sting", tg) {
            return;
        }
        if !inp.t_slowed && self.try_cast(out, inp, t, "conc", tg) {
            return;
        }
        self.try_cast(out, inp, t, "arcane", tg);
    }

    fn melee_abilities(&mut self, out: &mut Vec<Intent>, inp: &FightInput, t: &Tactics) {
        // Raptor Strike replaces the next swing (no GCD).
        self.try_cast(out, inp, t, "raptor", Some(inp.target));
    }

    fn melee_tick(&mut self, inp: &FightInput, mut out: Vec<Intent>) -> Vec<Intent> {
        let d = inp.dist();
        if d > self.bands.melee - 1.0 {
            out.push(Intent::MoveTo(inp.tpos));
            self.phase = Phase::Approach;
        } else {
            if inp.moving {
                out.push(Intent::Stop);
            }
            out.push(Intent::FaceTarget);
            self.phase = Phase::Melee;
        }
        // Start swinging once close (CMaNGOS chases with us; harmless out of range).
        if d <= self.bands.melee + 5.0 {
            self.set_melee(&mut out, true);
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn known() -> BTreeSet<u32> {
        [75u32, 2973, 1978, 3044, 1130, 5116, 2974]
            .into_iter()
            .collect()
    }

    struct S {
        known: BTreeSet<u32>,
        ready: Box<dyn Fn(u32) -> bool>,
    }

    fn s() -> S {
        S {
            known: known(),
            ready: Box::new(|_| true),
        }
    }

    fn inp<'a>(s: &'a S, now: u64, me: Vec3, tpos: Vec3) -> FightInput<'a> {
        FightInput {
            now,
            me,
            my_speed: 7.0,
            moving: false,
            target: 0x42,
            tpos,
            t_dead: false,
            t_hp_pct: 1.0,
            t_speed: 6.0,
            t_slowed: false,
            t_has_sting: true,
            t_has_mark: true,
            mana: 200,
            base_mana: 100,
            ranged_speed_ms: 2_300,
            last_shot_ms: None,
            known: &s.known,
            ready: &*s.ready,
        }
    }

    fn has(v: &[Intent], i: &Intent) -> bool {
        v.contains(i)
    }

    fn casts(v: &[Intent]) -> Vec<u32> {
        v.iter()
            .filter_map(|i| match i {
                Intent::Cast { spell, .. } => Some(*spell),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn approach_then_open_fire_with_mark_first() {
        let s = s();
        let t = Tactics::default();
        let mut f = Fight::new(0x42, 0);
        let mut i = inp(&s, 0, [0.0; 3], [60.0, 0.0, 0.0]);
        i.t_has_mark = false;
        let v = f.tick(&i, &t);
        assert!(has(&v, &Intent::Select(0x42)));
        assert!(has(&v, &Intent::MoveTo([60.0, 0.0, 0.0])));
        assert_eq!(f.phase, Phase::Approach);
        i.me = [27.0, 0.0, 0.0]; // 33 yd away: inside the 35 yd opening distance
        i.moving = true;
        let v = f.tick(&i, &t);
        assert!(has(&v, &Intent::Stop));
        assert!(has(&v, &Intent::AutoShotOn));
        assert_eq!(casts(&v), vec![1130], "Hunter's Mark before the first shot");
        assert_eq!(f.phase, Phase::Ranged);
    }

    #[test]
    fn ranged_rotation_respects_the_gcd_and_cooldowns() {
        let mut s = s();
        let t = Tactics::default();
        let mut f = Fight::new(0x42, 0);
        f.phase = Phase::Ranged;
        let mut i = inp(&s, 1_000, [0.0; 3], [25.0, 0.0, 0.0]);
        i.t_has_sting = false;
        assert_eq!(casts(&f.tick(&i, &t)), vec![1978], "sting first");
        i.now = 1_500;
        i.t_has_sting = true;
        assert!(casts(&f.tick(&i, &t)).is_empty(), "GCD still running");
        i.now = 2_600;
        assert_eq!(casts(&f.tick(&i, &t)), vec![5116], "then Concussive");
        // Arcane on cooldown: nothing.
        s.ready = Box::new(|sp| sp != 3044);
        let mut i = inp(&s, 4_200, [0.0; 3], [25.0, 0.0, 0.0]);
        i.t_slowed = true;
        assert!(casts(&f.tick(&i, &t)).is_empty());
    }

    #[test]
    fn kite_cycle_run_turn_shoot() {
        let s = s();
        let t = Tactics::default(); // trigger 15, cycles 2, turn 0.3
        let mut f = Fight::new(0x42, 0);
        f.phase = Phase::Ranged;
        f.auto_shot = true;
        let me = [0.0, 0.0, 0.0];
        let mut i = inp(&s, 10_000, me, [12.0, 0.0, 0.0]);
        i.last_shot_ms = Some(10_000);
        let v = f.tick(&i, &t);
        // Mob at 12 yd after a shot, slower than us (6 < 7): run away during the reload.
        let Phase::KiteRun { until } = f.phase else {
            panic!("{:?}", f.phase)
        };
        assert_eq!(
            until,
            10_000 + 1_800 + 300,
            "reload (2.3 s - 0.5 s aim) + turn"
        );
        let away = v
            .iter()
            .find_map(|x| match x {
                Intent::MoveTo(p) => Some(*p),
                _ => None,
            })
            .unwrap();
        assert!(away[0] < -5.0, "runs away from the mob: {away:?}");
        assert_eq!(f.cycles, 1);
        assert!(!has(&v, &Intent::AutoShotOff), "auto shot stays armed");

        let mut i2 = inp(&s, 12_100, [-14.0, 0.0, 0.0], [4.0, 0.0, 0.0]);
        i2.moving = true;
        i2.last_shot_ms = Some(10_000);
        let v = f.tick(&i2, &t);
        assert!(has(&v, &Intent::Stop) && has(&v, &Intent::FaceTarget));
        assert!(matches!(f.phase, Phase::Turn { .. }));
        i2.now = 12_400;
        i2.moving = false;
        f.tick(&i2, &t);
        assert_eq!(f.phase, Phase::Ranged, "18 yd: shooting again");
    }

    #[test]
    fn no_kite_when_the_mob_is_as_fast_and_not_slowed() {
        let s = s();
        let t = Tactics::default();
        let mut f = Fight::new(0x42, 0);
        f.phase = Phase::Ranged;
        let mut i = inp(&s, 5_000, [0.0; 3], [12.0, 0.0, 0.0]);
        i.t_speed = 7.0;
        i.last_shot_ms = Some(5_000);
        i.t_slowed = false;
        f.tick(&i, &t);
        assert_eq!(f.phase, Phase::Ranged);
        // Slowed by Concussive: now it may run.
        i.t_slowed = true;
        i.last_shot_ms = Some(7_300);
        i.now = 7_300;
        f.tick(&i, &t);
        assert!(matches!(f.phase, Phase::KiteRun { .. }));
    }

    #[test]
    fn dead_zone_without_cycles_left_goes_melee_with_raptor() {
        let s = s();
        let t = Tactics::default();
        let mut f = Fight::new(0x42, 0);
        f.phase = Phase::Ranged;
        f.auto_shot = true;
        f.cycles = 2;
        let i = inp(&s, 20_000, [0.0; 3], [6.0, 0.0, 0.0]);
        let v = f.tick(&i, &t);
        assert_eq!(f.phase, Phase::Melee);
        assert!(has(&v, &Intent::AutoShotOff) && has(&v, &Intent::MeleeOn));
        assert_eq!(casts(&v), vec![2973]);
        // In melee at 6 yd we close in; at 3 yd we stand and swing.
        let v = f.tick(&inp(&s, 20_200, [0.0; 3], [6.0, 0.0, 0.0]), &t);
        assert!(has(&v, &Intent::MoveTo([6.0, 0.0, 0.0])));
    }

    #[test]
    fn wing_clip_buys_another_run() {
        let s = s();
        let t = Tactics::default();
        let mut f = Fight::new(0x42, 0);
        f.phase = Phase::Melee;
        f.melee = true;
        f.cycles = 1;
        let v = f.tick(&inp(&s, 30_000, [0.0; 3], [2.0, 0.0, 0.0]), &t);
        assert_eq!(casts(&v), vec![2974]);
        assert!(has(&v, &Intent::MeleeOff) && has(&v, &Intent::AutoShotOn));
        assert_eq!(f.phase, Phase::KiteRun { until: 32_500 });
        assert_eq!(f.cycles, 2);
    }

    #[test]
    fn stand_strategy_never_runs() {
        let s = s();
        let t = Tactics {
            strategy: "stand".into(),
            ..Default::default()
        };
        let mut f = Fight::new(0x42, 0);
        f.phase = Phase::Ranged;
        let mut i = inp(&s, 5_000, [0.0; 3], [12.0, 0.0, 0.0]);
        i.last_shot_ms = Some(5_000);
        i.t_slowed = true;
        f.tick(&i, &t);
        assert_eq!(f.phase, Phase::Ranged);
    }

    #[test]
    fn melee_strategy_walks_in_and_swings() {
        let s = s();
        let t = Tactics {
            strategy: "melee".into(),
            ..Default::default()
        };
        let mut f = Fight::new(0x42, 0);
        let v = f.tick(&inp(&s, 0, [0.0; 3], [30.0, 0.0, 0.0]), &t);
        assert!(has(&v, &Intent::MoveTo([30.0, 0.0, 0.0])));
        assert!(!has(&v, &Intent::MeleeOn));
        let v = f.tick(&inp(&s, 100, [27.0, 0.0, 0.0], [30.0, 0.0, 0.0]), &t);
        assert!(has(&v, &Intent::FaceTarget) && has(&v, &Intent::MeleeOn));
        assert!(!has(&v, &Intent::AutoShotOn));
    }

    #[test]
    fn a_dead_target_ends_the_fight() {
        let s = s();
        let t = Tactics::default();
        let mut f = Fight::new(0x42, 0);
        f.phase = Phase::Ranged;
        f.auto_shot = true;
        let mut i = inp(&s, 0, [0.0; 3], [20.0, 0.0, 0.0]);
        i.t_dead = true;
        let v = f.tick(&i, &t);
        assert_eq!(v, vec![Intent::AutoShotOff]);
        assert_eq!(f.phase, Phase::Done);
    }

    #[test]
    fn ranks_pick_the_highest_known() {
        let k: BTreeSet<u32> = [2973, 14260, 1978].into_iter().collect();
        assert_eq!(best_rank(&k, "raptor"), Some(14260));
        assert_eq!(best_rank(&k, "sting"), Some(1978));
        assert_eq!(best_rank(&k, "arcane"), None);
        assert!(!on_gcd(14260) && on_gcd(1978) && !on_gcd(AUTO_SHOT));
        assert_eq!(mana_cost(5116, 120), 9);
    }
}
