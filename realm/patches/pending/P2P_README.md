# 0012 — directory, identity tokens, tracker (pending, NOT deployed)

`0012-openvanilla-directory-identity-tracker.patch` adds `crates/wenilla-realm/src/p2p/` to wenilla-realm:
the community-realm directory with its reachability probe, PASETO identity tokens, the signed
revocation list, realm reports to Discord, staff delist and verify, and a restricted BitTorrent tracker.
Apply it on wenilla `def2a7b0` after `0001`–`0011` (`git apply` in order). It adds no SQL
migration: all of its state is in files in the state dir, so rolling back leaves the sqlite file
compatible.

**Every part is off by default.** While a switch is off, its routes are not mounted, and the
service behaves exactly as it did with 0011.

## Environment

| Variable | Default | Meaning |
|---|---|---|
| `DIRECTORY_ENABLED` | off | `1` mounts `GET /api/directory`, `POST /api/directory/heartbeat`, `POST /api/directory/report`, `GET /admin/api/directory`, `POST /admin/api/directory/{delist,verify}` |
| `DIRECTORY_PERSIST` | off | `1` also keeps claims (token SHA-256, host ids, last probe) in `<state>/directory-state.json`, saved every 60 s, so hosts keep their token across a restart. Without it, claims live in memory only, and after a restart every agent has to claim again |
| `DIRECTORY_REPORT_WEBHOOK` | — | Discord webhook URL (https) that receives reports. When it is unset, reports go only to the log and to the `audit` table |
| `DIRECTORY_WORDLIST` | — | File of words (one per line, `#` comments) refused in names, descriptions and tags |
| `RELAY_HOST` | `relay.openvanilla.app` | `host` shown in listed entries of relayed hosts |
| `RELAY_PLAYER_URL` | `wss://relay.openvanilla.app` | Relay player side: the probe and `relay_url` use `<this>/h/<host_id>/ws/3724` |
| `DIRECTORY_PROBE_TIMEOUT_SECS` | `5` | Probe connect+reply budget |
| `DIRECTORY_MAX_CLAIMS` | `2000` | Total claims (503 beyond) |
| `RELAY_VERIFY_SECRET` | — | Shared secret with the relay. When set (and the directory is on), mounts `GET /api/directory/verify` |
| `DIRECTORY_ALLOW_PRIVATE` | off | Accept loopback/RFC 1918 hosts. **Only for tests and LAN labs. Never set it in production** (with it set, the probe can reach internal addresses) |
| `IDENTITY_ENABLED` | off | `1` mounts `GET /.well-known/openvanilla-keys.json`, `POST /api/identity/token`, `GET /api/identity/revoked`, `POST /admin/api/identity/{revoke,rotate}` |
| `IDENTITY_TOKEN_TTL_SECS` | `300` | Token lifetime (clamped to 30–3600) |
| `TRACKER_ENABLED` | off | `1` mounts `GET /announce` |
| `TRACKER_ALLOWLIST` | `<state>/torrents.allow` | Allowed info-hashes, 40 hex characters per line (`#` comments). It is re-read within 5 s of a change. Any other hash gets `failure reason` |
| `TRACKER_INTERVAL` | `1800` | Announce interval (`min interval` = half) |
| `TRACKER_MAX_PEERS` | `50` | Peers per reply (cap 200). Each swarm is also capped at 5000 remembered peers, and peers expire after 2 intervals |

`<state>` is `REALM_STATE_DIR` (`/state` in the container).

Fixed limits: heartbeats are 30/min per address, 5 new claims/hour per address and 1 beat per entry per 20 s, with a 4 KB body.
An entry is listed 180 s after its last heartbeat at most, and a claim lasts 24 h. The probe is valid for 30 min and is
re-run every 10 min (a failed probe is retried after 30 s). Reports are limited to 5/hour per account and 20/hour per address.
Tokens are limited to 30/min per account.

Client addresses come from `X-Forwarded-For`. The production Caddyfile sets it to `{remote_host}`,
which overwrites any value a client sends. Keep it that way: the rate limits and the tracker's peer
addresses depend on it.

## API notes (the parts of the contract that were left open)

- **Heartbeat** follows `docs/P2P_NETWORK.md`, plus these fields: `visibility` (`public` | `private`, default
  public), `relay` (bool), `template` (`classicplus` | `vanilla`, default classicplus) and `region`
  (`us` only). With `relay: true`, `host` and `port` may be left out. `build` must be 5875. Replies
  (201 on a new claim, which also carries `token`):
  `{"host_id","ttl":180,"heartbeat_every":60,"listed",bool,"verified",bool,"probe":{"ok","at","error"}}`.
  The first heartbeat waits for the probe, so the agent gets its self-test result straight away.
- **List entries** add `host_id`, `type`, `template`, `region`, `verified`, `official:false`, `relay`,
  `version`. Relayed entries also carry `relay_url` (`<RELAY_PLAYER_URL>/h/<host_id>`) and list
  `host = RELAY_HOST`, `port = 3724`. The directory sets the tags `community`, a type tag (`PvE`/`PvP`/`RPPvE`/`RPPvP`) and,
  for classicplus, `Classic+`. Players cannot claim these, nor `official`/`verified`/`relay`. Verified entries sort first.
- **Relay verify**: `GET /api/directory/verify?host_id=<16 base32>&token_sha=<64 hex>` with
  `Authorization: Bearer <RELAY_VERIFY_SECRET>` (compared in constant time; 401 when wrong). It returns
  `{"ok":true,"visibility":"public"|"private"}` when `token_sha` matches the stored SHA-256 of the claim token
  and the claim is live (less than 24 h since the last heartbeat) and not delisted; otherwise `{"ok":false}`.
  The endpoint is not mounted without the secret. Generate the secret with `openssl rand -hex 32` and set the same value
  on the relay.
- **Probe**: sends `AUTH_LOGON_CHALLENGE` (1.12.1, build 5875, account `PROBE`) and accepts any
  `00 00 <result ≤ 0x20>` reply. Names that resolve to non-public addresses are refused.
- **Identity token**: PASETO `v4.public`. Footer `{"kid":"<16 hex>"}`, empty implicit assertion.
  Claims: `iss` (REALM_PUBLIC_URL), `sub` (account id **as a string**), `name`, `roles` (`["player"]`,
  plus `"staff"` for admins), `aud`, `iat`, `exp`, `jti` (32 hex). **`iat`/`exp` in the token are RFC 3339 UTC
  strings** (`2026-10-15T12:00:00Z`), as PASETO registers them. Only the HTTP reply's `exp` is unix seconds.
  The endpoint accepts the session cookie or the launcher's `Authorization: Bearer <launcher token>`. Revoked or disabled
  accounts get 403.
- **Revocation list**: body `{"updated":<unix>,"sub":["<id>",…]}`. It lists staff-revoked accounts and
  disabled users. The signature is Ed25519 over the exact body bytes, sent in `X-OpenVanilla-Signature` (base64url, no padding). The signing key
  is in `X-OpenVanilla-Kid`.
- **Staff endpoints** are behind the existing session and admin gate, and also need the session's CSRF
  token in `X-CSRF-Token`. Body: `{"target":"<host_id or host>","on":true|false}` for delist (a host id
  also blocks that entry's direct address) and verify (host id only); `{"sub":<id>,"on":bool}` for
  revoke; rotate takes no body. Every action is written to `audit`.

## Keys

The identity keys are created on the first start with `IDENTITY_ENABLED=1`, in `<state>/identity/`:
`<kid>.key` (hex Ed25519 seed, mode 0600) and `active` (the kid that signs). `kid` is the first 8 bytes of
SHA-256(public key), written as hex. Back up `<state>/identity/` the same way as `master.key`. If the key is lost, hosts have to
fetch the keys document again (they do every few minutes) and tokens already in flight fail. Nothing else is lost.

- Rotate: `POST /admin/api/identity/rotate` (admin session + `X-CSRF-Token`). The new key starts signing at once.
  The old key stays published, so tokens that are still alive keep verifying.
- Retire an old key after at least `IDENTITY_TOKEN_TTL_SECS` + the hosts' key-cache time (about 15 min):
  `mv <state>/identity/<kid>.key <state>/identity/<kid>.retired`, then restart the service.
- Bring your own key: write the 32-byte seed as hex to `<kid>.key`, using the kid computed as described above,
  and put that kid in `active`. If the name does not match the key, the service refuses to start.

## Deploy (when approved — not done)

1. Build wenilla-realm from `def2a7b0` with patches 0001–0012 applied. Rebuild the realm image the usual way.
2. Put the switches in the realm service's environment (`.env`/compose), starting with just
   `DIRECTORY_ENABLED=1` and `DIRECTORY_PERSIST=1`. Before turning on the tracker, create the allowlist:
   `touch /state/torrents.allow`, then add the info-hashes of Open Vanilla's own torrents (patch-Z, launcher)
   **only**.
3. Set `DIRECTORY_REPORT_WEBHOOK` to the Herald's staff channel webhook.
4. Restart the realm container. Check that:
   `curl -s https://play.openvanilla.app/api/directory` returns `{"servers":[],…}`, and with identity on,
   `curl -s https://play.openvanilla.app/.well-known/openvanilla-keys.json` lists one key.
   `curl -s 'https://play.openvanilla.app/announce?info_hash=%00'` should return a bencoded failure.
5. Caddy needs no change: it already proxies every path to the realm and overwrites `X-Forwarded-For`.

## Rollback

- To turn a part off: remove its `*_ENABLED` variable and restart the service. Its routes return 404 again.
- To remove the code: rebuild from 0001–0011 only. The patch has no migration, so the sqlite file stays valid.
  The files it creates (`directory-state.json`, `directory-staff.json`, `identity/`, `torrents.allow`) can stay;
  the old build ignores them. Keep `identity/` if the feature will come back, so that hosts' cached keys stay valid.

## Tests

`cargo test -p wenilla-realm` covers:
- unit tests for validation, listing rules, packet shape, address policy, the PASETO v4 official vector 4-S-1,
  rotation/revocation and bencode/announce;
- `tests/p2p.rs`, which runs a fake realmd and a fake relay WebSocket for the probe and covers claim, token and
  limits, private entries, reports to a fake webhook, staff verify/delist with CSRF, tokens by cookie and by
  launcher bearer, the signed revocation list, rotation, and the tracker allowlist.

---

# 0018 — the node network: tiers, volunteer nodes, tickets, leaderboard (pending, NOT deployed)

`0018-openvanilla-node-network.patch` goes on top of 0012–0015 (checked: `git apply` of 0013, 0014, 0015,
0018 in order on the 0012 base). It adds `crates/wenilla-realm/src/p2p/nodes.rs` and small hunks in
`config.rs`, `directory.rs`, `identity.rs`, `mod.rs`. Design: `docs/NODE_NETWORK.md`; launcher side:
`launcher/p2p/node.py`, `tiers.py`, `leaderboard.py`, `e2e.py`. No SQL migration: state is
`<state>/nodes-state.json`. Built and tested here with `cargo check`/`cargo test -p wenilla-realm`
(lib p2p:: 19 passed incl. 6 new; tests/p2p.rs 6 passed, unchanged).

**Off by default.** `NODES_ENABLED=1` (needs `DIRECTORY_ENABLED=1` and `IDENTITY_ENABLED=1`, or the
service refuses to start) mounts the node routes. Without it the directory behaves as with 0015,
apart from the new optional heartbeat fields and list fields below, which are inert.

| Variable | Default | Meaning |
|---|---|---|
| `NODES_ENABLED` | off | Mounts `POST /api/nodes/heartbeat`, `GET /api/nodes`, `GET /api/nodes/leaderboard`, `GET /admin/api/nodes`, `POST /admin/api/nodes/verify` |
| `NODES_LEADERBOARD_FILE` | — | Also write the leaderboard there every minute, e.g. `/srv/community/nodes.json` (the Herald public dir Caddy serves at `/community/`) |

## Directory changes (always on with the directory)

- **Heartbeat** takes four more optional fields: `key` (the host key fingerprint, 16 base32), `e2e`
  (bool; needs `key`), `nodes` (bool: may be carried by a volunteer node) and `node_failed` (a node id
  the agent couldn't reach). The launcher only sends them when live flag `nodes` is on.
- **List entries** add `tier` (`verified` | `community`), `badges` (`verified`|`community`, `relayed`,
  `e2e`), and `key`/`e2e` when the host sent a key. A relayed entry's `relay_url` is the carrying
  node's `<url>/h/<host_id>` when it is on a node. A relayed entry never shows the host's address
  (unchanged: `host = RELAY_HOST`, port 3724).
- **`GET /api/directory/route/{host_id}`** (60/min per address): `{"relay_url","key","e2e"}` for a live
  relayed realm, public or private (private realms are joined by invite and never listed). 404 otherwise.
- **Assignment**: when nodes are on and a relayed host sent `e2e`+`key`+`nodes:true`, the heartbeat reply
  may carry `"relay": {"url","node_id","ticket"}` — a verified, accepting, fresh node with room
  (fewest hosts first; sticky while it stays usable; never the `node_failed` one). No usable node:
  no `relay` key, the agent stays on (or goes back to) Open Vanilla's relay. A host on a node is not probed
  through Open Vanilla's relay; it counts as reachable while the node's own heartbeat lists it in `carrying`.
- **Node ticket**: `v4.public`, signed with the active identity key, footer `{"kid"}`; claims
  `typ:"node"`, `aud` = node id, `sub` = host id, `vis` = `public`|`private`, `iat`/`exp` RFC 3339, 10 minutes.
  The agent sends a fresh one over the control socket on every heartbeat; nodes check them offline
  against `/.well-known/openvanilla-keys.json`.

## Nodes

- **Heartbeat** (`launcher/p2p/node.py heartbeat_payload`, unknown fields refused, 4 KB, 20/min per
  address, 3 new nodes/hour per address, 500 nodes max, one beat per 20 s): `node_id` must be the
  fingerprint of `key` (so nobody can register someone else's node), `url` `ws://host:port` or
  `wss://host` with a public host, caps, counters, `leaderboard` (`off`|`anonymous`|`named`),
  `display_name`, `carrying`. First beat: 201 with `token` (only its SHA-256 is kept). Reply:
  `{"node_id","status","message","checks":{name:{"ok","detail"}},"heartbeat_every":60}`.
- **Probe**: every 10 minutes, `GET http(s)://<node>/node?c=<nonce>`; the node must answer with its id,
  key and an Ed25519 signature over `OWNODE1|<node_id>|<nonce>`. Redirects are not followed. 30 days of
  results are kept for the uptime checks.
- **Status** (same rules as `launcher/p2p/tiers.py`): `unlisted` → `pending` once reachable → `verified`
  only by the maintainer, and only when every check passes (reachable + key proof, ≥ 3 days and ≥ 300
  probes, ≥ 95% uptime, protocol ≥ 1 with e2e required, caps ≥ 256 KB/s · 5 GB/day · 16 streams, rules
  accepted, no open reports). A verified node below 90% (7 days), unreachable or reported drops to
  `suspended` and comes back by itself when it passes again. `revoked` sticks until `unrevoke`.
- **Stats ingestion** (for the leaderboard): each beat's `relay_bytes_total`/`seed_bytes_total` become
  deltas on that node's UTC-day row (a restart resets the base); relay deltas are capped at what the
  node's own `kbps` allows for the elapsed time, so inflated counters don't help. Rows older than 30 days
  are dropped. Not done yet: cross-checking relay bytes against hosts' agents, seeding bytes against the
  tracker's announce totals (both are self-reported today and capped only by the node's caps).
- **`GET /api/nodes`** and **`GET /api/nodes/leaderboard`** (CORS `*`) never contain a URL, address, key,
  node id or account id; names only for `named`. The leaderboard has the `www/community/nodes.json`
  shape (`version`, `updated`, `window_days`, `network`, `supporters`, `privacy`; the site adds `tiers`
  from its own copy).
- **Maintainer**: `GET /admin/api/nodes` (full detail incl. URLs, checks, assignments) and
  `POST /admin/api/nodes/verify` `{"node_id","decision":"approve"|"revoke"|"unrevoke","message"}` behind
  the admin session + `X-CSRF-Token`; written to `audit`. The message is shown in the volunteer's launcher.

## Deploy (when approved — not done)

1. After 0012 is live (directory + identity on, relay verify secret shared with relay.openvanilla.app):
   build with 0018, set `NODES_ENABLED=1` and `NODES_LEADERBOARD_FILE=/srv/community/nodes.json`
   (mount the Herald public dir read-write into the realm container, or keep the default and let the
   site read `GET /api/nodes/leaderboard`).
2. Live flag `nodes` stays false until at least one maintainer-run test node is verified
   (docs/NODE_NETWORK.md, "Test round").
3. Rollback: unset `NODES_ENABLED` (routes 404; hosts on nodes get no `relay` in the next beat and go back
   to Open Vanilla's relay within a minute). `nodes-state.json` can stay.

Note (16 Oct): renumbered from 0016 to 0018. Your live folder now has 0016-openvanilla-sign-in and
0017-openvanilla-guest-accounts from other work; this patch was written against 0001-0015 and must be
re-checked on top of 0016-0017 before it moves to the live folder.
