# Dev proxy

Play the live realm in your browser, with the page layer and the Classic+ addons coming from
your own checkout. Edit a file, reload the page (or type `/reload` in game for addon code), and
you see the change. Nothing is rebuilt, nothing is uploaded.

## Run it (Windows)

```
py -3 -m pip install aiohttp
cd C:\path\to\openvanilla
py -3 devkit\proxy\devproxy.py
```

Open http://localhost:8080/ in Chrome or Edge and sign in with your **web password**.
Discord sign-in does not work through the proxy (Discord sends you back to play.openvanilla.app).

Options:

| option | default | what it does |
|---|---|---|
| `--upstream URL` | `https://play.openvanilla.app` | the realm to forward to |
| `--port N` | `8080` | local port |
| `--repo DIR` | `.` | the openvanilla checkout |
| `--https` | off | serve `https://localhost:PORT` with a self-signed cert (needs `pip install cryptography`; the browser warns once). Not needed for Chrome/Edge, which treat `http://localhost` as secure. |
| `--insecure` | off | don't verify the upstream's certificate (a test realm on Caddy's internal CA) |
| `--no-data-overlay` | off | forward every `/data` request untouched |
| `-v` | off | print each file served from disk |

## What comes from your disk

| URL | file |
|---|---|
| `/ow/<file>` | `realm/www/<file>` (falls through to the realm if you don't have it) |
| `/bridge.js` | `realm/classicplus/bridge.js` |
| `/addons-loader.js` | `realm/classicplus/addons-loader.js` |
| `/login-backdrop.*` | `realm/login-backdrop/*` |
| `/data/Interface/AddOns/...` | `Data/Interface/AddOns/...` |
| `/data/Interface/ClassicPlus/...` | `Data/Interface/ClassicPlus/...` |
| `/data/__addons` | a live listing of your `Data/Interface/AddOns` |
| `/data/__index` | the realm's file list plus every local addon/ClassicPlus file |

Addon files are matched however the game spells them: `/data/Interface/AddOns/X/a.lua` (the
loader), `/data/Interface%5CAddOns%5CX%5Ca.lua` (the game's own reads), any upper/lower case.
So a new `.lua` file works as soon as it is listed in the `.toc` — no patch-Z rebuild.

Local files are sent with `Cache-Control: no-store`. Addon files that still come from the realm
get `no-cache` instead of the realm's year-long cache, so creating a local copy later takes
effect at once.

Everything else — the play page, the wasm, game data, `/login`, `/api/*` and the `/ws/*` game
connection — goes to the realm with your session cookie.

## What it fixes up on the way

- **Cookie**: the realm's `wr_session` cookie (`Path=/; HttpOnly; Secure; SameSite=Lax`, no
  `Domain`, no `__Host-` prefix) loses `Domain` and, on plain http, `Secure`.
- **Redirects** to the realm's own address point back at the proxy.
- **Origin/Referer** are rewritten to the realm's address on the way up (the realm rejects
  `Sec-Fetch-Site: cross-site` POSTs and WebSocket upgrades; the browser sends `same-origin`,
  which passes).
- **HSTS and Alt-Svc** from Caddy are dropped, so `localhost` is never pinned to https or QUIC.
- **CSP**: the realm sends none today; if it ever does, its own origin is rewritten to localhost.
- **Compression**: realm responses are passed through still compressed (the 15 MB brotli wasm
  stays 15 MB); local files are sent uncompressed, so a stale `bridge.js.br` can never win.

## Test

```
py -3 -m pip install pytest
py -3 -m pytest devkit\proxy\test_devproxy.py      (or: py -3 devkit\proxy\test_devproxy.py)
```

`fake_realm.py` is a small stand-in for the realm (login form, the real cookie flags, `/data`,
`/data/__index`, a `/ws` echo, a CSP and HSTS header). The test starts both and checks the
overrides, the login, the cookie, the WebSocket and the merged listings.
