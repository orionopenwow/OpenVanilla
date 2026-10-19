# openvanilla-relay

Phase 3 of `docs/P2P_NETWORK.md`: players reach community hosts behind NAT/CGNAT through
`relay.openvanilla.app` (US region, one VM). The relay only pipes WebSockets: it never dials
TCP itself, carries no `/data` and no Blizzard files, and never shows player IPs to hosts.

## Protocol (fixed contract)

| Endpoint | Who | Notes |
|---|---|---|
| `GET /agent` (WS) | host agent | `Authorization: Bearer <directory token>`, `X-Host-Id: <16 base32>`. One control socket per host; a new one replaces the old. |
| `GET /agent/stream/<id>` (WS) | host agent | same headers; binary frames = raw TCP bytes of one player connection |
| `GET /h/<host_id>/ws/3724`, `/ws/8085` (WS) | player / launcher bridge | binary frames; `?invite=<10 base32>` for private hosts |
| `GET /metrics` | Prometheus | text format; Caddy restricts it |
| `GET /healthz` | probes | `ok` |

Control messages (JSON text frames):

* relay → agent: `{"limits":{"max_streams","bytes_per_sec","daily_bytes","stream_idle_secs"}}` on
  connect; `{"open":id,"port":3724|8085}` (with `"e2e":1` when the player connected with `?e2e=1`:
  the stream is sealed end to end between the player's launcher and the agent, see
  `launcher/p2p/e2e.py`); `{"close":id}`; `{"invite_check":"<code>","stream":id}`;
  `{"pong":n}`.
* agent → relay: `{"ping":n}` (every 25 s; the control socket is dropped after 90 s of silence),
  `{"close":id}`, `{"invite_ok":id}` / `{"invite_no":id}`.

Player connect flow: port must be 3724/8085 (else 404) → host online (404 "host offline") →
daily quota (429) → stream limit (503) → private host: invite present and accepted by the agent
within 10 s (403) → `open` sent, agent must open `/agent/stream/<id>` within 10 s (502) → upgrade
and pipe. All refusals happen before the WebSocket upgrade, so clients get a real HTTP status.

## Limits (per host, env-configurable)

| Env | Default | |
|---|---|---|
| `RELAY_MAX_STREAMS` | 64 | concurrent player connections (a player uses 2: 3724 then 8085) |
| `RELAY_KBPS` | 256 | token bucket in KB/s, both directions together, burst = 1 s |
| `RELAY_DAILY_GB` | 20 | resets at 00:00 UTC; survives agent reconnects (not relay restarts) |
| `RELAY_STREAM_IDLE_SECS` | 900 | no bytes either way → stream closed |
| `RELAY_CTRL_IDLE_SECS` | 90 | control socket without any frame |
| `RELAY_OPEN_TIMEOUT_SECS` | 10 | invite answer / agent stream dial |

Other env: `RELAY_BIND` (`0.0.0.0:8080`), `RELAY_TRUST_PROXY=1` (take `X-Forwarded-For`; only
behind our Caddy), `RELAY_VERIFY_URL`, `RELAY_VERIFY_SECRET`, `RELAY_ALLOW_FILE`, `RUST_LOG`.

## Agent authentication

1. **Static allow-list** (`RELAY_ALLOW_FILE`, for tests/staging/official hosts): lines
   `host_id sha256(token)_hex [public|private]`, `#` comments. Checked first.
2. **Central verify** — new endpoint for the central worker (wenilla-realm on play.openvanilla.app):

```
GET /api/directory/verify?host_id=<16 base32>&token_sha=<64 lowercase hex>
Authorization: Bearer <RELAY_VERIFY_SECRET>     (shared secret; 401 without it)

200 {"ok": true,  "visibility": "public"|"private"}   token_sha matches the stored SHA-256 of
                                                       the directory token for that host_id and
                                                       the claim is live and not blocklisted
200 {"ok": false}                                      otherwise (or 404)
```

Central already keeps only SHA-256(token), so this is a constant-time compare of two stored
hashes; the raw token never leaves the relay. The relay caches positive answers 60 s and
re-verifies each live control socket every 10 min (delisted/blocked hosts drop off).

## Privacy and logs

JSON logs to stdout (`tracing`). Player addresses are logged only as
`sha256(random per-process salt ‖ UTC day ‖ ip)[:12 hex]` — not reversible, not linkable across
days or restarts. Caddy has no access log. Docker's json-file rotation (50 MB × 14) bounds
retention; raw IPs are never written, so the 14-day rule holds trivially.

## Shutdown

SIGTERM/Ctrl-C: stop accepting, signal every control and stream session to close, drain, exit
(compose `stop_grace_period: 20s`). Agents reconnect with backoff; launchers' bridges reconnect.

## Deploy (not run)

```
relay/deploy/compose.yml      relay + Caddy (TLS, HTTP/3) for relay.openvanilla.app
relay/deploy/Caddyfile        /metrics limited to loopback/Tailscale range; no access log
relay/deploy/relay.env.example
relay/deploy/deploy_relay.sh  fresh Ubuntu 22.04+/Debian 12: docker, ufw (22/80/443), build, up
```

Set DNS first, run `deploy_relay.sh` as root on the VM, then put the printed
`RELAY_VERIFY_SECRET` into the central service's env.

## Sizing and cost (estimate — verify prices before buying)

Traffic per player ≈ 5 KB/s, counted twice at the relay (in + out) → ~36 MB/h per player.

| Concurrent players (24/7) | Relay throughput | Traffic/month |
|---|---|---|
| 25 | 250 KB/s | ~0.65 TB |
| 100 | 1 MB/s | ~2.6 TB |
| 500 | 5 MB/s | ~13 TB |

CPU work is memcpy + TLS; a 2 vCPU / 2–4 GB VM handles thousands of streams. US options:
Hetzner CPX11/CPX21 in Ashburn/Hillsboro (~$5–9/month, but US locations include only ~1 TB
traffic, then ~$1/TB), or a $6 DigitalOcean/Vultr droplet (1–2 TB included, ~$10/TB over).
Budget ≈ $6–15/month up to ~100 concurrent relayed players. The per-host caps (256 KB/s ≈ 50
players, 20 GB/day) keep one host from spending more than ~0.6 TB/month.

## Tests

`cargo test` — `tests/e2e.rs` runs a real relay, a fake agent, fake realmd/mangosd TCP servers
and player WebSocket clients: bytes both ways on 3724 and 8085, metrics, bad ports/offline
hosts, agent auth (allow-list and a fake central verify endpoint), private-host invites,
stream limit, token-bucket rate, daily quota, idle timeout, graceful shutdown.

Not done yet: per-host limit overrides (all hosts share the env limits), yamux multiplexing,
persistence of daily counters across relay restarts, a second region.
