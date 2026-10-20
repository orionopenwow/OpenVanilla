// The camera-snap fix in realm/www/input.js: pointer-lock spikes are dropped, normal moves pass.
// node tests/input_spike_test.mjs
// Minimal DOM stand-in: runs input.js's spike filter on fake pointer events.
const listeners = {};
const canvas = { id: 'benilla', width: 100, height: 100, clientWidth: 100, clientHeight: 100,
  getBoundingClientRect: () => ({ left: 0, top: 0 }), focus() {}, blur() {}, setPointerCapture() {}, dispatchEvent() { return true; } };
globalThis.location = { search: '' };
globalThis.devicePixelRatio = 1;
globalThis.window = { devicePixelRatio: 1, addEventListener: (t, f) => (listeners[t] ||= []).push(f) };
globalThis.addEventListener = window.addEventListener;
globalThis.document = { getElementById: () => canvas, querySelector: () => canvas, activeElement: canvas, pointerLockElement: canvas,
  hasFocus: () => true, hidden: false, addEventListener() {} };
globalThis.Element = class {}; Element.prototype.requestPointerLock = function () {};
globalThis.PointerEvent = class { constructor(t, i) { Object.assign(this, i, { type: t }); } };
const { installInput } = await import(new URL("../realm/www/input.js", import.meta.url));
const stats = installInput();
function fire(mx, my, coalesced) {
  let stopped = false;
  const e = { type: 'pointermove', isTrusted: true, pointerType: 'mouse', movementX: mx, movementY: my, target: canvas,
    getCoalescedEvents: () => coalesced || [], stopImmediatePropagation() { stopped = true; }, preventDefault() {} };
  for (const f of listeners.pointermove) { f(e); if (stopped) break; }
  return stopped;
}
const ok = (c, m) => { if (!c) { console.log('FAIL', m); process.exitCode = 1; } else console.log('ok', m); };
ok(!fire(40, -12), 'a normal move reaches the game');
ok(fire(900, 3), 'a 900 px spike is dropped');
ok(fire(10, 2, [{ movementX: 5, movementY: 0 }, { movementX: -640, movementY: 0 }]), 'a spike inside the coalesced reports is dropped');
document.pointerLockElement = null;
ok(!fire(900, 3), 'unlocked (cursor) moves are never touched');
ok(stats.spikes === 2, 'counted: ' + stats.spikes);
