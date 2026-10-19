//! Wizards (plan §6.5): the common jobs as one form each, writing ordinary rows the Data screen
//! shows afterwards. Each wizard tags its rows (`comment = "quest:<id>"`, `"item:<id>"`), so saving
//! the form again replaces them instead of adding more.
//!
//! * **Quest**: quest_template + who gives it (creature_questrelation) + who takes it back
//!   (creature_involvedrelation); a giver that is one of the pack's own creatures gets the quest
//!   giver flag.
//! * **Item**: item_template with stats, damage, armour, prices and an icon/model from the game's
//!   ItemDisplayInfo.
//! * **Vendor**: npc_vendor rows (and the vendor flag on the pack's own creature).

use crate::data::{self, save_rows};
use crate::ids::IdLock;
use crate::project::Project;
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use toml::Value;

/// NPC flags (creature_template.NpcFlags, 1.12).
pub const NPC_GOSSIP: i64 = 1;
pub const NPC_QUESTGIVER: i64 = 2;
pub const NPC_VENDOR: i64 = 4;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Pair {
    pub id: i64,
    pub count: i64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct QuestSpec {
    /// Empty: a new ID from the pack's quest range.
    pub id: Option<i64>,
    pub title: String,
    #[serde(default)]
    pub level: i64,
    #[serde(default)]
    pub min_level: i64,
    /// Zone (AreaTable ID, the quest log heading); 0: none.
    #[serde(default)]
    pub zone: i64,
    pub giver: i64,
    /// Default: the giver.
    pub ender: Option<i64>,
    #[serde(default)]
    pub details: String,
    #[serde(default)]
    pub objectives: String,
    #[serde(default)]
    pub request_text: String,
    #[serde(default)]
    pub reward_text: String,
    /// Up to 4 creatures to kill.
    #[serde(default)]
    pub kill: Vec<Pair>,
    /// Up to 4 items to bring.
    #[serde(default)]
    pub collect: Vec<Pair>,
    /// Copper.
    #[serde(default)]
    pub money: i64,
    /// Up to 4 items everyone gets.
    #[serde(default)]
    pub reward_items: Vec<Pair>,
    /// Up to 6 items to choose one from.
    #[serde(default)]
    pub choice_items: Vec<Pair>,
    #[serde(default)]
    pub prev_quest: i64,
    #[serde(default)]
    pub next_in_chain: i64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Stat {
    /// ITEM_MOD_*: 3 agility, 4 strength, 5 intellect, 6 spirit, 7 stamina, 0 mana, 1 health.
    pub kind: i64,
    pub value: i64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ItemSpec {
    pub id: Option<i64>,
    pub name: String,
    #[serde(default)]
    pub quality: i64,
    /// 2 weapon, 4 armour, 0 consumable, 12 quest, 15 misc ...
    #[serde(default)]
    pub class: i64,
    #[serde(default)]
    pub subclass: i64,
    /// 0 not worn, 1 head, 5 chest, 13 one-hand, 17 two-hand, 16 back, 11 finger ...
    #[serde(default)]
    pub inventory_type: i64,
    /// ItemDisplayInfo ID: the icon and the model.
    #[serde(default)]
    pub display: i64,
    #[serde(default)]
    pub item_level: i64,
    #[serde(default)]
    pub required_level: i64,
    #[serde(default)]
    pub stats: Vec<Stat>,
    #[serde(default)]
    pub armor: i64,
    #[serde(default)]
    pub dmg_min: f64,
    #[serde(default)]
    pub dmg_max: f64,
    /// Weapon speed in milliseconds.
    #[serde(default)]
    pub delay: i64,
    #[serde(default)]
    pub buy_price: i64,
    #[serde(default)]
    pub sell_price: i64,
    /// 0 none, 1 when picked up, 2 when equipped, 4 quest item.
    #[serde(default)]
    pub bonding: i64,
    #[serde(default)]
    pub stack: i64,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub durability: i64,
}

pub(crate) fn tagged(p: &Project, kind: &str, table: &str, tag: &str) -> Vec<toml::Table> {
    let d = data::load(p);
    let m = if kind == "world" { &d.world } else { &d.dbc };
    m.get(table).map(|r| r.rows.iter().filter(|x| x.get("comment").and_then(Value::as_str) != Some(tag)).cloned().collect()).unwrap_or_default()
}

pub(crate) fn put(p: &Project, table: &str, tag: &str, rows: Vec<toml::Table>) -> Result<()> {
    let mut all = tagged(p, "world", table, tag);
    all.extend(rows);
    save_rows(p, "world", table, &all)?;
    Ok(())
}

pub(crate) fn row(tag: &str) -> toml::Table {
    let mut t = toml::Table::new();
    t.insert("comment".into(), tag.into());
    t
}

pub(crate) fn take_id(p: &Project, given: Option<i64>, table: &str, what: &str) -> Result<i64> {
    if let Some(id) = given.filter(|i| *i > 0) {
        return Ok(id);
    }
    let mut lock = IdLock::load(&p.root)?;
    let id = lock.allocate(&p.manifest.pack.id, table, what)?;
    lock.save(&p.root)?;
    Ok(id as i64)
}

/// Give one of the pack's own creatures an NPC flag; false when the creature isn't the pack's.
pub(crate) fn add_npc_flag(p: &Project, entry: i64, flag: i64) -> Result<bool> {
    let d = data::load(p);
    let Some(rows) = d.world.get("creature_template") else { return Ok(false) };
    let mut rows = rows.rows.clone();
    let mut found = false;
    for r in rows.iter_mut() {
        let e = r.iter().find(|(k, _)| k.eq_ignore_ascii_case("Entry")).and_then(|(_, v)| v.as_integer());
        if e == Some(entry) && r.get("override").and_then(Value::as_bool) != Some(true) {
            let cur = r.get("NpcFlags").and_then(Value::as_integer).unwrap_or(0);
            r.insert("NpcFlags".into(), (cur | flag).into());
            found = true;
        }
    }
    if found {
        save_rows(p, "world", "creature_template", &rows)?;
    }
    Ok(found)
}

#[derive(Debug, Serialize)]
pub struct Made {
    pub id: i64,
    pub notes: Vec<String>,
}

pub fn quest(p: &Project, q: &QuestSpec) -> Result<Made> {
    if q.title.trim().is_empty() {
        bail!("the quest needs a title");
    }
    if q.giver <= 0 {
        bail!("the quest needs a giver (a creature entry)");
    }
    if q.kill.len() > 4 || q.collect.len() > 4 || q.reward_items.len() > 4 || q.choice_items.len() > 6 {
        bail!("Quests take up to 4 kills, 4 items to bring, 4 reward items and 6 to choose from");
    }
    let id = take_id(p, q.id, "quest_template", &q.title)?;
    let tag = format!("quest:{id}");
    let mut r = row(&tag);
    let level = if q.level > 0 { q.level } else { 1 };
    r.insert("entry".into(), id.into());
    r.insert("Title".into(), q.title.clone().into());
    r.insert("QuestLevel".into(), level.into());
    r.insert("MinLevel".into(), (if q.min_level > 0 { q.min_level } else { (level - 5).max(1) }).into());
    r.insert("ZoneOrSort".into(), q.zone.into());
    r.insert("Details".into(), q.details.clone().into());
    r.insert("Objectives".into(), q.objectives.clone().into());
    r.insert("RequestItemsText".into(), q.request_text.clone().into());
    r.insert("OfferRewardText".into(), q.reward_text.clone().into());
    r.insert("RewOrReqMoney".into(), q.money.into());
    r.insert("PrevQuestId".into(), q.prev_quest.into());
    r.insert("NextQuestInChain".into(), q.next_in_chain.into());
    for (i, k) in q.kill.iter().enumerate() {
        r.insert(format!("ReqCreatureOrGOId{}", i + 1), k.id.into());
        r.insert(format!("ReqCreatureOrGOCount{}", i + 1), k.count.max(1).into());
    }
    for (i, c) in q.collect.iter().enumerate() {
        r.insert(format!("ReqItemId{}", i + 1), c.id.into());
        r.insert(format!("ReqItemCount{}", i + 1), c.count.max(1).into());
    }
    for (i, c) in q.reward_items.iter().enumerate() {
        r.insert(format!("RewItemId{}", i + 1), c.id.into());
        r.insert(format!("RewItemCount{}", i + 1), c.count.max(1).into());
    }
    for (i, c) in q.choice_items.iter().enumerate() {
        r.insert(format!("RewChoiceItemId{}", i + 1), c.id.into());
        r.insert(format!("RewChoiceItemCount{}", i + 1), c.count.max(1).into());
    }
    put(p, "quest_template", &tag, vec![r])?;
    let ender = q.ender.filter(|e| *e > 0).unwrap_or(q.giver);
    let rel = |who: i64| {
        let mut x = row(&tag);
        x.insert("id".into(), who.into());
        x.insert("quest".into(), id.into());
        x
    };
    put(p, "creature_questrelation", &tag, vec![rel(q.giver)])?;
    put(p, "creature_involvedrelation", &tag, vec![rel(ender)])?;
    let mut notes = vec![];
    for who in [q.giver, ender] {
        if !add_npc_flag(p, who, NPC_QUESTGIVER)? {
            notes.push(format!("{who} isn't one of this pack's creatures: make sure it has the quest giver flag (NpcFlags 2), or it won't offer the quest."));
        }
    }
    notes.dedup();
    Ok(Made { id, notes })
}

pub fn item(p: &Project, it: &ItemSpec) -> Result<Made> {
    if it.name.trim().is_empty() {
        bail!("the item needs a name");
    }
    if it.stats.len() > 10 {
        bail!("Items take up to 10 stats");
    }
    let id = take_id(p, it.id, "item_template", &it.name)?;
    let tag = format!("item:{id}");
    let mut r = row(&tag);
    r.insert("entry".into(), id.into());
    r.insert("name".into(), it.name.clone().into());
    r.insert("Quality".into(), it.quality.into());
    r.insert("class".into(), it.class.into());
    r.insert("subclass".into(), it.subclass.into());
    r.insert("InventoryType".into(), it.inventory_type.into());
    r.insert("displayid".into(), it.display.into());
    r.insert("ItemLevel".into(), it.item_level.into());
    r.insert("RequiredLevel".into(), it.required_level.into());
    r.insert("BuyPrice".into(), it.buy_price.into());
    r.insert("SellPrice".into(), (if it.sell_price > 0 { it.sell_price } else { it.buy_price / 4 }).into());
    r.insert("bonding".into(), it.bonding.into());
    r.insert("stackable".into(), it.stack.max(1).into());
    r.insert("description".into(), it.description.clone().into());
    if it.armor > 0 {
        r.insert("armor".into(), it.armor.into());
    }
    if it.dmg_max > 0.0 {
        r.insert("dmg_min1".into(), Value::Float(it.dmg_min));
        r.insert("dmg_max1".into(), Value::Float(it.dmg_max));
        r.insert("delay".into(), (if it.delay > 0 { it.delay } else { 2000 }).into());
    }
    if it.durability > 0 {
        r.insert("MaxDurability".into(), it.durability.into());
    }
    for (i, s) in it.stats.iter().enumerate() {
        r.insert(format!("stat_type{}", i + 1), s.kind.into());
        r.insert(format!("stat_value{}", i + 1), s.value.into());
    }
    put(p, "item_template", &tag, vec![r])?;
    let mut notes = vec![];
    if it.display == 0 {
        notes.push("No display: the item shows a question-mark icon. Pick one from the game's ItemDisplayInfo.".into());
    }
    Ok(Made { id, notes })
}

/// An item icon from the creator's own picture: squared and fitted to the game's 64 × 64 with a
/// soft dark edge like the game's own, saved as `art/Interface/Icons/<name>.png` (built to BLP), and a
/// new ItemDisplayInfo (a copy of `base_display` when given, for its model) that uses it.
/// Returns the new display ID.
pub fn item_icon(p: &Project, base_display: i64, name: &str, picture: &[u8]) -> Result<i64> {
    let img = image::load_from_memory(picture).context("not a picture Forge can read (PNG, JPEG or TGA)")?.to_rgba8();
    let side = img.width().min(img.height());
    if side < 16 {
        bail!("the picture is too small for an icon");
    }
    let sq = image::imageops::crop_imm(&img, (img.width() - side) / 2, (img.height() - side) / 2, side, side).to_image();
    let mut icon = image::imageops::resize(&sq, 64, 64, image::imageops::FilterType::Lanczos3);
    for y in 0..64u32 {
        for x in 0..64u32 {
            let edge = x.min(y).min(63 - x).min(63 - y) as f32;
            let k = if edge < 4.0 { 0.55 + 0.45 * edge / 4.0 } else { 1.0 };
            let px = icon.get_pixel_mut(x, y);
            for c in 0..3 {
                px[c] = (px[c] as f32 * k) as u8;
            }
            px[3] = 255;
        }
    }
    let clean: String = name.chars().filter(|c| c.is_ascii_alphanumeric()).take(28).collect();
    let pack: String = p.manifest.pack.id.chars().filter(|c| c.is_ascii_alphanumeric()).take(12).collect();
    let file = format!("INV_{pack}_{}", if clean.is_empty() { "Icon".to_string() } else { clean });
    let dir = p.root.join("art").join("Interface").join("Icons");
    std::fs::create_dir_all(&dir)?;
    icon.save(dir.join(format!("{file}.png")))?;
    let mut lock = IdLock::load(&p.root)?;
    let id = lock.allocate(&p.manifest.pack.id, "ItemDisplayInfo", &file)? as i64;
    lock.save(&p.root)?;
    let tag = format!("icon:{id}");
    let mut r = row(&tag);
    r.insert("ID".into(), id.into());
    if base_display > 0 {
        r.insert("clone".into(), base_display.into());
    }
    r.insert("InventoryIcon".into(), file.into());
    let d = data::load(p);
    let mut rows: Vec<toml::Table> = d.dbc.get("ItemDisplayInfo").map(|t| t.rows.clone()).unwrap_or_default();
    rows.push(r);
    save_rows(p, "dbc", "ItemDisplayInfo", &rows)?;
    Ok(id)
}

/// A vendor's list: npc_vendor rows for one creature (replacing its earlier list from this wizard).
pub fn vendor(p: &Project, creature: i64, items: &[Pair]) -> Result<Made> {
    if creature <= 0 {
        bail!("pick the vendor (a creature entry)");
    }
    let tag = format!("vendor:{creature}");
    let rows: Vec<toml::Table> = items
        .iter()
        .filter(|i| i.id > 0)
        .map(|i| {
            let mut r = row(&tag);
            r.insert("entry".into(), creature.into());
            r.insert("item".into(), i.id.into());
            r.insert("maxcount".into(), i.count.max(0).into()); // 0: unlimited
            r
        })
        .collect();
    put(p, "npc_vendor", &tag, rows)?;
    let mut notes = vec![];
    if !add_npc_flag(p, creature, NPC_VENDOR | NPC_GOSSIP).context("vendor flag")? {
        notes.push(format!("{creature} isn't one of this pack's creatures: make sure it has the vendor flag (NpcFlags 4)."));
    }
    Ok(Made { id: creature, notes })
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Drop {
    pub item: i64,
    /// Percent; a negative chance means "only while on a quest that needs it".
    pub chance: f64,
    #[serde(default)]
    pub min: i64,
    #[serde(default)]
    pub max: i64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct CreatureSpec {
    pub id: Option<i64>,
    pub name: String,
    #[serde(default)]
    pub subname: String,
    #[serde(default)]
    pub min_level: i64,
    #[serde(default)]
    pub max_level: i64,
    /// hostile | neutral | friendly
    #[serde(default)]
    pub attitude: String,
    /// 0 normal, 1 elite, 2 rare elite, 3 boss, 4 rare
    #[serde(default)]
    pub rank: i64,
    /// CreatureDisplayInfo ID.
    pub display: i64,
    #[serde(default)]
    pub scale: f64,
    #[serde(default)]
    pub health: f64,
    #[serde(default)]
    pub damage: f64,
    #[serde(default)]
    pub quest_giver: bool,
    #[serde(default)]
    pub vendor: bool,
    #[serde(default)]
    pub gold_min: i64,
    #[serde(default)]
    pub gold_max: i64,
    #[serde(default)]
    pub loot: Vec<Drop>,
}

/// The stock creature new ones copy (AI, flags, class stats): Kobold Vermin, a plain level 1
/// humanoid with no script.
pub const CREATURE_BASE: i64 = 6;

pub fn creature(p: &Project, c: &CreatureSpec) -> Result<Made> {
    if c.name.trim().is_empty() {
        bail!("the creature needs a name");
    }
    if c.display <= 0 {
        bail!("pick how it looks (a CreatureDisplayInfo ID: search the game, or import a model)");
    }
    let id = take_id(p, c.id, "creature_template", &c.name)?;
    let tag = format!("creature:{id}");
    let (lo, hi) = (c.min_level.max(1), c.max_level.max(c.min_level).max(1));
    let faction = match c.attitude.as_str() {
        "friendly" => 35,
        "neutral" => 7,
        _ => 14,
    };
    let mut npc = 0;
    if c.quest_giver {
        npc |= NPC_QUESTGIVER;
    }
    if c.vendor {
        npc |= NPC_VENDOR | NPC_GOSSIP;
    }
    // keep flags other wizards set (a quest given later, a vendor list)
    let prev_row = data::load(p).world.get("creature_template").and_then(|r| r.rows.iter().find(|x| text(x, "comment") == tag).cloned());
    let prev = prev_row.as_ref().map(|x| int(x, "NpcFlags")).unwrap_or(0);
    let mut r = row(&tag);
    // what Behaviour Studio set (its AI, its dialogue) stays
    for k in ["AIName", "GossipMenuId"] {
        if let Some(v) = prev_row.as_ref().and_then(|x| x.get(k)) {
            r.insert(k.into(), v.clone());
        }
    }
    r.insert("Entry".into(), id.into());
    r.insert("clone".into(), CREATURE_BASE.into());
    r.insert("Name".into(), c.name.clone().into());
    r.insert("SubName".into(), c.subname.clone().into());
    r.insert("MinLevel".into(), lo.into());
    r.insert("MaxLevel".into(), hi.into());
    r.insert("DisplayId1".into(), c.display.into());
    for k in ["DisplayId2", "DisplayId3", "DisplayId4", "DisplayIdProbability2", "DisplayIdProbability3", "DisplayIdProbability4"] {
        r.insert(k.into(), 0i64.into());
    }
    r.insert("DisplayIdProbability1".into(), 100i64.into());
    r.insert("Faction".into(), (faction as i64).into());
    r.insert("Rank".into(), c.rank.into());
    r.insert("Scale".into(), Value::Float(if c.scale > 0.0 { c.scale } else { 1.0 }));
    r.insert("HealthMultiplier".into(), Value::Float(if c.health > 0.0 { c.health } else { 1.0 }));
    r.insert("DamageMultiplier".into(), Value::Float(if c.damage > 0.0 { c.damage } else { 1.0 }));
    r.insert("NpcFlags".into(), (npc | (prev & !(NPC_QUESTGIVER | NPC_VENDOR | NPC_GOSSIP))).into());
    r.insert("MinLootGold".into(), c.gold_min.into());
    r.insert("MaxLootGold".into(), c.gold_max.max(c.gold_min).into());
    r.insert("LootId".into(), (if c.loot.is_empty() { 0 } else { id }).into());
    put(p, "creature_template", &tag, vec![r])?;
    let drops: Vec<toml::Table> = c
        .loot
        .iter()
        .filter(|d| d.item > 0)
        .map(|d| {
            let mut x = row(&tag);
            x.insert("entry".into(), id.into());
            x.insert("item".into(), d.item.into());
            x.insert("ChanceOrQuestChance".into(), Value::Float(d.chance));
            x.insert("mincountOrRef".into(), d.min.max(1).into());
            x.insert("maxcount".into(), d.max.max(d.min).max(1).into());
            x
        })
        .collect();
    if drops.iter().map(|d| int(d, "item")).collect::<std::collections::HashSet<_>>().len() != drops.len() {
        bail!("an item is in the loot twice");
    }
    put(p, "creature_loot_template", &tag, drops)?;
    Ok(Made { id, notes: vec![] })
}

pub fn get_creature(p: &Project, id: i64) -> Result<CreatureSpec> {
    let d = data::load(p);
    let tag = format!("creature:{id}");
    let r = d.world.get("creature_template").and_then(|r| r.rows.iter().find(|x| text(x, "comment") == tag).cloned()).context("no such creature from the wizard")?;
    let f = |k: &str| r.get(k).and_then(|v| v.as_float().or(v.as_integer().map(|i| i as f64))).unwrap_or(0.0);
    let npc = int(&r, "NpcFlags");
    let loot = d
        .world
        .get("creature_loot_template")
        .map(|t| t.rows.iter().filter(|x| text(x, "comment") == tag).map(|x| Drop { item: int(x, "item"), chance: x.get("ChanceOrQuestChance").and_then(Value::as_float).unwrap_or(0.0), min: int(x, "mincountOrRef"), max: int(x, "maxcount") }).collect())
        .unwrap_or_default();
    Ok(CreatureSpec {
        id: Some(id),
        name: text(&r, "Name"),
        subname: text(&r, "SubName"),
        min_level: int(&r, "MinLevel"),
        max_level: int(&r, "MaxLevel"),
        attitude: match int(&r, "Faction") { 35 => "friendly", 7 => "neutral", _ => "hostile" }.into(),
        rank: int(&r, "Rank"),
        display: int(&r, "DisplayId1"),
        scale: f("Scale"),
        health: f("HealthMultiplier"),
        damage: f("DamageMultiplier"),
        quest_giver: npc & NPC_QUESTGIVER != 0,
        vendor: npc & NPC_VENDOR != 0,
        gold_min: int(&r, "MinLootGold"),
        gold_max: int(&r, "MaxLootGold"),
        loot,
    })
}

pub(crate) fn int(r: &toml::Table, k: &str) -> i64 {
    r.get(k).and_then(|v| v.as_integer().or(v.as_float().map(|f| f as i64))).unwrap_or(0)
}
pub(crate) fn text(r: &toml::Table, k: &str) -> String {
    r.get(k).and_then(Value::as_str).unwrap_or("").to_string()
}
fn pairs(r: &toml::Table, id: &str, count: &str, n: usize) -> Vec<Pair> {
    (1..=n).map(|i| Pair { id: int(r, &format!("{id}{i}")), count: int(r, &format!("{count}{i}")) }).filter(|p| p.id > 0).collect()
}

/// What the wizards made, to list and reopen: quests, items, vendors.
pub fn list(p: &Project) -> serde_json::Value {
    let d = data::load(p);
    let rows = |t: &str| d.world.get(t).map(|r| r.rows.clone()).unwrap_or_default();
    let givers = rows("creature_questrelation");
    let enders = rows("creature_involvedrelation");
    let names: std::collections::HashMap<i64, String> = rows("creature_template").iter().map(|r| (int(r, "Entry"), text(r, "Name"))).collect();
    let who = |list: &Vec<toml::Table>, q: i64| -> Option<serde_json::Value> {
        list.iter().find(|x| int(x, "quest") == q).map(|x| { let e = int(x, "id"); serde_json::json!({"entry": e, "name": names.get(&e).cloned().unwrap_or_default()}) })
    };
    let quests: Vec<_> = rows("quest_template")
        .iter()
        .filter(|r| text(r, "comment").starts_with("quest:"))
        .map(|r| {
            let id = int(r, "entry");
            let kills: Vec<i64> = (1..=4).map(|i| int(r, &format!("ReqCreatureOrGOId{i}"))).filter(|x| *x != 0).collect();
            serde_json::json!({"id": id, "title": text(r, "Title"), "level": int(r, "QuestLevel"), "prev": int(r, "PrevQuestId"), "next": int(r, "NextQuestInChain"),
                               "money": int(r, "RewOrReqMoney"), "giver": who(&givers, id), "ender": who(&enders, id), "kills": kills})
        })
        .collect();
    let items: Vec<_> = rows("item_template").iter().filter(|r| text(r, "comment").starts_with("item:")).map(|r| serde_json::json!({"id": int(r, "entry"), "name": text(r, "name"), "quality": int(r, "Quality"), "display": int(r, "displayid")})).collect();
    let made_creatures: Vec<_> = rows("creature_template").iter().filter(|r| text(r, "comment").starts_with("creature:")).map(|r| serde_json::json!({"id": int(r, "Entry"), "name": text(r, "Name"), "display": int(r, "DisplayId1")})).collect();
    let mut vendors: Vec<i64> = rows("npc_vendor").iter().filter(|r| text(r, "comment").starts_with("vendor:")).map(|r| int(r, "entry")).collect();
    vendors.dedup();
    let creatures: Vec<_> = rows("creature_template").iter().filter(|r| r.get("override").is_none()).map(|r| serde_json::json!({"id": int(r, "Entry"), "name": text(r, "Name"), "display": int(r, "DisplayId1")})).collect();
    serde_json::json!({"made_creatures": made_creatures, "quests": quests, "items": items, "vendors": vendors, "creatures": creatures})
}

/// A quest the wizard made, back as its form.
pub fn get_quest(p: &Project, id: i64) -> Result<QuestSpec> {
    let d = data::load(p);
    let tag = format!("quest:{id}");
    let find = |t: &str| d.world.get(t).and_then(|r| r.rows.iter().find(|x| text(x, "comment") == tag).cloned());
    let r = find("quest_template").context("no such quest from the wizard")?;
    Ok(QuestSpec {
        id: Some(id),
        title: text(&r, "Title"),
        level: int(&r, "QuestLevel"),
        min_level: int(&r, "MinLevel"),
        zone: int(&r, "ZoneOrSort"),
        giver: find("creature_questrelation").map(|x| int(&x, "id")).unwrap_or(0),
        ender: find("creature_involvedrelation").map(|x| int(&x, "id")),
        details: text(&r, "Details"),
        objectives: text(&r, "Objectives"),
        request_text: text(&r, "RequestItemsText"),
        reward_text: text(&r, "OfferRewardText"),
        kill: pairs(&r, "ReqCreatureOrGOId", "ReqCreatureOrGOCount", 4),
        collect: pairs(&r, "ReqItemId", "ReqItemCount", 4),
        money: int(&r, "RewOrReqMoney"),
        reward_items: pairs(&r, "RewItemId", "RewItemCount", 4),
        choice_items: pairs(&r, "RewChoiceItemId", "RewChoiceItemCount", 6),
        prev_quest: int(&r, "PrevQuestId"),
        next_in_chain: int(&r, "NextQuestInChain"),
    })
}

/// An item the wizard made, back as its form.
pub fn get_item(p: &Project, id: i64) -> Result<ItemSpec> {
    let d = data::load(p);
    let tag = format!("item:{id}");
    let r = d.world.get("item_template").and_then(|r| r.rows.iter().find(|x| text(x, "comment") == tag).cloned()).context("no such item from the wizard")?;
    let f = |k: &str| r.get(k).and_then(|v| v.as_float().or(v.as_integer().map(|i| i as f64))).unwrap_or(0.0);
    Ok(ItemSpec {
        id: Some(id),
        name: text(&r, "name"),
        quality: int(&r, "Quality"),
        class: int(&r, "class"),
        subclass: int(&r, "subclass"),
        inventory_type: int(&r, "InventoryType"),
        display: int(&r, "displayid"),
        item_level: int(&r, "ItemLevel"),
        required_level: int(&r, "RequiredLevel"),
        stats: (1..=10).map(|i| Stat { kind: int(&r, &format!("stat_type{i}")), value: int(&r, &format!("stat_value{i}")) }).filter(|s| s.value != 0).collect(),
        armor: int(&r, "armor"),
        dmg_min: f("dmg_min1"),
        dmg_max: f("dmg_max1"),
        delay: int(&r, "delay"),
        buy_price: int(&r, "BuyPrice"),
        sell_price: int(&r, "SellPrice"),
        bonding: int(&r, "bonding"),
        stack: int(&r, "stackable"),
        description: text(&r, "description"),
        durability: int(&r, "MaxDurability"),
    })
}

/// A vendor's list from the wizard.
pub fn get_vendor(p: &Project, creature: i64) -> Vec<Pair> {
    let d = data::load(p);
    let tag = format!("vendor:{creature}");
    d.world.get("npc_vendor").map(|r| r.rows.iter().filter(|x| text(x, "comment") == tag).map(|x| Pair { id: int(x, "item"), count: int(x, "maxcount") }).collect()).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::{create, Template};

    #[test]
    fn an_icon_from_a_picture() {
        let dir = tempfile::tempdir().unwrap();
        let p = crate::project::create(dir.path().join("p"), "Icon Pack", "Me", crate::project::Template::Pack).unwrap();
        let mut png = std::io::Cursor::new(Vec::new());
        image::RgbaImage::from_pixel(120, 90, image::Rgba([200, 60, 20, 255])).write_to(&mut png, image::ImageFormat::Png).unwrap();
        let id = item_icon(&p, 5161, "Ember Blade!", &png.into_inner()).unwrap();
        let f = p.root.join("art/Interface/Icons/INV_iconpack_EmberBlade.png");
        let img = image::open(&f).unwrap().to_rgba8();
        assert_eq!((img.width(), img.height()), (64, 64));
        assert!(img.get_pixel(0, 0)[0] < img.get_pixel(32, 32)[0], "darker at the edge");
        let d = data::load(&p);
        let r = d.dbc["ItemDisplayInfo"].rows.iter().find(|r| int(r, "ID") == id).unwrap().clone();
        assert_eq!(text(&r, "InventoryIcon"), "INV_iconpack_EmberBlade");
        assert_eq!(int(&r, "clone"), 5161);
        assert!(crate::check::run(&p, None).iter().all(|f| f.level != crate::check::Level::Error), "{:?}", crate::check::run(&p, None));
    }

    #[test]
    fn a_quest_line_with_its_items_and_vendor() {
        let dir = tempfile::tempdir().unwrap();
        let p = create(dir.path().join("p"), "Quest Pack", "Orion", Template::Empty).unwrap();
        // a giver of our own
        let mut lock = IdLock::load(&p.root).unwrap();
        let npc = lock.allocate(&p.manifest.pack.id, "creature_template", "Keeper").unwrap() as i64;
        lock.save(&p.root).unwrap();
        std::fs::create_dir_all(p.root.join("data/world")).unwrap();
        std::fs::write(p.root.join("data/world/creature_template.toml"), format!("[[row]]\nEntry = {npc}\nclone = 308\nName = \"Keeper Lunara\"\n")).unwrap();

        let sword = item(&p, &ItemSpec { name: "Emberforged Blade".into(), quality: 3, class: 2, subclass: 7, inventory_type: 13, display: 5161,
            item_level: 30, required_level: 25, stats: vec![Stat { kind: 4, value: 8 }, Stat { kind: 7, value: 5 }], dmg_min: 40.0, dmg_max: 75.0,
            delay: 2600, buy_price: 40000, bonding: 1, durability: 75, ..Default::default() }).unwrap();
        let q = QuestSpec { title: "Embers in the Dark".into(), level: 28, giver: npc, details: "Bring me ten embers, $N.".into(),
            kill: vec![Pair { id: 448, count: 1 }], collect: vec![], money: 2500, choice_items: vec![Pair { id: sword.id, count: 1 }], ..Default::default() };
        let made = quest(&p, &q).unwrap();
        assert!(made.notes.is_empty(), "{:?}", made.notes);
        // saving again replaces, doesn't duplicate
        let again = quest(&p, &QuestSpec { id: Some(made.id), ..q.clone() }).unwrap();
        assert_eq!(again.id, made.id);
        let d = data::load(&p);
        assert_eq!(d.world["quest_template"].rows.len(), 1);
        assert_eq!(d.world["creature_questrelation"].rows.len(), 1);
        assert_eq!(d.world["creature_template"].rows[0]["NpcFlags"].as_integer(), Some(2));
        vendor(&p, npc, &[Pair { id: sword.id, count: 0 }]).unwrap();
        assert_eq!(data::load(&p).world["creature_template"].rows[0]["NpcFlags"].as_integer(), Some(7));
        let back = get_quest(&p, made.id).unwrap();
        assert_eq!((back.title.as_str(), back.giver, back.choice_items[0].id), ("Embers in the Dark", npc, sword.id));
        let bi = get_item(&p, sword.id).unwrap();
        assert_eq!((bi.dmg_max, bi.stats.len()), (75.0, 2));
        assert_eq!(get_vendor(&p, npc)[0].id, sword.id);
        assert_eq!(list(&p)["quests"][0]["title"], "Embers in the Dark");
        let mob = creature(&p, &CreatureSpec { name: "Ember Whelp".into(), min_level: 26, max_level: 28, attitude: "hostile".into(), display: 397,
            gold_min: 120, gold_max: 300, loot: vec![Drop { item: sword.id, chance: 2.5, min: 1, max: 1 }, Drop { item: 2589, chance: 40.0, min: 1, max: 3 }], ..Default::default() }).unwrap();
        let back = get_creature(&p, mob.id).unwrap();
        assert_eq!((back.loot.len(), back.max_level, back.attitude.as_str()), (2, 28, "hostile"));
        let d = data::load(&p);
        let ct = d.world["creature_template"].rows.iter().find(|r| int(r, "Entry") == mob.id).unwrap().clone();
        assert_eq!((int(&ct, "LootId"), int(&ct, "Faction"), int(&ct, "clone")), (mob.id, 14, CREATURE_BASE));
        // a stock giver gets a note
        assert_eq!(quest(&p, &QuestSpec { title: "X".into(), giver: 197, ..Default::default() }).unwrap().notes.len(), 1);
        let f = crate::check::run(&p, None);
        assert!(!f.iter().any(|x| x.level == crate::check::Level::Error), "{f:?}");
    }
}
