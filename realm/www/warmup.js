// ow/warmup.js — the files the client reads one at a time, fetched ahead, many at a time.
//
// 1. The boot prefetch (boot.js) downloads boot-manifest.json's ~400 files 8 at a time. From the
//    US that took ~10 s. This helps from the other end of the same list, so the two meet in the
//    middle (same URLs: whichever comes second is an HTTP-cache hit).
// 2. manifests/_ui.json (tools/gen_ui_manifest.py): the synchronous reads the boot prefetch does
//    not cover — game tables, the stock interface (FrameXML) and every Classic+ addon's files,
//    ~400 reads that each cost a full round trip on the client's main thread (about a minute at
//    the end of the loading bar from the US). They go into ow/syncread.js's memory store, 12 at
//    a time: "boot" now, "world" right after, long before Enter World.
//
// ?nowarmup=1 turns it off. window.owWarmup: { state, bootHelp, boot, world, ms } for owdiag.

const BASE = new URL('./', import.meta.url);
const HELP_AT_ONCE = 8;
const dataUrl = (name) => '/data/' + name;

function slowLink() {
  const c = navigator.connection;
  return !!(c && (c.saveData || /(^|-)2g$|3g/.test(c.effectiveType || '')));
}

async function helpBoot(status) {
  try {
    const r = await fetch('/boot-manifest.json');
    if (!r.ok) return;
    const names = ((await r.json()) || {}).names || [];
    const mine = names.slice(Math.floor(names.length / 2)).reverse();   // the back half, from the end
    async function worker() {
      for (;;) {
        const name = mine.shift();
        if (name === undefined) return;
        try {
          const resp = await fetch('/data/' + encodeURIComponent(name), { credentials: 'same-origin' });
          if (resp.ok) await resp.arrayBuffer();
        } catch { /* boot.js or the client fetches it */ }
        status.bootHelp += 1;
      }
    }
    await Promise.all(Array.from({ length: HELP_AT_ONCE }, worker));
  } catch { /* nothing to help with */ }
}

export function installWarmup(wenilla) {
  const status = (window.owWarmup = { state: 'starting', bootHelp: 0, boot: 0, world: 0, ms: 0 });
  const q = new URLSearchParams(location.search);
  if (q.get('nowarmup') === '1' || slowLink()) {
    status.state = 'skipped';
    return status;
  }
  const t0 = performance.now();
  const syncread = import('./syncread.js').catch(() => null);
  const manifest = fetch(new URL('manifests/_ui.json', BASE), { cache: 'no-cache' })
    .then((r) => (r.ok ? r.json() : null))
    .catch(() => null);
  (async () => {
    const [sr, m] = await Promise.all([syncread, manifest]);
    const help = helpBoot(status);
    if (sr && m) {
      status.state = 'boot';
      await sr.warm((m.boot || []).map(dataUrl), { any: true, priority: 'high', onEach: (ok) => { status.boot += ok ? 1 : 0; } });
      status.state = 'world';
      await sr.warm((m.world || []).map(dataUrl), { any: true, onEach: (ok) => { status.world += ok ? 1 : 0; } });
    }
    await help;
    status.state = 'done';
    status.ms = Math.round(performance.now() - t0);
  })().catch((e) => { status.state = 'error'; status.error = String(e?.message || e); });
  return status;
}
