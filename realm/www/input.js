// ow/input.js — keep the mouse working in the browser client.
//
// The client turns the camera (right or left drag) only while it believes its window has focus:
// unfocused, it hands the cursor back and throws mouse motion away (engine camera.rs,
// sync_look_focus), the desktop client's behaviour for alt-tab. In a page that focus is the
// canvas's DOM focus, and the page can lose it without the player noticing: a click on the ≡ menu
// or the dock, the Assistant, a link opened in another tab. Clicking back on the game does not
// always focus the canvas again (the client prevents the default of a press), so the camera stays
// dead until something re-focuses it. That is "the mouse sometimes doesn't work".
//
// Guards, all page-side:
//   * a press on the game focuses the canvas (and re-announces focus when it already had it but
//     the window did not: coming back from another app or tab);
//   * the pressed button is captured to the canvas, so a release over the menu, the dock or
//     outside the window still reaches the game (no button stuck down, no camera stuck turning);
//   * the browser refuses a new pointer lock for about a second after one ends: a refused lock
//     during a drag is tried again while the button is still down.
//   * high-resolution screens (phones, 150% Windows scaling, Retina): the client reads a pointer in
//     device pixels as a pixel of its drawing buffer, so when it draws at page size on a screen with
//     2 device pixels per CSS pixel every click and tap landed at double its real place (Enter World could
//     not be pressed on a phone). Each pointer event on the game is re-sent with the position the
//     client expects, and a press is preceded by a move to the same spot, because the client only
//     counts a press where the pointer has moved first (a finger tap has no move before it).
//   * pointer-lock spikes: while the camera turns (pointer lock), Chromium on Windows now and then
//     reports one mouse move hundreds of pixels long that the hand never made (a browser bug; it
//     also happens on the first move after a lock). The client turns the camera by it: the view
//     "snaps around". A locked move that long is dropped before the client sees it.
// ?noinputguard=1 turns it off. window.owInput: counters for owdiag.

// A pointer event the client will take. Its input layer (winit) reads a pointermove through
// getCoalescedEvents(), and for an event made by a script that list is EMPTY unless it is given:
// a scripted move was dropped whole, so the pointer never "moved" onto a button and the press
// after it was ignored (the green ring with no click). So a move carries itself as its one
// coalesced event. That copy is never dispatched, so its offsetX/Y read as its clientX/Y: it is
// given the position relative to the canvas, which is what winit reads (measured, Chromium 141).
export function gamePointerEvent(c, type, init) {
  if (type !== 'pointermove') return new PointerEvent(type, init);
  const r = c.getBoundingClientRect();
  try {
    const one = new PointerEvent('pointermove', { ...init, clientX: init.clientX - r.left, clientY: init.clientY - r.top });
    return new PointerEvent('pointermove', { ...init, coalescedEvents: [one] });
  } catch {
    return new PointerEvent(type, init);
  }
}

const RELOCK_MS = 1100;

export function installInput() {
  if (new URLSearchParams(location.search).get('noinputguard') === '1') return null;
  const stats = (window.owInput = { refocus: 0, reannounce: 0, captured: 0, relockTries: 0, relocked: 0, lockErrors: 0, spikes: 0 });
  const canvas = () => document.getElementById('benilla') || document.querySelector('canvas');
  lockSpikes(canvas, stats);
  let held = 0;          // bitmask of buttons pressed on the game
  let lostFocus = false; // the canvas or the window lost focus since the last press

  function refocus(c) {
    if (document.activeElement !== c) {
      c.focus({ preventScroll: true });
      stats.refocus += 1;
    } else if (lostFocus) {
      // already the active element, but its focus event was missed: blur and focus again so the
      // client hears "focused" (its flag only changes on those events)
      c.blur();
      c.focus({ preventScroll: true });
      stats.reannounce += 1;
    }
    lostFocus = false;
  }

  window.addEventListener('blur', () => { lostFocus = true; });
  document.addEventListener('focusout', (e) => { if (e.target === canvas()) lostFocus = true; }, true);
  document.addEventListener('visibilitychange', () => { if (document.hidden) lostFocus = true; });

  window.addEventListener('pointerdown', (e) => {
    const c = canvas();
    if (!c || e.target !== c) return;
    held |= 1 << e.button;
    if (document.hasFocus()) refocus(c);
    try {
      c.setPointerCapture(e.pointerId);
      stats.captured += 1;
    } catch { /* not capturable (already locked): fine */ }
  }, true);

  const up = (e) => { held &= ~(1 << e.button); };
  window.addEventListener('pointerup', up, true);
  window.addEventListener('pointercancel', () => { held = 0; }, true);
  window.addEventListener('blur', () => { held = 0; });

  // A lock refused (the browser's cooldown after the last one ended): retry while still dragging.
  const realLock = Element.prototype.requestPointerLock;
  if (realLock && !realLock.__ow) {
    const wrapped = function owRequestPointerLock(...args) {
      const el = this;
      let r;
      try { r = realLock.apply(el, args); } catch (err) { r = Promise.reject(err); }
      const retry = () => {
        stats.lockErrors += 1;
        const want = held;
        if (!want) return;
        setTimeout(() => {
          if (!held || document.pointerLockElement) return;
          stats.relockTries += 1;
          try {
            const again = realLock.apply(el, args);
            if (again && again.then) again.then(() => { stats.relocked += 1; }, () => {});
          } catch { /* give up quietly: the drag still turns the view without the lock */ }
        }, RELOCK_MS);
      };
      if (r && typeof r.then === 'function') r.then(() => {}, retry);
      return r;
    };
    wrapped.__ow = true;
    Element.prototype.requestPointerLock = wrapped;
  }
  pointerScale(canvas, stats);
  return stats;
}

// Pointer-lock spikes (see the top). A real hand move between two mouse reports is a few dozen
// pixels even in a fast flick; a spike is hundreds. Each report is checked, the event and the
// reports coalesced into it, and a move holding one longer than SPIKE_PX is dropped whole (it is
// one frame of turning at most). ?spikepx=<n> changes the limit, ?spikepx=0 turns the filter off.
const SPIKE_PX = 250;

function lockSpikes(canvas, stats) {
  const q = Number(new URLSearchParams(location.search).get('spikepx'));
  const limit = Number.isFinite(q) && q >= 0 && new URLSearchParams(location.search).has('spikepx') ? q : SPIKE_PX;
  if (!limit) return;
  const big = (ev) => Math.abs(ev.movementX || 0) > limit || Math.abs(ev.movementY || 0) > limit;
  const drop = (e) => {
    if (!e.isTrusted || e.pointerType !== 'mouse') return;
    const c = canvas();
    if (!c || document.pointerLockElement !== c) return;
    let spike = big(e);
    if (!spike && e.getCoalescedEvents) {
      try { spike = e.getCoalescedEvents().some(big); } catch { /* no list: the event alone decides */ }
    }
    if (!spike) return;
    e.stopImmediatePropagation();
    e.preventDefault();
    stats.spikes += 1;
  };
  window.addEventListener('pointermove', drop, true);
  window.addEventListener('pointerrawupdate', drop, true);
  // the same check on the plain mouse event, for an input layer that listens to those
  window.addEventListener('mousemove', (e) => {
    const c = canvas();
    if (e.isTrusted && c && document.pointerLockElement === c && big(e)) { e.stopImmediatePropagation(); stats.spikes += 1; }
  }, true);
}

const POINTER_TYPES = ['pointerover', 'pointerenter', 'pointermove', 'pointerdown', 'pointerup', 'pointercancel', 'pointerout', 'pointerleave'];

function pointerScale(canvas, stats) {
  stats.rescaled = 0;
  // Only when the factor isn't 1 (a full-resolution buffer needs nothing; touches still get their
  // move-before-press below).
  // The client multiplies a pointer's page position by devicePixelRatio and reads that as a pixel of
  // its drawing buffer: per axis, pixel ratio x page size / buffer size lines it up (1.0 on a phone
  // drawing at full resolution, 2 for a page-sized buffer at ratio 2). ?tapscale=<n> forces a factor.
  // ow/touch.js pointerFactor: the same rule and the measurements behind it.
  const factor = (c) => {
    const q = new URLSearchParams(location.search).get('tapscale');
    if (q && Number(q) > 0) return [Number(q), Number(q)];
    const dpr = window.devicePixelRatio || 1;
    if (!c.width || !c.height || !c.clientWidth || !c.clientHeight) return [dpr, dpr];
    return [dpr * c.clientWidth / c.width, dpr * c.clientHeight / c.height];
  };
  const resend = (c, type, e, [fx, fy], extra) => {
    const r = c.getBoundingClientRect();
    // a move must carry itself as its coalesced event, or the client drops it: gamePointerEvent
    c.dispatchEvent(gamePointerEvent(c, type, {
      bubbles: true, cancelable: true, composed: true,
      pointerId: e.pointerId, pointerType: e.pointerType, isPrimary: e.isPrimary,
      button: e.button, buttons: e.buttons, width: e.width, height: e.height, pressure: e.pressure,
      clientX: r.left + (e.clientX - r.left) / fx, clientY: r.top + (e.clientY - r.top) / fy,
      screenX: e.screenX, screenY: e.screenY,
      movementX: (e.movementX || 0) / fx, movementY: (e.movementY || 0) / fy,
      ctrlKey: e.ctrlKey, shiftKey: e.shiftKey, altKey: e.altKey, metaKey: e.metaKey,
      ...extra,
    }));
  };
  for (const type of POINTER_TYPES) {
    window.addEventListener(type, (e) => {
      const c = canvas();
      if (!e.isTrusted || !c || e.target !== c) return;
      const f = factor(c);
      // full-resolution client: only a touch press needs help (a mouse always moves before it clicks)
      const one = Math.abs(f[0] - 1) < 0.01 && Math.abs(f[1] - 1) < 0.01;
      if (one && !(type === 'pointerdown' && e.pointerType !== 'mouse')) return;
      e.stopImmediatePropagation();
      e.preventDefault();
      // a press where the pointer never moved (a tap): move there first
      if (type === 'pointerdown') resend(c, 'pointermove', e, f, { button: -1, buttons: 0 });
      resend(c, type, e, f);
      stats.rescaled += 1;
    }, true);
  }
}
