# Copied from Vanilla Agents (vanilla_agents/remote/relay.py) by scripts/export_browser_access.py. Change it there, not here.
"""The Vanilla Agents relay (V-054): a blind mailbox between a PC's window and the browsers paired with it. Standard library only.

    python -m vanilla_agents.remote.relay --port 8790 [--data /var/lib/va-relay] [--trust-proxy]

Routes
    GET  /healthz                         "ok"
    GET  /ws  (WebSocket)                 first message says who you are:
           {"t":"pc","pair":P,"token":T}      the PC. The first PC to use pair id P sets sha256(T); later ones must match.
           {"t":"dev","pair":P,"dev":D}       a browser. It can only talk to that pair's PC.
    POST /mcp/<pair>/<connector token>    a Claude connector (remote MCP, JSON-RPC over HTTP). Handed to the PC, whose answer is returned.

What the relay sees: pair ids, device ids, frame sizes and times. Browser <-> PC frames are sealed (seal.py) and it cannot open
them. Connector calls are plain JSON-RPC from Claude (TLS ends at our Caddy), held in memory only for the call. It stores the
pair -> sha256(PC token) list (so nobody else can pretend to be your PC) and nothing else; it logs counts, never addresses.
"""
import argparse
import asyncio
import hashlib
import hmac
import json
import os
import re
import secrets
import struct
import tempfile
import time
from pathlib import Path

from .wsproto import CLOSE, PING, PONG, TEXT, Assembler, Closed, _xor, accept_value, encode, parse_head

ID = re.compile(r"^[A-Za-z0-9_-]{16,64}$")
DEV_MAX_IN, PC_MAX_IN, MCP_MAX = 64 * 1024, 4 * 1024 * 1024, 256 * 1024
DEVS_PER_PAIR, CONNS_PER_IP, NEW_PAIRS_PER_IP_HOUR, MAX_PAIRS = 16, 64, 20, 200_000
HELLO_WAIT, IDLE, PING_EVERY, MCP_WAIT = 10, 90, 25, 30


class Bucket:
    """rate per second, burst."""
    def __init__(self, rate, burst):
        self.rate, self.burst, self.level, self.t = rate, burst, burst, time.monotonic()

    def take(self):
        now = time.monotonic()
        self.level = min(self.burst, self.level + (now - self.t) * self.rate)
        self.t = now
        if self.level < 1:
            return False
        self.level -= 1
        return True


class Conn:
    def __init__(self, reader, writer, ip, limit):
        self.r, self.w, self.ip, self.asm = reader, writer, ip, Assembler(limit)
        self.seen, self.closed, self.bucket = time.monotonic(), False, Bucket(30, 60)
        self.role = self.pair = self.dev = None

    async def send(self, obj):
        if self.closed:
            return
        try:
            self.w.write(encode(TEXT, json.dumps(obj, separators=(",", ":")), mask=False))
            await self.w.drain()
        except (ConnectionError, OSError):
            self.close()

    async def ctrl(self, op, payload=b""):
        try:
            self.w.write(encode(op, payload, mask=False))
            await self.w.drain()
        except (ConnectionError, OSError):
            self.close()

    def close(self):
        if not self.closed:
            self.closed = True
            try:
                self.w.close()
            except Exception:
                pass

    async def recv(self):
        """Next text message; None when the connection ended. Clients must mask their frames."""
        while not self.closed:
            try:
                b2 = await self.r.readexactly(2)
                fin, op, masked, ln = parse_head(b2)
                if not masked:
                    raise Closed("client frames must be masked")
                if ln == 126:
                    ln = struct.unpack(">H", await self.r.readexactly(2))[0]
                elif ln == 127:
                    ln = struct.unpack(">Q", await self.r.readexactly(8))[0]
                if ln > self.asm.limit:
                    raise Closed("frame too big")
                m = await self.r.readexactly(4)
                data = await self.r.readexactly(ln)
                got = self.asm.feed(fin, op, _xor(data, m))
            except (asyncio.IncompleteReadError, ConnectionError, OSError, Closed, UnicodeDecodeError):
                self.close()
                return None
            self.seen = time.monotonic()
            if got is None or got[0] == "pong":
                continue
            if got[0] == "ping":
                await self.ctrl(PONG, got[1])
                continue
            if got[0] == "close":
                await self.ctrl(CLOSE)
                self.close()
                return None
            return got[1]
        return None


class Pair:
    def __init__(self):
        self.pc, self.devs, self.waiting = None, {}, {}


class Relay:
    def __init__(self, data_dir=None, trust_proxy=False, clock=time.time):
        self.pairs, self.trust_proxy, self.clock = {}, trust_proxy, clock
        self.data = Path(data_dir) / "pairs.json" if data_dir else None
        self.known = self._load()          # pair id -> {"h": sha256 hex of the PC token, "seen": unix time}
        self.ips, self.new_pairs = {}, {}  # ip -> open connections; ip -> [times of new pair registrations]
        self.stats = {"pc": 0, "dev": 0, "frames": 0, "mcp": 0}
        self._dirty = False

    # ---- the pair list ----
    def _load(self):
        if not self.data:
            return {}
        try:
            d = json.loads(self.data.read_text(encoding="utf-8"))
            return {k: v for k, v in d.items() if ID.match(k) and isinstance(v, dict) and isinstance(v.get("h"), str)} if isinstance(d, dict) else {}
        except (OSError, ValueError):
            return {}

    def save(self):
        if not self.data or not self._dirty:
            return
        self._dirty = False
        self.data.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=str(self.data.parent), prefix=".pairs")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(self.known, f)
        os.replace(tmp, self.data)

    def forget_old(self, days=180):
        cut = self.clock() - days * 86400
        old = [k for k, v in self.known.items() if v.get("seen", 0) < cut]
        for k in old:
            del self.known[k]
        self._dirty = self._dirty or bool(old)

    def pc_ok(self, pair, token, ip):
        """True when this token may act as the PC of this pair (registers a new pair, rate-limited per address)."""
        h = hashlib.sha256(token.encode("utf-8")).hexdigest()
        k = self.known.get(pair)
        if k:
            if not hmac.compare_digest(k["h"], h):
                return False
        else:
            recent = [t for t in self.new_pairs.get(ip, []) if t > self.clock() - 3600]
            if len(recent) >= NEW_PAIRS_PER_IP_HOUR or len(self.known) >= MAX_PAIRS:
                return False
            self.new_pairs[ip] = recent + [self.clock()]
            k = self.known[pair] = {"h": h, "seen": int(self.clock())}
            self._dirty = True
            self.save()             # a new pair is written at once, so a restart cannot hand it to someone else
        if self.clock() - k.get("seen", 0) > 3600:
            k["seen"] = int(self.clock())
            self._dirty = True
        return True

    # ---- HTTP ----
    async def handle(self, reader, writer):
        ip = (writer.get_extra_info("peername") or ("?",))[0]
        try:
            head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), HELLO_WAIT)
        except (asyncio.TimeoutError, asyncio.IncompleteReadError, asyncio.LimitOverrunError, ConnectionError, OSError):
            writer.close()
            return
        lines = head.decode("latin-1").split("\r\n")
        try:
            method, path, _ = lines[0].split(" ", 2)
        except ValueError:
            writer.close()
            return
        hdr = {k.strip().lower(): v.strip() for k, _, v in (ln.partition(":") for ln in lines[1:] if ":" in ln)}
        if self.trust_proxy and hdr.get("x-forwarded-for"):
            ip = hdr["x-forwarded-for"].split(",")[0].strip()
        path = path.split("?", 1)[0]
        try:
            if path == "/healthz" and method in ("GET", "HEAD"):
                return await self._plain(writer, 200, "ok\n")
            if path == "/ws" and method == "GET" and "websocket" in hdr.get("upgrade", "").lower():
                return await self._ws(reader, writer, hdr, ip)
            m = re.match(r"^/mcp/([A-Za-z0-9_-]{16,64})/([A-Za-z0-9_-]{16,128})$", path)
            if m:
                return await self._mcp(reader, writer, method, hdr, m.group(1), m.group(2))
            return await self._plain(writer, 404, "not found\n")
        finally:
            try:
                writer.close()
            except Exception:
                pass

    async def _plain(self, writer, code, text, ctype="text/plain; charset=utf-8", extra=""):
        body = text.encode("utf-8")
        reason = {200: "OK", 202: "Accepted", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large",
                  429: "Too Many Requests", 503: "Service Unavailable", 504: "Gateway Timeout"}.get(code, "OK")
        writer.write(("HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n%s\r\n"
                      % (code, reason, ctype, len(body), extra)).encode("latin-1") + body)
        try:
            await writer.drain()
        except (ConnectionError, OSError):
            pass

    # ---- Claude connector (remote MCP) ----
    async def _mcp(self, reader, writer, method, hdr, pair, tok):
        if method != "POST":
            return await self._plain(writer, 405, "POST JSON-RPC here\n", extra="Allow: POST\r\n")
        try:
            n = int(hdr.get("content-length", "0"))
        except ValueError:
            n = -1
        if n < 0 or n > MCP_MAX:
            return await self._plain(writer, 413, "too big\n")
        try:
            body = (await asyncio.wait_for(reader.readexactly(n), HELLO_WAIT)).decode("utf-8")
        except (asyncio.TimeoutError, asyncio.IncompleteReadError, UnicodeDecodeError, ConnectionError, OSError):
            return
        p = self.pairs.get(pair)
        err = lambda msg: json.dumps({"jsonrpc": "2.0", "id": None, "error": {"code": -32000, "message": msg}})
        if not p or not p.pc:
            return await self._plain(writer, 503, err("The owner's Vanilla Agents is not running or browser access is off. Try again later."), "application/json")
        if len(p.waiting) > 32 or not p.pc.bucket.take():
            return await self._plain(writer, 429, err("Too many calls at once."), "application/json")
        rid = secrets.token_urlsafe(12)
        fut = asyncio.get_running_loop().create_future()
        p.waiting[rid] = fut
        self.stats["mcp"] += 1
        await p.pc.send({"t": "mcp", "rid": rid, "tok": tok, "body": body})
        try:
            ans = await asyncio.wait_for(fut, MCP_WAIT)
        except asyncio.TimeoutError:
            return await self._plain(writer, 504, err("Vanilla Agents did not answer in time."), "application/json")
        finally:
            p.waiting.pop(rid, None)
        if ans.get("status") == 202 or not ans.get("body"):
            return await self._plain(writer, 202, "")
        return await self._plain(writer, int(ans.get("status") or 200) if ans.get("status") in (200, 400, 401, 403, 404) else 200, ans["body"], "application/json")

    # ---- WebSocket ----
    async def _ws(self, reader, writer, hdr, ip):
        key = hdr.get("sec-websocket-key", "")
        if hdr.get("sec-websocket-version") != "13" or not key:
            return await self._plain(writer, 400, "bad websocket request\n")
        if self.ips.get(ip, 0) >= CONNS_PER_IP:
            return await self._plain(writer, 429, "too many connections\n")
        writer.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n"
                      % accept_value(key)).encode("ascii"))
        self.ips[ip] = self.ips.get(ip, 0) + 1
        c = Conn(reader, writer, ip, DEV_MAX_IN)
        pinger = asyncio.create_task(self._pinger(c))
        try:
            try:
                first = await asyncio.wait_for(c.recv(), HELLO_WAIT)
                hello = json.loads(first) if first else None
            except (asyncio.TimeoutError, ValueError):
                hello = None
            if not await self._hello(c, hello):
                return
            while True:
                text = await c.recv()
                if text is None:
                    break
                await self._frame(c, text)
        finally:
            pinger.cancel()
            c.close()
            self._gone(c)
            self.ips[ip] -= 1
            if not self.ips[ip]:
                del self.ips[ip]

    async def _pinger(self, c):
        while not c.closed:
            await asyncio.sleep(PING_EVERY)
            if time.monotonic() - c.seen > IDLE:
                c.close()
                return
            await c.ctrl(PING)

    async def _hello(self, c, h):
        if not isinstance(h, dict) or not isinstance(h.get("pair"), str) or not ID.match(h["pair"]):
            await c.send({"t": "error", "error": "bad hello"})
            return False
        pair = h["pair"]
        if h.get("t") == "pc" and isinstance(h.get("token"), str) and 16 <= len(h["token"]) <= 128:
            if not self.pc_ok(pair, h["token"], c.ip):
                await c.send({"t": "error", "error": "this pair belongs to another PC"})
                return False
            p = self.pairs.setdefault(pair, Pair())
            if p.pc:
                await p.pc.send({"t": "error", "error": "replaced by a newer connection"})
                p.pc.close()
            c.role, c.pair, c.asm.limit, c.bucket = "pc", pair, PC_MAX_IN, Bucket(200, 400)
            p.pc = c
            self.stats["pc"] += 1
            await c.send({"t": "ready", "devs": sorted(p.devs)})
            for d in p.devs.values():
                await d.send({"t": "pc", "online": True})
            return True
        if h.get("t") == "dev" and isinstance(h.get("dev"), str) and ID.match(h["dev"]):
            p = self.pairs.setdefault(pair, Pair())
            old = p.devs.get(h["dev"])
            if old:
                old.close()
            elif len(p.devs) >= DEVS_PER_PAIR:
                await c.send({"t": "error", "error": "too many browsers on this pair"})
                return False
            c.role, c.pair, c.dev = "dev", pair, h["dev"]
            p.devs[c.dev] = c
            self.stats["dev"] += 1
            await c.send({"t": "pc", "online": p.pc is not None})
            if p.pc:
                await p.pc.send({"t": "join", "dev": c.dev})
            return True
        await c.send({"t": "error", "error": "bad hello"})
        return False

    async def _frame(self, c, text):
        self.stats["frames"] += 1
        if not c.bucket.take():
            return              # over the rate: dropped (the PC and the page both cope with a lost frame)
        try:
            m = json.loads(text)
        except ValueError:
            return
        if not isinstance(m, dict):
            return
        p = self.pairs.get(c.pair)
        if not p:
            return
        if c.role == "dev":
            if m.get("t") in ("pair", "msg") and p.pc:
                m["dev"] = c.dev                     # the relay says which browser sent it; the browser cannot claim another
                await p.pc.send(m)
            return
        t = m.get("t")
        if t == "msg" and isinstance(m.get("dev"), str):
            d = p.devs.get(m["dev"])
            if d:
                await d.send({"t": "msg", "data": m.get("data")})
        elif t == "kick" and isinstance(m.get("dev"), str):
            d = p.devs.pop(m["dev"], None)
            if d:
                d.close()
        elif t == "mcpres" and isinstance(m.get("rid"), str):
            fut = p.waiting.get(m["rid"])
            if fut and not fut.done():
                fut.set_result({"status": m.get("status"), "body": m.get("body") if isinstance(m.get("body"), str) else ""})

    def _gone(self, c):
        p = self.pairs.get(c.pair)
        if not p:
            return
        if c.role == "pc" and p.pc is c:
            p.pc = None
            for fut in p.waiting.values():
                if not fut.done():
                    fut.set_result({"status": 200, "body": json.dumps({"jsonrpc": "2.0", "id": None, "error": {"code": -32000, "message": "Vanilla Agents went offline."}})})
            for d in p.devs.values():
                asyncio.ensure_future(d.send({"t": "pc", "online": False}))
        elif c.role == "dev" and p.devs.get(c.dev) is c:
            del p.devs[c.dev]
            if p.pc:
                asyncio.ensure_future(p.pc.send({"t": "leave", "dev": c.dev}))
        if not p.pc and not p.devs and not p.waiting:
            self.pairs.pop(c.pair, None)

    async def housekeeping(self, log=print):
        while True:
            await asyncio.sleep(600)
            self.forget_old()
            self.save()
            log("relay: %d pairs online, %d known; since start %s" % (len(self.pairs), len(self.known), self.stats))


async def run(host, port, data_dir=None, trust_proxy=False):
    relay = Relay(data_dir, trust_proxy)
    srv = await asyncio.start_server(relay.handle, host, port, limit=16384)
    print("Vanilla Agents relay on %s:%d" % (host, port), flush=True)
    async with srv:
        await asyncio.gather(srv.serve_forever(), relay.housekeeping(lambda s: print(s, flush=True)))


def main(argv=None):
    ap = argparse.ArgumentParser(description="The Vanilla Agents relay: a blind mailbox between a PC and its paired browsers.")
    ap.add_argument("--host", default=os.environ.get("RELAY_HOST", "127.0.0.1"))
    ap.add_argument("--port", type=int, default=int(os.environ.get("RELAY_PORT", "8790")))
    ap.add_argument("--data", default=os.environ.get("RELAY_DATA"), help="folder for the pair list (pairs.json)")
    ap.add_argument("--trust-proxy", action="store_true", default=os.environ.get("RELAY_TRUST_PROXY") == "1",
                    help="take the address from X-Forwarded-For (only behind our own Caddy)")
    a = ap.parse_args(argv)
    try:
        asyncio.run(run(a.host, a.port, a.data, a.trust_proxy))
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
