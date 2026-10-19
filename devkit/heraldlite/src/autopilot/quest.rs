//! The route from `tools/autopilot/planner.py` (`out/route_elwynn.json`) as executable steps, and
//! the quest-giver conversation for accepting and turning in one quest.
//!
//! Route steps carry `kind`, `pos` ([x, y], no z), `desc`, `quest` (accept/turnin/objects/
//! explore/tame), `entry`+`kills` (kill/grind), and the planner's timing (`start_min`, `end_min`,
//! `level`, `xp`). The planner does not name NPCs, so the executor uses the nearest quest giver to
//! `pos`; optional extra fields the planner may add later are honoured: `npc` (creature entry of
//! the giver/ender), `go_entry` (objects), `trigger` (explore: an AreaTrigger.dbc id).
//!
//! Conversation (CMaNGOS classic `QuestHandler.cpp`, `GossipDef.cpp`):
//! - accept: `CMSG_QUESTGIVER_HELLO` -> gossip / `SMSG_QUESTGIVER_QUEST_LIST` (then
//!   `CMSG_QUESTGIVER_QUERY_QUEST`) or straight `SMSG_QUESTGIVER_QUEST_DETAILS` ->
//!   `CMSG_QUESTGIVER_ACCEPT_QUEST` -> the quest appears in `PLAYER_QUEST_LOG_*`.
//! - turn in: `CMSG_QUESTGIVER_HELLO` -> list (then `CMSG_QUESTGIVER_COMPLETE_QUEST`) or
//!   `SMSG_QUESTGIVER_REQUEST_ITEMS` (complete: `CMSG_QUESTGIVER_REQUEST_REWARD`) ->
//!   `SMSG_QUESTGIVER_OFFER_REWARD` -> `CMSG_QUESTGIVER_CHOOSE_REWARD` ->
//!   `SMSG_QUESTGIVER_QUEST_COMPLETE`.

use anyhow::{bail, Context, Result};
use serde::Deserialize;

use super::out::OutCmd;
use super::world::Dialog;

#[derive(Debug, Clone, PartialEq)]
pub enum StepKind {
    Travel,
    Accept {
        quest: u32,
    },
    TurnIn {
        quest: u32,
    },
    Kill {
        entry: u32,
        count: u32,
        quests: Vec<u32>,
    },
    Grind {
        entry: u32,
        count: u32,
    },
    Objects {
        quest: u32,
        go_entry: Option<u32>,
    },
    Explore {
        quest: u32,
        trigger: Option<u32>,
    },
    /// A step v1 cannot do (tame, pet, unknown kinds): skipped and logged.
    Unsupported(String),
}

#[derive(Debug, Clone, PartialEq)]
pub struct Step {
    pub index: usize,
    pub kind: StepKind,
    pub desc: String,
    pub pos: [f32; 2],
    pub npc: Option<u32>,
    /// The planner's prediction for this step.
    pub planned_start_min: f32,
    pub planned_end_min: f32,
    pub planned_level: u32,
}

impl Step {
    pub fn quest(&self) -> Option<u32> {
        match self.kind {
            StepKind::Accept { quest }
            | StepKind::TurnIn { quest }
            | StepKind::Objects { quest, .. }
            | StepKind::Explore { quest, .. } => Some(quest),
            StepKind::Kill { ref quests, .. } => quests.first().copied(),
            _ => None,
        }
    }
    pub fn kind_name(&self) -> &'static str {
        match self.kind {
            StepKind::Travel => "travel",
            StepKind::Accept { .. } => "accept",
            StepKind::TurnIn { .. } => "turnin",
            StepKind::Kill { .. } => "kill",
            StepKind::Grind { .. } => "grind",
            StepKind::Objects { .. } => "objects",
            StepKind::Explore { .. } => "explore",
            StepKind::Unsupported(_) => "unsupported",
        }
    }
    pub fn planned_minutes(&self) -> f32 {
        (self.planned_end_min - self.planned_start_min).max(0.0)
    }
}

#[derive(Debug, Deserialize)]
struct RawStep {
    kind: String,
    #[serde(default)]
    desc: String,
    pos: Vec<f32>,
    quest: Option<u32>,
    entry: Option<u32>,
    kills: Option<u32>,
    npc: Option<u32>,
    #[serde(default)]
    quests: Vec<u32>,
    go_entry: Option<u32>,
    trigger: Option<u32>,
    #[serde(default)]
    start_min: f32,
    #[serde(default)]
    end_min: f32,
    #[serde(default)]
    level: u32,
}

#[derive(Debug, Deserialize)]
struct RawRoute {
    steps: Vec<RawStep>,
    #[serde(default)]
    minutes_per_level: std::collections::BTreeMap<String, f32>,
    #[serde(default)]
    quest_minutes: std::collections::BTreeMap<String, f32>,
}

/// A parsed route plus the planner's predictions (for the end-of-run comparison).
#[derive(Debug, Clone, Default)]
pub struct Route {
    pub steps: Vec<Step>,
    pub predicted_minutes_per_level: std::collections::BTreeMap<u32, f32>,
    pub predicted_quest_minutes: std::collections::BTreeMap<u32, f32>,
}

/// "quest 7: 10 x Kobold Vermin" -> [7]; "quest 47,60: 20 x Kobold Tunneler" -> [47, 60].
fn quests_from_desc(desc: &str) -> Vec<u32> {
    let Some(rest) = desc.strip_prefix("quest ") else {
        return vec![];
    };
    let head = rest.split(':').next().unwrap_or("");
    head.split(',')
        .filter_map(|q| q.trim().parse().ok())
        .collect()
}

impl Route {
    pub fn parse(text: &str) -> Result<Route> {
        let raw: RawRoute = serde_json::from_str(text).context("route JSON")?;
        let mut steps = Vec::with_capacity(raw.steps.len());
        for (index, s) in raw.steps.into_iter().enumerate() {
            if s.pos.len() < 2 {
                bail!("step {index}: pos needs [x, y]");
            }
            let need_quest = || {
                s.quest
                    .with_context(|| format!("step {index} ({}): no quest id", s.kind))
            };
            let kind = match s.kind.as_str() {
                "travel" => StepKind::Travel,
                "accept" => StepKind::Accept {
                    quest: need_quest()?,
                },
                "turnin" => StepKind::TurnIn {
                    quest: need_quest()?,
                },
                "kill" => StepKind::Kill {
                    entry: s
                        .entry
                        .with_context(|| format!("step {index}: kill without entry"))?,
                    count: s.kills.unwrap_or(1),
                    quests: if !s.quests.is_empty() {
                        s.quests.clone()
                    } else if let Some(q) = s.quest {
                        vec![q]
                    } else {
                        quests_from_desc(&s.desc)
                    },
                },
                "grind" => StepKind::Grind {
                    entry: s
                        .entry
                        .with_context(|| format!("step {index}: grind without entry"))?,
                    count: s.kills.unwrap_or(1),
                },
                "objects" => StepKind::Objects {
                    quest: need_quest()?,
                    go_entry: s.go_entry,
                },
                "explore" => StepKind::Explore {
                    quest: need_quest()?,
                    trigger: s.trigger,
                },
                other => StepKind::Unsupported(other.to_string()),
            };
            steps.push(Step {
                index,
                kind,
                desc: s.desc,
                pos: [s.pos[0], s.pos[1]],
                npc: s.npc,
                planned_start_min: s.start_min,
                planned_end_min: s.end_min,
                planned_level: s.level,
            });
        }
        Ok(Route {
            steps,
            predicted_minutes_per_level: raw
                .minutes_per_level
                .into_iter()
                .filter_map(|(k, v)| k.parse().ok().map(|k| (k, v)))
                .collect(),
            predicted_quest_minutes: raw
                .quest_minutes
                .into_iter()
                .filter_map(|(k, v)| k.parse().ok().map(|k| (k, v)))
                .collect(),
        })
    }

    pub fn load(path: &std::path::Path) -> Result<Route> {
        let text = std::fs::read_to_string(path)
            .with_context(|| format!("reading route {}", path.display()))?;
        Route::parse(&text).with_context(|| format!("route {}", path.display()))
    }

    /// The steps up to (and including) the last one planned for `max_level`.
    pub fn up_to_level(mut self, max_level: u32) -> Route {
        if let Some(cut) = self.steps.iter().position(|s| s.planned_level > max_level) {
            self.steps.truncate(cut);
        }
        self
    }
}

// ── the conversation ─────────────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Goal {
    Accept,
    TurnIn,
}

#[derive(Debug, Clone, PartialEq)]
pub enum TalkResult {
    Pending,
    Done(String),
    Failed(String),
}

/// What the conversation can see each tick.
#[derive(Debug, Clone)]
pub struct TalkInput<'a> {
    pub now: u64,
    pub dialog: Option<&'a Dialog>,
    /// The quest is in our log (and whether it is complete).
    pub in_log: Option<bool>,
    /// `SMSG_QUESTGIVER_QUEST_COMPLETE` for this quest arrived.
    pub rewarded: bool,
    /// `SMSG_QUESTGIVER_QUEST_INVALID` / `_FAILED` / log full arrived.
    pub refused: Option<String>,
}

/// One accept or turn-in conversation with one NPC.
#[derive(Debug, Clone)]
pub struct Talk {
    pub npc: u64,
    pub quest: u32,
    pub goal: Goal,
    last_sent: Option<(u64, &'static str)>,
    hellos: u32,
    started: Option<u64>,
}

const STAGE_TIMEOUT_MS: u64 = 3_000;
const TALK_TIMEOUT_MS: u64 = 20_000;

impl Talk {
    pub fn new(npc: u64, quest: u32, goal: Goal) -> Talk {
        Talk {
            npc,
            quest,
            goal,
            last_sent: None,
            hellos: 0,
            started: None,
        }
    }

    fn send(&mut self, now: u64, what: &'static str, cmd: OutCmd, out: &mut Vec<OutCmd>) {
        self.last_sent = Some((now, what));
        out.push(cmd);
    }

    fn waiting_for(&self, now: u64, what: &str) -> bool {
        self.last_sent
            .is_some_and(|(t, w)| w == what && now < t + STAGE_TIMEOUT_MS)
    }

    pub fn tick(&mut self, inp: &TalkInput) -> (Vec<OutCmd>, TalkResult) {
        let now = inp.now;
        let started = *self.started.get_or_insert(now);
        let mut out = vec![];
        let (npc, q) = (self.npc, self.quest);
        // Finished?
        match self.goal {
            Goal::Accept if inp.in_log.is_some() => {
                return (out, TalkResult::Done(format!("quest {q} in the log")))
            }
            Goal::TurnIn if inp.rewarded => {
                return (out, TalkResult::Done(format!("quest {q} rewarded")))
            }
            _ => {}
        }
        if let Some(why) = &inp.refused {
            return (out, TalkResult::Failed(why.clone()));
        }
        if now >= started + TALK_TIMEOUT_MS {
            return (
                out,
                TalkResult::Failed(format!(
                    "no result after {} s (last sent: {})",
                    TALK_TIMEOUT_MS / 1000,
                    self.last_sent.map(|x| x.1).unwrap_or("nothing")
                )),
            );
        }
        match (self.goal, inp.dialog) {
            // Accept: the details panel for our quest -> accept.
            (Goal::Accept, Some(Dialog::Details(d))) if d.quest_id == q => {
                if !self.waiting_for(now, "accept") {
                    self.send(
                        now,
                        "accept",
                        OutCmd::QuestgiverAcceptQuest(npc, q),
                        &mut out,
                    );
                }
            }
            (Goal::Accept, Some(Dialog::QuestList(l)))
                if l.quests.iter().any(|e| e.quest_id == q) =>
            {
                if !self.waiting_for(now, "query") {
                    self.send(now, "query", OutCmd::QuestgiverQueryQuest(npc, q), &mut out);
                }
            }
            (Goal::Accept, Some(Dialog::Gossip { quests, .. }))
                if quests.iter().any(|e| e.0 == q) =>
            {
                if !self.waiting_for(now, "query") {
                    self.send(now, "query", OutCmd::QuestgiverQueryQuest(npc, q), &mut out);
                }
            }
            // Turn in: list -> complete; progress panel -> request reward; reward panel -> choose.
            (Goal::TurnIn, Some(Dialog::QuestList(l)))
                if l.quests.iter().any(|e| e.quest_id == q) =>
            {
                if !self.waiting_for(now, "complete") {
                    self.send(
                        now,
                        "complete",
                        OutCmd::QuestgiverCompleteQuest(npc, q),
                        &mut out,
                    );
                }
            }
            (Goal::TurnIn, Some(Dialog::Gossip { quests, .. }))
                if quests.iter().any(|e| e.0 == q) =>
            {
                if !self.waiting_for(now, "complete") {
                    self.send(
                        now,
                        "complete",
                        OutCmd::QuestgiverCompleteQuest(npc, q),
                        &mut out,
                    );
                }
            }
            (Goal::TurnIn, Some(Dialog::RequestItems(r))) if r.quest_id == q => {
                if !r.is_complete {
                    return (
                        out,
                        TalkResult::Failed(format!("quest {q}: the ender says it is not complete")),
                    );
                }
                if !self.waiting_for(now, "request_reward") {
                    self.send(
                        now,
                        "request_reward",
                        OutCmd::QuestgiverRequestReward(npc, q),
                        &mut out,
                    );
                }
            }
            (Goal::TurnIn, Some(Dialog::OfferReward(o))) if o.quest_id == q => {
                if !self.waiting_for(now, "choose") {
                    // v1 takes the first choice (index 0, also valid with no choice).
                    self.send(
                        now,
                        "choose",
                        OutCmd::QuestgiverChooseReward(npc, q, 0),
                        &mut out,
                    );
                }
            }
            // Nothing useful open (or another quest's panel): say hello, then try the direct verb.
            _ => {
                let busy = self
                    .last_sent
                    .is_some_and(|(t, _)| now < t + STAGE_TIMEOUT_MS);
                if !busy {
                    if self.hellos < 2 {
                        self.hellos += 1;
                        self.send(now, "hello", OutCmd::QuestgiverHello(npc), &mut out);
                    } else {
                        // The giver did not show our quest: ask for it directly (the server
                        // checks it is involved, CMaNGOS HandleQuestgiver*Opcode).
                        let cmd = match self.goal {
                            Goal::Accept => OutCmd::QuestgiverQueryQuest(npc, q),
                            Goal::TurnIn => OutCmd::QuestgiverCompleteQuest(npc, q),
                        };
                        self.send(now, "direct", cmd, &mut out);
                    }
                }
            }
        }
        (out, TalkResult::Pending)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use benilla_protocol::messages::{
        QuestDetails, QuestGiverList, QuestListEntry, QuestOfferReward, QuestRequestItems,
    };

    fn input(now: u64, dialog: Option<&Dialog>) -> TalkInput<'_> {
        TalkInput {
            now,
            dialog,
            in_log: None,
            rewarded: false,
            refused: None,
        }
    }

    fn details(q: u32) -> Dialog {
        Dialog::Details(QuestDetails {
            npc: 9,
            quest_id: q,
            title: "t".into(),
            details: String::new(),
            objectives: String::new(),
            auto_finish: 0,
            choices: vec![],
            rewards: vec![],
            money: 0,
            reward_spell: 0,
        })
    }

    #[test]
    fn accept_through_a_quest_list() {
        let mut t = Talk::new(9, 7, Goal::Accept);
        let (v, r) = t.tick(&input(0, None));
        assert_eq!(v, vec![OutCmd::QuestgiverHello(9)]);
        assert_eq!(r, TalkResult::Pending);
        let list = Dialog::QuestList(QuestGiverList {
            npc: 9,
            greeting: String::new(),
            emote_delay: 0,
            emote: 0,
            quests: vec![
                QuestListEntry {
                    quest_id: 783,
                    icon: 4,
                    level: 1,
                    title: "a".into(),
                },
                QuestListEntry {
                    quest_id: 7,
                    icon: 5,
                    level: 2,
                    title: "b".into(),
                },
            ],
        });
        let (v, _) = t.tick(&input(300, Some(&list)));
        assert_eq!(v, vec![OutCmd::QuestgiverQueryQuest(9, 7)]);
        let d = details(7);
        let (v, _) = t.tick(&input(600, Some(&d)));
        assert_eq!(v, vec![OutCmd::QuestgiverAcceptQuest(9, 7)]);
        let (v, _) = t.tick(&input(700, Some(&d)));
        assert!(v.is_empty(), "no double accept while waiting");
        let mut i = input(900, None);
        i.in_log = Some(false);
        assert!(matches!(t.tick(&i).1, TalkResult::Done(_)));
    }

    #[test]
    fn details_for_another_quest_does_not_accept_it() {
        let mut t = Talk::new(9, 7, Goal::Accept);
        t.tick(&input(0, None));
        let d = details(33);
        let (v, _) = t.tick(&input(100, Some(&d)));
        assert!(v.is_empty());
        // After the stage timeout: hello again, then the direct query.
        let (v, _) = t.tick(&input(3_100, Some(&d)));
        assert_eq!(v, vec![OutCmd::QuestgiverHello(9)]);
        let (v, _) = t.tick(&input(6_200, Some(&d)));
        assert_eq!(v, vec![OutCmd::QuestgiverQueryQuest(9, 7)]);
    }

    #[test]
    fn turn_in_progress_then_reward() {
        let mut t = Talk::new(9, 7, Goal::TurnIn);
        t.tick(&input(0, None));
        let ri = Dialog::RequestItems(QuestRequestItems {
            npc: 9,
            quest_id: 7,
            title: String::new(),
            request_text: String::new(),
            emote: 0,
            close_on_cancel: 1,
            required_money: 0,
            required_items: vec![],
            is_complete: true,
        });
        let (v, _) = t.tick(&input(100, Some(&ri)));
        assert_eq!(v, vec![OutCmd::QuestgiverRequestReward(9, 7)]);
        let or = Dialog::OfferReward(QuestOfferReward {
            npc: 9,
            quest_id: 7,
            title: String::new(),
            offer_text: String::new(),
            auto_finish: 1,
            choices: vec![],
            rewards: vec![],
            money: 25,
            quest_flags: 0,
            reward_spell: 0,
        });
        let (v, _) = t.tick(&input(200, Some(&or)));
        assert_eq!(v, vec![OutCmd::QuestgiverChooseReward(9, 7, 0)]);
        let mut i = input(300, None);
        i.rewarded = true;
        assert!(matches!(t.tick(&i).1, TalkResult::Done(_)));
    }

    #[test]
    fn incomplete_turn_in_and_refusals_fail() {
        let mut t = Talk::new(9, 7, Goal::TurnIn);
        let ri = Dialog::RequestItems(QuestRequestItems {
            npc: 9,
            quest_id: 7,
            title: String::new(),
            request_text: String::new(),
            emote: 0,
            close_on_cancel: 1,
            required_money: 0,
            required_items: vec![],
            is_complete: false,
        });
        assert!(matches!(
            t.tick(&input(0, Some(&ri))).1,
            TalkResult::Failed(_)
        ));
        let mut t = Talk::new(9, 7, Goal::Accept);
        let mut i = input(0, None);
        i.refused = Some("quest invalid (reason 5)".into());
        assert!(matches!(t.tick(&i).1, TalkResult::Failed(_)));
        let mut t = Talk::new(9, 7, Goal::Accept);
        t.tick(&input(0, None));
        assert!(matches!(
            t.tick(&input(20_000, None)).1,
            TalkResult::Failed(_)
        ));
    }

    /// The real planner output (enriched by route_enrich.py), committed as a fixture.
    #[test]
    fn the_real_elwynn_route_parses_and_levels_1_to_5_are_playable() {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/fixtures/route_elwynn_enriched.json"
        );
        let r = Route::load(std::path::Path::new(path)).unwrap();
        assert!(r.steps.len() > 100);
        assert!(r.predicted_minutes_per_level.contains_key(&1));
        let l5 = r.up_to_level(5);
        assert!(l5.steps.len() >= 40, "{}", l5.steps.len());
        for s in &l5.steps {
            assert!(
                !matches!(s.kind, StepKind::Unsupported(_)),
                "step {} {:?}",
                s.index,
                s.kind
            );
            if matches!(s.kind, StepKind::Accept { .. } | StepKind::TurnIn { .. }) {
                assert!(s.npc.is_some(), "step {} has no npc", s.index);
            }
        }
        assert_eq!(l5.steps[0].kind, StepKind::Accept { quest: 783 });
        assert_eq!(l5.steps[0].npc, Some(823), "Deputy Willem");
        assert!(l5.steps.iter().any(|s| s.kind
            == StepKind::Objects {
                quest: 3904,
                go_entry: Some(161557)
            }));
        assert!(l5.steps.iter().any(|s| s.kind
            == StepKind::Explore {
                quest: 62,
                trigger: Some(88)
            }));
    }

    #[test]
    fn route_parses_the_planner_shape() {
        let text = r#"{"minutes_per_level": {"1": 3.69}, "quest_minutes": {"7": 4.77},
          "steps": [
            {"desc": "accept 783 A Threat Within", "end_min": 0.08, "kind": "accept", "level": 1, "pos": [-8950.0, -132.5], "quest": 783, "start_min": 0.0, "xp": 0, "xp_into_level": 0},
            {"desc": "to Marshal McBride (783)", "end_min": 0.26, "kind": "travel", "level": 1, "pos": [-8902.6, -162.6], "start_min": 0.08, "xp": 0, "xp_into_level": 0},
            {"desc": "quest 7: 10 x Kobold Vermin", "end_min": 4.75, "entry": 6, "kills": 10, "kind": "kill", "level": 2, "pos": [-8779.0, -173.8], "seconds": 215, "start_min": 1.15, "xp": 506, "xp_into_level": 166},
            {"desc": "grind: 34 x Kobold Miner", "end_min": 92.83, "entry": 40, "kills": 34, "kind": "grind", "level": 8, "pos": [-9781.6, 118.2], "seconds": 939, "start_min": 77.17, "xp": 2448, "xp_into_level": 54},
            {"desc": "tame a pet (Tame Beast learned)", "end_min": 182.52, "kind": "pet", "level": 10, "pos": [-9462.6, 70.9], "start_min": 181.52, "xp": 0, "xp_into_level": 4952}
          ]}"#;
        let r = Route::parse(text).unwrap();
        assert_eq!(r.steps.len(), 5);
        assert_eq!(r.steps[0].kind, StepKind::Accept { quest: 783 });
        assert_eq!(
            r.steps[2].kind,
            StepKind::Kill {
                entry: 6,
                count: 10,
                quests: vec![7]
            }
        );
        assert_eq!(
            quests_from_desc("quest 47,60: 20 x Kobold Tunneler"),
            vec![47, 60]
        );
        assert!(quests_from_desc("grind: 34 x Kobold Miner").is_empty());
        assert_eq!(r.steps[4].kind, StepKind::Unsupported("pet".into()));
        assert_eq!(r.predicted_minutes_per_level[&1], 3.69);
        assert_eq!(r.predicted_quest_minutes[&7], 4.77);
        let cut = r.up_to_level(5);
        assert_eq!(cut.steps.len(), 3, "the L8 grind and later are cut");
        assert!(Route::parse(r#"{"steps":[{"kind":"accept","pos":[1,2]}]}"#).is_err());
    }
}
