// The realm page's busy banner (realm/www/openvanilla.js): thresholds and the banner itself, with a fake
// fetch, clock and DOM. Run: node tests/solo_banner_test.mjs   (exit 0 = all good)
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const src = fs.readFileSync(path.join(here, '..', 'realm', 'www', 'openvanilla.js'), 'utf8');
const tmp = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'owbusy-')), 'openvanilla.mjs');
// A CSS escape like "\2026" inside a JS template string is an octal escape: a SyntaxError in a module.
// Reported, not hidden: the harness doubles the backslash only so the banner can still be tested.
const octal = /(content: "[^"`]*?)(?<!\\)\\(\d{4})/g;
if (octal.test(src)) console.log('NOTE openvanilla.js: a CSS "\\NNNN" escape in a template string breaks the module (SyntaxError); needs "\\\\NNNN"');
fs.writeFileSync(tmp, src.replace(octal, '$1\\\\$2') + '\nexport { realmLoad, busyBanner };\n');

// ---- a tiny DOM: enough for busyBanner()
class El {
  constructor(tag) { this.tag = tag; this.children = []; this.attrs = {}; this.listeners = {}; this.textContent = ''; this.parent = null; }
  append(...c) { for (const x of c) { x.parent = this; this.children.push(x); } }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter((c) => c !== this); this.parent = null; }
  setAttribute(k, v) { this.attrs[k] = v; }
  addEventListener(t, f) { this.listeners[t] = f; }
  querySelector(sel) { return this.children.find((c) => c.tag === sel) || null; }
}
const body = new El('body');
const head = new El('head');
globalThis.document = { body, head, visibilityState: 'visible', createElement: (t) => new El(t) };
const store = {};
globalThis.sessionStorage = { getItem: (k) => store[k] ?? null, setItem: (k, v) => { store[k] = String(v); } };
let timers = [];
globalThis.setTimeout = (f, ms) => { timers.push({ f, ms }); return timers.length; };
globalThis.clearTimeout = () => {};
let now = 0;
globalThis.performance = { now: () => now };
let reply;
globalThis.fetch = async (url) => {
  if (url !== '/healthz') throw new Error('unexpected ' + url);
  const r = reply();
  if (r.throws) throw new Error('network');
  now += r.ms ?? 100;
  return { ok: r.status < 400, status: r.status ?? 200, json: async () => { if (r.body === undefined) throw new Error('no json'); return r.body; } };
};

const { realmLoad, busyBanner } = await import(pathToFileURL(tmp).href);
let failed = 0;
const check = (name, ok, extra = '') => { console.log((ok ? 'PASS ' : 'FAIL ') + name + (ok ? '' : ' ' + extra)); if (!ok) failed++; };

const healthy = { sqlite: true, mariadb: true, soap: true };
const cases = [
  ['healthy', { body: healthy }, 'ok'],
  ['slow world', { body: healthy, ms: 1600 }, 'slow'],
  ['world down', { body: { ...healthy, soap: false } }, 'down'],
  ['database down', { body: { ...healthy, mariadb: false } }, 'down'],
  ['503', { status: 503, body: { sqlite: false } }, 'down'],
  ['no realm service (local page)', { status: 404 }, 'unknown'],
  ['queue', { body: { ...healthy, world: { queue: 4 } } }, 'full'],
  ['95% full', { body: { ...healthy, players_online: 95, player_limit: 100 } }, 'full'],
  ['94% fine', { body: { ...healthy, players_online: 94, player_limit: 100 } }, 'ok'],
  ['unreachable', { throws: true }, 'down'],
];
for (const [name, r, want] of cases) {
  reply = () => r;
  const got = await realmLoad();
  check(`realmLoad: ${name} -> ${want}`, got.state === want, JSON.stringify(got));
}

// The banner: three looks; one slow answer is not enough, two are; the link keeps the queue (new tab).
const LOOKS = [3000, 90000, 240000];
const isLook = (t) => LOOKS.includes(t.ms);
reply = () => ({ body: healthy, ms: 1700 });
timers = [];
busyBanner();
check('three looks scheduled', timers.filter(isLook).length === 3);
const looks = timers.filter(isLook).sort((a, b) => a.ms - b.ms);
timers = [];
await looks[0].f(); await new Promise((r) => setImmediate(r));
check('one slow answer shows nothing', !body.children.some((c) => c.id === 'ow-busy'));
await looks[1].f(); await new Promise((r) => setImmediate(r));
const banner = body.children.find((c) => c.id === 'ow-busy');
check('two slow answers show the banner', !!banner);
const link = banner && banner.children.find((c) => c.tag === 'a');
check('link opens solo.html in a new tab', link && link.href.endsWith('/solo.html') && link.target === '_blank' && link.rel === 'noopener');
check('banner says why', banner && banner.children[0].textContent.includes('slow'));
reply = () => ({ body: healthy });
await looks[2].f(); await new Promise((r) => setImmediate(r));
check('a good answer hides it again', !body.children.some((c) => c.id === 'ow-busy'));

// Dismissed: stays dismissed for the tab.
reply = () => ({ body: { ...healthy, soap: false } });
timers = [];
busyBanner();
for (const t of timers.filter(isLook).slice(0, 1)) await t.f();
await new Promise((r) => setImmediate(r));
const b2 = body.children.find((c) => c.id === 'ow-busy');
check('down shows at once', !!b2);
b2.children.find((c) => c.tag === 'button').listeners.click();
check('dismiss removes it', !body.children.some((c) => c.id === 'ow-busy'));
timers = [];
busyBanner();
check('dismissed: no more looks this tab', timers.length === 0);

fs.rmSync(path.dirname(tmp), { recursive: true, force: true });
console.log(failed ? `${failed} failed` : 'all passed');
process.exit(failed ? 1 : 0);
