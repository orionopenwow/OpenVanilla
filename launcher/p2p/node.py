"""Become a node: this PC relays other players' encrypted game streams for community hosts.

    svc = NodeService(settings["p2p_node"], save=save_settings)
    svc.enable()                      # off -> consent (the launcher shows CONSENT_TEXT)
    svc.accept()                      # consent -> starting -> pending (blocks: run on a worker thread)
    svc.status()                      # dict for the launcher panel and the in-game window
    svc.turn_off()                    # one click, from any state: server down, port unmapped, setting off

Why a Python node and not the bundled Rust relay (relay/): the node speaks exactly the relay's wire
protocol (docs: relay/README.md), so hosts' agents (host.RelayAgent) and players' bridges
(bridge.Bridge) work against it unchanged, and it reuses p2p.ws. Shipping a second native binary
per OS means signing it, antivirus false positives and a process to babysit; in-process, "off"
really is one click and the caps are enforced right here. The load is small: 1.12 game traffic is
~5 KB/s per player, so a node's default 64 streams need well under a core. The official relay
(relay.openvanilla.app) stays Rust.

What differs from the official relay:
  * agents authenticate with a node ticket (PASETO v4.public signed by Open Vanilla's directory key,
    aud = this node, sub = the host id, 10-minute life, refreshed over the control socket), checked
    offline with the published keys; a volunteer never holds a shared secret;
  * players must ask for end-to-end encrypted streams (?e2e=1, p2p.e2e): a node never carries
    plaintext game traffic; it sees host ids, timing and byte counts, nothing else;
  * the node keeps no addresses at all: no logs, only counters;
  * caps are the volunteer's: KB/s (both directions together), GB per UTC day, hosts, streams.
    At the daily cap the node pauses (streams end, new ones get 429) until 00:00 UTC.
"""
import dataclasses
import datetime
import hashlib
import json
import os
import re
import socket
import threading
import time
import urllib.parse

import ed25519

from . import (CENTRAL_URL, CODE_RE, HOST_ID_RE, REGION, P2PError, b32, http_json, paseto, read_json, write_json,
               ws)
from . import tiers

NODE_PORT = 3728
CONSENT_VERSION = 1
NODE_VERSION = "1"
HEARTBEAT_EVERY = 60
PORTS = (3724, 8085)
TICKET_TTL_MAX = 3600
TICKET_GRACE = 120

DEFAULTS = {"enabled": False, "consent": 0, "port": NODE_PORT, "kbps": 512, "daily_gb": 10, "max_hosts": 4,
            "max_streams": 64, "upnp": False, "public_url": "", "leaderboard": "anonymous", "display_name": "",
            "region": REGION}
LEADERBOARD_CHOICES = (("off", "Don't list me (still counted in network totals)"),
                       ("anonymous", "List me as \"Anonymous node\""),
                       ("named", "List me with a display name"))


class NodeError(P2PError):
    pass


# ---------------------------------------------------------------- what the volunteer is told

CONSENT_TEXT = (
    "WHY\n"
    "Players reach community realms through relays, so nobody has to open router ports or show their "
    "home address. Every node adds connection capacity, soaks up attacks and shortens the path for "
    "players near you. It doesn't make any one world bigger: each realm still runs on its host's PC.\n\n"
    "WHAT IS SHARED\n"
    "• Only other players' game traffic, end-to-end encrypted between the player and the realm's host: "
    "your node passes sealed bytes along and can't read them.\n"
    "• Never Blizzard's game files, your WoW folder, your characters or anything else on this PC. "
    "(Seeding, a separate switch, shares only Open Vanilla's own signed downloads.)\n\n"
    "BANDWIDTH\n"
    "• Capped at {kbps} KB/s and {daily_gb} GB per day (change both below). At the daily cap the node "
    "pauses until midnight UTC. Up to {max_hosts} realms and {max_streams} connections at once.\n\n"
    "YOUR ADDRESS AND THEIRS\n"
    "• Players and hosts connect to your node, so they can see your IP address, as with seeding a torrent. "
    "They never see each other's.\n"
    "• You (the node) see the IP addresses that connect to it, which realm id each stream is for, when "
    "it starts and ends, and how many bytes flow. Not what is said or done in game. The node writes no "
    "logs; it keeps only counters.\n"
    "• The node rules: don't record addresses, don't inspect, sell or tamper with traffic. Breaking them "
    "gets a node revoked.\n\n"
    "YOUR PORT\n"
    "• The node listens on TCP {port}. The launcher can ask your router to open it (UPnP), or you "
    "forward it yourself. Behind carrier-grade NAT a home PC can't be a node; a small VPS can.\n\n"
    "TURNING IT OFF\n"
    "• One click: Host → Become a node → TURN OFF. The node also stops when the launcher closes, "
    "and it is off by default after an update until you turn it back on."
)

RULES = (
    "Node rules v1: no logging or sharing of IP addresses; no inspecting, altering, throttling by "
    "realm, or selling traffic; keep the launcher up to date; one node per person unless the "
    "maintainer agrees. Breaking a rule gets the node revoked."
)


def consent_text(cfg):
    c = dict(DEFAULTS)
    c.update(cfg or {})
    return CONSENT_TEXT.format(**{k: c[k] for k in ("kbps", "daily_gb", "max_hosts", "max_streams", "port")})


# ---------------------------------------------------------------- the state machine

STATES = ("off", "consent", "starting", "pending", "verified", "paused", "error", "stopping")
RUNNING = ("pending", "verified", "paused")
STATE_LABELS = {
    "off": "Off", "consent": "Waiting for your OK", "starting": "Starting…", "pending": "On: being checked",
    "verified": "On: verified node", "paused": "Paused: daily cap reached", "error": "Couldn't start",
    "stopping": "Turning off…",
}


class NodeMachine:
    """Pure state machine (no I/O). fire(event) -> new state; an event that doesn't apply raises."""

    TRANSITIONS = {
        ("off", "enable"): "consent",
        ("off", "resume"): "starting",
        ("consent", "accept"): "starting",
        ("consent", "decline"): "off",
        ("starting", "started"): "pending",
        ("starting", "failed"): "error",
        ("error", "retry"): "starting",
        ("pending", "approved"): "verified",
        ("verified", "suspended"): "pending",
        ("pending", "suspended"): "pending",
        ("verified", "approved"): "verified",
        ("pending", "cap_reached"): "paused",
        ("verified", "cap_reached"): "paused",
        ("stopping", "stopped"): "off",
    }

    def __init__(self, state="off", on_change=None):
        self.state = state if state in STATES else "off"
        self.before_pause = "pending"
        self.on_change = on_change or (lambda old, new, event: None)

    def can(self, event):
        try:
            self._next(event)
            return True
        except NodeError:
            return False

    def _next(self, event):
        s = self.state
        if event == "turn_off":
            if s in ("off",):
                return "off"
            if s in ("consent", "error"):
                return "off"
            return "stopping"
        if event == "new_day" and s == "paused":
            return self.before_pause
        if event in ("approved", "suspended") and s == "paused":
            self.before_pause = "verified" if event == "approved" else "pending"
            return "paused"
        nxt = self.TRANSITIONS.get((s, event))
        if nxt is None:
            raise NodeError(f"can't {event} while {s}")
        return nxt

    def fire(self, event):
        old = self.state
        new = self._next(event)
        if event == "cap_reached":
            self.before_pause = old
        self.state = new
        if new != old:
            self.on_change(old, new, event)
        return new

    @property
    def running(self):
        return self.state in RUNNING

    @property
    def enabled(self):
        """What the setting should say: on from the moment the volunteer said yes until they turn it off."""
        return self.state in ("starting", "pending", "verified", "paused", "error")


# ---------------------------------------------------------------- node tickets

class TicketError(Exception):
    pass


def verify_ticket(token, keys, node_id, host_id, now):
    """A node ticket: v4.public signed by the directory; claims typ="node", aud=node_id, sub=host_id,
    vis public|private, iat, exp (life at most an hour). -> claims."""
    if isinstance(keys, paseto.KeyCache):
        try:
            claims = paseto.verify_signature(token, keys.get())
        except paseto.TokenError:
            claims = paseto.verify_signature(token, keys.refresh(force=True))
    else:
        try:
            claims = paseto.verify_signature(token, keys)
        except paseto.TokenError as e:
            raise TicketError(str(e)) from None
    if claims.get("typ") != "node":
        raise TicketError("not a node ticket")
    if claims.get("aud") != node_id:
        raise TicketError("ticket is for another node")
    if claims.get("sub") != host_id:
        raise TicketError("ticket is for another host")
    try:
        exp, iat = paseto._ts(claims.get("exp")), paseto._ts(claims.get("iat", now))
    except paseto.TokenError as e:
        raise TicketError(str(e)) from None
    if exp < now - paseto.CLOCK_SKEW or iat > now + paseto.CLOCK_SKEW or exp - iat > TICKET_TTL_MAX:
        raise TicketError("ticket expired or has wrong times")
    if claims.get("vis", "public") not in ("public", "private"):
        raise TicketError("bad visibility")
    return claims


# ---------------------------------------------------------------- the relay node (server)

@dataclasses.dataclass
class NodeLimits:
    max_hosts: int = 4
    max_streams: int = 64
    kbps: int = 512
    daily_gb: float = 10
    stream_idle: int = 900
    ctrl_idle: int = 90
    open_timeout: int = 10

    @classmethod
    def from_cfg(cls, cfg):
        c = dict(DEFAULTS)
        c.update(cfg or {})
        return cls(max_hosts=max(1, min(int(c["max_hosts"]), 32)), max_streams=max(2, min(int(c["max_streams"]), 1024)),
                   kbps=max(32, min(int(c["kbps"]), 1_000_000)), daily_gb=max(0.5, min(float(c["daily_gb"]), 10_000)))

    def as_wire(self):
        return {"max_streams": self.max_streams, "bytes_per_sec": self.kbps * 1024,
                "daily_bytes": int(self.daily_gb * 1e9), "stream_idle_secs": self.stream_idle}


class Bucket:
    """Token bucket over both directions together; burst = one second."""

    def __init__(self, rate, clock=time.monotonic, sleep=time.sleep):
        self.rate, self.clock, self.sleep = float(rate), clock, sleep
        self.tokens, self.t = float(rate), clock()
        self.lock = threading.Lock()

    def take(self, n):
        while True:
            with self.lock:
                now = self.clock()
                self.tokens = min(self.rate, self.tokens + (now - self.t) * self.rate)
                self.t = now
                if self.tokens >= min(n, self.rate):
                    self.tokens -= n
                    return
                wait = (min(n, self.rate) - self.tokens) / self.rate
            self.sleep(min(wait, 0.5))


class _Host:
    def __init__(self, ctrl, vis, exp):
        self.ctrl, self.vis, self.exp = ctrl, vis, exp
        self.lock = threading.Lock()
        self.pending = {}     # sid -> [Event, ws or None]
        self.invites = {}     # sid -> [Event, bool]
        self.streams = {}     # sid -> (player ws, agent ws)

    def send(self, obj):
        try:
            self.ctrl.send(json.dumps(obj, separators=(",", ":")))
            return True
        except OSError:
            return False


def utc_day(t):
    return datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%d")


class RelayNode:
    """The relay protocol (relay/README.md) in Python, for volunteers. require_e2e is always on for
    volunteers; tests may switch it off to check the refusal."""

    def __init__(self, node_id, keys, bind=("0.0.0.0", NODE_PORT), limits=None, clock=time.time, node_key=None,
                 tap=None, require_e2e=True, on_cap=None):
        self.node_id, self.keys, self.bind = node_id, keys, bind
        self.limits = limits or NodeLimits()
        self.clock, self.node_key, self.tap = clock, node_key, tap
        self.require_e2e = require_e2e
        self.on_cap = on_cap or (lambda: None)
        self.hosts = {}
        self.lock = threading.Lock()
        self.srv = None
        self.port = None
        self.stopped = threading.Event()
        self.paused = False
        self.bucket = Bucket(self.limits.kbps * 1024)
        self._sid = 0
        t = clock()
        self.counters = {"started": int(t), "day": utc_day(t), "bytes_today": 0, "bytes_total": 0,
                         "streams_total": 0, "refused": {"offline": 0, "limit": 0, "daily": 0, "invite": 0,
                                                         "timeout": 0, "e2e": 0, "auth": 0}}

    # -- lifecycle
    def start(self):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind(self.bind)
        except OSError as e:
            s.close()
            raise NodeError(f"Port {self.bind[1]} is in use or not allowed ({e}). Pick another port.") from None
        s.listen(128)
        self.srv, self.port = s, s.getsockname()[1]
        threading.Thread(target=self._accept, daemon=True, name="node-accept").start()
        return self.port

    def stop(self):
        self.stopped.set()
        if self.srv:
            try:
                self.srv.shutdown(socket.SHUT_RDWR)   # wakes the blocked accept() and frees the port
            except OSError:
                pass
            try:
                self.srv.close()
            except OSError:
                pass
        with self.lock:
            hosts = list(self.hosts.values())
            self.hosts.clear()
        for h in hosts:
            self._drop_host(h)

    def _drop_host(self, h):
        with h.lock:
            streams = list(h.streams.values())
            h.streams.clear()
            for slot in list(h.pending.values()) + list(h.invites.values()):
                slot[0].set()
        for p, a in streams:
            p.close()
            a.close()
        h.ctrl.close()

    def pause(self, on=True):
        self.paused = on
        if on:
            with self.lock:
                hosts = list(self.hosts.values())
            for h in hosts:
                with h.lock:
                    streams = list(h.streams.values())
                for p, a in streams:
                    p.close()
                    a.close()

    # -- counters
    def _roll_day(self):
        d = utc_day(self.clock())
        if d != self.counters["day"]:
            self.counters["day"], self.counters["bytes_today"] = d, 0
            if self.paused:
                self.paused = False
                return True
        return False

    def _count(self, n):
        self.counters["bytes_today"] += n
        self.counters["bytes_total"] += n
        if not self.paused and self.counters["bytes_today"] >= self.limits.daily_gb * 1e9:
            self.paused = True
            threading.Thread(target=self._cap_hit, daemon=True).start()

    def _cap_hit(self):
        self.pause(True)
        self.on_cap()

    def stats(self):
        new_day = self._roll_day()
        with self.lock:
            carrying = sorted(self.hosts)
            streams = sum(len(h.streams) for h in self.hosts.values())
        out = dict(self.counters)
        out["refused"] = dict(self.counters["refused"])
        out.update(hosts_now=len(carrying), carrying=carrying, streams_now=streams, paused=self.paused, new_day=new_day,
                   uptime_secs=int(self.clock() - self.counters["started"]))
        return out

    # -- HTTP
    def _accept(self):
        while not self.stopped.is_set():
            try:
                conn, _addr = self.srv.accept()   # the address is never stored or logged
            except OSError:
                return
            threading.Thread(target=self._conn, args=(conn,), daemon=True).start()

    @staticmethod
    def _reply(sock, status, body=b"", ctype="text/plain"):
        reason = {200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                  429: "Too Many Requests", 502: "Bad Gateway", 503: "Service Unavailable"}.get(status, "Error")
        if isinstance(body, str):
            body = body.encode()
        try:
            sock.sendall(f"HTTP/1.1 {status} {reason}\r\nContent-Type: {ctype}\r\nContent-Length: {len(body)}\r\n"
                         f"Cache-Control: no-store\r\nConnection: close\r\n\r\n".encode() + body)
        except OSError:
            pass
        try:
            sock.close()
        except OSError:
            pass

    @staticmethod
    def _upgrade(sock, headers, rest):
        key = headers.get("sec-websocket-key", "")
        sock.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                      f"Sec-WebSocket-Accept: {ws.accept_key(key)}\r\n\r\n").encode("latin-1"))
        sock.settimeout(None)
        return ws.WebSocket(sock, client=False, leftover=rest)

    def _conn(self, sock):
        try:
            sock.settimeout(10)
            line, headers, rest = ws._read_http_head(sock)
        except OSError:
            sock.close()
            return
        parts = line.split(" ")
        if len(parts) < 2 or parts[0] != "GET":
            return self._reply(sock, 400)
        u = urllib.parse.urlsplit(parts[1])
        q = dict(urllib.parse.parse_qsl(u.query))
        path = u.path
        is_ws = headers.get("upgrade", "").lower() == "websocket"
        try:
            if path == "/healthz":
                return self._reply(sock, 200, "ok")
            if path == "/node":
                return self._info(sock, q.get("c", ""))
            if not is_ws:
                return self._reply(sock, 404)
            if path == "/agent":
                return self._agent(sock, headers, rest)
            m = re.fullmatch(r"/agent/stream/([A-Za-z0-9_-]{1,64})", path)
            if m:
                return self._agent_stream(sock, headers, rest, m.group(1))
            m = re.fullmatch(r"/h/([a-z2-7]{16})/ws/(\d{1,5})", path)
            if m:
                return self._player(sock, rest, headers, m.group(1), int(m.group(2)), q)
            return self._reply(sock, 404)
        except OSError:
            try:
                sock.close()
            except OSError:
                pass

    def _info(self, sock, challenge):
        c = re.sub(r"[^0-9a-f]", "", challenge.lower())[:64]
        body = {"node_id": self.node_id, "version": NODE_VERSION, "protocol": tiers.NODE_PROTOCOL,
                "e2e_required": self.require_e2e, "limits": self.limits.as_wire(), "paused": self.paused}
        if self.node_key and c:
            body["key"] = ed25519.public_key(self.node_key).hex()
            body["sig"] = ed25519.sign(self.node_key, info_message(self.node_id, c)).hex()
        return self._reply(sock, 200, json.dumps(body), "application/json")

    def _auth(self, headers):
        host_id = headers.get("x-host-id", "")
        auth = headers.get("authorization", "")
        if not HOST_ID_RE.match(host_id) or not auth.lower().startswith("bearer "):
            return None, None
        try:
            claims = verify_ticket(auth[7:].strip(), self.keys, self.node_id, host_id, self.clock())
        except (TicketError, paseto.TokenError):
            return None, None
        return host_id, claims

    # -- agent control socket
    def _agent(self, sock, headers, rest):
        host_id, claims = self._auth(headers)
        if not host_id:
            self.counters["refused"]["auth"] += 1
            return self._reply(sock, 401, "bad node ticket")
        with self.lock:
            if host_id not in self.hosts and len(self.hosts) >= self.limits.max_hosts:
                return self._reply(sock, 503, "node is full")
        c = self._upgrade(sock, headers, rest)
        h = _Host(c, claims.get("vis", "public"), paseto._ts(claims["exp"]))
        with self.lock:
            old = self.hosts.get(host_id)
            self.hosts[host_id] = h
        if old:
            self._drop_host(old)
        h.send({"limits": self.limits.as_wire()})
        c.settimeout(self.limits.ctrl_idle)
        try:
            while not self.stopped.is_set():
                msg = c.recv()
                if msg is None or isinstance(msg, bytes):
                    if msg is None:
                        break
                    continue
                if self.clock() > h.exp + TICKET_GRACE:
                    break                       # no fresh ticket: the directory no longer vouches for it
                try:
                    m = json.loads(msg)
                except ValueError:
                    continue
                if not isinstance(m, dict):
                    continue
                if "ping" in m:
                    h.send({"pong": m["ping"]})
                if "ticket" in m:
                    try:
                        cl = verify_ticket(str(m["ticket"]), self.keys, self.node_id, host_id, self.clock())
                        h.exp, h.vis = paseto._ts(cl["exp"]), cl.get("vis", "public")
                    except (TicketError, paseto.TokenError):
                        break
                if "close" in m:
                    with h.lock:
                        pair = h.streams.pop(str(m["close"]), None)
                        slot = h.pending.get(str(m["close"]))
                    if pair:
                        pair[0].close()
                        pair[1].close()
                    if slot:
                        slot[0].set()
                for k, ok in (("invite_ok", True), ("invite_no", False)):
                    if k in m:
                        with h.lock:
                            slot = h.invites.get(str(m[k]))
                        if slot:
                            slot[1] = ok
                            slot[0].set()
        finally:
            with self.lock:
                if self.hosts.get(host_id) is h:
                    del self.hosts[host_id]
            self._drop_host(h)

    def _agent_stream(self, sock, headers, rest, sid):
        host_id, _ = self._auth(headers)
        if not host_id:
            self.counters["refused"]["auth"] += 1
            return self._reply(sock, 401)
        with self.lock:
            h = self.hosts.get(host_id)
        if not h:
            return self._reply(sock, 404)
        with h.lock:
            slot = h.pending.get(sid)
        if not slot or slot[1] is not None:
            return self._reply(sock, 404)
        slot[1] = self._upgrade(sock, headers, rest)
        slot[0].set()

    # -- players
    def _player(self, sock, rest, headers, host_id, port, q):
        ref = self.counters["refused"]
        if port not in PORTS:
            return self._reply(sock, 404)
        if self.require_e2e and q.get("e2e") != "1":
            ref["e2e"] += 1
            return self._reply(sock, 400, "this node carries end-to-end encrypted streams only")
        with self.lock:
            h = self.hosts.get(host_id)
        if not h:
            ref["offline"] += 1
            return self._reply(sock, 404, "host offline")
        self._roll_day()
        if self.paused:
            ref["daily"] += 1
            return self._reply(sock, 429, "node daily cap reached")
        with self.lock:
            busy = sum(len(x.streams) + len(x.pending) for x in self.hosts.values())
            self._sid += 1
            sid = str(self._sid)
        if busy >= self.limits.max_streams:
            ref["limit"] += 1
            return self._reply(sock, 503, "node stream limit reached")
        wait = self.limits.open_timeout
        if h.vis == "private":
            code = (q.get("invite") or "").upper()
            if not CODE_RE.match(code):
                ref["invite"] += 1
                return self._reply(sock, 403, "invite required")
            slot = [threading.Event(), False]
            with h.lock:
                h.invites[sid] = slot
            h.send({"invite_check": code, "stream": int(sid)})
            slot[0].wait(wait)
            with h.lock:
                h.invites.pop(sid, None)
            if not slot[1]:
                ref["invite"] += 1
                return self._reply(sock, 403, "invite refused")
        slot = [threading.Event(), None]
        with h.lock:
            h.pending[sid] = slot
        h.send({"open": int(sid), "port": port, "e2e": 1})
        slot[0].wait(wait)
        with h.lock:
            h.pending.pop(sid, None)
            agent = slot[1]
        if agent is None:
            ref["timeout"] += 1
            return self._reply(sock, 502, "host did not answer")
        try:
            player = self._upgrade(sock, headers, rest)
        except OSError:
            agent.close()
            return
        self.counters["streams_total"] += 1
        with h.lock:
            h.streams[sid] = (player, agent)
        try:
            self._pipe(player, agent)
        finally:
            with h.lock:
                h.streams.pop(sid, None)
            h.send({"close": int(sid)})

    def _pipe(self, player, agent):
        idle = self.limits.stream_idle
        player.settimeout(idle)
        agent.settimeout(idle)
        done = threading.Event()

        def one(src, dst, direction):
            try:
                while not done.is_set() and not self.paused:
                    m = src.recv()
                    if m is None:
                        break
                    if isinstance(m, str):
                        m = m.encode()
                    self.bucket.take(len(m))
                    if self.tap:
                        self.tap(direction, m)
                    dst.send(m)
                    self._count(len(m))
            except OSError:
                pass
            finally:
                done.set()
                src.close()
                dst.close()

        t = threading.Thread(target=one, args=(agent, player, "to_player"), daemon=True)
        t.start()
        one(player, agent, "to_host")
        t.join(timeout=5)


def info_message(node_id, challenge_hex):
    return ("OWNODE1|" + node_id + "|" + challenge_hex).encode("ascii")


def node_id_for(pub):
    """A node's id is its key's fingerprint: self-certifying, no central allocation needed."""
    return b32(hashlib.sha256(pub).digest()[:10])


# ---------------------------------------------------------------- the service (what the launcher drives)

def _brand_dir(base):
    """base\\OpenVanilla, or the older folder with the old name when it (from before the rename) already exists."""
    old = os.path.join(base, "OpenWoW")
    return old if os.path.isdir(old) else os.path.join(base, "OpenVanilla")


def default_state_dir():
    base = os.environ.get("APPDATA") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(_brand_dir(base), "node")


class NodeService:
    def __init__(self, cfg, save=None, *, central=CENTRAL_URL, http=http_json, mapper=None, keys=None,
                 state_dir=None, clock=time.time, server_factory=RelayNode, torrents=None, on_status=None,
                 relay_enabled=True, bind_host="0.0.0.0", firewall_run=None):
        for k, v in DEFAULTS.items():
            cfg.setdefault(k, v)
        self.cfg, self.save = cfg, save or (lambda: None)
        self.central, self.http, self.clock = central.rstrip("/"), http, clock
        self.mapper = mapper
        self.keys = keys if keys is not None else paseto.KeyCache(self.central + "/.well-known/openvanilla-keys.json")
        self.state_dir = state_dir or default_state_dir()
        self.server_factory, self.torrents = server_factory, torrents
        self.on_status = on_status or (lambda st: None)
        self.relay_enabled = relay_enabled          # live.json flags.nodes: the test round is open
        self.bind_host = bind_host
        self.firewall_run = firewall_run
        self.machine = NodeMachine("off", on_change=self._changed)
        self.server = None
        self.public_url = None
        self.verification = {"status": "unlisted", "checks": {}, "message": ""}
        self.last_error = None
        self.last_heartbeat = None
        self.stopped = threading.Event()
        self._thread = None
        self.mapped = False

    # -- identity
    def node_key(self):
        path = os.path.join(self.state_dir, "node_key.seed")
        try:
            with open(path) as f:
                seed = bytes.fromhex(f.read().strip())
            if len(seed) == 32:
                return seed
        except (OSError, ValueError):
            pass
        seed = os.urandom(32)
        os.makedirs(self.state_dir, exist_ok=True)
        with open(path, "w") as f:
            f.write(seed.hex())
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
        return seed

    @property
    def node_id(self):
        if getattr(self, "_node_id", None) is None:
            self._node_id = node_id_for(ed25519.public_key(self.node_key()))
        return self._node_id

    def _token_path(self):
        return os.path.join(self.state_dir, "node.json")

    # -- state
    def _changed(self, old, new, event):
        self.cfg["enabled"] = self.machine.enabled
        self.save()
        self.on_status(self.status())

    def enable(self):
        """The volunteer clicked Become a node: show CONSENT_TEXT next."""
        if not self.relay_enabled:
            raise NodeError("The node network isn't open yet: the test round starts with Open Vanilla's own relay. "
                            "Watch the news on the Home page.")
        if self.machine.state == "off":
            self.machine.fire("enable")
        return consent_text(self.cfg)

    def decline(self):
        if self.machine.state == "consent":
            self.machine.fire("decline")

    def accept(self):
        if self.machine.state == "consent":
            self.cfg["consent"] = CONSENT_VERSION
            self.machine.fire("accept")
        elif self.machine.state == "error":
            self.machine.fire("retry")
        else:
            raise NodeError("Click Become a node first.")
        return self._start()

    def resume(self):
        """At launcher start: carry on if the volunteer had it on and agreed to the current text."""
        if not (self.cfg.get("enabled") and int(self.cfg.get("consent") or 0) >= CONSENT_VERSION and self.relay_enabled):
            if self.cfg.get("enabled") and int(self.cfg.get("consent") or 0) < CONSENT_VERSION:
                self.cfg["enabled"] = False      # the explanation changed: ask again
                self.save()
            return False
        self.machine.fire("resume")
        return self._start()

    def _start(self):
        limits = NodeLimits.from_cfg(self.cfg)
        port = int(self.cfg["port"]) if self.cfg.get("port") is not None else NODE_PORT
        try:
            self.server = self.server_factory(self.node_id, self.keys, bind=(self.bind_host, port), limits=limits,
                                              clock=self.clock, node_key=self.node_key(), on_cap=self._cap)
            port = self.server.start()
            self.public_url = self._reach(port)
        except (NodeError, OSError) as e:
            if self.server:
                self.server.stop()
                self.server = None
            self.last_error = str(e)
            self.machine.fire("failed")
            return False
        self.machine.fire("started")
        self.stopped.clear()
        self.heartbeat()
        self._thread = threading.Thread(target=self._loop, daemon=True, name="node-heartbeat")
        self._thread.start()
        return True

    def _reach(self, port):
        url = str(self.cfg.get("public_url") or "").strip()
        if url:
            u = urllib.parse.urlsplit(url)
            if u.scheme not in ("ws", "wss") or not u.hostname:
                raise NodeError("The public address must look like wss://node.example.org or ws://203.0.113.5:3728.")
            return url.rstrip("/")
        if self.cfg.get("upnp") and self.mapper is not None:
            method, ext = self.mapper.map([port])
            if method and ext:
                self.mapped = True
                if self.firewall_run:
                    from . import firewall
                    firewall.add_rules([port], self.firewall_run)
                return f"ws://{ext}:{port}"
            raise NodeError("Your router didn't open the node port (UPnP / NAT-PMP is off or missing). Forward TCP "
                            f"{port} yourself and enter your public address, or run the node on a VPS.")
        raise NodeError(f"Tell the launcher how players reach this node: tick 'Ask my router' or enter the public "
                        f"address you forwarded TCP {port} to.")

    def _cap(self):
        if self.machine.state in ("pending", "verified"):
            self.machine.fire("cap_reached")

    def _loop(self):
        while not self.stopped.wait(HEARTBEAT_EVERY):
            self.tick()

    def tick(self):
        st = self.server.stats() if self.server else {}
        if st.get("new_day") and self.machine.state == "paused":
            self.machine.fire("new_day")
        self.heartbeat()

    # -- central
    def heartbeat_payload(self):
        st = self.server.stats() if self.server else {}
        seed_total = 0
        if self.torrents is not None:
            try:
                tst = self.torrents.status() or {}
                if tst.get("seeding_enabled"):
                    seed_total = int(tst.get("uploaded_total") or 0)
            except Exception:
                seed_total = 0
        lb = self.cfg.get("leaderboard") if self.cfg.get("leaderboard") in dict(LEADERBOARD_CHOICES) else "anonymous"
        name = clean_display_name(self.cfg.get("display_name")) if lb == "named" else ""
        return {"node_id": self.node_id, "key": ed25519.public_key(self.node_key()).hex(), "url": self.public_url,
                "region": str(self.cfg.get("region") or REGION)[:8], "version": NODE_VERSION,
                "protocol": tiers.NODE_PROTOCOL, "rules": tiers.NODE_RULES_VERSION, "e2e_required": True,
                "caps": {"kbps": int(self.cfg["kbps"]), "daily_gb": float(self.cfg["daily_gb"]),
                         "max_hosts": int(self.cfg["max_hosts"]), "max_streams": int(self.cfg["max_streams"])},
                "state": "paused" if self.machine.state == "paused" else "running",
                "accepting": self.machine.state in ("pending", "verified"),
                "stats": {"relay_bytes_today": int(st.get("bytes_today") or 0),
                          "relay_bytes_total": int(st.get("bytes_total") or 0),
                          "streams_total": int(st.get("streams_total") or 0),
                          "streams_now": int(st.get("streams_now") or 0), "hosts_now": int(st.get("hosts_now") or 0),
                          "uptime_secs": int(st.get("uptime_secs") or 0), "seed_bytes_total": seed_total},
                "leaderboard": lb, "display_name": name,
                # host ids this node carries now: the directory counts them as reachable (no addresses)
                "carrying": list(st.get("carrying") or [])[:32]}

    def heartbeat(self):
        saved = read_json(self._token_path(), {}) or {}
        headers = {"Authorization": "Bearer " + saved["token"]} if saved.get("token") else {}
        try:
            status, data = self.http(self.central + "/api/nodes/heartbeat", "POST", self.heartbeat_payload(), headers)
        except OSError as e:
            self.last_error = f"Open Vanilla can't be reached ({e}). The node keeps relaying for realms it already carries."
            self.on_status(self.status())
            return False
        data = data if isinstance(data, dict) else {}
        if status in (200, 201):
            if data.get("token"):
                saved["token"] = data["token"]
                write_json(self._token_path(), saved)
            self.last_heartbeat = self.clock()
            self.last_error = None
            self._apply_verification(data)
            self.on_status(self.status())
            return True
        if status == 403 and headers:
            write_json(self._token_path(), {})
        self.last_error = f"Open Vanilla answered {status}: {data.get('error', '')}".strip()
        self.on_status(self.status())
        return False

    def _apply_verification(self, data):
        status = data.get("status") if data.get("status") in tiers.NODE_STATUSES else "pending"
        self.verification = {"status": status, "checks": data.get("checks") or {},
                             "message": str(data.get("message") or "")[:300]}
        if status == "revoked":
            self.last_error = "The maintainer revoked this node" + (f": {self.verification['message']}"
                                                                     if self.verification["message"] else ".")
            threading.Thread(target=self.turn_off, daemon=True).start()
            return
        if status == "verified" and self.machine.can("approved"):
            self.machine.fire("approved")
        elif status in ("pending", "suspended", "unlisted") and self.machine.state in ("verified", "paused"):
            self.machine.fire("suspended")

    # -- off
    def turn_off(self):
        """One click, from any state. Always ends with the node off and the setting off."""
        if self.machine.state in ("off", "consent", "error"):
            self.machine.fire("turn_off")
            self.cfg["enabled"] = False
            self.save()
            return
        if self.machine.state != "stopping":
            self.machine.fire("turn_off")
        self.stopped.set()
        if self.server:
            self.server.stop()
            self.server = None
        if self.mapped and self.mapper is not None:
            try:
                self.mapper.unmap()
            except OSError:
                pass
            self.mapped = False
        if self.firewall_run:
            try:
                from . import firewall
                firewall.remove_rules([int(self.cfg.get("port") or NODE_PORT)], self.firewall_run)
            except Exception:
                pass
        self.public_url = None
        if self.machine.state == "stopping":
            self.machine.fire("stopped")
        self.cfg["enabled"] = False
        self.save()

    # -- status
    def status(self):
        st = self.server.stats() if self.server else {}
        s = self.machine.state
        return {"state": s, "label": STATE_LABELS.get(s, s), "on": self.machine.running,
                "verified": s == "verified" or (s == "paused" and self.machine.before_pause == "verified"),
                "verification": self.verification.get("status"), "checks": self.verification.get("checks") or {},
                "message": self.verification.get("message") or "", "error": self.last_error,
                "node_id": self.node_id if s != "off" else None, "relayed_today": int(st.get("bytes_today") or 0),
                "relayed_total": int(st.get("bytes_total") or 0), "streams_now": int(st.get("streams_now") or 0),
                "hosts_now": int(st.get("hosts_now") or 0), "kbps": int(self.cfg["kbps"]),
                "daily_gb": float(self.cfg["daily_gb"]), "port": int(self.cfg["port"]),
                "leaderboard": self.cfg.get("leaderboard"), "updated": int(self.clock())}


def clean_display_name(name):
    name = re.sub(r"\s+", " ", "".join(ch for ch in str(name or "") if ch.isprintable())).strip()[:24]
    return name if len(name) >= 3 else ""


# ---------------------------------------------------------------- the in-game window's status file

GAME_ADDON = "Node"
GAME_STATUS_FILE = "Status.lua"


def _lua_str(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ").replace("\r", " ")[:200] + '"'


def game_status_lua(status, now=None):
    """Lua 5.0 source the Node addon loads (Status.lua is in its .toc). The game can't ask the launcher
    anything while it runs, so this is a snapshot: the window says when it was taken."""
    t = int(now if now is not None else status.get("updated") or time.time())
    when = datetime.datetime.fromtimestamp(t, datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    st = status.get("state") or "off"
    fields = [("state", _lua_str(st)), ("label", _lua_str(status.get("label") or STATE_LABELS.get(st, st))),
              ("on", "true" if status.get("on") else "false"), ("verified", "true" if status.get("verified") else "false"),
              ("relayed_today_mb", str(int(int(status.get("relayed_today") or 0) / 1e6))),
              ("relayed_total_mb", str(int(int(status.get("relayed_total") or 0) / 1e6))),
              ("daily_gb", str(float(status.get("daily_gb") or 0))), ("kbps", str(int(status.get("kbps") or 0))),
              ("hosts", str(int(status.get("hosts_now") or 0))), ("updated", _lua_str(when)), ("source", '"launcher"')]
    body = ",\n".join(f"    {k} = {v}" for k, v in fields)
    return ("-- Written by the Open Vanilla launcher (launcher/p2p/node.py) when the node changes state.\n"
            "-- A snapshot for the Become a Node window; the game can't switch the node itself.\n"
            "OpenVanillaNode_Status = {\n" + body + ",\n}\n")


def write_game_status(addons_dirs, status):
    """Write <addons>/Node/Status.lua in each folder that has the Node addon. -> paths written."""
    out = []
    src = game_status_lua(status)
    for d in addons_dirs:
        if not d:
            continue
        folder = os.path.join(d, GAME_ADDON)
        if not os.path.isfile(os.path.join(folder, GAME_ADDON + ".toc")):
            continue
        path = os.path.join(folder, GAME_STATUS_FILE)
        try:
            with open(path + ".tmp", "w", encoding="utf-8", newline="\n") as f:
                f.write(src)
            os.replace(path + ".tmp", path)
            out.append(path)
        except OSError:
            pass
    return out
