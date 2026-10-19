"""A small realm for the armory exporter's tests: the CMaNGOS classic tables it reads (column names
as in mangos-classic sql/base, types kept portable so the same DDL runs in SQLite and MariaDB), a
handful of characters covering every privacy mode, two guilds whose names collide on one slug, and
tiny DBC files (WDBC) for icons, talents, reputations, enchantments and item sets.
"""
import os
import struct

CHARS, WORLD, REALMD = "classiccharacters", "classicmangos", "classicrealmd"
NOW = 1792000000            # 2026-10-15T...Z
DAY = 86400

TABLES = {
    (REALMD, "realmlist"): "id INT NOT NULL, name VARCHAR(32) NOT NULL DEFAULT '', PRIMARY KEY (id)",
    (REALMD, "account"): "id INT NOT NULL, username VARCHAR(32) NOT NULL DEFAULT '', PRIMARY KEY (id)",
    (CHARS, "characters"): (
        "guid INT NOT NULL, account INT NOT NULL DEFAULT 0, name VARCHAR(12) NOT NULL DEFAULT '', race INT NOT NULL DEFAULT 0, "
        "class INT NOT NULL DEFAULT 0, gender INT NOT NULL DEFAULT 0, level INT NOT NULL DEFAULT 0, "
        "logout_time BIGINT NOT NULL DEFAULT 0, online INT NOT NULL DEFAULT 0, honor_highest_rank INT NOT NULL DEFAULT 0, "
        "honor_standing INT NOT NULL DEFAULT 0, stored_dishonorable_kills INT NOT NULL DEFAULT 0, "
        "stored_honorable_kills INT NOT NULL DEFAULT 0, deleteInfos_Account INT DEFAULT NULL, "
        "deleteInfos_Name VARCHAR(12) DEFAULT NULL, deleteDate BIGINT DEFAULT NULL, PRIMARY KEY (guid)"),
    (CHARS, "character_inventory"): ("guid INT NOT NULL DEFAULT 0, bag INT NOT NULL DEFAULT 0, slot INT NOT NULL DEFAULT 0, "
                                     "item INT NOT NULL DEFAULT 0, item_template INT NOT NULL DEFAULT 0, PRIMARY KEY (item)"),
    (CHARS, "item_instance"): ("guid INT NOT NULL DEFAULT 0, owner_guid INT NOT NULL DEFAULT 0, itemEntry INT NOT NULL DEFAULT 0, "
                               "enchantments TEXT NOT NULL, randomPropertyId INT NOT NULL DEFAULT 0, "
                               "durability INT NOT NULL DEFAULT 0, PRIMARY KEY (guid)"),
    (CHARS, "character_skills"): ("guid INT NOT NULL, skill INT NOT NULL, value INT NOT NULL, max INT NOT NULL, "
                                  "PRIMARY KEY (guid, skill)"),
    (CHARS, "character_reputation"): ("guid INT NOT NULL DEFAULT 0, faction INT NOT NULL DEFAULT 0, standing INT NOT NULL DEFAULT 0, "
                                      "flags INT NOT NULL DEFAULT 0, PRIMARY KEY (guid, faction)"),
    (CHARS, "character_spell"): ("guid INT NOT NULL DEFAULT 0, spell INT NOT NULL DEFAULT 0, active INT NOT NULL DEFAULT 1, "
                                 "disabled INT NOT NULL DEFAULT 0, PRIMARY KEY (guid, spell)"),
    (CHARS, "character_honor_cp"): ("guid INT NOT NULL DEFAULT 0, victim_type INT NOT NULL DEFAULT 4, victim INT NOT NULL DEFAULT 0, "
                                    "honor FLOAT NOT NULL DEFAULT 0, date INT NOT NULL DEFAULT 0, type INT NOT NULL DEFAULT 0"),
    (CHARS, "character_stats"): ("guid INT NOT NULL DEFAULT 0, maxhealth INT NOT NULL DEFAULT 0, maxpower1 INT NOT NULL DEFAULT 0, "
                                 "strength INT NOT NULL DEFAULT 0, agility INT NOT NULL DEFAULT 0, stamina INT NOT NULL DEFAULT 0, "
                                 "intellect INT NOT NULL DEFAULT 0, spirit INT NOT NULL DEFAULT 0, armor INT NOT NULL DEFAULT 0, "
                                 "resHoly INT NOT NULL DEFAULT 0, resFire INT NOT NULL DEFAULT 0, resNature INT NOT NULL DEFAULT 0, "
                                 "resFrost INT NOT NULL DEFAULT 0, resShadow INT NOT NULL DEFAULT 0, resArcane INT NOT NULL DEFAULT 0, "
                                 "blockPct FLOAT NOT NULL DEFAULT 0, dodgePct FLOAT NOT NULL DEFAULT 0, parryPct FLOAT NOT NULL DEFAULT 0, "
                                 "critPct FLOAT NOT NULL DEFAULT 0, rangedCritPct FLOAT NOT NULL DEFAULT 0, "
                                 "attackPower INT NOT NULL DEFAULT 0, rangedAttackPower INT NOT NULL DEFAULT 0, PRIMARY KEY (guid)"),
    (CHARS, "guild"): ("guildid INT NOT NULL DEFAULT 0, name VARCHAR(255) NOT NULL DEFAULT '', leaderguid INT NOT NULL DEFAULT 0, "
                       "info VARCHAR(500) NOT NULL DEFAULT '', motd VARCHAR(128) NOT NULL DEFAULT '', "
                       "createdate BIGINT NOT NULL DEFAULT 0, PRIMARY KEY (guildid)"),
    (CHARS, "guild_member"): ("guildid INT NOT NULL DEFAULT 0, guid INT NOT NULL DEFAULT 0, rank INT NOT NULL DEFAULT 0, "
                              "pnote VARCHAR(31) NOT NULL DEFAULT '', offnote VARCHAR(31) NOT NULL DEFAULT '', PRIMARY KEY (guid)"),
    (CHARS, "guild_rank"): ("guildid INT NOT NULL DEFAULT 0, rid INT NOT NULL, rname VARCHAR(255) NOT NULL DEFAULT '', "
                            "rights INT NOT NULL DEFAULT 0, PRIMARY KEY (guildid, rid)"),
    (CHARS, "openvanilla_character"): ("guid INT NOT NULL, active_spec INT NOT NULL DEFAULT 1, starter_pet INT NOT NULL DEFAULT 0, "
                                   "armory VARCHAR(8) NOT NULL DEFAULT 'public', armory_key VARCHAR(40) NOT NULL DEFAULT '', "
                                   "PRIMARY KEY (guid)"),
    (CHARS, "openvanilla_spec"): ("guid INT NOT NULL, spec INT NOT NULL, name VARCHAR(32) NOT NULL DEFAULT '', talents TEXT NOT NULL, "
                              "PRIMARY KEY (guid, spec)"),
    (CHARS, "character_achievement"): "guid INT NOT NULL, achievement INT NOT NULL, date INT NOT NULL, PRIMARY KEY (guid, achievement)",
    (CHARS, "openvanilla_realm_first"): ("achievement INT NOT NULL, guid INT NOT NULL, name VARCHAR(12) NOT NULL, date INT NOT NULL, "
                                     "PRIMARY KEY (achievement)"),
    (WORLD, "openvanilla_achievement"): ("id INT NOT NULL, name VARCHAR(80) NOT NULL, description VARCHAR(255) NOT NULL, "
                                     "points INT NOT NULL, category VARCHAR(16) NOT NULL, icon VARCHAR(80) NOT NULL, "
                                     "faction INT NOT NULL DEFAULT 0, class_mask INT NOT NULL DEFAULT 0, need INT NOT NULL DEFAULT 0, "
                                     "flags INT NOT NULL DEFAULT 0, PRIMARY KEY (id)"),
    (WORLD, "spell_template"): "Id INT NOT NULL DEFAULT 0, SpellIconID INT NOT NULL DEFAULT 0, SpellName TEXT NOT NULL, PRIMARY KEY (Id)",
    (WORLD, "item_template"): (
        "entry INT NOT NULL DEFAULT 0, class INT NOT NULL DEFAULT 0, subclass INT NOT NULL DEFAULT 0, "
        "name VARCHAR(255) NOT NULL DEFAULT '', displayid INT NOT NULL DEFAULT 0, Quality INT NOT NULL DEFAULT 0, "
        "InventoryType INT NOT NULL DEFAULT 0, ItemLevel INT NOT NULL DEFAULT 0, RequiredLevel INT NOT NULL DEFAULT 0, "
        + "".join(f"stat_type{n} INT NOT NULL DEFAULT 0, stat_value{n} INT NOT NULL DEFAULT 0, " for n in range(1, 11))
        + "dmg_min1 FLOAT NOT NULL DEFAULT 0, dmg_max1 FLOAT NOT NULL DEFAULT 0, dmg_type1 INT NOT NULL DEFAULT 0, "
        "armor INT NOT NULL DEFAULT 0, holy_res INT NOT NULL DEFAULT 0, fire_res INT NOT NULL DEFAULT 0, "
        "nature_res INT NOT NULL DEFAULT 0, frost_res INT NOT NULL DEFAULT 0, shadow_res INT NOT NULL DEFAULT 0, "
        "arcane_res INT NOT NULL DEFAULT 0, delay INT NOT NULL DEFAULT 1000, "
        + "".join(f"spellid_{n} INT NOT NULL DEFAULT 0, spelltrigger_{n} INT NOT NULL DEFAULT 0, " for n in range(1, 6))
        + "bonding INT NOT NULL DEFAULT 0, description VARCHAR(255) NOT NULL DEFAULT '', block INT NOT NULL DEFAULT 0, "
        "itemset INT NOT NULL DEFAULT 0, MaxDurability INT NOT NULL DEFAULT 0, PRIMARY KEY (entry)"),
}

# guid, account, name, race, class, gender, level, logout, online, hk, dk, hrank
CHARACTERS = [
    (1, 1, "Aldric", 1, 1, 0, 60, NOW - 2 * DAY, 0, 1200, 3, 12),
    (2, 2, "Berra", 4, 3, 1, 41, NOW - 3 * DAY, 0, 0, 0, 0),
    (3, 3, "Corvin", 1, 8, 0, 60, NOW - DAY, 0, 50, 0, 0),
    (4, 4, "Dara", 3, 5, 1, 30, NOW - 5 * DAY, 1, 10, 0, 0),
    (5, 9, "Botter", 2, 1, 0, 60, NOW - DAY, 1, 999, 0, 0),           # RNDBOT account: never exported
    (6, 5, "Grom", 2, 1, 0, 52, NOW - 4 * DAY, 0, 400, 0, 0),         # Horde guild master
    (7, 5, "Eira", 5, 9, 1, 60, NOW - 6 * DAY, 0, 20, 0, 0),
]
DELETED = (8, 6, "Gone", 1, 1, 0, 20, NOW - 9 * DAY, 0, 0, 0, 0)
BERRA_KEY = "k3y4berra0000000000a"

ITEMS = [
    # entry, class, subclass, name, display, quality, inv, ilvl, req, stats, dmg (min,max,type,delay), armor, res(fire), spells, bond, itemset, maxdur, block
    (990901, 4, 4, "Helm of Valor", 7001, 3, 1, 58, 53, [(7, 15), (4, 12)], None, 528, 0, [(990950, 1)], 1, 990, 80, 0),
    (990902, 2, 8, "Ashkandi, Greatsword of the Brotherhood", 7002, 4, 17, 83, 60, [(7, 33)],
     (229, 344, 0, 3500), 0, 10, [(990951, 1)], 1, 0, 120, 0),
    (990903, 4, 4, "Breastplate of Valor", 7003, 3, 5, 58, 53, [(7, 18)], None, 710, 0, [], 1, 990, 135, 0),
    (990904, 4, 1, "Robe of the Archmage", 7004, 4, 20, 60, 56, [(5, 30)], None, 90, 0, [], 1, 0, 100, 0),
    (990905, 4, 0, "Band of <script>alert(1)</script>", 7005, 2, 11, 40, 35, [(3, 7)], None, 0, 0, [], 2, 0, 0, 0),
]
INVENTORY = [  # guid, slot, item guid, entry, enchantments, randomprop
    (1, 0, 5001, 990901, "1886 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 ", 0),
    (1, 4, 5002, 990903, "", 0),
    (1, 15, 5003, 990902, "1900 0 0 ", 0),
    (1, 10, 5004, 990905, "", 777),
    (3, 4, 5005, 990904, "", 0),
    (2, 4, 5006, 990903, "", 0),
]
SKILLS = [(1, 164, 300, 300), (1, 186, 285, 300), (1, 185, 120, 150), (1, 43, 300, 300),
          (2, 165, 210, 225), (3, 197, 300, 300), (4, 129, 150, 150), (6, 182, 150, 150)]
REPS = [(1, 72, 9500, 1), (1, 47, 100, 17), (1, 76, 0, 4), (1, 530, 0, 9)]
GUILDS = [(10, "Ashen Vanguard", 1, "Raids MC/BWL Tue and Thu 20:00 server time.", "secret motd", NOW - 200 * DAY),
          (11, "<Knights of Ni!>", 6, "", "", NOW - 100 * DAY),
          (12, "Knights of Ni", 7, "We say Ni.", "", NOW - 50 * DAY)]
RANKS = [(10, 0, "Guild Master"), (10, 1, "Officer"), (10, 2, "Veteran"), (10, 3, "Member"), (10, 4, "Initiate"),
         (11, 0, "Warchief"), (11, 1, "Grunt"), (12, 0, "Head Knight"), (12, 1, "Knight")]
MEMBERS = [(10, 1, 0, "public note", "officer note"), (10, 2, 4, "", ""), (10, 3, 1, "", ""), (11, 6, 0, "", ""),
           (12, 7, 0, "", ""), (10, 5, 3, "", "")]
ACHIEVEMENTS = [(6, "Level 60", "Reach level 60.", 25, "general", "Interface\\Icons\\INV_Sword_39", 1),
                (412, "Molten Core", "Defeat Ragnaros.", 25, "dungeons", "Interface\\Icons\\INV_Misc_Head_Dragon_01", 0),
                (500, "Grand Explorer", "Explore everything.", 50, "exploration", "INV_Misc_Map_01", 4)]
EARNED = [(1, 6, NOW - 30 * DAY), (1, 412, NOW - 3 * DAY), (3, 6, NOW - 10 * DAY), (2, 6, NOW - 20 * DAY),
          (7, 6, NOW - 40 * DAY), (7, 500, NOW - 8 * DAY)]
FIRSTS = [(6, 7, "Eira", NOW - 40 * DAY), (412, 1, "Aldric", NOW - 3 * DAY), (500, 3, "Corvin", NOW - 2 * DAY)]
SPELLS = [(990950, 0, "Increased Defense"), (990951, 0, "Fiery Blaze"), (12282, 132, "Improved Heroic Strike"),
          (12285, 133, "Improved Charge"), (12300, 134, "Tactical Mastery")]
# warrior talents (fake dbc): 1001 Improved Heroic Strike (3 ranks: 12282, 12663, 12664) in Arms;
# 1002 Improved Charge (2 ranks: 12285, 12697) in Arms; 1003 Tactical Mastery (5 ranks) in Arms row 1;
# 1101 Cruelty in Fury (5 ranks: 12320..12324)
CHAR_SPELLS = [(1, 12282), (1, 12663), (1, 12664), (1, 12285), (1, 12320), (1, 12321), (1, 133)]
SPEC2 = "1001:0,1101:4,9999:2"


def ddl():
    out = []
    for (db, table), cols in TABLES.items():
        out.append(f"CREATE TABLE {db}.{table} ({cols})")
    return out


def rows():
    """[(sql with %s, args), ...] inserting the fixture."""
    ins = []

    def add(db, table, cols, values):
        ins.append((f"INSERT INTO {db}.{table} ({cols}) VALUES ({','.join(['%s'] * len(values))})", tuple(values)))

    add(REALMD, "realmlist", "id, name", (1, "Vanilla Reloaded"))
    for aid, user in ((1, "ALDRIC"), (2, "BERRA"), (3, "CORVIN"), (4, "DARA"), (5, "GROM"), (6, "GONE"), (9, "RNDBOT0001")):
        add(REALMD, "account", "id, username", (aid, user))
    cols = ("guid, account, name, race, class, gender, level, logout_time, online, stored_honorable_kills, "
            "stored_dishonorable_kills, honor_highest_rank")
    for c in CHARACTERS:
        add(CHARS, "characters", cols, c)
    add(CHARS, "characters", cols + ", deleteInfos_Account, deleteInfos_Name, deleteDate",
        DELETED + (6, "Gone", NOW - DAY))
    for e, cls, sub, name, disp, q, inv, ilvl, req, stats, dmg, armor, fire, spells, bond, iset, maxdur, block in ITEMS:
        c = ["entry", "class", "subclass", "name", "displayid", "Quality", "InventoryType", "ItemLevel", "RequiredLevel",
             "armor", "fire_res", "bonding", "itemset", "MaxDurability", "block"]
        v = [e, cls, sub, name, disp, q, inv, ilvl, req, armor, fire, bond, iset, maxdur, block]
        for n, (st, val) in enumerate(stats, 1):
            c += [f"stat_type{n}", f"stat_value{n}"]
            v += [st, val]
        if dmg:
            c += ["dmg_min1", "dmg_max1", "dmg_type1", "delay"]
            v += list(dmg)
        for n, (sp, tr) in enumerate(spells, 1):
            c += [f"spellid_{n}", f"spelltrigger_{n}"]
            v += [sp, tr]
        add(WORLD, "item_template", ", ".join(c), v)
    for guid, slot, item, entry, ench, rp in INVENTORY:
        add(CHARS, "character_inventory", "guid, bag, slot, item, item_template", (guid, 0, slot, item, entry))
        add(CHARS, "item_instance", "guid, owner_guid, itemEntry, enchantments, randomPropertyId, durability",
            (item, guid, entry, ench, rp, 50))
    add(CHARS, "character_inventory", "guid, bag, slot, item, item_template", (1, 0, 23, 5099, 990904))   # a backpack slot
    for s in SKILLS:
        add(CHARS, "character_skills", "guid, skill, value, max", s)
    for r in REPS:
        add(CHARS, "character_reputation", "guid, faction, standing, flags", r)
    for g in GUILDS:
        add(CHARS, "guild", "guildid, name, leaderguid, info, motd, createdate", g)
    for r in RANKS:
        add(CHARS, "guild_rank", "guildid, rid, rname", r)
    for m in MEMBERS:
        add(CHARS, "guild_member", "guildid, guid, rank, pnote, offnote", m)
    add(CHARS, "openvanilla_character", "guid, active_spec, armory, armory_key", (2, 1, "friends", BERRA_KEY))
    add(CHARS, "openvanilla_character", "guid, active_spec, armory, armory_key", (3, 1, "hidden", ""))
    add(CHARS, "openvanilla_character", "guid, active_spec, armory, armory_key", (1, 1, "public", ""))
    add(CHARS, "openvanilla_spec", "guid, spec, name, talents", (1, 1, "Arms", ""))
    add(CHARS, "openvanilla_spec", "guid, spec, name, talents", (1, 2, "Fury", SPEC2))
    for a in ACHIEVEMENTS:
        add(WORLD, "openvanilla_achievement", "id, name, description, points, category, icon, flags", a)
    for e in EARNED:
        add(CHARS, "character_achievement", "guid, achievement, date", e)
    for f in FIRSTS:
        add(CHARS, "openvanilla_realm_first", "achievement, guid, name, date", f)
    for s in SPELLS:
        add(WORLD, "spell_template", "Id, SpellIconID, SpellName", s)
    for g, sp in CHAR_SPELLS:
        add(CHARS, "character_spell", "guid, spell", (g, sp))
    for n in range(5):
        add(CHARS, "character_honor_cp", "guid, victim_type, victim, honor, date, type", (1, 4, 100 + n, 10.0, NOW, 1))
    add(CHARS, "character_honor_cp", "guid, victim_type, victim, honor, date, type", (1, 4, 200, 0.0, NOW, 2))
    add(CHARS, "character_stats", "guid, maxhealth, strength, stamina, armor, dodgePct, attackPower",
        (1, 5400, 210, 300, 4100, 7.5, 900))
    return ins


def sqlite_db():
    import sqlite3
    conn = sqlite3.connect(":memory:")
    for db in (CHARS, WORLD, REALMD):
        conn.execute(f"ATTACH DATABASE ':memory:' AS {db}")
    for stmt in ddl():
        conn.execute(stmt)
    for sql, args in rows():
        conn.execute(sql.replace("%s", "?"), args)
    conn.commit()
    return conn


# ---- DBC files ---------------------------------------------------------------------------------

def write_dbc(path, nfields, records):
    """records: list of lists; ints, or str for a string field."""
    strings = bytearray(b"\0")
    offs = {}

    def soff(s):
        if s == "":
            return 0
        if s not in offs:
            offs[s] = len(strings)
            strings.extend(s.encode("utf-8") + b"\0")
        return offs[s]

    body = bytearray()
    for rec in records:
        rec = list(rec) + [0] * (nfields - len(rec))
        for v in rec:
            body += struct.pack("<I", soff(v) if isinstance(v, str) else (v & 0xFFFFFFFF))
    head = b"WDBC" + struct.pack("<4I", len(records), nfields, nfields * 4, len(strings))
    with open(path, "wb") as f:
        f.write(head + bytes(body) + bytes(strings))


def make_dbcs(d):
    os.makedirs(d, exist_ok=True)
    # ItemDisplayInfo: id, model x2, tex x2, icon x2 ... (23 fields)
    write_dbc(os.path.join(d, "ItemDisplayInfo.dbc"), 23,
              [[7001, "", "", "", "", "INV_Helmet_03"], [7002, "", "", "", "", "INV_Sword_50"],
               [7003, "", "", "", "", "INV_Chest_Plate03"], [7004, "", "", "", "", "INV_Chest_Cloth_25"],
               [7005, "", "", "", "", "INV_Jewelry_Ring_15"]])
    # SpellIcon: id, path
    write_dbc(os.path.join(d, "SpellIcon.dbc"), 2,
              [[132, "Interface\\Icons\\Ability_Rogue_Ambush"], [133, "Interface\\Icons\\Ability_Warrior_Charge"],
               [134, "Interface\\Icons\\Spell_Nature_EnchantArmor"], [500, "Interface\\Icons\\Ability_Rogue_Eviscerate"],
               [501, "Interface\\Icons\\Ability_Warrior_DefensiveStance"]])
    # TalentTab: id, name x8, flags, icon, race, class, order, bg (15)
    write_dbc(os.path.join(d, "TalentTab.dbc"), 15,
              [[161, "Arms", "", "", "", "", "", "", "", 0, 500, 0, 1, 0, "WarriorArms"],
               [164, "Fury", "", "", "", "", "", "", "", 0, 501, 0, 1, 1, "WarriorFury"],
               [163, "Protection", "", "", "", "", "", "", "", 0, 501, 0, 1, 2, "WarriorProtection"],
               [81, "Arcane", "", "", "", "", "", "", "", 0, 132, 0, 128, 0, "MageArcane"]])
    # Talent: id, tab, row, col, rank1..5, x4, depends, x2, dependsRank, x3, reqSpell (21)
    write_dbc(os.path.join(d, "Talent.dbc"), 21,
              [[1001, 161, 0, 0, 12282, 12663, 12664], [1002, 161, 0, 1, 12285, 12697],
               [1003, 161, 1, 1, 12295, 12676, 12677, 12678, 12300], [1101, 164, 0, 1, 12320, 12321, 12322, 12323, 12324],
               [1201, 163, 0, 0, 12298, 12724], [8001, 81, 0, 0, 11210, 12592]])
    # Faction: id, repIndex, raceMask x4, classMask x4, base x4, flags x4, team, name x8 ... (37)
    hum = 1 | 4 | 8 | 64     # alliance races (human, dwarf, night elf, gnome)
    write_dbc(os.path.join(d, "Faction.dbc"), 37,
              [[72, 1, hum, 0, 0, 0, 0, 0, 0, 0, 3100, 0, 0, 0, 16, 0, 0, 0, 469, "Stormwind"],
               [47, 2, hum, 0, 0, 0, 0, 0, 0, 0, 4000, 0, 0, 0, 16, 0, 0, 0, 469, "Ironforge"],
               [76, 3, 2 | 16 | 32 | 128, hum, 0, 0, 0, 0, 0, 0, 3100, -42000 & 0xFFFFFFFF, 0, 0, 16, 0, 0, 0, 67,
                "Orgrimmar"],
               [530, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, "Darkspear Trolls"]])
    # SpellItemEnchantment: id, ... names at 13 (24)
    write_dbc(os.path.join(d, "SpellItemEnchantment.dbc"), 24,
              [[1886] + [0] * 12 + ["+10 Stamina"], [1900] + [0] * 12 + ["Crusader"],
               [91] + [0] * 12 + ["+7 Agility"], [92] + [0] * 12 + ["+7 Stamina"]])
    # ItemRandomProperties: id, internal, ench x3, x2, name x8, flags (16)
    write_dbc(os.path.join(d, "ItemRandomProperties.dbc"), 16, [[777, "Monkey", 91, 92, 0, 0, 0, "of the Monkey"]])
    # ItemSet: id, name x8, flags, x16?, items at 10..26 ...: 45 fields
    write_dbc(os.path.join(d, "ItemSet.dbc"), 45,
              [[990, "Battlegear of Valor", "", "", "", "", "", "", "", 0, 990901, 990903, 990906, 990907]])
    return d
