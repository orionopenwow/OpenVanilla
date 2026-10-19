#!/usr/bin/env python3
"""Spell.dbc field -> CMaNGOS spell_template column (the server reads spells from the database,
the client from Spell.dbc). Writes crates/forge-core/schemas/spell_template.json.

    python3 spell_template_map.py [Spell.sql Spell.dbc]   # with both: also checks the map on real data
"""
import json, os, re, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__))
DBC = json.load(open(os.path.join(HERE, "..", "crates", "forge-core", "schemas", "dbc.json")))["Spell"]

RENAME = {"ID": "Id", "DispelType": "Dispel", "AttributesExB": "AttributesEx2", "AttributesExC": "AttributesEx3",
          "AttributesExD": "AttributesEx4", "ShapeshiftMask": "Stances", "ShapeshiftExclude": "StancesNot",
          "ManaCostPerLevel": "ManaCostPerlevel", "CumulativeAura": "StackAmount",
          "EquippedItemSubclass": "EquippedItemSubClassMask", "EquippedItemInvTypes": "EquippedItemInventoryTypeMask",
          "Name_lang": "SpellName", "NameSubtext_lang": "Rank1", "ManaCostPct": "ManaCostPercentage",
          "SpellClassSet": "SpellFamilyName", "MaxTargets": "MaxAffectedTargets", "DefenseType": "DmgClass",
          "MinFactionID": "MinFactionId"}
ARRAY = {"ImplicitTargetA": "EffectImplicitTargetA", "ImplicitTargetB": "EffectImplicitTargetB",
         "EffectAura": "EffectApplyAuraName", "EffectAuraPeriod": "EffectAmplitude",
         "EffectAmplitude": "EffectMultipleValue", "EffectChainTargets": "EffectChainTarget",
         "EffectPointsPerCombo": "EffectPointsPerComboPoint", "EffectChainAmplitude": "DmgMultiplier"}
SKIP = {"Description_lang", "AuraDescription_lang"}   # client-only text


def build():
    m = {}
    for f in DBC["fields"]:
        n, c = f["name"], f["count"]
        if n in SKIP:
            continue
        if n == "SpellVisualID":
            m["SpellVisualID[0]"] = "SpellVisual"     # [1] has no server column
        elif n == "SpellClassMask":
            m["SpellClassMask[0]"] = "SpellFamilyFlags:lo"
            m["SpellClassMask[1]"] = "SpellFamilyFlags:hi"
        elif c > 1:
            for k in range(c):
                m[f"{n}[{k}]"] = f"{ARRAY.get(n, n)}{k + 1}"
        else:
            m[n] = RENAME.get(n, n)
    return m


def check(m, sql_path, dbc_path):
    sql = open(sql_path, encoding="utf-8", errors="replace").read()
    ct = sql[sql.index("CREATE TABLE `spell_template`"):]
    cols = re.findall(r"^\s*`(\w+)`", ct[:ct.index("ENGINE")], re.M)
    for v in m.values():
        assert v.split(":")[0] in cols, v
    body = sql[sql.index("INSERT INTO `spell_template`"):]
    rows = {}
    for t in re.finditer(r"\((\d+),(.*?)\)(?=,\s*\(|;)", body, re.S):
        vals = [t.group(1)] + re.findall(r"'(?:[^'\\]|\\.|'')*'|[^,]+", t.group(2))
        if len(vals) == len(cols):
            rows[int(vals[0])] = dict(zip(cols, vals))
    b = open(dbc_path, "rb").read()
    n, f, rs, ss = struct.unpack("<4I", b[4:20])
    slot, at = {}, 0
    for fl in DBC["fields"]:
        w = 9 if fl["type"] == "locstring" else 1
        for k in range(fl["count"]):
            slot[fl["name"] if fl["count"] == 1 else f"{fl['name']}[{k}]"] = (at + k * w, fl["type"])
        at += fl["count"] * w
    bad = {}
    seen = 0
    for i in range(n):
        rec = struct.unpack("<%dI" % f, b[20 + i * rs:20 + (i + 1) * rs])
        r = rows.get(rec[0])
        if not r:
            continue
        seen += 1
        for key, col in m.items():
            o, typ = slot[key]
            if typ in ("string", "locstring"):
                continue
            w = rec[o]
            name, part = (col.split(":") + [None])[:2]
            sv = r[name]
            if part:
                x = int(sv)
                sv = str(x & 0xFFFFFFFF if part == "lo" else x >> 32)
            if typ == "float":
                ok = abs(float(sv) - struct.unpack("<f", struct.pack("<I", w))[0]) < 1e-3
            else:
                ok = (int(float(sv)) & 0xFFFFFFFF) == w
            if not ok:
                bad[key] = bad.get(key, 0) + 1
    print(f"checked {seen} spells; columns that differ (cmangos fixes are expected on a few):")
    for k, v in sorted(bad.items(), key=lambda x: -x[1]):
        print(f"  {k} -> {m[k]}: {v}")


if __name__ == "__main__":
    m = build()
    json.dump(m, open(os.path.join(HERE, "..", "crates", "forge-core", "schemas", "spell_template.json"), "w"), indent=1)
    print(len(m), "fields mapped")
    if len(sys.argv) == 3:
        check(m, *sys.argv[1:])
