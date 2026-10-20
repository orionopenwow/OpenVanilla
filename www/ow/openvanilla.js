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

    /* The pre-login loading overlay (web/boot.js #wenilla-boot): Open Vanilla art instead of black. */
    #wenilla-boot { background: #05040c url("${BASE}login-backdrop.webp") center / cover no-repeat !important; }
    #wenilla-boot > video.ow-boot-video { position: absolute; inset: 0; width: 100%; height: 100%;
      object-fit: cover; z-index: -1; pointer-events: none; }
    #wenilla-boot { isolation: isolate; }
    #wenilla-boot .box { position: relative; margin-top: 52vh; padding: 12px 16px 10px;
      background: rgba(6,4,14,.62); border: 1px solid rgba(201,162,39,.35); border-radius: 8px;
      box-shadow: 0 8px 30px rgba(0,0,0,.55); }
    #wenilla-boot .stage { color: #f0e2b6; font-family: Georgia, serif; letter-spacing: .03em; }
    #wenilla-boot .bar { background: rgba(255,255,255,.08) !important; }
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
      s.src = BASE + f;
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

export function install(wenilla) {
  try { style(); } catch (e) { console.warn('openvanilla.js style', e); }
  try { dock(); } catch (e) { console.warn('openvanilla.js dock', e); }
  try { bootArt(); } catch (e) { console.warn('openvanilla.js boot art', e); }
  try { diag(wenilla); } catch (e) { console.warn('openvanilla.js diag', e); }
}
