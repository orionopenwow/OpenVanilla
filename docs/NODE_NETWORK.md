# The Open Vanilla node network

Status: **built, tested, not deployed.** Code: `launcher/p2p/{node,e2e,tiers,leaderboard}.py`, the
Node addon (in game: Esc > Become a Node), `www/nodes.html`, `hetzner/relay_up.sh`,
`tools/relay_smoke.py`, pending realm patch `realm/patches/pending/0018-openvanilla-node-network.patch`.
Builds on `docs/P2P_NETWORK.md` (hosting, directory, relay, identity).

## In one paragraph

Players already host realms from their PCs, and players reach them through a relay so nobody opens
router ports or shows a home address. The node network lets volunteers run more relays from the
launcher (HOST > Become a node). A node carries only end-to-end encrypted game traffic, never
Blizzard files. It adds connection capacity, absorbs attacks, hides addresses and shortens paths.
It does **not** make any single world bigger. Bigger means more worlds ("slices") that share
Open Vanilla accounts.

## The three tiers

Every list uses the same three labels: the launcher's realm list, `www/realms.html`, `www/nodes.html`
and the directory API (`tier`, `badges`). They are defined once in `launcher/p2p/tiers.py`, and
`www/community/nodes.json` carries a copy (a test keeps the two equal).

| Tier | Badge | Who | Criteria | Who approves |
|---|---|---|---|---|
| **Verified realms** | OFFICIAL / VERIFIED (gold) | Open Vanilla's own realms, and community realms the maintainer has vetted | Official: always. Community: listed ≥ 14 days, ≥ 98% of probes passing, uses Open Vanilla sign-in (players' passwords never reach the host), backups on, has a description and rules, no upheld reports, owner in good standing (`tiers.realm_promotion_checks`) | the maintainer (`POST /admin/api/directory/verify`) |
| **Community P2P realms** | COMMUNITY (grey), RELAYED, ENCRYPTED | Any player-hosted realm that passes the automatic checks | heartbeat every minute; reachability probe (directly, through Open Vanilla's relay, or reported by the node carrying it); name/description word list; not blocklisted | machines only. Shown below the verified realms, with "not vetted, play at your own risk" |
| **Verified P2P nodes** | NODE (teal) / PENDING | Volunteers' relays (Become a node) | below | machines check, then the maintainer approves |

**Node criteria** (`tiers.node_checks`, mirrored in `nodes.rs`):

1. *Reachable*: the directory's probe (`GET <node>/node?c=<nonce>`) answers, signed with the node's
   key. The node id is the fingerprint of that key, so nobody can claim someone else's node.
2. *History*: ≥ 3 days and ≥ 300 probes (one every 10 minutes).
3. *Uptime*: ≥ 95% of probes over 30 days.
4. *Software*: node protocol ≥ 1, end-to-end encryption required (no plaintext streams).
5. *Caps*: ≥ 256 KB/s, ≥ 5 GB/day, ≥ 16 streams.
6. *Rules*: accepted the node rules (no recording of addresses; no inspecting, altering,
   throttling by realm or selling traffic; keep the launcher current; one node per person
   unless agreed).
7. *Standing*: no open reports, not blocklisted.

**Verification flow:** `unlisted` → `pending` (automatic, as soon as it is reachable) → `verified`
(only when the maintainer approves, and only if every check passes) → `suspended` (automatic: below 90%
uptime over 7 days, unreachable, or reported) → `verified` again by itself once it passes →
`revoked` (the maintainer; it stays revoked until they lift it, and the launcher turns that node off
and shows why). Only verified, fresh (heartbeat within 3 min), accepting and unpaused nodes get
realms assigned.

**Data model.** Directory entry: `tier`, `badges[]`, `verified`, `official`, `relay`, `relay_url`
(Open Vanilla's relay or the carrying node), `key` (the host key fingerprint), `e2e`. Node (central):
`node_id` (key fingerprint), `key`, `url`, `region`, `version`, `protocol`, `rules`, `e2e_required`,
`caps{kbps,daily_gb,max_hosts,max_streams}`, `accepting`, `paused`, `carrying[]`, `first_seen`,
`last_seen`, `probes[(t,ok)]`, `status`, `message`, `days{UTC day: {relay_bytes, seed_bytes}}`,
`leaderboard` (`off|anonymous|named`), `display_name`. Public node / leaderboard row: `name`,
`anonymous`, `verified`, `region`, `relay_gb`, `seed_gb`, `uptime_pct`, `days_active`, `since`
(month), `badges`, `rank`. It never has a URL, address, key, node id or account id.

## How a stream flows

```
player's game ─TCP─ launcher bridge ══ WebSocket (sealed) ══ node ══ WebSocket (sealed) ══ host agent ─TCP─ realmd/mangosd
                   127.0.0.1         e2e: X25519 + host-signed   relays bytes,      checks its node ticket
                                     handshake, sealed frames    can't read them
```

* **Assignment.** A relayed host whose launcher has the network on sends `key`, `e2e`, `nodes:true`.
  The directory answers its heartbeat with `relay: {url, node_id, ticket}` when a verified node has
  room (fewest hosts first, sticky). The ticket is a 10-minute PASETO signed by Open Vanilla (`typ:node`,
  `aud` = node, `sub` = host) and is refreshed every heartbeat. The node checks it offline against
  the published keys, so volunteers hold no secrets. If the agent fails 3 reconnects to its node, it
  goes back to Open Vanilla's relay and reports `node_failed`; that node isn't assigned to it again.
* **Players.** The realm list carries the node's `relay_url` and the host `key`. Invite links carry
  `k=`, and private realms are looked up with `GET /api/directory/route/<host_id>`. A realm on a node
  is joined only end-to-end encrypted, and only with a host key the player already trusts (link, list
  or pin). Otherwise the launcher refuses and asks for a fresh invite. A node can't sit in the middle,
  because it can't sign as the host.
* **Why encrypt at all?** 1.12's protocol is mostly plaintext: a relay could read chat, character names
  and the sign-in frames. Sealing the stream between the two launchers makes "the node only sees
  encrypted bytes" true, for volunteer nodes and for Open Vanilla's own relay. v1 uses only the standard
  library: X25519 (RFC 7748, tested against its vector and the `cryptography` package), HKDF-SHA256,
  a SHAKE256 keystream with HMAC-SHA256 (encrypt-then-MAC) and implicit sequence numbers. **Have it
  reviewed before volunteer nodes carry public traffic.** The handshake's magic carries the version,
  so v2 can move to ChaCha20-Poly1305.

### Why the node is Python, not the bundled Rust relay

The node speaks the relay's exact wire protocol (`relay/README.md`), so the host agent
(`host.RelayAgent`) and the player bridge (`bridge.Bridge`) work against either one unchanged
(`tests/test_node_network.py` and `tools/relay_smoke.py`, against the real relay binary). Doing it
in-process means:

* no second native binary per OS to sign and ship, and no antivirus false positives;
* "off" is one click: no child process to hunt down;
* caps are enforced where the volunteer set them.

The load is small. Game traffic is about 5 KB/s per player, so a node at its default 512 KB/s (both
directions) carries about 50 players, well under one core. The official relay stays Rust (`relay/`)
because it is the hot path for everyone.

## What a volunteer sees

HOST > **BECOME A NODE** (the in-game Esc menu's **Become a Node** button explains the same, and so
does `www/nodes.html`):

* **Off by default.** Turn on… shows the full explanation and the rules first: why, what is shared
  (only end-to-end encrypted game traffic and, separately, seeding of Open Vanilla's own signed files,
  never Blizzard's), the caps, who sees which addresses, the port, and how to stop. Nothing starts
  until they press *Turn on my node*.
* **Caps:** KB/s (both directions), GB per UTC day (at the cap the node pauses until midnight UTC;
  open streams end, new ones get 429), and at most 4 realms and 64 connections.
* **Reachability:** a node must accept connections. Either the launcher asks the router (UPnP /
  NAT-PMP, with consent) or the volunteer enters the address they forwarded TCP 3728 to (or a
  `wss://` name on a VPS). Behind carrier-grade NAT a home PC can't be a node, and the launcher says so.
* **Status:** being checked → verified (the NODE badge), with each check's result, bytes relayed,
  realms carried, and the maintainer's message.
* **Leaderboard choice:** not listed (still counted in the totals), "Anonymous node", or a display name.
* **Turn off:** one click. The server stops, the router mapping is removed, and the setting goes off.
  Closing the launcher also stops the node; it resumes next time only if the volunteer had it on and
  agreed to the current text (a changed explanation asks again).
* **In game:** Esc > Become a Node shows the launcher's last report (written to `Node/Status.lua` on
  every state change and picked up when the game starts). The window says that the game can't switch
  the node itself.

### Who sees what

| | sees |
|---|---|
| Players and hosts using a node | the node's IP address (as with seeding a torrent). **Never each other's.** |
| The node operator | the IP addresses connecting to it, which realm id each stream is for, when it opens and closes, and byte counts. **Not** chat, names, sign-ins or game content (sealed). The Python node writes no logs and keeps only counters. |
| Open Vanilla (directory) | each node's address (to send players there), caps and counters, which hosts it carries |
| Everyone (site, launcher, API) | tiers, names only by choice, rounded totals; no addresses, keys or ids |

## Supporter leaderboard

`launcher/p2p/leaderboard.py` (and `nodes.rs`) aggregate 30 days of per-node, per-day rows into
`www/community/nodes.json` / `GET /api/nodes/leaderboard`: `network` totals (verified/pending nodes,
GB relayed and seeded, regions), `supporters` ranked by relay GB + ½ × seed GB, then uptime. Relay
bytes are capped at what a node's own cap allows, so inflating counters doesn't help. Seeding bytes are
self-reported for now; cross-checking them against the tracker is listed in the patch notes. The
site shows the table (`www/nodes.html`), and the launcher shows the top 12 beside Become a node.

## Capacity: what nodes add, and what they can't

**What relays and nodes add:**

* **Connection capacity:** more simultaneous player connections across the network, spread over more
  machines and uplinks. One Hetzner relay handles thousands of streams (memcpy + TLS); each volunteer
  node adds about 50 players at the default cap.
* **DDoS absorption:** attacks hit relays, not hosts' homes. A small node can be overwhelmed, and the
  directory then moves its hosts (fall back to Open Vanilla's relay, assign another node). Large attacks
  need a provider's filtering (Hetzner's), which only the official relay has.
* **IP privacy:** hosts and players never see each other's addresses.
* **Reach:** hosts behind NAT/CGNAT become reachable. A node near the players or the host shortens the
  path, although any relay is one extra hop (about +5–30 ms in-region).

**What they can't do:**

* **One world server's CPU is the ceiling.** A realm is one `mangosd` process: every player, creature,
  bot and spell in that world runs there. Relays move bytes; they don't run game logic. A home host's
  realm is limited by that PC (and playerbots are the heavy part), and Open Vanilla's official realm by
  its box.
* **No splitting one world across nodes.** CMaNGOS has no cross-machine sharding of maps or instances,
  and the nodes don't hold characters or state. Making one world span machines would need a different
  server architecture. That is not on the table, so this doc doesn't pretend it is.
* **Relays don't reduce a host's upload:** the host still sends every player's stream once (to the relay
  instead of to the player).
* **Volunteer nodes are best-effort:** they come and go. The official relay stays the floor.

**Slices: how Open Vanilla grows instead.** A slice is one more realm (its own world server) that shares
Open Vanilla accounts through identity tokens. Players sign in once and play anywhere; characters belong to
each realm. Examples:

* **Seasonal rounds:** a fresh Classic+ realm per season, with the old one kept or archived.
* **Warfront PvP:** a PvP-focused realm (battlegrounds and world PvP events), which keeps its load off
  the main world.
* **Community realms:** players' own hosts, in the Community P2P tier, some promoted to Verified.

Every slice is listed in the realm list under its tier. Official slices run on Open Vanilla's servers
(direct, or through the relay for privacy and DDoS cover), and community slices on hosts' PCs. When
there are enough verified nodes, the directory spreads relayed slices across them, so no single relay
is the bottleneck or the single target.

## Where Open Vanilla is today

* **Live:** one official realm (Vanilla Remastered, Classic+) on the maintainer's Hetzner box; the
  desktop client connects directly and the browser through wenilla-realm's WebSockets.
* **In the launcher, working:** hosting for friends (Solo-based) with Direct and LAN. "Through Open Vanilla"
  (the relay) is hidden until live flag `relay`. Joining by invite link and by address, seeding.
* **Built, not deployed:** the relay (`relay/`), the directory, identity tokens and tracker (patch 0012),
  the node network (this doc: launcher code behind live flag `nodes`, patch 0018).
* **How players join slices once enough nodes exist:** Realms tab → pick a realm under its tier → Join.
  The launcher signs in with an Open Vanilla token, opens a sealed bridge to whichever relay the directory
  names (Open Vanilla's or a node), and starts the game. Private slices are joined from an invite link, and
  the route lookup finds the carrying relay.

## Test round (the maintainer's steps)

Each step can be undone on its own, and nothing reaches players until a live flag says so.

**Step 0: Open Vanilla's relay on the existing Hetzner box (no change to the realm or the launcher).**

1. DNS: an A (and AAAA) record for `relay.openvanilla.app` pointing at the realm server.
2. On the server, from a checkout: `bash hetzner/relay_up.sh`. This builds `relay/` and runs it as the
   container `openvanilla-relay`:
   * on the realm's Docker network, with no published ports;
   * limits: 1 CPU, 256 MB, 256 PIDs, read-only, no capabilities;
   * test-round limits per host: 32 streams, 256 KB/s, 5 GB/day.

   It also adds a `relay.openvanilla.app` site to the realm's Caddyfile (TLS, HTTP/3, no access log,
   `/metrics` hidden) and reloads Caddy. `openvanilla_realm_up.sh` keeps that site on re-runs. Firewall:
   nothing new; only 443 is used, which ufw already allows.
3. From your PC: `python tools/relay_smoke.py --gen`. Add the printed line to
   `/opt/openvanilla-relay/allow.txt`, then run `docker compose -p openvanilla-relay restart`.
4. `python tools/relay_smoke.py --relay wss://relay.openvanilla.app --host-id … --token … --plain`. It should
   print OK for the sealed and the plain round trip.
5. Watch: `docker stats`, `docker compose -p openvanilla-relay logs` (hashed addresses only).
   Undo: `docker compose -p openvanilla-relay down`, delete `/opt/openvanilla-relay/relay.env`, and re-run
   `openvanilla_realm_up.sh`.

**Step 1: hosts through the relay (needs patch 0012, test on staging first).**
Deploy 0012 with `DIRECTORY_ENABLED=1 DIRECTORY_PERSIST=1 IDENTITY_ENABLED=1`, and give the realm the
same `RELAY_VERIFY_SECRET` as `/opt/openvanilla-relay/relay.env` (the relay already points at
`http://realm:8090/api/directory/verify`). Then set `RELAY_HOST`/`RELAY_PLAYER_URL`. Flip live flag
`relay` to true and ask a few Discord testers to host "Through Open Vanilla".

**Step 2: the first nodes (needs patch 0018).** Deploy with `NODES_ENABLED=1` (and optionally
`NODES_LEADERBOARD_FILE=/srv/community/nodes.json`). Leave live flag `nodes` off. Run one or two test
nodes yourself (a second cheap VPS with a `wss://` name, or your PC with a forwarded port), starting
the launcher with `OPENVANILLA_NODES=1`, which turns the network on for that launcher only. Hosts and
players in the test also start with `OPENVANILLA_NODES=1`. After 3 days, check
`GET /admin/api/nodes` and approve: `POST /admin/api/nodes/verify {"node_id","decision":"approve"}`.

**Step 3: volunteers.** Post the news item, flip live flag `nodes` to true, approve nodes as they pass
their checks, and watch uptime and reports. Undo: flags `nodes`/`relay` back to false. Hosts return to
the official relay or to Direct within a minute, and nodes can't be turned on any more.

**Needs the maintainer's go:** DNS and `relay_up.sh` on the live box; deploying 0012 and 0018; flipping
live flags. None of it was done here.

## Tests

* `python3 -m unittest tests.test_node_network`: e2e (RFC 7748 vector, tamper, replay, wrong key),
  tiers and the status flow, leaderboard aggregation and its privacy, the node state machine, the
  relay node forwarding with fakes (sealed only; the node's tap never sees plaintext; tickets,
  private invites, daily cap, signed info), a host put on a node with a player joining sealed through
  it, fallback to Open Vanilla's relay, the service (consent, reachability, verified, revoked, one-click
  off, the game status file as valid Lua 5.0), and `tools/relay_smoke.py` against the real relay
  binary when it is built.
* `xvfb-run -a python3.12 -m unittest tests.test_p2p_gui`: the Become a node tab (waits for the test
  round, explanation first, one-click off, leaderboard) and the tab list.
* `lua5.1 devkit/sim/run_tests.lua`: `tests/node.lua` (Esc menu button, window, status states).
* `cargo test` in `relay/`: the `e2e` flag reaches the agent.
* Patch 0018: `cargo test -p wenilla-realm` (nodes unit tests; tests/p2p.rs unchanged and passing).
