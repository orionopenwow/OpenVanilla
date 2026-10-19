//! Behaviour Studio: what the pack's creatures do, without the number columns.
//!
//! * **Cards** (When → If → Do) compile to CMaNGOS EventAI rows (`creature_ai_scripts`, the
//!   creature's `AIName = 'EventAI'`), and the lines they say to `custom_texts` (negative entries
//!   from the pack's own range). Event IDs are `entry × 100 + n`, the convention the database uses.
//! * **Paths**: a spawn walks a route of points (`creature_movement`, the spawn's
//!   `MovementType = 2`), waiting where asked.
//! * **Dialogue**: pages of gossip with options that lead to other pages, close the window, or open
//!   the creature's shop or training (`npc_text`, `gossip_menu`, `gossip_menu_option`, the
//!   creature's `GossipMenuId` and gossip flag).
//!
//! Every row is tagged (`behaviour:<entry>`, `path:<guid>`, `dialogue:<entry>`), so saving again
//! replaces them, and the form's own JSON is kept in `behaviour/` to reopen it.

use crate::data::{self, save_rows};
use crate::project::Project;
use crate::wizards::{add_npc_flag, int, put, row, take_id, text, NPC_GOSSIP};
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use toml::Value;

// ------------------------------------------------------------------ cards

/// When a card fires.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum When {
    /// In combat: first after `first` seconds (a range), then every `every` seconds (0: once).
    CombatTimer { first: [f64; 2], #[serde(default)] every: [f64; 2] },
    /// Out of combat, the same way.
    IdleTimer { first: [f64; 2], #[serde(default)] every: [f64; 2] },
    /// Its health drops to `below` percent (once, unless `every` is set).
    HealthBelow { below: i64, #[serde(default)] every: [f64; 2] },
    ManaBelow { below: i64, #[serde(default)] every: [f64; 2] },
    /// Its target's health drops to `below` percent.
    TargetHealthBelow { below: i64, #[serde(default)] every: [f64; 2] },
    /// Combat starts.
    Aggro,
    /// It kills someone.
    Kill,
    /// It dies.
    Death,
    /// It gives up and goes home.
    Evade,
    /// It's hit by a spell (`spell` 0: any).
    SpellHit { #[serde(default)] spell: i64 },
    /// A target comes within `max` yards (in combat).
    InRange { #[serde(default)] min: i64, max: i64, #[serde(default)] every: [f64; 2] },
    /// A player comes within `max` yards while it's idle and can see them.
    PlayerNear { max: i64, #[serde(default)] every: [f64; 2] },
    /// It appears (spawns or respawns).
    Spawned,
    /// It's back home after a fight.
    ReachedHome,
    /// A friend nearby (within `radius`) is missing `deficit` health or more.
    FriendHurt { deficit: i64, radius: i64, #[serde(default)] every: [f64; 2] },
}

/// What a card does (up to three).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Do {
    /// Say, yell or emote a line (`style`: say, yell, emote).
    Say { text: String, #[serde(default)] style: String },
    /// Cast a spell at a target (`target`: self, victim, random, random_player, invoker).
    Cast { spell: i64, #[serde(default)] target: String, #[serde(default)] interrupt: bool, #[serde(default)] triggered: bool },
    /// Summon a creature for `seconds` (0: until it dies).
    Summon { entry: i64, #[serde(default)] seconds: i64 },
    /// Go to phase `phase` (0–31; cards can be limited to a phase).
    Phase { phase: i64 },
    Emote { emote: i64 },
    Sound { sound: i64 },
    /// Run to friends for help.
    Flee,
    /// Call friends within `radius` yards into the fight.
    CallForHelp { radius: i64 },
    /// Change look (a CreatureDisplayInfo; 0: back to normal).
    Morph { display: i64 },
    /// Disappear after `ms` milliseconds.
    Despawn { #[serde(default)] ms: i64 },
    /// Count as a kill of `entry` for the player's quests.
    QuestCredit { entry: i64 },
    /// Stop moving in combat (a caster that stands and casts), or move again.
    Stand { still: bool },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Card {
    pub when: When,
    /// Up to three things, in order.
    #[serde(rename = "do")]
    pub actions: Vec<Do>,
    /// Percent chance it fires (default 100).
    #[serde(default = "hundred")]
    pub chance: i64,
    /// Only in this phase (none: any).
    #[serde(default)]
    pub phase: Option<i64>,
    #[serde(default)]
    pub note: String,
}
fn hundred() -> i64 {
    100
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Behaviour {
    pub entry: i64,
    pub cards: Vec<Card>,
}

fn target(t: &str) -> Result<i64> {
    Ok(match t {
        "" | "victim" => 1,
        "self" => 0,
        "second" => 2,
        "random" => 4,
        "random_not_top" => 5,
        "invoker" => 6,
        "random_player" => 8,
        "farthest" => 18,
        other => bail!("unknown target {other:?} (self, victim, random, random_player, invoker, farthest)"),
    })
}

fn ms(s: f64) -> i64 {
    (s.max(0.0) * 1000.0).round() as i64
}

/// One card's event: (type, params, repeatable).
fn event(w: &When) -> Result<(i64, [i64; 6], bool)> {
    let rep = |e: &[f64; 2]| -> ([i64; 2], bool) { ([ms(e[0]), ms(e[1].max(e[0]))], e[1] > 0.0 || e[0] > 0.0) };
    let pct = |b: i64| -> Result<i64> {
        if !(1..=99).contains(&b) {
            bail!("a health or mana card needs a percent from 1 to 99");
        }
        Ok(b)
    };
    Ok(match w {
        When::CombatTimer { first, every } | When::IdleTimer { first, every } => {
            let t = if matches!(w, When::CombatTimer { .. }) { 0 } else { 1 };
            let (r, repeat) = rep(every);
            (t, [ms(first[0]), ms(first[1].max(first[0])), r[0], r[1], 0, 0], repeat)
        }
        When::HealthBelow { below, every } | When::ManaBelow { below, every } | When::TargetHealthBelow { below, every } => {
            let t = match w {
                When::HealthBelow { .. } => 2,
                When::ManaBelow { .. } => 3,
                _ => 12,
            };
            let (r, repeat) = rep(every);
            (t, [pct(*below)?, 0, r[0], r[1], 0, 0], repeat)
        }
        When::Aggro => (4, [0; 6], false),
        When::Kill => (5, [0; 6], true),
        When::Death => (6, [0; 6], false),
        When::Evade => (7, [0; 6], true),
        When::SpellHit { spell } => (8, [*spell, -1, 0, 0, 0, 0], true),
        When::InRange { min, max, every } => {
            let (r, _) = rep(every);
            (9, [*min, *max, r[0], r[1], 0, 0], true)
        }
        When::PlayerNear { max, every } => {
            let (r, _) = rep(every);
            // hostile or not (1: not only hostiles), range, repeat, players only
            (10, [1, *max, r[0].max(1000), r[1].max(1000), 1, 0], true)
        }
        When::Spawned => (11, [0; 6], false),
        When::ReachedHome => (21, [0; 6], true),
        When::FriendHurt { deficit, radius, every } => {
            let (r, _) = rep(every);
            (14, [*deficit, *radius, r[0].max(1000), r[1].max(1000), 0, 0], true)
        }
    })
}

/// One action: (type, params), and a line to write to custom_texts when it says something.
fn action(a: &Do, line_id: &mut dyn FnMut(&str, i64) -> Result<i64>) -> Result<(i64, [i64; 3])> {
    Ok(match a {
        Do::Say { text, style } => {
            if text.trim().is_empty() {
                bail!("a Say needs its line");
            }
            let kind = match style.as_str() {
                "" | "say" => 0,
                "yell" => 1,
                "emote" => 2,
                other => bail!("unknown style {other:?} (say, yell, emote)"),
            };
            (1, [line_id(text, kind)?, 0, 0])
        }
        Do::Cast { spell, target: t, interrupt, triggered } => {
            if *spell <= 0 {
                bail!("a Cast needs a spell");
            }
            (11, [*spell, target(t)?, (*interrupt as i64) | ((*triggered as i64) << 1)])
        }
        Do::Summon { entry, seconds } => (12, [*entry, 0, seconds.max(&0) * 1000]),
        Do::Phase { phase } => {
            if !(0..=31).contains(phase) {
                bail!("phases go from 0 to 31");
            }
            (22, [*phase, 0, 0])
        }
        Do::Emote { emote } => (5, [*emote, 0, 0]),
        Do::Sound { sound } => (4, [*sound, 0, 0]),
        Do::Flee => (25, [0, 0, 0]),
        Do::CallForHelp { radius } => (39, [*radius, 0, 0]),
        Do::Morph { display } => (3, [0, *display, 0]),
        Do::Despawn { ms } => (41, [*ms, 0, 0]),
        Do::QuestCredit { entry } => (33, [*entry, 6, 0]),
        Do::Stand { still } => (21, [if *still { 0 } else { 1 }, 0, 0]),
    })
}

fn spec_dir(p: &Project) -> std::path::PathBuf {
    p.root.join("behaviour")
}

fn save_spec<T: Serialize>(p: &Project, name: &str, v: &T) -> Result<()> {
    std::fs::create_dir_all(spec_dir(p))?;
    std::fs::write(spec_dir(p).join(format!("{name}.json")), serde_json::to_vec_pretty(v)?)?;
    Ok(())
}

fn load_spec<T: for<'a> Deserialize<'a>>(p: &Project, name: &str) -> Option<T> {
    std::fs::read(spec_dir(p).join(format!("{name}.json"))).ok().and_then(|b| serde_json::from_slice(&b).ok())
}

/// Is `entry` one of the pack's own creatures (a row it adds, not an override)?
fn own_creature(p: &Project, entry: i64) -> bool {
    data::load(p).world.get("creature_template").is_some_and(|r| r.rows.iter().any(|x| int(x, "Entry") == entry && x.get("override").and_then(Value::as_bool) != Some(true)))
}

/// Set a column on the pack's own creature.
fn set_creature(p: &Project, entry: i64, col: &str, v: Value) -> Result<()> {
    let d = data::load(p);
    let mut rows = d.world.get("creature_template").map(|r| r.rows.clone()).unwrap_or_default();
    let mut found = false;
    for r in rows.iter_mut() {
        if int(r, "Entry") == entry && r.get("override").and_then(Value::as_bool) != Some(true) {
            r.insert(col.into(), v.clone());
            found = true;
        }
    }
    if !found {
        bail!("{entry} isn't one of this pack's creatures");
    }
    save_rows(p, "world", "creature_template", &rows)?;
    Ok(())
}

/// Save a creature's cards: EventAI rows and their lines.
pub fn save_behaviour(p: &Project, b: &Behaviour) -> Result<serde_json::Value> {
    if !own_creature(p, b.entry) {
        bail!("Behaviour works on the pack's own creatures: make {} in Content first (or pick one of yours)", b.entry);
    }
    if b.cards.len() > 99 {
        bail!("up to 99 cards a creature");
    }
    let tag = format!("behaviour:{}", b.entry);
    // reuse the creature's line IDs where the text is the same, so saving again keeps them
    let old_lines: Vec<toml::Table> = data::load(p).world.get("custom_texts").map(|r| r.rows.iter().filter(|x| text(x, "comment") == tag).cloned().collect()).unwrap_or_default();
    let mut lines: Vec<toml::Table> = vec![];
    let mut line_id = |content: &str, kind: i64| -> Result<i64> {
        if let Some(l) = lines.iter().find(|l| text(l, "content_default") == content && int(l, "type") == kind) {
            return Ok(int(l, "entry"));
        }
        let id = match old_lines.iter().find(|l| text(l, "content_default") == content) {
            Some(l) => int(l, "entry"),
            None => -take_id(p, None, "custom_texts", "")?,
        };
        let mut r = row(&tag);
        r.insert("entry".into(), id.into());
        r.insert("content_default".into(), content.into());
        r.insert("type".into(), kind.into());
        r.insert("language".into(), 0i64.into());
        r.insert("sound".into(), 0i64.into());
        r.insert("emote".into(), 0i64.into());
        lines.push(r);
        Ok(id)
    };
    let mut events = vec![];
    for (i, c) in b.cards.iter().enumerate() {
        if c.actions.is_empty() || c.actions.len() > 3 {
            bail!("card {}: one to three things to do", i + 1);
        }
        let (etype, ep, repeat) = event(&c.when).with_context(|| format!("card {}", i + 1))?;
        let mut r = row(&tag);
        r.insert("id".into(), (b.entry * 100 + i as i64 + 1).into());
        r.insert("creature_id".into(), b.entry.into());
        r.insert("event_type".into(), etype.into());
        let mask = match c.phase {
            Some(ph) if (0..=31).contains(&ph) => (!(1u32 << ph)) as i32 as i64,
            Some(_) => bail!("card {}: phases go from 0 to 31", i + 1),
            None => 0,
        };
        r.insert("event_inverse_phase_mask".into(), mask.into());
        r.insert("event_chance".into(), c.chance.clamp(1, 100).into());
        r.insert("event_flags".into(), (repeat as i64).into());
        for (k, v) in ep.iter().enumerate() {
            r.insert(format!("event_param{}", k + 1), (*v).into());
        }
        for k in 0..3 {
            let (t, ap) = match c.actions.get(k) {
                Some(a) => action(a, &mut line_id).with_context(|| format!("card {}", i + 1))?,
                None => (0, [0; 3]),
            };
            r.insert(format!("action{}_type", k + 1), t.into());
            for (j, v) in ap.iter().enumerate() {
                r.insert(format!("action{}_param{}", k + 1, j + 1), (*v).into());
            }
        }
        r.insert("comment".into(), tag.clone().into());
        events.push(r);
    }
    put(p, "creature_ai_scripts", &tag, events)?;
    put(p, "custom_texts", &tag, lines)?;
    set_creature(p, b.entry, "AIName", (if b.cards.is_empty() { "" } else { "EventAI" }).into())?;
    save_spec(p, &format!("creature_{}", b.entry), b)?;
    Ok(serde_json::json!({"entry": b.entry, "cards": b.cards.len()}))
}

pub fn get_behaviour(p: &Project, entry: i64) -> Behaviour {
    load_spec(p, &format!("creature_{entry}")).unwrap_or(Behaviour { entry, cards: vec![] })
}

/// A card as one plain sentence ("When its health drops below 50%: yell "…", go to phase 1").
pub fn describe(c: &Card) -> String {
    let secs = |r: &[f64; 2]| if (r[1] - r[0]).abs() < 0.01 { format!("{}s", r[0]) } else { format!("{}–{}s", r[0], r[1]) };
    let again = |e: &[f64; 2]| if e[0] > 0.0 || e[1] > 0.0 { format!(", again every {}", secs(e)) } else { String::new() };
    let when = match &c.when {
        When::CombatTimer { first, every } => format!("In a fight, after {}{}", secs(first), again(every)),
        When::IdleTimer { first, every } => format!("Out of combat, after {}{}", secs(first), again(every)),
        When::HealthBelow { below, every } => format!("When its health drops below {below}%{}", again(every)),
        When::ManaBelow { below, every } => format!("When its mana drops below {below}%{}", again(every)),
        When::TargetHealthBelow { below, every } => format!("When its target's health drops below {below}%{}", again(every)),
        When::Aggro => "When a fight starts".into(),
        When::Kill => "When it kills someone".into(),
        When::Death => "When it dies".into(),
        When::Evade => "When it gives up the chase".into(),
        When::SpellHit { spell } => if *spell > 0 { format!("When spell {spell} hits it") } else { "When a spell hits it".into() },
        When::InRange { max, .. } => format!("When its target is within {max} yards"),
        When::PlayerNear { max, .. } => format!("When a player comes within {max} yards"),
        When::Spawned => "When it appears".into(),
        When::ReachedHome => "When it's back home after a fight".into(),
        When::FriendHurt { deficit, radius, .. } => format!("When a friend within {radius} yards is down {deficit} health"),
    };
    let what: Vec<String> = c
        .actions
        .iter()
        .map(|a| match a {
            Do::Say { text, style } => format!("{} \u{201c}{text}\u{201d}", if style.is_empty() { "say" } else { style }),
            Do::Cast { spell, target, .. } => format!("cast {spell} at {}", if target.is_empty() { "its target" } else { target }),
            Do::Summon { entry, seconds } => if *seconds > 0 { format!("summon {entry} for {seconds}s") } else { format!("summon {entry}") },
            Do::Phase { phase } => format!("go to phase {phase}"),
            Do::Emote { emote } => format!("emote {emote}"),
            Do::Sound { sound } => format!("play sound {sound}"),
            Do::Flee => "run for help".into(),
            Do::CallForHelp { radius } => format!("call friends within {radius} yards"),
            Do::Morph { display } => if *display > 0 { format!("change into display {display}") } else { "change back".into() },
            Do::Despawn { ms } => if *ms > 0 { format!("disappear after {:.1}s", *ms as f64 / 1000.0) } else { "disappear".into() },
            Do::QuestCredit { entry } => format!("count as a kill of {entry} for quests"),
            Do::Stand { still } => if *still { "stop chasing and stand".into() } else { "move again".into() },
        })
        .collect();
    let mut s = format!("{}: {}", when, what.join(", "));
    if let Some(ph) = c.phase {
        s = format!("[phase {ph}] {s}");
    }
    if c.chance < 100 {
        s.push_str(&format!(" ({}% chance)", c.chance));
    }
    s
}

// ------------------------------------------------------------------ paths

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Point {
    pub x: f64,
    pub y: f64,
    pub z: f64,
    /// Seconds to stand there.
    #[serde(default)]
    pub wait: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Path {
    /// The spawn (creature guid) that walks it.
    pub guid: i64,
    pub points: Vec<Point>,
}

/// Save a spawn's route (an empty route makes it stand or wander again).
pub fn save_path(p: &Project, path: &Path) -> Result<serde_json::Value> {
    let d = data::load(p);
    let mut spawns = d.world.get("creature").map(|r| r.rows.clone()).unwrap_or_default();
    let Some(sp) = spawns.iter_mut().find(|r| int(r, "guid") == path.guid) else {
        bail!("spawn {} isn't one of this pack's (paths are for spawns made with the Spawn tool)", path.guid);
    };
    if path.points.len() == 1 {
        bail!("a path needs two points or more");
    }
    sp.insert("MovementType".into(), (if path.points.is_empty() { 0i64 } else { 2 }).into());
    if !path.points.is_empty() {
        sp.insert("spawndist".into(), Value::Float(0.0));
    }
    save_rows(p, "world", "creature", &spawns)?;
    let tag = format!("path:{}", path.guid);
    let rows: Vec<toml::Table> = path
        .points
        .iter()
        .enumerate()
        .map(|(i, pt)| {
            let mut r = row(&tag);
            r.insert("Id".into(), path.guid.into());
            r.insert("Point".into(), (i as i64 + 1).into());
            r.insert("PositionX".into(), Value::Float(pt.x));
            r.insert("PositionY".into(), Value::Float(pt.y));
            r.insert("PositionZ".into(), Value::Float(pt.z));
            r.insert("Orientation".into(), Value::Float(100.0)); // 100: face where it walks
            r.insert("WaitTime".into(), ms(pt.wait).into());
            r.insert("ScriptId".into(), 0i64.into());
            r.insert("Comment".into(), tag.clone().into());
            r
        })
        .collect();
    put(p, "creature_movement", &tag, rows)?;
    Ok(serde_json::json!({"guid": path.guid, "points": path.points.len()}))
}

/// Every route the pack has, keyed by spawn.
pub fn paths(p: &Project) -> Vec<Path> {
    let d = data::load(p);
    let mut out: Vec<Path> = vec![];
    if let Some(r) = d.world.get("creature_movement") {
        let mut rows = r.rows.clone();
        rows.sort_by_key(|x| (int(x, "Id"), int(x, "Point")));
        let f = |x: &toml::Table, k: &str| x.get(k).and_then(|v| v.as_float().or(v.as_integer().map(|i| i as f64))).unwrap_or(0.0);
        for x in rows {
            let g = int(&x, "Id");
            let pt = Point { x: f(&x, "PositionX"), y: f(&x, "PositionY"), z: f(&x, "PositionZ"), wait: int(&x, "WaitTime") as f64 / 1000.0 };
            match out.iter_mut().find(|p| p.guid == g) {
                Some(p) => p.points.push(pt),
                None => out.push(Path { guid: g, points: vec![pt] }),
            }
        }
    }
    out
}

// ------------------------------------------------------------------ dialogue

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Choice {
    pub text: String,
    /// Another page's key, or "close", "vendor", "trainer", "innkeeper", "banker".
    pub to: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Page {
    pub key: String,
    pub text: String,
    #[serde(default)]
    pub choices: Vec<Choice>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Dialogue {
    pub entry: i64,
    /// The first page is what the creature says when talked to.
    pub pages: Vec<Page>,
}

/// Save a creature's dialogue: a gossip menu and an NPC text per page.
pub fn save_dialogue(p: &Project, dl: &Dialogue) -> Result<serde_json::Value> {
    if !own_creature(p, dl.entry) {
        bail!("Dialogue works on the pack's own creatures: make {} in Content first", dl.entry);
    }
    if dl.pages.is_empty() {
        bail!("a dialogue needs a first page");
    }
    let tag = format!("dialogue:{}", dl.entry);
    let d = data::load(p);
    // keep each page's IDs from last time (by key)
    let old: Option<Dialogue> = load_spec(p, &format!("dialogue_{}", dl.entry));
    let old_ids: Vec<(String, i64, i64)> = old
        .map(|o| {
            let menus: Vec<toml::Table> = d.world.get("gossip_menu").map(|r| r.rows.iter().filter(|x| text(x, "comment") == tag).cloned().collect()).unwrap_or_default();
            o.pages.iter().zip(menus.iter()).map(|(pg, m)| (pg.key.clone(), int(m, "entry"), int(m, "text_id"))).collect()
        })
        .unwrap_or_default();
    let mut ids = vec![];
    for pg in &dl.pages {
        if pg.text.trim().is_empty() {
            bail!("page {:?} has no text", pg.key);
        }
        if dl.pages.iter().filter(|q| q.key == pg.key).count() > 1 {
            bail!("two pages are called {:?}", pg.key);
        }
        let (menu, txt) = match old_ids.iter().find(|o| o.0 == pg.key) {
            Some(o) => (o.1, o.2),
            None => (take_id(p, None, "gossip_menu", "")?, take_id(p, None, "npc_text", "")?),
        };
        ids.push((pg.key.clone(), menu, txt));
    }
    let id_of = |k: &str| ids.iter().find(|x| x.0 == k).map(|x| x.1);
    let (mut menus, mut texts, mut options) = (vec![], vec![], vec![]);
    let mut flags = NPC_GOSSIP;
    for (pg, (_, menu, txt)) in dl.pages.iter().zip(&ids) {
        let mut m = row(&tag);
        m.insert("entry".into(), (*menu).into());
        m.insert("text_id".into(), (*txt).into());
        m.insert("script_id".into(), 0i64.into());
        m.insert("condition_id".into(), 0i64.into());
        menus.push(m);
        let mut t = row(&tag);
        t.insert("ID".into(), (*txt).into());
        t.insert("text0_0".into(), pg.text.clone().into());
        t.insert("text0_1".into(), pg.text.clone().into());
        t.insert("prob0".into(), Value::Float(1.0));
        texts.push(t);
        for (i, ch) in pg.choices.iter().enumerate() {
            if ch.text.trim().is_empty() {
                bail!("page {:?}: a choice has no text", pg.key);
            }
            // option_id: 1 gossip, 3 vendor, 5 trainer; action_menu_id −1 closes the window
            let (icon, option, npcflag, action) = match ch.to.as_str() {
                "close" => (0, 1, 1, -1),
                "vendor" => {
                    flags |= crate::wizards::NPC_VENDOR;
                    (1, 3, 4, 0)
                }
                "trainer" => {
                    flags |= 16;
                    (3, 5, 16, 0)
                }
                "innkeeper" => {
                    flags |= 128;
                    (5, 8, 128, 0)
                }
                "banker" => {
                    flags |= 256;
                    (6, 9, 256, 0)
                }
                k => (0, 1, 1, id_of(k).with_context(|| format!("page {:?}: a choice leads to {k:?}, which isn't a page", pg.key))?),
            };
            let mut o = row(&tag);
            o.insert("menu_id".into(), (*menu).into());
            o.insert("id".into(), (i as i64).into());
            o.insert("option_icon".into(), (icon as i64).into());
            o.insert("option_text".into(), ch.text.clone().into());
            o.insert("option_id".into(), (option as i64).into());
            o.insert("npc_option_npcflag".into(), (npcflag as i64).into());
            o.insert("action_menu_id".into(), (action as i64).into());
            options.push(o);
        }
    }
    put(p, "gossip_menu", &tag, menus)?;
    put(p, "npc_text", &tag, texts)?;
    put(p, "gossip_menu_option", &tag, options)?;
    set_creature(p, dl.entry, "GossipMenuId", ids[0].1.into())?;
    add_npc_flag(p, dl.entry, flags)?;
    save_spec(p, &format!("dialogue_{}", dl.entry), dl)?;
    Ok(serde_json::json!({"entry": dl.entry, "menu": ids[0].1, "pages": dl.pages.len()}))
}

pub fn get_dialogue(p: &Project, entry: i64) -> Dialogue {
    load_spec(p, &format!("dialogue_{entry}")).unwrap_or(Dialogue { entry, pages: vec![] })
}

/// The pack's creatures and what Behaviour Studio has for each.
pub fn overview(p: &Project) -> serde_json::Value {
    let d = data::load(p);
    let creatures: Vec<serde_json::Value> = d
        .world
        .get("creature_template")
        .map(|r| {
            r.rows
                .iter()
                .filter(|x| x.get("override").and_then(Value::as_bool) != Some(true))
                .map(|x| {
                    let e = int(x, "Entry");
                    let b = get_behaviour(p, e);
                    serde_json::json!({"entry": e, "name": text(x, "Name"), "display": int(x, "DisplayId1"), "cards": b.cards.len(), "dialogue": get_dialogue(p, e).pages.len(),
                                       "sentences": b.cards.iter().map(describe).collect::<Vec<_>>()})
                })
                .collect()
        })
        .unwrap_or_default();
    serde_json::json!({"creatures": creatures, "paths": paths(p)})
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::{create, Template};
    use crate::wizards::{creature, CreatureSpec};

    fn pack() -> (tempfile::TempDir, Project, i64) {
        let dir = tempfile::tempdir().unwrap();
        let p = create(&dir.path().join("p"), "Beh Pack", "Tester", Template::Pack).unwrap();
        let made = creature(&p, &CreatureSpec { name: "Ragnar".into(), display: 3171, min_level: 20, max_level: 20, ..Default::default() }).unwrap();
        (dir, p, made.id)
    }

    #[test]
    fn cards_become_eventai_rows_and_lines() {
        let (_d, p, entry) = pack();
        let b = Behaviour {
            entry,
            cards: vec![
                Card { when: When::Aggro, actions: vec![Do::Say { text: "You dare?".into(), style: "yell".into() }], chance: 100, phase: None, note: String::new() },
                Card { when: When::CombatTimer { first: [5.0, 8.0], every: [10.0, 12.0] }, actions: vec![Do::Cast { spell: 133, target: "random".into(), interrupt: false, triggered: false }], chance: 100, phase: Some(1), note: String::new() },
                Card { when: When::HealthBelow { below: 50, every: [0.0, 0.0] }, actions: vec![Do::Say { text: "Enough!".into(), style: "yell".into() }, Do::Phase { phase: 1 }], chance: 100, phase: None, note: String::new() },
            ],
        };
        save_behaviour(&p, &b).unwrap();
        let d = data::load(&p);
        let ev = &d.world["creature_ai_scripts"].rows;
        assert_eq!(ev.len(), 3);
        assert_eq!(int(&ev[0], "id"), entry * 100 + 1);
        assert_eq!(int(&ev[0], "event_type"), 4);
        assert_eq!(int(&ev[0], "action1_type"), 1);
        let line = int(&ev[0], "action1_param1");
        assert!(line <= -2_100_000, "{line}");
        assert_eq!(int(&ev[1], "event_type"), 0);
        assert_eq!(int(&ev[1], "event_param1"), 5000);
        assert_eq!(int(&ev[1], "event_param4"), 12000);
        assert_eq!(int(&ev[1], "event_flags"), 1);
        assert_eq!(int(&ev[1], "event_inverse_phase_mask"), !(1u32 << 1) as i32 as i64);
        assert_eq!(int(&ev[1], "action1_param2"), 4);
        assert_eq!(int(&ev[2], "event_param1"), 50);
        assert_eq!(int(&ev[2], "event_flags"), 0);
        assert_eq!(int(&ev[2], "action2_type"), 22);
        let lines = &d.world["custom_texts"].rows;
        assert_eq!(lines.len(), 2);
        assert_eq!(int(&lines[0], "type"), 1);
        let ct = d.world["creature_template"].rows.iter().find(|r| int(r, "Entry") == entry).unwrap().clone();
        assert_eq!(text(&ct, "AIName"), "EventAI");
        // saving again replaces, keeping the line IDs
        save_behaviour(&p, &b).unwrap();
        let d2 = data::load(&p);
        assert_eq!(d2.world["creature_ai_scripts"].rows.len(), 3);
        assert_eq!(int(&d2.world["creature_ai_scripts"].rows[0], "action1_param1"), line);
        assert_eq!(get_behaviour(&p, entry), b);
        // the creature form keeps the AI when saved again
        let spec = crate::wizards::get_creature(&p, entry).unwrap();
        creature(&p, &CreatureSpec { id: Some(entry), ..spec }).unwrap();
        let ct = data::load(&p).world["creature_template"].rows.iter().find(|r| int(r, "Entry") == entry).unwrap().clone();
        assert_eq!(text(&ct, "AIName"), "EventAI");
        assert!(describe(&b.cards[2]).contains("below 50%"));
        // and it builds to SQL
        let (install, _rollback) = data::sql(&p, &data::load(&p));
        assert!(install.contains("creature_ai_scripts") && install.contains("custom_texts"), "{install}");
        // FORGE_SQL_DUMP=<file>: with a dialogue and a path too, for loading into a real database
        if let Ok(out) = std::env::var("FORGE_SQL_DUMP") {
            let dl = Dialogue { entry, pages: vec![Page { key: "hi".into(), text: "Hello, $N.".into(), choices: vec![Choice { text: "Bye".into(), to: "close".into() }, Choice { text: "Wares?".into(), to: "vendor".into() }] }] };
            save_dialogue(&p, &dl).unwrap();
            let guid = data::add_spawn(&p, entry, data::Pos { map: 0, x: -9000.0, y: 100.0, z: 50.0, o: 0.0 }, 300, 0.0).unwrap() as i64;
            save_path(&p, &Path { guid, points: vec![Point { x: -9000.0, y: 100.0, z: 50.0, wait: 2.0 }, Point { x: -9010.0, y: 100.0, z: 50.0, wait: 0.0 }] }).unwrap();
            let (install, rollback) = data::sql(&p, &data::load(&p));
            std::fs::write(&out, format!("{install}\n-- ROLLBACK\n{rollback}")).unwrap();
        }
    }

    #[test]
    fn a_spawn_walks_its_path() {
        let (_d, p, entry) = pack();
        let guid = data::add_spawn(&p, entry, data::Pos { map: 0, x: -9000.0, y: 100.0, z: 50.0, o: 0.0 }, 300, 5.0).unwrap() as i64;
        let path = Path { guid, points: vec![Point { x: -9000.0, y: 100.0, z: 50.0, wait: 0.0 }, Point { x: -9010.0, y: 110.0, z: 51.0, wait: 3.0 }] };
        save_path(&p, &path).unwrap();
        let d = data::load(&p);
        let sp = d.world["creature"].rows.iter().find(|r| int(r, "guid") == guid).unwrap().clone();
        assert_eq!(int(&sp, "MovementType"), 2);
        assert_eq!(d.world["creature_movement"].rows.len(), 2);
        assert_eq!(int(&d.world["creature_movement"].rows[1], "WaitTime"), 3000);
        assert_eq!(paths(&p)[0].points.len(), 2);
        // an empty path: back to standing
        save_path(&p, &Path { guid, points: vec![] }).unwrap();
        assert!(data::load(&p).world.get("creature_movement").is_none_or(|r| r.rows.is_empty()));
        assert!(save_path(&p, &Path { guid: 1, points: vec![] }).is_err());
    }

    #[test]
    fn a_stock_creature_is_refused() {
        let (_d, p, _) = pack();
        assert!(save_behaviour(&p, &Behaviour { entry: 448, cards: vec![] }).is_err());
    }

    #[test]
    fn dialogue_pages_link_up() {
        let (_d, p, entry) = pack();
        let dl = Dialogue {
            entry,
            pages: vec![
                Page { key: "hello".into(), text: "Well met, $N.".into(), choices: vec![Choice { text: "Tell me of the isle.".into(), to: "isle".into() }, Choice { text: "Show me your wares.".into(), to: "vendor".into() }] },
                Page { key: "isle".into(), text: "It burns.".into(), choices: vec![Choice { text: "Farewell.".into(), to: "close".into() }] },
            ],
        };
        let r = save_dialogue(&p, &dl).unwrap();
        let d = data::load(&p);
        let menus = &d.world["gossip_menu"].rows;
        assert_eq!(menus.len(), 2);
        let opts = &d.world["gossip_menu_option"].rows;
        assert_eq!(int(&opts[0], "action_menu_id"), int(&menus[1], "entry"));
        assert_eq!(int(&opts[1], "option_id"), 3);
        assert_eq!(int(&opts[2], "action_menu_id"), -1);
        let ct = d.world["creature_template"].rows.iter().find(|r| int(r, "Entry") == entry).unwrap().clone();
        assert_eq!(int(&ct, "GossipMenuId"), r["menu"].as_i64().unwrap());
        assert_eq!(int(&ct, "NpcFlags") & 5, 5);
        // saving again keeps the IDs
        save_dialogue(&p, &dl).unwrap();
        let d2 = data::load(&p);
        assert_eq!(int(&d2.world["gossip_menu"].rows[0], "entry"), int(&menus[0], "entry"));
        assert_eq!(d2.world["gossip_menu_option"].rows.len(), 3);
        let bad = Dialogue { entry, pages: vec![Page { key: "a".into(), text: "x".into(), choices: vec![Choice { text: "go".into(), to: "nowhere".into() }] }] };
        assert!(save_dialogue(&p, &bad).is_err());
    }
}
