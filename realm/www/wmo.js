// ow/wmo.js — fetch a building's pieces in parallel.
//
// A WMO (a building, a city, a cave) is a root file plus one file per group: Stormwind is 274
// groups, Blackrock 46, Northshire Abbey 15, the Goldshire inn 13. The client asks for the groups
// one after another, each only once the last one has arrived, and the loading screen waits for all
// of them. From the US (~160 ms to the realm) Stormwind alone was two minutes at the very end of
// the loading bar.
//
// This module watches the client's own fetch() of a root .wmo, reads the group count from its MOHD
// header, and fetches every group straight away, GROUPS_AT_ONCE at a time. When the client then asks
// for a group, it gets the in-flight request (or the HTTP cache, /data is immutable): no new round
// trip. Same URLs as the client's, so nothing is downloaded twice.
//
// Only network work, nothing decoded beyond the 8-byte group count. ?nowmo=1 turns it off.
// window.owWmo: { roots, groups, ahead, waitedOn, bytes } for owdiag.

const GROUPS_AT_ONCE = 12;
const MAX_GROUPS = 512;
const ROOT = /\.wmo$/i;
const GROUP = /_\d{3}\.wmo$/i;

const stats = { roots: 0, groups: 0, ahead: 0, waitedOn: 0, bytes: 0 };
const inflight = new Map();   // absolute URL -> Promise that settles once ours is in the HTTP cache
const queued = new Set();

function abs(u) {
  try { return new URL(u, location.href).href; } catch { return null; }
}

/** The group count in a root WMO's MOHD chunk (chunk ids are stored reversed: 'DHOM'). */
export function groupCount(buf) {
  const dv = new DataView(buf);
  let off = 0;
  while (off + 8 <= dv.byteLength) {
    const id = String.fromCharCode(dv.getUint8(off), dv.getUint8(off + 1), dv.getUint8(off + 2), dv.getUint8(off + 3));
    const size = dv.getUint32(off + 4, true);
    if (id === 'DHOM' || id === 'MOHD') return off + 16 <= dv.byteLength ? dv.getUint32(off + 12, true) : 0;
    off += 8 + size;
  }
  return 0;
}

/** The group URLs of a root URL: name.wmo -> name_000.wmo .. name_(n-1).wmo, query kept. */
export function groupUrls(rootUrl, n) {
  const u = new URL(rootUrl, location.href);
  const out = [];
  for (let i = 0; i < Math.min(n, MAX_GROUPS); i++) {
    const g = new URL(u.href);
    g.pathname = u.pathname.replace(ROOT, '_' + String(i).padStart(3, '0') + '.wmo');
    out.push(g.href);
  }
  return out;
}

export function installWmo() {
  if (new URLSearchParams(location.search).get('nowmo') === '1') return null;
  if (window.__owWmo) return window.__owWmo;
  const realFetch = window.fetch.bind(window);
  let running = 0;
  const queue = [];

  function pump() {
    while (running < GROUPS_AT_ONCE && queue.length) {
      const url = queue.shift();
      if (inflight.has(url)) continue;
      running += 1;
      stats.ahead += 1;
      // Read it to the end, so the browser's HTTP cache holds all of it (/data is immutable).
      const done = realFetch(url, { credentials: 'same-origin' })
        .then((r) => (r.ok ? r.arrayBuffer().then((b) => { stats.bytes += b.byteLength; }) : null))
        .catch(() => {});
      inflight.set(url, done);
      done.finally(() => {
        running -= 1;
        setTimeout(() => inflight.delete(url), 30000);
        pump();
      });
    }
  }

  function planGroups(rootUrl, resp) {
    resp.clone().arrayBuffer().then((buf) => {
      const n = groupCount(buf);
      if (!n) return;
      stats.roots += 1;
      stats.groups += n;
      for (const g of groupUrls(rootUrl, n)) {
        if (!queued.has(g)) { queued.add(g); queue.push(g); }
      }
      pump();
    }).catch(() => {});
  }

  window.fetch = function owFetch(input, init) {
    const raw = typeof input === 'string' ? input : input instanceof URL ? input.href : input?.url;
    const url = raw && abs(raw);
    if (url && url.includes('/data/') && (!init || !init.method || init.method === 'GET')) {
      const path = new URL(url).pathname;
      const mine = inflight.get(url);
      if (mine) {
        // ours is on its way: wait for it, then the client's own request is a cache hit
        stats.waitedOn += 1;
        return mine.then(() => realFetch(input, init));
      }
      if (ROOT.test(path) && !GROUP.test(path)) {
        const p = realFetch(input, init);
        p.then((r) => { if (r.ok) planGroups(url, r); }).catch(() => {});
        return p;
      }
    }
    return realFetch(input, init);
  };
  window.__owWmo = stats;
  window.owWmo = stats;
  return stats;
}
