"""Open Vanilla player network (P2P): the launcher side of docs/P2P_NETWORK.md.

    p2p.directory   the live realm list and realmd pings
    p2p.host        HostSession: run a realm from this PC (Solo pack + agent)
    p2p.join        join a community realm (token, bridge, client)
    p2p.bridge      local TCP <-> relay WebSocket tunnel for the desktop client
    p2p.torrent     Torrents: our own downloads over BitTorrent (opt-in seeding) or plain HTTP
    p2p.invites     invite codes and links
    p2p.upnp        UPnP-IGD / NAT-PMP port mapping (with consent)
    p2p.paseto      PASETO v4.public identity tokens, key cache, revocation list
    p2p.soap        mangosd console commands (accounts, kick, ban, announce)
    p2p.ws          a small RFC 6455 WebSocket client (+ server handshake for tests)
    p2p.realmproto  realmd wire bits: logon challenge, realm list rewrite, the gate's login frames
    p2p.firewall    Windows Firewall rules for the two game ports

Standard library only (libtorrent is optional). Nothing here ever reads, sends or shares Blizzard
game files: the only files that travel are Open Vanilla's own (Solo pack, launcher/client zips, patch-Z).
"""
import base64
import json
import os
import re
import secrets
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
LAUNCHER_DIR = os.path.dirname(HERE)
ROOT = os.path.dirname(LAUNCHER_DIR)
for _p in (LAUNCHER_DIR, ROOT):
    if _p not in sys.path:
        sys.path.append(_p)   # ed25519.py (launcher/) and play_local.py (repo root / app folder)

CENTRAL_URL = os.environ.get("OPENVANILLA_CENTRAL", "https://play.openvanilla.app").rstrip("/")
RELAY_URL = os.environ.get("OPENVANILLA_RELAY", "wss://relay.openvanilla.app").rstrip("/")
DIRECTORY_URL = CENTRAL_URL + "/api/directory"
TRACKER_URL = CENTRAL_URL + "/announce"
REGION = "us"
USER_AGENT = "OpenVanilla-Node/1"
# Same release key as openvanilla_launcher.MANIFEST_PUBKEY (packaging/release_manifest.py signs with it).
MANIFEST_PUBKEY = "845b8fd97c36702fcac4e60ef279f0cfdf69628f54e2463d0efc2006e6c9f448"

HOST_ID_RE = re.compile(r"^[a-z2-7]{16}$")
CODE_RE = re.compile(r"^[A-Z2-7]{10}$")
REALM_TYPES = {"pve": 0, "pvp": 1, "rp": 6, "rppvp": 8}   # realmlist.icon / mangosd GameType
TEMPLATES = ("classicplus", "vanilla")


class P2PError(Exception):
    """Something the launcher shows the player as is."""


def b32(data):
    """Lowercase RFC 4648 base32 without padding."""
    return base64.b32encode(data).decode("ascii").rstrip("=").lower()


def random_code(n=10):
    """n upper-case base32 characters (invite codes)."""
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    return "".join(secrets.choice(alphabet) for _ in range(n))


def play_local():
    """The Solo backend (play_local.py beside the launcher folder)."""
    import play_local as P  # noqa: WPS433
    return P


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, data):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)


def http(url, method="GET", payload=None, headers=None, timeout=10, data=None):
    """(status, body bytes, headers dict). HTTP errors come back as their status, network errors raise OSError."""
    h = {"User-Agent": USER_AGENT}
    h.update(headers or {})
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        h["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read(), {k.lower(): v for k, v in r.headers.items()}
    except urllib.error.HTTPError as e:
        return e.code, e.read() or b"", {k.lower(): v for k, v in (e.headers or {}).items()}


def http_json(url, method="GET", payload=None, headers=None, timeout=10):
    status, body, _ = http(url, method, payload, headers, timeout)
    try:
        return status, json.loads(body.decode("utf-8") or "null")
    except ValueError:
        return status, None
