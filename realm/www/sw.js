// ow/sw.js — Open Vanilla's service worker: keeps the game data a player has downloaded, so the next
// visit loads it from disk instead of the network, and survives the browser's HTTP-cache churn.
//
// Registered by ow/sw-register.js at scope "/" (the realm must send `Service-Worker-Allowed: /`
// with this file; see devkit/loadlab/README.md). What it does per request:
//
//   /data/<a%2Fb%2Fc>        the client's ASYNC reads (its Bevy asset reader: terrain, models,
//                            world textures, sounds — paths with '/'), cache-first in Cache
//                            Storage ("ow-data-v1"). The realm serves these immutable.
//   /data/<a%5Cb%5Cc>        the client's SYNC reads (Chain names with '\\'): not touched. Sync XHR
//                            bypasses service workers, so these stay with the HTTP cache, which
//                            web/boot.js warms on purpose (see the fetch handler). ow/syncread.js
//                            serves them from memory instead.
//   /data/Sound%5C…          the exception: the browser build loads every sound with fetch(), never
//                            a sync read (benilla-app sound/web_load.rs), so sound files are kept
//                            like the async reads, and ow/prefetch.js warms the zone's sounds
//                            into this cache in priority order once the game's sound is up.
//   /data/<patch-Z family>   Interface/AddOns, Interface/ClassicPlus and DBFilesClient can change
//                            under the same name when the realm ships a new patch-Z.MPQ. They are
//                            cache-first in a cache named after the data version the realm
//                            publishes in /ow/data-version.json ("ow-dataz-<version>"); a new
//                            version drops the old cache. Without that file they go to the
//                            network every time (correct, just not faster).
//   /data/<world .blp>       with lite textures on, fetched as <url>?lite=1 (the realm then sends
//                            the texture without its largest mip; an older realm ignores it) and
//                            cached under that key, so full and lite copies never mix.
//   /data/__index            network-first (normal HTTP caching), with the last good copy as the
//                            offline fallback; re-fetched past the HTTP cache when the data
//                            version changes, because a new patch-Z can add files.
//   everything else          not touched: pages, /login, /api, /ws, the wasm, the scripts.
//
// Kill switches: ?nosw=1 on the page (that browser), or {"sw": "off"} in /ow/data-version.json
// (everyone: the worker unregisters itself and deletes its caches on its next check).

const SW_VERSION = 1;
const BASE = `ow-data-v${SW_VERSION}`;
const PATCH_PREFIX = 'ow-dataz-';
const META = 'ow-meta';
const VERSION_URL = new URL('./data-version.json', self.location).href;
const MUTABLE = ['interface/addons/', 'interface/classicplus/', 'dbfilesclient/'];
// Mirrors crates/wenilla-host/src/lite.rs ELIGIBLE_PREFIXES: world-space art only.
const LITE_PREFIXES = ['world/', 'creature/', 'tileset/', 'spells/', 'item/objectcomponents/', 'dungeons/', 'environments/'];
const VERSION_TTL_MS = 60_000;
const TRIM_HIGH = 0.8, TRIM_LOW = 0.7;  // fractions of the origin's quota

let settings = { lite: 'off' };          // 'on' | 'off' | 'auto', sent by the page
let dataVersion = { v: null, at: 0, sw: 'on' };
let versionCheck = null;
let puts = 0;
let disabled = false;                    // set by ?nosw=1 / owsw.off(): stop answering at once
const inflight = new Map();              // cache key -> Promise<Response> (one network fetch per URL)

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil((async () => {
  await loadSettings();
  for (const k of await caches.keys()) {
    if (k.startsWith('ow-data-v') && k !== BASE) await caches.delete(k);  // an older SW_VERSION
  }
  await self.clients.claim();
  await checkVersion(true).catch(() => {});
  trim().catch(() => {});
})()));

self.addEventListener('message', (e) => {
  const m = e.data || {};
  if (m.type === 'settings') {
    settings = { ...settings, ...m.settings };
    e.waitUntil(saveSettings());
  } else if (m.type === 'status') {
    e.waitUntil(status().then((s) => e.source?.postMessage({ type: 'status', status: s })));
  } else if (m.type === 'recheck') {
    e.waitUntil(checkVersion(true).catch(() => {}));
  } else if (m.type === 'disable') {
    disabled = true;
    e.waitUntil(clearAll());
  } else if (m.type === 'clear') {
    e.waitUntil(clearAll());
  }
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (disabled || (req.method !== 'GET' && req.method !== 'HEAD')) return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin || !url.pathname.startsWith('/data/')) return;
  if (url.pathname === '/data/__addons' || req.headers.has('range')) return;
  // Chain names ('\\' -> %5C) are left to the HTTP cache. The client reads them with SYNCHRONOUS
  // XMLHttpRequest, which a service worker never sees (measured in Chromium: workerStart 0 on
  // every sync XHR of a controlled page); web/boot.js prefetches them with fetch() precisely to
  // warm the HTTP cache for those reads. Answering that prefetch from Cache Storage would leave
  // the HTTP cache cold and turn the boot back into ~100 serial network reads.
  if (/%5c|\\/i.test(url.pathname) && !/^\/data\/sound(%5c|\\)/i.test(url.pathname)) return;
  if (url.pathname === '/data/__index') {
    if (req.method === 'GET') e.respondWith(indexFirst(req));
    return;
  }
  e.respondWith(dataFile(req, url));
});

// -- /data files ---------------------------------------------------------------------------------

function nameOf(url) {
  let n;
  try { n = decodeURIComponent(url.pathname.slice('/data/'.length)); } catch { n = url.pathname.slice(6); }
  return n.replace(/\\/g, '/').toLowerCase();
}

function liteWanted() {
  if (settings.lite === 'on') return true;
  if (settings.lite !== 'auto') return false;
  const c = self.navigator.connection;
  return !!c && (c.saveData || ['slow-2g', '2g', '3g'].includes(c.effectiveType));
}

async function dataFile(req, url) {
  const name = nameOf(url);
  const mutable = MUTABLE.some((p) => name.startsWith(p));
  let cacheName = BASE;
  if (mutable) {
    await checkVersion(false).catch(() => {});
    if (!dataVersion.v) return fetch(req, { cache: 'no-cache' });  // no version published: always fresh
    cacheName = PATCH_PREFIX + dataVersion.v;
  }
  if (dataVersion.sw === 'off') return fetch(req);
  let key = url.href;
  if (name.endsWith('.blp') && LITE_PREFIXES.some((p) => name.startsWith(p)) && liteWanted()) {
    const u = new URL(url.href);
    u.searchParams.set('lite', '1');
    key = u.href;
  }
  const cache = await caches.open(cacheName);
  const hit = await cache.match(key, { ignoreVary: true });
  if (hit) return req.method === 'HEAD' ? tagged(hit, 'hit', true) : tagged(hit, 'hit');
  if (req.method === 'HEAD') return fetch(req);
  return network(cache, key, mutable).then((res) => tagged(res, 'net'));
}

// `Server-Timing: owsw;desc=hit|net` — the only way the page's Resource Timing can tell a worker
// cache hit from a worker network fetch (both report transferSize 0). owdiag-load.js reads it.
function tagged(res, how, head = false) {
  const headers = new Headers(res.headers);
  headers.append('Server-Timing', `owsw;desc=${how}`);
  return new Response(head ? null : res.body, { status: res.status, statusText: res.statusText, headers });
}

function network(cache, key, mutable) {
  let p = inflight.get(key);
  if (!p) {
    // A patch-Z family file must skip the HTTP cache: it may hold the previous patch's copy,
    // marked immutable for a year. Base files take whatever the HTTP cache already has.
    p = fetch(key, { cache: mutable ? 'no-cache' : 'default', credentials: 'same-origin' }).then(async (res) => {
      if (res.ok && res.status === 200 && res.type === 'basic' &&
          !(res.headers.get('content-type') || '').startsWith('text/html')) {
        const copy = res.clone();
        cache.put(key, copy).then(() => { if (++puts % 200 === 0) trim().catch(() => {}); }).catch(() => {});
      }
      return res;
    });
    inflight.set(key, p);
    p.finally(() => inflight.delete(key)).catch(() => {});
  }
  return p.then((res) => res.clone());
}

// -- /data/__index -------------------------------------------------------------------------------

async function indexFirst(req) {
  const meta = await caches.open(META);
  try {
    const res = await fetch(req, { cache: dataVersion.reloadIndex ? 'reload' : 'default' });
    if (res.ok) {
      dataVersion.reloadIndex = false;
      meta.put('/data/__index', res.clone()).catch(() => {});
    }
    return res;
  } catch (e) {
    const old = await meta.match('/data/__index');
    if (old) return old;
    throw e;
  }
}

// -- The data version (patch-Z) and the operator kill switch -------------------------------------

function checkVersion(force) {
  if (!force && Date.now() - dataVersion.at < VERSION_TTL_MS) return Promise.resolve();
  versionCheck ??= (async () => {
    try {
      const res = await fetch(VERSION_URL, { cache: 'no-store', credentials: 'same-origin' });
      const j = res.ok ? await res.json() : {};
      const v = typeof j.patchZ === 'string' && /^[\w.-]{1,64}$/.test(j.patchZ) ? j.patchZ : null;
      const prev = dataVersion.v;
      dataVersion = { ...dataVersion, v, at: Date.now(), sw: j.sw === 'off' ? 'off' : 'on' };
      if (dataVersion.sw === 'off') return selfDestruct();
      if (v !== prev) {
        for (const k of await caches.keys()) {
          if (k.startsWith(PATCH_PREFIX) && k !== PATCH_PREFIX + v) await caches.delete(k);
        }
        if (prev !== null || v === null) dataVersion.reloadIndex = true;
      }
    } catch {
      dataVersion.at = Date.now();  // offline: try again later, keep what we have
    } finally {
      versionCheck = null;
    }
  })();
  return versionCheck;
}

async function selfDestruct() {
  disabled = true;
  await clearAll();
  await self.registration.unregister();
}

async function clearAll() {
  for (const k of await caches.keys()) if (k.startsWith('ow-')) await caches.delete(k);
}

// -- Storage -------------------------------------------------------------------------------------

// No fixed size cap: one player's world is ~1-3 GB and a cap below that would just re-download
// it. Instead, when this origin passes 80% of its quota, the oldest-stored base files go until
// it is under 70%. (Cache Storage keeps insertion order; that is "oldest first".)
async function trim() {
  if (!navigator.storage?.estimate) return;
  for (let round = 0; round < 8; round++) {
    const { usage = 0, quota = 0 } = await navigator.storage.estimate();
    if (!quota || usage < quota * (round ? TRIM_LOW : TRIM_HIGH)) return;
    const cache = await caches.open(BASE);
    const keys = await cache.keys();
    if (!keys.length) return;
    const n = Math.max(1, Math.ceil(keys.length * 0.1));
    for (const k of keys.slice(0, n)) await cache.delete(k);
  }
}

async function status() {
  const out = { swVersion: SW_VERSION, dataVersion: dataVersion.v, settings, lite: liteWanted(), caches: {} };
  for (const k of await caches.keys()) {
    if (k.startsWith('ow-')) out.caches[k] = (await (await caches.open(k)).keys()).length;
  }
  if (navigator.storage?.estimate) {
    const { usage, quota } = await navigator.storage.estimate();
    out.usageMB = Math.round((usage || 0) / 1048576);
    out.quotaMB = Math.round((quota || 0) / 1048576);
  }
  return out;
}

async function loadSettings() {
  const r = await (await caches.open(META)).match('/ow/__sw/settings');
  if (r) settings = { ...settings, ...(await r.json()) };
}

async function saveSettings() {
  await (await caches.open(META)).put('/ow/__sw/settings', new Response(JSON.stringify(settings),
    { headers: { 'content-type': 'application/json' } }));
}

loadSettings().catch(() => {});
