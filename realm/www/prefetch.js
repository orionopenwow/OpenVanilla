// ow/prefetch.js — warm the HTTP cache (or the service worker's cache) with the world around
// where this player last was, while they sit at the login and character screens.
//
// What the page can know before Enter World: very little. The character screens are native (no
// Lua VM), the bridge snapshot carries no character list, and the realm has no player-facing
// characters API. The client itself starts streaming terrain only after Enter World (its entry
// focus is the *picked* character). So this file remembers, per browser, the last place the
// player was in the world (map, position, zone name — from the bridge snapshot, every 15 s and
// on leaving the page), and on the next visit fetches, at low priority:
//
//   1. the map's WDT and the 3×3 ADT tiles around that position — in the exact URL form the
//      client's asset reader uses (`/data/World%2FMaps%2F<Dir>%2F<Dir>_<x>_<y>.adt`), so they are
//      cache hits when the client asks;
//   2. the zone manifest ow/manifests/<zone-slug>.json, if one was captured for that zone
//      (devkit/loadlab/capture_manifest.mjs): every /data URL a real session read in its first
//      minute there (models, textures, sounds), minus the boot and world manifests.
//
// It starts once the login screen is up and the boot's own world-manifest prefetch has finished
// (the "preparing world data" corner line is gone), runs 4 requests at a time, stops the moment
// the player is in the world, and skips entirely on Save-Data or a 2g/3g connection, and with
// ?noprefetch=1 or ?boottrace=1 (a trace must show the true read order).
//
// Synchronous reads (names with '\', %5C — the zone manifest's UI art, DBCs and the world-entry
// UI set in /world-manifest.json) are fetched into ow/syncread.js's memory store instead, so the
// client's synchronous XHR for them never waits (boot.js's own world prefetch only warms the
// HTTP cache). Everything else goes to the HTTP cache / the service worker as before.
//
// A brand-new character has no "last place": while the player is on the character-create screen
// (the page can't see which race they pick), the six stock starting areas' centre tiles are
// fetched instead (Northshire, Coldridge Valley, Deathknell, Shadowglen, Valley of Trials, Camp
// Narache): about 10 MB, so a new character's first Enter World finds its ground in the cache.
//
// Once in the world and the deferred sound is up (engine 'audio-ready'), the zone manifest's sound
// files follow in priority order — music, then ambience, then the rest — low priority, so the
// first zone bed and the first spells play from the cache.
//
// window.owPrefetch: { state, planned, done, bytes, ms, source, memory, sound } for owdiag's
// `load` routine.

const BASE = new URL('./', import.meta.url);
const syncread = import('./syncread.js').catch(() => null);
const isSync = (u) => /%5c/i.test(u);
const LAST_KEY = 'ow:lastpos';
const CONCURRENCY = 8;   // ~160 ms from the US: 4 left the glue prefetch mostly waiting
const BUDGET_BYTES = 80 * 1024 * 1024;
const TILE_YARDS = 533.3333;
const KNOWN_DIRS = { 0: 'Azeroth', 1: 'Kalimdor' };

export const tileOf = (x, y) => [
  Math.min(63, Math.max(0, Math.floor((32 * TILE_YARDS - y) / TILE_YARDS))),
  Math.min(63, Math.max(0, Math.floor((32 * TILE_YARDS - x) / TILE_YARDS))),
];
// 1.12.1 playercreateinfo start positions: [map id, x, y].
export const STARTS = [
  [0, -8949.95, -132.49],   // Human: Northshire Abbey
  [0, -6240.32, 331.03],    // Dwarf, Gnome: Coldridge Valley
  [0, 1676.71, 1678.31],    // Undead: Deathknell
  [1, 10311.3, 832.46],     // Night Elf: Shadowglen
  [1, -618.52, -4251.67],   // Orc, Troll: Valley of Trials
  [1, -2917.58, -257.98],   // Tauren: Camp Narache
];
export const slug = (s) => String(s || '').toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
const dataUrl = (name) => '/data/' + encodeURIComponent(name);

/** The client's own URL for an ADT/WDT (benilla-world terrain_stream: `mpq://World/Maps/...`). */
export function terrainUrls(dir, tx, ty, radius = 1) {
  const out = [dataUrl(`World/Maps/${dir}/${dir}.wdt`)];
  for (let dy = -radius; dy <= radius; dy++) {
    for (let dx = -radius; dx <= radius; dx++) {
      const x = tx + dx, y = ty + dy;
      if (x >= 0 && x < 64 && y >= 0 && y < 64) out.push(dataUrl(`World/Maps/${dir}/${dir}_${x}_${y}.adt`));
    }
  }
  return out;
}

/** Map.dbc (WDBC): field 0 the map id, field 1 the directory string. */
export function parseMapDirs(buf) {
  const v = new DataView(buf);
  if (buf.byteLength < 20 || v.getUint32(0, true) !== 0x43424457) return {};
  const recs = v.getUint32(4, true), size = v.getUint32(12, true), sb = 20 + recs * size;
  const u8 = new Uint8Array(buf), dec = new TextDecoder();
  const out = {};
  for (let i = 0; i < recs; i++) {
    const id = v.getUint32(20 + i * size, true), o = v.getUint32(24 + i * size, true);
    let e = sb + o;
    while (e < u8.length && u8[e]) e++;
    out[id] = dec.decode(u8.subarray(sb + o, e));
  }
  return out;
}

function slowLink() {
  const c = navigator.connection;
  return !!c && (c.saveData || ['slow-2g', '2g', '3g'].includes(c.effectiveType));
}

function remember(state) {
  const self = state?.self;
  if (state?.session?.state !== 'inworld' || !self?.pos || state.map?.id == null) return false;
  try {
    localStorage.setItem(LAST_KEY, JSON.stringify({
      map: state.map.id, pos: self.pos.map((n) => Math.round(n)), zone: state.zone?.realZone || state.zone?.name || null,
      at: Date.now(),
    }));
  } catch { /* storage blocked */ }
  return true;
}

async function mapDir(id) {
  try {
    // The client read this exact URL during boot, so this is a cache hit.
    const r = await fetch(dataUrl('DBFilesClient\\Map.dbc'));
    if (r.ok) {
      const dir = parseMapDirs(await r.arrayBuffer())[id];
      if (dir) return dir;
    }
  } catch { /* fall through */ }
  return KNOWN_DIRS[id] || null;
}

async function zoneManifest(zone) {
  if (!zone) return [];
  try {
    const r = await fetch(new URL(`manifests/${slug(zone)}.json`, BASE), { cache: 'no-cache' });
    if (!r.ok) return [];
    const m = await r.json();
    return Array.isArray(m.urls) ? m.urls.filter((u) => typeof u === 'string' && u.startsWith('/data/'))
      : Array.isArray(m.names) ? m.names.map(dataUrl) : [];
  } catch { return []; }
}

export async function plan(last) {
  if (!last || last.map == null || !Array.isArray(last.pos)) return { urls: [], source: 'none' };
  const urls = [];
  const dir = await mapDir(last.map);
  if (dir) {
    const [tx, ty] = tileOf(last.pos[0], last.pos[1]);
    urls.push(...terrainUrls(dir, tx, ty));
  }
  const zone = await zoneManifest(last.zone);
  urls.push(...zone);
  return { urls: [...new Set(urls)], source: zone.length ? `tiles+manifest:${slug(last.zone)}` : 'tiles' };
}

/** The starting areas' WDTs and centre tiles, for a character not made yet. */
export async function startsPlan() {
  const urls = [];
  for (const [map, x, y] of STARTS) {
    const dir = await mapDir(map);
    if (!dir) continue;
    const [tx, ty] = tileOf(x, y);
    urls.push(...terrainUrls(dir, tx, ty, 0));
  }
  return { urls: [...new Set(urls)], source: 'starts' };
}

function lastPlace() {
  try { return JSON.parse(localStorage.getItem(LAST_KEY) || 'null'); } catch { return null; }
}

async function run(wenilla, status, planned) {
  const { urls, source } = planned || await plan(lastPlace());
  Object.assign(status, { state: urls.length ? 'running' : 'nothing', planned: urls.length, source });
  if (!urls.length) return;
  const t0 = performance.now();
  const stop = () => wenilla.state?.session?.state === 'inworld' || status.bytes > BUDGET_BYTES;
  // Synchronous-read files go to the memory store, the rest to the caches.
  const mem = urls.filter(isSync);
  const queue = urls.filter((u) => !isSync(u));
  const sr = await syncread;
  const memRun = sr && mem.length
    ? sr.warm(mem, { stop, onEach: (ok, n) => { status.done += 1; status.bytes += n; status.memory += ok ? 1 : 0; } })
    : Promise.resolve(0);
  if (!sr) queue.push(...mem);
  async function worker() {
    while (queue.length && !stop()) {
      const url = queue.shift();
      try {
        const r = await fetch(url, { priority: 'low', credentials: 'same-origin' });
        if (r.ok) status.bytes += (await r.arrayBuffer()).byteLength;
      } catch { /* the client will fetch it the normal way */ }
      status.done += 1;
    }
  }
  await Promise.all([memRun, ...Array.from({ length: CONCURRENCY }, worker)]);
  status.ms = Math.round(performance.now() - t0);
  status.state = status.done < urls.length ? 'stopped' : 'done';
}

/** The world-entry UI set (boot.js warms it into the HTTP cache): into memory as well. */
async function worldSetToMemory(wenilla, status) {
  const sr = await syncread;
  if (!sr) return;
  try {
    const r = await fetch('/world-manifest.json');
    if (!r.ok) return;
    const names = (await r.json()).names || [];
    const stop = () => wenilla.state?.session?.state === 'inworld';
    await sr.warm(names.map(dataUrl), { stop, onEach: (ok) => { status.memory += ok ? 1 : 0; } });
  } catch { /* the HTTP cache still has them */ }
}

/** After the deferred sound is up: the zone's sound files, music and ambience first. */
export function soundOrder(urls) {
  const rank = (u) => {
    const n = decodeURIComponent(u).toLowerCase().replace(/\\/g, '/');
    if (!n.startsWith('/data/sound/')) return -1;
    if (n.startsWith('/data/sound/music/')) return 0;
    if (n.startsWith('/data/sound/ambience/')) return 1;
    if (n.startsWith('/data/sound/interface/')) return 2;
    if (n.startsWith('/data/sound/spells/')) return 3;
    return 4;
  };
  return urls.map((u) => [rank(u), u]).filter(([r]) => r >= 0).sort((a, b) => a[0] - b[0]).map(([, u]) => u);
}

async function soundsInBackground(wenilla, status, zone) {
  const urls = soundOrder(await zoneManifest(zone));
  status.sound = { planned: urls.length, done: 0 };
  for (const u of urls) {
    if (wenilla.state?.session?.state !== 'inworld') break;
    try {
      const r = await fetch(u, { priority: 'low', credentials: 'same-origin' });
      if (r.ok) await r.arrayBuffer();
    } catch { /* the client fetches it itself */ }
    status.sound.done += 1;
  }
}

const idle = () => new Promise((r) => (window.requestIdleCallback ? requestIdleCallback(r, { timeout: 2000 }) : setTimeout(r, 200)));

/** Wait until the boot's own world-manifest prefetch (boot.js corner line) is over, max 90 s. */
async function bootPrefetchDone() {
  for (let i = 0; i < 90 && document.getElementById('wenilla-corner'); i++) await new Promise((r) => setTimeout(r, 1000));
}

export function installPrefetch(wenilla) {
  const status = (window.owPrefetch = { state: 'waiting', planned: 0, done: 0, bytes: 0, ms: 0, source: null, memory: 0, sound: null });
  // A boot alone is ~600 /data reads; the default buffer of 250 entries would lose most of them.
  performance.setResourceTimingBufferSize?.(20000);
  // State marks for owdiag's load routine (performance.getEntriesByName('ow:state:inworld')).
  const marked = new Set();
  const mark = (s) => { if (s && !marked.has(s)) { marked.add(s); performance.mark('ow:state:' + s); } };
  let lastSave = 0;
  wenilla.on('frame', (snap) => {
    mark(snap?.session?.state);
    const now = Date.now();
    if (now - lastSave > 15000 && remember(snap)) lastSave = now;
  });
  wenilla.on('state', (s) => mark(s?.state));
  window.addEventListener('pagehide', () => remember(wenilla.state));
  document.addEventListener('visibilitychange', () => { if (document.hidden) remember(wenilla.state); });

  const q = new URLSearchParams(location.search);
  if (q.get('noprefetch') === '1' || q.get('boottrace') === '1' || slowLink()) {
    status.state = 'skipped';
    return status;
  }
  let started = false;
  const go = async (s) => {
    if (started || !['login', 'charselect'].includes(s)) return;
    started = true;
    await bootPrefetchDone();
    await idle();
    if (wenilla.state?.session?.state === 'inworld') { status.state = 'stopped'; return; }
    run(wenilla, status)
      .then(() => worldSetToMemory(wenilla, status))
      .catch((e) => { status.state = 'error'; status.error = String(e?.message || e); });
  };
  // The deferred sound's 'audio-ready' (engine patch 0009, through ow/stages.js's mark): the
  // zone's sounds next, in priority order.
  let soundStarted = false;
  const soundGo = () => {
    // A cheap property read every frame (an engine without patch 0009 never says audio-ready,
    // and scanning the 20000-entry performance timeline 60 times a second is not free).
    if (soundStarted || !(window.owStages?.marks && 'sound-ready' in window.owStages.marks)) return;
    soundStarted = true;
    let zone = null;
    try { zone = wenilla.state?.zone?.realZone || wenilla.state?.zone?.name || JSON.parse(localStorage.getItem(LAST_KEY) || 'null')?.zone; } catch { /* none */ }
    soundsInBackground(wenilla, status, zone).catch(() => {});
  };
  wenilla.on('frame', soundGo);
  // Character creation with no last place on record: the starting areas.
  let startsDone = false;
  const startsGo = async (s) => {
    if (startsDone || s !== 'charcreate' || lastPlace()) return;
    startsDone = true;
    await idle();
    const st = (status.starts = { state: 'running', planned: 0, done: 0, bytes: 0, ms: 0, memory: 0 });
    const p = await startsPlan();
    st.planned = p.urls.length;
    run(wenilla, st, p).catch((e) => { st.state = 'error'; st.error = String(e?.message || e); });
  };
  wenilla.on('state', (s) => { go(s?.state); startsGo(s?.state); });
  wenilla.on('frame', (snap) => { go(snap?.session?.state); startsGo(snap?.session?.state); });
  return status;
}
