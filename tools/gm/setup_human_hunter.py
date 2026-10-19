import os
import shutil
import struct
import urllib.request
import base64
import server_control

# --- File Paths ---
SERVER_DBC = os.environ.get("SERVER_DBC") or os.path.expanduser(r"~\Desktop\Games\SPP_Classics_V2\SPP_Server\Modules\vanilla\dbc\CharStartOutfit.dbc")
CLIENT_DBC = os.environ.get("CLIENT_DBC") or os.path.expanduser(r"~\WoW-1.12.1\Data\dbfilesclient\charstartoutfit.dbc")

def update_dbc():
    print("[DBC] Updating CharStartOutfit.dbc...")
    
    # 1. Backups
    if not os.path.exists(SERVER_DBC + ".bak"):
        shutil.copy2(SERVER_DBC, SERVER_DBC + ".bak")
        print(f"[DBC] Created server backup {SERVER_DBC}.bak")
    if not os.path.exists(CLIENT_DBC + ".bak"):
        shutil.copy2(CLIENT_DBC, CLIENT_DBC + ".bak")
        print(f"[DBC] Created client backup {CLIENT_DBC}.bak")

    with open(SERVER_DBC, "rb") as f:
        header = f.read(20)
        magic, records, fields, record_size, string_size = struct.unpack("4s4I", header)
        records_data = [f.read(record_size) for _ in range(records)]
        string_data = f.read(string_size)

    print(f"[DBC] Original records: {records}, record size: {record_size}")

    # Canonical starter outfit for Hunter (Bow, Dagger, Quiver, Arrows, Trapper set, Jerky, Water, Hearthstone)
    items = [2092, 148, 147, 129, 159, 2504, 2101, 2512, 117, 0, 6948, -1]
    displays = [6442, 9976, 9975, 9977, 18084, 8106, 21328, 5996, 2473, -1, 6418, -1]
    invtypes = [13, 4, 7, 8, 0, 15, 18, 24, 0, -1, 0, -1]

    # Check if records already exist
    existing_outfits = []
    for r in records_data:
        oid, race, cls, gen, sub = struct.unpack("IBBBB", r[:8])
        if race == 1 and cls == 3:
            existing_outfits.append((oid, gen))

    if existing_outfits:
        print(f"[DBC] Human Hunter outfits already present: {existing_outfits}")
    else:
        male_rec = struct.pack("IBBBB12i12i12i", 319, 1, 3, 0, 0, *items, *displays, *invtypes)
        female_rec = struct.pack("IBBBB12i12i12i", 320, 1, 3, 1, 0, *items, *displays, *invtypes)
        records_data.append(male_rec)
        records_data.append(female_rec)
        records += 2
        print(f"[DBC] Added Male (319) and Female (320) Human Hunter outfits. New count: {records}")

    new_header = struct.pack("4s4I", magic, records, fields, record_size, string_size)
    new_dbc_bytes = new_header + b"".join(records_data) + string_data

    with open(SERVER_DBC, "wb") as f:
        f.write(new_dbc_bytes)
    with open(CLIENT_DBC, "wb") as f:
        f.write(new_dbc_bytes)
    print(f"[DBC] Successfully wrote updated DBC to server and client ({len(new_dbc_bytes)} bytes).")

def update_database():
    print("[DB] Updating classicmangos tables for Human Hunter...")
    
    # 1. Skills: Give race 1 (Human) weapon skills for Bows, Daggers, Axes, Guns
    # Skill 45: Bows (Hunter) -> raceMask | 1
    # Skill 173: Daggers (Hunter) -> raceMask | 1
    # Skill 44: Axes (Hunter) -> raceMask | 1
    # Skill 46: Guns (Hunter) -> raceMask | 1
    sql_skills = """
    USE classicmangos;
    UPDATE playercreateinfo_skills SET raceMask = raceMask | 1 WHERE classMask & 4 AND skill IN (44, 45, 46, 173);
    """
    ret, out, err = server_control.run_mysql_query(sql_skills)
    if ret != 0:
        print(f"[DB] Error updating skills: {err}")
    else:
        print("[DB] Updated playercreateinfo_skills.")

    # 2. Spells: Clean up Dwarf racials on Human Hunter and add Bows, Daggers, and Human racials
    sql_spells = """
    USE classicmangos;
    DELETE FROM playercreateinfo_spell WHERE race=1 AND class=3 AND Spell IN (672, 2481, 20594, 20595, 20596);
    INSERT IGNORE INTO playercreateinfo_spell (race, class, Spell, Note) VALUES
    (1, 3, 264, 'Bows'),
    (1, 3, 1180, 'Daggers'),
    (1, 3, 20598, 'The Human Spirit'),
    (1, 3, 20599, 'Diplomacy'),
    (1, 3, 20600, 'Perception'),
    (1, 3, 20597, 'Sword Specialization'),
    (1, 3, 20864, 'Mace Specialization');
    """
    ret, out, err = server_control.run_mysql_query(sql_spells)
    if ret != 0:
        print(f"[DB] Error updating spells: {err}")
    else:
        print("[DB] Updated playercreateinfo_spell.")

    # 3. Actions: Fix action bar button 3 (Perception) and button 4
    sql_actions = """
    USE classicmangos;
    UPDATE playercreateinfo_action SET action=20600 WHERE race=1 AND class=3 AND button=3;
    DELETE FROM playercreateinfo_action WHERE race=1 AND class=3 AND button=4;
    """
    ret, out, err = server_control.run_mysql_query(sql_actions)
    if ret != 0:
        print(f"[DB] Error updating actions: {err}")
    else:
        print("[DB] Updated playercreateinfo_action.")

def send_soap_command(command):
    import xml.sax.saxutils
    url = "http://127.0.0.1:7878"
    escaped = xml.sax.saxutils.escape(command)
    body = (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/">'
        '<SOAP-ENV:Body>'
        '<ns1:executeCommand xmlns:ns1="urn:MaNGOS">'
        f'<command>{escaped}</command>'
        '</ns1:executeCommand>'
        '</SOAP-ENV:Body>'
        '</SOAP-ENV:Envelope>'
    )
    auth = base64.b64encode(b"ADMIN:admin").decode("ascii")
    req = urllib.request.Request(
        url,
        data=body.encode("utf-8"),
        headers={
            "Authorization": f"Basic {auth}",
            "Content-Type": "application/xml; charset=utf-8"
        }
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            text = resp.read().decode("utf-8")
            start = text.find("<result>")
            end = text.find("</result>")
            if start != -1 and end != -1:
                return text[start+8:end].strip()
            return text
    except Exception as e:
        return f"SOAP error: {e}"

def update_crackt_character():
    print("[CHAR] Updating character 'Crackt' (guid 4523)...")
    
    # 1. Update skills in classiccharacters
    sql_char_skills = """
    USE classiccharacters;
    DELETE FROM character_skills WHERE guid=4523 AND skill IN (111, 754);
    INSERT INTO character_skills (guid, skill, value, max) VALUES
    (4523, 44, 1, 5),
    (4523, 45, 1, 5),
    (4523, 46, 1, 5),
    (4523, 173, 1, 5)
    ON DUPLICATE KEY UPDATE value=VALUES(value), max=VALUES(max);
    """
    server_control.run_mysql_query(sql_char_skills)

    # 2. Update spells in classiccharacters
    sql_char_spells = """
    USE classiccharacters;
    DELETE FROM character_spell WHERE guid=4523 AND spell IN (672, 2481, 20594, 20595, 20596);
    INSERT IGNORE INTO character_spell (guid, spell, active, disabled) VALUES
    (4523, 75, 1, 0),
    (4523, 196, 1, 0),
    (4523, 203, 1, 0),
    (4523, 204, 1, 0),
    (4523, 264, 1, 0),
    (4523, 266, 1, 0),
    (4523, 668, 1, 0),
    (4523, 1180, 1, 0),
    (4523, 2973, 1, 0),
    (4523, 6603, 1, 0),
    (4523, 9077, 1, 0),
    (4523, 9078, 1, 0),
    (4523, 20597, 1, 0),
    (4523, 20598, 1, 0),
    (4523, 20599, 1, 0),
    (4523, 20600, 1, 0),
    (4523, 20864, 1, 0);
    """
    server_control.run_mysql_query(sql_char_spells)

    # 3. Update actions in classiccharacters
    sql_char_actions = """
    USE classiccharacters;
    DELETE FROM character_action WHERE guid=4523;
    INSERT INTO character_action (guid, button, action, type) VALUES
    (4523, 0, 6603, 0),
    (4523, 1, 2973, 0),
    (4523, 2, 75, 0),
    (4523, 3, 20600, 0),
    (4523, 10, 159, 128),
    (4523, 11, 117, 128);
    """
    server_control.run_mysql_query(sql_char_actions)

    # 4. Send starter gear via SOAP mail to Crackt
    mail_cmd = 'send items Crackt "Starting Equipment" "Here is your Hunter starting gear!" 2092 148 147 129 2504 2101 2512:200 159:5 117:5 6948'
    res = send_soap_command(mail_cmd)
    print(f"[CHAR] Mail sent to Crackt: {res}")

if __name__ == "__main__":
    update_dbc()
    update_database()
    update_crackt_character()
    print("\n[ALL] Done! All starting gear configurations applied.")
