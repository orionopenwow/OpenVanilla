//! The run log: one JSON object per line (JSONL), every decision and outcome with the time, route
//! step, action, result, position, level and XP, plus a snapshot every 30 s and a summary at the
//! end. The summary has the same shape as `tools/autopilot/out/predictions.json`
//! (`minutes_per_level`, `level_reached_min`, `xp_per_min_by_band`, `quests` with `taken_min`,
//! `rewarded_min`, `minutes`) so a run can be compared with the plan and with the botlab report
//! (median minutes per level, XP/min by class and band 1-4/5-8/9-12, per-quest minutes).

use std::collections::BTreeMap;
use std::io::Write;

use serde::Serialize;
use serde_json::{json, Value};

pub const BANDS: [(u32, u32); 3] = [(1, 4), (5, 8), (9, 12)];

/// What the log line describes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    Start,
    Decision,
    Outcome,
    Snapshot,
    Summary,
}

/// The state stamped on every line.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Stamp {
    pub now_ms: u64,
    pub pos: [f32; 3],
    pub level: u32,
    pub xp: u32,
    pub hp: u32,
    pub max_hp: u32,
    pub mana: u32,
}

#[derive(Debug, Clone, Default)]
struct QuestTimes {
    title: String,
    taken_ms: Option<u64>,
    rewarded_ms: Option<u64>,
}

/// Accumulates the run and writes JSONL lines to `out` (a file, or a Vec in tests).
pub struct RunLog {
    out: Box<dyn Write + Send>,
    pub lines: u64,
    last_action: String,
    last_snapshot_ms: u64,
    // progress tracking
    start_level: Option<u32>,
    level_reached_ms: BTreeMap<u32, u64>,
    last_level_xp: Option<(u32, u32, u32)>, // (level, xp, next_level_xp)
    xp_by_level: BTreeMap<u32, u64>,
    pub xp_gained: u64,
    quests: BTreeMap<u32, QuestTimes>,
    pub kills: u32,
    pub deaths: u32,
    pub stuck: u32,
    pub steps_done: u32,
    pub steps_skipped: u32,
    pub steps_failed: u32,
    pub loot_corpses: u32,
    pub loot_items: u32,
    pub loot_money: u32,
    pub last_step: Option<usize>,
}

fn r1(x: f64) -> f64 {
    (x * 100.0).round() / 100.0
}

impl RunLog {
    pub fn new(out: Box<dyn Write + Send>) -> RunLog {
        RunLog {
            out,
            lines: 0,
            last_action: String::new(),
            last_snapshot_ms: 0,
            start_level: None,
            level_reached_ms: BTreeMap::new(),
            last_level_xp: None,
            xp_by_level: BTreeMap::new(),
            xp_gained: 0,
            quests: BTreeMap::new(),
            kills: 0,
            deaths: 0,
            stuck: 0,
            steps_done: 0,
            steps_skipped: 0,
            steps_failed: 0,
            loot_corpses: 0,
            loot_items: 0,
            loot_money: 0,
            last_step: None,
        }
    }

    pub fn write(
        &mut self,
        kind: Kind,
        s: &Stamp,
        step: Option<(usize, &str)>,
        action: &str,
        result: &str,
        extra: Value,
    ) {
        let mut v = json!({
            "t": r1(s.now_ms as f64 / 1000.0),
            "min": r1(s.now_ms as f64 / 60000.0),
            "event": kind,
            "step": step.map(|x| x.0),
            "step_kind": step.map(|x| x.1),
            "action": action,
            "result": result,
            "pos": [r1(s.pos[0] as f64), r1(s.pos[1] as f64), r1(s.pos[2] as f64)],
            "level": s.level,
            "xp": s.xp,
            "hp": s.hp,
            "max_hp": s.max_hp,
            "mana": s.mana,
        });
        if let (Value::Object(m), Value::Object(e)) = (&mut v, extra) {
            m.extend(e);
        }
        let _ = writeln!(self.out, "{v}");
        self.lines += 1;
    }

    /// A decision; repeated identical decisions are written once.
    pub fn decision(&mut self, s: &Stamp, step: Option<(usize, &str)>, action: &str) {
        if action == self.last_action {
            return;
        }
        self.last_action = action.to_string();
        self.write(Kind::Decision, s, step, action, "", Value::Null);
    }

    pub fn outcome(&mut self, s: &Stamp, step: Option<(usize, &str)>, action: &str, result: &str) {
        self.last_action.clear();
        self.write(Kind::Outcome, s, step, action, result, Value::Null);
    }

    /// Feed our level/XP every tick: tracks level-up times and XP gained per level.
    pub fn progress(&mut self, s: &Stamp, next_level_xp: u32) {
        if s.level == 0 {
            return;
        }
        if self.start_level.is_none() {
            self.start_level = Some(s.level);
            self.level_reached_ms.insert(s.level, s.now_ms);
        }
        if let Some((lvl, xp, need)) = self.last_level_xp {
            let gain = if s.level == lvl {
                u64::from(s.xp.saturating_sub(xp))
            } else if s.level == lvl + 1 {
                u64::from(need.saturating_sub(xp)) + u64::from(s.xp)
            } else {
                0
            };
            if gain > 0 {
                self.xp_gained += gain;
                *self.xp_by_level.entry(lvl).or_default() += gain;
            }
            if s.level > lvl {
                self.level_reached_ms.entry(s.level).or_insert(s.now_ms);
            }
        }
        self.last_level_xp = Some((s.level, s.xp, next_level_xp));
        if s.now_ms >= self.last_snapshot_ms + 30_000 {
            self.last_snapshot_ms = s.now_ms;
            self.write(Kind::Snapshot, s, None, "", "", Value::Null);
        }
    }

    pub fn quest_taken(&mut self, quest: u32, title: &str, now_ms: u64) {
        let q = self.quests.entry(quest).or_default();
        q.taken_ms.get_or_insert(now_ms);
        if q.title.is_empty() {
            q.title = title.to_string();
        }
    }

    pub fn quest_rewarded(&mut self, quest: u32, now_ms: u64) {
        self.quests
            .entry(quest)
            .or_default()
            .rewarded_ms
            .get_or_insert(now_ms);
    }

    pub fn rewarded(&self, quest: u32) -> bool {
        self.quests
            .get(&quest)
            .is_some_and(|q| q.rewarded_ms.is_some())
    }

    /// The summary object (also written as the last line by [`Self::finish`]).
    pub fn summary(
        &self,
        end_ms: u64,
        end_reason: &str,
        predicted_mpl: &BTreeMap<u32, f32>,
        predicted_quests: &BTreeMap<u32, f32>,
        steps_total: usize,
    ) -> Value {
        let min = |ms: u64| r1(ms as f64 / 60000.0);
        let reached: BTreeMap<String, f64> = self
            .level_reached_ms
            .iter()
            .map(|(l, t)| (l.to_string(), min(*t)))
            .collect();
        // Minutes per level: level-up to level-up, complete levels only (like levels.csv). The
        // starting level counts from the start of the run, as predict.py counts from minute 0.
        let mut mpl = BTreeMap::new();
        for (l, t) in &self.level_reached_ms {
            if let Some(t2) = self.level_reached_ms.get(&(l + 1)) {
                mpl.insert(*l, r1((t2 - t) as f64 / 60000.0));
            }
        }
        // Minutes spent at each level (the last one up to the end) for XP/min.
        let mut mins_at: BTreeMap<u32, f64> = BTreeMap::new();
        let levels: Vec<(u32, u64)> = self
            .level_reached_ms
            .iter()
            .map(|(a, b)| (*a, *b))
            .collect();
        for (i, (l, t)) in levels.iter().enumerate() {
            let t2 = levels.get(i + 1).map(|x| x.1).unwrap_or(end_ms);
            mins_at.insert(*l, (t2.saturating_sub(*t)) as f64 / 60000.0);
        }
        let mut bands = serde_json::Map::new();
        for (lo, hi) in BANDS {
            let m: f64 = (lo..=hi).filter_map(|l| mins_at.get(&l)).sum();
            let x: u64 = (lo..=hi).filter_map(|l| self.xp_by_level.get(&l)).sum();
            bands.insert(
                format!("{lo}-{hi}"),
                if m > 0.0 {
                    json!(r1(x as f64 / m))
                } else {
                    Value::Null
                },
            );
        }
        let mut quests = serde_json::Map::new();
        for (q, v) in &self.quests {
            let minutes = match (v.taken_ms, v.rewarded_ms) {
                (Some(a), Some(b)) => json!(r1(b.saturating_sub(a) as f64 / 60000.0)),
                _ => Value::Null,
            };
            quests.insert(
                q.to_string(),
                json!({
                    "title": v.title,
                    "taken_min": v.taken_ms.map(min),
                    "rewarded_min": v.rewarded_ms.map(min),
                    "minutes": minutes,
                    "predicted_minutes": predicted_quests.get(q),
                }),
            );
        }
        let vs_levels: BTreeMap<String, Value> = mpl
            .iter()
            .map(|(l, a)| {
                let p = predicted_mpl.get(l).copied();
                (
                    l.to_string(),
                    json!({"actual": a, "predicted": p, "ratio": p.filter(|p| *p > 0.0).map(|p| r1(*a / f64::from(p)))}),
                )
            })
            .collect();
        let total_min = end_ms as f64 / 60000.0;
        json!({
            "end_reason": end_reason,
            "minutes": r1(total_min),
            "level_start": self.start_level,
            "level_end": self.last_level_xp.map(|x| x.0),
            "xp_gained": self.xp_gained,
            "xp_per_min": if total_min > 0.0 { json!(r1(self.xp_gained as f64 / total_min)) } else { Value::Null },
            "minutes_per_level": mpl.iter().map(|(l, m)| (l.to_string(), json!(m))).collect::<serde_json::Map<_, _>>(),
            "level_reached_min": reached,
            "xp_per_min_by_band": bands,
            "quests": quests,
            "quests_rewarded": self.quests.values().filter(|q| q.rewarded_ms.is_some()).count(),
            "steps": {"total": steps_total, "done": self.steps_done, "skipped": self.steps_skipped,
                      "failed": self.steps_failed, "last_index": self.last_step},
            "kills": self.kills,
            "deaths": self.deaths,
            "stuck_events": self.stuck,
            "loot": {"corpses": self.loot_corpses, "items": self.loot_items, "money_copper": self.loot_money},
            "vs_route": {"minutes_per_level": vs_levels},
        })
    }

    pub fn finish(&mut self, s: &Stamp, summary: &Value) {
        self.write(
            Kind::Summary,
            s,
            None,
            "end",
            summary["end_reason"].as_str().unwrap_or(""),
            json!({"summary": summary}),
        );
        let _ = self.out.flush();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    #[derive(Clone, Default)]
    pub struct Shared(pub Arc<Mutex<Vec<u8>>>);
    impl Write for Shared {
        fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(b);
            Ok(b.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    fn st(ms: u64, level: u32, xp: u32) -> Stamp {
        Stamp {
            now_ms: ms,
            level,
            xp,
            ..Default::default()
        }
    }

    #[test]
    fn levels_bands_quests_and_dedup() {
        let buf = Shared::default();
        let mut log = RunLog::new(Box::new(buf.clone()));
        log.progress(&st(0, 1, 0), 400);
        log.decision(&st(0, 1, 0), Some((0, "accept")), "talk to 197");
        log.decision(&st(100, 1, 0), Some((0, "accept")), "talk to 197");
        log.quest_taken(7, "Kobold Camp Cleanup", 6_000);
        log.progress(&st(60_000, 1, 300), 400);
        log.progress(&st(120_000, 2, 100), 900); // 100 to finish L1 + 100 into L2
        log.quest_rewarded(7, 126_000);
        log.progress(&st(240_000, 2, 700), 900);
        log.progress(&st(300_000, 3, 0), 1400);
        let mut pm = BTreeMap::new();
        pm.insert(1u32, 3.69f32);
        let mut pq = BTreeMap::new();
        pq.insert(7u32, 4.77f32);
        let s = log.summary(360_000, "time limit", &pm, &pq, 10);
        assert_eq!(s["minutes_per_level"]["1"], json!(2.0));
        assert_eq!(s["minutes_per_level"]["2"], json!(3.0));
        assert_eq!(s["level_reached_min"]["3"], json!(5.0));
        assert_eq!(s["xp_gained"], json!(400 + 900));
        // L1-4 band: 1300 XP in 6 minutes.
        assert_eq!(s["xp_per_min_by_band"]["1-4"], json!(r1(1300.0 / 6.0)));
        assert_eq!(s["xp_per_min_by_band"]["5-8"], Value::Null);
        assert_eq!(s["quests"]["7"]["minutes"], json!(2.0));
        assert_eq!(s["quests"]["7"]["predicted_minutes"], json!(4.77f32));
        assert_eq!(
            s["vs_route"]["minutes_per_level"]["1"]["predicted"],
            json!(3.69f32)
        );
        log.finish(&st(360_000, 3, 0), &s);
        let text = String::from_utf8(buf.0.lock().unwrap().clone()).unwrap();
        let lines: Vec<Value> = text
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect();
        assert_eq!(
            lines.iter().filter(|l| l["event"] == "decision").count(),
            1,
            "identical decisions collapse"
        );
        assert!(lines.iter().any(|l| l["event"] == "snapshot"));
        let last = lines.last().unwrap();
        assert_eq!(last["event"], "summary");
        assert_eq!(last["summary"]["quests_rewarded"], json!(1));
        for l in &lines {
            for k in ["t", "min", "action", "result", "pos", "level", "xp"] {
                assert!(l.get(k).is_some(), "{k} missing in {l}");
            }
        }
    }
}
