"""Join a community realm from the launcher.

    s = join(realm_or_invite_link, game_launcher, launcher_token=TOKEN)
    s.creds        {"user", "password", "realm"}  (the stock client needs them typed; show them)
    s.realmlist    what the client connects to ("127.0.0.1:<bridge port>" through the relay, else host[:port])
    s.process      whatever game_launcher returned
    s.wait(); s.stop()   # stop() closes the bridge (do it after the game exits)

realm_or_invite_link: a directory.Realm (or its dict), an openvanilla://join/… or https://…/join/… link,
an openvanilla://join/direct|lan/<host>:<port>?g=…&k=… guest link, or a plain "host[:port]".
game_launcher(env, realmlist) starts the client: env has WOW_HOST/WOW_USER/WOW_PASS/WOW_REALM (the Open Vanilla engine
signs in by itself with them). engine_launcher(exe, data) and stock_launcher(exe) build one.

The Open Vanilla sign-in: POST <central>/api/identity/token {"aud": host_id} with the launcher's token,
then the token goes to the host's gate (through the relay, or straight to host:port) which answers
with this realm's game account. The Open Vanilla password never reaches the host.
"""
import os
import re
import socket
import subprocess
import threading

import ed25519

from . import CENTRAL_URL, HOST_ID_RE, RELAY_URL, P2PError, http_json, invites, read_json, realmproto, write_json
from .bridge import Bridge
from .directory import Realm, route as directory_route


def identity_token(aud, launcher_token, central=CENTRAL_URL):
    if not launcher_token:
        raise P2PError("Sign in to Open Vanilla first (Account page) to join community realms.")
    try:
        status, data = http_json(central + "/api/identity/token", "POST", {"aud": aud},
                                 headers={"Authorization": "Bearer " + launcher_token}, timeout=10)
    except OSError as e:
        raise P2PError(f"Open Vanilla sign-in can't be reached ({e}).") from None
    if status in (401, 403):
        raise P2PError("Your Open Vanilla sign-in has expired. Sign in again.")
    if status != 200 or not isinstance(data, dict) or not str(data.get("token", "")).startswith("v4.public."):
        raise P2PError(f"Open Vanilla sign-in answered {status}.")
    return data["token"]


def direct_login(host, port, token, invite=None, timeout=15, extra=None):
    try:
        with socket.create_connection((host, int(port)), timeout=timeout) as s:
            s.settimeout(timeout)
            return realmproto.login_exchange(s.sendall, lambda n: realmproto.recv_exact(s, n), token, invite, extra)
    except (OSError, ValueError) as e:
        raise P2PError(f"The realm didn't answer the sign-in ({e}).") from None


def _brand_dir(base):
    """base\\OpenVanilla, or the older folder with the old name when it (from before the rename) already exists."""
    old = os.path.join(base, "OpenWoW")
    return old if os.path.isdir(old) else os.path.join(base, "OpenVanilla")


def default_pins_file():
    if os.environ.get("OPENVANILLA_PINS_FILE"):
        return os.environ["OPENVANILLA_PINS_FILE"]
    base = os.environ.get("APPDATA") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(_brand_dir(base), "host_pins.json")


def check_host_key(reply, nonce, pin_name, link_fp=None, pins_file=None):
    """Trust on first use: the reply must be signed by the host key whose fingerprint is in the link,
    and by the same key as last time for this host. Returns the fingerprint (or None for an
    old host without a key, only allowed when the link names none)."""
    from .host import key_fingerprint, reply_message
    pins_file = pins_file or default_pins_file()
    key_hex, sig_hex = reply.get("host_key"), reply.get("sig")
    pins = read_json(pins_file, {}) or {}
    if not key_hex or not sig_hex:
        if link_fp or pins.get(pin_name):
            raise P2PError("This realm didn't prove it is the host from your invite. Not connecting.")
        return None
    try:
        pub, sig = bytes.fromhex(key_hex), bytes.fromhex(sig_hex)
    except ValueError:
        raise P2PError("This realm sent a damaged host key. Not connecting.") from None
    if not ed25519.verify(pub, reply_message(nonce, reply), sig):
        raise P2PError("This realm's host signature doesn't check out. Not connecting.")
    fp = key_fingerprint(pub)
    if link_fp and fp != link_fp:
        raise P2PError("This realm's host key doesn't match the invite link. Someone may be pretending to be "
                       "the host; not connecting.")
    pinned = pins.get(pin_name)
    if pinned and pinned != fp:
        raise P2PError("This realm's host key changed since you last played there. If the host reinstalled, "
                       "ask them for a new invite link; otherwise someone may be pretending to be the host.")
    if pinned != fp:
        pins[pin_name] = fp
        write_json(pins_file, pins)
    return fp


class JoinSession:
    def __init__(self, realm, host_id, invite):
        self.realm, self.host_id, self.invite = realm, host_id, invite
        self.bridge = None
        self.creds = None
        self.realmlist = None
        self.env = None
        self.process = None
        self.pass_code = None
        self.fingerprint = None
        self._restore = None

    def wait(self):
        if self.process is not None and hasattr(self.process, "wait"):
            self.process.wait()

    def stop(self):
        if self.bridge:
            self.bridge.stop()
            self.bridge = None
        if self._restore:
            try:
                self._restore()
            except OSError:
                pass
            self._restore = None


def resolve(target, directory=None):
    """(Realm or None, host_id, invite code)."""
    if isinstance(target, Realm):
        return target, target.host_id, None
    if isinstance(target, dict):
        r = Realm(**{k: v for k, v in target.items() if k in Realm.__dataclass_fields__})
        return r, r.host_id, None
    parsed = invites.parse_link(str(target))
    if not parsed:
        raise P2PError("That isn't an Open Vanilla invite link.")
    host_id, code, name = parsed
    realm = next((r for r in (directory or []) if r.host_id == host_id), None)
    if realm is None:   # private realms are never listed: they are reached through the relay
        realm = Realm(name=name or "Community realm", host="", relay=True, host_id=host_id)
    return realm, host_id, code


def join(realm_or_invite_link, game_launcher, *, launcher_token=None, token_provider=None,
         central=CENTRAL_URL, relay_url=RELAY_URL, directory=None, bridge_factory=Bridge, invite=None,
         guest=None, guest_name=None, username=None, password=None, pins_file=None, node_network=False,
         route=None):
    """Direct/LAN links, plain "host:port", guest codes and username/password never call Open Vanilla's
    central services; only relayed realms (and Open Vanilla sign-in) do."""
    info = None
    if isinstance(realm_or_invite_link, str):
        info = invites.parse_any(realm_or_invite_link)
        if not info:
            raise P2PError("That isn't an Open Vanilla invite link or a host:port address.")
    if info and info["kind"] in ("direct", "lan", "plain"):
        realm = Realm(name=info["name"] or info["host"], host=info["host"], port=info["port"], relay=False)
        host_id, code = None, info["invite"]
    else:
        realm, host_id, code = resolve(realm_or_invite_link, directory)
    code = code or invite
    guest = guest or (info or {}).get("guest")
    link_fp = (info or {}).get("fp")
    s = JoinSession(realm, host_id, code)
    via_relay = bool(realm.relay or not realm.host)
    if not host_id and via_relay:
        raise P2PError("This realm can't be joined through Open Vanilla (no realm id).")
    pin_name = host_id or f"{realm.host}:{realm.port}"
    relay_for_join, sealed_fp = relay_url, None
    if via_relay and host_id:
        relay_for_join, sealed_fp = pick_relay(realm, host_id, relay_url, link_fp, pins_file, node_network,
                                               route or (lambda h: directory_route(h, central)))

    def make_bridge(invite_code):
        kw = {"invite": invite_code}
        if sealed_fp:
            kw["e2e_fp"] = sealed_fp
        return bridge_factory(host_id, relay_for_join, **kw)
    nonce = os.urandom(16).hex()
    reply = None
    if username:
        s.creds = {"user": username.strip().upper(), "password": password or "", "realm": ""}
    elif guest:
        extra = {"guest": guest, "name": guest_name or "Guest", "nonce": nonce}
        if via_relay:
            s.bridge = make_bridge(guest)
            reply = s.bridge.login(None, extra=extra)
        else:
            reply = direct_login(realm.host, realm.port, None, None, extra=extra)
    elif via_relay or host_id:
        get_token = token_provider or (lambda aud: identity_token(aud, launcher_token, central))
        token = get_token(host_id)
        if via_relay:
            s.bridge = make_bridge(code)
            reply = s.bridge.login(token, extra={"nonce": nonce})
        else:
            reply = direct_login(realm.host, realm.port, token, code, extra={"nonce": nonce})
    # else: a plain realm: the player's own account there (typed in the client)
    if reply is not None:
        if not reply.get("ok"):
            s.stop()
            raise P2PError(reply.get("error") or "The realm refused the sign-in.")
        try:
            s.fingerprint = check_host_key(reply, nonce, pin_name, link_fp, pins_file)
        except P2PError:
            s.stop()
            raise
        s.creds = {k: str(reply.get(k, "")) for k in ("user", "password", "realm")}
        if reply.get("pass"):
            # a private realm's personal pass: the game's relay streams use it (and the launcher may
            # remember it per host_id and pass it back as invite= next time)
            s.pass_code = str(reply["pass"])
            if s.bridge:
                s.bridge.invite = s.pass_code
    if via_relay:
        port = s.bridge.start()
        s.realmlist = f"127.0.0.1:{port}"
    else:
        s.realmlist = realm.host if int(realm.port) == 3724 else f"{realm.host}:{realm.port}"
    env = dict(os.environ)
    env["WOW_HOST"] = s.realmlist
    if s.creds:
        env["WOW_USER"], env["WOW_PASS"] = s.creds["user"], s.creds["password"]
        env["WOW_REALM"] = s.creds["realm"] or realm.name
    s.env = env
    try:
        s.process = game_launcher(env, s.realmlist)
    except BaseException:
        s.stop()
        raise
    if s.bridge and s.process is not None and hasattr(s.process, "wait"):
        threading.Thread(target=lambda: (s.process.wait(), s.stop()), daemon=True).start()
    return s


def pick_relay(realm, host_id, relay_url, link_fp, pins_file, node_network, route):
    """(relay base URL, host key fingerprint to seal streams with or None).

    A realm on a volunteer node is always joined end-to-end encrypted, and only with a host key we
    already trust (invite link k=, the directory's entry, or our pin): otherwise the node could sit
    in the middle. On Open Vanilla's own relay streams are sealed too once the network is on and the host
    supports it."""
    official = relay_url.rstrip("/")
    base, key, sealed = realm.relay_url, realm.key, realm.e2e
    if node_network and not base:
        r = route(host_id)
        if r:
            base, key, sealed = r.get("relay_url") or base, r.get("key") or key, bool(r.get("e2e")) or sealed
    pins = read_json(pins_file or default_pins_file(), {}) or {}
    fp = link_fp or key or pins.get(host_id)
    base = (base or official).rstrip("/")
    if base != official:
        if not node_network:
            return official, None          # nodes are switched off in this launcher: Open Vanilla's relay
        if not fp:
            raise P2PError("This realm is carried by a community node and its host key isn't known yet, so the "
                           "connection can't be encrypted safely. Ask the host for a fresh invite link.")
        return base, fp
    return official, (fp if node_network and sealed and fp else None)


# ---------------------------------------------------------------- client launchers

def engine_launcher(exe, data_folder=None, popen=subprocess.Popen):
    """The Open Vanilla engine: signs in by itself from the environment."""
    def launch(env, realmlist):
        env = dict(env)
        if data_folder:
            env["WOW_DATA"] = data_folder
        return popen([exe], cwd=os.path.dirname(exe), env=env)
    return launch


def stock_launcher(exe, popen=subprocess.Popen):
    """A stock 1.12.1 WoW.exe: realmlist.wtf points at the realm (put back when the game exits) and
    Config.wtf has the account name; the player types the password the launcher shows."""
    folder = os.path.dirname(exe)

    def launch(env, realmlist):
        rl = os.path.join(folder, "realmlist.wtf")
        try:
            with open(rl, encoding="utf-8", errors="replace") as f:
                old = f.read()
        except OSError:
            old = None
        with open(rl, "w", encoding="ascii", newline="\r\n") as f:
            f.write(f"set realmlist {realmlist}\n")
        cfg = os.path.join(folder, "WTF", "Config.wtf")
        if env.get("WOW_USER"):
            try:
                with open(cfg, encoding="utf-8", errors="replace") as f:
                    lines = f.read().splitlines()
            except OSError:
                lines = []
            lines = [l for l in lines if not re.match(r"(?i)^\s*set\s+(accountname|realmname)\s", l)]
            lines += [f'SET accountName "{env["WOW_USER"]}"', f'SET realmName "{env.get("WOW_REALM", "")}"']
            os.makedirs(os.path.dirname(cfg), exist_ok=True)
            with open(cfg, "w", encoding="utf-8", newline="\r\n") as f:
                f.write("\n".join(lines) + "\n")
        proc = popen([exe], cwd=folder)

        def restore():
            proc.wait()
            if old is not None:
                with open(rl, "w", encoding="utf-8", newline="") as f:
                    f.write(old)
        threading.Thread(target=restore, daemon=True).start()
        return proc
    return launch


def valid_host_id(h):
    return bool(HOST_ID_RE.match(h or ""))
