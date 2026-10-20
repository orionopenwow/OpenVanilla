// ow/syncread.js — answer the client's SYNCHRONOUS reads from memory.
//
// The client reads two ways (devkit/loadlab/README.md): asynchronous fetch() for terrain, models
// and world textures ('/'-separated names, %2F), which the service worker and the HTTP cache
// serve; and SYNCHRONOUS XMLHttpRequest for everything read through its patch chain
// ('\'-separated names, %5C: DBCs, UI art, the world map's tiles, the first-frame UI sprites).
// A service worker never sees a synchronous XHR, so those reads could only ever hit the HTTP
// cache — slower than memory, evicted at the browser's whim, and a network round trip on the
// main thread when they miss.
//
// This module puts a small in-memory store in front of them:
//
//   * warm(urls)   fetches files (low priority, 4 at a time) into memory. Files that do not
//                  change between patch-Z versions are also kept in Cache Storage
//                  ("owsync-v1"), so the next visit fills memory from disk, not the network;
//                  files patch-Z can change are kept per patch-Z version ("owsync-z-<version>").
//   * the XHR shim  a synchronous GET (or HEAD) of a /data/ URL the store holds is answered from
//                  memory: no request, no main-thread wait, and the bytes go to the client as
//                  the same "x-user-defined" binary string it asks for. A GET hands the file
//                  over and frees it (the client keeps what it reads). Anything else — async
//                  XHR, other URLs, misses — goes to the real XMLHttpRequest untouched.
//   * window.__ow_has(url) / window.__ow_warm(urls)   the engine's hooks (the world map warm-up
//                  in realm/patches/pending/0011): it asks for files, and decodes each only once
//                  it is here, so its own synchronous read never waits on the network.
//
// prefetch.js fills it at the login and character screens (the world-entry UI set and the zone
// manifest's sync reads). Budget: 96 MB of memory, oldest first out. ?nosyncmem=1 turns it off.
// window.owSyncRead: { hits, misses, heads, bytesServed, held, heldBytes, fetched, fromDisk }.

const MEM_BUDGET = 96 * 1024 * 1024;
// 12 at a time: from the US the realm is ~160 ms away, so 4 left most of a warm-up waiting on round trips
const CONCURRENCY = 12;
const DISK = 'owsync-v1';   // not 'ow-': the service worker's kill switch owns those
// patch-Z can change these under the same name; never persist them (memory only, fresh fetch).
// Addons are read with '/' (%2F) names too: Interface/AddOns/<addon>/<file>.lua.
// FrameXML too: patch-Z overrides parts of the stock interface (the server revalidates those).
const MUTABLE = ['interface%5caddons%5c', 'interface%2faddons%2f', 'interface%5cclassicplus%5c', 'interface%2fclassicplus%2f',
  'interface%5cframexml%5c', 'interface%2fframexml%2f', 'interface%5cgluexml%5c', 'dbfilesclient%5c'];

const store = new Map();        // key (path+search) -> Uint8Array
const inflight = new Map();     // key -> Promise
let heldBytes = 0;
const stats = { hits: 0, misses: 0, heads: 0, bytesServed: 0, fetched: 0, fromDisk: 0, evicted: 0 };

export function keyOf(url) {
  try {
    const u = new URL(url, location.href);
    if (u.origin !== location.origin || !u.pathname.startsWith('/data/')) return null;
    return u.pathname + u.search;
  } catch { return null; }
}

const isSyncName = (key) => /%5c/i.test(key);
const isMutable = (key) => MUTABLE.some((p) => key.toLowerCase().startsWith('/data/' + p));

function hold(key, u8) {
  if (store.has(key)) return;
  if (u8.byteLength > MEM_BUDGET / 4) return;           // one huge file never evicts the rest
  store.set(key, u8);
  heldBytes += u8.byteLength;
  for (const [k, v] of store) {                          // Map keeps insertion order: oldest first
    if (heldBytes <= MEM_BUDGET) break;
    store.delete(k);
    heldBytes -= v.byteLength;
    stats.evicted += 1;
  }
}

function take(key) {
  const u8 = store.get(key);
  if (u8) { store.delete(key); heldBytes -= u8.byteLength; }
  return u8;
}

export const has = (url) => { const k = keyOf(url); return !!k && store.has(k); };

let disk = null;
const openDisk = () => (disk ??= ('caches' in self ? caches.open(DISK).catch(() => null) : Promise.resolve(null)));

// Files patch-Z can change (MUTABLE) are kept on disk too, in a cache named after the patch-Z
// version the realm publishes in /ow/data-version.json (written after the realm has reopened a new
// patch-Z). A new version starts an empty cache and drops the old ones, so a returning player
// skips re-checking ~200 files with the server (one round trip each) while patch-Z is unchanged.
// No version (older realm, offline): memory only, fetched fresh, as before.
const ZDISK = 'owsync-z-';
let zdisk = null;
const openZDisk = () => (zdisk ??= (async () => {
  if (!('caches' in self)) return null;
  try {
    const r = await fetch('/ow/data-version.json', { cache: 'no-store', credentials: 'same-origin' });
    const v = r.ok ? String((await r.json())?.patchZ || '') : '';
    if (!/^[0-9a-f]{8,64}$/i.test(v)) return null;
    const name = ZDISK + v;
    for (const k of await caches.keys()) if (k.startsWith(ZDISK) && k !== name) caches.delete(k).catch(() => {});
    return await caches.open(name);
  } catch { return null; }
})());

/** Fetch one file into memory (Cache Storage first for an unchanging one). */
function load(key, priority) {
  if (store.has(key)) return Promise.resolve(true);
  let p = inflight.get(key);
  if (p) return p;
  p = (async () => {
    const persist = !isMutable(key);
    const c = persist ? await openDisk() : await openZDisk();
    try {
      const hit = c && (await c.match(key));
      if (hit) {
        hold(key, new Uint8Array(await hit.arrayBuffer()));
        stats.fromDisk += 1;
        return true;
      }
    } catch { /* fall through to the network */ }
    try {
      const r = await fetch(key, { priority, credentials: 'same-origin', cache: persist ? 'default' : 'no-cache' });
      if (!r.ok) return false;
      const buf = await r.arrayBuffer();
      hold(key, new Uint8Array(buf));
      stats.fetched += 1;
      if (c) c.put(key, new Response(buf, { headers: { 'content-type': 'application/octet-stream' } })).catch(() => {});
      return true;
    } catch { return false; }
  })().finally(() => inflight.delete(key));
  inflight.set(key, p);
  return p;
}

/**
 * Fetch `urls` into memory, `CONCURRENCY` at a time. Only synchronous-read URLs (%5C) are taken;
 * others are ignored (the service worker and the HTTP cache serve those). Resolves to the
 * number now held. `opts.stop()` ends it early; `opts.onEach(ok, bytes)` reports progress.
 */
export async function warm(urls, opts = {}) {
  if (disabled) return 0;
  // opts.any: the caller knows these are synchronous reads even with '/' names (FrameXML and the
  // addons are read as Interface%2F..., and were never warmed before).
  const keys = [...new Set(Array.from(urls || [], keyOf).filter((k) => k && (opts.any || isSyncName(k))))];
  const queue = keys.filter((k) => !store.has(k));
  const priority = opts.priority || 'low';
  async function worker() {
    while (queue.length && !(opts.stop && opts.stop())) {
      const k = queue.shift();
      const ok = await load(k, priority);
      opts.onEach?.(ok, ok ? store.get(k)?.byteLength || 0 : 0);
    }
  }
  await Promise.all(Array.from({ length: CONCURRENCY }, worker));
  return keys.filter((k) => store.has(k)).length;
}

// -- The XHR shim --------------------------------------------------------------------------------

/** Bytes as the binary string a sync XHR with `charset=x-user-defined` gives (one char per byte). */
export function binaryString(u8) {
  let s = '';
  for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
  return s;
}

let disabled = false;
let installed = false;

export function install() {
  const status = (window.owSyncRead = Object.assign(stats, {
    get held() { return store.size; },
    get heldBytes() { return heldBytes; },
  }));
  window.__ow_has = (url) => has(url);
  window.__ow_warm = (urls) => { warm(urls).catch(() => {}); };
  if (installed) return status;
  installed = true;
  if (new URLSearchParams(location.search).get('nosyncmem') === '1') { disabled = true; return status; }
  const Native = window.XMLHttpRequest;
  if (!Native) return status;
  class OwXHR extends Native {
    open(method, url, async, ...rest) {
      this.__ow = null;
      const m = String(method).toUpperCase();
      if (async === false && (m === 'GET' || m === 'HEAD')) {
        const key = keyOf(url);
        if (key && store.has(key)) {
          this.__ow = { m, key, state: 1, text: '' };
          return undefined;
        }
        if (key) stats.misses += 1;
      }
      return super.open(method, url, async === undefined ? true : async, ...rest);
    }
    send(body) {
      const o = this.__ow;
      if (!o) return super.send(body);
      if (o.m === 'HEAD') {
        stats.heads += 1;
      } else {
        const u8 = take(o.key);
        if (!u8) { this.__ow = null; return super.send(body); }  // evicted between open and send
        o.text = binaryString(u8);
        stats.hits += 1;
        stats.bytesServed += u8.byteLength;
      }
      o.state = 4;
      return undefined;
    }
    overrideMimeType(t) { if (!this.__ow) return super.overrideMimeType(t); return undefined; }
    setRequestHeader(k, v) { if (!this.__ow) return super.setRequestHeader(k, v); return undefined; }
    getResponseHeader(k) { return this.__ow ? null : super.getResponseHeader(k); }
    getAllResponseHeaders() { return this.__ow ? '' : super.getAllResponseHeaders(); }
    abort() { if (!this.__ow) super.abort(); }
    get readyState() { return this.__ow ? this.__ow.state : super.readyState; }
    get status() { return this.__ow ? (this.__ow.state === 4 ? 200 : 0) : super.status; }
    get statusText() { return this.__ow ? (this.__ow.state === 4 ? 'OK' : '') : super.statusText; }
    get responseText() { return this.__ow ? this.__ow.text : super.responseText; }
    get response() { return this.__ow ? this.__ow.text : super.response; }
    get responseURL() { return this.__ow ? location.origin + this.__ow.key : super.responseURL; }
  }
  window.XMLHttpRequest = OwXHR;
  return status;
}

/** Drop everything held (the page uses it on leaving the world, to give the memory back). */
export function clear() {
  store.clear();
  heldBytes = 0;
}
