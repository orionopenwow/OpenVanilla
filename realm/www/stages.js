// ow/stages.js — when each step of a visit happened, and whether the first 30 s in the world
// stuttered. Installed first thing by ow/openvanilla.js; read by owdiag's `load` routine
// (owdiag-load.js) and by devkit/loadlab/measure.mjs.
//
// Stages (ms since navigation; performance marks "ow:stage:<name>"):
//   engine        the client's first glue screen is up (window.__wenilla_progress('ready'))
//   login         the login screen (bridge state)
//   charlist      the character list (bridge state 'charselect')
//   world-enter   the loading screen rose for the world ('world-loading' from engine patch 0008;
//                 an older client: the bridge state turning 'inworld')
//   world-ready   the loading screen cleared ('world-ready', patch 0008); older client: absent
//   first-frame   the first animation frame after world-ready (or after world-enter, older client)
//   sound-ready   the deferred audio device opened ('audio-ready', patch 0009)
//   first-move    the first snapshot after world-ready with the player moving
//
// Hitches: every animation-frame gap over 100 ms in the 30 s after world-ready (or world-enter),
// as { at: ms after that stage, ms }. Counts and file names never reach the screen: the boot
// overlay's numbers are hidden (openvanilla.js) and summarised here, in the console, instead.
//
// window.owStages: { marks, hitches, frames, worstFrameMs, summary() }

const HITCH_MS = 100;
const WATCH_MS = 30000;

export function installStages(wenilla) {
  if (window.owStages) return window.owStages;
  const marks = {};
  const hitches = [];
  const st = (window.owStages = { marks, hitches, frames: 0, worstFrameMs: 0, summary });
  const mark = (name, at = performance.now()) => {
    if (name in marks) return;
    marks[name] = Math.round(at);
    try { performance.mark('ow:stage:' + name, { startTime: at }); } catch { /* old browser */ }
    if (name === 'world-ready' || (name === 'world-enter' && !watchStarted)) startWatch(name);
  };

  // The engine's progress hook: boot.js assigns window.__wenilla_progress; keep its function and
  // see every stage first, whichever of the two installs first.
  let inner = window.__wenilla_progress;
  const STAGE = { ready: 'engine', 'world-loading': 'world-enter', 'world-ready': 'world-ready', 'audio-ready': 'sound-ready' };
  const hook = (stage) => {
    if (STAGE[stage]) mark(STAGE[stage]);
    // Every stage, every time (a portal or a hearthstone brings the loading screen back too).
    try { window.dispatchEvent(new CustomEvent('ow:progress', { detail: stage })); } catch { /* old browser */ }
    if (stage === 'world-ready') afterFrame(() => mark('first-frame'));
    if (typeof inner === 'function') return inner(stage);
    return undefined;
  };
  try {
    Object.defineProperty(window, '__wenilla_progress', {
      configurable: true,
      get: () => hook,
      set: (f) => { if (f !== hook) inner = f; },
    });
  } catch { /* a non-configurable global: stages fall back to the bridge */ }

  // The bridge: screen states and the first movement.
  let readyPos = null;
  wenilla?.on?.('state', (s) => {
    const name = s?.state;
    if (name === 'login') mark('login');
    if (name === 'charselect') mark('charlist');
    if (name === 'inworld' && !('world-enter' in marks)) { mark('world-enter'); afterFrame(() => markLate('first-frame')); }
  });
  wenilla?.on?.('frame', (snap) => {
    if (!('world-ready' in marks) || 'first-move' in marks) return;
    const p = snap?.self?.pos;
    if (!p) return;
    readyPos ??= p;
    if (snap.self.moving || Math.hypot(p[0] - readyPos[0], p[1] - readyPos[1]) > 0.5) mark('first-move');
  });
  // An older client with no world-ready: the first frame after world-enter stands in.
  function markLate(name) { if (!('world-ready' in marks)) mark(name); }

  // The frame-gap watch.
  let watchStarted = false;
  function startWatch(from) {
    watchStarted = true;
    const t0 = performance.now();
    let last = t0;
    const tick = (t) => {
      const gap = t - last;
      last = t;
      st.frames += 1;
      if (gap > st.worstFrameMs) st.worstFrameMs = Math.round(gap);
      if (gap > HITCH_MS) hitches.push({ at: Math.round(t - t0), ms: Math.round(gap), from });
      if (t - t0 < WATCH_MS) requestAnimationFrame(tick);
      else console.info(`[Open Vanilla] first ${WATCH_MS / 1000}s after ${from}: ${st.frames} frames, ${hitches.length} hitches over ${HITCH_MS} ms (worst ${st.worstFrameMs} ms)`);
    };
    requestAnimationFrame(tick);
  }

  function summary() {
    const d = (a, b) => (marks[a] != null && marks[b] != null ? marks[b] - marks[a] : null);
    return {
      marks: { ...marks },
      spans: {
        boot: marks.engine ?? null,
        toCharlist: marks.charlist ?? null,
        worldLoad: d('world-enter', 'world-ready'),
        toFirstFrame: d('world-enter', 'first-frame'),
        toSound: d('world-ready', 'sound-ready'),
        toFirstMove: d('world-ready', 'first-move'),
      },
      hitches: hitches.length,
      worstFrameMs: st.worstFrameMs,
    };
  }
  return st;
}

function afterFrame(fn) {
  requestAnimationFrame(() => requestAnimationFrame(() => fn()));
}
