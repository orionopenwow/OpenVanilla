// platform.js — browser-platform glue the client cannot ask for itself: full-screen key capture
// and durable storage. Shared by the dev page (web/index.html) and the realm page
// (crates/wenilla-realm/templates/play.html), the same way boot.js is.
//
// Everything here is best-effort. Every entry point is feature-detected and every failure is
// swallowed: none of it is load-bearing for booting the client, and a browser that refuses one
// of these must still play exactly as it does today. Both pages import this module
// *dynamically*, off the boot path, so even a missing platform.js only costs the button.

// Ask the browser to exempt this origin's quota storage from eviction.
//
// What this protects is the player's own state, not the game archives. The client keeps its
// state folder — config.toml (CVars), key bindings, macros, layouts, chat settings, saved
// variables, the remembered account name — in `localStorage`, one entry per file
// (benilla-app/src/local_state.rs). localStorage is quota-managed storage, and a browser under
// storage pressure evicts a "best-effort" origin's quota storage as a unit, silently: the
// player comes back to default keybinds. `persist()` moves the origin to the persistent bucket,
// which Chrome then clears only when the user clears site data.
//
// It does NOT protect the downloaded game data. `/data/*` is served
// `private, max-age=31536000, immutable` (wenilla-host/src/data.rs) and boot.js prefetches the
// boot read-set into that cache, but that is the HTTP cache — a separate, browser-wide LRU that
// the Storage API does not govern, so a persistent origin can still lose it and pay a cold boot.
// Holding the archives across eviction would mean rehosting them in the Cache API (quota
// storage), which is a much bigger decision than this call — see web/README.md.
//
// The grant is heuristic (site engagement, installed PWA, notification permission) and in Chrome
// there is no prompt — it can simply return false, and there is nothing to fall back to. Firefox
// does prompt, which is why both pages call this only after the WebGPU gate: a browser that
// cannot run the client never asks the player for anything.
export async function requestPersistentStorage() {
  if (!navigator.storage || !navigator.storage.persist) return false;
  try {
    // Already granted: don't ask again, the answer is sticky for the origin.
    if (await navigator.storage.persisted()) return true;
    const granted = await navigator.storage.persist();
    console.log(`storage: persistent = ${granted}`);
    return granted;
  } catch (_) {
    return false;
  }
}

// The keys the game needs more than the browser does, as KeyboardEvent.code values. Keyboard
// Lock only takes effect in full screen, and only for the codes named here — locking everything
// (`lock()` with no argument) would take Ctrl+T, Ctrl+Tab and the rest hostage for no gain.
//
//   Escape — WoW's close-window / game-menu key. bindings/chord.rs maps it as "ESCAPE" and
//            login/mod.rs + char_select/ bind it directly. Unlocked, every press leaves full
//            screen and drops the pointer lock instead of ever reaching the client.
//   Tab    — target cycling. Unlocked, it walks browser focus out of the canvas.
//   KeyW   — forward. W already reaches the page on its own; locking the code is what keeps
//            Ctrl+W / Cmd+W from closing the tab mid-pull.
const LOCK_KEYS = ['Escape', 'Tab', 'KeyW'];

// Keep Keyboard Lock tied to the document's actual full-screen state, and optionally wire a
// button to toggle it.
//
// `button` may be null: the lock still follows F11 and every other way into full screen. When a
// button is given it also gets its label and aria-pressed kept in sync, and is hidden outright
// on a browser with no Fullscreen API.
//
// `focusTarget` (the canvas) gets focus back after every toggle: the click leaves focus on the
// button, and a focused button eats Space and Enter before winit's canvas listeners see them.
export function installFullscreenToggle(button, { target = document.documentElement, focusTarget = null } = {}) {
  const supported = !!(target.requestFullscreen && document.exitFullscreen);
  if (!supported) {
    if (button) button.hidden = true;
    return;
  }

  const lockKeys = async () => {
    if (!navigator.keyboard || !navigator.keyboard.lock) return;
    // Chrome shows its own "press and hold Esc to exit full screen" toast on the first lock.
    try { await navigator.keyboard.lock(LOCK_KEYS); } catch (_) { /* denied; keys stay browser-owned */ }
  };
  const unlockKeys = () => {
    if (!navigator.keyboard || !navigator.keyboard.unlock) return;
    try { navigator.keyboard.unlock(); } catch (_) {}
  };

  // Driven by `fullscreenchange`, not by the click: F11, the Esc long-press and the browser's
  // own exit affordances never go through our handler, and the lock has to follow all of them.
  // `initial` marks the install-time call, which only paints the button — stealing focus on
  // page load (before there is a client to type into) is not this module's business.
  const sync = (initial) => {
    const full = document.fullscreenElement !== null;
    if (button) {
      button.textContent = full ? 'exit full screen' : 'full screen';
      button.setAttribute('aria-pressed', String(full));
    }
    if (full) lockKeys(); else unlockKeys();
    if (!initial && focusTarget) focusTarget.focus?.();
  };

  if (button) {
    button.addEventListener('click', async () => {
      try {
        if (document.fullscreenElement) await document.exitFullscreen();
        else await target.requestFullscreen({ navigationUI: 'hide' });
      } catch (e) {
        console.warn('fullscreen:', e);
      }
    });
  }
  document.addEventListener('fullscreenchange', () => sync(false));
  sync(true);
}
