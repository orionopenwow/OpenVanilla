//! Looting one corpse or chest: open it (`CMSG_LOOT`, or `CMSG_GAMEOBJ_USE` for a chest), take
//! every row we may (`CMSG_AUTOSTORE_LOOT_ITEM`), the coin (`CMSG_LOOT_MONEY`), then release
//! (`CMSG_LOOT_RELEASE`). Pure: it reads the [`LootWindow`] the world model holds.

use benilla_protocol::messages::slot_type;

use super::out::OutCmd;
use super::world::LootWindow;

/// Interaction distance for looting (CMaNGOS `INTERACTION_DISTANCE` 5 yd); we walk to 3.
pub const LOOT_REACH: f32 = 3.0;
const OPEN_TIMEOUT_MS: u64 = 2_500;
const RELEASE_TIMEOUT_MS: u64 = 2_000;

#[derive(Debug, Clone, PartialEq)]
pub enum LootPhase {
    Open { sent_ms: Option<u64> },
    Taking { sent_ms: u64 },
    Releasing { sent_ms: u64 },
    Done { items: u32, money: u32, ok: bool },
}

#[derive(Debug, Clone)]
pub struct Looter {
    pub guid: u64,
    pub chest: bool,
    pub phase: LootPhase,
    taken: Vec<u8>,
    money_taken: u32,
    attempts: u32,
}

impl Looter {
    pub fn new(guid: u64, chest: bool) -> Looter {
        Looter {
            guid,
            chest,
            phase: LootPhase::Open { sent_ms: None },
            taken: vec![],
            money_taken: 0,
            attempts: 0,
        }
    }

    pub fn done(&self) -> bool {
        matches!(self.phase, LootPhase::Done { .. })
    }

    /// One step, given the open window (if any), whether the server closed it, and a loot error.
    pub fn tick(
        &mut self,
        now: u64,
        window: Option<&LootWindow>,
        released: bool,
        error: bool,
    ) -> Vec<OutCmd> {
        let mut out = vec![];
        let window = window.filter(|w| w.guid == self.guid);
        match self.phase.clone() {
            LootPhase::Open { sent_ms } => {
                if error {
                    self.phase = LootPhase::Done {
                        items: 0,
                        money: 0,
                        ok: false,
                    };
                } else if let Some(w) = window {
                    // Take everything we are allowed to, in one go.
                    for it in &w.items {
                        if it.slot_type == slot_type::ALLOW_LOOT {
                            out.push(OutCmd::AutostoreLoot(it.slot));
                            self.taken.push(it.slot);
                        }
                    }
                    if w.gold > 0 {
                        out.push(OutCmd::LootMoney);
                        self.money_taken = w.gold;
                    }
                    self.phase = LootPhase::Taking { sent_ms: now };
                } else if sent_ms.is_none_or(|t| now >= t + OPEN_TIMEOUT_MS) {
                    if self.attempts >= 2 {
                        self.phase = LootPhase::Done {
                            items: 0,
                            money: 0,
                            ok: false,
                        };
                    } else {
                        self.attempts += 1;
                        out.push(if self.chest {
                            OutCmd::GameObjUse(self.guid)
                        } else {
                            OutCmd::Loot(self.guid)
                        });
                        self.phase = LootPhase::Open { sent_ms: Some(now) };
                    }
                }
            }
            LootPhase::Taking { sent_ms } => {
                // Wait for the rows we took to disappear (SMSG_LOOT_REMOVED), briefly.
                let pending = window.is_some_and(|w| {
                    w.items.iter().any(|i| self.taken.contains(&i.slot)) || w.gold > 0
                });
                if !pending || now >= sent_ms + 1_000 {
                    out.push(OutCmd::LootRelease(self.guid));
                    self.phase = LootPhase::Releasing { sent_ms: now };
                }
            }
            LootPhase::Releasing { sent_ms } => {
                if released || window.is_none() || now >= sent_ms + RELEASE_TIMEOUT_MS {
                    self.phase = LootPhase::Done {
                        items: self.taken.len() as u32,
                        money: self.money_taken,
                        ok: true,
                    };
                }
            }
            LootPhase::Done { .. } => {}
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use benilla_protocol::messages::LootItem;

    fn item(slot: u8, id: u32, st: u8) -> LootItem {
        LootItem {
            slot,
            item_id: id,
            count: 1,
            display_info_id: 0,
            random_property_id: 0,
            slot_type: st,
        }
    }

    #[test]
    fn open_take_all_then_release() {
        let mut l = Looter::new(0x99, false);
        assert_eq!(l.tick(0, None, false, false), vec![OutCmd::Loot(0x99)]);
        assert!(l.tick(500, None, false, false).is_empty(), "waiting");
        let mut w = LootWindow {
            guid: 0x99,
            gold: 7,
            items: vec![
                item(0, 2589, slot_type::ALLOW_LOOT),
                item(1, 182, slot_type::ALLOW_LOOT),
                item(2, 999, slot_type::ROLL_ONGOING),
            ],
            opened_ms: 600,
        };
        let v = l.tick(600, Some(&w), false, false);
        assert_eq!(
            v,
            vec![
                OutCmd::AutostoreLoot(0),
                OutCmd::AutostoreLoot(1),
                OutCmd::LootMoney
            ]
        );
        // Rows removed and coin cleared -> release.
        w.items.retain(|i| i.slot == 2);
        w.gold = 0;
        assert_eq!(
            l.tick(700, Some(&w), false, false),
            vec![OutCmd::LootRelease(0x99)]
        );
        assert!(l.tick(800, None, true, false).is_empty());
        assert_eq!(
            l.phase,
            LootPhase::Done {
                items: 2,
                money: 7,
                ok: true
            }
        );
    }

    #[test]
    fn a_loot_error_ends_it_and_a_silent_server_is_retried_then_dropped() {
        let mut l = Looter::new(1, false);
        l.tick(0, None, false, false);
        l.tick(10, None, false, true);
        assert!(matches!(l.phase, LootPhase::Done { ok: false, .. }));

        let mut l = Looter::new(2, true);
        assert_eq!(l.tick(0, None, false, false), vec![OutCmd::GameObjUse(2)]);
        assert_eq!(
            l.tick(2_600, None, false, false),
            vec![OutCmd::GameObjUse(2)]
        );
        assert!(l.tick(5_200, None, false, false).is_empty());
        assert!(matches!(l.phase, LootPhase::Done { ok: false, .. }));
    }

    #[test]
    fn a_window_for_another_guid_is_ignored() {
        let mut l = Looter::new(5, false);
        l.tick(0, None, false, false);
        let w = LootWindow {
            guid: 6,
            gold: 1,
            items: vec![],
            opened_ms: 0,
        };
        assert!(l.tick(100, Some(&w), false, false).is_empty());
    }
}
