# Open Vanilla player network (P2P)

Status: design. Phase 2 has a prototype in wenilla-realm (`/api/directory`, off unless
`DIRECTORY_ENABLED=1`; patch `realm/patches/0006-directory.patch`). Nothing here is deployed.

Next layer: volunteer relay nodes, the three tiers (Verified realms / Community P2P realms / Verified
P2P nodes), end-to-end encrypted streams and the supporter leaderboard are in `docs/NODE_NETWORK.md`.

The goal: any player can host a realm from their own PC with one click, other players find it in
the launcher, connect without the host touching their router, and sign in with the same Open Vanilla
identity everywhere. The central service stays small: a list, a relay, and a signing key.
It never runs anybody's world and never carries Blizzard game data.

## The pieces that exist today

| Piece | Where it runs | Ports | What it does |
|---|---|---|---|
| MariaDB | live: container `mariadb`; Solo: `solo\mariadb` | 3306 (internal / 127.0.0.1) | `classicrealmd` (accounts, `realmlist`), `classicmangos` (world + our Classic+ SQL), `classiccharacters`, `classiclogs` |
| realmd (CMaNGOS) | container `realmd`; Solo `bin\realmd.exe` | 3724 TCP | SRP6 login, realm list (`realmlist` row: name, address, icon = type) |
| mangosd (CMaNGOS classic + PlayerBots + Open Vanilla hooks) | container `mangosd` (`ghcr.io/orionopenwow/openvanilla-mangos`); Solo `bin\mangosd.exe` | 8085 TCP (game), 7878 (SOAP, internal) | the world; our patches add the WNL addon channel, the Star Pouch level-up hook, gameplay switches (`Open Vanilla.*` in mangosd.conf) |
| wenilla-realm | container `realm` | 8090 internal | sign-in (password, Discord, launcher), `/api/play` hands a session its game credentials, `/data` serves the operator's client files to the browser client, `/ws/3724` and `/ws/8085` relay WebSocket bytes to realmd/mangosd, admin panel over SOAP |
| Caddy | container `caddy` | 80, 443 TCP, 443 UDP | TLS (HTTP/2, HTTP/3) in front of wenilla-realm; the only published ports |
| Launcher + desktop client | player PC | outbound only | reads `www/community/directory.json` (`servers`: name, host, port, portal, build, tags, description), runs Solo, plays live |

Solo already is a full local server (portable MariaDB, realmd, mangosd with playerbots and the
same Classic+ SQL), listening on 127.0.0.1 only. The network is built on top of Solo.

## Phase 1 — one-click host

*Who runs what:* the host's PC runs the Solo pack plus a small agent, `openvanilla-node`, inside the
launcher. Nothing central changes.

1. Launcher gets a **Host** button next to PLAY SOLO. It writes a separate `host\` data folder
   (never the solo characters), and starts MariaDB (127.0.0.1:3306, random root password in
   `state.json`), realmd and mangosd with `BindIP = 0.0.0.0` for 3724/8085 only. MariaDB and
   SOAP stay on 127.0.0.1.
2. `realmlist` row 1 gets the host's chosen name, `icon` from the type (0 PvE, 1 PvP, 6 RP,
   8 RP-PvP) and `GameType` in mangosd.conf to match (mangosd rewrites `icon` from `GameType` at
   every start), `address` = the public address the host chose (or what phase 3 sets).
3. Accounts: the host's own launcher creates accounts through SOAP (`account create`), the way
   wenilla-realm provisions them. Until phase 4 other players get an invite (username + password
   the host's agent generates) — the stock client works with it.
4. Reachability in phase 1 is the host's problem: UPnP-IGD / NAT-PMP mapping of TCP 3724 and
   8085 by the agent (with consent), else manual forwarding. The agent shows a self-test result
   by asking the directory to probe it (phase 2).
5. Guardrails: the agent never opens 3306/7878; playerbot counts are capped by the host's RAM
   (Solo already sizes them); Windows Firewall rules are added for the two ports and removed on
   **Stop hosting**.

## Phase 2 — directory (prototype done)

*Who runs what:* the central wenilla-realm on play.openvanilla.app (behind Caddy, port 443).
Hosts' agents send heartbeats; launchers and the website read the list.

### API

`POST /api/directory/heartbeat` (JSON, at most 4 KB):

```json
{ "name": "Stormwind Nights", "host": "realm.example.org", "port": 3724, "type": "rp",
  "population": 12, "version": "1.14.2", "portal": "https://realm.example.org/",
  "build": 5875, "description": "A friendly RP realm.", "tags": ["Classic+", "EU"] }
```

* `name` 3–40 characters, `host` a public DNS name or public IP (no localhost, RFC 1918, CGNAT,
  link-local, `.local`/`.lan`…), `port` = realmd's port (1–65535), `type` = `pve` | `pvp` |
  `rp` | `rppvp`, `population` 0–5000, `version` 1–32 of `A-Za-z0-9.-+_`; optional `portal`
  (https only, public host), `build` (default 5875), `description` (≤ 200), up to four `tags`.
  Unknown fields are refused. The directory sets `community` and the type tag itself; `official`
  and the type tags cannot be claimed.
* First heartbeat for a `host:port` → `201 {"token": "<64 hex>", "ttl": 180, "heartbeat_every": 60}`.
  The service keeps only SHA-256(token). Later heartbeats send `Authorization: Bearer <token>`;
  anything else → 403. The claim lasts 24 h after the last heartbeat; then the `host:port` is free.
* Limits: 30 requests/min per client address, 5 new claims/hour per address, one heartbeat per
  entry per 20 s (429 otherwise), 2000 claims in total (503).

`GET /api/directory` (public, `Access-Control-Allow-Origin: *`, `max-age=15`):

```json
{ "servers": [ { "name": "...", "host": "...", "port": 3724, "portal": "https://...",
  "build": 5875, "tags": ["community", "RPPvE", "Classic+"], "description": "...",
  "population": 12, "last_seen": 1792080000 } ], "updated": 1792080030 }
```

The `servers` entries are the launcher's `directory.json` shape plus `population` and
`last_seen`, so the launcher can merge the live list under the curated one. An entry leaves the
list 180 s after its last heartbeat (three missed beats). Entries are in memory: a restart of the
service forgets them and every host re-registers within a minute (the agent stores the new token).

### Still to do for phase 2
* Launcher: show the live list (merged, curated entries first), ping each host from the player's
  PC (a realmd `AUTH_LOGON_CHALLENGE` round trip) to show latency.
* Agent: heartbeat every 60 s with `population` from `SELECT COUNT(*) FROM characters WHERE online = 1`
  (players only — bots excluded via the bot accounts list).
* Reachability probe (central → host: TCP connect to `host:port` and read a realmd challenge
  reply) before an entry is shown, so dead and fake entries never list. The prototype does not
  verify that the sender runs the host it names; until the probe exists, a squatter can claim a
  `host:port` for 24 h. Turn on `DIRECTORY_ENABLED` only after the probe.

## Phase 3 — reach without port forwarding (outbound relay)

Most home hosts are behind NAT or CGNAT; many players cannot forward ports. The host's agent
therefore opens an **outbound** connection to a relay, and players connect to the relay.

*Who runs what:* a relay service `openvanilla-relay` (a small Rust binary reusing wenilla-host's WS
relay code) on its own VM (`relay.openvanilla.app`, behind Caddy or with its own TLS), so relay
traffic never competes with the live realm.

Protocol:
1. Agent → `wss://relay.openvanilla.app/agent` with `Authorization: Bearer <directory token>`, one
   long-lived WebSocket carrying control messages (JSON) and pings every 25 s.
2. A player connects to `wss://relay.openvanilla.app/h/<host-id>/ws/3724` (and `/ws/8085`) — the same
   per-port WebSocket byte relay the browser client already speaks to wenilla-realm. The desktop
   client keeps raw TCP: the launcher runs a local bridge on `127.0.0.1:<port>` that tunnels to
   that URL and rewrites the address in realmd's `CMD_REALM_LIST` reply (plaintext) to its own
   second local port for 8085.
3. Relay → agent control message `{"open": <stream-id>, "port": 3724|8085}`; the agent dials
   `127.0.0.1:<port>` and opens a data WebSocket `wss://relay.openvanilla.app/agent/stream/<id>`; the
   relay pipes the two WebSockets. (Multiplexing with yamux on the one socket is the later
   optimisation; one socket per player connection is simpler to meter and to cut.)
4. Directory entries of relayed hosts list `host = relay.openvanilla.app`, `port` = a per-host TCP
   port only if raw-TCP fallback is ever needed; the launcher prefers the `/h/<host-id>` URL.
5. Direct connections stay available when the host has a public address: relay is the fallback,
   chosen by the probe result.

What the relay does **not** carry: `/data` (the browser client's game files). Those are the
operator's own Blizzard files and must not be redistributed by Open Vanilla; browser play on a
community host therefore needs the host's own portal (wenilla-realm on the host) or the player's
desktop client with their own Data folder. This also keeps relay bandwidth small.

Cost: the 1.12 game protocol is light — roughly 2–10 KB/s per player downstream (cities and
raids at the top), well under 1 KB/s upstream; take 5 KB/s ≈ 18 MB/hour per player, counted
twice at the relay (in from the host, out to the player). 100 concurrent players around the clock
≈ 2 × 500 KB/s ≈ 2.6 TB/month. A Hetzner CX22-class VM (2 vCPU, 4 GB, ~€4–5/month, ~20 TB
traffic included in EU locations, about €1 per extra TB — verify current prices before buying)
carries that with room to spare; the CPU work is copying bytes. Limits per host (concurrent
streams, KB/s, GB/day) are enforced at the relay so one host cannot spend the budget; above a
threshold a host is told to forward ports. Latency adds one hop (EU relay: +5–30 ms in Europe;
a second relay region later).

## Phase 4 — one identity (signed Open Vanilla tokens)

Players sign in once (Discord / launcher sign-in, already in wenilla-realm) and play on any
community host without making an account there, and without the host ever seeing their Open Vanilla
password.

* Central wenilla-realm holds an Ed25519 signing key (in `/state`, like `master.key`) and
  publishes the public keys at `https://play.openvanilla.app/.well-known/openvanilla-keys.json` (with key
  ids for rotation).
* `POST /api/identity/token {"aud": "<host-id>"}` (session-gated) returns a PASETO v4.public
  (or JWS EdDSA) token: `sub` = Open Vanilla account id, `name`, `roles` (e.g. banned/staff flags),
  `aud` = the host id, `iat`, `exp` = 5 minutes, `jti` nonce.
* The launcher hands the token to the host's agent (`POST <portal>/api/ow-login` or over the
  relay control channel). The agent verifies signature, `aud`, `exp`, and a single use of `jti`;
  maps `sub` to a local realmd account (`OW` + base32 of the id, random password kept by the
  agent; created via SOAP on first visit); returns those game credentials to the launcher —
  exactly the `/api/play` hand-off wenilla-realm does today. Characters stay on the host.
* Audience binding means a host cannot replay a player's token on another host. Central bans are
  a signed revocation list the agent fetches every few minutes; a host may also ban locally.

## Phase 5 — trust and safety

* **Listing rules:** the reachability probe (phase 2) and the heartbeat token; a central blocklist
  of host ids / addresses; names and descriptions checked against a word list; reports from the
  launcher (`POST /api/directory/report`, session-gated, rate-limited) go to staff in Discord
  (the Herald); staff can delist with one command.
* **Players' safety:** the relay hides players' IP addresses from hosts (and hosts' from
  players). Hosts never receive Open Vanilla credentials, only audience-bound short tokens. The client
  never loads addons, MPQs or scripts from a community host without an explicit prompt (the
  Classic+ client already treats addons as sandboxed Lua); default is the player's own files.
* **Hosts' safety:** the agent exposes only 3724/8085 (or nothing, with the relay); MariaDB and
  SOAP stay on loopback; host-side rate limits on logins; the agent can kick and ban.
* **Badges:** `official` only for Open Vanilla's own realms (set centrally, never by heartbeat);
  `verified` once the probe passes and the host has signed in with a staff-approved Open Vanilla
  account; unverified entries are shown below, greyed.
* **Data and law:** no Blizzard files over the network (players bring their own client data);
  the directory stores names, addresses and counts only; logs keep addresses for 14 days.

## Direct and LAN mode, privacy, offline operation

A host picks one of three connections in the launcher (Host → Host a realm → Connection):

| Mode | Launcher label | Who can join | What players see of the host |
|---|---|---|---|
| `relay` (default) | Through Open Vanilla (recommended: your address stays hidden) | anyone with an invite, or everyone when Public | nothing: traffic goes through relay.openvanilla.app, no router ports opened |
| `direct` | Direct from my home connection | anyone who has the address or a link | the host's home IP address (so roughly city and ISP) |
| `lan` | My local network only | people on the same network | the host's LAN address |

**Direct mode privacy notice.** Before a direct realm starts, the launcher shows a notice that
must be accepted ("I understand, start"; the other button switches to the relay):

* everyone invited, and anyone they pass the link to, sees the home IP address and from it roughly
  where the host is (city, internet provider);
* router ports 3724 and 8085 stay open while hosting (UPnP and a firewall rule only with the
  host's ticks);
* sign-in details between friends travel unencrypted in direct mode;
* to stay safe: share links only with people you trust, stop hosting when done, use the relay to
  hide the address.

Players get the mirror image: joining a direct host asks first and says the host will see the
player's IP address (LAN joins say the realm is on the local network).

**Live panel.** The host sees the connection mode, the external (direct) or LAN address with a
"who can see this?" tooltip, the exposed ports, the host key fingerprint, and the invite tools:
"Guest invite (no account needed)" (`HostSession.guest_invite`, an
`openvanilla://join/direct|lan/<host>:<port>?g=<code>&n=<name>&k=<fingerprint>` link, or the relay form
with `g=`) and "Make an account for a friend" (`HostSession.create_account`: name, password and the
`set realmlist …` line for the stock client, copied to the clipboard).

**Host keys (trust on first use).** Each host has an Ed25519 key; guest/direct replies are signed
with it. The link carries the fingerprint (`k=`), and the player's launcher pins the key per host
the first time. If the key later differs, the join is refused and the launcher explains: the host
may have reinstalled (ask for a new invite link), or someone may be pretending to be the host
(don't sign in).

**Offline operation.** Direct and LAN links, plain `host:port` (Realms → Join by address, with an
optional guest code or account/password), guest codes and accounts made by the host never call
Open Vanilla's central services. When the directory or sign-in can't be reached, the launcher shows
"Open Vanilla is offline: you can still host and join friends directly" instead of errors, and
www/realms.html carries the same "Play without Open Vanilla" note. Only the listing, Open Vanilla sign-in
tokens, reports and the relay need play.openvanilla.app / relay.openvanilla.app.

## Order of work

1. Phase 2 probe, then enable the directory on play.openvanilla.app; launcher shows the live list.
2. Phase 1 Host button in the launcher (Solo-based), with UPnP and the heartbeat.
3. Phase 3 relay VM and the launcher's local bridge.
4. Phase 4 identity tokens (central endpoint + agent verification).
5. Phase 5 reports, verified badges and the revocation list, before any public promotion.
