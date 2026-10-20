"""The supporter leaderboard: people who run relay nodes or seed Open Vanilla's downloads.

    data = aggregate(nodes, reports, now)       # -> the www/community/nodes.json document
    rows = parse(data)                          # the launcher's view of it (tolerant of junk)

Inputs are what the directory keeps (realm/patches/pending/0016-openvanilla-node-network.patch):
  nodes   [{"node_id", "status", "region", "first_seen", "leaderboard": off|anonymous|named,
            "display_name", "probes_ok_30d", "probes_total_30d", "accepting"}]
  reports [{"node_id", "day": "YYYY-MM-DD", "relay_bytes", "seed_bytes"}]   one row per node per UTC day

Privacy, enforced here so that no page or launcher can show more:
  * no IP address, URL, key, node id or account id ever leaves aggregate(); ranks, not ids;
  * a display name only when its owner chose "named" (cleaned, 3-24 printable characters);
    "anonymous" shows as "Anonymous node"; "off" isn't listed but still counts in the totals;
  * numbers are coarse: GB to one decimal, uptime to whole percent, "since" to the month;
  * a node that leaves drops off the next build (nothing is kept per person beyond 30 days).
Self-reported bytes are capped at what the node's own caps allow (kbps x uptime), so inflating
them doesn't help; the directory also cross-checks relay bytes against hosts' agents (patch notes).
"""
import datetime
import re

from . import tiers

WINDOW_DAYS = 30
TOP = 50
SEED_WEIGHT = 0.5
WORDS = ("admin", "openvanilla staff", "open vanilla staff", "openvanilla staff", "moderator", "official")


def _gb(n):
    return round(max(0, int(n or 0)) / 1e9, 1)


def clean_name(name):
    name = re.sub(r"\s+", " ", "".join(ch for ch in str(name or "") if ch.isprintable())).strip()[:24]
    if len(name) < 3 or any(w in name.lower() for w in WORDS) or re.search(r"https?://|www\.|\.\w{2,4}/", name):
        return ""
    return name


def _month(ts):
    try:
        return datetime.datetime.fromtimestamp(int(ts), datetime.timezone.utc).strftime("%Y-%m")
    except (TypeError, ValueError, OverflowError, OSError):
        return ""


def aggregate(nodes, reports, now, window_days=WINDOW_DAYS, top=TOP, official=None):
    since_day = datetime.datetime.fromtimestamp(now - window_days * 86400, datetime.timezone.utc).strftime("%Y-%m-%d")
    by = {}
    for n in nodes or []:
        if isinstance(n, dict) and n.get("node_id"):
            by[n["node_id"]] = {"node": n, "relay": 0, "seed": 0, "days": set()}
    for r in reports or []:
        if not isinstance(r, dict):
            continue
        b = by.get(r.get("node_id"))
        if b is None or str(r.get("day", "")) < since_day:
            continue
        caps = b["node"].get("caps") or {}
        day_cap = int(caps.get("kbps") or 0) * 1024 * 86400 if caps.get("kbps") else None
        relay = max(0, int(r.get("relay_bytes") or 0))
        if day_cap is not None:
            relay = min(relay, day_cap)          # can't relay more than the node's own cap allows
        b["relay"] += relay
        b["seed"] += max(0, int(r.get("seed_bytes") or 0))
        b["days"].add(r.get("day"))
    rows, totals = [], {"relay_gb": 0.0, "seed_gb": 0.0, "nodes_verified": 0, "nodes_pending": 0, "supporters": 0}
    regions = {}
    for b in by.values():
        n = b["node"]
        status = n.get("status") if n.get("status") in tiers.NODE_STATUSES else "pending"
        if status in ("revoked", "unlisted"):
            continue
        totals["relay_gb"] += b["relay"] / 1e9
        totals["seed_gb"] += b["seed"] / 1e9
        totals["nodes_verified" if status == "verified" else "nodes_pending"] += 1
        reg = str(n.get("region") or "")[:8] or "?"
        regions[reg] = regions.get(reg, 0) + 1
        mode = n.get("leaderboard") if n.get("leaderboard") in ("off", "anonymous", "named") else "anonymous"
        if mode == "off" or (b["relay"] == 0 and b["seed"] == 0):
            continue
        name = clean_name(n.get("display_name")) if mode == "named" else ""
        total = int(n.get("probes_total_30d") or 0)
        uptime = round(100.0 * int(n.get("probes_ok_30d") or 0) / total) if total else 0
        badges = (["node"] if status == "verified" else ["pending"]) + (["seeder"] if b["seed"] else [])
        rows.append({"name": name or "Anonymous node", "anonymous": not name, "verified": status == "verified",
                     "region": reg, "relay_gb": _gb(b["relay"]), "seed_gb": _gb(b["seed"]), "uptime_pct": uptime,
                     "days_active": len(b["days"]), "since": _month(n.get("first_seen")), "badges": badges,
                     "_score": b["relay"] + SEED_WEIGHT * b["seed"]})
    rows.sort(key=lambda r: (-r["_score"], -r["uptime_pct"], r["name"].lower()))
    for i, r in enumerate(rows, 1):
        r["rank"] = i
        del r["_score"]
    totals["supporters"] = len(rows)
    totals["relay_gb"] = round(totals["relay_gb"], 1)
    totals["seed_gb"] = round(totals["seed_gb"], 1)
    return {
        "version": 1,
        "updated": datetime.datetime.fromtimestamp(now, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "window_days": window_days,
        "tiers": tiers.TIERS,
        "network": dict(totals, regions=regions),
        "official": official if official is not None else OFFICIAL,
        "supporters": rows[:top],
        "privacy": PRIVACY,
    }


OFFICIAL = [{"name": "relay.openvanilla.app", "status": "test round",
             "note": "Open Vanilla's own relay, on the maintainer's server. Not on the leaderboard."}]

PRIVACY = ("Opt-in. No IP addresses, node addresses, keys or account ids are published. Names appear only for "
           "supporters who chose to show one; everyone else is \"Anonymous node\" or not listed. Totals cover the "
           "last 30 days, rounded to 0.1 GB.")


def parse(data):
    """The launcher's leaderboard rows from nodes.json (anything malformed is skipped)."""
    out = []
    for r in (data or {}).get("supporters") or []:
        if not isinstance(r, dict):
            continue
        try:
            out.append({"rank": int(r.get("rank") or len(out) + 1),
                        "name": clean_name(r.get("name")) or "Anonymous node",
                        "verified": bool(r.get("verified")), "region": str(r.get("region") or "")[:8],
                        "relay_gb": float(r.get("relay_gb") or 0), "seed_gb": float(r.get("seed_gb") or 0),
                        "uptime_pct": int(r.get("uptime_pct") or 0),
                        "badges": [b for b in (r.get("badges") or []) if b in tiers.BADGES]})
        except (TypeError, ValueError):
            continue
    return out
