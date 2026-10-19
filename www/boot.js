// boot.js — the pre-login loading experience, shared by the dev page (web/index.html) and the
// realm page (crates/wenilla-realm/templates/play.html).
//
// Why this exists: the client cannot show its own boot. Everything a fresh tab waits on — the
// 15 MB (brotli) wasm download, instantiation, and the first update's catalog pile (~100+
// synchronous XHR chain reads in ONE rAF task, the "unresponsive tab" window) — happens before
// the first frame the app could draw. So the page owns a DOM overlay, and it does two jobs:
//
//   1. SHOW what is happening: a byte-counted wasm download bar (the counting stream is
//      re-wrapped in a Response so `WebAssembly.compileStreaming` still streams), a
//      "game data N/M" line for the prefetch, then indeterminate "Starting…" states driven by
//      the client's own `window.__wenilla_progress(stage)` calls (benilla-app/src/webprogress.rs)
//      until "ready" — the first glue screen — fades the overlay out.
//   2. SHRINK the unresponsive window: `/data/*` is served immutable (max-age=1y), and a sync
//      XHR is served from the HTTP cache when the same URL was fetch()ed first (verified live:
//      transferSize 0, deliveryType "cache"). So the overlay prefetches the boot read-set — a
//      checked-in manifest (boot-manifest.json) captured from a traced boot — with a small
//      fetch pool, in parallel with the wasm download. The catalog pile then costs parse, not
//      ~100 serial network round trips. Every miss (drift, missing manifest) degrades to
//      exactly today's behavior, and a warm-cache visitor flies through all of it: progress is
//      measured, never scripted.
//
// Page contract: `const w = await boot(init); bind(w.memory);` — bind must stay immediately
// after (the Lua WASI shims need the module's linear memory). Query switches: `?boottrace=1`
// arms window.__wenilla_boottrace and skips the prefetch (a manifest-capture boot must show the
// true read order); `?noprefetch=1` skips the prefetch only (the A/B lever).

// The wasm travels brotli-compressed: content-length counts .br bytes while the counted stream
// yields decompressed ones. Dividing the two on a real build gives ~5.0; it drifts a little per
// build and that is cosmetic — the bar is clamped at 99% until the stream actually ends.
const BR_RATIO = 5.0;
const READY_TIMEOUT_MS = 20000;
// Open Vanilla: 24 at once. HTTP/2 and HTTP/3 carry them on one connection, and from the US each
// file costs a ~160 ms round trip, so 8 left the boot set waiting on latency.
const PREFETCH_CONCURRENCY = 24;

export async function boot(init, opts = {}) {
  const q = new URLSearchParams(location.search);
  const ui = createBootUi();
  if (q.get('boottrace') === '1') window.__wenilla_boottrace = [];
  const skipPrefetch = q.get('boottrace') === '1' || q.get('noprefetch') === '1';
  installProgressHook(ui, skipPrefetch);

  const prefetch = skipPrefetch
    ? Promise.resolve()
    : prefetchManifest('./boot-manifest.json', (done, total) => ui.setData(done, total)).catch(
        () => ui.setData(0, 0)
      );

  // Compile immediately: merely fetching a Response leaves its body backpressured until
  // someone consumes it. Instantiation must still wait for the cache warmup because the
  // game's Startup performs synchronous reads of the prefetched catalogs.
  const wasm = compileWasm(new URL('./wenilla_bg.wasm', import.meta.url), (got, total) =>
    ui.setWasmProgress(got, total)
  );
  let w;
  try {
    // Attach rejection handlers to both operations now, including while prefetch is pending.
    const [module] = await Promise.all([wasm, prefetch]);
    w = await init({ module_or_path: module });
  } catch (e) {
    ui.fail('The client failed to start: ' + (e && e.message ? e.message : e));
    throw e;
  }
  // init() resolved = module instantiated and the plugin graph built; the heavy catalog frame
  // is still ahead. From here the client drives the stages; the timeout is the drift backstop
  // (an old bundle without webprogress under a new page must not strand the overlay).
  ui.setStage('Starting…');
  ui.armTimeout(opts.readyTimeoutMs ?? READY_TIMEOUT_MS);
  return w;
}

// Match wasm-bindgen's non-streaming fallback for servers without the WASM MIME type.
// Open Vanilla (Open Vanilla): compile the Response that fetch() returned, not a re-wrapped one. The
// browser can keep the compiled code with that HTTP cache entry (V8's wasm code cache), so a
// returning player skips recompiling the ~90 MB module; a constructed Response has no URL and no
// cache entry, so every visit compiled from scratch. The progress bar now reads a clone, which
// is drained as fast as it arrives, so the tee never holds more than a chunk or two.
async function compileWasm(url, onBytes) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`Client download failed (HTTP ${response.status})`);
  const streaming = typeof WebAssembly.compileStreaming === 'function' &&
    response.headers.get('content-type')?.trim().toLowerCase() === 'application/wasm';
  if (!streaming) {
    const bytes = await response.arrayBuffer();
    onBytes(bytes.byteLength, bytes.byteLength);
    return WebAssembly.compile(bytes);
  }
  if (response.body) countBytes(response.clone(), onBytes).catch(() => {});
  return WebAssembly.compileStreaming(response);
}

/// Drain a clone of the wasm Response to drive the progress bar; never touches the original.
async function countBytes(r, onBytes) {
  const contentLength = Number(r.headers.get('content-length')) || 0;
  const compressed = !!(r.headers.get('content-encoding') || '').trim();
  const total = contentLength ? contentLength * (compressed ? BR_RATIO : 1) : 0;
  let got = 0;
  const reader = r.body.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    got += value.byteLength;
    onBytes(got, total);
  }
  onBytes(got, got); // the honest total, now that we know it
}

/// Warm the HTTP cache with a manifest's read-set: fetch the manifest, then a fixed-size pool of
/// full-body fetches. Failures are counted as done and otherwise ignored — a miss just means
/// that file loads the old way. A missing/invalid manifest resolves immediately (line hides).
/// Used twice: the boot set before `init()`, the world-entry set after `ready`.
async function prefetchManifest(manifestUrl, onProgress) {
  const r = await fetch(manifestUrl);
  if (!r.ok) return onProgress(0, 0);
  const manifest = await r.json();
  const names = Array.isArray(manifest && manifest.names) ? manifest.names : [];
  if (!names.length) return onProgress(0, 0);
  let done = 0;
  onProgress(0, names.length);
  const queue = names.slice();
  async function worker() {
    for (;;) {
      const name = queue.shift();
      if (name === undefined) return;
      try {
        const resp = await fetch('/data/' + encodeURIComponent(name));
        if (resp.ok) await resp.arrayBuffer(); // body fully read = body fully cached
      } catch (_) {
        /* offline blip, 404 drift — the sync XHR path will deal with it */
      }
      done += 1;
      onProgress(done, names.length);
    }
  }
  await Promise.all(Array.from({ length: PREFETCH_CONCURRENCY }, worker));
}

/// `window.__wenilla_progress(stage)` — the client's calls land here (webprogress.rs).
///
/// `ready` also starts the SECOND prefetch: the world-entry read-set. Entering the world used
/// to be one frozen frame of ~200 synchronous sprite reads (184 `Interface\…\*.blp` on the
/// first UI draw, plus a few quest-marker models and zone sounds) — 206 s on a cold 100 ms-RTT
/// cache. That set is location-independent, so `world-manifest.json` (captured the same way
/// as the boot manifest, minus the boot set) is warmed while the player is at the glue screens,
/// with a corner line so it is visible but never in the way. Whatever is still in flight when
/// they click Enter World just loads the old way.
function installProgressHook(ui, skipPrefetch) {
  window.__wenilla_progress = (stage) => {
    if (stage === 'startup') ui.setStage('Loading interface…');
    else if (stage === 'ready') {
      ui.hide();
      if (!skipPrefetch) {
        const corner = createCornerLine();
        prefetchManifest('./world-manifest.json', (done, total) =>
          corner.set(total > 0 && done < total ? `preparing world data — ${done}/${total}` : '')
        )
          .catch(() => {})
          .finally(() => corner.remove());
      }
    }
  };
}

/// The unobtrusive bottom-left status line the world prefetch reports on.
function createCornerLine() {
  const el = document.createElement('div');
  el.id = 'wenilla-corner';
  el.style.cssText =
    'position:fixed;left:.6rem;bottom:.5rem;z-index:15;font:12px system-ui,sans-serif;' +
    'color:#888;background:rgba(0,0,0,.55);padding:.2rem .5rem;border-radius:4px;' +
    'pointer-events:none;transition:opacity .4s ease';
  document.body.appendChild(el);
  return {
    set(text) {
      el.textContent = text;
      el.style.opacity = text ? '1' : '0';
    },
    remove() {
      el.style.opacity = '0';
      setTimeout(() => el.remove(), 500);
    },
  };
}

function createBootUi() {
  const root = document.createElement('div');
  root.id = 'wenilla-boot';
  root.innerHTML = `
    <style>
      #wenilla-boot {
        position: fixed; inset: 0; z-index: 9999; display: flex; flex-direction: column;
        justify-content: space-between; align-items: center;
        background: #05060a url('assets/loading/background_clean.jpg') no-repeat center center;
        background-size: cover; color: #f0e6d2; font-family: 'Friz Quadrata', 'Cinzel', serif, system-ui;
        box-shadow: inset 0 0 160px rgba(0,0,0,0.85); transition: opacity .6s cubic-bezier(0.16, 1, 0.3, 1);
        user-select: none; padding: 2.5rem 1.5rem 3.5rem;
      }
      #wenilla-boot.gone { opacity: 0; pointer-events: none; }
      #wenilla-boot .brand-header {
        display: flex; flex-direction: column; align-items: center; margin-top: 1rem;
      }
      #wenilla-boot .brand-logo {
        max-width: 440px; width: 85vw; height: auto;
        filter: drop-shadow(0 0 35px rgba(50, 140, 255, 0.55)) drop-shadow(0 10px 30px rgba(0,0,0,0.95));
        animation: ow-logo-float 4s ease-in-out infinite alternate;
      }
      @keyframes ow-logo-float {
        0% { transform: translateY(0); filter: drop-shadow(0 0 25px rgba(50, 140, 255, 0.4)); }
        100% { transform: translateY(-6px); filter: drop-shadow(0 0 45px rgba(90, 180, 255, 0.7)); }
      }
      #wenilla-boot .bottom-dock {
        width: min(840px, 94vw); display: flex; flex-direction: column; align-items: center;
      }
      #wenilla-boot .game-tip {
        font-size: 13.5px; color: #dfcaa2; text-shadow: 0 2px 4px #000, 0 0 8px rgba(0,0,0,0.9);
        text-align: center; margin-bottom: 0.85rem; font-style: italic; max-width: 680px;
        line-height: 1.4;
      }
      #wenilla-boot .game-tip b { color: #ffd100; font-style: normal; }
      #wenilla-boot .bar-container {
        position: relative; width: 100%; max-width: 720px; display: flex; align-items: center; justify-content: center;
      }
      #wenilla-boot .dragon-endcap {
        width: 62px; height: 46px; flex-shrink: 0;
        filter: drop-shadow(0 4px 10px rgba(0,0,0,0.9));
        z-index: 2; pointer-events: none;
      }
      #wenilla-boot .dragon-endcap.left {
        margin-right: -14px;
      }
      #wenilla-boot .dragon-endcap.right {
        margin-left: -14px;
      }
      #wenilla-boot .bar-frame {
        position: relative; flex: 1; height: 22px;
        background: #060912; border: 2px solid #b8913c;
        box-shadow: 0 0 16px rgba(0,0,0,0.9), inset 0 2px 6px rgba(0,0,0,0.95);
        overflow: hidden; display: flex; align-items: center; border-radius: 2px;
      }
      #wenilla-boot .bar-fill {
        height: 100%; width: 0%;
        background: linear-gradient(90deg, #1b5cb8 0%, #298bf0 60%, #76d3ff 100%);
        box-shadow: 0 0 16px #3ca2f5, inset 0 1px 3px rgba(255,255,255,0.7);
        transition: width .2s ease-out;
      }
      #wenilla-boot .bar-frame.pulse .bar-fill {
        width: 35% !important; animation: ow-bar-pulse 1.4s ease-in-out infinite;
      }
      @keyframes ow-bar-pulse {
        0% { margin-left: -5%; } 50% { margin-left: 70%; } 100% { margin-left: -5%; }
      }
      #wenilla-boot .bar-glow {
        position: absolute; inset: 0; pointer-events: none;
        border: 1px solid rgba(255, 215, 0, 0.35);
      }
      #wenilla-boot .status-row {
        width: 100%; display: flex; justify-content: space-between; align-items: center;
        margin-top: 0.55rem; padding: 0 0.5rem; font-size: 12.5px; color: #a8b2c1;
        text-shadow: 0 1px 3px #000;
      }
      #wenilla-boot .stage-text { color: #e5c158; font-weight: 600; letter-spacing: 0.5px; }
      #wenilla-boot .file-counter { color: #8faec9; font-family: monospace; font-size: 12px; }
      #wenilla-boot .err { color: #ff5555; text-shadow: 0 0 8px rgba(255,0,0,0.6); }
    </style>
    <div class="brand-header">
      <img src="assets/openvanilla_logo.png" class="brand-logo" alt="Open Vanilla Browser RPG" />
    </div>
    <div class="bottom-dock">
      <div class="game-tip"><b>Tip:</b> Seek out the Ley-Architect's shrines throughout Azeroth to unlock Classic+ class enhancements and ancient boons.</div>
      <div class="bar-container">
        <img src="assets/loading/dragon_head_left.png" class="dragon-endcap left" alt="" />
        <div class="bar-frame">
          <div class="bar-fill"></div>
          <div class="bar-glow"></div>
        </div>
        <img src="assets/loading/dragon_head_right.png" class="dragon-endcap right" alt="" />
      </div>
      <div class="status-row">
        <span class="stage-text">Initializing client…</span>
        <span class="file-counter">Streaming game data…</span>
      </div>
    </div>`;
  document.body.appendChild(root);

  const stageEl = root.querySelector('.stage-text');
  const barFrame = root.querySelector('.bar-frame');
  const fillEl = root.querySelector('.bar-fill');
  const fileCounter = root.querySelector('.file-counter');
  let gone = false;
  let timeout = 0;
  const mb = (n) => (n / (1024 * 1024)).toFixed(1);

  return {
    setWasmProgress(got, total) {
      if (gone) return;
      if (total > 0) {
        const pct = Math.min(99, Math.floor((got / total) * 100));
        const done = got >= total;
        stageEl.textContent = done
          ? 'Engine Assembly Ready'
          : `Downloading Client — ${pct}%`;
        fileCounter.textContent = `${mb(got)} MB / ${mb(total)} MB`;
        fillEl.style.width = (done ? 100 : pct) + '%';
      } else {
        stageEl.textContent = 'Streaming Web Engine…';
        fileCounter.textContent = `${mb(got)} MB`;
        barFrame.classList.add('pulse');
      }
    },
    setData(done, total) {
      if (gone) return;
      if (total > 0) {
        const pct = Math.min(100, Math.floor((done / total) * 100));
        fileCounter.textContent = `World Chunks: ${done} / ${total} Files (${pct}%)`;
        fillEl.style.width = pct + '%';
      }
    },
    setStage(text) {
      if (gone) return;
      stageEl.textContent = text;
      barFrame.classList.add('pulse');
    },
    fail(text) {
      clearTimeout(timeout);
      barFrame.remove();
      stageEl.className = 'err';
      stageEl.textContent = text;
      fileCounter.textContent = 'Halted';
    },
    armTimeout(ms) {
      timeout = setTimeout(() => this.hide(), ms);
    },
    hide() {
      if (gone) return;
      gone = true;
      clearTimeout(timeout);
      root.classList.add('gone');
      setTimeout(() => root.remove(), 600);
    },
  };
}
