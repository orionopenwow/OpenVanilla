//! One headless game client: realmd logon, the world handshake, character select, entering the
//! world, the keep-alive, and a model of what the server told us that scenario checks read.
//!
//! The flow mirrors wenilla's own native sequencer (`benilla-app/src/net/io.rs`): `logon` ->
//! `WorldSession::connect` -> `char_enum` -> `player_login` + `set_active_mover` -> `into_split`,
//! then a reader thread turns packets into `SessionEvent`s while this side writes; `CMSG_PING`
//! every 30 s (`PING_INTERVAL`; the server kicks pings under ~27 s apart) and the acks a 1.12
//! client always sends (teleport, worldport, forced speed, mover modes, cinematic).

use std::collections::{HashMap, HashSet};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Result};
use benilla_protocol::messages::{
    self, ChatMessage, VendorItem, CHAT_MSG_CHANNEL, CHAT_MSG_EMOTE, CHAT_MSG_PARTY, CHAT_MSG_SAY,
    CHAT_MSG_SYSTEM, CHAT_MSG_WHISPER, CHAT_MSG_YELL,
};
use benilla_protocol::{
    AuthReject, Character, EntityKind, ObjectFields, Poll, SessionEvent, WardenRequired,
    WorldAuthReject, WorldSession, WorldWriter,
};

use crate::bridge::{Bridge, Upstream};
use crate::scenario::{ChatKind, ExpectKind};
use crate::web::{Origin, PlayCredential, WebSession};
use crate::wnl::{Reassembler, WnlMessage};

/// The 1.12 client's ping cadence (`benilla-app` `PING_INTERVAL`).
pub const PING_INTERVAL: Duration = Duration::from_secs(30);

/// How a client reaches the game.
#[derive(Clone, Debug)]
pub enum Mode {
    /// Direct TCP to realmd (`host[:port]`, default 3724) with a game account.
    Tcp { auth_host: String },
    /// Log in at a wenilla-realm web service, then go through its WebSocket relay.
    Web { url: String },
}

#[derive(Clone, Debug)]
pub struct ClientConfig {
    pub label: String,
    pub mode: Mode,
    /// Game account (tcp mode) or web account (web mode).
    pub user: String,
    pub pass: String,
    pub realm: Option<String>,
    /// Override the realm list's world address (tcp mode: `host:port`).
    pub world: Option<String>,
    /// Character to enter as when `login` names none (beats the web preset).
    pub character: Option<String>,
    /// Used when neither `login`, `character` nor the web preset names one, if the account has
    /// it (client `a`: "Herald"); otherwise the first character.
    pub fallback_character: Option<String>,
    pub timeout: Duration,
    pub verbose: bool,
}

/// Phase timings of one connect, in ms.
#[derive(Debug, Clone, Default, serde::Serialize)]
pub struct Timings {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub web_ms: Option<u64>,
    pub auth_ms: u64,
    pub world_ms: u64,
    pub char_enum_ms: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub enter_world_ms: Option<u64>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct CharInfo {
    pub name: String,
    pub guid: u64,
    pub level: u8,
    pub race: u8,
    pub class: u8,
    pub zone: u32,
    pub map: u32,
}

impl From<&Character> for CharInfo {
    fn from(c: &Character) -> Self {
        CharInfo {
            name: c.name.clone(),
            guid: c.guid,
            level: c.level,
            race: c.race,
            class: c.class,
            zone: c.zone,
            map: c.map,
        }
    }
}

/// Everything the scenario checks read; observations are consumed by the expectation they satisfy.
#[derive(Debug, Clone)]
pub enum Observed {
    Chat(ChatMessage),
    Wnl(WnlMessage),
    Joined(String),
    Vendor {
        vendor: u64,
        items: Vec<VendorItem>,
    },
    Bought {
        vendor: u64,
        entry: Option<u32>,
        slot: u32,
    },
    BuyFailed {
        entry: u32,
        reason: u8,
    },
    ItemCreated(u32),
    /// `SMSG_BATTLEFIELD_STATUS`: a queue slot's battleground map and status.
    BgStatus {
        map_id: u32,
        status: u32,
    },
}

#[derive(Debug)]
struct Entry {
    obs: Observed,
    consumed: bool,
}

#[derive(Debug, Clone)]
pub struct Unit {
    pub entry: Option<u32>,
    pub position: [f32; 3],
    pub npc_flags: u32,
}

enum Inbound {
    Events(Vec<SessionEvent>),
    Skipped(String),
    Closed(String),
}

/// The world as this client has been told it.
#[derive(Default)]
pub struct WorldModel {
    pub self_guid: u64,
    pub self_name: String,
    pub self_fields: ObjectFields,
    pub self_pos: Option<[f32; 3]>,
    pub orientation: f32,
    pub map: Option<u32>,
    pub units: HashMap<u64, Unit>,
    pub names: HashMap<u64, String>,
    asked_names: HashSet<u64>,
    log: Vec<Entry>,
    wnl: Reassembler,
    pub vendor_lists: HashMap<u64, Vec<VendorItem>>,
    pub target: Option<u64>,
    /// The battleground map of the last invite (`bg accept` ports there) or of the battle we are in.
    pub bg_map: Option<u32>,
    pub in_world: bool,
    pub logged_out: bool,
    pub logout_refused: Option<u32>,
    pub login_failed: Option<u8>,
    pub closed: Option<String>,
    pub packets: u64,
    pub skipped: u64,
    pub last_rtt_ms: u32,
    /// Movement flags our own mover currently has (the autopilot keeps this current), echoed in
    /// the speed-change and mover-mode acks.
    pub move_flags: u32,
}

/// The result of checking one expectation against what has arrived so far.
#[derive(Debug, PartialEq, Eq)]
pub enum Check {
    Met(String),
    Pending,
    Failed(String),
}

pub fn chat_kind_matches(kind: ChatKind, t: u8) -> bool {
    match kind {
        ChatKind::Any => true,
        ChatKind::Say => t == CHAT_MSG_SAY,
        ChatKind::Yell => t == CHAT_MSG_YELL,
        ChatKind::Party => t == CHAT_MSG_PARTY,
        ChatKind::Whisper => t == CHAT_MSG_WHISPER,
        ChatKind::System => t == CHAT_MSG_SYSTEM,
        ChatKind::Channel => t == CHAT_MSG_CHANNEL,
        ChatKind::Emote => t == CHAT_MSG_EMOTE,
    }
}

impl WorldModel {
    fn push(&mut self, obs: Observed) {
        self.log.push(Entry {
            obs,
            consumed: false,
        });
    }

    /// Record a chat line (and the WNL message it may complete).
    pub fn on_chat(&mut self, m: ChatMessage) {
        if let Some(w) = self.wnl.feed_text(&m.text) {
            self.push(Observed::Wnl(w));
        }
        self.push(Observed::Chat(m));
    }

    pub fn observe(&mut self, obs: Observed) {
        self.push(obs);
    }

    /// The skill slots the descriptor holds.
    pub fn skills(&self) -> Vec<messages::PlayerSkillSlot> {
        (0..messages::PLAYER_SKILL_SLOTS)
            .filter_map(|s| self.self_fields.player_skill(s))
            .filter(|s| s.skill_id != 0)
            .collect()
    }

    pub fn find_unit(&self, entry: u32) -> Option<(u64, &Unit)> {
        let me = self.self_pos;
        self.units
            .iter()
            .filter(|(_, u)| u.entry == Some(entry))
            .min_by(|a, b| {
                let d = |u: &Unit| me.map(|p| dist(p, u.position)).unwrap_or(0.0);
                d(a.1).total_cmp(&d(b.1))
            })
            .map(|(g, u)| (*g, u))
    }

    /// Check (and on success consume) one expectation.
    pub fn check(&mut self, what: &ExpectKind) -> Check {
        match what {
            ExpectKind::Wnl { tag, re } => {
                let hit = self.log.iter_mut().find(|e| {
                    !e.consumed
                        && matches!(&e.obs, Observed::Wnl(m) if m.tag == *tag
                            && re.as_ref().is_none_or(|r| r.is_match(&m.body)))
                });
                match hit {
                    Some(e) => {
                        e.consumed = true;
                        let Observed::Wnl(m) = &e.obs else {
                            unreachable!()
                        };
                        Check::Met(format!("{} {}", m.tag, m.body))
                    }
                    None => Check::Pending,
                }
            }
            ExpectKind::Chat {
                kind,
                channel,
                from,
                re,
            } => {
                let names = &self.names;
                let hit = self.log.iter_mut().find(|e| {
                    if e.consumed {
                        return false;
                    }
                    let Observed::Chat(m) = &e.obs else {
                        return false;
                    };
                    if !chat_kind_matches(*kind, m.chat_type) {
                        return false;
                    }
                    if let Some(ch) = channel {
                        if !m
                            .channel
                            .as_deref()
                            .is_some_and(|c| c.eq_ignore_ascii_case(ch))
                        {
                            return false;
                        }
                    }
                    if let Some(who) = from {
                        let name = m
                            .sender_name
                            .as_deref()
                            .or_else(|| names.get(&m.sender_guid).map(String::as_str));
                        if !name.is_some_and(|n| n.eq_ignore_ascii_case(who)) {
                            return false;
                        }
                    }
                    re.as_ref().is_none_or(|r| r.is_match(&m.text))
                });
                match hit {
                    Some(e) => {
                        e.consumed = true;
                        let Observed::Chat(m) = &e.obs else {
                            unreachable!()
                        };
                        let who = m
                            .sender_name
                            .clone()
                            .or_else(|| self.names.get(&m.sender_guid).cloned())
                            .unwrap_or_else(|| format!("guid {:#x}", m.sender_guid));
                        Check::Met(format!("{who}: {}", m.text))
                    }
                    None => Check::Pending,
                }
            }
            ExpectKind::Joined(ch) => {
                let hit = self.log.iter_mut().find(|e| {
                    !e.consumed
                        && matches!(&e.obs, Observed::Joined(c) if c.eq_ignore_ascii_case(ch))
                });
                match hit {
                    Some(e) => {
                        e.consumed = true;
                        Check::Met(format!("joined {ch}"))
                    }
                    None => Check::Pending,
                }
            }
            ExpectKind::VendorItem(entry) => {
                let target = self.target;
                let hit = self.log.iter_mut().find(|e| {
                    !e.consumed
                        && matches!(&e.obs, Observed::Vendor { vendor, .. }
                            if target.is_none_or(|t| t == *vendor))
                });
                match hit {
                    Some(e) => {
                        e.consumed = true;
                        let Observed::Vendor { items, .. } = &e.obs else {
                            unreachable!()
                        };
                        match items.iter().find(|i| i.entry == *entry) {
                            Some(i) => Check::Met(format!(
                                "item {} in vendor slot {} (gold price {}c, stock {})",
                                i.entry,
                                i.slot,
                                i.price,
                                if i.current_count == u32::MAX {
                                    "unlimited".to_string()
                                } else {
                                    i.current_count.to_string()
                                }
                            )),
                            None => Check::Failed(format!(
                                "vendor lists {} item(s), not {entry}: {:?}",
                                items.len(),
                                items.iter().map(|i| i.entry).collect::<Vec<_>>()
                            )),
                        }
                    }
                    None => Check::Pending,
                }
            }
            ExpectKind::Bought(entry) => {
                for e in self.log.iter_mut().filter(|e| !e.consumed) {
                    match &e.obs {
                        Observed::BuyFailed { entry: got, reason } if got == entry => {
                            e.consumed = true;
                            return Check::Failed(format!(
                                "SMSG_BUY_FAILED for {entry}: {}",
                                buy_reason(*reason)
                            ));
                        }
                        Observed::Bought {
                            entry: Some(got),
                            slot,
                            ..
                        } if got == entry => {
                            e.consumed = true;
                            return Check::Met(format!(
                                "SMSG_BUY_ITEM for {entry} (vendor slot {slot})"
                            ));
                        }
                        Observed::ItemCreated(got) if got == entry => {
                            e.consumed = true;
                            return Check::Met(format!("item {entry} arrived in the bags"));
                        }
                        _ => {}
                    }
                }
                Check::Pending
            }
            ExpectKind::Bg { status, map } => {
                let hit = self.log.iter_mut().find(|e| {
                    !e.consumed
                        && matches!(&e.obs, Observed::BgStatus { map_id, status: st }
                            if st == status && map.is_none_or(|m| m == *map_id))
                });
                match hit {
                    Some(e) => {
                        e.consumed = true;
                        let Observed::BgStatus { map_id, .. } = &e.obs else {
                            unreachable!()
                        };
                        Check::Met(format!("battleground map {map_id}: status {status}"))
                    }
                    None => Check::Pending,
                }
            }
            ExpectKind::Map(id) => {
                if self.map == Some(*id) {
                    Check::Met(format!("on map {id}"))
                } else {
                    Check::Pending
                }
            }
            ExpectKind::Near { x, y, z, radius } => match self.self_pos {
                Some(p) if dist(p, [*x, *y, *z]) <= *radius => Check::Met(format!(
                    "at ({:.1}, {:.1}, {:.1}), {:.1} yd from the point",
                    p[0], p[1], p[2], dist(p, [*x, *y, *z])
                )),
                _ => Check::Pending,
            },
            ExpectKind::VisibleEnchant { slot, enchant } => {
                let e = self.self_fields.player_visible_item_enchant(*slot, 0).unwrap_or(0);
                if e == *enchant { Check::Met(format!("slot {slot} shows enchantment {e}")) } else { Check::Pending }
            }
            ExpectKind::Visible { slot, entry } => {
                match self.self_fields.player_visible_item_entry(*slot) {
                    Some(e) if e == *entry => Check::Met(format!("slot {slot} shows item {e}")),
                    None if *entry == 0 => Check::Met(format!("slot {slot} shows nothing")),
                    _ => Check::Pending,
                }
            }
            ExpectKind::Faction(id) => match self.self_fields.unit_faction_template() {
                Some(f) if f == *id => Check::Met(format!("faction template {f}")),
                _ => Check::Pending,
            },
            ExpectKind::Skill(s) => match self.skills().iter().find(|k| k.skill_id == s.id) {
                Some(k) => Check::Met(format!("{} ({}) {}/{}", s.label, s.id, k.value, k.max)),
                None => Check::Pending,
            },
        }
    }

    /// A one-line reason an expectation is still unmet, for the failure report.
    pub fn why_not(&self, what: &ExpectKind) -> String {
        match what {
            ExpectKind::Wnl { tag, .. } => {
                let seen: Vec<String> = self
                    .log
                    .iter()
                    .filter_map(|e| match &e.obs {
                        Observed::Wnl(m) if m.tag == *tag => Some(m.body.clone()),
                        _ => None,
                    })
                    .collect();
                let tags: HashSet<&str> = self
                    .log
                    .iter()
                    .filter_map(|e| match &e.obs {
                        Observed::Wnl(m) => Some(m.tag.as_str()),
                        _ => None,
                    })
                    .collect();
                if seen.is_empty() {
                    let mut t: Vec<&str> = tags.into_iter().collect();
                    t.sort();
                    format!(
                        "no WNL {tag} arrived (WNL tags seen: {})",
                        if t.is_empty() {
                            "none".into()
                        } else {
                            t.join(",")
                        }
                    )
                } else {
                    format!(
                        "{} {tag} line(s) seen, none unconsumed+matching; last: {:?}",
                        seen.len(),
                        seen.last().unwrap()
                    )
                }
            }
            ExpectKind::Skill(s) => {
                let ids: Vec<u16> = self.skills().iter().map(|k| k.skill_id).collect();
                if ids.is_empty() {
                    format!(
                        "{} ({}) missing: no skill fields received yet",
                        s.label, s.id
                    )
                } else {
                    format!(
                        "{} ({}) missing; the player has skills {ids:?}",
                        s.label, s.id
                    )
                }
            }
            ExpectKind::Chat { .. } => {
                let n = self
                    .log
                    .iter()
                    .filter(|e| matches!(e.obs, Observed::Chat(_)))
                    .count();
                format!("no matching chat line ({n} chat line(s) received in total)")
            }
            ExpectKind::Bg { status, map } => {
                let seen: Vec<String> = self
                    .log
                    .iter()
                    .filter_map(|e| match &e.obs {
                        Observed::BgStatus { map_id, status } => Some(format!("{map_id}:{status}")),
                        _ => None,
                    })
                    .collect();
                format!(
                    "no battleground status {status}{} (statuses seen, map:status: {})",
                    map.map(|m| format!(" on map {m}")).unwrap_or_default(),
                    if seen.is_empty() { "none".into() } else { seen.join(" ") }
                )
            }
            ExpectKind::Map(id) => format!("on map {:?}, not {id}", self.map),
            ExpectKind::Near { x, y, z, radius } => match self.self_pos {
                Some(p) => format!(
                    "at ({:.1}, {:.1}, {:.1}) on map {:?}, {:.1} yd from ({x}, {y}, {z}) (allowed {radius})",
                    p[0], p[1], p[2], self.map, dist(p, [*x, *y, *z])
                ),
                None => "no position yet".into(),
            },
            ExpectKind::VisibleEnchant { slot, enchant } => format!(
                "slot {slot} shows enchantment {}, not {enchant}",
                self.self_fields.player_visible_item_enchant(*slot, 0).unwrap_or(0)
            ),
            ExpectKind::Visible { slot, entry } => format!(
                "slot {slot} shows {:?}, not {entry}",
                self.self_fields.player_visible_item_entry(*slot)
            ),
            ExpectKind::Faction(id) => format!(
                "faction template is {:?}, not {id}",
                self.self_fields.unit_faction_template()
            ),
            _ => "nothing matching arrived".into(),
        }
    }
}

fn dist(a: [f32; 3], b: [f32; 3]) -> f32 {
    ((a[0] - b[0]).powi(2) + (a[1] - b[1]).powi(2) + (a[2] - b[2]).powi(2)).sqrt()
}

pub fn buy_reason(code: u8) -> &'static str {
    use messages::buy_result as b;
    match code {
        b::CANT_FIND_ITEM => "can't find item",
        b::ITEM_ALREADY_SOLD => "already sold",
        b::NOT_ENOUGH_MONEY => "not enough money",
        b::SELLER_DONT_LIKE_YOU => "seller doesn't like you",
        b::DISTANCE_TOO_FAR => "too far from the vendor",
        b::ITEM_SOLD_OUT => "sold out",
        b::CANT_CARRY_MORE => "can't carry more",
        b::RANK_REQUIRE => "rank required",
        b::REPUTATION_REQUIRE => "reputation required",
        _ => "unknown reason",
    }
}

pub fn auth_reason(code: u8) -> &'static str {
    match code {
        0x03 => "account banned",
        0x04 => "unknown account or wrong password",
        0x05 => "account already online",
        0x06 => "no game time",
        0x07 => "realmd busy",
        0x08 => "version invalid",
        0x09 => "version invalid (integrity)",
        0x0C => "account suspended",
        0x0E => "no access",
        _ => "refused",
    }
}

/// A connected client. `world` is set once in the world.
pub struct Client {
    pub cfg: ClientConfig,
    pub characters: Vec<Character>,
    pub realm: Option<String>,
    pub timings: Timings,
    pub model: WorldModel,
    session: Option<WorldSession>,
    writer: Option<WorldWriter>,
    rx: Option<Receiver<Inbound>>,
    bridges: Vec<Bridge>,
    next_ping: Instant,
    ping_seq: u32,
    ping_sent: Option<(u32, Instant)>,
    /// The web preset character from `/api/play`, if any.
    pub preset_char: Option<String>,
    pub game_account: String,
    /// The world server address actually dialled (`--world`, else the realm list's).
    pub world_addr: String,
    /// When set, every decoded event is also copied here for a consumer (the autopilot).
    tap: Option<Vec<SessionEvent>>,
}

impl Client {
    fn log(&self, msg: impl AsRef<str>) {
        if self.cfg.verbose {
            eprintln!("[{}] {}", self.cfg.label, msg.as_ref());
        }
    }

    /// Log in (web if configured), SRP6 to realmd, pick the realm, open the world session and read
    /// the character list. Errors here mean "could not get in".
    pub fn connect(cfg: ClientConfig) -> Result<Client> {
        Self::connect_guarded(cfg, &|_| Ok(()))
    }

    /// [`Self::connect`], but `guard` vets the world server address (from `--world` or the realm
    /// list) before it is dialled.
    pub fn connect_guarded(
        cfg: ClientConfig,
        guard: &dyn Fn(&str) -> std::result::Result<(), String>,
    ) -> Result<Client> {
        let mut timings = Timings::default();
        let verbose = cfg.verbose;
        let label = cfg.label.clone();
        let say = |m: String| {
            if verbose {
                eprintln!("[{label}] {m}");
            }
        };

        // 1. Where realmd is, and with which game account.
        let (auth_up, game_user, game_pass, web, mut realm_want, preset) = match &cfg.mode {
            Mode::Tcp { auth_host } => {
                let (h, p) = benilla_protocol::host_port(auth_host, benilla_protocol::AUTH_PORT);
                (
                    Upstream::Tcp {
                        host: h.to_string(),
                        port: p,
                    },
                    cfg.user.clone(),
                    cfg.pass.clone(),
                    None,
                    cfg.realm.clone(),
                    None,
                )
            }
            Mode::Web { url } => {
                let t = Instant::now();
                let origin = Origin::parse(url)?;
                let mut s = WebSession::login(&origin, &cfg.user, &cfg.pass, cfg.timeout)?;
                let cred: PlayCredential = s.play_credential()?;
                timings.web_ms = Some(t.elapsed().as_millis() as u64);
                say(format!(
                    "web login ok; game account {} on realm {:?} via {}",
                    cred.user, cred.realm, cred.host
                ));
                (
                    Upstream::Ws {
                        session: s.clone(),
                        port: benilla_protocol::AUTH_PORT,
                        host: cred.host.clone(),
                    },
                    cred.user.clone(),
                    cred.pass.clone(),
                    Some((s, cred.host.clone())),
                    cfg.realm.clone().or(Some(cred.realm.clone())),
                    cred.character.clone(),
                )
            }
        };

        // 2. realmd: SRP6 logon + realm list, through the bridge.
        let t = Instant::now();
        let auth_bridge = Bridge::start(auth_up, cfg.timeout)?;
        say(format!("realmd via {}", auth_bridge.describe()));
        let logon = benilla_protocol::logon(&auth_bridge.addr(), &game_user, &game_pass)
            .map_err(|e| explain_auth(e, &auth_bridge))?;
        timings.auth_ms = t.elapsed().as_millis() as u64;
        drop(auth_bridge);
        if logon.realms.is_empty() {
            bail!("realmd listed no realms");
        }
        let realm = match realm_want.take() {
            Some(name) => logon
                .realms
                .iter()
                .find(|r| r.name.eq_ignore_ascii_case(&name))
                .or_else(|| (logon.realms.len() == 1).then(|| &logon.realms[0]))
                .ok_or_else(|| {
                    anyhow!(
                        "no realm named {name:?}; realmd lists: {}",
                        logon
                            .realms
                            .iter()
                            .map(|r| r.name.as_str())
                            .collect::<Vec<_>>()
                            .join(", ")
                    )
                })?
                .clone(),
            None => logon.realms[0].clone(),
        };
        say(format!(
            "SRP6 ok; realm {:?} at {}",
            realm.name, realm.address
        ));

        // 3. The world server.
        let t = Instant::now();
        let world_addr = cfg.world.clone().unwrap_or_else(|| realm.address.clone());
        if matches!(cfg.mode, Mode::Tcp { .. }) {
            guard(&world_addr).map_err(|e| anyhow!("world server {world_addr}: {e}"))?;
        }
        let (wh, wp) = benilla_protocol::host_port(&world_addr, benilla_protocol::WORLD_PORT);
        let world_up = match &web {
            None => Upstream::Tcp {
                host: wh.to_string(),
                port: wp,
            },
            // The browser maps the realm list's `host:port` to its own origin's `/ws/{port}`.
            Some((s, host)) => Upstream::Ws {
                session: s.clone(),
                port: wp,
                host: host.clone(),
            },
        };
        let world_bridge = Bridge::start(world_up, cfg.timeout)?;
        say(format!("mangosd via {}", world_bridge.describe()));
        let mut session =
            WorldSession::connect(&world_bridge.addr(), &game_user, logon.session_key)
                .map_err(|e| explain_world(e, &world_bridge))?;
        timings.world_ms = t.elapsed().as_millis() as u64;

        let t = Instant::now();
        let characters = session
            .char_enum()
            .map_err(|e| explain_world(e, &world_bridge))?;
        timings.char_enum_ms = t.elapsed().as_millis() as u64;
        say(format!(
            "{} character(s): {}",
            characters.len(),
            characters
                .iter()
                .map(|c| format!("{} ({})", c.name, c.level))
                .collect::<Vec<_>>()
                .join(", ")
        ));

        Ok(Client {
            cfg,
            characters,
            realm: Some(realm.name.clone()),
            timings,
            model: WorldModel::default(),
            session: Some(session),
            writer: None,
            rx: None,
            bridges: vec![world_bridge],
            next_ping: Instant::now() + PING_INTERVAL,
            ping_seq: 0,
            ping_sent: None,
            preset_char: preset,
            game_account: game_user,
            world_addr,
            tap: None,
        })
    }

    pub fn in_world(&self) -> bool {
        self.writer.is_some() && self.model.in_world && !self.model.logged_out
    }

    pub fn bytes(&self) -> (u64, u64) {
        self.bridges.iter().fold((0, 0), |(u, d), b| {
            let (bu, bd) = b.bytes();
            (u + bu, d + bd)
        })
    }

    /// Enter the world as `name` (or the configured/preset/first character). Waits until the
    /// server confirms (`SMSG_LOGIN_VERIFY_WORLD` or our own create) or refuses.
    pub fn enter_world(&mut self, name: Option<&str>) -> Result<String> {
        let mut session = self
            .session
            .take()
            .ok_or_else(|| anyhow!("not at character select (already entered or logged out)"))?;
        let wanted = name
            .map(str::to_string)
            .or_else(|| self.cfg.character.clone())
            .or_else(|| self.preset_char.clone())
            .or_else(|| {
                self.cfg.fallback_character.clone().filter(|f| {
                    self.characters
                        .iter()
                        .any(|c| c.name.eq_ignore_ascii_case(f))
                })
            });
        // HL_CREATE=<race>:<class> (ChrRaces / ChrClasses ids): make the wanted character first if
        // the account lacks it. For test realms; the name is the one being logged in.
        if let (Some(n), Ok(spec)) = (&wanted, std::env::var("HL_CREATE")) {
            if !self.characters.iter().any(|c| c.name.eq_ignore_ascii_case(n)) {
                let mut it = spec.split(':').map(|v| v.trim().parse::<u8>());
                let (Some(Ok(race)), Some(Ok(class))) = (it.next(), it.next()) else {
                    bail!("HL_CREATE must be <race>:<class>, got {spec:?}");
                };
                let req = messages::CharCreateReq {
                    name: n.clone(),
                    race,
                    class,
                    gender: 0,
                    skin: 0,
                    face: 0,
                    hair_style: 0,
                    hair_color: 0,
                    facial_hair: 0,
                };
                let code = session.create_character(&req)?;
                if code != messages::CHAR_CREATE_SUCCESS {
                    bail!("creating {n} (race {race}, class {class}) failed: SMSG_CHAR_CREATE {code}");
                }
                self.characters = session.char_enum()?;
            }
        }
        let ch = match &wanted {
            Some(n) => self
                .characters
                .iter()
                .find(|c| c.name.eq_ignore_ascii_case(n))
                .ok_or_else(|| {
                    anyhow!(
                        "no character {n:?} on account {}; it has: {}",
                        self.game_account,
                        if self.characters.is_empty() {
                            "none".to_string()
                        } else {
                            self.characters
                                .iter()
                                .map(|c| c.name.as_str())
                                .collect::<Vec<_>>()
                                .join(", ")
                        }
                    )
                })?,
            None => self
                .characters
                .first()
                .ok_or_else(|| anyhow!("account {} has no characters", self.game_account))?,
        }
        .clone();
        let t = Instant::now();
        session.player_login(ch.guid)?;
        session.set_active_mover(ch.guid)?;
        let (mut reader, writer) = session.into_split()?;
        let (tx, rx) = mpsc::channel();
        thread::Builder::new()
            .name(format!("hl-reader-{}", self.cfg.label))
            .spawn(move || loop {
                match reader.poll() {
                    Ok(Poll::Events { events, .. }) => {
                        if !events.is_empty() && tx.send(Inbound::Events(events)).is_err() {
                            break;
                        }
                    }
                    Ok(Poll::Skipped { reason, .. }) => {
                        if tx.send(Inbound::Skipped(reason)).is_err() {
                            break;
                        }
                    }
                    Err(e) => {
                        let _ = tx.send(Inbound::Closed(format!("{e:#}")));
                        break;
                    }
                }
            })?;
        self.writer = Some(writer);
        self.rx = Some(rx);
        self.model = WorldModel {
            self_guid: ch.guid,
            self_name: ch.name.clone(),
            self_pos: Some([ch.position.x, ch.position.y, ch.position.z]),
            map: Some(ch.map),
            ..WorldModel::default()
        };
        self.model.names.insert(ch.guid, ch.name.clone());
        self.next_ping = Instant::now() + PING_INTERVAL;

        let deadline = Instant::now() + self.cfg.timeout;
        while !self.model.in_world {
            if let Some(code) = self.model.login_failed {
                bail!(
                    "the server refused to log {} in (SMSG_CHARACTER_LOGIN_FAILED {code})",
                    ch.name
                );
            }
            if let Some(why) = &self.model.closed {
                bail!("connection closed while entering the world: {why}");
            }
            if Instant::now() >= deadline {
                bail!("no SMSG_LOGIN_VERIFY_WORLD within {:?}", self.cfg.timeout);
            }
            self.pump(Instant::now() + Duration::from_millis(20))?;
        }
        self.timings.enter_world_ms = Some(t.elapsed().as_millis() as u64);
        self.log(format!("in the world as {} ({:#x})", ch.name, ch.guid));
        Ok(ch.name.clone())
    }

    /// Start copying every decoded event into a buffer ([`Self::take_events`]). Turn it on
    /// before [`Self::enter_world`] to see the login burst (spells, our own create).
    pub fn enable_tap(&mut self) {
        self.tap.get_or_insert_with(Vec::new);
    }

    /// The events copied since the last call.
    pub fn take_events(&mut self) -> Vec<SessionEvent> {
        self.tap.as_mut().map(std::mem::take).unwrap_or_default()
    }

    /// The world writer, for callers that send their own packets (the autopilot).
    pub fn writer_mut(&mut self) -> Result<&mut WorldWriter> {
        self.writer()
    }

    fn writer(&mut self) -> Result<&mut WorldWriter> {
        if self.model.logged_out {
            bail!("logged out");
        }
        if let Some(why) = &self.model.closed {
            bail!("connection closed: {why}");
        }
        self.writer
            .as_mut()
            .ok_or_else(|| anyhow!("not in the world (no `login` yet)"))
    }

    /// Process inbound events until `until`, answering what a client must answer.
    pub fn pump(&mut self, until: Instant) -> Result<()> {
        loop {
            let now = Instant::now();
            if self.writer.is_some()
                && self.model.in_world
                && !self.model.logged_out
                && now >= self.next_ping
            {
                self.ping_seq = self.ping_seq.wrapping_add(1);
                let (seq, rtt) = (self.ping_seq, self.model.last_rtt_ms);
                if let Some(w) = self.writer.as_mut() {
                    w.ping(seq, rtt)?;
                }
                self.ping_sent = Some((seq, now));
                self.next_ping = now + PING_INTERVAL;
                self.log(format!("CMSG_PING {seq}"));
            }
            let Some(rx) = &self.rx else {
                if until > now {
                    thread::sleep(until - now);
                }
                return Ok(());
            };
            let wait = until
                .saturating_duration_since(now)
                .min(Duration::from_millis(50))
                .min(
                    self.next_ping
                        .saturating_duration_since(now)
                        .max(Duration::from_millis(1)),
                );
            match rx.recv_timeout(wait) {
                Ok(Inbound::Events(evs)) => {
                    self.model.packets += 1;
                    for ev in evs {
                        self.on_event(ev)?;
                    }
                }
                Ok(Inbound::Skipped(reason)) => {
                    self.model.skipped += 1;
                    self.log(format!("skipped packet: {reason}"));
                }
                Ok(Inbound::Closed(why)) => {
                    if self.model.closed.is_none() {
                        self.log(format!("connection closed: {why}"));
                    }
                    self.model.closed = Some(why);
                    self.rx = None;
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => {
                    self.rx = None;
                }
            }
            if Instant::now() >= until {
                return Ok(());
            }
        }
    }

    fn on_event(&mut self, ev: SessionEvent) -> Result<()> {
        if let Some(t) = self.tap.as_mut() {
            t.push(ev.clone());
        }
        let me = self.model.self_guid;
        match ev {
            SessionEvent::Chat(m) => {
                if self.cfg.verbose {
                    let who = m
                        .sender_name
                        .clone()
                        .or_else(|| self.model.names.get(&m.sender_guid).cloned())
                        .unwrap_or_else(|| format!("{:#x}", m.sender_guid));
                    let ch = m
                        .channel
                        .as_deref()
                        .map(|c| format!("[{c}] "))
                        .unwrap_or_default();
                    eprintln!(
                        "[{}] chat {:#04x} {ch}{who}: {}",
                        self.cfg.label,
                        m.chat_type,
                        m.text.replace('\t', "\\t")
                    );
                }
                let g = m.sender_guid;
                if g != 0 && !self.model.names.contains_key(&g) && self.model.asked_names.insert(g)
                {
                    if let Some(w) = self.writer.as_mut() {
                        w.name_query(g)?;
                    }
                }
                self.model.on_chat(m);
            }
            SessionEvent::Notification { text } | SessionEvent::ServerMessage { text, .. } => {
                self.log(format!("notice: {text}"));
                self.model.on_chat(ChatMessage {
                    chat_type: CHAT_MSG_SYSTEM,
                    language: 0,
                    sender_guid: 0,
                    target_guid: 0,
                    sender_name: None,
                    channel: None,
                    text,
                    chat_tag: 0,
                });
            }
            SessionEvent::ChannelNotify {
                notice, channel, ..
            } => {
                self.log(format!("channel notice {notice:#04x} on {channel}"));
                if notice == messages::channel_notice::YOU_JOINED {
                    self.model.observe(Observed::Joined(channel));
                }
            }
            SessionEvent::PlayerName { guid, name, .. } => {
                self.model.names.insert(guid, name);
            }
            SessionEvent::ObjectCreate {
                guid,
                kind,
                position,
                orientation,
                fields,
                ..
            } => {
                if guid == me {
                    self.model.self_fields.merge(fields);
                    self.model.self_pos = Some(position);
                    self.model.orientation = orientation;
                    self.model.in_world = true;
                } else if kind == EntityKind::Unit {
                    let entry = fields.object_entry();
                    self.model.units.insert(
                        guid,
                        Unit {
                            entry,
                            position,
                            npc_flags: fields.unit_npc_flags(),
                        },
                    );
                }
            }
            SessionEvent::ObjectValues { guid, fields } => {
                if guid == me {
                    self.model.self_fields.merge(fields);
                }
            }
            SessionEvent::ItemCreate { fields, .. } => {
                if let Some(entry) = fields.object_entry() {
                    self.model.observe(Observed::ItemCreated(entry));
                }
            }
            SessionEvent::ObjectMove {
                guid,
                position,
                orientation,
            } => {
                if guid == me {
                    self.model.self_pos = Some(position);
                    self.model.orientation = orientation;
                } else if let Some(u) = self.model.units.get_mut(&guid) {
                    u.position = position;
                }
            }
            SessionEvent::UnitMove { guid, position, .. } => {
                if let Some(u) = self.model.units.get_mut(&guid) {
                    u.position = position;
                }
            }
            SessionEvent::MonsterMove {
                guid, path, start, ..
            } => {
                if let Some(u) = self.model.units.get_mut(&guid) {
                    u.position = path.last().copied().unwrap_or(start);
                }
            }
            SessionEvent::ObjectsRemoved(guids) => {
                for g in guids {
                    self.model.units.remove(&g);
                }
            }
            SessionEvent::ObjectDestroyed(g) => {
                self.model.units.remove(&g);
            }
            SessionEvent::Worldport {
                map_id,
                position,
                orientation,
                needs_ack,
            } => {
                self.model.map = Some(map_id);
                self.model.self_pos = Some(position);
                self.model.orientation = orientation;
                self.model.in_world = true;
                if needs_ack {
                    self.writer()?.worldport_ack()?;
                    self.model.units.clear();
                    self.log(format!("worldport to map {map_id} acked"));
                }
            }
            SessionEvent::Teleport {
                guid,
                counter,
                position,
                orientation,
            } if guid == me => {
                self.model.self_pos = Some(position);
                self.model.orientation = orientation;
                self.writer()?.teleport_ack(guid, counter)?;
                self.log(format!("teleport to {position:?} acked"));
            }
            SessionEvent::ForceSpeedChange {
                guid,
                kind,
                counter,
                speed,
            } if guid == me => {
                let pos = self.model.self_pos.unwrap_or_default();
                let o = self.model.orientation;
                let flags = self.model.move_flags;
                self.writer()?.force_speed_change_ack(
                    kind, guid, counter, speed, flags, pos, o, 0.0, 0, None, None,
                )?;
            }
            SessionEvent::MoveMode {
                guid,
                counter,
                mode,
                apply,
            } if guid == me => {
                let pose = (
                    self.model.self_pos.unwrap_or_default(),
                    self.model.orientation,
                );
                let flags = if apply { mode.flag() } else { 0 };
                self.writer()?
                    .move_mode_ack(guid, counter, mode, apply, flags, pose)?;
            }
            SessionEvent::CinematicTriggered { .. } => {
                self.writer()?.complete_cinematic()?;
            }
            SessionEvent::CharacterLoginFailed { result } => {
                self.model.login_failed = Some(result);
            }
            SessionEvent::LogoutResponse { reason, .. } => {
                if reason != 0 {
                    self.model.logout_refused = Some(reason);
                }
            }
            SessionEvent::LoggedOut => {
                self.model.logged_out = true;
            }
            SessionEvent::Pong { sequence } => {
                if let Some((seq, at)) = self.ping_sent {
                    if seq == sequence {
                        self.model.last_rtt_ms = at.elapsed().as_millis() as u32;
                        self.ping_sent = None;
                    }
                }
            }
            SessionEvent::VendorInventory { vendor, items } => {
                self.model.vendor_lists.insert(vendor, items.clone());
                self.model.observe(Observed::Vendor { vendor, items });
            }
            SessionEvent::VendorBuyResult { vendor, slot, .. } => {
                let entry = self
                    .model
                    .vendor_lists
                    .get(&vendor)
                    .and_then(|l| l.iter().find(|i| i.slot == slot))
                    .map(|i| i.entry);
                self.model.observe(Observed::Bought {
                    vendor,
                    entry,
                    slot,
                });
            }
            SessionEvent::VendorBuyFailed {
                item_entry, reason, ..
            } => {
                self.model.observe(Observed::BuyFailed {
                    entry: item_entry,
                    reason,
                });
            }
            SessionEvent::BattlefieldStatus(st) => {
                self.log(format!(
                    "battlefield status: slot {} map {} status {}",
                    st.slot, st.map_id, st.status
                ));
                if st.map_id != 0 && (st.status == 2 || st.status == 3) {
                    self.model.bg_map = Some(st.map_id);
                }
                self.model.observe(Observed::BgStatus {
                    map_id: st.map_id,
                    status: st.status,
                });
            }
            _ => {}
        }
        Ok(())
    }

    /// Whether the connection is gone (for wait loops).
    pub fn closed(&self) -> Option<&str> {
        self.model.closed.as_deref()
    }

    // ── Actions ────────────────────────────────────────────────────────────────────────────────

    pub fn say(&mut self, text: &str) -> Result<()> {
        self.writer()?.send_chat(text)
    }

    pub fn yell(&mut self, text: &str) -> Result<()> {
        self.writer()?
            .send_message_chat(messages::CHAT_TYPE_YELL, None, None, text)
    }

    pub fn whisper(&mut self, to: &str, text: &str) -> Result<()> {
        self.writer()?
            .send_message_chat(messages::CHAT_TYPE_WHISPER, None, Some(to), text)
    }

    pub fn join(&mut self, channel: &str, password: &str) -> Result<()> {
        self.writer()?.join_channel(channel, password)
    }

    pub fn leave(&mut self, channel: &str) -> Result<()> {
        self.writer()?.leave_channel(channel)
    }

    pub fn say_channel(&mut self, channel: &str, text: &str) -> Result<()> {
        self.writer()?
            .send_message_chat(messages::CHAT_TYPE_CHANNEL, None, Some(channel), text)
    }

    /// A creature with this entry in view becomes the target; `None` until one streams in.
    pub fn try_find_npc(&mut self, entry: u32) -> Option<String> {
        let (guid, u) = self.model.find_unit(entry)?;
        let pos = u.position;
        let flags = u.npc_flags;
        let d = self.model.self_pos.map(|p| dist(p, pos));
        self.model.target = Some(guid);
        Some(format!(
            "entry {entry} guid {guid:#018x} at ({:.1}, {:.1}, {:.1}){} npc_flags {flags:#x}",
            pos[0],
            pos[1],
            pos[2],
            d.map(|d| format!(", {d:.1} yd away")).unwrap_or_default()
        ))
    }

    pub fn units_in_view(&self) -> usize {
        self.model.units.len()
    }

    pub fn target_npc(&mut self, entry: u32) -> Result<String> {
        let (guid, _) = self.model.find_unit(entry).ok_or_else(|| {
            anyhow!("creature {entry} is not in view (use `find npc {entry}` first)")
        })?;
        self.model.target = Some(guid);
        self.writer()?.set_selection(guid)?;
        Ok(format!("selected {guid:#018x}"))
    }

    pub fn target_self(&mut self) -> Result<String> {
        let me = self.model.self_guid;
        if me == 0 {
            bail!("not in the world yet");
        }
        self.model.target = Some(me);
        self.writer()?.set_selection(me)?;
        Ok(format!("selected self {me:#018x}"))
    }

    fn target(&self) -> Result<u64> {
        self.model
            .target
            .ok_or_else(|| anyhow!("no target (use `find npc <entry>` first)"))
    }

    pub fn quest_reward(&mut self, quest: u32, choice: u32) -> Result<String> {
        let t = self.target()?;
        self.writer()?.questgiver_choose_reward(t, quest, choice)?;
        Ok(format!("CMSG_QUESTGIVER_CHOOSE_REWARD quest {quest} choice {choice} to {t:#018x}"))
    }

    pub fn vendor_list(&mut self) -> Result<String> {
        let t = self.target()?;
        self.writer()?.list_inventory(t)?;
        Ok(format!("CMSG_LIST_INVENTORY {t:#018x}"))
    }

    pub fn buy(&mut self, entry: u32, count: u8) -> Result<String> {
        let t = self.target()?;
        self.writer()?.buy_item(t, entry, count)?;
        Ok(format!("CMSG_BUY_ITEM {entry} x{count} from {t:#018x}"))
    }

    pub fn bg_join(&mut self, map_id: u32) -> Result<String> {
        let t = self.target()?;
        self.writer()?.battlemaster_join(t, map_id, 0, false)?;
        Ok(format!("CMSG_BATTLEMASTER_JOIN map {map_id} via {t:#018x}"))
    }

    pub fn bg_accept(&mut self) -> Result<String> {
        let map = self
            .model
            .bg_map
            .ok_or_else(|| anyhow!("no battleground invite yet (expect bg invited first)"))?;
        self.writer()?.battlefield_port(map, true)?;
        Ok(format!("CMSG_BATTLEFIELD_PORT accept map {map}"))
    }

    pub fn bg_leave(&mut self) -> Result<String> {
        let map = self
            .model
            .bg_map
            .ok_or_else(|| anyhow!("not in a battleground"))?;
        self.writer()?.leave_battlefield(map)?;
        Ok(format!("CMSG_LEAVE_BATTLEFIELD map {map}"))
    }

    /// `CMSG_LOGOUT_REQUEST`; completion is [`Self::logout_state`].
    pub fn logout_start(&mut self) -> Result<()> {
        self.writer()?.logout_request()
    }

    /// `Met` once `SMSG_LOGOUT_COMPLETE` arrived (instant when resting or GM, else ~20 s).
    pub fn logout_state(&self) -> Check {
        if self.model.logged_out {
            Check::Met("SMSG_LOGOUT_COMPLETE".into())
        } else if let Some(reason) = self.model.logout_refused {
            Check::Failed(format!(
                "logout refused (reason {reason}: 1 in combat, 2 frozen, 3 falling)"
            ))
        } else {
            Check::Pending
        }
    }

    /// Drop the connection (no logout); the reader thread ends on EOF.
    pub fn close(&mut self) {
        self.writer = None;
        self.session = None;
        for b in &self.bridges {
            b.close();
        }
        self.model.in_world = false;
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        self.close();
    }
}

fn explain_auth(e: anyhow::Error, bridge: &Bridge) -> anyhow::Error {
    if let Some(r) = e.downcast_ref::<AuthReject>() {
        return anyhow!(
            "realmd refused the logon: {} ({:#04x})",
            auth_reason(r.code),
            r.code
        );
    }
    if let Some(up) = bridge.error() {
        return anyhow!("realmd unreachable: {up}");
    }
    e.context("realmd logon")
}

fn explain_world(e: anyhow::Error, bridge: &Bridge) -> anyhow::Error {
    if e.downcast_ref::<WardenRequired>().is_some() {
        return anyhow!(
            "the world server requires Warden, which this client (like wenilla) does not implement"
        );
    }
    if let Some(r) = e.downcast_ref::<WorldAuthReject>() {
        return anyhow!(
            "the world server refused the session: AUTH result {:#04x}",
            r.code
        );
    }
    if let Some(up) = bridge.error() {
        return anyhow!("world server unreachable: {up}");
    }
    e.context("world handshake")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scenario::{Pattern, SkillRef};
    use benilla_protocol::messages::field;

    fn chat(t: u8, guid: u64, channel: Option<&str>, text: &str) -> ChatMessage {
        ChatMessage {
            chat_type: t,
            language: 0,
            sender_guid: guid,
            target_guid: 0,
            sender_name: None,
            channel: channel.map(str::to_string),
            text: text.to_string(),
            chat_tag: 0,
        }
    }

    #[test]
    fn wnl_expectations_consume_in_order() {
        let mut m = WorldModel::default();
        m.on_chat(chat(CHAT_MSG_PARTY, 1, None, "WNL\tHI 1 Quests,Achievements"));
        m.on_chat(chat(CHAT_MSG_PARTY, 1, None, "WNL\tCP 1 1/1 120,5,1"));
        m.on_chat(chat(CHAT_MSG_PARTY, 1, None, "WNL\tCP 2 1/1 70,5,1"));
        let hi = ExpectKind::Wnl {
            tag: "HI".into(),
            re: None,
        };
        assert!(matches!(m.check(&hi), Check::Met(_)));
        assert_eq!(m.check(&hi), Check::Pending, "consumed");
        let cp = ExpectKind::Wnl {
            tag: "CP".into(),
            re: Some(Pattern::new(r"^\d+,\d+,[01]$").unwrap()),
        };
        assert_eq!(m.check(&cp), Check::Met("CP 120,5,1".into()));
        assert_eq!(m.check(&cp), Check::Met("CP 70,5,1".into()));
        assert_eq!(m.check(&cp), Check::Pending);
        assert!(m.why_not(&cp).contains("2 CP line(s) seen"));
    }

    #[test]
    fn channel_from_needs_the_name() {
        let mut m = WorldModel::default();
        m.on_chat(chat(
            CHAT_MSG_CHANNEL,
            0x42,
            Some("OWPersona"),
            "#P 3 ooc Herald~Chronicler",
        ));
        let want = ExpectKind::Chat {
            kind: ChatKind::Channel,
            channel: Some("owpersona".into()),
            from: Some("Herald".into()),
            re: Some(Pattern::new("^#P ").unwrap()),
        };
        assert_eq!(m.check(&want), Check::Pending, "name not known yet");
        m.names.insert(0x42, "Herald".into());
        assert!(matches!(m.check(&want), Check::Met(_)));
    }

    #[test]
    fn skills_come_from_the_descriptor() {
        let mut m = WorldModel::default();
        let base = field::FIELD_PLAYER_SKILL_INFO_1_1;
        // slot 0: Bows (45) 1/5; slot 3: Axes (44) 1/5
        m.self_fields.merge(ObjectFields::from_pairs(&[
            (base, 45),
            (base + 1, 1 | (5 << 16)),
            (base + 9, 44),
            (base + 10, 1 | (5 << 16)),
        ]));
        let bows = ExpectKind::Skill(SkillRef::parse("bows").unwrap());
        assert_eq!(m.check(&bows), Check::Met("bows (45) 1/5".into()));
        let guns = ExpectKind::Skill(SkillRef::parse("guns").unwrap());
        assert_eq!(m.check(&guns), Check::Pending);
        assert!(
            m.why_not(&guns).contains("[45, 44]"),
            "{}",
            m.why_not(&guns)
        );
    }

    #[test]
    fn vendor_and_buy_checks() {
        let mut m = WorldModel {
            target: Some(7),
            ..Default::default()
        };
        let item = |slot, entry| VendorItem {
            slot,
            entry,
            display_id: 0,
            current_count: u32::MAX,
            price: 0,
            max_durability: 0,
            buy_count: 1,
        };
        m.observe(Observed::Vendor {
            vendor: 7,
            items: vec![item(1, 2589)],
        });
        assert!(matches!(
            m.check(&ExpectKind::VendorItem(2589)),
            Check::Met(_)
        ));
        m.observe(Observed::Vendor {
            vendor: 7,
            items: vec![item(1, 1)],
        });
        assert!(matches!(
            m.check(&ExpectKind::VendorItem(2589)),
            Check::Failed(_)
        ));
        m.observe(Observed::BuyFailed {
            entry: 2589,
            reason: messages::buy_result::NOT_ENOUGH_MONEY,
        });
        let Check::Failed(why) = m.check(&ExpectKind::Bought(2589)) else {
            panic!()
        };
        assert!(why.contains("not enough"));
        m.observe(Observed::ItemCreated(2589));
        assert!(matches!(
            m.check(&ExpectKind::Bought(2589)),
            Check::Met(_)
        ));
    }

    #[test]
    fn nearest_unit_by_entry() {
        let mut m = WorldModel {
            self_pos: Some([0.0, 0.0, 0.0]),
            ..Default::default()
        };
        for (g, x) in [(1u64, 50.0f32), (2, 3.0), (3, 10.0)] {
            m.units.insert(
                g,
                Unit {
                    entry: Some(990001),
                    position: [x, 0.0, 0.0],
                    npc_flags: 0x4,
                },
            );
        }
        assert_eq!(m.find_unit(990001).map(|(g, _)| g), Some(2));
        assert!(m.find_unit(1).is_none());
    }
}
