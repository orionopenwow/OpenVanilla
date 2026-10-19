//! Test-only: a scripted 1.12 world server for the brain, in-process and on simulated time.
//!
//! Every server message is built as raw `SMSG_*` bytes (layouts from CMaNGOS classic, as in
//! `tests/e2e.rs`) and decoded with benilla-protocol's own `parse_server` + `decode`, and every
//! command the brain sends is encoded to bytes ([`OutCmd::encode`]) and read back here, so the
//! loop exercises both wire directions. The server keeps the player's position from the
//! `MSG_MOVE_*` stream and enforces interaction ranges (quest giver and loot 5 yd, shots 8-35 yd
//! standing still), so dead reckoning mistakes show up as failures.

use std::collections::VecDeque;

use benilla_protocol::messages::{self, opcode};
use benilla_protocol::wire::write_packed_guid;
use benilla_protocol::SessionEvent;

use super::geom::{dist2, Vec3};
use super::out::OutCmd;

pub const ME: u64 = 0x20;
pub const NPC: u64 = 0xF130_0000_C500_0001;
pub const NPC_ENTRY: u32 = 197;
pub const MOB_ENTRY: u32 = 6;
pub const QUEST: u32 = 7;
pub const GRAVEYARD: Vec3 = [-8960.0, -180.0, 82.0];

fn mob_guid(i: u32) -> u64 {
    0xF130_0000_0600_0000 | u64::from(i)
}

fn f32s(b: &mut Vec<u8>, v: &[f32]) {
    for f in v {
        b.extend_from_slice(&f.to_le_bytes());
    }
}
fn u32s(b: &mut Vec<u8>, v: &[u32]) {
    for x in v {
        b.extend_from_slice(&x.to_le_bytes());
    }
}
fn cstr(b: &mut Vec<u8>, s: &str) {
    b.extend_from_slice(s.as_bytes());
    b.push(0);
}

fn values_block(fields: &mut [(u16, u32)]) -> Vec<u8> {
    fields.sort_by_key(|f| f.0);
    let max = fields.last().unwrap().0;
    let blocks = (max / 32 + 1) as usize;
    let mut masks = vec![0u32; blocks];
    for (i, _) in fields.iter() {
        masks[(*i / 32) as usize] |= 1 << (i % 32);
    }
    let mut b = vec![blocks as u8];
    for m in masks {
        b.extend_from_slice(&m.to_le_bytes());
    }
    for (_, v) in fields.iter() {
        b.extend_from_slice(&v.to_le_bytes());
    }
    b
}

fn create_block(
    guid: u64,
    obj_type: u8,
    pos: Vec3,
    run: f32,
    fields: &mut [(u16, u32)],
) -> Vec<u8> {
    let mut b = vec![2u8];
    write_packed_guid(guid, &mut b).unwrap();
    b.push(obj_type);
    b.push(0x20 | if guid == ME { 0x01 } else { 0 }); // LIVING (+ SELF)
    u32s(&mut b, &[0, 0]);
    f32s(&mut b, &[pos[0], pos[1], pos[2], 0.0]);
    u32s(&mut b, &[0]);
    f32s(&mut b, &[2.5, run, 4.5, 4.722, 2.5, std::f32::consts::PI]);
    b.extend(values_block(fields));
    b
}

fn values_update(guid: u64, fields: &mut [(u16, u32)]) -> Vec<u8> {
    let mut b = vec![0u8];
    write_packed_guid(guid, &mut b).unwrap();
    b.extend(values_block(fields));
    b
}

fn update_object(blocks: Vec<Vec<u8>>) -> Vec<u8> {
    let mut b = (blocks.len() as u32).to_le_bytes().to_vec();
    b.push(0);
    for bl in blocks {
        b.extend(bl);
    }
    b
}

// Field indices (CMaNGOS classic UpdateFields.h; see world.rs).
const F_TYPE: u16 = 2;
const F_ENTRY: u16 = 3;
const F_HEALTH: u16 = 22;
const F_POWER1: u16 = 23;
const F_MAXHEALTH: u16 = 28;
const F_MAXPOWER1: u16 = 29;
const F_LEVEL: u16 = 34;
const F_FACTION: u16 = 35;
const F_BYTES0: u16 = 36;
const F_UNIT_FLAGS: u16 = 46;
const F_RANGED_TIME: u16 = 128;
const F_DYN: u16 = 143;
const F_NPC: u16 = 147;
const F_PLAYER_FLAGS: u16 = 190;
const F_QUEST1: u16 = 198;
const F_XP: u16 = 716;
const F_NEXT_XP: u16 = 717;

#[derive(Debug, Clone)]
pub struct Mob {
    pub guid: u64,
    pub pos: Vec3,
    pub hp: u32,
    pub aggro: bool,
    pub dead: bool,
    pub looted: bool,
    next_hit: u64,
}

#[derive(Debug, Default, Clone, Copy, PartialEq)]
pub enum QState {
    #[default]
    None,
    Taken,
    Complete,
    Rewarded,
}

/// The scripted world.
pub struct FakeServer {
    pub events: VecDeque<SessionEvent>,
    pub player: Vec3,
    pub moving: bool,
    pub still_since: u64,
    pub hp: u32,
    pub max_hp: u32,
    pub xp: u32,
    pub level: u32,
    pub ghost: bool,
    pub npc_pos: Vec3,
    pub mobs: Vec<Mob>,
    pub quest: QState,
    pub kills_needed: u32,
    pub kills: u32,
    /// Damage our shots do, and what a mob hit does to us.
    pub shot_dmg: u32,
    pub mob_dmg: u32,
    auto_shot_target: Option<u64>,
    melee_target: Option<u64>,
    last_shot: u64,
    loot_open: Option<u64>,
    corpse: Option<Vec3>,
    pub died_at: Option<u64>,
    pub log: Vec<(u64, String)>,
    pub heartbeats: Vec<u64>,
    pub violations: Vec<String>,
}

impl FakeServer {
    pub fn new(start: Vec3, npc_pos: Vec3, mob_positions: &[Vec3]) -> FakeServer {
        let mut s = FakeServer {
            events: VecDeque::new(),
            player: start,
            moving: false,
            still_since: 0,
            hp: 60,
            max_hp: 60,
            xp: 0,
            level: 1,
            ghost: false,
            npc_pos,
            mobs: mob_positions
                .iter()
                .enumerate()
                .map(|(i, p)| Mob {
                    guid: mob_guid(i as u32 + 1),
                    pos: *p,
                    hp: 40,
                    aggro: false,
                    dead: false,
                    looted: false,
                    next_hit: 0,
                })
                .collect(),
            quest: QState::None,
            kills_needed: 1,
            kills: 0,
            shot_dmg: 20,
            mob_dmg: 2,
            auto_shot_target: None,
            melee_target: None,
            last_shot: 0,
            loot_open: None,
            corpse: None,
            died_at: None,
            log: vec![],
            heartbeats: vec![],
            violations: vec![],
        };
        s.login();
        s
    }

    fn emit(&mut self, op: u16, body: Vec<u8>) {
        let p = messages::parse_server(op, &body)
            .unwrap_or_else(|e| panic!("fake {op:#x} does not parse: {e}"));
        self.events.extend(benilla_protocol::decode(p));
    }

    fn quest_fields(&self) -> Vec<(u16, u32)> {
        match self.quest {
            QState::None | QState::Rewarded => vec![(F_QUEST1, 0), (F_QUEST1 + 1, 0)],
            QState::Taken | QState::Complete => {
                let state = if self.quest == QState::Complete {
                    1u32 << 24
                } else {
                    0
                };
                vec![(F_QUEST1, QUEST), (F_QUEST1 + 1, self.kills | state)]
            }
        }
    }

    fn login(&mut self) {
        let mut me = vec![
            (0u16, ME as u32),
            (1, 0),
            (F_TYPE, 0x19),
            (F_HEALTH, self.hp),
            (F_MAXHEALTH, self.max_hp),
            (F_POWER1, 80),
            (F_MAXPOWER1, 80),
            (F_LEVEL, 1),
            (F_FACTION, 1),
            (F_BYTES0, 1 | (3 << 8)),
            (F_RANGED_TIME, 2300),
            (F_XP, 0),
            (F_NEXT_XP, 400),
        ];
        me.extend(self.quest_fields());
        let mut npc = vec![
            (0u16, NPC as u32),
            (1, (NPC >> 32) as u32),
            (F_TYPE, 0x09),
            (F_ENTRY, NPC_ENTRY),
            (F_HEALTH, 100),
            (F_MAXHEALTH, 100),
            (F_LEVEL, 10),
            (F_FACTION, 12),
            (F_NPC, 0x3),
        ];
        let mut blocks = vec![
            create_block(ME, 4, self.player, 7.0, &mut me),
            create_block(NPC, 3, self.npc_pos, 8.0, &mut npc),
        ];
        for m in self.mobs.clone() {
            let mut f = vec![
                (0u16, m.guid as u32),
                (1, (m.guid >> 32) as u32),
                (F_TYPE, 0x09),
                (F_ENTRY, MOB_ENTRY),
                (F_HEALTH, m.hp),
                (F_MAXHEALTH, 40),
                (F_LEVEL, 1),
                (F_FACTION, 25),
            ];
            blocks.push(create_block(m.guid, 3, m.pos, 6.0, &mut f));
        }
        self.emit(opcode::SMSG_UPDATE_OBJECT, update_object(blocks));
        // SMSG_INITIAL_SPELLS: Auto Shot, Raptor Strike; no cooldowns.
        let mut b = vec![0u8];
        b.extend_from_slice(&2u16.to_le_bytes());
        for s in [75u16, 2973] {
            b.extend_from_slice(&s.to_le_bytes());
            b.extend_from_slice(&0u16.to_le_bytes());
        }
        b.extend_from_slice(&0u16.to_le_bytes());
        self.emit(opcode::SMSG_INITIAL_SPELLS, b);
    }

    pub fn set_hp(&mut self, hp: u32) {
        self.hp = hp;
        self.me_values(vec![(F_HEALTH, hp)]);
    }

    fn me_values(&mut self, mut f: Vec<(u16, u32)>) {
        self.emit(
            opcode::SMSG_UPDATE_OBJECT,
            update_object(vec![values_update(ME, &mut f)]),
        );
    }

    fn mob_values(&mut self, guid: u64, mut f: Vec<(u16, u32)>) {
        self.emit(
            opcode::SMSG_UPDATE_OBJECT,
            update_object(vec![values_update(guid, &mut f)]),
        );
    }

    fn violation(&mut self, now: u64, what: String) {
        self.log.push((now, format!("VIOLATION {what}")));
        self.violations.push(what);
    }

    /// One command from the client, read back from its wire bytes.
    pub fn handle(&mut self, now: u64, cmd: &OutCmd) {
        let (op, body) = cmd.encode();
        let rd = |b: &[u8], at: usize| u64::from_le_bytes(b[at..at + 8].try_into().unwrap());
        let rd32 = |b: &[u8], at: usize| u32::from_le_bytes(b[at..at + 4].try_into().unwrap());
        if (0xB5..=0xEE).contains(&op) && matches!(cmd, OutCmd::Move { .. }) {
            // Read it the way a server would: as a relayed MSG_MOVE (guid + MovementInfo).
            let mut relay = Vec::new();
            write_packed_guid(ME, &mut relay).unwrap();
            relay.extend_from_slice(&body);
            let p = messages::parse_server(op, &relay).expect("movement parses");
            for e in benilla_protocol::decode(p) {
                if let SessionEvent::UnitMove {
                    position, flags, ..
                } = e
                {
                    let was = self.moving;
                    self.moving = flags & 1 != 0;
                    if was && !self.moving || !was && self.moving {
                        self.still_since = now;
                    }
                    // A fair anticheat: no more than 7 yd/s (+slack) since the last packet.
                    self.player = position;
                }
            }
            if op == opcode::MSG_MOVE_HEARTBEAT {
                self.heartbeats.push(now);
            }
            return;
        }
        self.log.push((now, cmd.label()));
        match op {
            opcode::CMSG_QUESTGIVER_HELLO => {
                let g = rd(&body, 0);
                if g != NPC || dist2(self.player, self.npc_pos) > 5.0 {
                    return self.violation(
                        now,
                        format!("hello from {:.1} yd", dist2(self.player, self.npc_pos)),
                    );
                }
                match self.quest {
                    QState::None => self.details(),
                    QState::Complete => self.offer(),
                    _ => self.emit(opcode::SMSG_GOSSIP_COMPLETE, vec![]),
                }
            }
            opcode::CMSG_QUESTGIVER_QUERY_QUEST => self.details(),
            opcode::CMSG_QUESTGIVER_ACCEPT_QUEST => {
                if rd32(&body, 8) == QUEST && self.quest == QState::None {
                    self.quest = QState::Taken;
                    let f = self.quest_fields();
                    self.me_values(f);
                    self.emit(opcode::SMSG_GOSSIP_COMPLETE, vec![]);
                }
            }
            opcode::CMSG_QUESTGIVER_COMPLETE_QUEST => {
                if self.quest == QState::Complete {
                    self.offer()
                }
            }
            opcode::CMSG_QUESTGIVER_CHOOSE_REWARD => {
                if self.quest == QState::Complete && dist2(self.player, self.npc_pos) <= 5.0 {
                    self.quest = QState::Rewarded;
                    let mut b = Vec::new();
                    u32s(&mut b, &[QUEST, 3, 170, 25, 0]);
                    self.emit(opcode::SMSG_QUESTGIVER_QUEST_COMPLETE, b);
                    self.give_xp(170);
                    let f = self.quest_fields();
                    self.me_values(f);
                }
            }
            opcode::CMSG_CAST_SPELL => {
                let spell = rd32(&body, 0);
                let target = if body.len() > 6 {
                    // mask 0x2 + packed guid
                    let mask = body[6];
                    let mut g = 0u64;
                    let mut at = 7;
                    for i in 0..8 {
                        if mask & (1 << i) != 0 {
                            g |= u64::from(body[at]) << (8 * i);
                            at += 1;
                        }
                    }
                    Some(g)
                } else {
                    None
                };
                if spell == 75 {
                    self.auto_shot_target = target;
                    if let Some(m) = self.mobs.iter_mut().find(|m| Some(m.guid) == target) {
                        m.aggro = true;
                    }
                }
            }
            opcode::CMSG_ATTACKSWING => {
                let g = rd(&body, 0);
                self.melee_target = Some(g);
                if let Some(m) = self.mobs.iter_mut().find(|m| m.guid == g) {
                    m.aggro = true;
                }
                let mut b = ME.to_le_bytes().to_vec();
                b.extend_from_slice(&g.to_le_bytes());
                self.emit(opcode::SMSG_ATTACKSTART, b);
            }
            opcode::CMSG_ATTACKSTOP => self.melee_target = None,
            opcode::CMSG_CANCEL_AUTO_REPEAT_SPELL => self.auto_shot_target = None,
            opcode::CMSG_LOOT => {
                let g = rd(&body, 0);
                let Some(i) = self.mobs.iter().position(|m| m.guid == g) else {
                    return;
                };
                if dist2(self.player, self.mobs[i].pos) > 5.0 {
                    return self.violation(
                        now,
                        format!("loot from {:.1} yd", dist2(self.player, self.mobs[i].pos)),
                    );
                }
                self.loot_open = Some(g);
                let mut b = g.to_le_bytes().to_vec();
                b.push(1); // LOOT_CORPSE
                u32s(&mut b, &[7]); // copper
                b.push(1);
                b.push(0); // slot
                u32s(&mut b, &[2589, 1, 0, 0, 0]); // Linen Cloth
                b.push(0); // ALLOW_LOOT
                self.emit(opcode::SMSG_LOOT_RESPONSE, b);
            }
            opcode::CMSG_AUTOSTORE_LOOT_ITEM => self.emit(opcode::SMSG_LOOT_REMOVED, vec![body[0]]),
            opcode::CMSG_LOOT_MONEY => {
                self.emit(opcode::SMSG_LOOT_MONEY_NOTIFY, 7u32.to_le_bytes().to_vec());
                self.emit(opcode::SMSG_LOOT_CLEAR_MONEY, vec![]);
            }
            opcode::CMSG_LOOT_RELEASE => {
                let g = rd(&body, 0);
                if let Some(m) = self.mobs.iter_mut().find(|m| m.guid == g) {
                    m.looted = true;
                }
                self.loot_open = None;
                let mut b = g.to_le_bytes().to_vec();
                b.push(1);
                self.emit(opcode::SMSG_LOOT_RELEASE_RESPONSE, b);
                self.mob_values(g, vec![(F_DYN, 0x20)]);
            }
            opcode::CMSG_REPOP_REQUEST => {
                if self.hp == 0 && !self.ghost {
                    self.ghost = true;
                    self.corpse = Some(self.player);
                    self.hp = 1;
                    self.me_values(vec![(F_HEALTH, 1), (F_PLAYER_FLAGS, 0x10)]);
                    // Teleport to the graveyard (near teleport, MSG_MOVE_TELEPORT_ACK).
                    let mut b = Vec::new();
                    write_packed_guid(ME, &mut b).unwrap();
                    u32s(&mut b, &[1, 0, 1]);
                    f32s(&mut b, &[GRAVEYARD[0], GRAVEYARD[1], GRAVEYARD[2], 0.0]);
                    u32s(&mut b, &[0]);
                    self.emit(opcode::MSG_MOVE_TELEPORT_ACK, b);
                    self.player = GRAVEYARD;
                }
            }
            opcode::MSG_CORPSE_QUERY => {
                if let Some(c) = self.corpse {
                    let mut b = vec![1u8];
                    u32s(&mut b, &[0]);
                    f32s(&mut b, &c);
                    u32s(&mut b, &[0]);
                    self.emit(opcode::MSG_CORPSE_QUERY, b);
                }
            }
            opcode::CMSG_RECLAIM_CORPSE => {
                let ok = self.ghost
                    && self.corpse.is_some_and(|c| dist2(c, self.player) <= 39.0)
                    && self.died_at.is_some_and(|t| now >= t + 30_000);
                if ok {
                    self.ghost = false;
                    self.hp = self.max_hp / 2;
                    let hp = self.hp;
                    self.me_values(vec![(F_HEALTH, hp), (F_PLAYER_FLAGS, 0)]);
                } else {
                    self.violation(now, "early or distant reclaim".into());
                }
            }
            opcode::CMSG_STANDSTATECHANGE => {}
            _ => {}
        }
    }

    fn details(&mut self) {
        let mut b = NPC.to_le_bytes().to_vec();
        u32s(&mut b, &[QUEST]);
        cstr(&mut b, "Kobold Camp Cleanup");
        cstr(&mut b, "Kill kobolds.");
        cstr(&mut b, "Slay a Kobold Vermin.");
        u32s(&mut b, &[0, 0, 0, 25, 0, 4]);
        for _ in 0..4 {
            u32s(&mut b, &[0, 0]);
        }
        self.emit(opcode::SMSG_QUESTGIVER_QUEST_DETAILS, b);
    }

    fn offer(&mut self) {
        let mut b = NPC.to_le_bytes().to_vec();
        u32s(&mut b, &[QUEST]);
        cstr(&mut b, "Kobold Camp Cleanup");
        cstr(&mut b, "Well done.");
        u32s(&mut b, &[1, 0, 0, 0, 25, 0, 0]);
        self.emit(opcode::SMSG_QUESTGIVER_OFFER_REWARD, b);
    }

    fn give_xp(&mut self, amount: u32) {
        self.xp += amount;
        if self.xp >= 400 {
            self.xp -= 400;
            self.level += 1;
        }
        let (xp, lvl) = (self.xp, self.level);
        self.me_values(vec![(F_XP, xp), (F_LEVEL, lvl), (F_NEXT_XP, 400)]);
    }

    /// Advance the world to `now`: shots land, mobs chase and hit, deaths happen.
    pub fn update(&mut self, now: u64) {
        // Auto Shot: every 2.3 s after standing still for 0.5 s, 8-35 yd.
        if let Some(t) = self.auto_shot_target {
            if let Some(i) = self.mobs.iter().position(|m| m.guid == t && !m.dead) {
                let d = dist2(self.player, self.mobs[i].pos);
                if !self.moving
                    && now >= self.still_since + 500
                    && now >= self.last_shot + 2_300
                    && (8.0..=35.0).contains(&d)
                    && self.hp > 0
                {
                    self.last_shot = now;
                    let mut b = Vec::new();
                    write_packed_guid(ME, &mut b).unwrap();
                    write_packed_guid(ME, &mut b).unwrap();
                    u32s(&mut b, &[75]);
                    b.extend_from_slice(&0u16.to_le_bytes());
                    b.push(1);
                    b.extend_from_slice(&t.to_le_bytes());
                    b.push(0);
                    b.extend_from_slice(&2u16.to_le_bytes());
                    write_packed_guid(t, &mut b).unwrap();
                    self.emit(opcode::SMSG_SPELL_GO, b);
                    self.damage(now, i, self.shot_dmg);
                }
            }
        }
        // Melee: one swing per 2 s at 5 yd.
        if let Some(t) = self.melee_target {
            if let Some(i) = self.mobs.iter().position(|m| m.guid == t && !m.dead) {
                if dist2(self.player, self.mobs[i].pos) <= 5.0 && now >= self.last_shot + 2_000 {
                    self.last_shot = now;
                    self.damage(now, i, 10);
                }
            }
        }
        // Mobs chase at 6 yd/s and hit every 2 s.
        for i in 0..self.mobs.len() {
            let m = self.mobs[i].clone();
            if !m.aggro || m.dead || self.ghost || self.hp == 0 {
                continue;
            }
            let d = dist2(self.player, m.pos);
            if d > 4.0 {
                let step = (6.0 * 0.15f32).min(d - 3.5);
                let dir = [
                    (self.player[0] - m.pos[0]) / d,
                    (self.player[1] - m.pos[1]) / d,
                ];
                let np = [
                    m.pos[0] + dir[0] * step,
                    m.pos[1] + dir[1] * step,
                    self.player[2],
                ];
                self.mobs[i].pos = np;
                // SMSG_MONSTER_MOVE: a one-point hop.
                let mut b = Vec::new();
                write_packed_guid(m.guid, &mut b).unwrap();
                f32s(&mut b, &m.pos);
                u32s(&mut b, &[1]);
                b.push(0);
                u32s(&mut b, &[0x100, 150, 1]);
                f32s(&mut b, &np);
                self.emit(opcode::SMSG_MONSTER_MOVE, b);
            } else if now >= m.next_hit {
                self.mobs[i].next_hit = now + 2_000;
                if m.next_hit == 0 {
                    let mut b = m.guid.to_le_bytes().to_vec();
                    b.extend_from_slice(&ME.to_le_bytes());
                    self.emit(opcode::SMSG_ATTACKSTART, b);
                }
                self.hp = self.hp.saturating_sub(self.mob_dmg);
                let hp = self.hp;
                self.me_values(vec![(F_HEALTH, hp)]);
                if hp == 0 {
                    self.died_at = Some(now);
                    self.auto_shot_target = None;
                    self.melee_target = None;
                    for m in &mut self.mobs {
                        m.aggro = false;
                    }
                    self.log.push((now, "player died".into()));
                }
            }
        }
        // Out of combat regen: 1 hp/s every second.
        if self.hp > 0
            && !self.ghost
            && self.mobs.iter().all(|m| !m.aggro || m.dead)
            && now % 1_000 < 150
            && self.hp < self.max_hp
        {
            self.hp = (self.hp + 3).min(self.max_hp);
            let hp = self.hp;
            self.me_values(vec![(F_HEALTH, hp)]);
        }
    }

    fn damage(&mut self, _now: u64, i: usize, dmg: u32) {
        let g = self.mobs[i].guid;
        self.mobs[i].hp = self.mobs[i].hp.saturating_sub(dmg);
        let hp = self.mobs[i].hp;
        if hp > 0 {
            self.mob_values(g, vec![(F_HEALTH, hp), (F_UNIT_FLAGS, 0x80000)]);
            return;
        }
        self.mobs[i].dead = true;
        self.auto_shot_target = None;
        self.melee_target = None;
        self.mob_values(
            g,
            vec![(F_HEALTH, 0), (F_DYN, 0x1 | 0x20), (F_UNIT_FLAGS, 0)],
        );
        let mut b = g.to_le_bytes().to_vec();
        u32s(&mut b, &[50]);
        b.push(0);
        u32s(&mut b, &[50]);
        f32s(&mut b, &[1.0]);
        self.emit(opcode::SMSG_LOG_XPGAIN, b);
        self.give_xp(50);
        if self.quest == QState::Taken {
            self.kills += 1;
            let mut b = Vec::new();
            u32s(&mut b, &[QUEST, MOB_ENTRY, self.kills, self.kills_needed]);
            b.extend_from_slice(&g.to_le_bytes());
            self.emit(opcode::SMSG_QUESTUPDATE_ADD_KILL, b);
            if self.kills >= self.kills_needed {
                self.quest = QState::Complete;
            }
            let f = self.quest_fields();
            self.me_values(f);
        }
    }
}
