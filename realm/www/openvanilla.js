// ow/openvanilla.js — Open Vanilla's page layer, loaded by bridge.js on the realm and by game.html locally.
//
// Everything here is page-side, so it ships WITHOUT rebuilding the realm image or restarting
// anything: on the realm it lives in /opt/openvanilla-classicplus/www, bind-mounted at /app/www/ow,
// and hetzner/openvanilla_hotpatch.sh swaps it in place (players get it on their next page load).
//
//   * Account dock: the page's account links (admin, password, bell, full screen, sign out) fold
//     into a small handle at the top centre, so nothing sits on the minimap. Click to open.
//   * Boot screen: the pre-login loading overlay shows the Open Vanilla art and loop instead of black.
//   * window.owdiag: the self-test kit (owdiag.js), loaded on first use or with ?diag=1.
//   * Busy realm: a tiny, dismissible "Play Solo on your PC" note when the realm is full, slow or down.
//   * Loading: stage timings (stages.js), the memory store for the client's synchronous reads
//     (syncread.js), the glue prefetch (prefetch.js), fetch-ahead in the world (ahead.js) and the
//     service worker switch (sw-register.js). No file names, counts or bytes on screen: the boot
//     overlay's numbers are hidden here (they go to owdiag and the console).
//   * Corner logo: the Open Vanilla logo top-left on the login, character and create screens, in place
//     of the client's WoW logo (engine patch 0010 drops that one when the page says
//     glue_logo: 'page').
//   * Signing in: when the play page hands the client its game login (it signs in by itself), a
//     "Signing in" screen covers the empty login form until the character list is up, so players
//     never see a login screen they don't need. A failed sign-in uncovers it after a few seconds.
//
//   * Slim boot list: the boot prefetch (boot.js) skips the login music (3 MB) so it doesn't
//     compete with the client and the files the engine needs before the login screen; the
//     client fetches it itself when it plays it.
//
//   * Touch controls: ow/touch.js (stick, action cluster, menu drawer, gestures) on touch screens.
//   * Launcher line: one static line on the in-game loading screens (engine 'world-loading' until
//     'world-ready', through stages.js's 'ow:progress' event) pointing at the desktop launcher.
//   * First-visit textures: a browser's first time in the world uses lite textures (sw-register.js);
//     the game's addons are told (WenillaCore.liteTextures) so the setup window can say full detail
//     arrives from the next visit, and the browser is marked for full textures after 2 minutes in
//     the world or on leaving.
//
// Never load-bearing: any failure here leaves the game exactly as it was.

const BASE = new URL('./', import.meta.url).href;
const STYLE_ID = 'ow-page-style';

function style() {
  if (document.getElementById(STYLE_ID)) return;
  const s = document.createElement('style');
  s.id = STYLE_ID;
  s.textContent = `
    #ow-dock { position: fixed; top: 0; left: 50%; transform: translateX(-50%); z-index: 30;
      display: flex; flex-direction: column; align-items: center; font: 12px system-ui, sans-serif; }
    #ow-dock-handle { all: unset; cursor: pointer; padding: 1px 14px 3px; color: #e8d7a8;
      background: rgba(10,8,18,.55); border: 1px solid rgba(201,162,39,.35); border-top: 0;
      border-radius: 0 0 8px 8px; opacity: .45; transition: opacity .15s; line-height: 12px; font-size: 11px;
      letter-spacing: .08em; }
    #ow-dock-handle:hover, #ow-dock.open #ow-dock-handle, #ow-dock-handle:focus-visible { opacity: 1; }
    #ow-dock-panel { display: none; margin-top: 2px; padding: 6px 10px; gap: 2px 4px; flex-wrap: wrap;
      justify-content: center; align-items: center; max-width: min(520px, 92vw);
      background: rgba(10,8,18,.9); border: 1px solid rgba(201,162,39,.5); border-radius: 8px;
      box-shadow: 0 6px 24px rgba(0,0,0,.6); color: #bbb; }
    #ow-dock.open #ow-dock-panel { display: flex; }
    #ow-dock-panel #bar, #ow-dock-panel #fs, #ow-dock-panel #bell, #ow-dock-panel #portal-btn {
      position: static !important; inset: auto !important; transform: none !important;
      background: none !important; border: 0 !important; border-radius: 0 !important;
      padding: 2px 4px !important; margin: 0 !important; display: inline-flex; flex-wrap: wrap;
      align-items: center; gap: 2px 6px; font: 12px system-ui, sans-serif !important; }
    #ow-dock-panel a, #ow-dock-panel button { color: #e8e2d0 !important; padding: 3px 6px !important;
      margin: 0 !important; border-radius: 4px; }
    #ow-dock-panel a:hover, #ow-dock-panel button:hover { background: rgba(201,162,39,.18) !important; }

    /* The launcher line: centred just above the loading bar (the bar spans 5–10% of the height
       from the bottom of the 4:3 area, which is the full window height). */
    #ow-launcher-line { position: fixed; left: 50%; bottom: 11.5vh; transform: translateX(-50%); z-index: 20;
      max-width: min(92vw, 120vh); pointer-events: none; text-align: center; white-space: nowrap;
      font: 600 clamp(11px, 1.7vh, 17px) 'OW Cinzel', Georgia, serif; letter-spacing: .06em; color: #e8d7a8;
      text-shadow: 0 1px 3px #000, 0 0 10px rgba(0,0,0,.9); opacity: 0; transition: opacity .4s; }
    #ow-launcher-line b { color: #f0c058; font-weight: 600; }
    #ow-launcher-line.on { opacity: 1; }
    /* "Signing in": over the client's login form while it signs in with the page's login. The
       art is the "Signing In" loop (ow-signin.mp4 or its VP9 copy, about 0.3 MB): its 33 KB poster paints
       first, and the video is fetched only when this screen actually shows. */
    #ow-signin { position: fixed; inset: 0; z-index: 25; overflow: hidden;
      background: #05040c url("${BASE}ow-signin.webp") center / cover no-repeat; transition: opacity .35s; }
    #ow-signin.off { opacity: 0; pointer-events: none; }
    #ow-signin video { width: 100%; height: 100%; object-fit: cover; display: block; }
    /* Portrait phones: the frame at 225% of the width, so its "Signing In" panel (37% of the
       frame) fills about 84% of the screen and is never cropped; night sky above and below. */
    @media (max-aspect-ratio: 1/1) {
      #ow-signin { background: radial-gradient(120% 60% at 50% 50%, #241a4a 0%, #0b0820 55%, #05040c 100%); }
      #ow-signin video { position: absolute; top: 50%; left: 50%; width: 225vw; height: auto; transform: translate(-50%, -50%); }
    }
    #ow-signin .ow-signin-text { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; }
    /* The pre-login loading overlay (web/boot.js #wenilla-boot): Open Vanilla art instead of black. */
    #wenilla-boot { background: #05040c url("${BASE}login-backdrop.webp") center / cover no-repeat !important; }
    #wenilla-boot > video.ow-boot-video { position: absolute; inset: 0; width: 100%; height: 100%;
      object-fit: cover; z-index: -1; pointer-events: none; }
    #wenilla-boot { isolation: isolate; }
    /* The loading box, in Open Vanilla's look: a framed panel with gold filigree corners, the dragon
       endcaps either side of an arcane-blue bar, and the line in Cinzel. "html body" outranks the
       overlay's own <style>, which comes later in the page. */
    @font-face { font-family: 'OW Cinzel'; src: url("${BASE}Cinzel-SemiBold.woff2") format("woff2"), url("${BASE}Cinzel-SemiBold.ttf") format("truetype"); font-display: swap; }
    html body #wenilla-boot .box { position: relative; margin-top: 52vh; width: min(560px, 88vw);
      padding: 18px 92px 22px; box-sizing: border-box;
      background: radial-gradient(120% 140% at 50% 0%, rgba(42,28,84,.80), rgba(8,6,18,.92) 70%);
      border: 1px solid #8a6a2c; border-radius: 10px;
      box-shadow: inset 0 0 0 1px rgba(255,215,130,.14), inset 0 0 36px rgba(70,50,160,.35), 0 14px 44px rgba(0,0,0,.7); }
    html body #wenilla-boot .box::before { content: ''; position: absolute; inset: 3px; pointer-events: none;
      background: url("${BASE}ow-corner-tl.png") top left / 40px 34px no-repeat,
        url("${BASE}ow-corner-tr.png") top right / 40px 34px no-repeat,
        url("${BASE}ow-corner-bl.png") bottom left / 40px 34px no-repeat,
        url("${BASE}ow-corner-br.png") bottom right / 40px 34px no-repeat; }
    html body #wenilla-boot .box::after { content: ''; position: absolute; left: 4px; right: 4px; bottom: 0; height: 70px;
      pointer-events: none; filter: drop-shadow(0 4px 8px rgba(0,0,0,.85));
      background: url("${BASE}ow-dragon-l.webp") left center / auto 70px no-repeat,
        url("${BASE}ow-dragon-r.webp") right center / auto 70px no-repeat; }
    html body #wenilla-boot .stage { margin: 0 0 14px; padding-bottom: 15px; text-align: center; font-size: 0;
      background: url("${BASE}ow-divider.png") bottom center / 78% auto no-repeat; }
    html body #wenilla-boot .stage::after { content: "Preparing your adventure…"; display: inline-block;
      font: 600 17px 'OW Cinzel', 'Cinzel', Georgia, serif; letter-spacing: .08em;
      background: linear-gradient(180deg, #fff3c4, #f0c058 55%, #b07a22); -webkit-background-clip: text; background-clip: text;
      color: transparent; filter: drop-shadow(0 2px 3px rgba(0,0,0,.9)); }
    html body #wenilla-boot .bar { height: 12px; background: #060912; border: 1px solid #b8913c; border-radius: 6px;
      box-shadow: inset 0 2px 5px #000, 0 0 0 1px rgba(0,0,0,.6), 0 0 16px rgba(60,120,255,.2); overflow: hidden; }
    html body #wenilla-boot .bar > i { position: relative; overflow: hidden; border-radius: 6px;
      background: linear-gradient(90deg, #1b5cb8, #298bf0 60%, #9be2ff);
      box-shadow: 0 0 12px #3ca2f5, inset 0 1px 2px rgba(255,255,255,.65); }
    html body #wenilla-boot .bar > i::after { content: ''; position: absolute; inset: 0; background-size: 220% 100%;
      background-image: linear-gradient(100deg, transparent 35%, rgba(255,255,255,.45) 50%, transparent 65%);
      animation: ow-boot-shimmer 2.2s linear infinite; }
    @keyframes ow-boot-shimmer { from { background-position: 120% 0; } to { background-position: -120% 0; } }
    @media (prefers-reduced-motion: reduce) { html body #wenilla-boot .bar > i::after { animation: none; } }
    @media (max-width: 520px) {
      html body #wenilla-boot .box { padding: 16px 64px 20px; }
      html body #wenilla-boot .box::after { height: 54px; background-size: auto 54px, auto 54px; left: 2px; right: 2px; }
      html body #wenilla-boot .stage::after { font-size: 13.5px; letter-spacing: .05em; } }
    html body #wenilla-boot .err { margin-bottom: 14px; text-align: center; font: 600 15px 'OW Cinzel', Georgia, serif; color: #ff9a8a; }
    /* No counts or bytes on screen: the overlay's "game data N/M" line and the corner line go
       (the bar still shows real progress). */
    #wenilla-boot .data, #wenilla-corner { display: none !important; }

    /* The corner logo on the glue screens, at the 4:3 glue area's top-left (the client
       pillarboxes its glue to 4:3 on wider windows), 14% of the height. */
    #ow-glue-logo { position: fixed; z-index: 5; pointer-events: none; user-select: none;
      top: 1.2vh; left: calc(max(0px, (100vw - 133.333vh) / 2) + 0.6vh); height: 14vh; width: auto;
      max-width: 40vw; object-fit: contain; filter: drop-shadow(0 2px 6px rgba(0,0,0,.6));
      opacity: 0; transition: opacity .35s ease; }
    #ow-glue-logo.on { opacity: 1; }
  `;
  document.head.append(s);
}

// -- Account dock ------------------------------------------------------------------------------

function dock() {
  if (document.getElementById('ow-dock')) return;
  // Realm page: one #bar. Local game.html: separate #portal-btn, #bell, #fs.
  const found = ['bar', 'portal-btn', 'bell', 'fs'].map((id) => document.getElementById(id)).filter(Boolean);
  const parts = found.filter((el) => !found.some((o) => o !== el && o.contains(el)));  // #bell sits inside #bar
  if (!parts.length) return;
  const root = document.createElement('div');
  root.id = 'ow-dock';
  const handle = document.createElement('button');
  handle.id = 'ow-dock-handle';
  handle.type = 'button';
  handle.title = 'Account, notifications, full screen, sign out';
  handle.setAttribute('aria-expanded', 'false');
  handle.textContent = '☰ menu';
  const panel = document.createElement('div');
  panel.id = 'ow-dock-panel';
  // A real move, not a copy: every listener (full screen, bell, sign-out form) stays attached.
  for (const p of parts) panel.append(p);
  // Lite textures: smaller world textures for slow connections (served by the realm, applied by
  // the service worker in sw-register.js). auto = on for Save-Data or 2g/3g.
  const lite = document.createElement('button');
  lite.type = 'button';
  lite.id = 'ow-lite';
  const NAMES = { auto: 'Textures: auto', on: 'Textures: lite', off: 'Textures: full' };
  const cur = () => { try { return localStorage.getItem('ow:lite') || 'auto'; } catch { return 'auto'; } };
  const show = () => { lite.textContent = NAMES[cur()] || NAMES.auto; };
  lite.title = 'Lite textures download about a quarter of the texture data. Takes effect on the next load.';
  lite.addEventListener('click', () => {
    const next = { auto: 'on', on: 'off', off: 'auto' }[cur()] || 'auto';
    if (window.owsw?.lite) window.owsw.lite(next); else { try { localStorage.setItem('ow:lite', next); } catch { /* storage off */ } }
    show();
  });
  show();
  panel.append(lite);
  root.append(handle, panel);
  document.body.append(root);
  const set = (open) => {
    root.classList.toggle('open', open);
    handle.setAttribute('aria-expanded', String(open));
  };
  handle.addEventListener('click', (e) => { e.stopPropagation(); set(!root.classList.contains('open')); });
  // Clicking back into the game closes it, so it never steals the canvas for long.
  document.addEventListener('pointerdown', (e) => { if (!root.contains(e.target)) set(false); }, true);
  panel.addEventListener('click', (e) => { if (e.target.closest('a,button') && e.target.id !== 'bell') setTimeout(() => set(false), 0); });
}

// -- Boot screen -------------------------------------------------------------------------------

function bootArt() {
  const reduce = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches || navigator.connection?.saveData;
  const dress = (el) => {
    if (reduce || el.querySelector('video.ow-boot-video')) return;
    const v = document.createElement('video');
    v.className = 'ow-boot-video';
    Object.assign(v, { muted: true, defaultMuted: true, loop: true, playsInline: true, autoplay: true });
    v.setAttribute('muted', '');
    v.setAttribute('playsinline', '');
    for (const [f, t] of [['login-backdrop.mp4', 'video/mp4; codecs="avc1.640028"'], ['login-backdrop.webm', 'video/webm; codecs="vp9"']]) {
      const s = document.createElement('source');
      s.src = '/' + f;   // the same clip the page's own login backdrop already loads: one download, not two
      s.type = t;
      v.append(s);
    }
    v.lastElementChild.addEventListener('error', () => v.remove());
    el.prepend(v);
    v.play().catch(() => {});
  };
  const now = document.getElementById('wenilla-boot');
  if (now) dress(now);
  const mo = new MutationObserver(() => {
    const el = document.getElementById('wenilla-boot');
    if (el) dress(el);
  });
  mo.observe(document.body, { childList: true });
  setTimeout(() => mo.disconnect(), 120000);
}

// -- Slim boot list ----------------------------------------------------------------------------

// boot.js and warmup.js read /boot-manifest.json and prefetch every name in it. Music and long
// sounds are only played, never read before the login screen, so leave them out of that rush.
const SKIP_AT_BOOT = /\.(mp3|wav)$/i;
function slimBoot() {
  if (window.__owSlimBoot) return;
  window.__owSlimBoot = true;
  const orig = window.fetch;
  window.fetch = function (input, init) {
    const url = typeof input === 'string' ? input : (input instanceof URL ? input.href : input?.url);
    const p = orig.apply(this, arguments);
    let path = '';
    try { path = url ? new URL(url, location.href).pathname : ''; } catch { /* not a URL */ }
    if (path !== '/boot-manifest.json') return p;
    return p.then(async (r) => {
      try {
        if (!r.ok) return r;
        const j = await r.clone().json();
        if (!j || !Array.isArray(j.names)) return r;
        const names = j.names.filter((n) => !SKIP_AT_BOOT.test(n));
        if (names.length === j.names.length) return r;
        return new Response(JSON.stringify({ ...j, names }), { status: r.status, statusText: r.statusText, headers: r.headers });
      } catch { return r; }
    });
  };
}

// -- Launcher line on the loading screens -------------------------------------------------------

function launcherLine() {
  const el = document.createElement('div');
  el.id = 'ow-launcher-line';
  el.innerHTML = 'Load faster with the <b>Open Vanilla desktop launcher</b> &middot; openvanilla.app';
  let safety = 0;
  const off = () => { el.classList.remove('on'); clearTimeout(safety); };
  window.addEventListener('ow:progress', (e) => {
    if (e.detail === 'world-loading') {
      if (!el.isConnected) document.body.append(el);
      el.classList.add('on');
      clearTimeout(safety);
      safety = setTimeout(off, 180000);   // never left on screen by a missed 'world-ready'
    } else if (e.detail === 'world-ready') {
      off();
    }
  });
}

// -- First-visit textures ------------------------------------------------------------------------

function firstVisitTextures(wenilla) {
  if (!wenilla?.on) return;
  let first = false;
  try { first = !localStorage.getItem('ow:lite') && localStorage.getItem('ow:fulltex') !== '1'; } catch { return; }
  if (!first) return;
  let inWorld = false, told = false;
  const markFull = () => { try { localStorage.setItem('ow:fulltex', '1'); } catch { /* storage off */ } };
  const tell = async () => {
    // Only when the worker that serves the lite copies is really answering this page.
    if (told || window.owsw?.mode !== 'on' || !navigator.serviceWorker?.controller) return;
    for (let i = 0; i < 10 && !told; i++) {
      try {
        const r = await wenilla.lua('if WenillaCore then WenillaCore.liteTextures = true return "ok" end return "no"', 3000);
        if (r && r[0] === 'ok') { told = true; break; }
      } catch { /* VM busy: try again */ }
      await new Promise((res) => setTimeout(res, 1500));
    }
  };
  wenilla.on('state', (s) => {
    if (s?.state !== 'inworld' || inWorld) return;
    inWorld = true;
    tell();
    setTimeout(markFull, 120000);
  });
  window.addEventListener('pagehide', () => { if (inWorld) markFull(); });
}

// -- Signing in --------------------------------------------------------------------------------

// The play page sets window.__wenilla_env (with the game login) once; glueLogo() watches for it
// and reports here, so there is one watcher on that global.
const envWatchers = [];
let envLast = null;
function envSeen(x) {
  if (!x || x === envLast) return;
  envLast = x;
  for (const f of envWatchers) { try { f(x); } catch { /* never load-bearing */ } }
}

function signingIn(wenilla) {
  if (!wenilla?.on) return;           // no screen states to follow: leave the login screen alone
  const GIVE_UP_MS = 12000;           // a failed sign-in: show the client's own message
  let cover = null, done = false, timer = 0;
  function hide() {
    done = true;
    clearTimeout(timer);
    if (!cover) return;
    const c = cover;
    cover = null;
    c.classList.add('off');
    setTimeout(() => { c.querySelector('video')?.pause(); c.remove(); }, 400);
  }
  function show(env) {
    if (done || cover || !(env?.user && env?.pass)) return;
    cover = document.createElement('div');
    cover.id = 'ow-signin';
    cover.setAttribute('role', 'status');
    cover.innerHTML = '<div class="ow-signin-text">Signing in</div>';
    // The poster (the cover's background) is the whole screen for reduced-motion and Data Saver.
    const still = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches || navigator.connection?.saveData === true;
    if (!still) {
      const v = document.createElement('video');
      v.muted = v.defaultMuted = v.loop = v.playsInline = v.autoplay = true;
      v.disablePictureInPicture = true;
      v.setAttribute('muted', ''); v.setAttribute('playsinline', ''); v.setAttribute('aria-hidden', 'true');
      v.poster = BASE + 'ow-signin.webp';
      // H.264 first, VP9 where H.264 isn't built in; the browser fetches only the one it plays.
      for (const [file, type] of [['ow-signin.mp4', 'video/mp4; codecs="avc1.640028"'], ['ow-signin.webm', 'video/webm; codecs="vp9"']]) {
        const src = document.createElement('source');
        src.src = BASE + file; src.type = type; v.append(src);
      }
      v.lastElementChild.addEventListener('error', () => v.remove());
      cover.append(v);
      v.play?.().catch(() => {});
    }
    document.body.append(cover);
    timer = setTimeout(hide, GIVE_UP_MS);
  }
  wenilla.on('state', (s) => {
    const name = s?.state;
    // Past the login form: the character list (realm given), the realm list, or straight in.
    if (name === 'charselect' || name === 'charcreate' || name === 'inworld' || /realm/i.test(name || '')) hide();
  });
  envWatchers.push(show);
  if (envLast) show(envLast);
}

// -- Corner logo -------------------------------------------------------------------------------

function glueLogo(wenilla) {
  // Only when the play page asked the client to leave the corner to us (patched play.html sets
  // glue_logo: 'page' in window.__wenilla_env, which the page deletes after boot): catch it
  // whether it is already there or set later.
  let wanted = window.__wenilla_env?.glue_logo === 'page';
  envSeen(window.__wenilla_env);
  if (!wanted && !('__wenilla_env' in window)) {
    try {
      let v;
      Object.defineProperty(window, '__wenilla_env', {
        configurable: true,
        get: () => v,
        set: (x) => { v = x; envSeen(x); if (x?.glue_logo === 'page') { wanted = true; sync(); } },
      });
    } catch { /* leave it */ }
  }
  const img = document.createElement('img');
  img.id = 'ow-glue-logo';
  img.alt = 'Open Vanilla';
  img.decoding = 'async';
  img.src = BASE + 'ow-corner-logo.webp';
  img.srcset = `${BASE}ow-corner-logo.webp 1x, ${BASE}ow-corner-logo@2x.webp 2x`;
  let state = 'login';
  const GLUE = new Set(['login', 'charselect']);  // not charcreate: it sat on the Alliance/Horde panel
  function sync() {
    if (wanted && !img.isConnected) document.body.append(img);
    img.classList.toggle('on', wanted && GLUE.has(state));
  }
  wenilla?.on?.('state', (s) => { state = s?.state || state; sync(); });
  // The boot overlay sits above until the first glue screen; the logo fades in under it.
  sync();
}

// -- Diagnostics -------------------------------------------------------------------------------

function diag(wenilla) {
  let mod = null;
  const load = () => (mod ??= import(BASE + 'owdiag.js').then((m) => m.createDiag(wenilla)));
  // A tiny stub: the first call loads the kit. owdiag.run() resolves to a compact JSON report.
  window.owdiag = new Proxy({}, {
    get: (_, name) => (...args) => load().then((d) => (typeof d[name] === 'function' ? d[name](...args) : d[name])),
  });
  load().then((d) => d.capture()).catch(() => {});  // start the error/network log early; cheap
  if (new URLSearchParams(location.search).get('diag')) {
    load().then((d) => d.autorun()).catch((e) => console.warn('owdiag:', e));
  }
}

// -- Busy realm: offer Play Solo ------------------------------------------------------------------
// /healthz answers after one world-server console command, so its round trip is the world's own
// latency. Same thresholds as the launcher (play_local.py classify): world or database down, a queue,
// 95% of the player limit, or two answers slower than 1.5 s. Three looks per page load at most (it costs
// the world a console command), and a dismissed banner stays dismissed for the tab. The link opens a new
// tab, so a place in the login queue here is kept.

const SOLO_URL = 'https://openvanilla.app/solo.html';

async function realmLoad() {
  const t0 = performance.now();
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 8000);
  try {
    const r = await fetch('/healthz', { cache: 'no-store', signal: ctl.signal });
    const ms = performance.now() - t0;
    let d = {};
    try { d = await r.json(); } catch { /* not JSON */ }
    const w = (d && typeof d.world === 'object' && d.world) || d || {};
    const num = (...keys) => keys.map((k) => w[k]).find((v) => typeof v === 'number');
    const queue = num('queue', 'queued') || 0;
    const players = num('players', 'players_online', 'online');
    const limit = num('player_limit', 'max_players', 'limit');
    if (r.status === 404) return { state: 'unknown' };  // a page without the realm service (local game.html)
    if (d.soap === false || d.mariadb === false || r.status >= 500) return { state: 'down', why: 'The world server is down right now.' };
    if (queue > 0) return { state: 'full', why: `The realm is full: ${queue} in the queue.` };
    if (players != null && limit && players >= 0.95 * limit) return { state: 'full', why: 'The realm is full right now.' };
    if (ms >= 1500) return { state: 'slow', why: 'The realm is slow right now.' };
    return { state: 'ok' };
  } catch {
    return { state: 'down', why: "The realm isn't answering right now." };
  } finally {
    clearTimeout(timer);
  }
}

function busyBanner() {
  try { if (sessionStorage.getItem('ow:busy-off')) return; } catch { /* storage off */ }
  let slow = 0;
  let shown = null;
  const show = (why) => {
    if (shown) { shown.querySelector('span').textContent = why; return; }
    const css = document.createElement('style');
    css.textContent = `#ow-busy { position: fixed; left: 10px; bottom: 10px; z-index: 31; display: flex; gap: 8px;
      align-items: center; max-width: min(460px, calc(100vw - 20px)); padding: 5px 6px 5px 10px; border-radius: 8px;
      background: rgba(10,8,18,.9); border: 1px solid rgba(201,162,39,.55); color: #e8e2d0;
      font: 12px system-ui, sans-serif; box-shadow: 0 4px 16px rgba(0,0,0,.5); }
      #ow-busy a { color: #f3d179; font-weight: 600; white-space: nowrap; text-decoration: none; }
      #ow-busy a:hover { text-decoration: underline; }
      #ow-busy button { all: unset; cursor: pointer; color: #9a917f; padding: 0 4px; font-size: 14px; line-height: 1; }
      #ow-busy button:hover, #ow-busy button:focus-visible { color: #fff; }`;
    document.head.append(css);
    shown = document.createElement('div');
    shown.id = 'ow-busy';
    shown.setAttribute('role', 'status');
    const text = document.createElement('span');
    text.textContent = why;
    const link = document.createElement('a');
    link.href = SOLO_URL;
    link.target = '_blank';
    link.rel = 'noopener';
    link.textContent = 'Play Solo on your PC \u2192';
    link.title = 'Your own offline world with playerbots. Your place in the queue here is kept. Solo characters stay on your PC.';
    const close = document.createElement('button');
    close.type = 'button';
    close.textContent = '\u00d7';
    close.setAttribute('aria-label', 'Dismiss');
    close.addEventListener('click', () => {
      shown.remove();
      try { sessionStorage.setItem('ow:busy-off', '1'); } catch { /* storage off */ }
    });
    shown.append(text, link, close);
    document.body.append(shown);
  };
  const look = async () => {
    if (document.visibilityState === 'hidden' || !document.body) return;
    const r = await realmLoad();
    slow = r.state === 'slow' ? slow + 1 : 0;
    if (r.state === 'down' || r.state === 'full' || slow >= 2) show(r.why);
    else if (r.state === 'ok' && shown) { shown.remove(); shown = null; }
  };
  for (const at of [3000, 90000, 240000]) setTimeout(() => { look().catch(() => {}); }, at);
}

// -- Loading: glue prefetch, service worker (opt-in) -------------------------------------------

function loading(wenilla) {
  // The memory store first: the client's synchronous reads look in it from here on.
  import(BASE + 'syncread.js').then((m) => m.install()).catch((e) => console.warn('ow/syncread.js:', e));
  // A building's pieces in parallel (Stormwind: 274 files the client fetched one by one).
  import(BASE + 'wmo.js').then((m) => m.installWmo()).catch((e) => console.warn('ow/wmo.js:', e));
  // The one-at-a-time reads (game tables, interface, addons) into memory, 12 at a time.
  import(BASE + 'warmup.js').then((m) => m.installWarmup(wenilla)).catch((e) => console.warn('ow/warmup.js:', e));
  import(BASE + 'prefetch.js').then((m) => m.installPrefetch(wenilla)).catch((e) => console.warn('ow/prefetch.js:', e));
  import(BASE + 'ahead.js').then((m) => m.installAhead(wenilla)).catch((e) => console.warn('ow/ahead.js:', e));
  import(BASE + 'sw-register.js').then((m) => m.installServiceWorker()).catch((e) => console.warn('ow/sw-register.js:', e));
}

function touchMaybe() {
  try {
    if (new URLSearchParams(location.search).has('touch')) return true;
    if (localStorage.getItem('ow:touch')) return true;
  } catch { /* storage blocked */ }
  return (navigator.maxTouchPoints || 0) > 0;
}

export function install(wenilla) {
  // Before boot.js asks for its prefetch list.
  try { slimBoot(); } catch (e) { console.warn('openvanilla.js slim boot', e); }
  // Stage timings first, so the earliest stages are seen.
  import(BASE + 'stages.js').then((m) => m.installStages(wenilla)).catch((e) => console.warn('ow/stages.js:', e));
  // The mouse: re-focus on a press, capture the button, retry a refused pointer lock.
  import(BASE + 'input.js').then((m) => m.installInput()).catch((e) => console.warn('ow/input.js:', e));
  try { style(); } catch (e) { console.warn('openvanilla.js style', e); }
  try { dock(); } catch (e) { console.warn('openvanilla.js dock', e); }
  try { bootArt(); } catch (e) { console.warn('openvanilla.js boot art', e); }
  // The full-screen "Signing in" video (signingIn) is off: the login screen goes straight to the game.
  try { launcherLine(); } catch (e) { console.warn('openvanilla.js launcher line', e); }
  try { firstVisitTextures(wenilla); } catch (e) { console.warn('openvanilla.js first-visit textures', e); }
  try { glueLogo(wenilla); } catch (e) { console.warn('openvanilla.js glue logo', e); }
  try { diag(wenilla); } catch (e) { console.warn('openvanilla.js diag', e); }
  try { loading(wenilla); } catch (e) { console.warn('openvanilla.js loading', e); }
  try { busyBanner(); } catch (e) { console.warn('openvanilla.js busy banner', e); }
  // "Share what I'm listening to" (off by default): nowplaying.js -> Persona.SetListening.
  // Touch controls on phones and tablets (off with a mouse; ?touch=1 / ?touch=0 to force).
  // Only devices that can use them download the touch controls (113 KB): a touch screen, ?touch=,
  // or a saved choice. Elsewhere a connected controller still starts the bridge's gamepad mapper,
  // which touch.js otherwise does.
  if (touchMaybe()) {
    import(BASE + 'touch.js').then((m) => m.installTouch(wenilla)).catch((e) => console.warn('ow/touch.js:', e));
  } else {
    addEventListener('gamepadconnected', () => { try { wenilla?.gamepad?.start?.(); } catch { /* mapper missing */ } });
  }
  import(BASE + 'nowplaying.js').then((m) => m.installNowPlaying(wenilla)).catch((e) => console.warn('ow/nowplaying.js:', e));
}
