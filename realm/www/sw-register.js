// ow/sw-register.js — turns Open Vanilla's service worker (ow/sw.js) on or off for this browser and
// passes it the player's lite-texture setting. Imported by ow/openvanilla.js; never load-bearing.
//
// Who decides, highest first:
//   ?nosw=1 / ?sw=1          this browser, remembered (localStorage "ow:sw" = off / on)
//   localStorage "ow:sw"     a previous ?sw= choice
//   /ow/data-version.json    {"sw": "on" | "off" | "opt-in"} — the operator's switch for everyone
//                            ("off" also makes running workers remove themselves)
//   default                  opt-in: nothing happens until ?sw=1
//
// Lite textures: window.owsw.lite('on' | 'off' | 'auto'), remembered in localStorage "ow:lite";
// 'auto' turns lite on when the browser reports Save-Data or a 2g/3g connection. ?lite=1 / ?lite=0
// set it from the address bar. With no choice made, a browser's FIRST visit to the world uses lite
// textures (about 75% fewer bytes, so a new player gets in faster) and every later visit uses full
// ones: openvanilla.js sets "ow:fulltex" once the player has been in the world (see firstVisitTextures).
//
//   owsw.status()   -> what the worker holds (caches, entries, MB used of quota, data version)
//   owsw.clear()    -> delete the cached game data (the worker stays)
//   owsw.off()      -> unregister and delete everything (same as ?nosw=1)

const BASE = new URL('./', import.meta.url);
const SW_URL = new URL('sw.js', BASE).href;
const LS = (k, v) => {
  try {
    if (v === undefined) return localStorage.getItem(k);
    if (v === null) localStorage.removeItem(k); else localStorage.setItem(k, v);
  } catch { /* storage blocked: defaults apply */ }
  return null;
};

async function off() {
  // The worker keeps controlling this page until it unloads, unregistered or not: tell it to stop
  // answering (and storing) first, then unregister, then delete.
  navigator.serviceWorker.controller?.postMessage({ type: 'disable' });
  const regs = await navigator.serviceWorker.getRegistrations();
  await Promise.all(regs.filter((r) => r.active?.scriptURL === SW_URL || r.installing?.scriptURL === SW_URL ||
    r.waiting?.scriptURL === SW_URL).map((r) => r.unregister()));
  for (const k of await caches.keys()) if (k.startsWith('ow-')) await caches.delete(k);
}

function post(msg) {
  const target = navigator.serviceWorker.controller;
  if (target) target.postMessage(msg);
  else navigator.serviceWorker.ready.then((r) => r.active?.postMessage(msg)).catch(() => {});
}

function liteMode() {
  const q = new URLSearchParams(location.search).get('lite');
  if (q === '1' || q === 'on') LS('ow:lite', 'on');
  else if (q === '0' || q === 'off') LS('ow:lite', 'off');
  else if (q === 'auto') LS('ow:lite', 'auto');
  const chosen = LS('ow:lite');
  if (chosen) return chosen;
  return LS('ow:fulltex') === '1' ? 'auto' : 'on';   // first visit: lite; then full (lite only on slow links)
}

export async function installServiceWorker() {
  if (!('serviceWorker' in navigator) || !window.isSecureContext) return { state: 'unsupported' };
  const q = new URLSearchParams(location.search);
  if (q.get('nosw') === '1') LS('ow:sw', 'off');
  else if (q.get('sw') === '1') LS('ow:sw', 'on');
  let mode = LS('ow:sw');
  if (!mode) {
    try {
      const r = await fetch(new URL('data-version.json', BASE), { cache: 'no-store' });
      if (r.ok) mode = (await r.json()).sw || null;
    } catch { /* no file: opt-in */ }
  }
  mode ||= 'opt-in';
  const api = {
    mode,
    lite: (m) => { LS('ow:lite', m); post({ type: 'settings', settings: { lite: m } }); return m; },
    status: () => new Promise((resolve) => {
      const ch = (e) => { if (e.data?.type === 'status') { navigator.serviceWorker.removeEventListener('message', ch); resolve(e.data.status); } };
      navigator.serviceWorker.addEventListener('message', ch);
      post({ type: 'status' });
      setTimeout(() => resolve({ controlled: !!navigator.serviceWorker.controller, mode }), 3000);
    }),
    clear: () => post({ type: 'clear' }),
    recheck: () => post({ type: 'recheck' }),  // look at /ow/data-version.json now, not within 60 s
    off: () => { LS('ow:sw', 'off'); return off(); },
  };
  window.owsw = api;
  if (mode !== 'on') {
    // Off (or not opted in): make sure nothing of ours is left from an earlier choice.
    if ((await navigator.serviceWorker.getRegistrations()).some((r) => r.active?.scriptURL === SW_URL)) await off();
    return { state: mode };
  }
  navigator.storage?.persist?.().catch(() => {});
  try {
    await navigator.serviceWorker.register(SW_URL, { scope: '/', updateViaCache: 'none' });
  } catch (e) {
    // Most likely the realm does not send Service-Worker-Allowed: / for /ow/sw.js yet.
    console.warn('ow/sw-register: service worker not registered:', e?.message || e);
    return { state: 'failed', error: String(e?.message || e) };
  }
  post({ type: 'settings', settings: { lite: liteMode() } });
  return { state: 'on', controlled: !!navigator.serviceWorker.controller };
}
