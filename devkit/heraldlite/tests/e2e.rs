//! End to end, offline: the real `heraldlite` binary against an in-process fake realm.
//!
//! - fake realmd: server-side SRP6 (verifier from benilla-srp, `B = 3v + g^b`, verifies the
//!   client's `M1`, answers `M2`), then the realm list;
//! - fake mangosd: `SMSG_AUTH_CHALLENGE`, checks the `CMSG_AUTH_SESSION` digest against the SRP
//!   session key, header crypto from then on, character list, login (verify-world, our own
//!   update-object create with skill fields, a vendor create), the Open Vanilla WNL hook (`HI`, `LG`),
//!   channels shared across sessions, name queries, a gold vendor, logout;
//! - fake web service: `POST /login` (cookie), `GET /api/play` (chunked JSON, rotates the cookie),
//!   and the cookie-gated `/ws/{port}` relay that pipes to realmd/mangosd one frame per TCP read.
//!
//! Every packet the fake server writes is parsed by benilla-protocol in the client, so this
//! verifies our use of the crates, the bridge, the scenario runner and the report, not the real
//! CMaNGOS server's behaviour.

#![allow(
    clippy::type_complexity,
    clippy::ptr_arg,
    clippy::result_large_err,
    clippy::explicit_counter_loop,
    clippy::manual_strip
)]

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use benilla_protocol::messages::{self, opcode};
use benilla_protocol::wire::write_packed_guid;
use benilla_srp::vanilla_header::HeaderCrypto;
use benilla_srp::{NormalizedString, GENERATOR, LARGE_SAFE_PRIME_LITTLE_ENDIAN};
use num_bigint::{BigInt, Sign};
use sha1::{Digest, Sha1};

// ── fake data ──────────────────────────────────────────────────────────────────────────────────

const VENDOR_ENTRY: u32 = 54; // a stock vendor (Corina Steele)
const VENDOR_GUID: u64 = 0xF130_0000_0000_0000 | ((VENDOR_ENTRY as u64) << 24) | 0x42;
const WARE: u32 = 2589; // Linen Cloth
const WARE_PRICE: u32 = 50; // copper
const FIELD_SKILL: u16 = 718;

// ── the autopilot's scripted world (account BOTHUNTER) ─────────────────────────────────────────
// A quest giver 10 yd north of the login spot and a Kobold Vermin 40 yd north. Auto Shot kills
// it at once; the server checks interaction ranges against the position from MSG_MOVE_*.
const BOT_GUID: u64 = 0x20;
const BOT_NPC: u64 = 0xF130_0000_C500_0001;
const BOT_MOB: u64 = 0xF130_0000_0600_0001;
const BOT_QUEST: u32 = 7;
const LOGIN_POS: [f32; 3] = [-8925.0, 607.0, 99.6];

fn bot_npc_pos() -> [f32; 3] {
    [LOGIN_POS[0] + 10.0, LOGIN_POS[1], LOGIN_POS[2]]
}
fn bot_mob_pos() -> [f32; 3] {
    [LOGIN_POS[0] + 40.0, LOGIN_POS[1], LOGIN_POS[2]]
}

#[derive(Default)]
struct BotWorld {
    pos: [f32; 3],
    /// 0 none, 1 taken, 2 complete, 3 rewarded
    quest: u8,
    mob_dead: bool,
    looted: bool,
    heartbeats: u32,
    starts: u32,
    stops: u32,
    violations: Vec<String>,
}

fn d2(a: [f32; 3], b: [f32; 3]) -> f32 {
    ((a[0] - b[0]).powi(2) + (a[1] - b[1]).powi(2)).sqrt()
}

fn values_update(guid: u64, fields: &mut Vec<(u16, u32)>) -> Vec<u8> {
    let mut b = vec![0u8];
    write_packed_guid(guid, &mut b).unwrap();
    b.extend(values_block(fields));
    b
}

fn bot_quest_fields(q: u8) -> Vec<(u16, u32)> {
    match q {
        1 => vec![(198, BOT_QUEST), (199, 0)],
        2 => vec![(198, BOT_QUEST), (199, 1 | (1 << 24))],
        _ => vec![(198, 0), (199, 0)],
    }
}

fn bot_login_packets(c: &Char) -> Vec<(u16, Vec<u8>)> {
    let mut me = vec![
        (0u16, c.guid as u32),
        (1, 0),
        (2, 0x19),
        (4, 1.0f32.to_bits()),
        (22, 60),
        (23, 80),
        (28, 60),
        (29, 80),
        (34, 1),
        (35, 1),
        (36, 1 | (3 << 8)),
        (128, 2300),
        (716, 0),
        (717, 400),
    ];
    let mut npc = vec![
        (0u16, BOT_NPC as u32),
        (1, (BOT_NPC >> 32) as u32),
        (2, 0x09),
        (3, 197),
        (22, 100),
        (28, 100),
        (34, 10),
        (147, 0x3),
    ];
    let mut mob = vec![
        (0u16, BOT_MOB as u32),
        (1, (BOT_MOB >> 32) as u32),
        (2, 0x09),
        (3, 6),
        (22, 40),
        (28, 40),
        (34, 1),
        (35, 25),
    ];
    let mut spells = vec![0u8];
    spells.extend_from_slice(&2u16.to_le_bytes());
    for sp in [75u16, 2973] {
        spells.extend_from_slice(&sp.to_le_bytes());
        spells.extend_from_slice(&0u16.to_le_bytes());
    }
    spells.extend_from_slice(&0u16.to_le_bytes());
    vec![
        (
            opcode::SMSG_UPDATE_OBJECT,
            update_object(vec![
                create_block(c.guid, 4, LOGIN_POS, &mut me),
                create_block(BOT_NPC, 3, bot_npc_pos(), &mut npc),
                create_block(BOT_MOB, 3, bot_mob_pos(), &mut mob),
            ]),
        ),
        (opcode::SMSG_INITIAL_SPELLS, spells),
    ]
}

/// The bot world's answer to one client packet.
fn bot_handle(w: &mut BotWorld, op: u16, body: &[u8]) -> Vec<(u16, Vec<u8>)> {
    let mut out = vec![];
    let guid_at = |at: usize| u64::from_le_bytes(body[at..at + 8].try_into().unwrap());
    let u32_at = |at: usize| u32::from_le_bytes(body[at..at + 4].try_into().unwrap());
    let u32s = |b: &mut Vec<u8>, v: &[u32]| {
        for x in v {
            b.extend_from_slice(&x.to_le_bytes());
        }
    };
    match op {
        opcode::MSG_MOVE_START_FORWARD
        | opcode::MSG_MOVE_STOP
        | opcode::MSG_MOVE_HEARTBEAT
        | opcode::MSG_MOVE_SET_FACING => {
            // MovementInfo: flags, time, x, y, z, o, fall time
            let f = |at: usize| f32::from_le_bytes(body[at..at + 4].try_into().unwrap());
            let flags = u32_at(0);
            let p = [f(8), f(12), f(16)];
            if d2(p, w.pos) > 8.0 {
                w.violations
                    .push(format!("teleport-like move {:?} -> {p:?}", w.pos));
            }
            w.pos = p;
            match op {
                opcode::MSG_MOVE_HEARTBEAT => {
                    w.heartbeats += 1;
                    if flags & 1 == 0 {
                        w.violations.push("heartbeat without FORWARD".into());
                    }
                }
                opcode::MSG_MOVE_START_FORWARD => w.starts += 1,
                opcode::MSG_MOVE_STOP => {
                    w.stops += 1;
                    if flags != 0 {
                        w.violations.push("stop with flags".into());
                    }
                }
                _ => {}
            }
        }
        opcode::CMSG_QUESTGIVER_HELLO | opcode::CMSG_QUESTGIVER_COMPLETE_QUEST => {
            if d2(w.pos, bot_npc_pos()) > 5.0 {
                w.violations.push(format!(
                    "quest giver from {:.1} yd",
                    d2(w.pos, bot_npc_pos())
                ));
                return out;
            }
            let mut b = BOT_NPC.to_le_bytes().to_vec();
            u32s(&mut b, &[BOT_QUEST]);
            cstr(&mut b, "Kobold Camp Cleanup");
            if w.quest == 0 {
                cstr(&mut b, "Kill kobolds.");
                cstr(&mut b, "Slay a Kobold Vermin.");
                u32s(&mut b, &[0, 0, 0, 25, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0]);
                out.push((opcode::SMSG_QUESTGIVER_QUEST_DETAILS, b));
            } else if w.quest == 2 {
                cstr(&mut b, "Well done.");
                u32s(&mut b, &[1, 0, 0, 0, 25, 0, 0]);
                out.push((opcode::SMSG_QUESTGIVER_OFFER_REWARD, b));
            }
        }
        opcode::CMSG_QUESTGIVER_ACCEPT_QUEST if w.quest == 0 && u32_at(8) == BOT_QUEST => {
            w.quest = 1;
            out.push((
                opcode::SMSG_UPDATE_OBJECT,
                update_object(vec![values_update(BOT_GUID, &mut bot_quest_fields(1))]),
            ));
            out.push((opcode::SMSG_GOSSIP_COMPLETE, vec![]));
        }
        opcode::CMSG_CAST_SPELL if u32_at(0) == 75 && !w.mob_dead => {
            let d = d2(w.pos, bot_mob_pos());
            if !(8.0..=35.0).contains(&d) {
                let mut b = 75u32.to_le_bytes().to_vec();
                b.extend_from_slice(&[2, 5]); // SPELL_FAILED_OUT_OF_RANGE-ish
                out.push((opcode::SMSG_CAST_RESULT, b));
                w.violations.push(format!("shot from {d:.1} yd"));
                return out;
            }
            w.mob_dead = true;
            out.push((
                opcode::SMSG_UPDATE_OBJECT,
                update_object(vec![values_update(
                    BOT_MOB,
                    &mut vec![(22, 0), (143, 0x21)],
                )]),
            ));
            let mut b = BOT_MOB.to_le_bytes().to_vec();
            u32s(&mut b, &[50]);
            b.push(0);
            u32s(&mut b, &[50]);
            b.extend_from_slice(&1.0f32.to_le_bytes());
            out.push((opcode::SMSG_LOG_XPGAIN, b));
            let mut b = Vec::new();
            u32s(&mut b, &[BOT_QUEST, 6, 1, 1]);
            b.extend_from_slice(&BOT_MOB.to_le_bytes());
            out.push((opcode::SMSG_QUESTUPDATE_ADD_KILL, b));
            w.quest = 2;
            let mut f = bot_quest_fields(2);
            f.push((716, 50));
            out.push((
                opcode::SMSG_UPDATE_OBJECT,
                update_object(vec![values_update(BOT_GUID, &mut f)]),
            ));
        }
        opcode::CMSG_LOOT if guid_at(0) == BOT_MOB && w.mob_dead => {
            if d2(w.pos, bot_mob_pos()) > 5.0 {
                w.violations
                    .push(format!("loot from {:.1} yd", d2(w.pos, bot_mob_pos())));
                return out;
            }
            let mut b = BOT_MOB.to_le_bytes().to_vec();
            b.push(1);
            u32s(&mut b, &[3]);
            b.push(1);
            b.push(0);
            u32s(&mut b, &[2589, 1, 0, 0, 0]);
            b.push(0);
            out.push((opcode::SMSG_LOOT_RESPONSE, b));
        }
        opcode::CMSG_AUTOSTORE_LOOT_ITEM => out.push((opcode::SMSG_LOOT_REMOVED, vec![body[0]])),
        opcode::CMSG_LOOT_MONEY => {
            out.push((opcode::SMSG_LOOT_MONEY_NOTIFY, 3u32.to_le_bytes().to_vec()));
            out.push((opcode::SMSG_LOOT_CLEAR_MONEY, vec![]));
        }
        opcode::CMSG_LOOT_RELEASE => {
            w.looted = true;
            let mut b = guid_at(0).to_le_bytes().to_vec();
            b.push(1);
            out.push((opcode::SMSG_LOOT_RELEASE_RESPONSE, b));
            out.push((
                opcode::SMSG_UPDATE_OBJECT,
                update_object(vec![values_update(BOT_MOB, &mut vec![(143, 0x20)])]),
            ));
        }
        opcode::CMSG_QUESTGIVER_CHOOSE_REWARD if w.quest == 2 => {
            w.quest = 3;
            let mut b = Vec::new();
            u32s(&mut b, &[BOT_QUEST, 3, 170, 25, 0]);
            out.push((opcode::SMSG_QUESTGIVER_QUEST_COMPLETE, b));
            let mut f = bot_quest_fields(3);
            f.push((716, 220));
            out.push((
                opcode::SMSG_UPDATE_OBJECT,
                update_object(vec![values_update(BOT_GUID, &mut f)]),
            ));
        }
        _ => {}
    }
    out
}

#[derive(Clone)]
struct Char {
    guid: u64,
    name: &'static str,
    race: u8,
    class: u8,
    level: u8,
    skills: Vec<u16>,
}

#[derive(Clone)]
struct Account {
    pass: &'static str,
    chars: Vec<Char>,
    money: u32,
}

fn accounts() -> HashMap<String, Account> {
    let mut m = HashMap::new();
    m.insert(
        "HERALD".to_string(),
        Account {
            pass: "pw-herald",
            chars: vec![
                Char {
                    guid: 0x12,
                    name: "Alt",
                    race: 1,
                    class: 1,
                    level: 1,
                    skills: vec![43, 98],
                },
                Char {
                    guid: 0x10,
                    name: "Herald",
                    race: 1,
                    class: 3,
                    level: 5,
                    skills: vec![45, 44, 46, 173, 98],
                },
            ],
            money: 120,
        },
    );
    m.insert(
        "BOTHUNTER".to_string(),
        Account {
            pass: "pw-bot",
            chars: vec![Char {
                guid: BOT_GUID,
                name: "Huntbot",
                race: 1,
                class: 3,
                level: 1,
                skills: vec![45, 44],
            }],
            money: 0,
        },
    );
    m.insert(
        "HERALD2".to_string(),
        Account {
            pass: "pw-two",
            chars: vec![Char {
                guid: 0x11,
                name: "Herald2",
                race: 1,
                class: 3,
                level: 3,
                skills: vec![45, 44],
            }],
            money: 10,
        },
    );
    m
}

struct Realm {
    accounts: Mutex<HashMap<String, Account>>,
    keys: Mutex<HashMap<String, [u8; 40]>>,
    /// channel (lowercase) -> session ids
    channels: Mutex<HashMap<String, Vec<u64>>>,
    sessions: Mutex<HashMap<u64, (u64, String, Sender<(u16, Vec<u8>)>)>>,
    next_session: AtomicU64,
    /// The bot world's end state, written at logout.
    bot_report: Mutex<Option<String>>,
}

// ── SRP6 server side ───────────────────────────────────────────────────────────────────────────

fn sha1(parts: &[&[u8]]) -> [u8; 20] {
    let mut h = Sha1::new();
    for p in parts {
        h.update(p);
    }
    h.finalize().into()
}

fn le(b: &[u8]) -> BigInt {
    BigInt::from_bytes_le(Sign::Plus, b)
}

fn pad32(v: &BigInt) -> [u8; 32] {
    let (_, b) = v.to_bytes_le();
    let mut o = [0u8; 32];
    o[..b.len()].copy_from_slice(&b);
    o
}

fn interleave(s: &[u8; 32]) -> [u8; 40] {
    let even: Vec<u8> = s.iter().step_by(2).copied().collect();
    let odd: Vec<u8> = s.iter().skip(1).step_by(2).copied().collect();
    let (g, h) = (sha1(&[&even]), sha1(&[&odd]));
    let mut out = [0u8; 40];
    for i in 0..20 {
        out[2 * i] = g[i];
        out[2 * i + 1] = h[i];
    }
    out
}

fn read_n(s: &mut TcpStream, n: usize) -> Option<Vec<u8>> {
    let mut b = vec![0u8; n];
    s.read_exact(&mut b).ok()?;
    Some(b)
}

fn realmd_session(
    mut s: TcpStream,
    realm: Arc<Realm>,
    address: String,
    counter: u64,
) -> Option<()> {
    let head = read_n(&mut s, 4)?;
    assert_eq!(head[0], 0x00, "logon challenge opcode");
    let size = u16::from_le_bytes([head[2], head[3]]) as usize;
    let body = read_n(&mut s, size)?;
    let name_len = body[29] as usize;
    let user = String::from_utf8(body[30..30 + name_len].to_vec()).unwrap();
    let acct = realm.accounts.lock().unwrap().get(&user).cloned();
    let Some(acct) = acct else {
        s.write_all(&[0x00, 0x00, 0x04]).ok()?;
        return Some(());
    };
    let n = le(&LARGE_SAFE_PRIME_LITTLE_ENDIAN);
    let g = BigInt::from(GENERATOR);
    let mut salt = sha1(&[b"salt", user.as_bytes()]).repeat(2)[..32].to_vec();
    salt[31] |= 0x80;
    let salt: [u8; 32] = salt.try_into().unwrap();
    let un = NormalizedString::new(&user).unwrap();
    let pn = NormalizedString::new(acct.pass).unwrap();
    let v = le(&benilla_srp::password_verifier(&un, &pn, &salt));
    let b = le(&sha1(&[b"b", &counter.to_le_bytes()]).repeat(2)[..32]);
    let big_b = (BigInt::from(3) * &v + g.modpow(&b, &n)) % &n;
    let big_b32 = pad32(&big_b);

    let mut p = vec![0x00, 0x00, 0x00];
    p.extend_from_slice(&big_b32);
    p.extend_from_slice(&[1, GENERATOR, 32]);
    p.extend_from_slice(&LARGE_SAFE_PRIME_LITTLE_ENDIAN);
    p.extend_from_slice(&salt);
    p.extend_from_slice(&[
        0xba, 0xa3, 0x1e, 0x99, 0xa0, 0x0b, 0x21, 0x57, 0xfc, 0x37, 0x3f, 0xb3, 0x69, 0xcd, 0xd2,
        0xf1,
    ]);
    p.push(0);
    s.write_all(&p).ok()?;

    let proof = read_n(&mut s, 75)?;
    assert_eq!(proof[0], 0x01);
    let a32: [u8; 32] = proof[1..33].try_into().unwrap();
    let m1: [u8; 20] = proof[33..53].try_into().unwrap();
    let a = le(&a32);
    let u = le(&sha1(&[&a32, &big_b32]));
    let s_val = (a * v.modpow(&u, &n)).modpow(&b, &n);
    let k = interleave(&pad32(&s_val));
    let (hn, hg) = (
        sha1(&[&LARGE_SAFE_PRIME_LITTLE_ENDIAN]),
        sha1(&[&[GENERATOR]]),
    );
    let xor: Vec<u8> = hn.iter().zip(hg.iter()).map(|(x, y)| x ^ y).collect();
    let expect_m1 = sha1(&[&xor, &sha1(&[user.as_bytes()]), &salt, &a32, &big_b32, &k]);
    if expect_m1 != m1 {
        s.write_all(&[0x01, 0x04]).ok()?;
        return Some(());
    }
    let m2 = sha1(&[&a32, &m1, &k]);
    let mut p = vec![0x01, 0x00];
    p.extend_from_slice(&m2);
    p.extend_from_slice(&0u32.to_le_bytes());
    s.write_all(&p).ok()?;
    realm.keys.lock().unwrap().insert(user.clone(), k);

    // realm list requests until the client hangs up
    loop {
        let req = read_n(&mut s, 5)?;
        assert_eq!(req[0], 0x10);
        let mut r = Vec::new();
        r.extend_from_slice(&0u32.to_le_bytes());
        r.push(0);
        r.extend_from_slice(b"Test Realm\0");
        r.extend_from_slice(address.as_bytes());
        r.push(0);
        r.extend_from_slice(&1.0f32.to_le_bytes());
        r.extend_from_slice(&[acct.chars.len() as u8, 1, 1]);
        let mut p = vec![0x10];
        p.extend_from_slice(&((4 + 1 + r.len() + 2) as u16).to_le_bytes());
        p.extend_from_slice(&0u32.to_le_bytes());
        p.push(1);
        p.extend_from_slice(&r);
        p.extend_from_slice(&0u16.to_le_bytes());
        s.write_all(&p).ok()?;
    }
}

// ── world packets ──────────────────────────────────────────────────────────────────────────────

fn cstr(b: &mut Vec<u8>, s: &str) {
    b.extend_from_slice(s.as_bytes());
    b.push(0);
}

fn enum_entry(c: &Char) -> Vec<u8> {
    let mut b = Vec::new();
    b.extend_from_slice(&c.guid.to_le_bytes());
    cstr(&mut b, c.name);
    b.extend_from_slice(&[c.race, c.class, 0, 1, 1, 1, 1, 1, c.level]);
    b.extend_from_slice(&1519u32.to_le_bytes()); // zone: Stormwind City
    b.extend_from_slice(&0u32.to_le_bytes()); // map
    for f in [-8920.0f32, 610.0, 99.6] {
        b.extend_from_slice(&f.to_le_bytes());
    }
    b.extend_from_slice(&0u32.to_le_bytes()); // guild
    b.extend_from_slice(&0u32.to_le_bytes()); // flags
    b.push(0); // first login
    b.extend_from_slice(&[0u8; 12]); // pet display, level, family
    for _ in 0..19 {
        b.extend_from_slice(&0u32.to_le_bytes());
        b.push(0);
    }
    b.extend_from_slice(&0u32.to_le_bytes());
    b.push(0);
    b
}

fn values_block(fields: &mut Vec<(u16, u32)>) -> Vec<u8> {
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

fn create_block(guid: u64, obj_type: u8, pos: [f32; 3], fields: &mut Vec<(u16, u32)>) -> Vec<u8> {
    let mut b = vec![2u8]; // UPDATETYPE_CREATE_OBJECT
    write_packed_guid(guid, &mut b).unwrap();
    b.push(obj_type);
    b.push(0x20); // UPDATEFLAG_LIVING
    b.extend_from_slice(&0u32.to_le_bytes()); // movement flags
    b.extend_from_slice(&0u32.to_le_bytes()); // time
    for f in pos {
        b.extend_from_slice(&f.to_le_bytes());
    }
    b.extend_from_slice(&0f32.to_le_bytes()); // orientation
    b.extend_from_slice(&0u32.to_le_bytes()); // fall time
    for sp in [2.5f32, 7.0, 4.5, 4.722, 2.5, std::f32::consts::PI] {
        b.extend_from_slice(&sp.to_le_bytes());
    }
    b.extend(values_block(fields));
    b
}

fn update_object(blocks: Vec<Vec<u8>>) -> Vec<u8> {
    let mut b = (blocks.len() as u32).to_le_bytes().to_vec();
    b.push(0); // has transport
    for bl in blocks {
        b.extend(bl);
    }
    b
}

fn player_create(c: &Char, pos: [f32; 3]) -> Vec<u8> {
    let mut f = vec![
        (0u16, c.guid as u32),
        (1, (c.guid >> 32) as u32),
        (2, 0x19),
        (4, 1.0f32.to_bits()),
    ];
    for (slot, id) in c.skills.iter().enumerate() {
        let base = FIELD_SKILL + 3 * slot as u16;
        f.push((base, u32::from(*id)));
        f.push((base + 1, 1 | (300 << 16)));
    }
    create_block(c.guid, 4, pos, &mut f)
}

fn vendor_create(pos: [f32; 3]) -> Vec<u8> {
    let mut f = vec![
        (0u16, VENDOR_GUID as u32),
        (1, (VENDOR_GUID >> 32) as u32),
        (2, 0x09),
        (3, VENDOR_ENTRY),
        (4, 1.0f32.to_bits()),
        (147, 0x4 | 0x1), // UNIT_NPC_FLAGS: vendor + gossip
    ];
    create_block(VENDOR_GUID, 3, pos, &mut f)
}

fn chat_packet(
    chat_type: u8,
    lang: u32,
    sender: u64,
    channel: Option<&str>,
    text: &str,
) -> Vec<u8> {
    let mut b = vec![chat_type];
    b.extend_from_slice(&lang.to_le_bytes());
    match chat_type {
        0x0E => {
            cstr(&mut b, channel.unwrap());
            b.extend_from_slice(&0u32.to_le_bytes());
            b.extend_from_slice(&sender.to_le_bytes());
        }
        0x00 | 0x01 | 0x05 => {
            b.extend_from_slice(&sender.to_le_bytes());
            b.extend_from_slice(&sender.to_le_bytes());
        }
        _ => b.extend_from_slice(&sender.to_le_bytes()),
    }
    b.extend_from_slice(&((text.len() + 1) as u32).to_le_bytes());
    cstr(&mut b, text);
    b.push(0);
    b
}

/// WNL lines as `WnlFormat::Lines` makes them, but with a small chunk size so a multi-part body
/// is exercised.
fn wnl_lines(tag: &str, seq: u32, body: &str, chunk: usize) -> Vec<String> {
    let n = if body.is_empty() {
        1
    } else {
        body.len().div_ceil(chunk)
    };
    (0..n)
        .map(|i| {
            let part = body
                .get(i * chunk..((i + 1) * chunk).min(body.len()))
                .unwrap_or("");
            format!("WNL\t{tag} {seq} {}/{n} {part}", i + 1)
        })
        .collect()
}

fn read_cstr(b: &[u8], at: &mut usize) -> String {
    let end = b[*at..].iter().position(|&c| c == 0).unwrap() + *at;
    let s = String::from_utf8_lossy(&b[*at..end]).into_owned();
    *at = end + 1;
    s
}

fn world_session(mut s: TcpStream, realm: Arc<Realm>) -> Option<()> {
    let server_seed: u32 = 0xC0FF_EE11;
    let mut p = Vec::new();
    p.extend_from_slice(&6u16.to_be_bytes());
    p.extend_from_slice(&opcode::SMSG_AUTH_CHALLENGE.to_le_bytes());
    p.extend_from_slice(&server_seed.to_le_bytes());
    s.write_all(&p).ok()?;

    let h = read_n(&mut s, 6)?;
    let size = u16::from_be_bytes([h[0], h[1]]) as usize;
    let op = u32::from_le_bytes([h[2], h[3], h[4], h[5]]);
    assert_eq!(op, u32::from(opcode::CMSG_AUTH_SESSION));
    let body = read_n(&mut s, size - 4)?;
    let mut at = 8;
    let account = read_cstr(&body, &mut at);
    let client_seed: [u8; 4] = body[at..at + 4].try_into().unwrap();
    let digest: [u8; 20] = body[at + 4..at + 24].try_into().unwrap();
    let key = realm.keys.lock().unwrap().get(&account).copied()?;
    let expect = sha1(&[
        account.as_bytes(),
        &[0u8; 4],
        &client_seed,
        &server_seed.to_le_bytes(),
        &key,
    ]);
    assert_eq!(
        digest, expect,
        "CMSG_AUTH_SESSION digest binds the SRP session key"
    );

    let (mut enc, mut dec) = HeaderCrypto::from_session_key(key).split();
    let (tx, rx) = mpsc::channel::<(u16, Vec<u8>)>();
    let mut w = s.try_clone().ok()?;
    thread::spawn(move || {
        for (op, body) in rx {
            let size = (body.len() + 2) as u16;
            let sb = size.to_be_bytes();
            let ob = op.to_le_bytes();
            let mut hdr = [sb[0], sb[1], ob[0], ob[1]];
            enc.encrypt(&mut hdr);
            let mut pkt = hdr.to_vec();
            pkt.extend_from_slice(&body);
            if w.write_all(&pkt).is_err() {
                break;
            }
        }
    });
    let send = |op: u16, body: Vec<u8>| {
        let _ = tx.send((op, body));
    };
    send(
        opcode::SMSG_AUTH_RESPONSE,
        vec![messages::AUTH_OK, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    );

    let sid = realm.next_session.fetch_add(1, Ordering::SeqCst);
    let acct = realm.accounts.lock().unwrap().get(&account).cloned()?;
    let mut me: Option<Char> = None;
    let mut greeted = false;
    let mut seq = 0u32;
    let mut bot: Option<BotWorld> = None;

    loop {
        let mut h = read_n(&mut s, 6)?;
        dec.decrypt(&mut h);
        let size = u16::from_be_bytes([h[0], h[1]]) as usize;
        let op = u32::from_le_bytes([h[2], h[3], h[4], h[5]]) as u16;
        let body = read_n(&mut s, size - 4)?;
        if let Some(w) = bot.as_mut() {
            for (o, b) in bot_handle(w, op, &body) {
                send(o, b);
            }
            if op == opcode::CMSG_LOGOUT_REQUEST {
                *realm.bot_report.lock().unwrap() = Some(format!(
                    "quest={} dead={} looted={} heartbeats={} starts={} stops={} violations={:?}",
                    w.quest, w.mob_dead, w.looted, w.heartbeats, w.starts, w.stops, w.violations
                ));
            }
        }
        match op {
            opcode::CMSG_CHAR_ENUM => {
                let mut b = vec![acct.chars.len() as u8];
                for c in &acct.chars {
                    b.extend(enum_entry(c));
                }
                send(opcode::SMSG_CHAR_ENUM, b);
            }
            opcode::CMSG_PLAYER_LOGIN => {
                let guid = u64::from_le_bytes(body[..8].try_into().unwrap());
                let c = acct.chars.iter().find(|c| c.guid == guid)?.clone();
                let pos = [-8925.0f32, 607.0, 99.6];
                let mut v = 0u32.to_le_bytes().to_vec();
                for f in [pos[0], pos[1], pos[2], 0.0] {
                    v.extend_from_slice(&f.to_le_bytes());
                }
                send(opcode::SMSG_LOGIN_VERIFY_WORLD, v);
                if c.guid == BOT_GUID {
                    for (op, b) in bot_login_packets(&c) {
                        send(op, b);
                    }
                    bot = Some(BotWorld {
                        pos: LOGIN_POS,
                        ..Default::default()
                    });
                    realm
                        .sessions
                        .lock()
                        .unwrap()
                        .insert(sid, (c.guid, c.name.to_string(), tx.clone()));
                    me = Some(c);
                    continue;
                }
                send(
                    opcode::SMSG_UPDATE_OBJECT,
                    update_object(vec![
                        player_create(&c, pos),
                        vendor_create([-8925.9, 608.6, 99.61]),
                    ]),
                );
                send(
                    opcode::SMSG_MESSAGECHAT,
                    chat_packet(
                        0x01,
                        messages::LANGUAGE_ADDON,
                        c.guid,
                        None,
                        "WNL\tHI 1 Quests,Threat,Prices,Plates,Achievements",
                    ),
                );
                realm
                    .sessions
                    .lock()
                    .unwrap()
                    .insert(sid, (c.guid, c.name.to_string(), tx.clone()));
                me = Some(c);
            }
            opcode::CMSG_MESSAGECHAT => {
                let Some(c) = &me else { continue };
                let t = u32::from_le_bytes(body[..4].try_into().unwrap());
                let mut at = 8;
                let target = (t == 6 || t == 0xE).then(|| read_cstr(&body, &mut at));
                let text = read_cstr(&body, &mut at);
                let addon = |s: &str| chat_packet(0x01, messages::LANGUAGE_ADDON, c.guid, None, s);
                if text.starts_with(".wnl ") {
                    let cmd = text[5..].split_whitespace().next().unwrap_or("");
                    match cmd {
                        "hi" => {
                            greeted = true;
                        }
                        "lg" if greeted => {
                            // the faction auction house's market: "<item>,<median>,<vendor>,<samples>"
                            let item = text[5..].split_whitespace().nth(1).unwrap_or("0");
                            seq += 1;
                            for l in wnl_lines("LG", seq, &format!("{item},0,0,0"), 200) {
                                send(opcode::SMSG_MESSAGECHAT, addon(&l));
                            }
                        }
                        _ => {}
                    }
                } else if text.starts_with('.') {
                    send(
                        opcode::SMSG_MESSAGECHAT,
                        chat_packet(0x0A, 0, 0, None, "There is no such command."),
                    );
                } else if t == 0xE {
                    let ch = target.unwrap_or_default();
                    let members = realm
                        .channels
                        .lock()
                        .unwrap()
                        .get(&ch.to_lowercase())
                        .cloned()
                        .unwrap_or_default();
                    let sessions = realm.sessions.lock().unwrap();
                    for m in members {
                        if let Some((_, _, out)) = sessions.get(&m) {
                            let _ = out.send((
                                opcode::SMSG_MESSAGECHAT,
                                chat_packet(0x0E, 7, c.guid, Some(&ch), &text),
                            ));
                        }
                    }
                } else {
                    send(
                        opcode::SMSG_MESSAGECHAT,
                        chat_packet(0x00, 7, c.guid, None, &text),
                    );
                }
            }
            opcode::CMSG_JOIN_CHANNEL => {
                let mut at = 0;
                let name = read_cstr(&body, &mut at);
                realm
                    .channels
                    .lock()
                    .unwrap()
                    .entry(name.to_lowercase())
                    .or_default()
                    .push(sid);
                let mut b = vec![messages::channel_notice::YOU_JOINED];
                cstr(&mut b, &name);
                b.extend_from_slice(&0u32.to_le_bytes());
                b.extend_from_slice(&0u32.to_le_bytes());
                send(opcode::SMSG_CHANNEL_NOTIFY, b);
            }
            opcode::CMSG_LEAVE_CHANNEL => {
                let mut at = 0;
                let name = read_cstr(&body, &mut at);
                if let Some(v) = realm.channels.lock().unwrap().get_mut(&name.to_lowercase()) {
                    v.retain(|&x| x != sid);
                }
                let mut b = vec![messages::channel_notice::YOU_LEFT];
                cstr(&mut b, &name);
                send(opcode::SMSG_CHANNEL_NOTIFY, b);
            }
            opcode::CMSG_NAME_QUERY => {
                let guid = u64::from_le_bytes(body[..8].try_into().unwrap());
                let name = realm
                    .sessions
                    .lock()
                    .unwrap()
                    .values()
                    .find(|(g, _, _)| *g == guid)
                    .map(|(_, n, _)| n.clone())
                    .unwrap_or_default();
                let mut b = guid.to_le_bytes().to_vec();
                cstr(&mut b, &name);
                b.push(0);
                for v in [1u32, 0, 3] {
                    b.extend_from_slice(&v.to_le_bytes());
                }
                send(opcode::SMSG_NAME_QUERY_RESPONSE, b);
            }
            opcode::CMSG_SET_SELECTION => {}
            opcode::CMSG_LIST_INVENTORY => {
                let guid = u64::from_le_bytes(body[..8].try_into().unwrap());
                if guid == VENDOR_GUID {
                    let mut b = guid.to_le_bytes().to_vec();
                    b.push(1);
                    for v in [1u32, WARE, 0, u32::MAX, WARE_PRICE, 0, 1] {
                        b.extend_from_slice(&v.to_le_bytes());
                    }
                    send(opcode::SMSG_LIST_INVENTORY, b);
                }
            }
            opcode::CMSG_BUY_ITEM => {
                let vendor = u64::from_le_bytes(body[..8].try_into().unwrap());
                let entry = u32::from_le_bytes(body[8..12].try_into().unwrap());
                let paid = {
                    let mut a = realm.accounts.lock().unwrap();
                    let a = a.get_mut(&account).unwrap();
                    if vendor == VENDOR_GUID && entry == WARE && a.money >= WARE_PRICE {
                        a.money -= WARE_PRICE;
                        true
                    } else {
                        false
                    }
                };
                if paid {
                    let mut b = vendor.to_le_bytes().to_vec();
                    for v in [1u32, u32::MAX, 1] {
                        b.extend_from_slice(&v.to_le_bytes());
                    }
                    send(opcode::SMSG_BUY_ITEM, b);
                } else {
                    let mut b = vendor.to_le_bytes().to_vec();
                    b.extend_from_slice(&entry.to_le_bytes());
                    b.push(messages::buy_result::NOT_ENOUGH_MONEY);
                    send(opcode::SMSG_BUY_FAILED, b);
                }
            }
            opcode::CMSG_LOGOUT_REQUEST => {
                let mut b = 0u32.to_le_bytes().to_vec();
                b.push(1);
                send(opcode::SMSG_LOGOUT_RESPONSE, b);
                send(opcode::SMSG_LOGOUT_COMPLETE, vec![]);
                realm.sessions.lock().unwrap().remove(&sid);
                for v in realm.channels.lock().unwrap().values_mut() {
                    v.retain(|&x| x != sid);
                }
                me = None;
            }
            opcode::CMSG_PING => {
                send(opcode::SMSG_PONG, body[..4].to_vec());
            }
            _ => {}
        }
    }
}

// ── fake web service ───────────────────────────────────────────────────────────────────────────

const WEB_USER: &str = "webherald";
const WEB_PASS: &str = "web pass&=1";

fn read_head(s: &mut TcpStream) -> Option<(String, String, HashMap<String, String>, Vec<u8>)> {
    let mut buf = Vec::new();
    let mut b = [0u8; 1];
    while !buf.ends_with(b"\r\n\r\n") {
        if s.read(&mut b).ok()? == 0 {
            return None;
        }
        buf.push(b[0]);
    }
    let head = String::from_utf8_lossy(&buf).into_owned();
    let mut lines = head.split("\r\n");
    let mut rl = lines.next()?.split(' ');
    let method = rl.next()?.to_string();
    let path = rl.next()?.to_string();
    let mut headers = HashMap::new();
    for l in lines {
        if let Some((k, v)) = l.split_once(':') {
            headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
        }
    }
    let len: usize = headers
        .get("content-length")
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    let body = read_n(s, len)?;
    Some((method, path, headers, body))
}

fn url_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'+' => out.push(b' '),
            b'%' => {
                out.push(u8::from_str_radix(&s[i + 1..i + 3], 16).unwrap());
                i += 2;
            }
            c => out.push(c),
        }
        i += 1;
    }
    String::from_utf8(out).unwrap()
}

fn web_conn(mut s: TcpStream, realmd: u16, world: u16, cookie: Arc<Mutex<String>>) {
    let mut peek = [0u8; 16];
    let n = s.peek(&mut peek).unwrap_or(0);
    if peek[..n].starts_with(b"GET /ws/") {
        let current = cookie.lock().unwrap().clone();
        let mut port = 0u16;
        let ws = tungstenite::accept_hdr(
            s.try_clone().unwrap(),
            |req: &tungstenite::handshake::server::Request, resp| {
                let ok = req
                    .headers()
                    .get("cookie")
                    .and_then(|v| v.to_str().ok())
                    .is_some_and(|c| c.contains(&format!("wr_session={current}")));
                let p: u16 = req
                    .uri()
                    .path()
                    .trim_start_matches("/ws/")
                    .parse()
                    .unwrap_or(0);
                if !ok {
                    let mut e = tungstenite::handshake::server::ErrorResponse::new(None);
                    *e.status_mut() = tungstenite::http::StatusCode::UNAUTHORIZED;
                    return Err(e);
                }
                if p != 3724 && p != 8085 {
                    let mut e = tungstenite::handshake::server::ErrorResponse::new(None);
                    *e.status_mut() = tungstenite::http::StatusCode::FORBIDDEN;
                    return Err(e);
                }
                port = p;
                Ok(resp)
            },
        );
        let Ok(ws) = ws else { return };
        let upstream = if port == 3724 { realmd } else { world };
        let tcp = TcpStream::connect(("127.0.0.1", upstream)).unwrap();
        ws.get_ref()
            .set_read_timeout(Some(Duration::from_millis(10)))
            .unwrap();
        let ws = Arc::new(Mutex::new(ws));
        let ws2 = Arc::clone(&ws);
        let mut tcp_r = tcp.try_clone().unwrap();
        thread::spawn(move || {
            let mut buf = [0u8; 4096];
            loop {
                match tcp_r.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        if ws2
                            .lock()
                            .unwrap()
                            .send(tungstenite::Message::Binary(buf[..n].to_vec()))
                            .is_err()
                        {
                            break;
                        }
                    }
                }
            }
            let _ = ws2.lock().unwrap().close(None);
        });
        let mut tcp_w = tcp;
        loop {
            let m = ws.lock().unwrap().read();
            match m {
                Ok(tungstenite::Message::Binary(b)) => {
                    if tcp_w.write_all(&b).is_err() {
                        break;
                    }
                }
                Ok(tungstenite::Message::Close(_)) => break,
                Ok(_) => {}
                Err(tungstenite::Error::Io(e))
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    thread::sleep(Duration::from_millis(1));
                }
                Err(_) => break,
            }
        }
        let _ = tcp_w.shutdown(Shutdown::Both);
        return;
    }
    let Some((method, path, headers, body)) = read_head(&mut s) else {
        return;
    };
    let reply = match (method.as_str(), path.as_str()) {
        ("POST", "/login") => {
            let form: HashMap<String, String> = String::from_utf8_lossy(&body)
                .split('&')
                .filter_map(|kv| kv.split_once('='))
                .map(|(k, v)| (k.to_string(), url_decode(v)))
                .collect();
            if form.get("username").map(String::as_str) == Some(WEB_USER)
                && form.get("password").map(String::as_str) == Some(WEB_PASS)
            {
                let c = cookie.lock().unwrap().clone();
                format!("HTTP/1.1 303 See Other\r\nLocation: /\r\nSet-Cookie: wr_session={c}; HttpOnly; Secure; SameSite=Lax; Path=/\r\nContent-Length: 0\r\n\r\n")
            } else {
                let page = "<html><p class=\"error\">wrong username or password</p></html>";
                format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{page}",
                    page.len()
                )
            }
        }
        ("GET", "/api/play") => {
            let current = cookie.lock().unwrap().clone();
            let ok = headers
                .get("cookie")
                .is_some_and(|c| c.contains(&format!("wr_session={current}")))
                && headers.get("x-requested-with").map(String::as_str) == Some("wenilla");
            if ok {
                // rotate the session token, as require_session may
                let fresh = format!("{current}r");
                *cookie.lock().unwrap() = fresh.clone();
                let json = r#"{"user":"herald","pass":"pw-herald","host":"play.test","realm":"Test Realm"}"#;
                let (a, b) = json.split_at(20);
                format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nSet-Cookie: wr_session={fresh}; Path=/\r\nTransfer-Encoding: chunked\r\n\r\n{:x}\r\n{a}\r\n{:x}\r\n{b}\r\n0\r\n\r\n",
                    a.len(),
                    b.len()
                )
            } else {
                "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n".to_string()
            }
        }
        _ => "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".to_string(),
    };
    let _ = s.write_all(reply.as_bytes());
    let _ = s.shutdown(Shutdown::Both);
}

// ── harness ────────────────────────────────────────────────────────────────────────────────────

struct Universe {
    realmd: u16,
    web: u16,
    realm: Arc<Realm>,
}

fn listen() -> (TcpListener, u16) {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let p = l.local_addr().unwrap().port();
    (l, p)
}

/// `web_address`: the realm list advertises `play.test:8085` (as REALM_DOMAIN:8085 behind the
/// relay) instead of the direct world address.
fn universe(web_address: bool) -> Universe {
    let realm = Arc::new(Realm {
        accounts: Mutex::new(accounts()),
        keys: Mutex::new(HashMap::new()),
        channels: Mutex::new(HashMap::new()),
        sessions: Mutex::new(HashMap::new()),
        next_session: AtomicU64::new(1),
        bot_report: Mutex::new(None),
    });
    let (wl, world) = listen();
    let r = Arc::clone(&realm);
    thread::spawn(move || {
        for s in wl.incoming().flatten() {
            let r = Arc::clone(&r);
            thread::spawn(move || world_session(s, r));
        }
    });
    let (rl, realmd) = listen();
    let address = if web_address {
        "play.test:8085".to_string()
    } else {
        format!("127.0.0.1:{world}")
    };
    let r = Arc::clone(&realm);
    thread::spawn(move || {
        let mut n = 0u64;
        for s in rl.incoming().flatten() {
            n += 1;
            let (r, a) = (Arc::clone(&r), address.clone());
            thread::spawn(move || realmd_session(s, r, a, n));
        }
    });
    let (hl, web) = listen();
    let cookie = Arc::new(Mutex::new("tok1".to_string()));
    thread::spawn(move || {
        for s in hl.incoming().flatten() {
            let c = Arc::clone(&cookie);
            thread::spawn(move || web_conn(s, realmd, world, c));
        }
    });
    Universe { realmd, web, realm }
}

fn scenario(name: &str) -> String {
    format!("{}/scenarios/{name}", env!("CARGO_MANIFEST_DIR"))
}

/// A test-only scenario under tests/fixtures (talks to the fake realm's vendor).
fn fixture(name: &str) -> String {
    format!("{}/tests/fixtures/{name}", env!("CARGO_MANIFEST_DIR"))
}

fn run(args: &[&str], env: &[(&str, &str)]) -> (i32, serde_json::Value) {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_heraldlite"));
    cmd.args(args);
    for k in [
        "HL_HOST", "HL_WEB", "HL_USER", "HL_PASS", "HL_CHAR", "HL_REALM", "HL_WORLD", "HL_USER2",
        "HL_PASS2", "HL_CHAR2",
    ] {
        cmd.env_remove(k);
    }
    for (k, v) in env {
        cmd.env(k, v);
    }
    let out = cmd.output().unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    let json: serde_json::Value = serde_json::from_str(stdout.trim()).unwrap_or_else(|e| {
        panic!(
            "stdout is not one JSON report ({e}):\n{stdout}\nstderr:\n{}",
            String::from_utf8_lossy(&out.stderr)
        )
    });
    (out.status.code().unwrap_or(-1), json)
}

fn tcp_args(u: &Universe) -> Vec<String> {
    vec![
        "--host".into(),
        format!("127.0.0.1:{}", u.realmd),
        "--user".into(),
        "herald".into(),
        "--timeout".into(),
        "5".into(),
    ]
}

#[test]
fn encoded_fixtures_decode_with_the_crate() {
    // Guards the fake server: what it writes must be what benilla-protocol reads.
    let c = &accounts()["HERALD"].chars[1];
    let body = update_object(vec![
        player_create(c, [1.0, 2.0, 3.0]),
        vendor_create([4.0, 5.0, 6.0]),
    ]);
    let p = messages::parse_server(opcode::SMSG_UPDATE_OBJECT, &body).unwrap();
    let evs = benilla_protocol::decode(p);
    let mut saw_player = false;
    let mut saw_vendor = false;
    for e in evs {
        if let benilla_protocol::SessionEvent::ObjectCreate {
            guid, fields, kind, ..
        } = e
        {
            if guid == c.guid {
                assert_eq!(kind, benilla_protocol::EntityKind::Player);
                assert_eq!(fields.player_skill(0).unwrap().skill_id, 45);
                saw_player = true;
            }
            if guid == VENDOR_GUID {
                assert_eq!(fields.object_entry(), Some(VENDOR_ENTRY));
                assert_eq!(fields.unit_npc_flags() & 0x4, 0x4);
                saw_vendor = true;
            }
        }
    }
    assert!(saw_player && saw_vendor);
    let p = messages::parse_server(opcode::SMSG_CHAR_ENUM, &{
        let mut b = vec![1u8];
        b.extend(enum_entry(c));
        b
    })
    .unwrap();
    assert_eq!(p.name(), "SMSG_CHAR_ENUM");
}

#[test]
fn tcp_smoke_passes_and_reports() {
    let u = universe(false);
    let mut args = tcp_args(&u);
    args.extend(["--scenario".into(), scenario("smoke.txt")]);
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let (code, r) = run(&args, &[("HL_PASS", "pw-herald")]);
    assert_eq!(code, 0, "{r:#}");
    eprintln!("{r:#}");
    assert_eq!(r["ok"], true);
    assert_eq!(r["mode"], "tcp");
    assert_eq!(r["fail"], 0);
    assert!(r["pass"].as_u64().unwrap() >= 6);
    let names: Vec<&str> = r["characters"]
        .as_array()
        .unwrap()
        .iter()
        .map(|c| c["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["Alt", "Herald"]);
    assert_eq!(r["clients"][0]["realm"], "Test Realm");
    assert!(r["clients"][0]["bytes_down"].as_u64().unwrap() > 0);
    assert!(r["scenarios"][0]["steps"][0]["ms"].is_u64());
}

#[test]
fn tcp_all_shipped_scenarios_pass_against_the_fake() {
    let u = universe(false);
    let mut args = tcp_args(&u);
    for s in [
        scenario("smoke.txt"),
        scenario("skills.txt"),
        scenario("persona_pair.txt"),
        fixture("vendor_buy.txt"),
    ] {
        args.extend(["-s".into(), s]);
    }
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let (code, r) = run(
        &args,
        &[
            ("HL_PASS", "pw-herald"),
            ("HL_USER2", "herald2"),
            ("HL_PASS2", "pw-two"),
        ],
    );
    assert_eq!(code, 0, "{r:#}");
    assert_eq!(r["scenarios"].as_array().unwrap().len(), 4);
    // the vendor fixture bought one ware for 50 copper: 120 -> 70
    let money = u.realm.accounts.lock().unwrap()["HERALD"].money;
    assert_eq!(money, 70);
    let b = r["clients"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["label"] == "b")
        .unwrap();
    assert_eq!(b["game_account"], "herald2");
}

#[test]
fn wrong_password_is_exit_2() {
    let u = universe(false);
    let args = tcp_args(&u);
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let (code, r) = run(&args, &[("HL_PASS", "nope")]);
    assert_eq!(code, 2, "{r:#}");
    let f = r["failures"][0].as_str().unwrap();
    assert!(f.contains("unknown account or wrong password"), "{f}");
}

#[test]
fn unknown_character_is_exit_2() {
    let u = universe(false);
    let mut args = tcp_args(&u);
    args.extend(["--char".into(), "Nobody".into()]);
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let (code, r) = run(&args, &[("HL_PASS", "pw-herald")]);
    assert_eq!(code, 2, "{r:#}");
    let f = r["failures"][0].as_str().unwrap();
    assert!(
        f.contains("no character \"Nobody\"") && f.contains("Alt, Herald"),
        "{f}"
    );
}

#[test]
fn a_failed_check_is_exit_1_with_a_reason() {
    let u = universe(false);
    let mut args = tcp_args(&u);
    // Alt is a warrior without bows
    args.extend([
        "--char".into(),
        "Alt".into(),
        "-s".into(),
        scenario("skills.txt"),
    ]);
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let (code, r) = run(&args, &[("HL_PASS", "pw-herald")]);
    assert_eq!(code, 1, "{r:#}");
    let f = r["failures"][0].as_str().unwrap();
    assert!(
        f.contains("bows (45) missing; the player has skills [43, 98]"),
        "{f}"
    );
    // the run still logged out cleanly at the end
    let steps = r["scenarios"][0]["steps"].as_array().unwrap();
    assert_eq!(steps.last().unwrap()["ok"], true);
}

#[test]
fn vendor_without_enough_money_fails_on_the_buy() {
    let u = universe(false);
    u.realm
        .accounts
        .lock()
        .unwrap()
        .get_mut("HERALD")
        .unwrap()
        .money = 10;
    let mut args = tcp_args(&u);
    args.extend(["-s".into(), fixture("vendor_buy.txt")]);
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let (code, r) = run(&args, &[("HL_PASS", "pw-herald")]);
    assert_eq!(code, 1, "{r:#}");
    let f = r["failures"].as_array().unwrap();
    assert!(f[0].as_str().unwrap().contains("not enough money"), "{f:?}");
}

#[test]
fn web_mode_logs_in_fetches_the_credential_and_uses_the_relay() {
    let u = universe(true);
    let url = format!("http://127.0.0.1:{}", u.web);
    let (code, r) = run(
        &[
            "--web",
            &url,
            "--timeout",
            "5",
            "-s",
            &scenario("smoke.txt"),
        ],
        &[
            ("HL_USER", WEB_USER),
            ("HL_PASS", WEB_PASS),
            ("HL_CHAR", "Herald"),
        ],
    );
    assert_eq!(code, 0, "{r:#}");
    assert_eq!(r["mode"], "web");
    assert_eq!(r["clients"][0]["game_account"], "herald");
    assert_eq!(r["clients"][0]["realm"], "Test Realm");
    assert!(r["clients"][0]["timings"]["web_ms"].is_u64());
}

#[test]
fn web_mode_wrong_password_is_exit_2() {
    let u = universe(true);
    let url = format!("http://127.0.0.1:{}", u.web);
    let (code, r) = run(
        &["--web", &url, "--timeout", "5"],
        &[("HL_USER", WEB_USER), ("HL_PASS", "bad")],
    );
    assert_eq!(code, 2, "{r:#}");
    let f = r["failures"][0].as_str().unwrap();
    assert!(
        f.contains("web login refused: wrong username or password"),
        "{f}"
    );
}

#[test]
fn nothing_listening_is_exit_2_with_the_address() {
    let (l, port) = listen();
    drop(l);
    let (code, r) = run(
        &[
            "--host",
            &format!("127.0.0.1:{port}"),
            "--user",
            "x",
            "--timeout",
            "2",
        ],
        &[("HL_PASS", "y")],
    );
    assert_eq!(code, 2, "{r:#}");
    let f = r["failures"][0].as_str().unwrap();
    assert!(
        f.contains("realmd unreachable") && f.contains(&port.to_string()),
        "{f}"
    );
}

#[test]
fn bad_scenario_file_is_reported_before_connecting() {
    let dir = std::env::temp_dir().join(format!("hl-bad-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let f = dir.join("bad.txt");
    std::fs::write(&f, "login\nexpect wnl\n").unwrap();
    let (code, r) = run(
        &[
            "--host",
            "127.0.0.1:1",
            "--user",
            "x",
            "-s",
            f.to_str().unwrap(),
        ],
        &[("HL_PASS", "y")],
    );
    assert_eq!(code, 1);
    assert!(
        r["failures"][0].as_str().unwrap().contains("bad.txt:2"),
        "{r:#}"
    );
}

#[test]
fn autopilot_plays_a_route_against_the_fake_world() {
    let u = universe(false);
    let dir = std::env::temp_dir().join(format!("hl-autopilot-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let route = dir.join("route.json");
    let log = dir.join("run.jsonl");
    let (n, m) = (bot_npc_pos(), bot_mob_pos());
    std::fs::write(
        &route,
        format!(
            r#"{{"minutes_per_level": {{}}, "quest_minutes": {{"7": 1.0}}, "steps": [
            {{"kind": "accept", "quest": 7, "desc": "accept 7 Kobold Camp Cleanup", "pos": [{}, {}], "level": 1}},
            {{"kind": "kill", "entry": 6, "kills": 1, "desc": "quest 7: 1 x Kobold Vermin", "pos": [{}, {}], "level": 1}},
            {{"kind": "turnin", "quest": 7, "desc": "turn in 7 Kobold Camp Cleanup", "pos": [{}, {}], "level": 1}}]}}"#,
            n[0], n[1], m[0], m[1], n[0], n[1]
        ),
    )
    .unwrap();
    let host = format!("127.0.0.1:{}", u.realmd);
    let (code, r) = run(
        &[
            "autopilot",
            "--host",
            &host,
            "--user",
            "bothunter",
            "--route",
            route.to_str().unwrap(),
            "--minutes",
            "2",
            "--log",
            log.to_str().unwrap(),
        ],
        &[("HL_PASS", "pw-bot")],
    );
    let report = u.realm.bot_report.lock().unwrap().clone();
    assert_eq!(code, 0, "{r:#}\nserver: {report:?}");
    let s = &r["summary"];
    let text = std::fs::read_to_string(&log).unwrap();
    assert_eq!(s["end_reason"], "route complete", "{r:#}");
    eprintln!("{text}");
    assert_eq!(s["steps"]["done"], 3);
    assert_eq!(s["kills"], 1);
    assert_eq!(s["loot"]["corpses"], 1);
    assert_eq!(s["quests_rewarded"], 1);
    assert_eq!(s["character"], "Huntbot");
    let report = report.expect("the bot logged out");
    assert!(
        report.starts_with("quest=3 dead=true looted=true"),
        "{report}"
    );
    assert!(report.ends_with("violations=[]"), "{report}");
    let lines: Vec<serde_json::Value> = text
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    assert!(lines
        .iter()
        .any(|l| l["action"] == "logout" && l["result"] == "logged out"));
    assert_eq!(lines.last().unwrap()["event"], "summary");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn autopilot_refuses_hosts_outside_the_allowlist() {
    for host in [
        "10.0.0.7:3724",
        "example.com",
        "play.openvanilla.app.example.com",
    ] {
        let (code, r) = run(
            &[
                "autopilot",
                "--host",
                host,
                "--user",
                "x",
                "--route",
                "nope.json",
            ],
            &[("HL_PASS", "y")],
        );
        assert_eq!(code, 1, "{r:#}");
        assert!(
            r["failures"][0]
                .as_str()
                .unwrap()
                .contains("refusing to run the autopilot"),
            "{r:#}"
        );
    }
    let (code, r) = run(
        &[
            "autopilot",
            "--host",
            "127.0.0.1:1",
            "--world",
            "10.1.1.1:8085",
            "--user",
            "x",
        ],
        &[("HL_PASS", "y")],
    );
    assert_eq!(code, 1, "{r:#}");
}
