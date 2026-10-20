//! Everything the autopilot sends, as data. The brain returns [`OutCmd`]s; the live driver hands
//! them to benilla-protocol's `WorldWriter` ([`WriterSink`]), and tests read them directly or turn
//! them into wire bytes with [`OutCmd::encode`] (built from the same benilla encoders the writer
//! uses). Opcode numbers come from `benilla_protocol::messages::opcode` and were cross-checked
//! against CMaNGOS classic `Opcodes.h` (see `tests::opcodes_match_cmangos_classic`).

use anyhow::Result;
use benilla_protocol::messages::{self, opcode, MovementInfo, UseItemTarget};
use benilla_protocol::wire::Vector3d;
use benilla_protocol::WorldWriter;

use super::geom::Vec3;

/// `CMSG_CANCEL_AUTO_REPEAT_SPELL` (CMaNGOS classic `Opcodes.h`: 0x26D).
pub const CMSG_CANCEL_AUTO_REPEAT_SPELL: u16 = opcode::CMSG_CANCEL_AUTO_REPEAT_SPELL;

/// Movement flags the autopilot sets (CMaNGOS classic `MovementFlags`): it only ever runs
/// forward, so `MOVEFLAG_FORWARD` is the only bit it uses.
pub const MOVEFLAG_NONE: u32 = 0;
pub const MOVEFLAG_FORWARD: u32 = 0x0000_0001;

/// `UNIT_STAND_STATE_*` (CMaNGOS `Unit.h`).
pub const STAND_STATE_STAND: u8 = 0;
pub const STAND_STATE_SIT: u8 = 1;

#[derive(Debug, Clone, PartialEq)]
pub enum OutCmd {
    /// One `MSG_MOVE_*` from our own mover. `time_ms` is the autopilot clock; on the live wire
    /// benilla stamps its own monotonic client uptime instead.
    Move {
        opcode: u16,
        flags: u32,
        pos: Vec3,
        orientation: f32,
        time_ms: u64,
    },
    SetSelection(u64),
    AttackSwing(u64),
    AttackStop,
    CastSpell {
        spell: u32,
        target: Option<u64>,
    },
    CancelAutoRepeat,
    Loot(u64),
    AutostoreLoot(u8),
    LootMoney,
    LootRelease(u64),
    QuestgiverStatusQuery(u64),
    QuestgiverHello(u64),
    QuestgiverQueryQuest(u64, u32),
    QuestgiverAcceptQuest(u64, u32),
    QuestgiverCompleteQuest(u64, u32),
    QuestgiverRequestReward(u64, u32),
    QuestgiverChooseReward(u64, u32, u32),
    GossipHello(u64),
    GossipSelectOption(u64, u32),
    GameObjUse(u64),
    RepopRequest,
    CorpseQuery,
    ReclaimCorpse(u64),
    StandState(u8),
    UseItem {
        bag: u8,
        slot: u8,
    },
    AreaTrigger(u32),
    LogoutRequest,
}

impl OutCmd {
    pub fn opcode(&self) -> u16 {
        self.encode().0
    }

    /// The opcode and body this command puts on the wire.
    pub fn encode(&self) -> (u16, Vec<u8>) {
        use OutCmd::*;
        let guid = |g: u64| g.to_le_bytes().to_vec();
        match *self {
            Move {
                opcode,
                flags,
                pos,
                orientation,
                time_ms,
            } => {
                let info = MovementInfo {
                    flags,
                    timestamp: (time_ms as u32).max(1),
                    position: Vector3d {
                        x: pos[0],
                        y: pos[1],
                        z: pos[2],
                    },
                    orientation,
                    transport: None,
                    pitch: 0.0,
                    fall_time: 0,
                    jump: None,
                };
                (opcode, messages::movement(&info))
            }
            SetSelection(g) => (opcode::CMSG_SET_SELECTION, guid(g)),
            AttackSwing(g) => (opcode::CMSG_ATTACKSWING, messages::attack_swing(g)),
            AttackStop => (opcode::CMSG_ATTACKSTOP, vec![]),
            CastSpell { spell, target } => {
                (opcode::CMSG_CAST_SPELL, messages::cast_spell(spell, target))
            }
            CancelAutoRepeat => (CMSG_CANCEL_AUTO_REPEAT_SPELL, vec![]),
            Loot(g) => (opcode::CMSG_LOOT, messages::loot(g)),
            AutostoreLoot(s) => (
                opcode::CMSG_AUTOSTORE_LOOT_ITEM,
                messages::autostore_loot_item(s),
            ),
            LootMoney => (opcode::CMSG_LOOT_MONEY, messages::loot_money()),
            LootRelease(g) => (opcode::CMSG_LOOT_RELEASE, messages::loot_release(g)),
            QuestgiverStatusQuery(g) => (
                opcode::CMSG_QUESTGIVER_STATUS_QUERY,
                messages::questgiver_status_query(g),
            ),
            QuestgiverHello(g) => (opcode::CMSG_QUESTGIVER_HELLO, messages::questgiver_hello(g)),
            QuestgiverQueryQuest(g, q) => (
                opcode::CMSG_QUESTGIVER_QUERY_QUEST,
                messages::questgiver_query_quest(g, q),
            ),
            QuestgiverAcceptQuest(g, q) => (
                opcode::CMSG_QUESTGIVER_ACCEPT_QUEST,
                messages::questgiver_accept_quest(g, q),
            ),
            QuestgiverCompleteQuest(g, q) => (
                opcode::CMSG_QUESTGIVER_COMPLETE_QUEST,
                messages::questgiver_complete_quest(g, q),
            ),
            QuestgiverRequestReward(g, q) => (
                opcode::CMSG_QUESTGIVER_REQUEST_REWARD,
                messages::questgiver_request_reward(g, q),
            ),
            QuestgiverChooseReward(g, q, r) => (
                opcode::CMSG_QUESTGIVER_CHOOSE_REWARD,
                messages::questgiver_choose_reward(g, q, r),
            ),
            GossipHello(g) => (opcode::CMSG_GOSSIP_HELLO, messages::gossip_hello(g)),
            GossipSelectOption(g, i) => (
                opcode::CMSG_GOSSIP_SELECT_OPTION,
                messages::gossip_select_option(g, i, None),
            ),
            GameObjUse(g) => (opcode::CMSG_GAMEOBJ_USE, messages::gameobj_use(g)),
            RepopRequest => (opcode::CMSG_REPOP_REQUEST, vec![]),
            CorpseQuery => (opcode::MSG_CORPSE_QUERY, vec![]),
            ReclaimCorpse(g) => (opcode::CMSG_RECLAIM_CORPSE, messages::reclaim_corpse(g)),
            StandState(s) => (
                opcode::CMSG_STANDSTATECHANGE,
                messages::stand_state_change(u32::from(s)),
            ),
            UseItem { bag, slot } => (
                opcode::CMSG_USE_ITEM,
                messages::use_item(bag, slot, 0, UseItemTarget::SelfImplicit),
            ),
            AreaTrigger(id) => (opcode::CMSG_AREATRIGGER, messages::area_trigger(id)),
            LogoutRequest => (opcode::CMSG_LOGOUT_REQUEST, vec![]),
        }
    }

    /// A short label for the run log.
    pub fn label(&self) -> String {
        let (op, _) = self.encode();
        messages::opcode_name(op)
            .map(str::to_string)
            .unwrap_or_else(|| format!("{op:#06x}"))
    }
}

/// Where commands go.
pub trait Sink {
    fn send(&mut self, cmd: &OutCmd) -> Result<()>;
}

/// A sink that records, for tests and dry runs.
#[derive(Default, Debug)]
pub struct Recorder {
    pub sent: Vec<OutCmd>,
}

impl Sink for Recorder {
    fn send(&mut self, cmd: &OutCmd) -> Result<()> {
        self.sent.push(cmd.clone());
        Ok(())
    }
}

/// The live sink: each command through the matching typed `WorldWriter` method.
pub struct WriterSink<'a>(pub &'a mut WorldWriter);

impl Sink for WriterSink<'_> {
    fn send(&mut self, cmd: &OutCmd) -> Result<()> {
        use OutCmd::*;
        let w = &mut *self.0;
        match *cmd {
            Move {
                opcode,
                flags,
                pos,
                orientation,
                ..
            } => w.send_movement(opcode, flags, pos, orientation, 0.0, 0, None, None),
            SetSelection(g) => w.set_selection(g),
            AttackSwing(g) => w.attack_swing(g),
            AttackStop => w.attack_stop(),
            CastSpell { spell, target } => w.cast_spell(spell, target),
            CancelAutoRepeat => w.cancel_auto_repeat(),
            Loot(g) => w.loot(g),
            AutostoreLoot(s) => w.autostore_loot_item(s),
            LootMoney => w.loot_money(),
            LootRelease(g) => w.loot_release(g),
            QuestgiverStatusQuery(g) => w.questgiver_status_query(g),
            QuestgiverHello(g) => w.questgiver_hello(g),
            QuestgiverQueryQuest(g, q) => w.questgiver_query_quest(g, q),
            QuestgiverAcceptQuest(g, q) => w.questgiver_accept_quest(g, q),
            QuestgiverCompleteQuest(g, q) => w.questgiver_complete_quest(g, q),
            QuestgiverRequestReward(g, q) => w.questgiver_request_reward(g, q),
            QuestgiverChooseReward(g, q, r) => w.questgiver_choose_reward(g, q, r),
            GossipHello(g) => w.gossip_hello(g),
            GossipSelectOption(g, i) => w.gossip_select_option(g, i, None),
            GameObjUse(g) => w.gameobj_use(g),
            RepopRequest => w.repop_request(),
            CorpseQuery => w.corpse_query(),
            ReclaimCorpse(g) => w.reclaim_corpse(g),
            StandState(s) => w.stand_state_change(u32::from(s)),
            UseItem { bag, slot } => w.use_item(bag, slot, 0, UseItemTarget::SelfImplicit),
            AreaTrigger(id) => w.area_trigger(id),
            LogoutRequest => w.logout_request(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every opcode the autopilot sends, with the value in CMaNGOS classic
    /// `src/game/Server/Opcodes.h` (checked by hand against /tmp/claude-0/mc on 2026-10-16).
    #[test]
    fn opcodes_match_cmangos_classic() {
        let cases: &[(OutCmd, u16)] = &[
            (OutCmd::SetSelection(1), 0x13D),
            (OutCmd::AttackSwing(1), 0x141),
            (OutCmd::AttackStop, 0x142),
            (
                OutCmd::CastSpell {
                    spell: 75,
                    target: Some(1),
                },
                0x12E,
            ),
            (OutCmd::CancelAutoRepeat, 0x26D),
            (OutCmd::Loot(1), 0x15D),
            (OutCmd::AutostoreLoot(0), 0x108),
            (OutCmd::LootMoney, 0x15E),
            (OutCmd::LootRelease(1), 0x15F),
            (OutCmd::QuestgiverStatusQuery(1), 0x182),
            (OutCmd::QuestgiverHello(1), 0x184),
            (OutCmd::QuestgiverQueryQuest(1, 2), 0x186),
            (OutCmd::QuestgiverAcceptQuest(1, 2), 0x189),
            (OutCmd::QuestgiverCompleteQuest(1, 2), 0x18A),
            (OutCmd::QuestgiverRequestReward(1, 2), 0x18C),
            (OutCmd::QuestgiverChooseReward(1, 2, 0), 0x18E),
            (OutCmd::GossipHello(1), 0x17B),
            (OutCmd::GossipSelectOption(1, 0), 0x17C),
            (OutCmd::GameObjUse(1), 0x0B1),
            (OutCmd::RepopRequest, 0x15A),
            (OutCmd::CorpseQuery, 0x216),
            (OutCmd::ReclaimCorpse(1), 0x1D2),
            (OutCmd::StandState(1), 0x101),
            (OutCmd::UseItem { bag: 255, slot: 23 }, 0x0AB),
            (OutCmd::AreaTrigger(1), 0x0B4),
            (OutCmd::LogoutRequest, 0x04B),
        ];
        for (cmd, want) in cases {
            assert_eq!(cmd.opcode(), *want, "{cmd:?}");
        }
        assert_eq!(opcode::MSG_MOVE_START_FORWARD, 0x0B5);
        assert_eq!(opcode::MSG_MOVE_STOP, 0x0B7);
        assert_eq!(opcode::MSG_MOVE_SET_FACING, 0x0DA);
        assert_eq!(opcode::MSG_MOVE_HEARTBEAT, 0x0EE);
    }

    /// Bodies follow the CMaNGOS classic handlers' `recv_data >>` order.
    #[test]
    fn bodies_match_the_server_readers() {
        let g = 0xF130_0000_C500_0042u64;
        // QuestHandler.cpp: guid >> quest >> reward
        let (_, b) = OutCmd::QuestgiverChooseReward(g, 33, 1).encode();
        assert_eq!(&b[..8], &g.to_le_bytes());
        assert_eq!(&b[8..12], &33u32.to_le_bytes());
        assert_eq!(&b[12..16], &1u32.to_le_bytes());
        // guid >> quest
        let (_, b) = OutCmd::QuestgiverAcceptQuest(g, 7).encode();
        assert_eq!(b.len(), 12);
        // SpellHandler.cpp: spellId, then SpellCastTargets (u16 mask 0x2 + packed guid)
        let (_, b) = OutCmd::CastSpell {
            spell: 75,
            target: Some(0x42),
        }
        .encode();
        assert_eq!(&b[..4], &75u32.to_le_bytes());
        assert_eq!(&b[4..6], &2u16.to_le_bytes());
        assert_eq!(&b[6..], &[0x01, 0x42], "packed guid");
        // LootHandler.cpp: u8 slot
        assert_eq!(OutCmd::AutostoreLoot(3).encode().1, vec![3]);
        // MiscHandler.cpp: guid
        assert_eq!(
            OutCmd::ReclaimCorpse(g).encode().1,
            g.to_le_bytes().to_vec()
        );
        // CMSG_USE_ITEM: bag, slot, spell slot, then an empty target mask
        assert_eq!(
            OutCmd::UseItem { bag: 255, slot: 24 }.encode().1,
            vec![255, 24, 0, 0, 0]
        );
    }
}
