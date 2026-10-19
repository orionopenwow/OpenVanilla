"""
gen_kits.py  (Open Vanilla / Warfront)

The level 60 starter kits: one complete PvP kit per class and spec, pure 1.12.1 items only.
Head, shoulders, chest, hands, legs and feet are the faction's epic PvP set (Field Marshal /
Marshal for the Alliance, Warlord / General for the Horde); every other slot is named below.

Checks every item against the world database's item_template (items.tsv, exported from
classicmangos) for: exists, the class may use it, it fits the slot. Writes:
  kits.json             the kits with item ids, for the website and the tools
  warfront_kits.sql     table warfront_kit (kit, faction, slot, item) for the server
  WarfrontKits.lua      the same data for the gear picker addon

Run: python3 gen_kits.py items.tsv outdir spell_template.tsv
"""
import json
import os
import sys

CLASS_BIT = {"Warrior": 1, "Paladin": 2, "Hunter": 4, "Rogue": 8, "Priest": 16,
             "Shaman": 64, "Mage": 128, "Warlock": 256, "Druid": 1024}
CLASS_ID = {"Warrior": 1, "Paladin": 2, "Hunter": 3, "Rogue": 4, "Priest": 5,
            "Shaman": 7, "Mage": 8, "Warlock": 9, "Druid": 11}

# equipment slot (0-based, as the server's EquipmentSlots) -> allowed InventoryType values
SLOT = {
    "head": (0, {1}), "neck": (1, {2}), "shoulders": (2, {3}), "chest": (4, {5, 20}),
    "waist": (5, {6}), "legs": (6, {7}), "feet": (7, {8}), "wrist": (8, {9}), "hands": (9, {10}),
    "finger1": (10, {11}), "finger2": (11, {11}), "trinket1": (12, {12}), "trinket2": (13, {12}),
    "back": (14, {16}), "mainhand": (15, {13, 17, 21}), "offhand": (16, {13, 14, 22, 23}),
    "ranged": (17, {15, 25, 26, 28}),
}
SET_SLOTS = ("head", "shoulders", "chest", "hands", "legs", "feet")
SET_RANK = {"head": 17, "shoulders": 17, "chest": 17, "hands": 16, "legs": 16, "feet": 16}
FACTIONS = ("Alliance", "Horde")

# Shared slot groups (names exactly as in item_template)
PHYS = {"neck": "Onyxia Tooth Pendant", "back": "Cloak of Draconic Might",
        "wrist": "Wristguards of Stability", "waist": "Onslaught Girdle",
        "finger1": "Quick Strike Ring", "finger2": "Master Dragonslayer's Ring",
        "trinket2": "Drake Fang Talisman"}
CASTER = {"neck": "Choker of the Fire Lord", "back": "Cloak of the Brood Lord",
          "waist": "Mana Igniting Cord", "finger1": "Band of Forced Concentration",
          "finger2": "Ring of Spell Power", "trinket2": "Talisman of Ephemeral Power"}
HEALER = {"neck": "Choker of Enlightenment", "back": "Cloak of the Brood Lord",
          "finger1": "Cauterizing Band", "finger2": "Ring of Blackrock",
          "trinket2": "Rejuvenating Gem"}


def kit(cls, spec, role, base, **slots):
    d = dict(base)
    d.update(slots)
    return {"class": cls, "spec": spec, "role": role, "slots": d}


KITS = [
    kit("Warrior", "Arms", "Melee", PHYS, mainhand="Ashkandi, Greatsword of the Brotherhood",
        ranged="Striker's Mark"),
    kit("Warrior", "Fury", "Melee", PHYS, mainhand="Chromatically Tempered Sword",
        offhand="Maladath, Runed Blade of the Black Flight", ranged="Striker's Mark"),
    kit("Paladin", "Retribution", "Melee", PHYS, wrist="Judgement Bindings",
        mainhand="Ashkandi, Greatsword of the Brotherhood", ranged="Libram of Fervor"),
    kit("Paladin", "Holy", "Healer", HEALER, wrist="Judgement Bindings", waist="Judgement Belt",
        mainhand="Aurastone Hammer", offhand="Red Dragonscale Protector", ranged="Libram of Divinity"),
    kit("Hunter", "Marksmanship", "Ranged", PHYS, wrist="Dragonstalker's Bracers",
        waist="Dragonstalker's Belt", mainhand="Ashkandi, Greatsword of the Brotherhood",
        ranged="Ashjre'thul, Crossbow of Smiting"),
    kit("Rogue", "Combat (swords)", "Melee", PHYS, neck="Prestor's Talisman of Connivery",
        wrist="Bloodfang Bracers", waist="Bloodfang Belt",
        mainhand="Chromatically Tempered Sword", offhand="Maladath, Runed Blade of the Black Flight",
        ranged="Striker's Mark"),
    kit("Rogue", "Subtlety (daggers)", "Melee", PHYS, neck="Prestor's Talisman of Connivery",
        wrist="Bloodfang Bracers", waist="Bloodfang Belt",
        mainhand="Perdition's Blade", offhand="Dragonfang Blade", ranged="Striker's Mark"),
    kit("Priest", "Shadow", "Caster", CASTER, wrist="Bindings of Transcendence",
        mainhand="Staff of the Shadow Flame", ranged="Dragon's Touch"),
    kit("Priest", "Holy / Discipline", "Healer", HEALER, wrist="Bindings of Transcendence",
        waist="Belt of Transcendence", mainhand="Aurastone Hammer", offhand="Lei of the Lifegiver",
        ranged="Essence Gatherer"),
    kit("Shaman", "Elemental", "Caster", CASTER, wrist="Bracers of Ten Storms",
        mainhand="Azuresong Mageblade", offhand="Fire Runed Grimoire", ranged="Totem of the Storm"),
    kit("Shaman", "Enhancement", "Melee", PHYS, mainhand="Draconic Maul", ranged="Totem of Rage"),
    kit("Shaman", "Restoration", "Healer", HEALER, wrist="Bracers of Ten Storms",
        waist="Belt of Ten Storms", mainhand="Aurastone Hammer", offhand="Red Dragonscale Protector",
        ranged="Totem of Sustaining"),
    kit("Mage", "Frost / Fire / Arcane", "Caster", CASTER, wrist="Netherwind Bindings",
        mainhand="Azuresong Mageblade", offhand="Fire Runed Grimoire", ranged="Dragon's Touch"),
    kit("Warlock", "Affliction / Destruction", "Caster", CASTER, wrist="Nemesis Bracers",
        mainhand="Staff of the Shadow Flame", ranged="Dragon's Touch"),
    kit("Druid", "Restoration", "Healer", HEALER, wrist="Stormrage Bracers", waist="Stormrage Belt",
        mainhand="Aurastone Hammer", offhand="Lei of the Lifegiver", ranged="Idol of Rejuvenation"),
    kit("Druid", "Feral", "Melee", PHYS, mainhand="Draconic Maul", ranged="Idol of Ferocity"),
    kit("Druid", "Balance", "Caster", CASTER, wrist="Stormrage Bracers",
        mainhand="Staff of the Shadow Flame", ranged="Idol of the Moon"),
]

# ── enchants: spell ids of 1.12.1 enchanting spells and Zul'Gurub / Zandalar item enchants ──
E = dict(CRUSADER=20034, SPELL=22749, HEAL=22750, AGI2H=27837, CHEST=20025, BR_STR=20010,
         BR_INT=20008, BR_HEAL=23802, GL_AGI=25080, GL_STR=20013, GL_HEAL=25079, GL_FROST=25074,
         GL_SHADOW=25073, GL_GAGI=20012, BOOTS=13890, CLOAK_AGI=13882, CLOAK_DEF=20015,
         SHIELD=20017, SCOPE=22779, SH_MIGHT=24422, SH_MOJO=24421, SH_SERENITY=24420)
ZG_IDOL = {"Warrior": 24149, "Paladin": 24160, "Rogue": 24161, "Hunter": 24162, "Shaman": 24163,
           "Mage": 24164, "Warlock": 24165, "Priest": 24167, "Druid": 24168}
GLOVES = {("Warrior", "Melee"): "GL_STR", ("Paladin", "Melee"): "GL_STR", ("Mage", "Caster"): "GL_FROST",
          ("Warlock", "Caster"): "GL_SHADOW", ("Priest", "Caster"): "GL_SHADOW"}


def kit_enchants(cls, role, slots):
    """slot -> enchant spell for a kit (slots: slot -> item row)."""
    melee = role in ("Melee", "Ranged")
    e = {"chest": E["CHEST"], "feet": E["BOOTS"], "head": ZG_IDOL[cls], "legs": ZG_IDOL[cls],
         "shoulders": E["SH_MIGHT"] if melee else E["SH_MOJO"] if role == "Caster" else E["SH_SERENITY"],
         "wrist": E["BR_STR"] if melee else E["BR_INT"] if role == "Caster" else E["BR_HEAL"],
         "back": E["CLOAK_AGI"] if melee else E["CLOAK_DEF"]}
    if role == "Healer":
        e["hands"] = E["GL_HEAL"]
    elif melee:
        e["hands"] = E[GLOVES.get((cls, "Melee"), "GL_AGI")]
    else:
        e["hands"] = E[GLOVES.get((cls, "Caster"), "GL_GAGI")]
    weapon = E["CRUSADER"] if melee else E["SPELL"] if role == "Caster" else E["HEAL"]
    for s in ("mainhand", "offhand"):
        r = slots.get(s)
        if not r:
            continue
        inv = int(r["InvType"])
        if inv == 14:
            e[s] = E["SHIELD"]
        elif inv in (13, 17, 21, 22):
            e[s] = E["AGI2H"] if (cls == "Hunter" and inv == 17) else weapon
    if cls == "Hunter" and "ranged" in slots:
        e["ranged"] = E["SCOPE"]
    return e


# Other enchants the picker offers besides the kits' (slot, spell)
EXTRA_ENCHANTS = [("mainhand", 20031), ("mainhand", 20032), ("mainhand", 20029), ("mainhand", 23800),
                  ("mainhand", 23799), ("mainhand", 20030), ("mainhand", 20036), ("offhand", 20031),
                  ("offhand", 20032), ("offhand", 20029), ("offhand", 23800), ("offhand", 23799),
                  ("chest", 20026), ("chest", 13917), ("wrist", 20011), ("wrist", 23801), ("wrist", 13931),
                  ("hands", 20012), ("hands", 25078), ("hands", 25072), ("feet", 20020), ("feet", 20023),
                  ("back", 25081), ("back", 25082), ("back", 25083), ("back", 25084), ("back", 25086),
                  ("back", 20014), ("head", 22840), ("head", 22844), ("head", 22846), ("legs", 22840),
                  ("legs", 22844), ("legs", 22846), ("offhand", 20016)]


# The consumables shop: (item, price in copper, most per purchase, name)
SHOP = [
    (13510, 250000, 5, 'Flask of the Titans'),
    (13452, 20000, 20, 'Elixir of the Mongoose'),
    (13454, 20000, 20, 'Greater Arcane Elixir'),
    (9206, 10000, 20, 'Elixir of Giants'),
    (9264, 10000, 20, 'Elixir of Shadow Power'),
    (21546, 10000, 20, 'Elixir of Greater Firepower'),
    (17708, 10000, 20, 'Elixir of Frost Power'),
    (3825, 5000, 20, 'Elixir of Fortitude'),
    (12820, 20000, 20, 'Winterfall Firewater'),
    (21151, 10000, 20, 'Rumsey Rum Black Label'),
    (12451, 20000, 20, 'Juju Power'),
    (12460, 20000, 20, 'Juju Might'),
    (13446, 10000, 20, 'Major Healing Potion'),
    (13444, 10000, 20, 'Major Mana Potion'),
    (5634, 10000, 20, 'Free Action Potion'),
    (3387, 20000, 20, 'Limited Invulnerability Potion'),
    (9030, 10000, 20, 'Restorative Potion'),
    (2459, 5000, 20, 'Swiftness Potion'),
    (13442, 10000, 20, 'Mighty Rage Potion'),
    (13457, 10000, 20, 'Greater Fire Protection Potion'),
    (13456, 10000, 20, 'Greater Frost Protection Potion'),
    (13458, 10000, 20, 'Greater Nature Protection Potion'),
    (13459, 10000, 20, 'Greater Shadow Protection Potion'),
    (14530, 2000, 20, 'Heavy Runecloth Bandage'),
    (15993, 5000, 20, 'Thorium Grenade'),
    (4390, 2000, 20, 'Iron Grenade'),
    (18641, 3000, 20, 'Dense Dynamite'),
    (12404, 5000, 20, 'Dense Sharpening Stone'),
    (18262, 20000, 20, 'Elemental Sharpening Stone'),
    (20749, 20000, 5, 'Brilliant Wizard Oil'),
    (20748, 20000, 5, 'Brilliant Mana Oil'),
    (13931, 1000, 20, 'Nightfin Soup'),
    (13928, 1000, 20, 'Grilled Squid'),
    (18254, 1000, 20, 'Runn Tum Tuber Surprise'),
    (20452, 1000, 20, 'Smoked Desert Dumplings'),
    (21023, 2000, 20, "Dirge's Kickin' Chimaerok Chops"),
    (8079, 500, 20, 'Conjured Crystal Water'),
    (10588, 500000, 1, 'Goblin Rocket Helmet'),
]


# Classes with no epic PvP set for a faction in 1.12.1 (the set falls back to the other faction's
# look-alike only when the realm allows cross-faction classes; otherwise the kit is not offered).
NO_SET = {("Paladin", "Horde"), ("Shaman", "Alliance")}


def load(path):
    hdr = ["entry", "class", "subclass", "name", "Quality", "InvType", "AllowClass", "AllowRace",
           "ilvl", "reqlvl", "honor", "repfac", "itemset", "sp1", "sp2", "sp3"]
    items = [dict(zip(hdr, l.rstrip("\n").split("\t"))) for l in open(path, encoding="utf-8")]
    return items


def by_name(items, name, cbit):
    hits = [r for r in items if r["name"] == name and
            (int(r["AllowClass"]) == -1 or int(r["AllowClass"]) & cbit)]
    hits = [r for r in hits if "DEP" not in r["name"] and "[PH]" not in r["name"]]
    return hits[0] if hits else None


def pvp_set(items, cls, faction):
    """The six pieces of the class's epic PvP set for that faction, slot -> item row."""
    cbit = CLASS_BIT[cls]
    pre = ("Field Marshal's", "Marshal's") if faction == "Alliance" else ("Warlord's", "General's")
    inv_slot = {1: "head", 3: "shoulders", 5: "chest", 20: "chest", 10: "hands", 7: "legs", 8: "feet"}
    out = {}
    for r in items:
        if r["Quality"] == "4" and r["name"].startswith(pre) and int(r["AllowClass"]) == cbit:
            s = inv_slot.get(int(r["InvType"]))
            if s and int(r["honor"]) == SET_RANK[s]:
                out[s] = r
    return out


def load_enchant_spells(path):
    """spell id -> (name, enchant id, item class, subclass mask, inventory type mask)"""
    import csv
    csv.field_size_limit(1 << 24)
    out = {}
    with open(path, encoding="utf-8") as f:
        r = csv.reader(f, delimiter="\t", quoting=csv.QUOTE_NONE)
        h = next(r)
        I = {k: i for i, k in enumerate(h)}
        for row in r:
            for n in (1, 2, 3):
                if row[I["Effect%d" % n]] == "53":
                    out[int(row[I["Id"]])] = (row[I["SpellName"]], int(row[I["EffectMiscValue%d" % n]]),
                                              int(row[I["EquippedItemClass"]]), int(row[I["EquippedItemSubClassMask"]]),
                                              int(row[I["EquippedItemInventoryTypeMask"]]))
    return out


def fits(spell, item):
    _, _, icls, sub, inv = spell
    if icls != -1:
        if icls != int(item["class"]):
            return False
        if sub and not (sub & (1 << int(item["subclass"]))):
            return False
    if inv and not (inv & (1 << int(item["InvType"]))):
        return False
    return True


def build(items, spells=None):
    errors, kits = [], []
    insignia = {}
    for r in items:
        if r["name"] in ("Insignia of the Alliance", "Insignia of the Horde"):
            insignia[(r["name"].split()[-1], int(r["AllowClass"]))] = r
    for k in KITS:
        cls, cbit = k["class"], CLASS_BIT[k["class"]]
        for faction in FACTIONS:
            if (cls, faction) in NO_SET:
                continue
            key = (cls + "-" + k["spec"]).lower().replace(" / ", "-").replace(" ", "-") \
                .replace("(", "").replace(")", "") + "-" + faction[0].lower()
            slots = {}
            for s, r in pvp_set(items, cls, faction).items():
                slots[s] = r
            ins = insignia.get((faction, cbit))
            if ins:
                slots["trinket1"] = ins
            else:
                errors.append("%s: no Insignia" % key)
            for s, name in k["slots"].items():
                r = by_name(items, name, cbit)
                if not r:
                    errors.append("%s: %s '%s' not found or not usable by %s" % (key, s, name, cls))
                    continue
                if int(r["InvType"]) not in SLOT[s][1]:
                    errors.append("%s: '%s' does not fit %s (InventoryType %s)" % (key, name, s, r["InvType"]))
                    continue
                slots[s] = r
            two_hand = "mainhand" in slots and slots["mainhand"]["InvType"] == "17"
            need = [s for s in SLOT if not (s == "offhand" and two_hand)]
            missing = [s for s in need if s not in slots]
            if missing:
                errors.append("%s: missing %s" % (key, ", ".join(missing)))
            enchants = {}
            if spells is not None:
                for s2, sp in kit_enchants(cls, k["role"], slots).items():
                    if sp not in spells:
                        errors.append("%s: enchant %d is not an enchanting spell" % (key, sp))
                    elif s2 in slots and not fits(spells[sp], slots[s2]):
                        errors.append("%s: enchant %s does not fit %s '%s'" % (key, spells[sp][0], s2, slots[s2]["name"]))
                    elif s2 in slots:
                        enchants[s2] = {"spell": sp, "name": spells[sp][0]}
            kits.append({"key": key, "enchants": enchants, "class": cls, "class_id": CLASS_ID[cls], "spec": k["spec"],
                         "role": k["role"], "faction": faction,
                         "items": {s: {"id": int(r["entry"]), "name": r["name"], "ilvl": int(r["ilvl"])}
                                   for s, r in slots.items()}})
    if spells is not None:
        for s, sp in EXTRA_ENCHANTS:
            if sp not in spells:
                errors.append("extra enchant %d (%s) is not an enchanting spell" % (sp, s))
    return kits, errors


def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def write(kits, out):
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "kits.json"), "w") as f:
        json.dump(kits, f, indent=1)
    with open(os.path.join(out, "warfront_kits.sql"), "w") as f:
        f.write("-- Warfront level 60 kits (generated by tools/warfront/gen_kits.py; do not edit)\n")
        f.write("CREATE TABLE IF NOT EXISTS `warfront_kit` (\n  `kit` varchar(64) NOT NULL,\n"
                "  `class` tinyint unsigned NOT NULL,\n  `spec` varchar(48) NOT NULL,\n"
                "  `faction` enum('Alliance','Horde') NOT NULL,\n  `slot` tinyint unsigned NOT NULL,\n"
                "  `item` mediumint unsigned NOT NULL,\n  PRIMARY KEY (`kit`,`slot`)\n) ENGINE=InnoDB;\n")
        f.write("DELETE FROM `warfront_kit`;\nINSERT INTO `warfront_kit` VALUES\n")
        rows = []
        for k in kits:
            for s, it in sorted(k["items"].items(), key=lambda x: SLOT[x[0]][0]):
                rows.append("('%s',%d,'%s','%s',%d,%d)" % (k["key"], k["class_id"],
                            k["spec"].replace("'", "''"), k["faction"], SLOT[s][0], it["id"]))
        f.write(",\n".join(rows) + ";\n")
        f.write("CREATE TABLE IF NOT EXISTS `warfront_kit_enchant` (\n  `kit` varchar(64) NOT NULL,\n"
                "  `slot` tinyint unsigned NOT NULL,\n  `spell` mediumint unsigned NOT NULL,\n"
                "  PRIMARY KEY (`kit`,`slot`)\n) ENGINE=InnoDB;\n")
        f.write("DELETE FROM `warfront_kit_enchant`;\nINSERT INTO `warfront_kit_enchant` VALUES\n")
        rows = []
        for k in kits:
            for s, en in sorted(k["enchants"].items(), key=lambda x: SLOT[x[0]][0]):
                rows.append("('%s',%d,%d)" % (k["key"], SLOT[s][0], en["spell"]))
        f.write(",\n".join(rows) + ";\n")
        # every enchant a player may choose in the picker: the kit ones, per slot
        allowed = sorted({(SLOT[s][0], en["spell"]) for k in kits for s, en in k["enchants"].items()} |
                         {(SLOT[s][0], sp) for s, sp in EXTRA_ENCHANTS})
        f.write("CREATE TABLE IF NOT EXISTS `warfront_enchant` (\n  `slot` tinyint unsigned NOT NULL,\n"
                "  `spell` mediumint unsigned NOT NULL,\n  PRIMARY KEY (`slot`,`spell`)\n) ENGINE=InnoDB;\n")
        f.write("DELETE FROM `warfront_enchant`;\nINSERT INTO `warfront_enchant` VALUES\n" +
                ",\n".join("(%d,%d)" % a for a in allowed) + ";\n")
        f.write("CREATE TABLE IF NOT EXISTS `warfront_consumable` (\n  `item` mediumint unsigned NOT NULL,\n"
                "  `price` int unsigned NOT NULL,\n  `max_count` smallint unsigned NOT NULL DEFAULT 20,\n"
                "  PRIMARY KEY (`item`)\n) ENGINE=InnoDB;\n")
        f.write("DELETE FROM `warfront_consumable`;\nINSERT INTO `warfront_consumable` (`item`, `price`, `max_count`) VALUES\n" +
                ",\n".join("(%d,%d,%d)" % (i, pr, mx) for i, pr, mx, _ in SHOP) + ";\n")
    with open(os.path.join(out, "WarfrontKits.lua"), "w") as f:
        f.write("-- Warfront level 60 kits (generated by tools/warfront/gen_kits.py; do not edit)\n")
        f.write("WarfrontKits = {\n")
        for k in kits:
            f.write("  { key = %s, class = %s, spec = %s, role = %s, faction = %s, items = {\n" % (
                lua_str(k["key"]), lua_str(k["class"].upper()), lua_str(k["spec"]),
                lua_str(k["role"]), lua_str(k["faction"])))
            for s, it in sorted(k["items"].items(), key=lambda x: SLOT[x[0]][0]):
                f.write("    [%d] = %d, -- %s: %s\n" % (SLOT[s][0] + 1, it["id"], s, it["name"]))
            f.write("  }, enchants = {\n")
            for s, en in sorted(k["enchants"].items(), key=lambda x: SLOT[x[0]][0]):
                f.write("    [%d] = %d, -- %s\n" % (SLOT[s][0] + 1, en["spell"], en["name"]))
            f.write("  } },\n")
        f.write("}\n")
        # enchants offered per slot (slot numbers as GetInventoryItemLink: 1 = head ... 18 = ranged)
        f.write("WarfrontEnchants = {\n")
        per = {}
        for k in kits:
            for s, en in k["enchants"].items():
                per.setdefault(SLOT[s][0] + 1, {})[en["spell"]] = en["name"]
        for s, sp in EXTRA_ENCHANTS:
            if SPELLS and sp in SPELLS:
                per.setdefault(SLOT[s][0] + 1, {})[sp] = SPELLS[sp][0]
        for slot in sorted(per):
            f.write("  [%d] = {\n" % slot)
            for sp, name in sorted(per[slot].items(), key=lambda x: x[1]):
                f.write("    { %d, %s },\n" % (sp, lua_str(name)))
            f.write("  },\n")
        f.write("}\n")
        f.write("WarfrontShop = {\n")
        for i, pr, mx, name in SHOP:
            f.write("  { %d, %d, %d, %s },\n" % (i, pr, mx, lua_str(name)))
        f.write("}\n")


SPELLS = None


if __name__ == "__main__":
    items = load(sys.argv[1])
    spells = load_enchant_spells(sys.argv[3]) if len(sys.argv) > 3 else None
    SPELLS = spells
    kits, errors = build(items, spells)
    if spells is None:
        errors.append("give spell_template.tsv as the third argument to check the enchants")
    for e in errors:
        print("ERROR", e)
    if errors:
        print("%d errors: nothing written" % len(errors))
        sys.exit(1)
    write(kits, sys.argv[2])
    print("%d kits, 0 errors" % len(kits))
