"""Set the official realm's name, address and links everywhere in one go.

    py -3 set_realm.py --name "Vanilla Remastered" --host play.example.com --discord https://discord.gg/abc123
    py -3 set_realm.py --host 203.0.113.10 --portal https://203.0.113.10:8090/     (portal defaults to https://HOST:8090/)

Rewrites: links.txt (all copies), launcher/defaults.json, www/community/directory.json, the website's
index/portal pages, the Discord bot and backend defaults, the Hetzner kit, and the realm row in the
local database (when MySQL is running). Re-run any time; it reads the current values from links.txt.
"""
import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LINKS = ["links.txt", os.path.join("launcher", "links.txt"), os.path.join("www", "downloads", "links.txt")]
TEXT_FILES = [os.path.join("www", "index.html"), os.path.join("www", "portal.html"), os.path.join("archive", "discord_bot.py"), "asset_server.py",
              os.path.join("archive", "publish_release.py"), os.path.join("hetzner", "database", "init_db.sql"), os.path.join("hetzner", "setup_hetzner.sh"),
              os.path.join("hetzner", "README.md"), ".env.example"]
JSON_FILES = [os.path.join("launcher", "defaults.json"), os.path.join("www", "community", "directory.json")]
HOST_RE = re.compile(r"(?=.{1,253}$)([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?")
# names the realm has had; all become the new name
OLD_NAMES = ["Open Vanilla RPPvE (Vanilla Remastered)", "Vanilla Remastered (Classic 1.12.1)", "OPENVANILLA RPPvE (DEDICATED)",
             "Open Vanilla RPPvE", "Vanilla Remastered"]


def rd(rel):
    with open(os.path.join(HERE, rel), encoding="utf-8", newline="") as f:
        return f.read()


def wr(rel, text):
    with open(os.path.join(HERE, rel), "w", encoding="utf-8", newline="") as f:
        f.write(text)


def current_links():
    out = {}
    for line in rd("links.txt").splitlines():
        k, sep, v = line.partition("=")
        if sep and not k.strip().startswith("#"):
            out[k.strip()] = v.strip()
    return out


def set_line(text, key, value):
    return re.sub(rf"(?m)^({re.escape(key)}\s*=\s*).*?(\r?)$", lambda m: f"{m.group(1)}{value}{m.group(2)}", text)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--name", help="realm name, e.g. 'Vanilla Remastered'")
    ap.add_argument("--host", help="address players connect to (DNS name or IP)")
    ap.add_argument("--portal", help="realm website for sign-up and browser play (default https://HOST:8090/)")
    ap.add_argument("--discord", help="permanent Discord invite link")
    a = ap.parse_args()
    cur = current_links()
    name = a.name or cur.get("REALM_NAME")
    host = a.host or cur.get("REALM_HOST")
    if not HOST_RE.fullmatch(host or ""):
        sys.exit(f"Not a valid host name or IP: {host!r}")
    portal = (a.portal or (f"https://{host}:8090/" if a.host else cur.get("BACKEND_URL") or f"https://{host}:8090/")).rstrip("/") + "/"
    if not portal.startswith("https://"):
        sys.exit("The portal must be an https:// address (the launcher only sends passwords over https).")
    discord = a.discord or cur.get("DISCORD_INVITE")
    if a.discord and not re.fullmatch(r"https://(discord\.gg|discord\.com/invite)/[A-Za-z0-9-]+", a.discord):
        sys.exit("The Discord link should look like https://discord.gg/abc123")

    old_host, old_portal, old_discord = cur.get("REALM_HOST"), cur.get("BACKEND_URL"), cur.get("DISCORD_INVITE")
    old_names = [n for n in [cur.get("REALM_NAME")] + OLD_NAMES if n and n != name]

    for rel in LINKS:
        if os.path.isfile(os.path.join(HERE, rel)):
            t = rd(rel)
            for k, v in (("REALM_NAME", name), ("REALM_HOST", host), ("BACKEND_URL", portal), ("DISCORD_INVITE", discord)):
                t = set_line(t, k, v)
            wr(rel, t)

    for rel in TEXT_FILES:
        if not os.path.isfile(os.path.join(HERE, rel)):
            continue
        t = rd(rel)
        for o in old_names:
            t = t.replace(o.upper(), name.upper()) if o.isupper() else t.replace(o, name)
        for o, n in ((old_portal, portal), (old_host, host), (old_discord, discord)):
            if o and o != n:
                t = t.replace(o, n)
        wr(rel, t)

    for rel in JSON_FILES:
        path = os.path.join(HERE, rel)
        if not os.path.isfile(path):
            continue
        data = json.loads(rd(rel))
        servers = list(data.get("realms", [])[:1]) + (data.get("directory", data).get("servers", [])[:1])
        for s in servers:  # the first entry is the official realm
            s.update(name=name, host=host, portal=portal)
            if s.get("description"):
                s["description"] = f"The official Open Vanilla realm, {name}: vanilla 1.12.1 with Classic+ additions."
        if "community" in data:
            data["community"]["discord"] = discord
        wr(rel, json.dumps(data, indent=2, ensure_ascii=False) + "\n")

    print(f"Realm set: {name} at {host}  ·  website {portal}  ·  Discord {discord}")
    try:  # the realm row realmd hands to players
        sys.path.insert(0, HERE)
        import server_control
        if server_control.is_port_open(int(server_control.MYSQL_PORT)):
            ret, _, err = server_control.run_mysql_query(
                f"UPDATE classicrealmd.realmlist SET name='{name.replace(chr(39), '')}', "
                f"address='{server_control.sql_value(host)}' WHERE id=1;")
            print("Database realm row updated." if ret == 0 else f"Database not updated: {err.strip()}")
        else:
            print("MySQL isn't running: the database realm row will be set when Go_Live runs.")
    except Exception as e:  # tooling extra; the files above are the main job
        print(f"Database not updated ({e}).")


if __name__ == "__main__":
    main()
