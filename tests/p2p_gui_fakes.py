"""A fake `p2p` package for the launcher's GUI tests (tests/test_p2p_gui.py; the real one is launcher/p2p/).

It has the launcher-facing API of launcher/p2p — p2p.directory (fetch, ping, Realm), p2p.host
(HostConfig, HostSession), p2p.join (join(target, game_launcher, *, launcher_token) with
game_launcher(env, realmlist)), p2p.torrent (Torrents) — and records every call in CALLS so tests
can check what the UI did. Nothing touches the network or the disk.
"""
import dataclasses
import sys
import types

CALLS = []
_SAVED = {}  # the real launcher/p2p modules other tests imported, put back by uninstall()


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
    ping: object = None
    description: str = ""


REALMS = [
    Realm("Stormwind Nights", "relay.openvanilla.app", type="rp", population=12, tags=["EU"], verified=True,
          relay=True, host_id="aaaaaaaaaaaaaaaa", description="A friendly RP realm."),
    Realm("Vanilla Reloaded", "play.openvanilla.app", type="pve", population=230, official=True, verified=True,
          host_id="oooooooooooooooo", description="The official Open Vanilla realm."),
    Realm("Bob's Basement", "203.0.113.7", type="pvp", population=3, template="vanilla",
          host_id="bbbbbbbbbbbbbbbb"),
]


def install():
    """Register the fake package in sys.modules (so `importlib.import_module("p2p.x")` finds it)."""
    _SAVED.clear()
    for k in [k for k in sys.modules if k == "p2p" or k.startswith("p2p.")]:
        _SAVED[k] = sys.modules.pop(k)
    CALLS.clear()
    pkg = types.ModuleType("p2p")
    pkg.__path__ = []
    d = types.ModuleType("p2p.directory")
    d.Realm = Realm

    def fetch(url):
        CALLS.append(("fetch", url))
        return [dataclasses.replace(r) for r in REALMS]

    d.fetch = fetch
    d.ping = lambda realm: {"aaaaaaaaaaaaaaaa": 48, "oooooooooooooooo": 31}.get(realm.host_id)

    h = types.ModuleType("p2p.host")

    @dataclasses.dataclass
    class HostConfig:
        name: str
        type: str = "pve"
        template: str = "classicplus"
        max_players: int = 20
        bots: int = 40
        visibility: str = "private"
        data_dir: str = None
        upnp_consent: bool = False
        firewall: bool = True
        connection: str = "relay"     # relay | direct | lan

    class HostSession:
        last = None

        def __init__(self, cfg, progress_cb=None):
            self.cfg, self.progress_cb = cfg, progress_cb
            self.running = False
            self.names = ["Arthas", "Jaina"]
            HostSession.last = self

        def start(self):
            CALLS.append(("start", self.cfg.name))
            if self.progress_cb:
                self.progress_cb("start", "Starting the world server…")
            self.running = True

        def stop(self):
            CALLS.append(("stop",))
            self.running = False

        def status(self):
            c = self.cfg.connection
            return {"running": self.running, "players": len(self.names), "cpu": 12.5, "ram": 820, "up_kbps": 40,
                    "down_kbps": 6, "reachability": "relay" if c == "relay" else "direct",
                    "listed": self.cfg.visibility == "public", "max_players": self.cfg.max_players,
                    "connection": c, "external_ip": "198.51.100.23" if c == "direct" else None,
                    "lan_ip": "192.168.1.20", "exposed_ports": [] if c == "relay" else [3724, 8085],
                    "fingerprint": self.fingerprint()}

        def fingerprint(self):
            return "k7q2-m4xa-90zz"

        def guest_invite(self, uses=1, hours=24, address=None):
            CALLS.append(("guest_invite", uses, hours))
            if self.cfg.connection == "relay":
                return "openvanilla://join/cccccccccccccccc?g=GUESTCODE2&k=k7q2m4xa90zz"
            return f"openvanilla://join/{self.cfg.connection}/198.51.100.23:3724?g=GUESTCODE2&n=Test&k=k7q2m4xa90zz"

        def create_account(self, name, password):
            CALLS.append(("create_account", name, password))
            return {"user": name.upper(), "password": password.upper(), "realm": self.cfg.name,
                    "realmlist": None if self.cfg.connection == "relay" else "198.51.100.23"}

        def invite(self, uses=1, hours=24):
            CALLS.append(("invite", uses, hours))
            return "openvanilla://join/cccccccccccccccc?i=ABCDEFGHJK&n=Test%20Realm"

        def kick(self, name):
            CALLS.append(("kick", name))
            self.names.remove(name)

        def ban(self, name, reason="Banned by the host"):
            CALLS.append(("ban", name))
            self.names.remove(name)

        def announce(self, text):
            CALLS.append(("announce", text))

        def backup(self):
            CALLS.append(("backup",))
            return "backup.sql.gz"

    h.HostConfig, h.HostSession = HostConfig, HostSession

    j = types.ModuleType("p2p.join")

    def join(target, game_launcher, *, launcher_token=None, guest=None, username=None, password=None):
        CALLS.append(("join", target if isinstance(target, str) else target.name, launcher_token))
        if guest or username:
            CALLS.append(("join_extra", guest, username, password))
        if isinstance(target, str) and "changed.example" in target:
            raise Exception("This realm's host key changed since you last played there. If the host reinstalled, "
                            "ask them for a new invite link; otherwise someone may be pretending to be the host.")
        env = {"WOW_HOST": "127.0.0.1:40123", "WOW_USER": "OWABCDEF", "WOW_PASS": "secret", "WOW_REALM": "Test"}
        proc = game_launcher(env, env["WOW_HOST"])
        return types.SimpleNamespace(process=proc, creds={"user": "OWABCDEF", "password": "secret"},
                                     stop=lambda: CALLS.append(("join_stop",)))

    j.join = join

    t = types.ModuleType("p2p.torrent")

    class Torrents:
        def __init__(self, state_dir, settings=None):
            self.state_dir, self.settings = state_dir, settings
            self.seeding_enabled = False
            CALLS.append(("torrents", state_dir))

        def enable_seeding(self, upload_kbps=256):
            CALLS.append(("enable_seeding", upload_kbps))
            self.seeding_enabled = True

        def disable_seeding(self):
            CALLS.append(("disable_seeding",))
            self.seeding_enabled = False

        def download(self, manifest_url, dest, progress_cb=None):
            return dest

        def status(self):
            return {"backend": "http", "down_kbps": 900, "up_kbps": 0,
                    "torrents": [{"name": "Open Vanilla client 1.15.0", "progress": 0.42, "peers": 4, "seeding": False},
                                 {"name": "patch-Z.mpq", "progress": 1.0, "peers": 2, "seeding": True}]}

    t.Torrents = Torrents
    n, lb = _node_modules()
    for name, mod in (("directory", d), ("host", h), ("join", j), ("torrent", t), ("node", n), ("leaderboard", lb)):
        setattr(pkg, name, mod)
        sys.modules["p2p." + name] = mod
    sys.modules["p2p"] = pkg
    return pkg


def _node_modules():
    """p2p.node (Become a node) and p2p.leaderboard, with the launcher-facing API only."""
    n = types.ModuleType("p2p.node")
    n.LEADERBOARD_CHOICES = (("off", "Don't list me"), ("anonymous", "List me as \"Anonymous node\""),
                             ("named", "List me with a display name"))
    n.RULES = "Node rules v1: no logging of addresses."
    n.consent_text = lambda cfg: (f"WHAT IS SHARED: only end-to-end encrypted game traffic, never Blizzard's game files. "
                                  f"Capped at {cfg.get('kbps')} KB/s and {cfg.get('daily_gb')} GB per day. "
                                  "Players can see your IP address. One click: Host > Become a node > TURN OFF.")

    class NodeError(Exception):
        pass
    n.NodeError = NodeError
    n.write_game_status = lambda dirs, st: CALLS.append(("node_game_status", st.get("state")))

    class NodeService:
        last = None

        def __init__(self, cfg, save=None, relay_enabled=False, torrents=None, mapper=None, on_status=None, **kw):
            for k, v in {"enabled": False, "kbps": 512, "daily_gb": 10, "port": 3728, "upnp": False, "public_url": "",
                         "leaderboard": "anonymous", "display_name": ""}.items():
                cfg.setdefault(k, v)
            self.cfg, self.save, self.relay_enabled = cfg, save or (lambda: None), relay_enabled
            self.on_status = on_status or (lambda st: None)
            self.machine = types.SimpleNamespace(state="off", running=False)
            NodeService.last = self

        def _set(self, state):
            self.machine.state, self.machine.running = state, state in ("pending", "verified", "paused")
            self.cfg["enabled"] = self.machine.running
            self.on_status(self.status())

        def status(self):
            s = self.machine.state
            return {"state": s, "label": {"off": "Off", "pending": "On: being checked"}.get(s, s),
                    "on": self.machine.running, "verified": False, "error": None, "relayed_today": 0,
                    "relayed_total": 0, "hosts_now": 0, "streams_now": 0, "kbps": self.cfg["kbps"],
                    "daily_gb": self.cfg["daily_gb"], "checks": {}, "message": ""}

        def enable(self):
            if not self.relay_enabled:
                raise NodeError("The node network isn't open yet: the test round starts with Open Vanilla's own relay.")
            self.machine.state = "consent"
            return n.consent_text(self.cfg)

        def decline(self):
            self.machine.state = "off"

        def accept(self):
            CALLS.append(("node_accept", dict(self.cfg)))
            self._set("pending")
            return True

        def resume(self):
            CALLS.append(("node_resume",))
            return False

        def turn_off(self):
            CALLS.append(("node_turn_off",))
            self._set("off")
    n.NodeService = NodeService

    lb = types.ModuleType("p2p.leaderboard")
    lb.parse = lambda data: [dict(r, badges=list(r.get("badges") or [])) for r in (data or {}).get("supporters") or []]
    return n, lb


def uninstall():
    for k in [k for k in sys.modules if k == "p2p" or k.startswith("p2p.")]:
        del sys.modules[k]
    sys.modules.update(_SAVED)
    _SAVED.clear()
