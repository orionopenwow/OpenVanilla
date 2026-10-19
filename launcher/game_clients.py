"""Game clients, with no Tk: the list Workshop > CLIENTS shows and the HOME client dropdown.

Four sources, merged by id (later sources update the fields an earlier one set):
    builtin   defaults.json `clients`         always in the dropdown, can't be removed (Vanilla)
    parked    defaults.json `clients_parked`  known clients the launcher doesn't offer by default
    live      live content `clients`           published by the maintainer (www/downloads/live.src.json)
    local     clients.txt in the user-data folder (the maintainer's and power users' own list)

The player's "Add to my clients" choices are a list of ids in settings (`my_clients`), so a client added
from live content keeps following the maintainer's edits.

clients.txt is Notepad-friendly: one client per block of `key = value` lines, a blank line between
blocks, `#` starts a comment. Keys: name, url, type (exe|engine|web), version, page, description, image,
status (available|coming_soon), id (made from the name when left out).

Standard library only; Python 3.10 compatible.
"""
import live_content

KEYS = ("id", "name", "type", "version", "url", "page", "repo", "description", "image", "status")
SOURCES = ("builtin", "parked", "live", "local")
CLIENTS_TXT_EXAMPLE = """\
# Open Vanilla game clients: one client per block, a blank line between blocks.
# They show up in Workshop > CLIENTS; press "Add to my clients" there to put one in the HOME dropdown.
#
# name = My Classic+ build
# type = engine
# version = 1.12.1
# url = https://example.org/downloads/MyClient.zip
# page = https://github.com/example/my-client
# description = A test build of the engine.
"""


def parse_clients_txt(text):
    """[client] from clients.txt's text (checked like live content; bad blocks are skipped)."""
    out, block = [], {}

    def flush():
        if block:
            c = live_content.sanitize_client(block)
            if c and all(c["id"] != o["id"] for o in out):
                out.append(c)
            block.clear()

    for raw in str(text or "").replace("﻿", "").splitlines():
        line = raw.strip()
        if not line:
            flush()
            continue
        if line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip().lower()
        if key in KEYS and value.strip():
            if key == "name" and block.get("name"):   # a new name without a blank line: a new client
                flush()
            block[key] = value.strip()
    flush()
    return out


def read_clients_txt(path):
    try:
        with open(path, encoding="utf-8-sig", errors="replace") as f:
            return parse_clients_txt(f.read())
    except OSError:
        return []


def from_defaults(c):
    """A defaults.json client in the catalog's shape (download_url -> url, note -> description, coming_soon -> status)."""
    e = dict(c)
    if e.get("download_url") and not e.get("url"):
        e["url"] = e["download_url"]
    if e.get("note") and not e.get("description"):
        e["description"] = e["note"]
    e.setdefault("status", "coming_soon" if e.get("coming_soon") else "available")
    return e


def _as_launcher_client(e):
    """Fill the fields the launcher's client code reads (download_url, homepage, exe, coming_soon)."""
    if e.get("url"):
        e["download_url"] = e["url"]
    if e.get("page"):
        e["homepage"] = e["page"]
    if e.get("type") == "exe":
        e.setdefault("exe", "WoW.exe")
    e["coming_soon"] = e.get("status") == "coming_soon"
    return e


def catalog(builtin=(), parked=(), live=(), local=()):
    """Every known client, in order (builtin, parked, live, local), merged by id. Each entry has
    `source` (where it first came from), `sources` (all of them) and `removable`."""
    merged = {}
    for source, items in zip(SOURCES, (builtin, parked, live, local)):
        for c in items or ():
            if not isinstance(c, dict) or not c.get("id"):
                continue
            c = from_defaults(c) if source in ("builtin", "parked") else dict(c)
            cur = merged.get(c["id"])
            if cur is None:
                merged[c["id"]] = dict(c, source=source, sources=[source], removable=source != "builtin")
                continue
            for k, v in c.items():
                if k == "id" or v in (None, ""):
                    continue
                if k == "type" and cur["source"] in ("builtin", "parked"):
                    continue   # what a shipped client is never changes
                cur[k] = v
            cur["sources"].append(source)
    return [_as_launcher_client(e) for e in merged.values()]


def my_clients(entries, added_ids):
    """The HOME dropdown: the built-in clients, then the ones the player added (in catalog order)."""
    added = set(added_ids or ())
    return [dict(e) for e in entries if e.get("source") == "builtin" or e["id"] in added]


def add(settings, cid):
    ids = settings.setdefault("my_clients", [])
    if cid not in ids:
        ids.append(cid)


def remove(settings, entry):
    """Take a client out of the dropdown. Built-in clients stay (False)."""
    if not entry.get("removable", True):
        return False
    ids = settings.get("my_clients", [])
    if entry["id"] in ids:
        ids.remove(entry["id"])
    return True
