//! Our own movement: the `MSG_MOVE_*` stream a 1.12 client sends while running in straight lines,
//! a [`Navigator`] seam for path planning (v1: [`StraightLine`]; a Detour/mmaps navigator plugs in
//! later), and a [`PathFollower`] with stuck detection and recovery.
//!
//! The 1.12 client's stream, as CMaNGOS classic `MovementHandler.cpp` expects it:
//! - `MSG_MOVE_SET_FACING` when the heading changes (flags keep `FORWARD` while running),
//! - `MSG_MOVE_START_FORWARD` with `MOVEFLAG_FORWARD` at the start position,
//! - `MSG_MOVE_HEARTBEAT` every 500 ms while moving, at the current position,
//! - `MSG_MOVE_STOP` with no flags at the final position.
//!
//! Positions are dead-reckoned at the server's run speed (`SMSG_FORCE_RUN_SPEED_CHANGE`, or the
//! create block's speed). There is no height map yet: z comes from a ground estimate (see
//! `World::ground_z`) or is interpolated between waypoints.

use std::collections::VecDeque;
use std::f32::consts::FRAC_PI_2;

use benilla_protocol::messages::opcode;

use super::geom::{angle_diff, dist2, facing, step, Vec3};
use super::out::{OutCmd, MOVEFLAG_FORWARD, MOVEFLAG_NONE};

/// The 1.12 client's heartbeat cadence while moving.
pub const HEARTBEAT_MS: u64 = 500;
/// Heading changes smaller than this are not worth a `SET_FACING`.
pub const FACING_EPS: f32 = 0.05;

pub type GroundFn<'a> = &'a dyn Fn(f32, f32) -> Option<f32>;

/// Dead-reckoned mover that emits the packets a client would.
#[derive(Debug, Clone)]
pub struct Mover {
    pub pos: Vec3,
    pub orientation: f32,
    /// Run speed in yd/s.
    pub speed: f32,
    moving: bool,
    seg_start: Vec3,
    dest: Option<Vec3>,
    last_tick_ms: u64,
    last_sent_ms: u64,
}

impl Mover {
    pub fn new(pos: Vec3, orientation: f32, speed: f32) -> Mover {
        Mover {
            pos,
            orientation,
            speed,
            moving: false,
            seg_start: pos,
            dest: None,
            last_tick_ms: 0,
            last_sent_ms: 0,
        }
    }

    pub fn is_moving(&self) -> bool {
        self.moving
    }

    pub fn dest(&self) -> Option<Vec3> {
        self.dest
    }

    /// The flags our packets carry right now.
    pub fn flags(&self) -> u32 {
        if self.moving {
            MOVEFLAG_FORWARD
        } else {
            MOVEFLAG_NONE
        }
    }

    fn msg(&mut self, op: u16, now: u64) -> OutCmd {
        self.last_sent_ms = now;
        OutCmd::Move {
            opcode: op,
            flags: self.flags(),
            pos: self.pos,
            orientation: self.orientation,
            time_ms: now,
        }
    }

    /// Run toward `dest`: turn (if needed) and start, or just turn when already running.
    pub fn go(&mut self, now: u64, dest: Vec3, ground: GroundFn) -> Vec<OutCmd> {
        let mut out = self.advance(now, ground);
        if dist2(self.pos, dest) < 0.05 {
            if self.moving {
                out.extend(self.stop(now, ground));
            }
            return out;
        }
        self.seg_start = self.pos;
        self.dest = Some(dest);
        let o = facing(self.pos, dest);
        let turn = angle_diff(self.orientation, o).abs() > FACING_EPS;
        self.orientation = o;
        if !self.moving {
            if turn {
                out.push(self.msg(opcode::MSG_MOVE_SET_FACING, now));
            }
            self.moving = true;
            self.last_tick_ms = now;
            out.push(self.msg(opcode::MSG_MOVE_START_FORWARD, now));
        } else if turn {
            out.push(self.msg(opcode::MSG_MOVE_SET_FACING, now));
        }
        out
    }

    /// Move the dead-reckoned position up to `now` (no packets).
    fn advance(&mut self, now: u64, ground: GroundFn) -> Vec<OutCmd> {
        if !self.moving {
            self.last_tick_ms = now;
            return vec![];
        }
        let Some(dest) = self.dest else {
            return vec![];
        };
        let dt = now.saturating_sub(self.last_tick_ms) as f32 / 1000.0;
        self.last_tick_ms = now;
        let left = dist2(self.pos, dest);
        let d = (self.speed * dt).min(left);
        let mut p = step(self.pos, self.orientation, d);
        if left - d < 0.01 {
            p = dest;
        }
        p[2] = ground(p[0], p[1]).unwrap_or_else(|| {
            let total = dist2(self.seg_start, dest).max(1e-3);
            let t = (dist2(self.seg_start, p) / total).clamp(0.0, 1.0);
            self.seg_start[2] + (dest[2] - self.seg_start[2]) * t
        });
        self.pos = p;
        vec![]
    }

    /// Advance; heartbeat every 500 ms; stop on arrival.
    pub fn tick(&mut self, now: u64, ground: GroundFn) -> Vec<OutCmd> {
        let mut out = self.advance(now, ground);
        if !self.moving {
            return out;
        }
        if self.dest.is_some_and(|d| dist2(self.pos, d) < 0.01) {
            out.extend(self.stop(now, ground));
            return out;
        }
        if now.saturating_sub(self.last_sent_ms) >= HEARTBEAT_MS {
            out.push(self.msg(opcode::MSG_MOVE_HEARTBEAT, now));
        }
        out
    }

    /// Stop where we are now.
    pub fn stop(&mut self, now: u64, ground: GroundFn) -> Vec<OutCmd> {
        let mut out = self.advance(now, ground);
        if self.moving {
            self.moving = false;
            self.dest = None;
            out.push(self.msg(opcode::MSG_MOVE_STOP, now));
        }
        out
    }

    /// Turn in place (or while running) to face `o`.
    pub fn face(&mut self, now: u64, o: f32, ground: GroundFn) -> Vec<OutCmd> {
        let mut out = self.advance(now, ground);
        if angle_diff(self.orientation, o).abs() > FACING_EPS {
            self.orientation = o;
            out.push(self.msg(opcode::MSG_MOVE_SET_FACING, now));
        }
        out
    }

    /// A server correction (teleport, worldport): adopt it silently; we are no longer moving.
    pub fn set_pos(&mut self, p: Vec3, o: f32) {
        self.pos = p;
        self.orientation = o;
        self.moving = false;
        self.dest = None;
        self.seg_start = p;
    }
}

/// Plans a route. v1 is [`StraightLine`]; a Detour/mmaps implementation can replace it.
pub trait Navigator {
    /// Waypoints from `from` to `to` (the last one is `to`).
    fn route(&mut self, from: Vec3, to: Vec3) -> Result<Vec<Vec3>, String>;
    fn name(&self) -> &'static str;
}

/// One straight segment.
#[derive(Debug, Default, Clone, Copy)]
pub struct StraightLine;

impl Navigator for StraightLine {
    fn route(&mut self, _from: Vec3, to: Vec3) -> Result<Vec<Vec3>, String> {
        Ok(vec![to])
    }
    fn name(&self) -> &'static str {
        "straight-line"
    }
}

/// No progress for `window_ms` -> stuck.
#[derive(Debug, Clone)]
pub struct StuckDetector {
    pub window_ms: u64,
    pub min_progress: f32,
    best: f32,
    since: u64,
}

impl StuckDetector {
    pub fn new(window_ms: u64, min_progress: f32) -> StuckDetector {
        StuckDetector {
            window_ms,
            min_progress,
            best: f32::INFINITY,
            since: 0,
        }
    }
    pub fn reset(&mut self, now: u64) {
        self.best = f32::INFINITY;
        self.since = now;
    }
    /// Feed the distance left; true once it has not shrunk by `min_progress` for the window.
    pub fn stuck(&mut self, now: u64, dist_left: f32) -> bool {
        if dist_left < self.best - self.min_progress || !self.best.is_finite() {
            self.best = dist_left;
            self.since = now;
            return false;
        }
        now.saturating_sub(self.since) >= self.window_ms
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Follow {
    Moving,
    Arrived,
    GaveUp(String),
}

/// What recovery did, for the run log.
#[derive(Debug, Clone, PartialEq)]
pub enum Recovery {
    Sidestep(Vec3),
    Backtrack(Vec3),
}

/// Walks a waypoint list with a [`Mover`], detecting and recovering from being stuck: first a
/// sidestep (alternating left/right), then a backtrack to where we were a while ago, then it gives
/// up after `max_recoveries`.
#[derive(Debug, Clone)]
pub struct PathFollower {
    pub goal: Vec3,
    pub arrive_radius: f32,
    pub waypoints: VecDeque<Vec3>,
    pub stuck: StuckDetector,
    pub recoveries: u32,
    pub max_recoveries: u32,
    pub last_recovery: Option<Recovery>,
    history: VecDeque<(u64, Vec3)>,
    detour: bool,
}

impl PathFollower {
    pub fn new(goal: Vec3, waypoints: Vec<Vec3>, arrive_radius: f32, now: u64) -> PathFollower {
        let mut stuck = StuckDetector::new(5_000, 1.0);
        stuck.reset(now);
        PathFollower {
            goal,
            arrive_radius,
            waypoints: waypoints.into(),
            stuck,
            recoveries: 0,
            max_recoveries: 3,
            last_recovery: None,
            history: VecDeque::new(),
            detour: false,
        }
    }

    pub fn tick(&mut self, now: u64, m: &mut Mover, ground: GroundFn) -> (Vec<OutCmd>, Follow) {
        let mut out = m.tick(now, ground);
        if self.history.back().is_none_or(|(t, _)| now >= t + 1_000) {
            self.history.push_back((now, m.pos));
            while self.history.len() > 30 {
                self.history.pop_front();
            }
        }
        if dist2(m.pos, self.goal) <= self.arrive_radius {
            out.extend(m.stop(now, ground));
            return (out, Follow::Arrived);
        }
        // Drop reached waypoints.
        while let Some(w) = self.waypoints.front().copied() {
            let last = self.waypoints.len() == 1;
            let r = if last { self.arrive_radius } else { 1.0 };
            if dist2(m.pos, w) <= r {
                self.waypoints.pop_front();
                if self.detour {
                    self.detour = false;
                    self.stuck.reset(now);
                }
            } else {
                break;
            }
        }
        let Some(next) = self.waypoints.front().copied() else {
            self.waypoints.push_back(self.goal);
            return (out, Follow::Moving);
        };
        if self.stuck.stuck(now, dist2(m.pos, next)) {
            if self.recoveries >= self.max_recoveries {
                out.extend(m.stop(now, ground));
                return (
                    out,
                    Follow::GaveUp(format!(
                        "no progress toward ({:.1}, {:.1}) after {} recoveries",
                        next[0], next[1], self.recoveries
                    )),
                );
            }
            self.recoveries += 1;
            let rec = if self.recoveries % 2 == 1 {
                let side = if self.recoveries % 4 == 1 {
                    FRAC_PI_2
                } else {
                    -FRAC_PI_2
                };
                Recovery::Sidestep(step(m.pos, facing(m.pos, next) + side, 6.0))
            } else {
                let back = self
                    .history
                    .iter()
                    .rev()
                    .find(|(t, p)| now.saturating_sub(*t) >= 3_000 && dist2(*p, m.pos) > 3.0)
                    .map(|(_, p)| *p)
                    .unwrap_or_else(|| step(m.pos, facing(next, m.pos), 8.0));
                Recovery::Backtrack(back)
            };
            let p = match &rec {
                Recovery::Sidestep(p) | Recovery::Backtrack(p) => *p,
            };
            self.waypoints.push_front(p);
            self.detour = true;
            self.last_recovery = Some(rec);
            self.stuck.reset(now);
        }
        let next = *self.waypoints.front().unwrap();
        if !m.is_moving() || m.dest().is_none_or(|d| dist2(d, next) > 0.1) {
            out.extend(m.go(now, next, ground));
        }
        (out, Follow::Moving)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn flat(_: f32, _: f32) -> Option<f32> {
        None
    }

    fn ops(v: &[OutCmd]) -> Vec<u16> {
        v.iter().map(|c| c.opcode()).collect()
    }

    #[test]
    fn start_heartbeat_stop_sequence_and_flags() {
        let mut m = Mover::new([0.0, 0.0, 10.0], 0.0, 7.0);
        let first = m.go(0, [10.0, 0.0, 10.0], &flat);
        // Already facing north: no SET_FACING, just START_FORWARD at the start position.
        assert_eq!(ops(&first), vec![opcode::MSG_MOVE_START_FORWARD]);
        let OutCmd::Move { flags, pos, .. } = first[0] else {
            panic!()
        };
        assert_eq!(flags, MOVEFLAG_FORWARD);
        assert_eq!(pos, [0.0, 0.0, 10.0]);

        let mut sent = vec![];
        let mut t = 0;
        while t < 1_200 {
            t += 100;
            sent.extend(m.tick(t, &flat));
        }
        // Heartbeats at 500 and 1000 ms only.
        let hb: Vec<u64> = sent
            .iter()
            .filter_map(|c| match c {
                OutCmd::Move {
                    opcode: o,
                    time_ms,
                    flags,
                    ..
                } if *o == opcode::MSG_MOVE_HEARTBEAT => {
                    assert_eq!(*flags, MOVEFLAG_FORWARD);
                    Some(*time_ms)
                }
                _ => None,
            })
            .collect();
        assert_eq!(hb, vec![500, 1000]);
        let OutCmd::Move { pos, .. } = sent.last().unwrap() else {
            panic!()
        };
        assert!((pos[0] - 7.0).abs() < 0.01, "1 s at 7 yd/s: {pos:?}");

        // 10 yd at 7 yd/s: arrival (and the stop) at ~1430 ms.
        let rest = m.tick(1_500, &flat);
        assert!(!m.is_moving());
        let all: Vec<_> = sent.iter().chain(rest.iter()).cloned().collect();
        let stop = all
            .iter()
            .find(|c| c.opcode() == opcode::MSG_MOVE_STOP)
            .expect("a stop");
        let OutCmd::Move { flags, pos, .. } = stop else {
            panic!()
        };
        assert_eq!(*flags, MOVEFLAG_NONE, "STOP carries no movement flags");
        assert_eq!(*pos, [10.0, 0.0, 10.0]);
    }

    #[test]
    fn turning_sends_set_facing_first_and_keeps_forward_while_running() {
        let mut m = Mover::new([0.0, 0.0, 0.0], 0.0, 7.0);
        let v = m.go(0, [0.0, 10.0, 0.0], &flat);
        assert_eq!(
            ops(&v),
            vec![opcode::MSG_MOVE_SET_FACING, opcode::MSG_MOVE_START_FORWARD]
        );
        let OutCmd::Move {
            flags, orientation, ..
        } = v[0]
        else {
            panic!()
        };
        assert_eq!(flags, MOVEFLAG_NONE, "turned before starting");
        assert!((orientation - FRAC_PI_2).abs() < 1e-4);
        // Redirect while running: SET_FACING with FORWARD still set.
        let v = m.go(200, [-10.0, 1.4, 0.0], &flat);
        assert_eq!(ops(&v), vec![opcode::MSG_MOVE_SET_FACING]);
        let OutCmd::Move { flags, .. } = v[0] else {
            panic!()
        };
        assert_eq!(flags, MOVEFLAG_FORWARD);
        // A tiny heading change sends nothing.
        assert!(m.face(250, m.orientation + 0.01, &flat).is_empty());
    }

    #[test]
    fn z_follows_the_ground_estimate_or_interpolates() {
        let mut m = Mover::new([0.0, 0.0, 0.0], 0.0, 10.0);
        m.go(0, [10.0, 0.0, 20.0], &flat);
        m.tick(500, &flat);
        assert!((m.pos[2] - 10.0).abs() < 0.01, "halfway: {:?}", m.pos);
        let hill = |_: f32, _: f32| Some(3.5);
        m.tick(700, &hill);
        assert_eq!(m.pos[2], 3.5);
    }

    #[test]
    fn server_correction_stops_without_a_packet() {
        let mut m = Mover::new([0.0, 0.0, 0.0], 0.0, 7.0);
        m.go(0, [50.0, 0.0, 0.0], &flat);
        m.set_pos([100.0, 100.0, 5.0], 1.0);
        assert!(!m.is_moving());
        assert!(m.tick(600, &flat).is_empty());
        assert_eq!(m.pos, [100.0, 100.0, 5.0]);
    }

    #[test]
    fn follower_arrives_on_a_waypoint_list() {
        let mut m = Mover::new([0.0, 0.0, 0.0], 0.0, 7.0);
        let goal = [20.0, 20.0, 0.0];
        let mut f = PathFollower::new(goal, vec![[20.0, 0.0, 0.0], goal], 2.0, 0);
        let mut t = 0;
        let mut state = Follow::Moving;
        while t < 20_000 && state == Follow::Moving {
            t += 100;
            state = f.tick(t, &mut m, &flat).1;
        }
        assert_eq!(state, Follow::Arrived);
        assert!(t < 7_000, "40 yd at 7 yd/s takes ~6 s, took {t}");
        assert!(!m.is_moving());
    }

    #[test]
    fn stuck_sidesteps_then_backtracks_then_gives_up() {
        // A mover whose position the "server" keeps snapping back: no progress at all.
        let mut m = Mover::new([0.0, 0.0, 0.0], 0.0, 7.0);
        let goal = [100.0, 0.0, 0.0];
        let mut f = PathFollower::new(goal, vec![goal], 2.0, 0);
        let mut recs = vec![];
        let mut t = 0;
        let mut state = Follow::Moving;
        while t < 60_000 && state == Follow::Moving {
            t += 100;
            let (_, s) = f.tick(t, &mut m, &flat);
            state = s;
            if let Some(r) = f.last_recovery.take() {
                recs.push((t, r));
            }
            // Snap back (a wall the server enforces, or a teleport loop).
            m.set_pos([0.0, 0.0, 0.0], m.orientation);
        }
        assert!(matches!(state, Follow::GaveUp(_)), "{state:?}");
        assert_eq!(recs.len(), 3);
        assert!(matches!(recs[0].1, Recovery::Sidestep(_)));
        assert!(matches!(recs[1].1, Recovery::Backtrack(_)));
        assert!(matches!(recs[2].1, Recovery::Sidestep(_)));
        assert!(recs[0].0 >= 5_000, "first recovery after the 5 s window");
    }

    #[test]
    fn straight_line_navigator() {
        let mut n = StraightLine;
        assert_eq!(
            n.route([0.0; 3], [1.0, 2.0, 3.0]).unwrap(),
            vec![[1.0, 2.0, 3.0]]
        );
    }
}
