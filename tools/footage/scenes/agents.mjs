// Vanilla Agents: the demo inn (six pretend helpers at their laptops, a barmaid), filmed on its
// own. Starts the demo from your Vanilla Agents folder (VA_DIR, default
// %USERPROFILE%\Downloads\VanillaAgents\vanilla-agents) on a spare port and stops it afterwards;
// or set VA_URL to an inn that is already running (with its #k= key).
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const vaDir = (env) => env.VA_DIR || path.join(os.homedir(), 'Downloads', 'VanillaAgents', 'vanilla-agents');
const PORT = 8979;

function py(env) { return env.PYTHON_EXE ? env.PYTHON_EXE.split(' ') : process.platform === 'win32' ? ['py', '-3'] : ['python3']; }

async function startDemo(s) {
  if (s.env.VA_URL) return { url: s.env.VA_URL, stop: async () => {} };
  const data = path.join(vaDir(s.env), 'data');
  const feed = path.join(os.tmpdir(), `va-footage-${Date.now()}.jsonl`);
  const [exe, ...pre] = py(s.env);
  const feedP = spawn(exe, [...pre, path.join('scripts', 'demo_feed.py'), '--out', feed, '--agents', '6', '--barmaid'], { cwd: data, stdio: 'ignore' });
  await new Promise((r) => feedP.on('exit', r));          // the whole demo story at once (the inn shows the end state)
  const srv = spawn(exe, [...pre, '-m', 'vanilla_agents.app.server', '--feed', feed, '--fake-verify', '--demo', '--show-key', '--port', String(PORT)], { cwd: data });
  let out = '';
  const url = await new Promise((res, rej) => {
    const t = setTimeout(() => rej(new Error('the demo inn did not start: ' + out.slice(-300))), 60000);
    const on = (b) => { out += b.toString(); const m = /(http:\/\/127\.0\.0\.1:\d+\/#k=\S+)/.exec(out); if (m) { clearTimeout(t); res(m[1]); } };
    srv.stdout.on('data', on); srv.stderr.on('data', on);
    srv.on('exit', (c) => { clearTimeout(t); rej(new Error(`the demo inn stopped (${c}): ${out.slice(-300)}`)); });
  });
  return { url, stop: async () => { try { srv.kill(); } catch { /* gone */ } try { fs.rmSync(feed, { force: true }); } catch { /* fine */ } } };
}

// a camera flight through the inn (photo mode: a fixed camera, the hero hidden), eased, every frame
const fly = (s, from, to, ms) => s.page.evaluate(([a, b, d]) => new Promise((res) => {
  const t0 = performance.now(), lerp = (p, q, k) => p.map((v, i) => v + (q[i] - v) * k);
  const step = (now) => {
    const k = Math.min(1, (now - t0) / d), e = k < 0.5 ? 2 * k * k : 1 - Math.pow(-2 * k + 2, 2) / 2;
    window.__inn.photo({ pos: lerp(a.pos, b.pos, e), look: lerp(a.look, b.look, e), hide: true });
    k < 1 ? requestAnimationFrame(step) : res();
  };
  requestAnimationFrame(step);
}), [from, to, ms]);
const orbitInn = (s, secs, radius = 6.5, height = 3.6) => s.page.evaluate(([d, r, h]) => new Promise((res) => {
  const I = window.__inn, list = I.seats.filter((q) => q.table && Math.abs(q.y - I.hero.y) < 2);
  let cx = 0, cz = 0, cy = 0; for (const q of list) { cx += q.x; cz += q.z; cy += q.y; }
  const n = Math.max(1, list.length); cx /= n; cz /= n; cy /= n;
  const t0 = performance.now();
  const step = (now) => {
    const k = Math.min(1, (now - t0) / d), a = 0.6 + k * 2.2;
    I.photo({ pos: [cx + Math.sin(a) * r, cy + h, cz + Math.cos(a) * r], look: [cx, cy + 0.8, cz], hide: true });
    k < 1 ? requestAnimationFrame(step) : res();
  };
  requestAnimationFrame(step);
}), [secs * 1000, radius, height]);
// a close-up of a helper at its laptop: the camera comes in from across its table, on the first of a
// few angles with nothing (a pillar, a wall, a shelf) between the camera and the helper
const across = (s, id) => s.page.evaluate((who) => {
  const I = window.__inn, v = I.villagers.get(who); if (!v || !v.st || !v.p) return null;
  const V3 = v.p.g.position.constructor, sp = v.st.spot, t = sp.table || { x: sp.x + Math.sin(sp.yaw), z: sp.z + Math.cos(sp.yaw) };
  const base = Math.atan2(t.x - sp.x, t.z - sp.z), look = [sp.x, sp.y + 0.9, sp.z];
  const clear = (pos) => {
    const o = new V3(...look), d = new V3(pos[0] - look[0], pos[1] - look[1], pos[2] - look[2]), dist = d.length();
    const h = I.hit(o, d.normalize(), dist, I.solid || undefined);
    return !h || h.distance > dist - 0.15;
  };
  for (const turn of [0.35, -0.35, 0.8, -0.8, 0, 1.3, -1.3]) {
    const a = base + turn, ux = Math.sin(a), uz = Math.cos(a);
    const far = [sp.x + ux * 3.2, sp.y + 2.3, sp.z + uz * 3.2], near = [sp.x + ux * 2.1, sp.y + 1.95, sp.z + uz * 2.1];
    if (clear(far) && clear(near)) return { far: { pos: far, look }, near: { pos: near, look: [sp.x + ux * 0.3, sp.y + 0.85, sp.z + uz * 0.3] } };
  }
  return null;
}, id);
const ui = (s, on) => s.page.evaluate((v) => { const u = document.getElementById('ui'); if (u) u.style.visibility = v ? '' : 'hidden'; document.querySelectorAll('.welcome, .empty-hint').forEach((e) => { e.style.visibility = v ? '' : 'hidden'; }); }, on);

export default [
  {
    name: 'agents-demo',
    title: 'Vanilla Agents: the inn, helpers at laptops, quests, the party window',
    ready: (env) => (env.VA_URL || fs.existsSync(path.join(vaDir(env), 'data', 'vanilla_agents')) ? true : `Vanilla Agents not found in ${vaDir(env)} (set VA_DIR)`),
    async setup(s) { const d = await startDemo(s); s.vaUrl = d.url; return d.stop; },
    async run(s) {
      await s.cursor(false);
      await s.shot('loading', 1, async () => {                      // the game's loading screen, zone name, tips
        await s.goto(s.vaUrl);
        await s.page.waitForFunction(() => !document.getElementById('loading'), null, { timeout: 180000 });
        await s.sleep(1200);
      });
      await s.shot('welcome', 6, async () => {
        await s.sleep(3500);
        await s.cursor(true); await s.click('.welcome .btn-green', 900); await s.cursor(false);
      });
      await ui(s, false);
      await s.shot('orbit', 12, async () => { await orbitInn(s, 12); });
      const ids = await s.page.evaluate(() => [...window.__inn.villagers.entries()].filter(([, v]) => v.st && v.stage === 'work').map(([id, v]) => [id, v.p && v.p.look.race]));
      const pick = [ids.find((x) => x[1] === 'gnome'), ...ids.filter((x) => x[1] !== 'gnome')].filter(Boolean).slice(0, 3);
      let k = 0;
      for (const [id] of pick) {
        const cam = await across(s, id); if (!cam) continue;
        await s.shot(`laptop-${++k}`, 5, async () => { await fly(s, cam.far, cam.near, 4800); });
      }
      await s.page.evaluate(() => window.__inn.photo(null));
      await ui(s, true);
      await s.shot('walk', 9, async () => {                          // you walk the inn as your own hero
        await s.page.mouse.move(s.W / 2, s.H / 2);
        await s.page.keyboard.down('KeyW'); await s.sleep(2400);
        await s.page.keyboard.down('KeyA'); await s.sleep(900); await s.page.keyboard.up('KeyA');
        await s.sleep(2200); await s.page.keyboard.up('KeyW');
      });
      await s.shot('windows', 12, async () => {                      // the quest log, the party, the action bar
        await s.page.keyboard.press('KeyL'); await s.sleep(3500); await s.page.keyboard.press('KeyL');
        await s.page.keyboard.press('KeyG'); await s.sleep(3500); await s.page.keyboard.press('KeyG');
        await s.cursor(true); await s.point('[data-panel="action_bar"]', 1200); await s.sleep(1500);
      });
    },
  },
];
