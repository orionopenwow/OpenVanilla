# Load lab

Tools to measure how fast the realm loads, plus four changes that make it faster or cheaper.
Each change works on its own, is off by default where it carries risk, and can be measured
before and after with `measure.mjs --compare`.

## How the game loads today (what this is built on)

- The page downloads the client (`wenilla_bg.wasm`, ~15 MB brotli). It is served `no-cache`, so
  a returning player gets a 304 instead of the file.
- The game reads its data one file at a time from `/data/<name>`. There are two kinds of read:
  - **Synchronous reads** (`XMLHttpRequest`, the client's `Chain`). The URL uses `%5C` for `\`,
    e.g. `/data/DBFilesClient%5CSpell.dbc`. Most of the boot and the UI art.
  - **Asynchronous reads** (`fetch`, the client's Bevy asset reader). The URL uses `%2F` for `/`,
    and the names are lower-case except terrain, e.g. `/data/World%2FMaps%2FAzeroth%2FAzeroth_32_48.adt`,
    `/data/world%2Fazeroth%2F...%2Ftree.m2`. Terrain, models, world textures.
- `web/boot.js` already prefetches two lists into the browser's HTTP cache: `boot-manifest.json`
  (404 files, while the wasm downloads) and `world-manifest.json` (199 UI files, once the login
  screen is up). `/data` files are sent `immutable` for a year, so they stay in the HTTP cache
  until the browser evicts them.
- **Measured here (Chromium):** a service worker never sees synchronous XHR. Every sync read goes
  straight to the HTTP cache. This decides how the service worker below must behave.
- **Bug found:** files from `patch-Z.MPQ` (`Interface\AddOns`, `Interface\ClassicPlus`,
  `DBFilesClient` overrides) are also sent `immutable`. After a new patch-Z, a returning player
  keeps the old copies until the browser evicts them. Patch 0007 fixes this.

## Files

| file | what it is |
|---|---|
| `measure.mjs` | Playwright: cold run (fresh profile) and warm run (same profile, browser reopened). Records time to each screen, wasm bytes and time, the boot prefetch, and `/data` counts and bytes for boot, glue (login + character screens) and the first 60 s in the world, split into network / HTTP cache / service worker. Writes JSON, prints a table. `--compare a.json b.json` prints the differences. |
| `capture_manifest.mjs` | Enters the world with a fresh profile and records every `/data` URL for 60 s. Writes `manifests/<zone>.json` for the prefetch. |
| `realm/www/owdiag-load.js` | Herald routine `load`: the same numbers, read from inside the page (plus stages, the memory store and fetch-ahead). |
| `realm/www/sw.js`, `realm/www/sw-register.js` | The service worker and its on/off switch. |
| `realm/www/prefetch.js` | Prefetch at the login and character screens; the zone's sounds once in the world. |
| `realm/www/stages.js`, `syncread.js`, `ahead.js` | Stage timings and the hitch watch; the memory store for synchronous reads; fetch-ahead in the world (Open Vanilla 1.15, see `realm/patches/pending/README.md`). |
| `0006-openvanilla-lite-textures.patch` | Server: `?lite=1` serves world textures without their largest mip. |
| `0007-openvanilla-patchz-revalidate.patch` | Server: patch-Z files are revalidated instead of cached for a year. |
| `stub/` | A fake play page and server, used by the tests. |
| `test_loadlab.mjs` | The tests (40 checks, real headless Chromium). |
| `gate.mjs` | The load-time gate: `node gate.mjs now.json baseline.json` fails when a screen got more than 20% and 750 ms slower, or the downloads more than 10% bigger. Run by `packaging/workflows/loadgate.yml` after every hot update and realm image, and daily. |

The page files used to be staged in `page/` here; they now live only in `realm/www/` (the stub
serves them from there), so the tests always run against what ships.

Run measurements:

```
npm i playwright
set REALM_URL=https://play.openvanilla.app & set OWBOT_USER=owbot & set OWBOT_PASS=...
node devkit/loadlab/measure.mjs --out before.json
node devkit/loadlab/measure.mjs --query sw=1 --out after.json
node devkit/loadlab/measure.mjs --compare before.json after.json
```

`--until charselect` stops at the character screen. `--anonymous --url ...` skips the web sign-in,
for a dev host without the realm's login. `--query noprefetch=1` turns off boot.js's prefetch,
for an A/B test. Headless WebGPU uses SwiftShader, so time in the world is slow, but the
download counts and bytes are accurate.

Tests: `node devkit/loadlab/test_loadlab.mjs` (set `CHROMIUM` if Playwright's own browser is not
installed).

## Stages, repeats and the quality guard (Open Vanilla 1.15)

`ow/stages.js` marks each step of a visit in the page (ms since navigation): `engine` (first glue
screen), `login`, `charlist`, `world-enter` (loading screen up), `world-ready` (loading screen
cleared), `first-frame`, `sound-ready` (the deferred audio device opened), `first-move`; and it
records every frame gap over 100 ms in the first 30 s after `world-ready`. `world-enter`,
`world-ready` and `sound-ready` come from the engine (pending patches 0008/0009); an older client
falls back to the bridge's `inworld` state and has no `world-ready`/`sound-ready`.

In the page: `owStages.summary()`, or `await owdiag.snapshot(['load'])` (`stages`, `syncRead`, `ahead`).

```
# 10 cold runs: median and p90 of every stage, fail on any frame over 100 ms in the first 30 s
node devkit/loadlab/measure.mjs --runs cold --repeat 10 --max-hitches 0 --out ten.json

# Quality guard: a baseline screenshot after the world settles, then compare a change against it
node devkit/loadlab/measure.mjs --runs cold --world-secs 20 --shot base/
node devkit/loadlab/measure.mjs --runs cold --world-secs 20 --query lite=1 --baseline base/ --max-diff 2
```

`--repeat N` prints a second table (median / p90 per stage) and stores `stats` and `repeats` in
the JSON. `--baseline DIR` compares each settled screenshot with `DIR/<run>-0.png` (share of
pixels differing by more than 24/255 in any channel; fails above `--max-diff` %). Screenshots in
the world move with the time of day, NPCs and weather: use the guard for A/B runs taken back to
back from the same character and spot, and expect a few % of noise on a busy spot.

## The changes

| change | what it saves | on / off | risk |
|---|---|---|---|
| **Glue prefetch** (`prefetch.js`) | The world around where you last played: the map's WDT, the 3×3 terrain tiles around you, and the zone manifest if one was captured. These download while you sit at the login and character screens, not after you click Enter World. | On once added to `openvanilla.js`. Skipped on Save-Data, 2g/3g, `?noprefetch=1` and `?boottrace=1`. Stops when you enter the world, or after 80 MB. | Low. It uses a little bandwidth that may be wasted if you log in on a different character somewhere else. It waits for boot.js's own world prefetch to finish first. |
| **Service worker** (`sw.js`) | Keeps the asynchronous reads (terrain, models, world textures, sounds) in Cache Storage, which outlasts the HTTP cache and is covered by `navigator.storage.persist()`. Also applies lite textures and keeps patch-Z files in step with a data version. | Opt-in: `?sw=1` for one browser, or `"sw": "on"` in `/ow/data-version.json` for everyone. `?nosw=1` (one browser) or `"sw": "off"` (everyone) unregisters it and deletes its caches. | Medium. It needs a new Caddy header. It does not touch the synchronous reads, on purpose: answering boot.js's prefetch from Cache Storage would leave the HTTP cache cold for the sync XHR that follows. A cached file is stored twice (Cache Storage + HTTP cache) until the browser evicts the HTTP copy. Turn it on for everyone only after a `measure.mjs` comparison on the real realm. |
| **Lite textures** (patch 0006 + `sw.js`) | World textures larger than 64 px lose their largest mip: half the width and height, about 75% fewer bytes for those files. Applies to `World\`, `Creature\`, `Tileset\`, `Spells\`, `Item\ObjectComponents\`, `Dungeons\`, `Environments\`. | Needs patch 0006 on the realm and the service worker. `owsw.lite('on' / 'off' / 'auto')` or `?lite=1/0/auto`. `auto` turns it on for Save-Data or 2g/3g. | Low for the files it touches: textures are blurrier up close. Only the asynchronous reads get it (sync reads bypass the worker). UI, character skins, item skin components and minimap tiles are excluded, because the client lays those out by pixel size (the body atlas composites fixed 256² rectangles). |
| **patch-Z revalidation** (patch 0007) | Fixes stale addons and DBC overrides after a patch-Z update. Those files are fresh for an hour, then revalidated with an ETag (a 304, no body, when unchanged). | Server patch; nothing to switch. | Low. A patch-Z file not in the boot prefetch, read after the hour, costs one round trip. The boot set is revalidated in parallel by boot.js's prefetch. |
| **HTTP/3** | Faster connection setup and less head-of-line blocking on lossy links. Matters most for the 4–8 parallel `/data` fetches. | Caddy has it on by default. It needs UDP 443 open (see below). | Low. Browsers fall back to HTTP/2 by themselves. |

Measured on the stub (not the realm): a warm run made 0 `/data` network requests at boot (all
from the HTTP cache), and the wasm came back as a 304. With the service worker on, the warm run's
30 asynchronous world reads were answered from Cache Storage, and the 6 sync reads still came from
the HTTP cache. These numbers only show that the plumbing works. Real gains have to be measured
against the realm with `measure.mjs`.

## Edits to make (I did not touch realm/www or hetzner/)

**1. Copy the page files** to `realm/www/`: `sw.js`, `sw-register.js`, `prefetch.js` and
`owdiag-load.js`. Captured manifests go in `realm/www/manifests/` (they are served at
`/ow/manifests/`).

**2. `realm/www/openvanilla.js`**: add these lines after `function diag(...)` and before `export function install`:

```js
// -- Loading: glue prefetch, service worker (opt-in) -------------------------------------------

function loading(wenilla) {
  import(BASE + 'prefetch.js').then((m) => m.installPrefetch(wenilla)).catch((e) => console.warn('ow/prefetch.js:', e));
  import(BASE + 'sw-register.js').then((m) => m.installServiceWorker()).catch((e) => console.warn('ow/sw-register.js:', e));
}
```

Inside `install(wenilla)`, add:

```js
  try { loading(wenilla); } catch (e) { console.warn('openvanilla.js loading', e); }
```

**3. `realm/www/owdiag-capture.js`**: register the routine:

```js
import { ROUTINE as LOAD } from './owdiag-load.js';
// ...and at the end of the file:
ROUTINES.push(LOAD);
```

**4. `hetzner/openvanilla_realm_up.sh`**

- Step 1's page-layer download list:
  `for f in openvanilla.js owdiag.js owdiag-checks.js owdiag-capture.js owdiag-load.js sw.js sw-register.js prefetch.js login-backdrop.js login-backdrop.webp login-backdrop.webm login-backdrop.mp4; do`
- The zone manifests, right after that loop:
  ```bash
  mkdir -p "$CP/www/manifests"
  if curl -fsSL "$RAW/realm/www/manifests/index.json" -o "$CP/www/manifests/index.json"; then
    for z in $(python3 -c "import json;print(' '.join(json.load(open('$CP/www/manifests/index.json'))))"); do
      curl -fsSL "$RAW/realm/www/manifests/$z.json" -o "$CP/www/manifests/$z.json" || true
    done
  fi
  ```
- Replace `chmod 644 "$CP"/www/*`. It would make the `manifests` folder unreadable. Use this instead:
  `find "$CP/www" -type f -exec chmod 644 {} +; find "$CP/www" -type d -exec chmod 755 {} +`
- Step 2, after `cp "$CP/patch-Z.MPQ" "$CLIENT_DATA/patch-Z.MPQ"`, publish the data version.
  `sw` is the operator switch: `opt-in`, `on` or `off`.
  ```bash
  printf '{"patchZ":"%s","sw":"%s"}\n' "$(sha256sum "$CP/patch-Z.MPQ" | cut -c1-16)" "${OW_SW:-opt-in}" > "$CP/www/data-version.json"
  chmod 644 "$CP/www/data-version.json"
  ```
- The Caddyfile heredoc, inside the site block (next to `encode zstd gzip`):
  ```
  	# Open Vanilla service worker: allowed to control the whole site, not just /ow/.
  	@owsw path /ow/sw.js
  	header @owsw Service-Worker-Allowed "/"
  ```

**5. `hetzner/openvanilla_hotpatch.sh`**

- Make `realm/www/*` keep subfolders, so `manifests/*.json` don't land flat in `www/`:
  ```bash
      realm/www/*)
        rel=${f#realm/www/}
        echo "  [0] page  $rel"
        [ $DRY = 1 ] || { mkdir -p "$CP/www/$(dirname "$rel")"; cp "$src" "$CP/www/$rel.new"; chmod 644 "$CP/www/$rel.new"; mv "$CP/www/$rel.new" "$CP/www/$rel"; } ;;
  ```
- Tier 1, right after `docker compose up -d --no-deps --force-recreate realm`, write the new
  data version (the line from step 4). Do it only after the realm has reopened the new patch-Z,
  so that service workers refetch the new files and not the old ones.

**6. `realm/patches/`**: add `0006-openvanilla-lite-textures.patch` and
`0007-openvanilla-patchz-revalidate.patch`. Both apply in order after 0001–0005 (checked with
`git apply --check`). The realm-image workflow applies `realm/patches/*.patch` in name order.

**7. CSP**: the realm sends no Content-Security-Policy today (none in wenilla-realm, none in
either Caddyfile), so nothing to change. If one is added later, it needs
`worker-src 'self' blob:` (bridge.js runs its background keepalive as a `blob:` Worker) and
`connect-src 'self'`.

## HTTP/3

Upstream `compose.yaml` already publishes `"443:443/udp"` for Caddy, and Caddy 2 serves HTTP/3 by
default. `setup_hetzner.sh` and `wenilla_up.sh` both run `ufw allow 443/udp`. Docker-published
ports bypass ufw anyway. `openvanilla_realm_up.sh`'s `compose.override.yaml` doesn't touch the ports.
So it is probably on already. Check on the server:

```bash
curl -sI https://play.openvanilla.app | grep -i alt-svc          # expect: alt-svc: h3=":443"; ma=2592000
docker compose -f /opt/wenilla-realm/compose.yaml port --protocol udp caddy 443   # expect 0.0.0.0:443
```

If the server's `compose.yaml` is an older copy without the UDP line, add it to the caddy block
of the override that `openvanilla_realm_up.sh` writes:

```yaml
  caddy:
    ports:
      - "443:443/udp"
    volumes: ...
```

Add that only if `docker compose config caddy` doesn't already list it, because a duplicate
mapping fails to bind. To be explicit in the Caddyfile, add a global block at the top of the
heredoc:

```
{
	servers {
		protocols h1 h2 h3
	}
}
```

Also check the **Hetzner Cloud Firewall** in the console, if one is attached: it must allow
UDP 443 inbound. Caddy's QUIC wants bigger UDP buffers, so on the host run
`sysctl -w net.core.rmem_max=7500000 net.core.wmem_max=7500000` (persist in `/etc/sysctl.d/`).
Otherwise Caddy logs "failed to sufficiently increase receive buffer size".

## Lite textures: design note

`/data` is answered by wenilla-host's `data.rs` (mounted by wenilla-realm behind the session).
It reads the inflated file from the MPQ chain on a blocking thread and sends it with
`image/x-blp` (never compressed). Patch 0006 adds `crates/wenilla-host/src/lite.rs`. When the
request has `?lite=1` or `X-OW-Lite: 1`, an eligible BLP2 is rewritten on that thread: level 1
becomes level 0, the width and height halve, and the offset and size tables shift up one slot
and are re-based. The bytes from level 1 to the end of the file are copied as one block, so a
DXT level the reader extends past its stored size still finds the same bytes. Nothing is
re-encoded.

These files are left untouched:
- not BLP2, or JPEG-compressed;
- no mips, or 64 px or smaller;
- a level table that is not one ascending run inside the file.

Lite responses carry `X-OW-Lite: 1`, and eligible files carry `Vary: X-OW-Lite`.

A unit test decodes the result with the client's own decoder (benilla-blp, via
`benilla_formats::blp_mip_stats`). It checks that the result is a texture half the size whose
levels are the original's levels 1 and down.

`cargo test -p wenilla-host` passed here: 14 unit tests, including 5 for lite and 1 for 0007, plus
the existing integration tests. `cargo clippy` is clean. `cargo check -p wenilla-realm` passed
with 0001–0007 applied. This was on stable 1.97; the pinned 1.98.1 toolchain could not be
downloaded here.

Where the client depends on texture size: the character body atlas composites base skins and
item components into fixed 256² rectangles (`benilla-formats/src/characters/sections.rs`), and
the UI lays art out by texel coordinates. Both are excluded by path. Model and terrain textures
are sampled with normalized UVs, so a smaller texture only looks blurrier. Not verified in a
live client: particle atlases and anything else that might compare a texture's size with a
number stored elsewhere. Check a few zones with `?lite=1` before turning `auto` on for everyone.

## Unknowns

- All numbers here come from a stub. On the real realm, measure with `measure.mjs` before and
  after each change.
- Whether the SW actually beats the HTTP cache on warm loads. Cache Storage lookups cost a few
  ms each, and the HTTP cache is usually faster when it still holds the file. The SW's value is
  durability and lite textures, not raw speed. Compare `--query sw=1` against a plain run.
- The glue prefetch helps only when the player comes back to the same place. A zone manifest
  helps only for zones someone has captured, and it goes stale when the client changes what it
  reads.
- Sync XHR bypassing the service worker was measured in Chromium. Firefox and Safari were not
  tested, and there the worker might see these reads. That is harmless, because they would be
  passed through.
