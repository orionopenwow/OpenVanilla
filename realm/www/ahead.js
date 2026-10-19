// ow/ahead.js — fetch the world ahead of the player, so it is already in the browser's caches
// (Cache Storage with the service worker on, the HTTP cache always) when the client asks for it.
//
// Three cases, read from the bridge snapshot (realm/classicplus/bridge.js `frame`):
//
//   moving      the terrain tiles along the direction of travel, as far ahead as ~25 s at the
//               current speed (300..2000 yd), and the models and textures those tiles place.
//   flying      on a taxi (`self.flight.nodes`, engine patch 0011): every tile along the flight's
//               path, in flight order from where the player is, with models for the next stretch.
//   casting     a hearthstone or Astral Recall (`self.bind`, engine patch 0011), a mage teleport or
//               a portal: the 3×3 tiles around the destination and their models, from the
//               moment the cast starts — a 10 s cast is usually enough to have them all.
//   world map   20 s after the world is up: the detail tiles of every zone on this continent
//               (WorldMapArea.dbc), into the HTTP cache. The world map is FrameXML drawing UI
//               sprites the client reads synchronously; engine patch 0011 decodes the current
//               zone's, continent's and the world sheet's ahead of time, and this makes any other
//               zone the player clicks to a disk read instead of a network wait on the main thread.
//
// Only network work: nothing is decoded or built here. URLs are the exact ones the client's
// asset reader uses (terrain names keep their case, everything else is lower case, '/' as %2F),
// so each prefetch is the client's own request answered early. Low priority, 3 at a time, 150 MB
// per session at most; off on Save-Data or 2g/3g, and with ?noahead=1.
//
// window.owAhead: { state, tiles, models, bytes, last } for owdiag.

import { tileOf, parseMapDirs, terrainUrls } from './prefetch.js';

const TILE = 533.3333;
const CONCURRENCY = 3;
const BUDGET = 150 * 1024 * 1024;
const LOOK_SECS = 25;
const LOOK_MIN = 300, LOOK_MAX = 2000;

// Hearthstone, Astral Recall: the bind point. Mage teleports and portals: their fixed
// destinations (spell_target_position; the portal spells' triggered teleports go to the same places).
const TO_BIND = new Set([8690, 556]);
const FIXED = {
  3561: [0, -9003.46, 870.031], 10059: [0, -9003.46, 870.031],       // Stormwind
  3562: [0, -4613.62, -915.38], 11416: [0, -4613.62, -915.38],        // Ironforge
  3563: [0, 1773.47, 61.121], 11418: [0, 1773.47, 61.121],            // Undercity
  3565: [1, 9664.14, 2526.36], 11419: [1, 9660.81, 2513.64],          // Darnassus
  3566: [1, -964.98, 283.433], 11420: [1, -964.98, 283.433],          // Thunder Bluff
  3567: [1, 1469.85, -4221.52], 11417: [1, 1469.85, -4221.52],        // Orgrimmar
};

const enc = (name) => '/data/' + encodeURIComponent(name);
const lower = (name) => name.replace(/\\/g, '/').toLowerCase();

/** The client's URL for a model or texture name as an ADT or a model file spells it. */
export function m2Url(raw) {
  const p = lower(raw).replace(/\.(mdx|mdl|m2)$/, '');
  return enc(p + '.m2');
}
export const wmoUrl = (raw) => enc(lower(raw));
export const texUrl = (raw) => enc(lower(raw));

/** Chunks of an IFF-style file (ADT, WMO): id (as written, e.g. "MTEX") → [offset, size]. */
export function chunks(buf, stopAt) {
  const v = new DataView(buf), out = {};
  for (let o = 0; o + 8 <= buf.byteLength;) {
    const id = String.fromCharCode(v.getUint8(o + 3), v.getUint8(o + 2), v.getUint8(o + 1), v.getUint8(o));
    const size = v.getUint32(o + 4, true);
    if (id === stopAt) break;
    if (!(id in out)) out[id] = [o + 8, size];
    o += 8 + size;
  }
  return out;
}

function strings(buf, [off, size]) {
  const u8 = new Uint8Array(buf, off, Math.min(size, buf.byteLength - off)), dec = new TextDecoder();
  const out = [];
  let s = 0;
  for (let i = 0; i < u8.length; i++) {
    if (u8[i] === 0) { if (i > s) out.push(dec.decode(u8.subarray(s, i))); s = i + 1; }
  }
  return out;
}

/** What an ADT places: its ground textures, doodads (M2) and buildings (WMO roots). */
export function adtRefs(buf) {
  const c = chunks(buf, 'MCNK');
  return {
    textures: c.MTEX ? strings(buf, c.MTEX).map(texUrl) : [],
    m2: c.MMDX ? strings(buf, c.MMDX).map(m2Url) : [],
    wmo: c.MWMO ? strings(buf, c.MWMO).map(wmoUrl) : [],
  };
}

/** A WMO root's group files and textures. */
export function wmoRefs(url, buf) {
  const c = chunks(buf, 'MOGP');
  const out = [];
  if (c.MOHD) {
    const n = new DataView(buf).getUint32(c.MOHD[0] + 4, true);
    const stem = url.replace(/\.wmo$/i, '');
    for (let i = 0; i < Math.min(n, 512); i++) out.push(`${stem}_${String(i).padStart(3, '0')}.wmo`);
  }
  if (c.MOTX) out.push(...strings(buf, c.MOTX).filter((s) => /\.blp$/i.test(s)).map(texUrl));
  return out;
}

/** A 1.12 M2's hard-coded texture file names (texture type 0); others come from the DBCs. */
export function m2Textures(buf) {
  const v = new DataView(buf);
  if (buf.byteLength < 100 || v.getUint32(0, true) !== 0x3032444d) return [];  // "MD20"
  const n = v.getUint32(92, true), ofs = v.getUint32(96, true), out = [];
  for (let i = 0; i < Math.min(n, 64); i++) {
    const r = ofs + i * 16;
    if (r + 16 > buf.byteLength) break;
    if (v.getUint32(r, true) !== 0) continue;
    const len = v.getUint32(r + 8, true), at = v.getUint32(r + 12, true);
    if (!len || at + len > buf.byteLength) continue;
    const name = new TextDecoder().decode(new Uint8Array(buf, at, len)).replace(/\0.*$/, '');
    if (/\.blp$/i.test(name)) out.push(texUrl(name));
  }
  return out;
}

/** Tiles along a ray from (x, y) heading (dx, dy), `from`..`to` yards out, with one tile each side. */
export function tilesAlong(x, y, dx, dy, from, to) {
  const len = Math.hypot(dx, dy) || 1, ux = dx / len, uy = dy / len;
  const out = [];
  const seen = new Set();
  for (let d = from; d <= to; d += TILE / 2) {
    for (const side of [0, -TILE * 0.6, TILE * 0.6]) {
      const px = x + ux * d - uy * side, py = y + uy * d + ux * side;
      const t = tileOf(px, py), k = t.join('_');
      if (!seen.has(k)) { seen.add(k); out.push(t); }
    }
  }
  return out;
}

/** WDBC → rows of u32/f32 views. */
function dbc(buf) {
  const v = new DataView(buf);
  if (buf.byteLength < 20 || v.getUint32(0, true) !== 0x43424457) return null;
  const recs = v.getUint32(4, true), size = v.getUint32(12, true);
  return { recs, row: (i) => ({ u: (f) => v.getUint32(20 + i * size + f * 4, true), f: (f) => v.getFloat32(20 + i * size + f * 4, true) }) };
}

const getBuf = async (name) => {
  const r = await fetch(enc(name), { credentials: 'same-origin' });
  return r.ok ? r.arrayBuffer() : null;
};

/** WorldMapArea.dbc rows on `map`: the art folders of the continent and its zones. */
export function mapFolders(buf, map) {
  const t = dbc(buf);
  if (!t) return [];
  const v = new DataView(buf), size = v.getUint32(12, true), sb = 20 + t.recs * size, u8 = new Uint8Array(buf);
  const out = [];
  for (let i = 0; i < t.recs; i++) {
    const r = t.row(i);
    if (r.u(1) !== map) continue;
    let e = sb + r.u(3);
    const s0 = e;
    while (e < u8.length && u8[e]) e++;
    const name = new TextDecoder().decode(u8.subarray(s0, e));
    if (name) out.push({ name, continent: r.u(2) === 0 });
  }
  return out.sort((a, b) => b.continent - a.continent);
}

/** The world map's synchronous-read URLs for an art folder (benilla-assets sprite_candidates). */
export const mapTileUrls = (folder) =>
  Array.from({ length: 12 }, (_, i) => enc(`interface\\worldmap\\${folder}\\${folder}${i + 1}.blp`.toLowerCase()));

/** A taxi route (TaxiNodes ids) as map points in flight order, from the client's own DBCs. */
export async function flightPath(nodes) {
  const [pathsBuf, pnBuf] = await Promise.all([getBuf('DBFilesClient\\TaxiPath.dbc'), getBuf('DBFilesClient\\TaxiPathNode.dbc')]);
  const paths = pathsBuf && dbc(pathsBuf), pn = pnBuf && dbc(pnBuf);
  if (!paths || !pn) return [];
  const pathId = new Map();
  for (let i = 0; i < paths.recs; i++) { const r = paths.row(i); pathId.set(r.u(1) + '>' + r.u(2), r.u(0)); }
  const byPath = new Map();
  for (let i = 0; i < pn.recs; i++) {
    const r = pn.row(i), p = r.u(1);
    if (!byPath.has(p)) byPath.set(p, []);
    byPath.get(p).push([r.u(2), r.u(3), r.f(4), r.f(5)]);
  }
  const out = [];
  for (let i = 0; i + 1 < nodes.length; i++) {
    const pts = byPath.get(pathId.get(nodes[i] + '>' + nodes[i + 1])) || [];
    pts.sort((a, b) => a[0] - b[0]);
    for (const [, map, x, y] of pts) out.push([map, x, y]);
  }
  return out;
}

function slowLink() {
  const c = navigator.connection;
  return !!c && (c.saveData || ['slow-2g', '2g', '3g'].includes(c.effectiveType));
}

export function installAhead(wenilla) {
  const status = (window.owAhead = { state: 'idle', tiles: 0, models: 0, bytes: 0, last: null });
  const q = new URLSearchParams(location.search);
  if (q.get('noahead') === '1' || q.get('boottrace') === '1' || slowLink()) { status.state = 'off'; return status; }

  const done = new Set();          // URLs fetched (or failed) this session
  const tilesDone = new Set();     // "map:x_y" whose ADT was parsed
  let queue = [];                  // [url, kind, map]; kind: adt | wmo | m2 | tex
  let running = 0;
  let dirs = null;

  const mapDirs = async () => {
    if (dirs) return dirs;
    const b = await getBuf('DBFilesClient\\Map.dbc').catch(() => null);
    dirs = b ? parseMapDirs(b) : {};
    if (!dirs[0]) dirs[0] = 'Azeroth';
    if (!dirs[1]) dirs[1] = 'Kalimdor';
    return dirs;
  };

  function push(items, front = false) {
    const fresh = items.filter(([u]) => !done.has(u) && !queue.some(([q2]) => q2 === u));
    queue = front ? fresh.concat(queue) : queue.concat(fresh);
    pump();
  }

  async function fetchOne([url, kind, map]) {
    done.add(url);
    try {
      const r = await fetch(url, { priority: 'low', credentials: 'same-origin' });
      if (!r.ok) return;
      const buf = await r.arrayBuffer();
      status.bytes += buf.byteLength;
      if (kind === 'adt-only') status.tiles += 1;
      if (kind === 'adt') {
        status.tiles += 1;
        const refs = adtRefs(buf);
        push([...refs.wmo.map((u) => [u, 'wmo', map]), ...refs.m2.map((u) => [u, 'm2', map]), ...refs.textures.map((u) => [u, 'tex', map])]);
      } else if (kind === 'wmo') {
        status.models += 1;
        push(wmoRefs(url, buf).map((u) => [u, /\.wmo$/.test(u) ? 'grp' : 'tex', map]));
      } else if (kind === 'm2') {
        status.models += 1;
        push(m2Textures(buf).map((u) => [u, 'tex', map]));
      }
    } catch { /* the client fetches it itself */ }
  }

  function pump() {
    while (running < CONCURRENCY && queue.length && status.bytes < BUDGET) {
      const item = queue.shift();
      if (done.has(item[0])) continue;
      running += 1;
      fetchOne(item).finally(() => { running -= 1; pump(); });
    }
    status.state = queue.length ? 'fetching' : 'idle';
  }

  async function tiles(map, list, { front = false, models = true } = {}) {
    const d = (await mapDirs())[map];
    if (!d) return;
    const items = [];
    for (const [tx, ty] of list) {
      const k = `${map}:${tx}_${ty}`;
      if (tilesDone.has(k)) continue;
      tilesDone.add(k);
      // terrainUrls' first entry is the WDT; the client has that already.
      const adt = terrainUrls(d, tx, ty, 0)[1];
      if (adt) items.push([adt, models ? 'adt' : 'adt-only', map]);
    }
    push(items, front);
  }

  // -- Movement ----------------------------------------------------------------------------------
  let lastPos = null, lastT = 0, lastCast = null, lastFlight = '';
  const onFrame = (s) => {
    if (s?.session?.state !== 'inworld' || !s.self?.pos || s.map?.id == null) { lastPos = null; return; }
    const now = performance.now();
    const map = s.map.id, [x, y] = s.self.pos;

    // A cast with a known destination: fetch it now, ahead of everything else.
    const spell = s.self.casting?.spellId ?? null;
    if (spell !== lastCast) {
      lastCast = spell;
      let dest = null;
      if (TO_BIND.has(spell) && s.self.bind?.pos) dest = [s.self.bind.map, s.self.bind.pos[0], s.self.bind.pos[1]];
      else if (FIXED[spell]) dest = FIXED[spell];
      if (dest) {
        const [m, dx, dy] = dest, [tx, ty] = tileOf(dx, dy);
        const around = [];
        for (let i = -1; i <= 1; i++) for (let j = -1; j <= 1; j++) around.push([tx + i, ty + j]);
        status.last = { why: 'cast', spell, map: m };
        tiles(m, around, { front: true });
      }
    }

    // A flight: the whole path, in order from here.
    const nodes = s.self.flight?.nodes;
    const fkey = Array.isArray(nodes) ? nodes.join(',') : '';
    if (fkey && fkey !== lastFlight) {
      lastFlight = fkey;
      status.last = { why: 'flight', nodes: nodes.length };
      flightPath(nodes).then((pts) => {
        if (!pts.length) return;
        let start = 0, best = Infinity;
        pts.forEach(([m, px, py], i) => { if (m === map) { const d = Math.hypot(px - x, py - y); if (d < best) { best = d; start = i; } } });
        const seen = new Set(), ordered = [];
        for (const [m, px, py] of pts.slice(start)) {
          const t = tileOf(px, py), k = m + ':' + t.join('_');
          if (!seen.has(k)) { seen.add(k); ordered.push([m, t]); }
        }
        // The next 12 tiles of the path with their models, then the rest as terrain only (the
        // client streams the models in as it flies; terrain is what a fast flight outruns).
        ordered.forEach(([m, t], j) => tiles(m, [t], { models: j < 12 }));
      }).catch(() => {});
    } else if (!fkey) {
      lastFlight = '';
    }

    // Moving on foot or mounted: along the heading, as far as ~25 s at this speed.
    if (lastPos && now - lastT >= 1000) {
      const dt = (now - lastT) / 1000, vx = (x - lastPos[0]) / dt, vy = (y - lastPos[1]) / dt;
      const speed = Math.hypot(vx, vy);
      if (speed > 1.5 && speed < 200 && !fkey) {
        const reach = Math.min(LOOK_MAX, Math.max(LOOK_MIN, speed * LOOK_SECS));
        tiles(map, tilesAlong(x, y, vx, vy, TILE * 0.75, reach));
      }
      lastPos = [x, y]; lastT = now;
    } else if (!lastPos) {
      lastPos = [x, y]; lastT = now;
    }
  };
  // The world map: every zone of this continent, once per continent, 20 s after the world is up.
  const mapsDone = new Set();
  let mapAt = 0;
  function worldMap(s) {
    const map = s.map?.id;
    if (map == null || mapsDone.has(map)) return;
    const ready = performance.getEntriesByName('ow:stage:world-ready')[0]?.startTime
      ?? performance.getEntriesByName('ow:stage:world-enter')[0]?.startTime;
    if (ready == null || performance.now() - ready < 20000 || performance.now() < mapAt) return;
    mapsDone.add(map);
    mapAt = performance.now() + 5000;
    getBuf('DBFilesClient\\WorldMapArea.dbc').then((b) => {
      if (!b) return;
      const urls = mapFolders(b, map).flatMap((f) => mapTileUrls(f.name));
      status.mapTiles = (status.mapTiles || 0) + urls.length;
      push(urls.map((u) => [u, 'map', map]));
    }).catch(() => {});
  }

  let next = 0;
  wenilla.on('frame', (s) => {
    const t = performance.now();
    if (t < next) return;
    next = t + 250;
    try { onFrame(s); } catch (e) { console.warn('ow/ahead.js', e); }
    if (s?.session?.state === 'inworld') { try { worldMap(s); } catch { /* next frame */ } }
  });
  return status;
}
