//! The scenario line DSL: one action or check per line.
//!
//! ```text
//! # comment
//! login Herald                      # enter the world as Herald (default: --char)
//! send .wnl hi                      # /say a line (dot-commands included)
//! expect wnl HI within 5s
//! expect wnl CP matches ^\d+,
//! join OWPersona
//! say-channel OWPersona #P 1 ooc Herald~Chronicler
//! [b] expect channel OWPersona from Herald matches ^#P
//! logout
//! ```
//!
//! A leading `[name]` runs the line on another client (`a` is the default/primary one, `b` the
//! second account from `HL_USER2`/`HL_PASS2`). `${VAR}` and `${VAR:-default}` expand from the
//! environment. Durations are `500ms`, `5s`, `2m` or a bare number of seconds.

use std::fmt;
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};

/// A compiled `matches` regex that keeps its source for reports.
#[derive(Clone)]
pub struct Pattern {
    pub source: String,
    pub re: regex_lite::Regex,
}

impl Pattern {
    pub fn new(source: &str) -> Result<Pattern> {
        Ok(Pattern {
            source: source.to_string(),
            re: regex_lite::Regex::new(source).with_context(|| format!("bad regex {source:?}"))?,
        })
    }
    pub fn is_match(&self, s: &str) -> bool {
        self.re.is_match(s)
    }
}

impl fmt::Debug for Pattern {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "/{}/", self.source)
    }
}

impl PartialEq for Pattern {
    fn eq(&self, other: &Self) -> bool {
        self.source == other.source
    }
}

/// Which chat lane an `expect chat` waits on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChatKind {
    Any,
    Say,
    Yell,
    Party,
    Whisper,
    System,
    Channel,
    Emote,
}

impl ChatKind {
    fn parse(s: &str) -> Option<ChatKind> {
        Some(match s {
            "any" => ChatKind::Any,
            "say" => ChatKind::Say,
            "yell" => ChatKind::Yell,
            "party" => ChatKind::Party,
            "whisper" => ChatKind::Whisper,
            "system" => ChatKind::System,
            "channel" => ChatKind::Channel,
            "emote" => ChatKind::Emote,
            _ => return None,
        })
    }
}

/// A skill named in `expect skill`: a known name or a raw `SkillLine.dbc` id.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SkillRef {
    pub id: u16,
    pub label: String,
}

/// `SkillLine.dbc` ids for the lines a scenario is likely to check.
pub const SKILLS: &[(&str, u16)] = &[
    ("swords", 43),
    ("axes", 44),
    ("bows", 45),
    ("guns", 46),
    ("beast-mastery", 50),
    ("survival", 51),
    ("maces", 54),
    ("two-handed-swords", 55),
    ("defense", 95),
    ("language-common", 98),
    ("language-orcish", 109),
    ("staves", 136),
    ("two-handed-maces", 160),
    ("unarmed", 162),
    ("marksmanship", 163),
    ("two-handed-axes", 172),
    ("daggers", 173),
    ("thrown", 176),
    ("crossbows", 226),
    ("wands", 228),
    ("polearms", 229),
    ("plate-mail", 293),
    ("mail", 413),
    ("leather", 414),
    ("cloth", 415),
    ("shield", 433),
    ("fist-weapons", 473),
];

impl SkillRef {
    pub fn parse(s: &str) -> Result<SkillRef> {
        if let Ok(id) = s.parse::<u16>() {
            return Ok(SkillRef {
                id,
                label: format!("skill {id}"),
            });
        }
        let key = s.to_ascii_lowercase().replace(['_', ' '], "-");
        SKILLS
            .iter()
            .find(|(n, _)| *n == key)
            .map(|(n, id)| SkillRef {
                id: *id,
                label: (*n).to_string(),
            })
            .ok_or_else(|| {
                anyhow!(
                    "unknown skill {s:?} (use a SkillLine id or one of: {})",
                    skill_names()
                )
            })
    }
}

fn skill_names() -> String {
    SKILLS
        .iter()
        .map(|(n, _)| *n)
        .collect::<Vec<_>>()
        .join(", ")
}

#[derive(Debug, Clone, PartialEq)]
pub enum ExpectKind {
    /// A WNL message with this tag (body optionally matching).
    Wnl { tag: String, re: Option<Pattern> },
    /// A chat line.
    Chat {
        kind: ChatKind,
        channel: Option<String>,
        from: Option<String>,
        re: Option<Pattern>,
    },
    /// `SMSG_CHANNEL_NOTIFY` YOU_JOINED for this channel.
    Joined(String),
    /// `SMSG_LIST_INVENTORY` from the current target listing this item entry.
    VendorItem(u32),
    /// A purchase of this item entry went through (`SMSG_BUY_ITEM` or the item's create).
    Bought(u32),
    /// The player's `PLAYER_SKILL_INFO` holds this skill line.
    Skill(SkillRef),
    /// `SMSG_BATTLEFIELD_STATUS` with this status (1 queued, 2 invited, 3 in the battle), on this
    /// battleground map if given.
    Bg { status: u32, map: Option<u32> },
    /// The client is on this map (after a worldport).
    Map(u32),
    /// The player's own `UNIT_FIELD_FACTIONTEMPLATE` is this `FactionTemplate.dbc` row.
    Faction(u32),
    /// The player stands within `radius` yards of this point (on the current map).
    Near { x: f32, y: f32, z: f32, radius: f32 },
    /// What others see in an equipment slot (0 head ... 18 tabard): `PLAYER_VISIBLE_ITEM_<slot>`'s
    /// item entry, 0 for nothing shown.
    Visible { slot: u8, entry: u32 },
    /// The permanent enchantment others see on an equipment slot (`PLAYER_VISIBLE_ITEM_<slot>_0 + 1`),
    /// 0 for none: a weapon's glow, or a transmog illusion.
    VisibleEnchant { slot: u8, enchant: u32 },
}

/// `expect bg <word>`: the status names.
pub fn bg_status(word: &str) -> Option<u32> {
    Some(match word {
        "queued" => 1,
        "invited" => 2,
        "in" => 3,
        _ => return None,
    })
}

#[derive(Debug, Clone, PartialEq)]
pub enum Cmd {
    Login {
        character: Option<String>,
    },
    Logout,
    Say(String),
    Yell(String),
    Whisper {
        to: String,
        text: String,
    },
    Join {
        channel: String,
        password: String,
    },
    Leave(String),
    SayChannel {
        channel: String,
        text: String,
    },
    Wait(Duration),
    FindNpc {
        entry: u32,
        within: Option<Duration>,
    },
    TargetNpc(u32),
    /// Select your own character (for GM commands such as `.die` that act on the selection).
    TargetSelf,
    /// Turn a completed quest in to the target and take reward choice `choice` (0-based):
    /// `CMSG_QUESTGIVER_CHOOSE_REWARD`. Pair with `.quest add` / `.quest complete` as a GM.
    QuestReward { quest: u32, choice: u32 },
    VendorList,
    Buy {
        entry: u32,
        count: u8,
    },
    /// `CMSG_BATTLEMASTER_JOIN` through the target battlemaster, for this battleground map.
    BgJoin(u32),
    /// `CMSG_BATTLEFIELD_PORT` accept for the battleground last invited to.
    BgAccept,
    /// `CMSG_LEAVE_BATTLEFIELD` for the battleground the client is in.
    BgLeave,
    Expect {
        what: ExpectKind,
        within: Option<Duration>,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub struct Step {
    /// 1-based source line.
    pub line: usize,
    /// The client the line runs on (`a` unless prefixed `[name]`).
    pub client: String,
    /// The line as written (after `${}` expansion), for reports.
    pub text: String,
    pub cmd: Cmd,
}

#[derive(Debug, Clone)]
pub struct Scenario {
    pub name: String,
    pub steps: Vec<Step>,
}

pub fn parse_duration(s: &str) -> Result<Duration> {
    let s = s.trim();
    let (num, unit) = match s.find(|c: char| !(c.is_ascii_digit() || c == '.')) {
        Some(i) => (&s[..i], &s[i..]),
        None => (s, "s"),
    };
    let n: f64 = num
        .parse()
        .map_err(|_| anyhow!("bad duration {s:?} (use 500ms, 5s, 2m)"))?;
    let secs = match unit {
        "ms" => n / 1000.0,
        "s" | "" => n,
        "m" | "min" => n * 60.0,
        _ => bail!("bad duration unit in {s:?} (use ms, s or m)"),
    };
    if !(0.0..=86_400.0).contains(&secs) {
        bail!("duration {s:?} out of range");
    }
    Ok(Duration::from_secs_f64(secs))
}

/// Expand `${VAR}` / `${VAR:-default}` with `lookup`; an unset variable with no default errors.
pub fn expand(line: &str, lookup: &dyn Fn(&str) -> Option<String>) -> Result<String> {
    let mut out = String::with_capacity(line.len());
    let mut rest = line;
    while let Some(start) = rest.find("${") {
        out.push_str(&rest[..start]);
        let after = &rest[start + 2..];
        let end = after
            .find('}')
            .ok_or_else(|| anyhow!("unclosed ${{ in {line:?}"))?;
        let inner = &after[..end];
        let (name, default) = match inner.split_once(":-") {
            Some((n, d)) => (n, Some(d)),
            None => (inner, None),
        };
        match lookup(name).filter(|v| !v.is_empty()) {
            Some(v) => out.push_str(&v),
            None => match default {
                Some(d) => out.push_str(d),
                None => bail!("${{{name}}} is not set"),
            },
        }
        rest = &after[end + 1..];
    }
    out.push_str(rest);
    Ok(out)
}

/// Split off a trailing `within <dur>`.
fn take_within(s: &str) -> Result<(&str, Option<Duration>)> {
    let t = s.trim_end();
    // Only a trailing `within <valid duration>` counts, so a regex may contain "within".
    if let Some(idx) = t.rfind(" within ") {
        if let Ok(d) = parse_duration(t[idx + 8..].trim()) {
            return Ok((&t[..idx], Some(d)));
        }
    }
    if let Some(dur) = t.strip_prefix("within ") {
        if let Ok(d) = parse_duration(dur.trim()) {
            return Ok(("", Some(d)));
        }
    }
    Ok((t, None))
}

/// Split off `matches <regex to end of line>`.
fn take_matches(s: &str) -> Result<(&str, Option<Pattern>)> {
    if let Some(idx) = s.find(" matches ") {
        let re = s[idx + 9..].trim();
        if re.is_empty() {
            bail!("`matches` needs a regex");
        }
        return Ok((&s[..idx], Some(Pattern::new(re)?)));
    }
    if let Some(re) = s.strip_prefix("matches ") {
        return Ok(("", Some(Pattern::new(re.trim())?)));
    }
    Ok((s, None))
}

fn rest_after<'a>(s: &'a str, word: &str) -> &'a str {
    s[word.len()..].trim()
}

fn need<'a>(s: &'a str, what: &str) -> Result<&'a str> {
    if s.is_empty() {
        bail!("missing {what}");
    }
    Ok(s)
}

fn parse_u32(s: &str, what: &str) -> Result<u32> {
    s.trim()
        .parse()
        .map_err(|_| anyhow!("{what} must be a number, got {s:?}"))
}

fn parse_expect(body: &str) -> Result<Cmd> {
    let (body, within) = take_within(body)?;
    let (body, re) = take_matches(body)?;
    let mut words = body.split_whitespace();
    let head = words.next().ok_or_else(|| anyhow!("expect what?"))?;
    let words: Vec<&str> = words.collect();
    let what = match head {
        "wnl" => {
            let tag = words
                .first()
                .ok_or_else(|| anyhow!("expect wnl needs a TAG"))?
                .to_ascii_uppercase();
            if words.len() > 1 {
                bail!("unexpected {:?} after the tag", words[1..].join(" "));
            }
            ExpectKind::Wnl { tag, re }
        }
        "joined" => {
            if re.is_some() {
                bail!("expect joined takes no `matches`");
            }
            ExpectKind::Joined(
                words
                    .first()
                    .ok_or_else(|| anyhow!("expect joined needs a channel"))?
                    .to_string(),
            )
        }
        "vendor-item" => ExpectKind::VendorItem(parse_u32(
            words.first().copied().unwrap_or(""),
            "item entry",
        )?),
        "bought" => ExpectKind::Bought(parse_u32(
            words.first().copied().unwrap_or(""),
            "item entry",
        )?),
        "bg" => {
            if re.is_some() {
                bail!("expect bg takes no `matches`");
            }
            let status = words
                .first()
                .and_then(|w| bg_status(w))
                .ok_or_else(|| anyhow!("expect bg queued|invited|in [map <id>]"))?;
            let map = match (words.get(1), words.get(2)) {
                (Some(&"map"), Some(id)) => Some(parse_u32(id, "map id")?),
                (None, _) => None,
                _ => bail!("expect bg queued|invited|in [map <id>]"),
            };
            ExpectKind::Bg { status, map }
        }
        "near" => {
            if re.is_some() || words.len() != 4 {
                bail!("expect near <x> <y> <z> <radius>");
            }
            let f = |w: &str| -> Result<f32> {
                w.parse::<f32>().map_err(|_| anyhow!("expect near: {w:?} is not a number"))
            };
            ExpectKind::Near { x: f(words[0])?, y: f(words[1])?, z: f(words[2])?, radius: f(words[3])? }
        }
        "enchant" => {
            if re.is_some() || words.len() != 2 {
                bail!("expect enchant <slot 0-18> <enchantment id, 0 = none>");
            }
            let slot = parse_u32(words[0], "slot")?;
            if slot > 18 {
                bail!("slot must be 0..18");
            }
            ExpectKind::VisibleEnchant { slot: slot as u8, enchant: parse_u32(words[1], "enchantment id")? }
        }
        "visible" => {
            if re.is_some() || words.len() != 2 {
                bail!("expect visible <slot 0-18> <item entry, 0 = nothing shown>");
            }
            let slot = parse_u32(words[0], "slot")?;
            if slot > 18 {
                bail!("slot must be 0..18");
            }
            ExpectKind::Visible { slot: slot as u8, entry: parse_u32(words[1], "item entry")? }
        }
        "map" => ExpectKind::Map(parse_u32(words.first().copied().unwrap_or(""), "map id")?),
        "faction" => ExpectKind::Faction(parse_u32(
            words.first().copied().unwrap_or(""),
            "faction template id",
        )?),
        "skill" => {
            if words.is_empty() {
                bail!("expect skill needs a name or id");
            }
            ExpectKind::Skill(SkillRef::parse(&words.join("-"))?)
        }
        other => {
            // `expect chat <kind> ...` or the kind directly: `expect channel X from Y ...`.
            let (kind_word, rest) = if other == "chat" {
                (
                    *words
                        .first()
                        .ok_or_else(|| anyhow!("expect chat needs a kind"))?,
                    &words[1..],
                )
            } else {
                (other, &words[..])
            };
            let kind = ChatKind::parse(kind_word)
                .ok_or_else(|| anyhow!("unknown expectation {other:?}"))?;
            let mut rest = rest.iter().copied();
            let mut channel = None;
            let mut from = None;
            if kind == ChatKind::Channel {
                channel = Some(
                    rest.next()
                        .ok_or_else(|| anyhow!("expect channel needs a channel name"))?
                        .to_string(),
                );
            }
            while let Some(w) = rest.next() {
                match w {
                    "from" => {
                        from = Some(
                            rest.next()
                                .ok_or_else(|| anyhow!("`from` needs a name"))?
                                .to_string(),
                        )
                    }
                    other => bail!("unexpected {other:?}"),
                }
            }
            ExpectKind::Chat {
                kind,
                channel,
                from,
                re,
            }
        }
    };
    Ok(Cmd::Expect { what, within })
}

/// Parse one (already expanded, non-empty, non-comment) line into a command.
pub fn parse_cmd(line: &str) -> Result<Cmd> {
    let line = line.trim();
    let word = line.split_whitespace().next().unwrap_or("");
    let rest = rest_after(line, word);
    Ok(match word {
        "login" => Cmd::Login {
            character: (!rest.is_empty()).then(|| rest.to_string()),
        },
        "logout" => Cmd::Logout,
        "send" | "say" => Cmd::Say(need(rest, "text")?.to_string()),
        "yell" => Cmd::Yell(need(rest, "text")?.to_string()),
        "whisper" => {
            let (to, text) = need(rest, "target and text")?
                .split_once(char::is_whitespace)
                .ok_or_else(|| anyhow!("whisper <name> <text>"))?;
            Cmd::Whisper {
                to: to.to_string(),
                text: text.trim().to_string(),
            }
        }
        "join" => {
            let mut it = need(rest, "channel")?.split_whitespace();
            let channel = it.next().unwrap_or_default().to_string();
            let password = it.next().unwrap_or("").to_string();
            Cmd::Join { channel, password }
        }
        "leave" => Cmd::Leave(need(rest, "channel")?.to_string()),
        "say-channel" => {
            let (channel, text) = need(rest, "channel and text")?
                .split_once(char::is_whitespace)
                .ok_or_else(|| anyhow!("say-channel <channel> <text>"))?;
            Cmd::SayChannel {
                channel: channel.to_string(),
                text: text.trim().to_string(),
            }
        }
        "wait" => Cmd::Wait(parse_duration(need(rest, "duration")?)?),
        "find" => {
            let (body, within) = take_within(rest)?;
            let mut it = body.split_whitespace();
            if it.next() != Some("npc") {
                bail!("find npc <entry> [within <dur>]");
            }
            let entry = parse_u32(it.next().unwrap_or(""), "creature entry")?;
            Cmd::FindNpc { entry, within }
        }
        "target" => {
            let mut it = rest.split_whitespace();
            match it.next() {
                Some("npc") => Cmd::TargetNpc(parse_u32(it.next().unwrap_or(""), "creature entry")?),
                Some("self") => Cmd::TargetSelf,
                _ => bail!("target npc <entry> | target self"),
            }
        }
        "quest" => {
            let w: Vec<&str> = rest.split_whitespace().collect();
            match w.as_slice() {
                ["reward", q, c] => Cmd::QuestReward { quest: parse_u32(q, "quest id")?, choice: parse_u32(c, "reward choice")? },
                ["reward", q] => Cmd::QuestReward { quest: parse_u32(q, "quest id")?, choice: 0 },
                _ => bail!("quest reward <quest id> [choice 0-5]"),
            }
        }
        "vendor" => match rest {
            "list" => Cmd::VendorList,
            _ => bail!("vendor list"),
        },
        "buy" => {
            let mut it = rest.split_whitespace();
            let entry = parse_u32(it.next().unwrap_or(""), "item entry")?;
            let count = match it.next() {
                Some(c) => c
                    .parse::<u8>()
                    .map_err(|_| anyhow!("count must be 1..255, got {c:?}"))?,
                None => 1,
            };
            Cmd::Buy { entry, count }
        }
        "bg" => {
            let mut it = rest.split_whitespace();
            match (it.next(), it.next()) {
                (Some("join"), Some(map)) => Cmd::BgJoin(parse_u32(map, "battleground map id")?),
                (Some("accept"), None) => Cmd::BgAccept,
                (Some("leave"), None) => Cmd::BgLeave,
                _ => bail!("bg join <map id> | bg accept | bg leave"),
            }
        }
        "expect" => parse_expect(rest)?,
        "" => bail!("empty line"),
        other => bail!("unknown command {other:?}"),
    })
}

/// Parse a whole scenario file's text.
pub fn parse(name: &str, text: &str, lookup: &dyn Fn(&str) -> Option<String>) -> Result<Scenario> {
    let mut steps = Vec::new();
    for (i, raw) in text.lines().enumerate() {
        let line_no = i + 1;
        let trimmed = raw.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let expanded = expand(trimmed, lookup).with_context(|| format!("{name}:{line_no}"))?;
        let (client, body) = match expanded.strip_prefix('[') {
            Some(after) => {
                let (c, b) = after
                    .split_once(']')
                    .ok_or_else(|| anyhow!("{name}:{line_no}: unclosed [client]"))?;
                let c = c.trim();
                if c.is_empty() || !c.chars().all(|ch| ch.is_ascii_alphanumeric()) {
                    bail!("{name}:{line_no}: client name must be alphanumeric");
                }
                (c.to_ascii_lowercase(), b.trim().to_string())
            }
            None => ("a".to_string(), expanded.clone()),
        };
        let cmd = parse_cmd(&body).with_context(|| format!("{name}:{line_no}: {body}"))?;
        steps.push(Step {
            line: line_no,
            client,
            text: expanded,
            cmd,
        });
    }
    Ok(Scenario {
        name: name.to_string(),
        steps,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn no_env(_: &str) -> Option<String> {
        None
    }

    fn cmd(s: &str) -> Cmd {
        parse_cmd(s).unwrap()
    }

    #[test]
    fn battleground_lines() {
        assert_eq!(cmd("bg join 489"), Cmd::BgJoin(489));
        assert_eq!(cmd("bg accept"), Cmd::BgAccept);
        assert_eq!(cmd("bg leave"), Cmd::BgLeave);
        assert_eq!(cmd("target self"), Cmd::TargetSelf);
        assert!(parse_cmd("bg join").is_err());
        assert!(parse_cmd("bg dance").is_err());
        assert_eq!(
            cmd("expect bg invited map 489 within 2m"),
            Cmd::Expect {
                what: ExpectKind::Bg { status: 2, map: Some(489) },
                within: Some(Duration::from_secs(120))
            }
        );
        assert_eq!(
            cmd("expect bg queued"),
            Cmd::Expect { what: ExpectKind::Bg { status: 1, map: None }, within: None }
        );
        assert!(parse_cmd("expect bg sleeping").is_err());
        assert_eq!(
            cmd("expect near 596.8 -188.7 -54.1 30 within 10s"),
            Cmd::Expect {
                what: ExpectKind::Near { x: 596.8, y: -188.7, z: -54.1, radius: 30.0 },
                within: Some(Duration::from_secs(10))
            }
        );
        assert!(parse_cmd("expect near 1 2 3").is_err());
        assert_eq!(
            cmd("expect visible 4 2470 within 5s"),
            Cmd::Expect {
                what: ExpectKind::Visible { slot: 4, entry: 2470 },
                within: Some(Duration::from_secs(5))
            }
        );
        assert!(parse_cmd("expect visible 19 1").is_err());
        assert_eq!(
            cmd("expect enchant 15 1900 within 5s"),
            Cmd::Expect {
                what: ExpectKind::VisibleEnchant { slot: 15, enchant: 1900 },
                within: Some(Duration::from_secs(5))
            }
        );
        assert_eq!(cmd("expect map 489"), Cmd::Expect { what: ExpectKind::Map(489), within: None });
        assert_eq!(
            cmd("expect faction 2 within 5s"),
            Cmd::Expect { what: ExpectKind::Faction(2), within: Some(Duration::from_secs(5)) }
        );
    }

    #[test]
    fn durations() {
        assert_eq!(parse_duration("5s").unwrap(), Duration::from_secs(5));
        assert_eq!(parse_duration("500ms").unwrap(), Duration::from_millis(500));
        assert_eq!(parse_duration("2m").unwrap(), Duration::from_secs(120));
        assert_eq!(parse_duration("3").unwrap(), Duration::from_secs(3));
        assert_eq!(parse_duration("1.5s").unwrap(), Duration::from_millis(1500));
        assert!(parse_duration("5h").is_err());
        assert!(parse_duration("abc").is_err());
    }

    #[test]
    fn the_examples_from_the_brief_parse() {
        assert_eq!(
            cmd("login Herald"),
            Cmd::Login {
                character: Some("Herald".into())
            }
        );
        assert_eq!(cmd("login"), Cmd::Login { character: None });
        assert_eq!(cmd("send .wnl hi"), Cmd::Say(".wnl hi".into()));
        assert_eq!(
            cmd("expect wnl HI within 5s"),
            Cmd::Expect {
                what: ExpectKind::Wnl {
                    tag: "HI".into(),
                    re: None
                },
                within: Some(Duration::from_secs(5))
            }
        );
        let Cmd::Expect {
            what: ExpectKind::Wnl { tag, re: Some(re) },
            within: None,
        } = cmd(r"expect wnl CP matches ^\d+,\d+,[01]$")
        else {
            panic!()
        };
        assert_eq!(tag, "CP");
        assert!(re.is_match("120,5,1"));
        assert!(!re.is_match("120,5,2"));
        assert_eq!(
            cmd("join OWPersona"),
            Cmd::Join {
                channel: "OWPersona".into(),
                password: String::new()
            }
        );
        assert_eq!(
            cmd("say-channel OWPersona #P 1 ooc Herald~Chronicler"),
            Cmd::SayChannel {
                channel: "OWPersona".into(),
                text: "#P 1 ooc Herald~Chronicler".into()
            }
        );
        let Cmd::Expect {
            what:
                ExpectKind::Chat {
                    kind: ChatKind::Channel,
                    channel: Some(ch),
                    from: Some(from),
                    re: Some(re),
                },
            within: Some(w),
        } = cmd(r"expect channel OWPersona from Herald2 matches ^#P \d+ within 20s")
        else {
            panic!()
        };
        assert_eq!((ch.as_str(), from.as_str()), ("OWPersona", "Herald2"));
        assert!(re.is_match("#P 1 ooc X~Y"));
        assert_eq!(w, Duration::from_secs(20));
        assert_eq!(cmd("logout"), Cmd::Logout);
    }

    #[test]
    fn matches_keeps_spaces_and_within_only_at_the_end() {
        let Cmd::Expect {
            what: ExpectKind::Wnl { re: Some(re), .. },
            within,
        } = cmd("expect wnl LG matches ^\\d+,[01];2589,50 within 8s")
        else {
            panic!()
        };
        assert_eq!(re.source, "^\\d+,[01];2589,50");
        assert_eq!(within, Some(Duration::from_secs(8)));
        let Cmd::Expect {
            what: ExpectKind::Chat { re: Some(re), .. },
            within: None,
        } = cmd("expect system matches you are within reach")
        else {
            panic!()
        };
        assert_eq!(re.source, "you are within reach");
    }

    #[test]
    fn other_commands() {
        assert_eq!(
            cmd("whisper Herald2 hello there"),
            Cmd::Whisper {
                to: "Herald2".into(),
                text: "hello there".into()
            }
        );
        assert_eq!(cmd("wait 2s"), Cmd::Wait(Duration::from_secs(2)));
        assert_eq!(
            cmd("find npc 990001 within 15s"),
            Cmd::FindNpc {
                entry: 990001,
                within: Some(Duration::from_secs(15))
            }
        );
        assert_eq!(cmd("target npc 990001"), Cmd::TargetNpc(990001));
        assert_eq!(cmd("quest reward 2929 2"), Cmd::QuestReward { quest: 2929, choice: 2 });
        assert!(parse_cmd("quest finish 2929").is_err());
        assert_eq!(cmd("vendor list"), Cmd::VendorList);
        assert_eq!(
            cmd("buy 2589"),
            Cmd::Buy {
                entry: 2589,
                count: 1
            }
        );
        assert_eq!(
            cmd("expect skill Bows"),
            Cmd::Expect {
                what: ExpectKind::Skill(SkillRef {
                    id: 45,
                    label: "bows".into()
                }),
                within: None
            }
        );
        assert_eq!(
            cmd("expect skill two handed axes"),
            Cmd::Expect {
                what: ExpectKind::Skill(SkillRef {
                    id: 172,
                    label: "two-handed-axes".into()
                }),
                within: None
            }
        );
        assert_eq!(
            cmd("expect skill 999"),
            Cmd::Expect {
                what: ExpectKind::Skill(SkillRef {
                    id: 999,
                    label: "skill 999".into()
                }),
                within: None
            }
        );
        assert_eq!(
            cmd("expect joined OWPersona within 5s"),
            Cmd::Expect {
                what: ExpectKind::Joined("OWPersona".into()),
                within: Some(Duration::from_secs(5))
            }
        );
        assert!(matches!(
            cmd("expect chat system matches ^Hello"),
            Cmd::Expect {
                what: ExpectKind::Chat {
                    kind: ChatKind::System,
                    ..
                },
                ..
            }
        ));
    }

    #[test]
    fn errors_name_the_problem() {
        for bad in [
            "dance",
            "expect",
            "expect wnl",
            "expect wnl CP matches (",
            "expect skill unobtanium",
            "expect channel",
            "wait forever",
            "buy",
            "buy 1 300",
            "whisper Bob",
            "find vendor 1",
            "snapshot wallet",
            "expect wallet-delta -50",
            "expect wnl CP CP",
        ] {
            assert!(parse_cmd(bad).is_err(), "{bad:?} should fail");
        }
    }

    #[test]
    fn files_have_comments_clients_and_env() {
        let env = |k: &str| match k {
            "HL_CHAR2" => Some("Scribe".to_string()),
            _ => None,
        };
        let s = parse(
            "pair.txt",
            "# a comment\n\nlogin\n[b] login ${HL_CHAR2:-Herald2}\n[B] logout ${NOPE:-}\n",
            &env,
        );
        let s = s.unwrap();
        assert_eq!(s.steps.len(), 3);
        assert_eq!(s.steps[0].line, 3);
        assert_eq!(s.steps[0].client, "a");
        assert_eq!(s.steps[1].client, "b");
        assert_eq!(
            s.steps[1].cmd,
            Cmd::Login {
                character: Some("Scribe".into())
            }
        );
        assert_eq!(s.steps[2].client, "b");
        assert!(parse("x", "login ${MISSING}\n", &no_env).is_err());
        let err = parse("x.txt", "login\nfrobnicate\n", &no_env).unwrap_err();
        assert!(format!("{err:#}").contains("x.txt:2"), "{err:#}");
    }

    #[test]
    fn expand_defaults_and_literals() {
        let env = |k: &str| (k == "A").then(|| "1".to_string());
        assert_eq!(expand("x${A}y", &env).unwrap(), "x1y");
        assert_eq!(expand("${B:-two}", &env).unwrap(), "two");
        assert_eq!(expand("no vars $ here", &env).unwrap(), "no vars $ here");
        assert!(expand("${A", &env).is_err());
    }

    #[test]
    fn the_shipped_scenarios_parse() {
        let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/scenarios");
        let mut n = 0;
        for entry in std::fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            if path.extension().and_then(|e| e.to_str()) != Some("txt") {
                continue;
            }
            let text = std::fs::read_to_string(&path).unwrap();
            // numeric settings (HL_FACTION_A ...) need a number, durations (HL_PLAY) a duration; the rest any text
            let env = |k: &str| {
                Some(if k.starts_with("HL_FACTION") { "1" } else if k == "HL_PLAY" { "90s" } else { "X" }.to_string())
            };
            parse(&path.display().to_string(), &text, &env)
                .unwrap_or_else(|e| panic!("{}: {e:#}", path.display()));
            n += 1;
        }
        assert!(n >= 5, "expected the shipped scenarios, found {n}");
    }
}
