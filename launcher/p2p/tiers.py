"""The three tiers of the Open Vanilla network, in one place for the launcher, the site and the directory
(docs/NODE_NETWORK.md has the prose; www/community/nodes.json carries TIERS for the site).

    tier_of_realm(entry)        -> "verified" | "community"
    badges_for_realm(entry)     -> ["official"|"verified", "community", "relayed", "e2e", ...]
    node_checks(node, now)      -> {check: {"ok": bool, "detail": str}} the automatic checks
    node_status(current, checks, decision) -> the next verification status of a node
    public_realm(entry)         -> a directory entry with nothing that reveals a relayed host's address
    public_node(node)           -> a node for public lists (no URL, no IP, no key)

Verification is two-step on purpose: machines check what can be measured (probes, uptime,
version, caps, reports), and only the maintainer flips a node or a community realm to Verified.
A verified node that later fails its checks drops back to "suspended" by itself and comes back
when it recovers; "revoked" is the maintainer's and stays until they lift it.
"""
import ipaddress

# ---------------------------------------------------------------- definitions (shown everywhere)

TIERS = [
    {"key": "verified", "label": "Verified realms", "badge": "VERIFIED", "color": "#e8b64c",
     "short": "Run by Open Vanilla, or a community realm the maintainer has vetted.",
     "criteria": [
         "Open Vanilla's own realms are always Verified.",
         "A community realm: listed for 14 days or more with 98% of reachability probes passing,",
         "uses Open Vanilla sign-in (players' passwords never reach the host) and keeps backups on,",
         "has a description and rules, no upheld reports, and its host's Open Vanilla account is in good standing,",
         "and the maintainer approved it. The maintainer can withdraw it at any time.",
     ]},
    {"key": "community", "label": "Community P2P realms", "badge": "COMMUNITY", "color": "#9aa0a6",
     "short": "Hosted by players from their own PCs. Listed after an automatic reachability check.",
     "criteria": [
         "Heartbeats every minute and answers the directory's probe (directly or through a relay).",
         "Name and description pass the word list; not on the blocklist.",
         "Not vetted by a person: play at your own risk. Your Open Vanilla password never reaches the host.",
     ]},
    {"key": "node", "label": "Verified P2P nodes", "badge": "NODE", "color": "#4fc3b0",
     "short": "Volunteers' relays that passed the checks and were approved by the maintainer.",
     "criteria": [
         "Reachable: the directory's probe passes and the node proves it holds its key.",
         "Up 95% of probes over the last 7 days, with at least 3 days of history.",
         "Current launcher (node protocol v1), end-to-end encryption required, caps at or above the minimum.",
         "Accepted the node rules (no logging of addresses, no inspecting or selling traffic).",
         "No upheld reports, and the maintainer approved it. Falls back to Pending by itself if it stops passing.",
     ]},
]
TIER_KEYS = tuple(t["key"] for t in TIERS)

BADGES = {
    "official": {"label": "OFFICIAL", "tier": "verified", "tip": "Run by the Open Vanilla team."},
    "verified": {"label": "VERIFIED", "tier": "verified", "tip": "A community realm the maintainer has vetted."},
    "community": {"label": "COMMUNITY", "tier": "community", "tip": "Hosted by a player. Not vetted by a person."},
    "relayed": {"label": "RELAYED", "tier": "community", "tip": "Players connect through a relay: the host's and "
                                                                   "players' addresses stay hidden from each other."},
    "e2e": {"label": "ENCRYPTED", "tier": "community", "tip": "Game traffic is encrypted end to end; relays see "
                                                              "only ciphertext."},
    "node": {"label": "NODE", "tier": "node", "tip": "A verified volunteer relay."},
    "pending": {"label": "PENDING", "tier": "node", "tip": "A volunteer relay still being checked."},
    "seeder": {"label": "SEEDER", "tier": "node", "tip": "Shares Open Vanilla's own downloads with other players."},
}

# ---------------------------------------------------------------- node criteria

NODE_PROTOCOL = 1
NODE_RULES_VERSION = 1
MIN_UPTIME_PCT = 95.0
SUSPEND_BELOW_PCT = 90.0
MIN_HISTORY_DAYS = 3
MIN_PROBES = 300               # ~3 days of 10-minute probes
MIN_KBPS = 256
MIN_DAILY_GB = 5
MIN_STREAMS = 16
NODE_STATUSES = ("unlisted", "pending", "verified", "suspended", "revoked")

REALM_MIN_DAYS = 14
REALM_MIN_UPTIME_PCT = 98.0


def node_checks(node, now):
    """node: {"first_seen", "probes_ok", "probes_total", "protocol", "e2e_required", "rules",
    "caps": {"kbps", "daily_gb", "max_streams"}, "reports_open", "blocked", "key_proof"}."""
    caps = node.get("caps") or {}
    days = max(0.0, (now - int(node.get("first_seen") or now)) / 86400.0)
    total, ok = int(node.get("probes_total") or 0), int(node.get("probes_ok") or 0)
    pct = 100.0 * ok / total if total else 0.0
    c = {
        "reachable": (bool(node.get("probe_ok_now")) and bool(node.get("key_proof")),
                      "probe passed and the node signed the challenge" if node.get("probe_ok_now") else
                      "the directory can't reach the node's port"),
        "history": (days >= MIN_HISTORY_DAYS and total >= MIN_PROBES,
                    f"{days:.1f} of {MIN_HISTORY_DAYS} days, {total} of {MIN_PROBES} probes"),
        "uptime": (total > 0 and pct >= MIN_UPTIME_PCT, f"{pct:.1f}% of probes passed (needs {MIN_UPTIME_PCT:.0f}%)"),
        "software": (int(node.get("protocol") or 0) >= NODE_PROTOCOL and bool(node.get("e2e_required")),
                     "node protocol v%s, %s" % (node.get("protocol") or 0,
                                                "end-to-end encryption required" if node.get("e2e_required") else
                                                "accepts unencrypted streams")),
        "caps": (int(caps.get("kbps") or 0) >= MIN_KBPS and float(caps.get("daily_gb") or 0) >= MIN_DAILY_GB
                 and int(caps.get("max_streams") or 0) >= MIN_STREAMS,
                 f"{caps.get('kbps', 0)} KB/s, {caps.get('daily_gb', 0)} GB/day, {caps.get('max_streams', 0)} streams "
                 f"(minimum {MIN_KBPS} KB/s, {MIN_DAILY_GB} GB/day, {MIN_STREAMS} streams)"),
        "rules": (int(node.get("rules") or 0) >= NODE_RULES_VERSION, "accepted the node rules" if
                  int(node.get("rules") or 0) >= NODE_RULES_VERSION else "hasn't accepted the current node rules"),
        "standing": (not node.get("blocked") and int(node.get("reports_open") or 0) == 0,
                     "blocked by staff" if node.get("blocked") else f"{int(node.get('reports_open') or 0)} open reports"),
    }
    return {k: {"ok": bool(v[0]), "detail": v[1]} for k, v in c.items()}


def checks_pass(checks):
    return all(v["ok"] for v in checks.values())


def node_status(current, checks, decision=None, uptime_pct=None):
    """Next status. decision: None | "approve" | "revoke" | "unrevoke" (the maintainer's)."""
    current = current if current in NODE_STATUSES else "unlisted"
    if decision == "revoke":
        return "revoked"
    if current == "revoked":
        return "pending" if decision == "unrevoke" else "revoked"
    ok = checks_pass(checks)
    if decision == "approve":
        if not ok:
            return "pending"          # the maintainer can only approve what passes the checks
        return "verified"
    if current == "verified":
        low = uptime_pct is not None and uptime_pct < SUSPEND_BELOW_PCT
        if not checks.get("reachable", {}).get("ok", True) or low or not checks.get("standing", {}).get("ok", True):
            return "suspended"
        return "verified"
    if current == "suspended":
        return "verified" if ok else "suspended"   # comes back by itself: it was approved before
    if checks.get("reachable", {}).get("ok"):
        return "pending"
    return current if current == "pending" else "unlisted"


# ---------------------------------------------------------------- realms

def tier_of_realm(entry):
    e = entry if isinstance(entry, dict) else getattr(entry, "__dict__", {})
    tags = {str(t).lower() for t in e.get("tags") or []}
    if e.get("official") or "official" in tags or e.get("verified"):
        return "verified"
    return "community"


def badges_for_realm(entry):
    e = entry if isinstance(entry, dict) else getattr(entry, "__dict__", {})
    tags = {str(t).lower() for t in e.get("tags") or []}
    out = []
    if e.get("official") or "official" in tags:
        out.append("official")
    elif e.get("verified"):
        out.append("verified")
    else:
        out.append("community")
    if e.get("relay"):
        out.append("relayed")
    if e.get("e2e"):
        out.append("e2e")
    return out


def realm_promotion_checks(realm, now):
    """What a community realm needs before the maintainer can make it Verified."""
    days = max(0.0, (now - int(realm.get("first_listed") or now)) / 86400.0)
    total, ok = int(realm.get("probes_total") or 0), int(realm.get("probes_ok") or 0)
    pct = 100.0 * ok / total if total else 0.0
    c = {
        "age": (days >= REALM_MIN_DAYS, f"listed {days:.0f} of {REALM_MIN_DAYS} days"),
        "uptime": (total > 0 and pct >= REALM_MIN_UPTIME_PCT, f"{pct:.1f}% of probes (needs {REALM_MIN_UPTIME_PCT:.0f}%)"),
        "identity": (bool(realm.get("identity")), "uses Open Vanilla sign-in" if realm.get("identity") else "own accounts only"),
        "backups": (bool(realm.get("backups")), "backups on" if realm.get("backups") else "backups off"),
        "description": (len(str(realm.get("description") or "")) >= 20, "has a description and rules"),
        "standing": (not realm.get("blocked") and int(realm.get("reports_upheld") or 0) == 0
                     and not realm.get("owner_banned"), "no upheld reports, owner in good standing"),
    }
    return {k: {"ok": bool(v[0]), "detail": v[1]} for k, v in c.items()}


def looks_like_ip(s):
    s = str(s or "").strip().strip("[]")
    try:
        ipaddress.ip_address(s)
        return True
    except ValueError:
        return False


def public_realm(entry, relay_host="relay.openvanilla.app"):
    """The directory's public JSON for one entry, with the privacy rule enforced: a relayed realm never
    shows the host's own address (host/port point at the relay; no "addr", "ip", "external_ip")."""
    e = dict(entry)
    out = {k: e[k] for k in ("name", "host", "port", "build", "tags", "description", "population", "last_seen",
                              "host_id", "type", "template", "region", "verified", "official", "relay", "version",
                              "portal", "relay_url", "key", "e2e") if k in e}
    if e.get("relay"):
        out["host"], out["port"] = relay_host, 3724
        if looks_like_ip(_host_of(e.get("portal"))):
            out.pop("portal", None)       # a portal on the host's bare IP would give the address away
    out["tier"] = tier_of_realm(e)
    out["badges"] = badges_for_realm(e)
    return out


def _host_of(url):
    import urllib.parse
    try:
        return urllib.parse.urlsplit(str(url or "")).hostname or ""
    except ValueError:
        return ""


def public_node(node):
    """A node for public lists (directory /api/nodes, nodes.json): never its URL, address or key."""
    name = node.get("display_name") if node.get("leaderboard") == "named" else None
    return {"tier": "node", "status": node.get("status", "pending"),
            "badges": ["node" if node.get("status") == "verified" else "pending"],
            "name": name or "Anonymous node", "anonymous": not name,
            "region": str(node.get("region") or "")[:8], "since": str(node.get("since") or "")[:7],
            "uptime_pct": round(float(node.get("uptime_pct") or 0)), "accepting": bool(node.get("accepting", True))}
