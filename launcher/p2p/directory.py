"""The live realm list (GET /api/directory) and realmd pings, for the launcher's Community page.

    realms = fetch()                    # list[Realm]; raises P2PError when the list can't be read
    ms = ping(realms[0])                # realmd challenge round trip in ms, or None
    report(host_id, reason, token)      # POST /api/directory/report (signed-in players)

Private realms are never in the list; they are joined by invite link (p2p.join).
"""
import dataclasses
import re
import time
import urllib.parse

from . import CENTRAL_URL, DIRECTORY_URL, HOST_ID_RE, RELAY_URL, P2PError, http_json, realmproto, tiers

FP_RE = re.compile(r"^[a-z2-7]{16}$")


def relay_base(relay_url, host_id):
    """"wss://node.example:3728/h/<host_id>" -> "wss://node.example:3728"; anything odd -> ""."""
    u = str(relay_url or "").strip().rstrip("/")
    if not u:
        return ""
    try:
        p = urllib.parse.urlsplit(u)
    except ValueError:
        return ""
    if p.scheme not in ("ws", "wss") or not p.hostname or p.query or p.fragment:
        return ""
    path = p.path
    if host_id and path.endswith("/h/" + host_id):
        path = path[: -len("/h/" + host_id)]
    if path not in ("", "/"):
        return ""
    return f"{p.scheme}://{p.netloc}"

TYPE_TAGS = {"pve": "PvE", "pvp": "PvP", "rp": "RPPvE", "rppvp": "RPPvP"}


@dataclasses.dataclass
class Realm:
    name: str
    host: str
    port: int = 3724
    type: str = "pve"
    population: int = 0
    tags: list = dataclasses.field(default_factory=list)
    template: str = "classicplus"
    verified: bool = False
    official: bool = False
    relay: bool = False
    host_id: str = ""
    last_seen: int = 0
    ping: int = None
    description: str = ""
    portal: str = ""
    build: int = 5875
    version: str = ""
    relay_url: str = ""        # which relay carries it: Open Vanilla's, or a verified volunteer node (".../h/<host_id>")
    key: str = ""              # host key fingerprint (checked in the e2e handshake)
    e2e: bool = False          # the host answers end-to-end encrypted streams
    tier: str = "community"    # tiers.TIERS: "verified" | "community"
    badges: list = dataclasses.field(default_factory=list)

    def as_dict(self):
        return dataclasses.asdict(self)


def _type_from(entry):
    t = str(entry.get("type", "")).lower()
    if t in TYPE_TAGS:
        return t
    tags = {str(x).lower() for x in entry.get("tags", [])}
    for k, tag in (("rppvp", "rppvp"), ("rp", "rppve"), ("pvp", "pvp"), ("pve", "pve")):
        if tag in tags:
            return k
    return "pve"


def _clean(s, n):
    return "".join(ch for ch in str(s or "") if ch.isprintable())[:n]


def parse(data):
    out = []
    for e in (data or {}).get("servers", []) or []:
        if not isinstance(e, dict) or e.get("visibility") == "private":
            continue
        name, host = _clean(e.get("name"), 40), _clean(e.get("host"), 253)
        try:
            port = int(e.get("port", 3724))
        except (TypeError, ValueError):
            continue
        if not name or not host or not 0 < port < 65536:
            continue
        host_id = str(e.get("host_id") or "")
        relay = bool(e.get("relay")) and bool(HOST_ID_RE.match(host_id))
        tags = [_clean(t, 24) for t in (e.get("tags") or [])][:8]
        key = str(e.get("key") or "")
        r_url = relay_base(e.get("relay_url"), host_id) if relay else ""
        out.append(Realm(
            name=name, host=host, port=port, type=_type_from(e),
            population=max(0, int(e.get("population") or 0)) if str(e.get("population", "0")).isdigit() else 0,
            tags=tags, template=e.get("template") if e.get("template") in ("classicplus", "vanilla") else
            ("classicplus" if "Classic+" in tags else "vanilla"),
            verified=bool(e.get("verified")), official=bool(e.get("official")) or "official" in tags,
            relay=relay, host_id=host_id if HOST_ID_RE.match(host_id) else "",
            last_seen=int(e.get("last_seen") or 0), description=_clean(e.get("description"), 200),
            portal=_clean(e.get("portal"), 200), build=int(e.get("build") or 5875),
            version=_clean(e.get("version"), 32),
            relay_url=r_url, key=key if FP_RE.match(key) else "", e2e=bool(e.get("e2e")) and bool(FP_RE.match(key))))
        out[-1].tier = tiers.tier_of_realm(out[-1].__dict__)
        out[-1].badges = tiers.badges_for_realm(out[-1].__dict__)
    # official first, then verified, then by population
    out.sort(key=lambda r: (not r.official, not r.verified, -r.population, r.name.lower()))
    return out


def fetch(url=DIRECTORY_URL, timeout=8):
    try:
        status, data = http_json(url, timeout=timeout)
    except OSError as e:
        raise P2PError(f"The realm list can't be reached ({e}).") from None
    if status != 200 or not isinstance(data, dict):
        raise P2PError(f"The realm list answered {status}.")
    return parse(data)


def relay_ping(host_id, relay_url=RELAY_URL, timeout=4.0, clock=time.perf_counter):
    from . import ws
    try:
        sock = ws.connect(f"{relay_url}/h/{host_id}/ws/3724", timeout=timeout)
    except (OSError, ValueError):
        return None
    try:
        sock.settimeout(timeout)
        t0 = clock()
        sock.send(realmproto.logon_challenge())
        buf = b""
        while len(buf) < 3:
            m = sock.recv()
            if m is None:
                return None
            buf += m if isinstance(m, bytes) else m.encode()
        return int(round((clock() - t0) * 1000)) if realmproto.is_challenge_reply(buf) else None
    finally:
        sock.close()


def ping(realm, relay_url=RELAY_URL, timeout=3.0):
    """ms or None. Relayed realms are pinged through the relay (that's the path the game takes)."""
    if isinstance(realm, dict):
        realm = Realm(**{k: v for k, v in realm.items() if k in Realm.__dataclass_fields__})
    if realm.relay and realm.host_id:
        ms = relay_ping(realm.host_id, relay_url, timeout)
    else:
        ms = realmproto.tcp_ping(realm.host, realm.port, timeout)
    realm.ping = ms
    return ms


def ping_all(realms, workers=8, **kw):
    import concurrent.futures
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        return list(ex.map(lambda r: ping(r, **kw), realms))


def route(host_id, central=CENTRAL_URL, timeout=6, http=http_json):
    """Which relay carries a realm right now (private realms aren't listed, so invite links ask):
    GET /api/directory/route/<host_id> -> {"relay_url", "key", "e2e"}. None when unknown or offline."""
    if not HOST_ID_RE.match(host_id or ""):
        return None
    try:
        status, data = http(f"{central}/api/directory/route/{host_id}", timeout=timeout)
    except OSError:
        return None
    if status != 200 or not isinstance(data, dict):
        return None
    key = str(data.get("key") or "")
    return {"relay_url": relay_base(data.get("relay_url"), host_id), "key": key if FP_RE.match(key) else "",
            "e2e": bool(data.get("e2e")) and bool(FP_RE.match(key))}


def report(host_id, reason, token, central=CENTRAL_URL):
    """Report a realm to staff. token = the launcher's sign-in token. -> True when accepted."""
    if not HOST_ID_RE.match(host_id or ""):
        raise P2PError("That realm can't be reported.")
    reason = re.sub(r"\s+", " ", _clean(reason, 500)).strip()
    if not reason:
        raise P2PError("Say what is wrong with this realm.")
    status, data = http_json(central + "/api/directory/report", "POST", {"host_id": host_id, "reason": reason},
                             headers={"Authorization": "Bearer " + token} if token else None)
    if status == 429:
        raise P2PError("You've sent several reports already. Try again later.")
    if status in (401, 403):
        raise P2PError("Sign in to report a realm.")
    return 200 <= status < 300
