// bridge.js — the page-side face of the JavaScript bridge (`benilla-app/src/webbridge`).
//
// The wasm looks up `window.__wenilla_bridge` once a frame and, when it is there, calls
// `onFrame(snapshot)` and `onEvent(name, payload)` on it and drains its `queue` of command
// objects. This module creates that object and wraps the raw contract in `wenilla`: a
// listener registry, promise-returning Lua evaluation, a gamepad mapper, the hidden-tab
// keepalive, and desktop notifications. `web/README.md` § "JavaScript bridge" documents the
// snapshot and event schema; this file is the API.
//
// Dynamic, unawaited, never load-bearing — the same posture as platform.js: a page that never
// imports it runs the game exactly as before, at the cost of one `Reflect.get` per frame.

const hook = (window.__wenilla_bridge ??= {});
Object.assign(hook, {
  version: 1,
  hz: hook.hz ?? 20,            // onFrame calls per second (0 = every frame)
  radius: hook.radius ?? 60,    // yards; units[] is everything within it
  maxUnits: hook.maxUnits ?? 64,
  events: hook.events ?? [],    // Lua event names to relay, or '*'
  queue: hook.queue ?? [],      // commands, drained by the wasm every frame
});

const listeners = new Map();
const emit = (name, payload) => {
  const set = listeners.get(name);
  if (!set) return;
  for (const cb of set) {
    try {
      cb(payload);
    } catch (e) {
      console.error(`wenilla: listener for ${name} threw`, e);
    }
  }
};

const pendingLua = new Map();
let luaSeq = 0;
const push = (cmd) => hook.queue.push(cmd);

// Bridge-level event names; anything else passed to `on()` is taken as a Lua event name and
// subscribed to on the page's behalf.
const BRIDGE_EVENTS = new Set([
  'frame', 'ready', 'commands', 'state', 'map', 'zone', 'chat', 'lua', 'event', 'input', 'error',
]);

hook.onFrame = (snapshot) => {
  wenilla.state = snapshot;
  emit('frame', snapshot);
};
hook.onEvent = (name, payload) => {
  if (name === 'ready') {
    wenilla.ready = true;
    wenilla.commands = payload.commands;
    // The wasm re-reads `events` every frame; a subscription made before boot is honoured now.
  } else if (name === 'commands') {
    wenilla.commands = payload;
  } else if (name === 'lua') {
    const p = pendingLua.get(payload.id);
    if (p) {
      pendingLua.delete(payload.id);
      clearTimeout(p.timer);
      payload.ok ? p.resolve(payload.values) : p.reject(new Error(payload.error));
    }
  } else if (name === 'event') {
    emit(payload.name, payload.args);
  } else if (name === 'error') {
    console.warn('wenilla: bridge error', payload);
  }
  emit(name, payload);
};

export const wenilla = {
  /** The last `onFrame` snapshot (see README for the schema), or null before the first. */
  state: null,
  /** `[{name, category}]` — every command `hold`/`fire` accepts, from `ready` and `commands`. */
  commands: [],
  ready: false,

  /** Listen for a bridge event ('frame', 'chat', 'state', …) or any Lua UI event name. */
  on(name, cb) {
    if (!listeners.has(name)) listeners.set(name, new Set());
    listeners.get(name).add(cb);
    if (!BRIDGE_EVENTS.has(name)) this.subscribe(name);
    return () => this.off(name, cb);
  },
  off(name, cb) {
    listeners.get(name)?.delete(cb);
  },
  /** Ask the wasm to relay these Lua events (`'*'` for all — debugging only, it is a firehose). */
  subscribe(...names) {
    if (hook.events === '*') return;
    if (names.includes('*')) {
      hook.events = '*';
      return;
    }
    hook.events = [...new Set([...hook.events, ...names])];
  },

  /** Assert (or release) a held command by name — MOVEFORWARD, STRAFELEFT, TURNLEFT… */
  hold(cmd, down = true) {
    push({ op: 'hold', cmd, down });
  },
  release(cmd) {
    push({ op: 'hold', cmd, down: false });
  },
  releaseAll() {
    push({ op: 'release' });
  },
  /** Fire a command once: JUMP, SITORSTAND, TARGETNEARESTENEMY, ACTIONBUTTON1, CAMERAZOOMIN… */
  fire(cmd, amount = 1) {
    push({ op: 'fire', cmd, amount });
  },
  /** Turn the character's aim by `dyaw` radians (positive = left / counter-clockwise). */
  look(dyaw) {
    push({ op: 'look', dyaw });
  },
  /** Evaluate a Lua chunk in the UI VM; resolves to its return values as plain JS values. */
  lua(chunk, timeoutMs = 10000) {
    const id = ++luaSeq;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pendingLua.delete(id);
        reject(new Error('wenilla.lua: timed out (is the game running and in a state with a VM?)'));
      }, timeoutMs);
      pendingLua.set(id, { resolve, reject, timer });
      push({ op: 'lua', id, chunk });
    });
  },
  /** A line as if typed into the chat box: `/say hi`, `/target Bob`, `/follow`, `.gm on`. */
  chat(text) {
    push({ op: 'chat', text });
  },
  /** Live knobs: `{hz, radius, maxUnits, backgroundHz}`. */
  set({ hz, radius, maxUnits, backgroundHz } = {}) {
    if (hz !== undefined) hook.hz = hz;
    if (radius !== undefined) hook.radius = radius;
    if (maxUnits !== undefined) hook.maxUnits = maxUnits;
    if (backgroundHz !== undefined) background.hz = backgroundHz;
  },

  /** Distance in yards between two `[x, y, z]` WoW positions. */
  dist(a, b) {
    return Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);
  },
  /**
   * Bearing of a unit relative to where the player faces, in radians in (-π, π]: 0 is dead
   * ahead, positive is to the left (WoW's orientation grows counter-clockwise, +X north, +Y west).
   */
  bearingTo(unit) {
    const me = this.state?.self;
    if (!me || !unit?.pos) return NaN;
    const dx = unit.pos[0] - me.pos[0];
    const dy = unit.pos[1] - me.pos[1];
    let b = Math.atan2(dy, dx) - me.facing;
    while (b > Math.PI) b -= 2 * Math.PI;
    while (b <= -Math.PI) b += 2 * Math.PI;
    return b;
  },
};

// ── The hidden-tab keepalive ──
//
// Visible, the game runs off requestAnimationFrame. A hidden tab gets no animation frames and
// its timers are throttled to once a second (once a minute after five minutes), so nothing
// happens in it — no chat, no death, no level-up, until it is looked at again. Dedicated
// Workers are not throttled that way, so while hidden a Worker ticks at `background.hz` and
// each tick calls the `wake` function the wasm installed on the hook, which runs one app update
// (`WinitUserEvent::WakeUp`). That update is a full frame's CPU (~11 ms outdoors); 4 Hz is a
// few percent of a core and enough for notifications, a bot may want more.
const background = {
  hz: 4,
  worker: null,
  get active() {
    return this.worker !== null;
  },
  start() {
    if (this.worker || !this.hz) return;
    const src = `setInterval(() => postMessage(0), ${Math.max(20, 1000 / this.hz)});`;
    const url = URL.createObjectURL(new Blob([src], { type: 'text/javascript' }));
    this.worker = new Worker(url);
    URL.revokeObjectURL(url);
    this._misses = 0;
    this.worker.onmessage = () => {
      // No `wake` yet. Either the wasm has not attached (a tab hidden before boot finished —
      // worth waiting for), or this session opted out (`?bridge=0`, where the plugin returns
      // early and never installs one — nothing will ever appear). `?.()` cannot tell those
      // apart and would leave a Worker ticking at nothing for the life of the tab, so give the
      // wasm a few seconds' grace and then stop.
      if (!hook.wake) {
        if (++this._misses > Math.max(8, this.hz * 5)) this.stop();
        return;
      }
      this._misses = 0;
      try {
        hook.wake();
      } catch (e) {
        // A stale `wake` (the wasm let go of the hook): stop nagging it.
        this.stop();
      }
    };
  },
  stop() {
    this.worker?.terminate();
    this.worker = null;
  },
};
wenilla.background = background;
document.addEventListener('visibilitychange', () => {
  if (document.hidden) background.start();
  else background.stop();
});
if (document.hidden) background.start();

// ── Notifications ──
//
// Desktop notifications for the things worth leaving another tab for, built on the event
// stream. `enable()` must run from a user gesture (browsers gate the permission prompt on one);
// the dev page's bell button calls it. Rules are plain data the page may edit or replace.
const notify = {
  enabled: false,
  /** Show even when the tab is visible and focused. */
  always: false,
  count: 0,
  rules: [
    { event: 'PLAYER_LEVEL_UP', title: (a) => `Level ${a[0]}!`, body: () => 'Ding.', tag: 'level' },
    { event: 'PLAYER_DEAD', title: () => 'You died', body: () => 'Release, or wait for a resurrection.', tag: 'death' },
    { event: 'RESURRECT_REQUEST', title: (a) => `${a[0]} wants to resurrect you`, tag: 'death' },
    { event: 'PARTY_INVITE_REQUEST', title: (a) => `${a[0]} invites you to a group`, tag: 'invite' },
    { event: 'GUILD_INVITE_REQUEST', title: (a) => `${a[0]} invites you to ${a[1] ?? 'a guild'}`, tag: 'invite' },
    { event: 'DUEL_REQUESTED', title: (a) => `${a[0]} challenges you to a duel`, tag: 'invite' },
    { event: 'UPDATE_PENDING_MAIL', title: () => 'You have new mail', tag: 'mail', cooldownMs: 60000 },
    { event: 'PLAYER_REGEN_DISABLED', title: () => 'You are in combat', tag: 'combat', cooldownMs: 30000 },
    { event: 'QUEST_COMPLETE', title: () => 'Quest complete', tag: 'quest' },
  ],
  /** Whisper and disconnect rules, kept apart because they come from `chat` and `state`. */
  whispers: true,
  disconnects: true,
  _last: new Map(),
  _title: document.title,

  async enable() {
    if (!('Notification' in window)) return false;
    const perm =
      Notification.permission === 'granted'
        ? 'granted'
        : await Notification.requestPermission();
    this.enabled = perm === 'granted';
    if (this.enabled) this._arm();
    return this.enabled;
  },
  disable() {
    this.enabled = false;
  },
  _armed: false,
  _arm() {
    if (this._armed) return;
    this._armed = true;
    for (const rule of this.rules) {
      wenilla.on(rule.event, (args) => {
        if (!this.enabled) return;
        this.show(rule.title(args), rule.body?.(args), rule.tag ?? rule.event, rule.cooldownMs ?? 0);
      });
    }
    wenilla.on('chat', (c) => {
      if (this.enabled && this.whispers && c.kind === 'WHISPER') {
        this.show(`${c.sender} whispers`, c.text, `whisper:${c.sender}`);
      }
    });
    wenilla.on('state', (s) => {
      if (this.enabled && this.disconnects && !s.connected && s.state === 'inworld') {
        this.show('Disconnected', 'The connection to the server dropped.', 'net');
      }
    });
    document.addEventListener('visibilitychange', () => {
      if (!document.hidden) this._clearBadge();
    });
  },
  /** Show one now (subject to the hidden/focus rule and the per-tag cooldown). */
  show(title, body, tag = 'wenilla', cooldownMs = 0) {
    if (!this.enabled) return;
    if (!this.always && !document.hidden && document.hasFocus()) return;
    const now = Date.now();
    if (cooldownMs && now - (this._last.get(tag) ?? -Infinity) < cooldownMs) return;
    this._last.set(tag, now);
    try {
      const n = new Notification(title, { body, tag, silent: false });
      n.onclick = () => {
        window.focus();
        n.close();
      };
    } catch (e) {
      console.warn('wenilla: notification failed', e);
    }
    this.count += 1;
    document.title = `(${this.count}) ${this._title}`;
    navigator.setAppBadge?.(this.count).catch?.(() => {});
  },
  _clearBadge() {
    this.count = 0;
    document.title = this._title;
    navigator.clearAppBadge?.().catch?.(() => {});
  },
};
wenilla.notify = notify;

// ── Gamepad ──
//
// A mapper in plain JS over the command API: sticks become held movement commands (1.12
// movement is on/off, so the stick is thresholded, not analog), the right stick turns the aim
// through `look`, buttons fire commands. Standard-layout indices (0 A · 1 B · 2 X · 3 Y · 4 LB
// · 5 RB · 6 LT · 7 RT · 8 back · 9 start · 10/11 stick clicks · 12-15 d-pad). Edit
// `gamepad.mapping` or pass one to `start()`.
const gamepad = {
  running: false,
  deadzone: 0.3,
  /** Radians per second of turn at full right-stick deflection. */
  lookRate: 2.5,
  /** Zoom notches per second at full trigger. */
  zoomRate: 3,
  mapping: {
    buttons: {
      0: 'JUMP',
      1: 'SITORSTAND',
      2: 'ACTIONBUTTON1',
      3: 'ACTIONBUTTON2',
      4: 'TARGETPREVIOUSENEMY',
      5: 'TARGETNEARESTENEMY',
      8: 'TOGGLEUI',
      9: 'TOGGLEAUTORUN',
      10: 'TOGGLESHEATH',
      11: 'ATTACKTARGET',
      12: 'ACTIONBUTTON3',
      13: 'ACTIONBUTTON4',
      14: 'ACTIONBUTTON5',
      15: 'ACTIONBUTTON6',
    },
    axes: { moveX: 0, moveY: 1, lookX: 2 },
    triggers: { 6: 'CAMERAZOOMOUT', 7: 'CAMERAZOOMIN' },
  },
  _held: new Set(),
  _down: new Set(),
  _raf: 0,
  _last: 0,
  start(mapping) {
    if (mapping) this.mapping = { ...this.mapping, ...mapping };
    if (this.running) return;
    this.running = true;
    this._last = performance.now();
    const tick = (t) => {
      if (!this.running) return;
      this._poll((t - this._last) / 1000);
      this._last = t;
      this._raf = requestAnimationFrame(tick);
    };
    this._raf = requestAnimationFrame(tick);
    console.log('wenilla: gamepad mapper on — press a button on the controller if nothing moves');
  },
  stop() {
    this.running = false;
    cancelAnimationFrame(this._raf);
    for (const cmd of this._held) wenilla.release(cmd);
    this._held.clear();
    this._down.clear();
  },
  _setHold(cmd, on) {
    if (on && !this._held.has(cmd)) {
      this._held.add(cmd);
      wenilla.hold(cmd, true);
    } else if (!on && this._held.has(cmd)) {
      this._held.delete(cmd);
      wenilla.release(cmd);
    }
  },
  _poll(dt) {
    const pads = navigator.getGamepads?.() ?? [];
    const gp = [...pads].find((p) => p && p.connected);
    if (!gp) return;
    const dz = this.deadzone;
    const ax = (i) => gp.axes[i] ?? 0;
    const { moveX, moveY, lookX } = this.mapping.axes;
    this._setHold('MOVEFORWARD', ax(moveY) < -dz);
    this._setHold('MOVEBACKWARD', ax(moveY) > dz);
    this._setHold('STRAFELEFT', ax(moveX) < -dz);
    this._setHold('STRAFERIGHT', ax(moveX) > dz);
    const rx = ax(lookX);
    if (Math.abs(rx) > dz) {
      // Stick right = turn right = clockwise = a negative yaw delta.
      const mag = (Math.abs(rx) - dz) / (1 - dz);
      wenilla.look(-Math.sign(rx) * mag * this.lookRate * dt);
    }
    for (const [i, cmd] of Object.entries(this.mapping.buttons)) {
      const pressed = gp.buttons[i]?.pressed ?? false;
      if (pressed && !this._down.has(i)) wenilla.fire(cmd);
      pressed ? this._down.add(i) : this._down.delete(i);
    }
    for (const [i, cmd] of Object.entries(this.mapping.triggers)) {
      const v = gp.buttons[i]?.value ?? 0;
      if (v > dz) wenilla.fire(cmd, v * this.zoomRate * dt);
    }
  },
};
wenilla.gamepad = gamepad;
window.addEventListener('gamepadconnected', (e) => {
  console.log(`wenilla: gamepad connected — ${e.gamepad.id}; wenilla.gamepad.start() to drive`);
});

window.wenilla = wenilla;
export default wenilla;
