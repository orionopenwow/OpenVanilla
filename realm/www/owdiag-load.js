// ow/owdiag-load.js — Herald's `load` routine: what this page load cost, from the browser's own
// Resource Timing, in one small object. Same numbers devkit/loadlab/measure.mjs prints, read from
// inside the page.
//
//   await owdiag.snapshot(['load'])     (once the ROUTINE is added to owdiag-capture.js's list)
//
// Phases: boot = before the login screen; glue = login + character screens; world60 = the first
// 60 s after entering the world. Per phase: n requests to /data, how many came over the network,
// from the HTTP cache, or through the service worker, MB on the wire vs MB decoded, and the
// summed request time. "sw" = answered from the service worker's cache (it tags its responses
// with Server-Timing: owsw;desc=hit|net). States are seconds since navigation (marks set by ow/prefetch.js).
//
// Also (Open Vanilla 1.15): `stages` — ms since navigation for engine up, character list, world enter,
// world ready (loading screen cleared), first frame, sound ready, first movement, and the frame
// gaps over 100 ms in the first 30 s in the world (ow/stages.js); `syncRead` — the synchronous
// reads answered from memory (ow/syncread.js); `ahead` — the fetch-ahead (ow/ahead.js). Several
// runs, medians and p90: devkit/loadlab/measure.mjs --repeat 10.

const MB = (b) => Math.round((b / 1048576) * 100) / 100;
const S = (ms) => (ms == null ? null : Math.round(ms / 100) / 10);

// net: bytes came over the wire (a 304 counts: it is a round trip). sw: answered through the
// service worker with nothing on the wire. cache: the HTTP cache, no worker involved.
function from(e) {
  const sw = (e.serverTiming || []).find((t) => t.name === 'owsw')?.description;
  if (sw) return sw === 'hit' ? 'sw' : 'net';
  if (e.transferSize > 0 && e.deliveryType !== 'cache') return 'net';
  return 'cache';
}
// What crossed the wire: the worker's own network fetches report transferSize 0 to the page, so
// count their encoded size instead.
const wireOf = (e) => (from(e) === 'net' && !e.transferSize ? e.encodedBodySize || 0 : e.transferSize || 0);

function bucket(list) {
  const b = { n: list.length, net: 0, cache: 0, sw: 0, mb: 0, decodedMB: 0, ms: 0 };
  let wire = 0, dec = 0, dur = 0;
  for (const e of list) {
    b[from(e)] += 1;
    wire += wireOf(e);
    dec += e.decodedBodySize || 0;
    dur += e.duration || 0;
  }
  return Object.assign(b, { mb: MB(wire), decodedMB: MB(dec), ms: Math.round(dur) });
}

/**
 * entries: Resource Timing entries (or plain copies); nav: the navigation entry; marks:
 * { login, charselect, inworld } in ms since navigation; bootSet: Set of '/data/...' URL paths in
 * boot-manifest.json. Pure: measure.mjs runs the same function on entries copied out of a page.
 */
export function summarize(entries, nav, marks = {}, bootSet = new Set(), worldSecs = 60) {
  const path = (u) => { try { const x = new URL(u); return x.pathname + x.search; } catch { return u; } };
  const data = entries.filter((e) => path(e.name).startsWith('/data/'));
  const glueAt = marks.login ?? marks.charselect ?? Infinity;
  const worldAt = marks.inworld ?? Infinity;
  const wasm = entries.find((e) => /wenilla_bg\.wasm(\?|$)/.test(e.name));
  const boot = data.filter((e) => bootSet.has(path(e.name)) && e.initiatorType === 'fetch');
  const span = (l) => (l.length ? Math.round(Math.max(...l.map((e) => e.responseEnd)) - Math.min(...l.map((e) => e.startTime))) : 0);
  return {
    v: 1,
    nav: nav ? { ttfb: Math.round(nav.responseStart), dcl: Math.round(nav.domContentLoadedEventEnd), load: Math.round(nav.loadEventEnd) } : null,
    states: { login: S(marks.login), charselect: S(marks.charselect), inworld: S(marks.inworld) },
    wasm: wasm ? { mb: MB(wasm.transferSize), decodedMB: MB(wasm.decodedBodySize), ms: Math.round(wasm.duration), from: from(wasm) } : null,
    bootPrefetch: { n: boot.length, mb: MB(boot.reduce((a, e) => a + wireOf(e), 0)), ms: span(boot) },
    data: {
      boot: bucket(data.filter((e) => e.startTime < glueAt)),
      glue: bucket(data.filter((e) => e.startTime >= glueAt && e.startTime < worldAt)),
      world60: bucket(data.filter((e) => e.startTime >= worldAt && e.startTime < worldAt + worldSecs * 1000)),
      all: bucket(data),
    },
  };
}

function marksNow() {
  const m = {};
  for (const s of ['login', 'charselect', 'inworld']) {
    const e = performance.getEntriesByName('ow:state:' + s)[0];
    if (e) m[s] = e.startTime;
  }
  return m;
}

export const ROUTINE = {
  id: 'load',
  async run() {
    let bootSet = new Set();
    try {
      const m = await (await fetch('/boot-manifest.json')).json();
      bootSet = new Set((m.names || []).map((n) => '/data/' + encodeURIComponent(n)));
    } catch { /* no manifest: bootPrefetch reads 0 */ }
    const out = summarize(performance.getEntriesByType('resource'), performance.getEntriesByType('navigation')[0],
      marksNow(), bootSet);
    out.sw = navigator.serviceWorker?.controller ? 'controlled' : 'none';
    out.prefetch = window.owPrefetch ? { ...window.owPrefetch } : null;
    out.entries = performance.getEntriesByType('resource').length;
    out.stages = window.owStages ? { ...window.owStages.summary(), hitchList: window.owStages.hitches.slice(0, 20) } : null;
    out.syncRead = window.owSyncRead
      ? { hits: owSyncRead.hits, misses: owSyncRead.misses, heads: owSyncRead.heads, servedMB: MB(owSyncRead.bytesServed),
        held: owSyncRead.held, heldMB: MB(owSyncRead.heldBytes), fetched: owSyncRead.fetched, fromDisk: owSyncRead.fromDisk }
      : null;
    out.ahead = window.owAhead ? { ...window.owAhead, mb: MB(window.owAhead.bytes) } : null;
    return out;
  },
};
