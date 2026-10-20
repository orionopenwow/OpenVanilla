"""Smoke-test a relay from your PC: a fake host (realmd + world echo) behind the real host agent, and a
player bridge, both through the relay, with and without end-to-end encryption.

    python tools/relay_smoke.py --gen
        prints a test host id, its token, and the allow.txt line for the relay
        (add the line to /opt/openvanilla-relay/allow.txt on the server, then
         docker compose -p openvanilla-relay restart: the relay reads the list at start)
    python tools/relay_smoke.py --relay wss://relay.openvanilla.app --host-id <id> --token <token>
        -> "OK" and timings, exit 0; anything wrong -> the reason, exit 1

Nothing here touches game data or a real realm: the "realm" is two tiny local sockets.
"""
import argparse
import hashlib
import os
import secrets
import socket
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "launcher"))

import ed25519  # noqa: E402
from p2p import b32, e2e, host, realmproto  # noqa: E402
from p2p.bridge import Bridge  # noqa: E402


def gen():
    host_id = b32(os.urandom(10))
    token = secrets.token_hex(32)
    return host_id, token, f"{host_id} {hashlib.sha256(token.encode()).hexdigest()} public"


class _Fake:
    """realm: answers a logon challenge with 3 bytes; world: upper-cases what it gets."""

    def __init__(self, kind):
        self.kind = kind
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(8)
        self.port = self.sock.getsockname()[1]
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        while True:
            try:
                c, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(c,), daemon=True).start()

    def _serve(self, c):
        try:
            while True:
                d = c.recv(4096)
                if not d:
                    break
                c.sendall(b"\x00\x00\x04" if self.kind == "realm" and d[:1] == b"\x00" else d.upper())
        except OSError:
            pass
        finally:
            c.close()

    def close(self):
        self.sock.close()


def run(relay, host_id, token, sealed=True, timeout=20, out=print):
    seed = os.urandom(32)
    realm, world = _Fake("realm"), _Fake("world")
    agent = host.RelayAgent(relay, host_id, token, {3724: realm.port, 8085: world.port}, lambda code: True,
                            host_key=seed)
    agent.start()
    bridge = None
    try:
        end = time.time() + timeout
        while not agent.connected and time.time() < end:
            time.sleep(0.1)
        if not agent.connected:
            raise RuntimeError(f"the host agent couldn't connect: {agent.last_error} (is the line in allow.txt?)")
        out("host agent connected")
        fp = e2e.fingerprint(ed25519.public_key(seed)) if sealed else None
        bridge = Bridge(host_id, relay, e2e_fp=fp)
        bridge.start()
        t0 = time.perf_counter()
        with socket.create_connection(("127.0.0.1", bridge.auth_port), timeout=timeout) as c:
            c.settimeout(timeout)
            c.sendall(realmproto.logon_challenge("SMOKE"))
            if realmproto.recv_exact(c, 3) != b"\x00\x00\x04":
                raise RuntimeError("the realm port answered something else")
        t1 = time.perf_counter()
        msg = b"openvanilla relay smoke test"
        with socket.create_connection(("127.0.0.1", bridge.world_port), timeout=timeout) as c:
            c.settimeout(timeout)
            c.sendall(msg)
            if realmproto.recv_exact(c, len(msg)) != msg.upper():
                raise RuntimeError("the world port answered something else")
        t2 = time.perf_counter()
        out(f"OK{' (end-to-end encrypted)' if sealed else ''}: realm {1000 * (t1 - t0):.0f} ms, "
            f"world {1000 * (t2 - t1):.0f} ms through {relay}")
        return True
    finally:
        if bridge:
            bridge.stop()
        agent.stop()
        realm.close()
        world.close()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--gen", action="store_true", help="print a test host id, token and allow.txt line")
    ap.add_argument("--relay", default="wss://relay.openvanilla.app")
    ap.add_argument("--host-id")
    ap.add_argument("--token")
    ap.add_argument("--plain", action="store_true", help="also run without end-to-end encryption")
    a = ap.parse_args(argv)
    if a.gen:
        host_id, token, line = gen()
        print(f"host id:  {host_id}\ntoken:    {token}\nallow.txt line (on the server):\n{line}")
        return 0
    if not (a.host_id and a.token):
        ap.error("--host-id and --token (from --gen) are needed")
    try:
        ok = run(a.relay, a.host_id, a.token, sealed=True)
        if a.plain:
            ok = run(a.relay, a.host_id, a.token, sealed=False) and ok
    except Exception as e:   # noqa: BLE001 - a smoke test reports whatever went wrong
        print(f"FAILED: {e}")
        return 1
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
