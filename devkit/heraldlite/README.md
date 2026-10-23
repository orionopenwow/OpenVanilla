# Herald Lite

A headless command-line client for a Vanilla (CMaNGOS classic) realm: no graphics, no game data.
It logs in, enters the world as a character, talks to the server, checks what comes back, and
prints one JSON report. It is the fast test bot for Open Vanilla.

It is built on wenilla's own protocol crate, `benilla-protocol` (SRP6 logon, world handshake, header
encryption, packet codecs, the `SMSG_UPDATE_OBJECT` decoder), pinned to wenilla commit
`def2a7b026b9ac7e615f49f52841532b7ab5b0c4`. It sends the same bytes the browser client sends.
It does not pull in Bevy, wgpu, Lua or any asset code. The whole dependency tree is 82 crates.

**Autopilot:** `heraldlite autopilot` is a questing and combat bot for QA on our own realm. It
plays a `tools/autopilot` route: Northshire for a Human Hunter, levels 1 to about 5. See
[AUTOPILOT.md](AUTOPILOT.md).

## How it connects

```
direct mode:   heraldlite ─ loopback bridge ─ TCP ────────────────────────────────▶ realmd:3724 / mangosd:8085
web mode:      heraldlite ─ loopback bridge ─ wss://<realm>/ws/{3724|8085} (relay) ─▶ realmd / mangosd
                     └─ POST /login (cookie) → GET /api/play (game credential)
```

- **Direct mode** (`--host`) uses a game account name and password, the same as a native Vanilla
  client. Use it for a local or staging realm, or on the server box itself. In production,
  realmd and mangosd can't be reached from outside, and only the relay can dial them.
- **Web mode** (`--web`) uses a web account and logs in the way the play page does:
  1. `POST /login` with `username` and `password`. The service answers `303` with a
     `wr_session` cookie. The login form has no CSRF token.
  2. `GET /api/play` sends that cookie and `X-Requested-With: wenilla`. The service returns
     `{user, pass, host, realm, char?}`: the game account it provisioned for this web user, its
     password, the realm name, and an optional preset character.
  3. The client opens the cookie-gated WebSocket relay at `/ws/3724?host=<host>`, then
     `/ws/8085`. The world port comes from the realm list address, which is how the browser maps
     `REALM_DOMAIN:8085` to `/ws/8085`. The relay is a raw byte pipe, so SRP6 and the world
     protocol run through it unchanged.

  This flow comes from `crates/wenilla-realm/src/{auth/local.rs, api.rs, session.rs, csrf.rs}`,
  `templates/play.html` and `crates/wenilla-host/src/ws.rs` at the pinned commit.
- In both modes the protocol code dials a loopback **bridge**, which pipes the bytes to the real
  upstream. This lets the unmodified native transport of `benilla-protocol` work over a
  WebSocket. It also lets a session be closed cleanly and gives the byte counters in the report.

In the world, the client acts like a Vanilla client:
- It sends `CMSG_PING` every 30 s.
- It acks teleports, worldports, forced speed changes, mover modes (root, water walk, etc.) and
  cinematics.
- It asks for player names (`CMSG_NAME_QUERY`) when needed.
- It sends `CMSG_LOGOUT_REQUEST` and waits for `SMSG_LOGOUT_COMPLETE`.

## Build

### Windows

1. Install Rust with rustup from https://rustup.rs. Use the default MSVC toolchain. It needs the
   "Desktop development with C++" Build Tools, which rustup offers to install.
2. In this folder, run:

```powershell
cargo build --release
# -> target\release\heraldlite.exe
```

The first build downloads the wenilla repository through Cargo's own git, so `git` doesn't need
to be installed. On a fresh machine the build takes about a minute. If a proxy breaks the git
fetch, set `CARGO_NET_GIT_FETCH_WITH_CLI=true`.

Linux and macOS build the same way. The wenilla workspace pins Rust 1.98.1 in
`rust-toolchain.toml`. That file doesn't apply to a git dependency, and Herald Lite was built and
tested with stable Rust 1.97.0.

To run the offline test suite:

```powershell
cargo test
```

## Run

Pass passwords through the environment, not the command line.

**Staging or live (web mode):**

```powershell
$env:HL_WEB  = "https://staging.openvanilla.app"   # or https://play.openvanilla.app
$env:HL_USER = "herald-bot"                    # the WEB login
$env:HL_PASS = "..."
.\target\release\heraldlite.exe -s scenarios\smoke.txt --pretty
.\target\release\heraldlite.exe -s scenarios\smoke.txt -s scenarios\skills.txt
```

The game account behind that web login must own the character, which defaults to `Herald`. A web
account that still has an admin-issued first password is sent to `/account/password` by the
service. Change that password in a browser first; Herald Lite reports this case.

**Direct (a local realm, or on the server box):**

```powershell
.\target\release\heraldlite.exe --host 127.0.0.1 --user HERALD --pass ... -s scenarios\smoke.txt
# realmd advertises the public domain; on the box, point the world connection at loopback:
.\target\release\heraldlite.exe --host 127.0.0.1 --world 127.0.0.1:8085 --user HERALD ...
```

| flag | env | meaning |
|---|---|---|
| `--host <h[:port]>` | `HL_HOST` | direct mode: realmd address (default port 3724) |
| `--web <url>` | `HL_WEB` | web mode: the realm service URL |
| `--user`, `--pass` | `HL_USER`, `HL_PASS` | game account (direct mode) or web login (web mode) |
| `--char <name>` | `HL_CHAR` | character when a `login` line names none. Default order: the web preset, then `Herald` if the account has one, then the first character |
| `--realm <name>` | `HL_REALM` | realm to pick. Default: the web credential's realm, then the first realm listed |
| `--world <h:port>` | `HL_WORLD` | direct mode: override the world address from the realm list |
| `-s, --scenario <file>` | | scenario files, run in order. With none, the client logs in and logs out |
| `--timeout <s>` | | connect timeout, and the default `within` for `expect` (10 s) |
| `--logout-timeout <s>` | | how long `logout` waits (30 s; logout outside a rested area takes 20 s) |
| `-v, --verbose` | | progress, every chat line, notices and skipped packets on stderr |
| `--pretty` | | pretty-print the JSON |
| | `HL_USER2`, `HL_PASS2`, `HL_CHAR2` | the account for client `[b]` (same kind as `--user`) |
| | `HL_USER_<X>`, `HL_PASS_<X>`, `HL_CHAR_<X>` | the account for client `[x]` |
| | `HL_CA_FILE` | an extra PEM CA bundle for TLS. Mozilla's roots are built in |
| | `HL_CREATE` | `<race>:<class>` (ChrRaces / ChrClasses ids, e.g. `3:3` Dwarf Hunter): create the character a client logs in as when its account lacks it. For test realms |
| | `HL_CREATE_<X>` | the same for client `[x]` only (`HL_CREATE_A`, `HL_CREATE_B`), before `HL_CREATE` |

**Exit codes:**

| code | meaning |
|---|---|
| 0 | every step passed |
| 1 | a step failed, or bad usage or a bad scenario file |
| 2 | could not get in: a web login, realmd, world handshake or character login failed |

**Report:** one JSON object on stdout.

```json
{"ok":true,"exit":0,"pass":6,"fail":0,"failures":[],"mode":"web","target":"https://staging.openvanilla.app",
 "characters":[{"name":"Herald","guid":16,"level":5,"race":1,"class":3,"zone":1519,"map":0}],
 "ms":1840,
 "clients":[{"label":"a","game_account":"...","realm":"...","timings":{"web_ms":310,"auth_ms":95,"world_ms":60,"char_enum_ms":30,"enter_world_ms":420},
             "bytes_up":476,"bytes_down":16610,"packets":41,"packets_skipped":0,"characters":[...]}],
 "scenarios":[{"name":"smoke.txt","pass":6,"fail":0,"skipped":0,"ms":1700,
   "steps":[{"line":4,"client":"a","step":"login","ok":true,"ms":700,"detail":"in world as Herald on ..."}, ...]}]}
```

Each entry in `failures` is one line: `file:line [client] step: reason`. For example:
`skills.txt:8 [a] expect skill guns within 2s: timed out after 2.0s: guns (46) missing; the player has skills [45, 44, 98]`.

## Scenario syntax

Scenarios live in `scenarios/*.txt`, with one action or check per line.

- Lines starting with `#` and empty lines are skipped.
- A leading `[b]` runs the line on a second client (`a` is the default).
- `${VAR}` and `${VAR:-default}` expand from the environment.
- Durations look like `500ms`, `5s` or `2m`, or a bare number of seconds.

| line | does |
|---|---|
| `login [Name]` | connect (web, then realmd, then world), then enter the world as Name |
| `logout` | send `CMSG_LOGOUT_REQUEST`, wait for `SMSG_LOGOUT_COMPLETE`, close the connection |
| `send <text>` / `say <text>` | say a line in the character's language. Dot-commands like `.wnl hi` go this way |
| `yell <text>`, `whisper <Name> <text>` | other chat lanes |
| `join <channel> [password]`, `leave <channel>` | `CMSG_JOIN_CHANNEL` / `CMSG_LEAVE_CHANNEL` |
| `say-channel <channel> <text>` | a channel line |
| `wait <dur>` | keep every client alive for a while |
| `find npc <entry> [within <dur>]` | wait until a creature with that entry is in view. It becomes the target. The detail shows its guid and distance |
| `target npc <entry>` | `CMSG_SET_SELECTION` on it |
| `vendor list` | `CMSG_LIST_INVENTORY` on the target |
| `buy <item> [count]` | `CMSG_BUY_ITEM` from the target |
| `expect wnl <TAG> [matches <re>] [within <dur>]` | a `WNL` message with that tag, with chunks already reassembled |
| `expect <say\|yell\|party\|whisper\|system\|emote\|any> [from <Name>] [matches <re>] [within <dur>]` | a chat line |
| `expect channel <channel> [from <Name>] [matches <re>] [within <dur>]` | a channel line. `from` is resolved through name queries |
| `expect joined <channel>` | the `YOU_JOINED` notice for that channel |
| `expect vendor-item <item>` | the target's `SMSG_LIST_INVENTORY` lists the item |
| `expect bought <item>` | `SMSG_BUY_ITEM` or the item arriving. `SMSG_BUY_FAILED` fails the step with the reason |
| `expect skill <name\|SkillLine id>` | the player's `PLAYER_SKILL_INFO` has that skill. Names include `bows guns axes daggers swords maces thrown crossbows defense ...` |
| `target self` | select your own character (for GM commands that act on the selection, like `.die`) |
| `bg join <map id>` | `CMSG_BATTLEMASTER_JOIN` through the target battlemaster (`find npc` first). Maps: 489 Warsong Gulch, 529 Arathi Basin, 30 Alterac Valley |
| `bg accept` / `bg leave` | `CMSG_BATTLEFIELD_PORT` for the last invite / `CMSG_LEAVE_BATTLEFIELD` |
| `expect bg <queued\|invited\|in> [map <id>]` | an `SMSG_BATTLEFIELD_STATUS` with that status |
| `expect map <id>` | the client is on that map (after a worldport) |
| `expect near <x> <y> <z> <radius>` | the player stands within `radius` yards of the point |
| `expect faction <id>` | the player's own `UNIT_FIELD_FACTIONTEMPLATE` (Human 1, Orc 2, Dwarf 3, Night Elf 4, Undead 5, Tauren 6, Gnome 115, Troll 116) |

**Run-time variables** (for lines whose values only the server knows, like an instance id):

| line | does |
|---|---|
| `expect ... matches (?P<name>re)` | a met expectation's named groups become variables |
| `set <var> <value>` | set one (`%{other}` allowed in the value) |
| `%{var}` anywhere in a line | replaced when the line runs (the report shows `ran: <line>`) |
| `check <a> <op> <b>` | compare: `==` `!=` `<` `<=` `>` `>=` (as numbers when both are) or `~` (a regex). An operand is a literal, `%{var}`, or `field(var,key)`: the value after `key=`, `key:` or `key ` in the variable's text (a `k=v,k=v` line read by key, whatever its order) |
| `reject <expectation>` | passes when nothing matches during the whole `within` (default: `--timeout`) |
| `try <line>` | the line's failure becomes a skip (`"skipped": true`, not counted as a failure) |
| `when <var> <line>` | runs the line only when `var` is set; otherwise a skip. `set why_<var> <reason>` names why it may be missing |

The report's `vars` holds the variables at the end; `skipped` counts the skips.

How `expect` works:

- It also sees lines that arrived **before** it ran, as long as they are still unconsumed. Each
  matched line is consumed, so two `expect wnl LG` lines need two `LG` messages.
- `matches` takes the rest of the line as a regex. Only a trailing `within <dur>` is split off.
- Regexes use `regex-lite` syntax.

**WNL parsing** follows `WenillaCore.lua`:

- The line text starts with `WNL\t` (or `WNL `). The server sends it as `CHAT_MSG_PARTY` with
  `LANG_ADDON` from the player's own guid; the parser also accepts system and whisper lines.
- The text continues `<TAG> <payload>`.
- For `HI`, the payload is `<version> <addons>` and is never chunked.
- Every other tag is chunked as `<seq> <i>/<n> <part>` and reassembled per `(tag, seq)`.
- `LG` is `<item>,<median>,<vendor price>,<samples>` (the answer to `.wnl lg <item>`).

After each scenario, any client still in the world is logged out. That cleanup isn't counted as
a step.

### Shipped scenarios

| file | checks | needs |
|---|---|---|
| `smoke.txt` | login, the server's `HI` greeting, `.wnl hi`, `.wnl lg 2589` gives a well-formed `LG`, logout | any Open Vanilla realm with the WNL hook |
| `skills.txt` | Bows, Axes, Guns and Daggers in the player's skill fields | a Human Hunter. A fresh one may lack Guns and Daggers on some cores; the failure lists the skills the character actually has |
| `persona_pair.txt` | two clients join `OWPersona` and exchange `#P` and `?P` lines in `Persona.lua` format; `from` is checked by name | `HL_USER2`/`HL_PASS2` (a second account), and both characters in the same faction |
| `warfront_smoke.txt` | the Warfront hello, a kit, the gear picker, enchants, refusals, the shop, the arena queue | a level 60 Warfront Hunter (`HL_KIT` for another class) |
| `warfront_live.txt` | the live counts line, and a queue showing up in it | a Warfront character, nobody else in the 2v2 skirmish queue |
| `warfront_streak.txt` | a streak ended by a non-player death pays nothing and tells the zone | a GM account (the `streak` test hook, `.die`) |
| `warfront_sets.txt` | share, find, vote for and apply a gear set | two accounts, characters of the same class |
| `warfront_ringoflaw.txt` | a full rated 1v1: Ring of Law landing, prep, fight, rating, home | two GM accounts; from one address `OpenVanilla.Warfront.Arena.SameAddressRated = 1` |
| `warfront_arena.txt` | rated 1v1 where the loser logs out (a loss, a 15 min lock) | as above; run it last |
| `warfront_wintrade.txt` | one address in the rated 1v1 queue twice is never matched | two accounts from one address, `SameAddressRated = 0` |
| `warfront_crossfaction_bg.txt` | two same-faction characters in Warsong Gulch end up on opposite sides; factions restored after | two administrator accounts (`.debug bg`); a test realm |
| `warfront_botfill.txt` | realm bots fill a battle and the player is told | realm bots on, a GM account |

## What is verified and what is not

**Verified here** (by `cargo test` and `cargo build --release`, offline):

- The unit tests (plus those for the autopilot, see AUTOPILOT.md):
  - the scenario parser, including every shipped file
  - WNL parsing and chunk reassembly
  - expectation matching and consumption: name-resolved `from`, skill slots read from
    `ObjectFields`, vendor and buy outcomes
  - HTTP parsing (chunked), cookies, `/api/play` JSON, form encoding and relay URLs
  - the TCP bridge, including byte counts and a dead-upstream report
- 11 end-to-end tests that run the real binary against an in-process fake realm (plus 2 for the
  autopilot: a scripted quest world over TCP, and the host allowlist):
  - **SRP6:** the fake realmd computes `B` from benilla-srp's verifier, checks the client's `M1`
    and returns `M2`.
  - **World:** the fake mangosd checks the `CMSG_AUTH_SESSION` digest against the SRP session key
    and uses header encryption both ways. It covers the character list, login, an
    update-object create with skill fields and a vendor create, WNL `HI` and `LG`, channels
    shared across two sessions, name queries, a gold vendor (the test-only
    `tests/fixtures/vendor_buy.txt`), and logout.
  - **Web:** a fake web service handles login, `/api/play` (chunked, with cookie rotation) and a
    cookie-gated `/ws/{port}` relay.
  - Runs: smoke, skills, the two-client pair and the vendor fixture pass in direct mode; smoke
    passes in web mode.
  - Failures: wrong password, unknown character, nothing listening and a bad web password exit
    with code 2; a missing skill and an unaffordable buy exit with code 1, each with a one-line
    reason.

**Not verified** (needs a live server; this sandbox can't reach the Open Vanilla hosts):

- A real CMaNGOS realmd and mangosd. The packet layouts are benilla-protocol's, which wenilla uses
  in production, but my fake server is built from those same codecs, so it can't catch a mismatch
  between the codecs and CMaNGOS.
- The real web service behind Caddy: TLS, HTTP/1.1 through Caddy, its exact redirects, the
  `/api/play` rate limit (30/min per session) and the real relay.
- Open Vanilla's hook behaviour:
  - the timing of `HI`
  - whether `.go xyz` is allowed for the bot account
- Which weapon skills a fresh Human Hunter really has on this realm.

## Open points

- **Warden:** if the world server sends `SMSG_WARDEN_DATA`, the session is refused, as in
  wenilla. The browser client works on Open Vanilla, so Warden should be off there.
- **One world connection per login:** after `logout` the client closes its connection. The next
  `login` reconnects from scratch (web login, realmd, world). The protocol crate's split writer
  has no `CMSG_CHAR_ENUM`/`CMSG_PLAYER_LOGIN`, so the client can't re-enter from character select.
- **Movement:** scenarios only stand still. To move a scenario client, use GM `.go` commands.
  The autopilot moves on its own.
- **Channels:** custom channels are per-faction in Vanilla unless the realm allows cross-faction
  channels.
- **Web accounts:** each `[x]` client in web mode needs its own web account, and each `login`
  costs one `/api/play` call.
