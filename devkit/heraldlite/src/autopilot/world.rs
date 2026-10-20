//! The autopilot's object manager: units, players, game objects, items and corpses from
//! `SMSG_UPDATE_OBJECT`, our own player state, the spell book and cooldowns, the quest log, and the
//! last NPC dialogs and loot window. It is built only from benilla-protocol's decoded
//! [`SessionEvent`]s, so tests can feed it scripted packets without a server.
//!
//! Field indices are benilla's accessors; the ones read here were checked against CMaNGOS classic
//! `UpdateFields.h` (UNIT_END = 0xB6 + OBJECT_END: health 22, level 34, faction template 35,
//! flags 46, dynamic flags 143, npc flags 147, target 16, PLAYER_QUEST_LOG_1_1 198, inventory 486,
//! backpack 532, XP 716/717, coinage 1176).
//!
//! One deviation from benilla: CMaNGOS classic sets `UNIT_DYNFLAG_TAPPED` (0x4) per viewer only
//! when the creature is tapped by *someone else* (`Object.cpp` BuildValuesUpdate); 0x8 is
//! `UNIT_DYNFLAG_ROOTED` there, not "tapped by me". So "tapped by another" is just bit 0x4.

use std::collections::{BTreeSet, HashMap, HashSet, VecDeque};

use benilla_protocol::messages::{
    quest_slot_state, LootItem, QuestDetails, QuestGiverList, QuestOfferReward, QuestRequestItems,
    PLAYER_QUEST_LOG_SLOTS,
};
use benilla_protocol::{EntityKind, ObjectFields, SessionEvent};

use super::geom::{along, dist2, path_len, Vec3};

pub const UNIT_DYNFLAG_LOOTABLE: u32 = 0x01;
pub const UNIT_DYNFLAG_TAPPED: u32 = 0x04;
pub const UNIT_DYNFLAG_DEAD: u32 = 0x20;
pub const UNIT_FLAG_PLAYER_CONTROLLED: u32 = 0x0000_0008;
pub const UNIT_FLAG_IMMUNE_TO_PLAYER: u32 = 0x0000_0100;
pub const UNIT_FLAG_IN_COMBAT: u32 = 0x0008_0000;
pub const UNIT_FLAG_UNTARGETABLE: u32 = 0x0001_0000;
pub const UNIT_FLAG_UNINTERACTIBLE: u32 = 0x0200_0000;
pub const UNIT_NPC_FLAG_GOSSIP: u32 = 0x01;
pub const UNIT_NPC_FLAG_QUESTGIVER: u32 = 0x02;
pub const UNIT_NPC_FLAG_VENDOR: u32 = 0x04;
pub const PLAYER_FLAGS_GHOST: u32 = 0x10;
/// `GAMEOBJECT_TYPE_CHEST` / `_QUESTGIVER` / `_GOOBER` (CMaNGOS `SharedDefines.h`).
pub const GO_TYPE_QUESTGIVER: i32 = 2;
pub const GO_TYPE_CHEST: i32 = 3;
pub const GO_TYPE_GOOBER: i32 = 10;

/// A server path a creature is walking, so its position can be read at any time.
#[derive(Debug, Clone)]
pub struct Spline {
    pub points: Vec<Vec3>,
    pub t0_ms: u64,
    pub duration_ms: u32,
}

#[derive(Debug, Clone)]
pub struct Unit {
    pub guid: u64,
    pub is_player: bool,
    pub pos: Vec3,
    pub orientation: f32,
    pub spline: Option<Spline>,
    pub fields: ObjectFields,
    pub run_speed: f32,
    /// When we last saw it change (for "stale" checks).
    pub seen_ms: u64,
}

impl Unit {
    pub fn entry(&self) -> u32 {
        self.fields.object_entry().unwrap_or(0)
    }
    pub fn health(&self) -> u32 {
        self.fields.unit_health().unwrap_or(1)
    }
    pub fn max_health(&self) -> u32 {
        self.fields.unit_max_health().unwrap_or(1).max(1)
    }
    pub fn hp_pct(&self) -> f32 {
        self.health() as f32 / self.max_health() as f32
    }
    pub fn level(&self) -> u32 {
        self.fields.unit_level().unwrap_or(1)
    }
    pub fn is_dead(&self) -> bool {
        self.fields.unit_health() == Some(0) || self.dyn_flags() & UNIT_DYNFLAG_DEAD != 0
    }
    pub fn dyn_flags(&self) -> u32 {
        self.fields.unit_dynamic_flags()
    }
    pub fn unit_flags(&self) -> u32 {
        self.fields.unit_flags()
    }
    pub fn npc_flags(&self) -> u32 {
        self.fields.unit_npc_flags()
    }
    /// Lootable by us (CMaNGOS strips the bit per viewer).
    pub fn lootable(&self) -> bool {
        self.dyn_flags() & UNIT_DYNFLAG_LOOTABLE != 0
    }
    /// Tapped by someone other than us (CMaNGOS classic semantics, see the module docs).
    pub fn tapped_by_other(&self) -> bool {
        self.dyn_flags() & UNIT_DYNFLAG_TAPPED != 0
    }
    pub fn in_combat(&self) -> bool {
        self.unit_flags() & UNIT_FLAG_IN_COMBAT != 0
    }
    pub fn target(&self) -> u64 {
        self.fields.unit_target().unwrap_or(0)
    }
    pub fn faction_template(&self) -> u32 {
        self.fields.unit_faction_template().unwrap_or(0)
    }
    pub fn has_aura(&self, spell: u32) -> bool {
        self.fields.unit_aura_ids().any(|a| a == spell)
    }
    /// Where it is at `now_ms`, following its server path if it has one.
    pub fn pos_at(&self, now_ms: u64) -> Vec3 {
        match &self.spline {
            Some(s) if s.points.len() >= 2 && s.duration_ms > 0 => {
                let f = ((now_ms.saturating_sub(s.t0_ms)) as f32 / s.duration_ms as f32).min(1.0);
                along(&s.points, f * path_len(&s.points)).unwrap_or(self.pos)
            }
            _ => self.pos,
        }
    }
}

#[derive(Debug, Clone)]
pub struct GameObj {
    pub guid: u64,
    pub entry: u32,
    pub pos: Vec3,
    pub fields: ObjectFields,
}

impl GameObj {
    pub fn go_type(&self) -> i32 {
        self.fields.gameobject_type_id()
    }
}

#[derive(Debug, Clone)]
pub struct Item {
    pub guid: u64,
    pub entry: u32,
    pub fields: ObjectFields,
}

impl Item {
    pub fn count(&self) -> u32 {
        self.fields.item_stack_count().unwrap_or(1)
    }
}

/// One bag position holding an item, as `CMSG_USE_ITEM` addresses it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BagSlot {
    /// 255 for the backpack, else the bag's inventory slot (19-22).
    pub bag: u8,
    /// Backpack: 23-38; a bag: 0-based.
    pub slot: u8,
    pub guid: u64,
    pub entry: u32,
    pub count: u32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct LootWindow {
    pub guid: u64,
    pub gold: u32,
    pub items: Vec<LootItem>,
    pub opened_ms: u64,
}

/// The last NPC panel the server opened.
#[derive(Debug, Clone, PartialEq)]
pub enum Dialog {
    Gossip {
        npc: u64,
        options: Vec<(u32, u8, String)>,
        quests: Vec<(u32, u32)>,
    },
    QuestList(QuestGiverList),
    Details(QuestDetails),
    RequestItems(QuestRequestItems),
    OfferReward(QuestOfferReward),
}

/// Things worth a line in the run log, drained by the brain each tick.
#[derive(Debug, Clone, PartialEq)]
pub enum Note {
    XpGain {
        amount: u32,
        victim: u64,
        kill: bool,
    },
    LevelUp(u32),
    QuestObjective {
        quest: u32,
        entry: u32,
        count: u32,
        required: u32,
    },
    QuestItem {
        item: u32,
        count: u32,
    },
    QuestObjectivesComplete(u32),
    QuestRewarded {
        quest: u32,
        xp: u32,
        money: u32,
    },
    QuestInvalid(u32),
    QuestFailed {
        quest: u32,
        reason: u32,
    },
    QuestLogFull,
    CastFailed {
        spell: u32,
        reason: u8,
    },
    AttackError(String),
    LootError {
        guid: u64,
        error: u8,
    },
    ItemReceived {
        entry: u32,
        count: u32,
    },
    Money(u32),
    Teleported(Vec3),
    Died,
    Ghost,
    Resurrected,
    CorpseAt(Vec3),
    ReclaimDelay(u32),
    Closed(String),
}

#[derive(Debug, Default)]
pub struct World {
    pub me: u64,
    pub fields: ObjectFields,
    pub pos: Vec3,
    pub orientation: f32,
    pub map: u32,
    pub run_speed: f32,
    pub rooted: bool,
    pub in_world: bool,
    pub units: HashMap<u64, Unit>,
    pub gos: HashMap<u64, GameObj>,
    pub items: HashMap<u64, Item>,
    /// Corpse guid -> (owner, position).
    pub corpses: HashMap<u64, (u64, Vec3)>,
    pub spells: BTreeSet<u32>,
    /// Spell id -> ready-at (ms).
    pub cooldowns: HashMap<u32, u64>,
    /// Units that swung at us or announced an attack on us, and when last.
    pub attackers: HashMap<u64, u64>,
    /// Our melee auto-attack victim (`SMSG_ATTACKSTART` from us).
    pub melee_victim: Option<u64>,
    /// When our last Auto Shot left the bow (`SMSG_SPELL_GO` from us, spell 75).
    pub last_shot_ms: Option<u64>,
    pub shots: u32,
    pub dialog: Option<Dialog>,
    pub gossip_closed_ms: Option<u64>,
    pub loot: Option<LootWindow>,
    pub loot_released: Option<u64>,
    pub corpse_pos: Option<Vec3>,
    pub quest_status: HashMap<u64, u32>,
    pub notes: VecDeque<Note>,
    pub item_templates: HashSet<u32>,
    pub closed: Option<String>,
    was_dead: bool,
    was_ghost: bool,
    /// Every ground point we have seen (units, objects, ourselves): a crude height map.
    pub ground_samples: Vec<Vec3>,
}

impl World {
    pub fn new(me: u64, pos: Vec3, map: u32) -> World {
        World {
            me,
            pos,
            map,
            run_speed: 7.0,
            ..Default::default()
        }
    }

    // ── our own state ─────────────────────────────────────────────────────────────────────────

    pub fn health(&self) -> u32 {
        self.fields.unit_health().unwrap_or(1)
    }
    pub fn max_health(&self) -> u32 {
        self.fields.unit_max_health().unwrap_or(1).max(1)
    }
    pub fn hp_pct(&self) -> f32 {
        self.health() as f32 / self.max_health() as f32
    }
    pub fn mana(&self) -> u32 {
        self.fields.unit_power(0).unwrap_or(0)
    }
    pub fn max_mana(&self) -> u32 {
        self.fields.unit_max_power(0).unwrap_or(0)
    }
    /// Mana fraction; 1.0 for a class without mana.
    pub fn mana_pct(&self) -> f32 {
        let m = self.max_mana();
        if m == 0 {
            1.0
        } else {
            self.mana() as f32 / m as f32
        }
    }
    pub fn level(&self) -> u32 {
        self.fields.unit_level().unwrap_or(1)
    }
    pub fn xp(&self) -> u32 {
        self.fields.player_xp().unwrap_or(0)
    }
    pub fn next_level_xp(&self) -> u32 {
        self.fields.player_next_level_xp().unwrap_or(0)
    }
    pub fn money(&self) -> u32 {
        self.fields.player_money().unwrap_or(0)
    }
    pub fn class(&self) -> u8 {
        self.fields.unit_class().unwrap_or(0)
    }
    pub fn is_ghost(&self) -> bool {
        self.fields.player_flags() & PLAYER_FLAGS_GHOST != 0
    }
    /// Dead and not yet released.
    pub fn is_dead_body(&self) -> bool {
        self.fields.unit_health() == Some(0) && !self.is_ghost()
    }
    pub fn is_sitting(&self) -> bool {
        self.fields.unit_stand_state() != 0
    }
    pub fn has_aura(&self, spell: u32) -> bool {
        self.fields.unit_aura_ids().any(|a| a == spell)
    }
    pub fn in_combat(&self) -> bool {
        self.fields.unit_flags() & UNIT_FLAG_IN_COMBAT != 0
    }

    pub fn spell_ready(&self, spell: u32, now_ms: u64) -> bool {
        self.cooldowns.get(&spell).is_none_or(|&t| now_ms >= t)
    }

    /// Our quest log: `(slot, quest id, counters, complete, failed)` for each used slot.
    pub fn quest_log(&self) -> Vec<QuestEntry> {
        (0..PLAYER_QUEST_LOG_SLOTS)
            .filter_map(|s| self.fields.player_quest_log(s))
            .filter(|q| q.quest_id != 0)
            .map(|q| QuestEntry {
                quest: q.quest_id,
                counters: q.counters,
                complete: q.state & quest_slot_state::COMPLETE != 0,
                failed: q.state & quest_slot_state::FAIL != 0,
            })
            .collect()
    }

    pub fn quest(&self, id: u32) -> Option<QuestEntry> {
        self.quest_log().into_iter().find(|q| q.quest == id)
    }

    /// Items in the backpack and equipped bags.
    pub fn bag_items(&self) -> Vec<BagSlot> {
        let mut out = Vec::new();
        let mut push = |bag: u8, slot: u8, guid: u64| {
            if guid == 0 {
                return;
            }
            if let Some(it) = self.items.get(&guid) {
                out.push(BagSlot {
                    bag,
                    slot,
                    guid,
                    entry: it.entry,
                    count: it.count(),
                });
            }
        };
        for i in 0..16u8 {
            if let Some(g) = self.fields.player_pack_slot(i) {
                push(255, 23 + i, g);
            }
        }
        for b in 19..23u8 {
            let Some(bag) = self.fields.player_inv_slot(b).filter(|g| *g != 0) else {
                continue;
            };
            let Some(bag_item) = self.items.get(&bag) else {
                continue;
            };
            let n = bag_item.fields.container_num_slots().unwrap_or(0).min(36) as u8;
            for j in 0..n {
                if let Some(g) = bag_item.fields.container_slot(j) {
                    push(b, j, g);
                }
            }
        }
        out
    }

    pub fn count_item(&self, entry: u32) -> u32 {
        self.bag_items()
            .iter()
            .filter(|b| b.entry == entry)
            .map(|b| b.count)
            .sum()
    }

    pub fn unit(&self, guid: u64) -> Option<&Unit> {
        self.units.get(&guid)
    }

    /// Units attacking us now: those that hit us or started attacking us in the last 8 s and
    /// are still alive and in view.
    pub fn live_attackers(&self, now_ms: u64) -> Vec<u64> {
        let mut v: Vec<u64> = self
            .attackers
            .iter()
            .filter(|(g, t)| {
                now_ms.saturating_sub(**t) < 8_000
                    && self.units.get(g).is_some_and(|u| !u.is_dead())
            })
            .map(|(g, _)| *g)
            .collect();
        // Also any creature that targets us and is in combat.
        for (g, u) in &self.units {
            if !u.is_player
                && u.target() == self.me
                && u.in_combat()
                && !u.is_dead()
                && !v.contains(g)
            {
                v.push(*g);
            }
        }
        v.sort();
        v
    }

    /// Ground height estimate at (x, y): the inverse-distance mean of the 4 nearest samples
    /// within 40 yd (units walk on the ground, so their z is a good sample).
    pub fn ground_z(&self, x: f32, y: f32) -> Option<f32> {
        let p = [x, y, 0.0];
        let mut near: Vec<(f32, f32)> = self
            .ground_samples
            .iter()
            .map(|s| (dist2(p, *s), s[2]))
            .filter(|(d, _)| *d < 40.0)
            .collect();
        if near.is_empty() {
            return None;
        }
        near.sort_by(|a, b| a.0.total_cmp(&b.0));
        near.truncate(4);
        let (mut num, mut den) = (0.0, 0.0);
        for (d, z) in near {
            let w = 1.0 / (d + 0.5);
            num += w * z;
            den += w;
        }
        Some(num / den)
    }

    fn sample(&mut self, p: Vec3) {
        // Keep it bounded; a 2 yd grid is plenty.
        if self.ground_samples.iter().any(|s| dist2(*s, p) < 2.0) {
            return;
        }
        if self.ground_samples.len() >= 20_000 {
            self.ground_samples.remove(0);
        }
        self.ground_samples.push(p);
    }

    // ── events ────────────────────────────────────────────────────────────────────────────────

    /// Fold one decoded server event into the model.
    pub fn apply(&mut self, ev: &SessionEvent, now_ms: u64) {
        let me = self.me;
        match ev {
            SessionEvent::ObjectCreate {
                guid,
                kind,
                position,
                orientation,
                speeds,
                fields,
                ..
            } => {
                let guid = *guid;
                if guid == me {
                    self.fields.merge(fields.clone());
                    self.pos = *position;
                    self.orientation = *orientation;
                    if let Some(s) = speeds {
                        self.run_speed = s.run;
                    }
                    self.in_world = true;
                    self.sample(*position);
                    return;
                }
                match kind {
                    EntityKind::Unit | EntityKind::Player => {
                        self.units.insert(
                            guid,
                            Unit {
                                guid,
                                is_player: *kind == EntityKind::Player,
                                pos: *position,
                                orientation: *orientation,
                                spline: None,
                                fields: fields.clone(),
                                run_speed: speeds.map(|s| s.run).unwrap_or(7.0),
                                seen_ms: now_ms,
                            },
                        );
                        self.sample(*position);
                    }
                    EntityKind::GameObject => {
                        let pos = fields
                            .gameobject_position()
                            .map(|(v, _)| [v.x, v.y, v.z])
                            .unwrap_or(*position);
                        self.gos.insert(
                            guid,
                            GameObj {
                                guid,
                                entry: fields.object_entry().unwrap_or(0),
                                pos,
                                fields: fields.clone(),
                            },
                        );
                        self.sample(pos);
                    }
                    EntityKind::Corpse => {
                        let owner = fields.corpse_owner().unwrap_or(0);
                        self.corpses.insert(guid, (owner, *position));
                        if owner == me {
                            self.corpse_pos = Some(*position);
                        }
                    }
                    _ => {}
                }
            }
            SessionEvent::ItemCreate { guid, fields, .. } => {
                self.items.insert(
                    *guid,
                    Item {
                        guid: *guid,
                        entry: fields.object_entry().unwrap_or(0),
                        fields: fields.clone(),
                    },
                );
            }
            SessionEvent::ObjectValues { guid, fields } => {
                if *guid == me {
                    self.fields.merge(fields.clone());
                } else if let Some(u) = self.units.get_mut(guid) {
                    u.fields.merge(fields.clone());
                    u.seen_ms = now_ms;
                } else if let Some(i) = self.items.get_mut(guid) {
                    i.fields.merge(fields.clone());
                } else if let Some(g) = self.gos.get_mut(guid) {
                    g.fields.merge(fields.clone());
                }
            }
            SessionEvent::ObjectMove {
                guid,
                position,
                orientation,
            } => {
                if *guid == me {
                    self.pos = *position;
                    self.orientation = *orientation;
                } else if let Some(u) = self.units.get_mut(guid) {
                    u.pos = *position;
                    u.orientation = *orientation;
                    u.spline = None;
                    u.seen_ms = now_ms;
                }
                self.sample(*position);
            }
            SessionEvent::UnitMove {
                guid,
                position,
                orientation,
                ..
            } => {
                if let Some(u) = self.units.get_mut(guid) {
                    u.pos = *position;
                    u.orientation = *orientation;
                    u.spline = None;
                    u.seen_ms = now_ms;
                }
                self.sample(*position);
            }
            SessionEvent::MonsterMove {
                guid,
                transport: None,
                start,
                path,
                stop,
                duration_ms,
                ..
            } => {
                if let Some(u) = self.units.get_mut(guid) {
                    u.seen_ms = now_ms;
                    if *stop || path.is_empty() {
                        u.pos = *start;
                        u.spline = None;
                    } else {
                        // benilla's path already leads with `start`.
                        let mut pts = path.clone();
                        if pts.first() != Some(start) {
                            pts.insert(0, *start);
                        }
                        u.pos = *pts.last().unwrap();
                        u.spline = Some(Spline {
                            points: pts,
                            t0_ms: now_ms,
                            duration_ms: *duration_ms,
                        });
                    }
                }
                self.sample(*start);
            }
            SessionEvent::ObjectsRemoved(gs) => {
                for g in gs {
                    self.forget(*g);
                }
            }
            SessionEvent::ObjectDestroyed(g) => self.forget(*g),
            SessionEvent::Teleport {
                guid,
                position,
                orientation,
                ..
            } if *guid == me => {
                self.pos = *position;
                self.orientation = *orientation;
                self.notes.push_back(Note::Teleported(*position));
            }
            SessionEvent::Worldport {
                map_id,
                position,
                orientation,
                needs_ack,
            } => {
                self.map = *map_id;
                self.pos = *position;
                self.orientation = *orientation;
                self.in_world = true;
                if *needs_ack {
                    self.units.clear();
                    self.gos.clear();
                    self.notes.push_back(Note::Teleported(*position));
                }
            }
            SessionEvent::ForceSpeedChange {
                guid, kind, speed, ..
            } if *guid == me => {
                if matches!(kind, benilla_protocol::SpeedKind::Run) {
                    self.run_speed = *speed;
                }
            }
            SessionEvent::SpeedChanged { guid, kind, speed } => {
                if matches!(kind, benilla_protocol::SpeedKind::Run) {
                    if *guid == me {
                        self.run_speed = *speed;
                    } else if let Some(u) = self.units.get_mut(guid) {
                        u.run_speed = *speed;
                    }
                }
            }
            SessionEvent::MoveMode {
                guid, mode, apply, ..
            } if *guid == me => {
                if matches!(mode, benilla_protocol::MoveMode::Root) {
                    self.rooted = *apply;
                }
            }
            SessionEvent::SpellBook {
                spell_ids,
                cooldowns,
            } => {
                self.spells.extend(spell_ids.iter().copied());
                for c in cooldowns {
                    let ms = c.spell_cd_ms.max(c.category_cd_ms);
                    if ms > 0 {
                        self.cooldowns
                            .insert(u32::from(c.spell_id), now_ms + u64::from(ms));
                    }
                }
            }
            SessionEvent::SpellLearned { spell_id } => {
                self.spells.insert(*spell_id);
            }
            SessionEvent::SpellRemoved { spell_id } => {
                self.spells.remove(spell_id);
            }
            SessionEvent::SpellSuperceded {
                old_spell_id,
                new_spell_id,
            } => {
                self.spells.remove(old_spell_id);
                self.spells.insert(*new_spell_id);
            }
            SessionEvent::SpellCooldowns { caster, cooldowns } if *caster == me => {
                for (spell, ms) in cooldowns {
                    if *ms > 0 {
                        self.cooldowns.insert(*spell, now_ms + u64::from(*ms));
                    }
                }
            }
            SessionEvent::CooldownEvent { spell_id, caster } if *caster == me => {
                // The on-hold cooldown starts now; we don't know its length without Spell.dbc,
                // so keep whatever the brain recorded at cast time, or 1.5 s.
                self.cooldowns
                    .entry(*spell_id)
                    .and_modify(|t| *t = (*t).max(now_ms + 1_500))
                    .or_insert(now_ms + 1_500);
            }
            SessionEvent::ClearCooldown { spell_id, caster } if *caster == me => {
                self.cooldowns.remove(spell_id);
            }
            SessionEvent::CastResult {
                spell_id,
                success,
                reason,
                ..
            } => {
                if !*success {
                    self.notes.push_back(Note::CastFailed {
                        spell: *spell_id,
                        reason: reason.unwrap_or(0),
                    });
                }
            }
            SessionEvent::SpellGo {
                caster, spell_id, ..
            } if *caster == me => {
                if *spell_id == super::combat::AUTO_SHOT {
                    self.last_shot_ms = Some(now_ms);
                    self.shots += 1;
                }
            }
            SessionEvent::AttackStart { attacker, victim } => {
                if *attacker == me {
                    self.melee_victim = Some(*victim);
                } else if *victim == me {
                    self.attackers.insert(*attacker, now_ms);
                }
            }
            SessionEvent::AttackStop { attacker, victim } => {
                if *attacker == me {
                    self.melee_victim = None;
                } else if *victim == me {
                    self.attackers.remove(attacker);
                }
            }
            SessionEvent::AttackerState(s) => {
                if s.victim == me && s.attacker != me {
                    self.attackers.insert(s.attacker, now_ms);
                }
            }
            SessionEvent::AttackSwingError(e) => {
                self.notes.push_back(Note::AttackError(format!("{e:?}")));
            }
            SessionEvent::CancelCombat => {
                self.melee_victim = None;
            }
            SessionEvent::XpGain(x) => self.notes.push_back(Note::XpGain {
                amount: x.total,
                victim: x.victim,
                kill: x.kill,
            }),
            SessionEvent::LevelUp(l) => self.notes.push_back(Note::LevelUp(l.level)),
            SessionEvent::GossipMenu {
                npc,
                options,
                quests,
                ..
            } => {
                self.dialog = Some(Dialog::Gossip {
                    npc: *npc,
                    options: options
                        .iter()
                        .map(|o| (o.index, o.icon, o.message.clone()))
                        .collect(),
                    quests: quests.iter().map(|q| (q.0, q.1)).collect(),
                });
            }
            SessionEvent::QuestGiverStatus { npc, status } => {
                self.quest_status.insert(*npc, *status);
            }
            SessionEvent::QuestGreeting(l) => self.dialog = Some(Dialog::QuestList(l.clone())),
            SessionEvent::QuestDetail(d) => self.dialog = Some(Dialog::Details(d.clone())),
            SessionEvent::QuestProgress(p) => self.dialog = Some(Dialog::RequestItems(p.clone())),
            SessionEvent::QuestOffer(o) => self.dialog = Some(Dialog::OfferReward(o.clone())),
            SessionEvent::QuestComplete(c) => {
                self.dialog = None;
                self.notes.push_back(Note::QuestRewarded {
                    quest: c.quest_id,
                    xp: c.xp,
                    money: c.money,
                });
            }
            SessionEvent::GossipComplete => {
                self.dialog = None;
                self.gossip_closed_ms = Some(now_ms);
            }
            SessionEvent::QuestObjectiveKill {
                quest_id,
                entry,
                count,
                required,
            } => self.notes.push_back(Note::QuestObjective {
                quest: *quest_id,
                entry: *entry,
                count: *count,
                required: *required,
            }),
            SessionEvent::QuestObjectiveItem { item_id, count } => {
                self.notes.push_back(Note::QuestItem {
                    item: *item_id,
                    count: *count,
                })
            }
            SessionEvent::QuestObjectivesComplete { quest_id } => self
                .notes
                .push_back(Note::QuestObjectivesComplete(*quest_id)),
            SessionEvent::QuestGiverInvalid { reason } => {
                self.dialog = None;
                self.notes.push_back(Note::QuestInvalid(*reason))
            }
            SessionEvent::QuestGiverFailed { quest_id, reason } => {
                self.notes.push_back(Note::QuestFailed {
                    quest: *quest_id,
                    reason: *reason,
                })
            }
            SessionEvent::QuestLogFull => self.notes.push_back(Note::QuestLogFull),
            SessionEvent::LootResponse {
                guid, gold, items, ..
            } => {
                self.loot = Some(LootWindow {
                    guid: *guid,
                    gold: *gold,
                    items: items.clone(),
                    opened_ms: now_ms,
                });
                self.loot_released = None;
            }
            SessionEvent::LootError { guid, error } => {
                self.loot = None;
                self.loot_released = Some(*guid);
                self.notes.push_back(Note::LootError {
                    guid: *guid,
                    error: *error,
                });
            }
            SessionEvent::LootRemoved { slot } => {
                if let Some(l) = &mut self.loot {
                    l.items.retain(|i| i.slot != *slot);
                }
            }
            SessionEvent::LootMoneyNotify { amount } => {
                self.notes.push_back(Note::Money(*amount));
                if let Some(l) = &mut self.loot {
                    l.gold = 0;
                }
            }
            SessionEvent::LootClearMoney => {
                if let Some(l) = &mut self.loot {
                    l.gold = 0;
                }
            }
            SessionEvent::LootReleaseResponse { guid } => {
                self.loot = None;
                self.loot_released = Some(*guid);
            }
            SessionEvent::ItemPushResult(r) => self.notes.push_back(Note::ItemReceived {
                entry: r.item_entry,
                count: r.count,
            }),
            SessionEvent::CorpseQuery {
                found, position, ..
            } => {
                if *found {
                    self.corpse_pos = Some(*position);
                    self.notes.push_back(Note::CorpseAt(*position));
                }
            }
            SessionEvent::CorpseReclaimDelay { delay_ms } => {
                self.notes.push_back(Note::ReclaimDelay(*delay_ms))
            }
            SessionEvent::ItemTemplate { .. } => {}
            SessionEvent::Disconnected { reason, .. } => {
                self.closed = Some(reason.clone());
                self.notes.push_back(Note::Closed(reason.clone()));
            }
            _ => {}
        }
        self.track_life();
    }

    fn forget(&mut self, g: u64) {
        self.units.remove(&g);
        self.gos.remove(&g);
        self.corpses.remove(&g);
        self.attackers.remove(&g);
    }

    fn track_life(&mut self) {
        let dead = self.is_dead_body();
        let ghost = self.is_ghost();
        if dead && !self.was_dead {
            self.notes.push_back(Note::Died);
        }
        if ghost && !self.was_ghost {
            self.notes.push_back(Note::Ghost);
        }
        if (self.was_dead || self.was_ghost)
            && !dead
            && !ghost
            && self.fields.unit_health().unwrap_or(0) > 0
        {
            self.notes.push_back(Note::Resurrected);
            self.attackers.clear();
        }
        self.was_dead = dead;
        self.was_ghost = ghost;
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct QuestEntry {
    pub quest: u32,
    pub counters: [u8; 4],
    pub complete: bool,
    pub failed: bool,
}

#[cfg(test)]
mod tests {
    use super::*;
    use benilla_protocol::messages::{self, opcode};

    fn ev(op: u16, body: Vec<u8>) -> Vec<SessionEvent> {
        benilla_protocol::decode(messages::parse_server(op, &body).unwrap())
    }

    fn unit(guid: u64, pairs: &[(u16, u32)]) -> SessionEvent {
        SessionEvent::ObjectCreate {
            guid,
            kind: EntityKind::Unit,
            display_id: None,
            position: [10.0, 0.0, 0.0],
            orientation: 0.0,
            scale: 1.0,
            speeds: None,
            mover: None,
            transport_progress: None,
            transport: None,
            spline: None,
            fields: ObjectFields::from_pairs(pairs),
        }
    }

    #[test]
    fn dynamic_flags_follow_cmangos_classic() {
        let mut w = World::new(1, [0.0; 3], 0);
        w.apply(&unit(2, &[(3, 6), (22, 0), (28, 40), (143, 0x1 | 0x20)]), 0);
        w.apply(
            &unit(
                3,
                &[
                    (3, 6),
                    (22, 30),
                    (28, 40),
                    (143, 0x4),
                    (46, UNIT_FLAG_IN_COMBAT),
                ],
            ),
            0,
        );
        w.apply(&unit(4, &[(3, 6), (22, 30), (28, 40), (143, 0x8)]), 0);
        let (a, b, c) = (w.unit(2).unwrap(), w.unit(3).unwrap(), w.unit(4).unwrap());
        assert!(a.is_dead() && a.lootable() && !a.tapped_by_other());
        assert!(b.tapped_by_other() && b.in_combat() && !b.is_dead());
        assert!(
            !c.tapped_by_other(),
            "0x8 is UNIT_DYNFLAG_ROOTED in CMaNGOS classic"
        );
        assert_eq!(a.entry(), 6);
    }

    #[test]
    fn attackers_expire_and_die() {
        let mut w = World::new(1, [0.0; 3], 0);
        w.apply(&unit(2, &[(22, 30), (28, 40)]), 0);
        let mut b = 2u64.to_le_bytes().to_vec();
        b.extend_from_slice(&1u64.to_le_bytes());
        for e in ev(opcode::SMSG_ATTACKSTART, b) {
            w.apply(&e, 1_000);
        }
        assert_eq!(w.live_attackers(2_000), vec![2]);
        assert!(w.live_attackers(9_500).is_empty(), "8 s without a swing");
        w.apply(
            &SessionEvent::ObjectValues {
                guid: 2,
                fields: ObjectFields::from_pairs(&[(22, 0)]),
            },
            2_100,
        );
        assert!(w.live_attackers(2_200).is_empty(), "dead");
    }

    #[test]
    fn bags_quest_log_and_spline_position() {
        let mut w = World::new(1, [0.0; 3], 0);
        // Backpack slot 1 holds item 0x40 (Tough Jerky x5); bag 19 (0x50, 4 slots) slot 2 holds
        // item 0x41 (Refreshing Spring Water).
        w.apply(
            &SessionEvent::ObjectValues {
                guid: 1,
                fields: ObjectFields::from_pairs(&[
                    (532 + 2, 0x40),
                    (524, 0x50),
                    (198, 7),
                    (199, 3 | (1 << 24)),
                    (201, 33),
                    (202, 4 << 6),
                ]),
            },
            0,
        );
        for (g, e, extra) in [
            (0x40u64, 117u32, vec![(14u16, 5u32)]),
            (0x41, 159, vec![]),
            (0x50, 4496, vec![(48, 4), (50 + 4, 0x41)]),
        ] {
            let mut f = vec![(3u16, e)];
            f.extend(extra);
            w.apply(
                &SessionEvent::ItemCreate {
                    guid: g,
                    container: g == 0x50,
                    fields: ObjectFields::from_pairs(&f),
                },
                0,
            );
        }
        let bags = w.bag_items();
        assert!(bags.contains(&BagSlot {
            bag: 255,
            slot: 24,
            guid: 0x40,
            entry: 117,
            count: 5
        }));
        assert!(bags.contains(&BagSlot {
            bag: 19,
            slot: 2,
            guid: 0x41,
            entry: 159,
            count: 1
        }));
        assert_eq!(w.count_item(117), 5);
        let log = w.quest_log();
        assert_eq!(log.len(), 2);
        assert!(log[0].quest == 7 && log[0].complete && log[0].counters[0] == 3);
        assert!(log[1].quest == 33 && !log[1].complete && log[1].counters[1] == 4);

        // A creature walking a server path is read along it.
        w.apply(&unit(2, &[(22, 30), (28, 40)]), 0);
        w.apply(
            &SessionEvent::MonsterMove {
                guid: 2,
                transport: None,
                start: [10.0, 0.0, 0.0],
                spline_id: 1,
                path: vec![[10.0, 0.0, 0.0], [20.0, 0.0, 0.0]],
                facing: benilla_protocol::MonsterMoveFacing::None,
                stop: false,
                duration_ms: 2_000,
                flying: false,
                run_mode: true,
            },
            1_000,
        );
        let p = w.unit(2).unwrap().pos_at(2_000);
        assert!((p[0] - 15.0).abs() < 0.01, "{p:?}");
        assert_eq!(w.unit(2).unwrap().pos_at(9_000)[0], 20.0);
    }

    #[test]
    fn quest_panels_from_wire_bytes() {
        let mut w = World::new(1, [0.0; 3], 0);
        // SMSG_QUESTGIVER_QUEST_LIST (GossipDef.cpp SendQuestGiverQuestList)
        let mut b = 0x99u64.to_le_bytes().to_vec();
        b.extend_from_slice(b"Hi\0");
        b.extend_from_slice(&0u32.to_le_bytes());
        b.extend_from_slice(&0u32.to_le_bytes());
        b.push(1);
        for v in [7u32, 5, 2] {
            b.extend_from_slice(&v.to_le_bytes());
        }
        b.extend_from_slice(b"Kobold Camp Cleanup\0");
        for e in ev(opcode::SMSG_QUESTGIVER_QUEST_LIST, b) {
            w.apply(&e, 0);
        }
        let Some(Dialog::QuestList(l)) = &w.dialog else {
            panic!("{:?}", w.dialog)
        };
        assert_eq!(l.quests[0].quest_id, 7);
        for e in ev(opcode::SMSG_GOSSIP_COMPLETE, vec![]) {
            w.apply(&e, 0);
        }
        assert!(w.dialog.is_none());
        // SMSG_QUESTGIVER_QUEST_COMPLETE (Player::SendQuestReward)
        let mut b = vec![];
        for v in [7u32, 3, 170, 25, 0] {
            b.extend_from_slice(&v.to_le_bytes());
        }
        for e in ev(opcode::SMSG_QUESTGIVER_QUEST_COMPLETE, b) {
            w.apply(&e, 0);
        }
        assert_eq!(
            w.notes.pop_front(),
            Some(Note::QuestRewarded {
                quest: 7,
                xp: 170,
                money: 25
            })
        );
        // SMSG_QUESTUPDATE_ADD_KILL (Player::SendQuestUpdateAddCreatureOrGo)
        let mut b = vec![];
        for v in [7u32, 6, 3, 10] {
            b.extend_from_slice(&v.to_le_bytes());
        }
        b.extend_from_slice(&0x77u64.to_le_bytes());
        for e in ev(opcode::SMSG_QUESTUPDATE_ADD_KILL, b) {
            w.apply(&e, 0);
        }
        assert_eq!(
            w.notes.pop_front(),
            Some(Note::QuestObjective {
                quest: 7,
                entry: 6,
                count: 3,
                required: 10
            })
        );
    }
}
