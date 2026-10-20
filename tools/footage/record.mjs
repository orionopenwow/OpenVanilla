#!/usr/bin/env node
// tools/footage/record.mjs: records trailer footage of every Open Vanilla feature, one video per
// feature, without OBS. Each scene (tools/footage/scenes/*.mjs) drives a real Chrome window (your
// graphics card) or a desktop app, films its shots, and the shots are joined into one video:
//
//   _local/video/raw/<date>/<scene>.mp4      (H.264, 1920x1080, 60 fps, plays everywhere)
//   _local/video/raw/<date>/<scene>/<shot>.mp4 (each shot on its own, for editing)
//
//   Record_Footage.bat                       every scene that can run on this PC
//   Record_Footage.bat site-home agents-demo only those
//   Record_Footage.bat --list                what there is and what each needs
//
// Browser scenes are filmed from the page's own frames (Chrome's screencast: no desktop, no
// cursor, full quality); a soft cursor is drawn in the page where a scene points at things.
// Desktop scenes (launcher, Forge) are filmed by window title with ffmpeg. Hands off the mouse and
// keyboard while a scene films. Settings: .env (REALM_URL, OWBOT_USER / OWBOT_PASS for in-game
// scenes, VA_DIR for Vanilla Agents, FORGE_EXE), or the environment.
import { chromium } from 'playwright';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..', '..');
const argv = process.argv.slice(2);
const flag = (n) => argv.includes(n);
const opt = (n, d) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : d; };
const W = Number(opt('--width', 1920)), H = Number(opt('--height', 1080));
const FPS = Number(opt('--fps', 60));
const HEADLESS = flag('--headless');                 // for testing without a screen (software graphics)
const log = (s) => console.log(`[footage] ${s}`);

// .env next to the repo root: KEY=VALUE lines (the same file Film_Herald.bat reads)
const ENV = { ...process.env };
try {
  for (const line of fs.readFileSync(path.join(ROOT, '.env'), 'utf8').split(/\r?\n/)) {
    const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/.exec(line);
    if (m && ENV[m[1]] === undefined) ENV[m[1]] = m[2].replace(/^"(.*)"$/, '$1');
  }
} catch { /* no .env */ }

const stamp = new Date().toISOString().slice(0, 16).replace('T', '_').replace(':', '-');
const OUT = path.resolve(opt('--out', path.join(ROOT, '_local', 'video', 'raw', stamp)));
const PY = ENV.PYTHON_EXE ? ENV.PYTHON_EXE.split(' ') : [process.platform === 'win32' ? 'py' : 'python3', ...(process.platform === 'win32' ? ['-3'] : [])];
const ENCODE = path.join(HERE, 'encode.py');

// ---- scenes -----------------------------------------------------------------------------------
const sceneFiles = fs.readdirSync(path.join(HERE, 'scenes')).filter((f) => f.endsWith('.mjs')).sort();
const SCENES = [];
for (const f of sceneFiles) {
  const m = await import(pathToFileURL(path.join(HERE, 'scenes', f)).href);
  for (const s of [].concat(m.default || [])) SCENES.push(s);
}
if (flag('--list')) {
  for (const s of SCENES) {
    const why = s.ready ? s.ready(ENV) : true;
    console.log(`${s.name.padEnd(18)} ${(s.kind || 'browser').padEnd(8)} ${why === true ? 'ready ' : 'skip  '} ${s.title}${why === true ? '' : '  (' + why + ')'}`);
  }
  process.exit(0);
}
const wanted = argv.filter((a, i) => !a.startsWith('--') && !(i > 0 && ['--out', '--width', '--height', '--fps', '--chrome'].includes(argv[i - 1])));
const todo = SCENES.filter((s) => !wanted.length || wanted.includes(s.name));
if (wanted.length && todo.length !== wanted.length) {
  log(`unknown scene(s): ${wanted.filter((w) => !SCENES.some((s) => s.name === w)).join(', ')} (see --list)`);
  process.exit(2);
}
fs.mkdirSync(OUT, { recursive: true });

// ---- the browser ------------------------------------------------------------------------------
let browser = null;
async function getBrowser() {
  if (browser) return browser;
  const exe = opt('--chrome', ENV.CHROMIUM);
  browser = await chromium.launch({
    headless: HEADLESS,
    executablePath: exe || undefined,
    args: ['--enable-unsafe-webgpu', '--autoplay-policy=no-user-gesture-required', '--mute-audio', '--hide-scrollbars',
      `--window-size=${W + 16},${H + 120}`, '--disable-infobars', '--hide-crash-restore-bubble',
      ...(HEADLESS ? ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'] : [])],
  });
  return browser;
}

// A soft cursor drawn in the page (the screencast has no system cursor): a gold ring that follows
// the mouse and pulses on a click. Installed on every page a scene opens; s.cursor(false) hides it.
const CURSOR_JS = `(() => {
  if (window.__ovCursor) return; const c = document.createElement('div'); window.__ovCursor = c;
  c.style.cssText = 'position:fixed;left:0;top:0;width:22px;height:22px;margin:-11px 0 0 -11px;border:2px solid #ffd76a;border-radius:50%;box-shadow:0 0 10px rgba(255,200,80,.7),inset 0 0 6px rgba(255,200,80,.5);pointer-events:none;z-index:2147483647;transition:transform .12s,opacity .3s;opacity:0';
  const put = () => document.documentElement.appendChild(c); if (document.documentElement) put(); else document.addEventListener('DOMContentLoaded', put);
  addEventListener('mousemove', (e) => { c.style.left = e.clientX + 'px'; c.style.top = e.clientY + 'px'; if (!window.__ovCursorOff) c.style.opacity = '1'; }, true);
  addEventListener('mousedown', () => { c.style.transform = 'scale(.7)'; }, true);
  addEventListener('mouseup', () => { c.style.transform = 'scale(1)'; }, true);
})();`;

function makeKit(page, cdp, sceneDir) {
  const sleep = (ms) => page.waitForTimeout(ms);
  let mx = W / 2, my = H / 2;
  const shots = [];
  const kit = {
    page, cdp, env: ENV, W, H, sleep, log: (m) => log(m), root: ROOT,
    async goto(url, wait = 'domcontentloaded') { await page.goto(url, { waitUntil: wait, timeout: 120000 }); },
    // the mouse glides (eased) instead of jumping
    async glide(x, y, ms = 700) {
      const steps = Math.max(8, Math.round(ms / 16)), x0 = mx, y0 = my;
      for (let i = 1; i <= steps; i++) {
        const t = i / steps, e = t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;
        await page.mouse.move(x0 + (x - x0) * e, y0 + (y - y0) * e); await sleep(ms / steps);
      }
      mx = x; my = y;
    },
    async point(selector, ms = 700) {
      const el = page.locator(selector).first();
      await el.scrollIntoViewIfNeeded({ timeout: 5000 }).catch(() => {});
      const b = await el.boundingBox().catch(() => null);
      if (!b) { log(`  (not found: ${selector})`); return null; }
      await kit.glide(b.x + b.width / 2, b.y + Math.min(b.height / 2, 40), ms);
      return b;
    },
    async click(selector, ms = 700) { const b = await kit.point(selector, ms); if (b) { await sleep(150); await page.mouse.down(); await sleep(90); await page.mouse.up(); } return !!b; },
    async type(text, perChar = 55) { for (const ch of text) { await page.keyboard.type(ch); await sleep(perChar + Math.random() * 40); } },
    // smooth page scroll (eased in the page itself, so every frame moves)
    async scrollTo(target, ms = 2500, offset = 80) {
      await page.evaluate(([t, d, off]) => new Promise((res) => {
        const m = typeof t === 'string' ? /^(.+?)\s*>>\s*nth=(\d+)$/.exec(t) : null;      // 'h2 >> nth=2': the third h2
        const el = typeof t === 'string' ? (m ? document.querySelectorAll(m[1])[Number(m[2])] : document.querySelector(t)) : null;
        const y1 = el ? el.getBoundingClientRect().top + scrollY - off : (t === 'bottom' ? document.documentElement.scrollHeight - innerHeight : Number(t));
        const y0 = scrollY, t0 = performance.now();
        const step = (now) => { const k = Math.min(1, (now - t0) / d), e = k < 0.5 ? 4 * k * k * k : 1 - Math.pow(-2 * k + 2, 3) / 2; scrollTo(0, y0 + (y1 - y0) * e); k < 1 ? requestAnimationFrame(step) : res(); };
        requestAnimationFrame(step);
      }), [target, ms, offset]);
    },
    cursor(on) { return page.evaluate((v) => { window.__ovCursorOff = !v; if (window.__ovCursor) window.__ovCursor.style.opacity = v ? '1' : '0'; }, on); },
    // hide things that should not be in a trailer (support pop-ups, cookie notes)
    tidy(selectors) { return page.addStyleTag({ content: selectors.join(',') + '{display:none!important}' }).catch(() => {}); },
    // film one shot: frames from Chrome's compositor while `action` runs, at least `secs` long
    async shot(name, secs, action = async () => {}) {
      const dir = path.join(sceneDir, name);
      fs.rmSync(dir, { recursive: true, force: true }); fs.mkdirSync(dir, { recursive: true });
      const frames = [];
      let n = 0;
      const onFrame = (f) => {
        n += 1;
        const file = String(n).padStart(6, '0') + '.jpg';
        fs.writeFileSync(path.join(dir, file), Buffer.from(f.data, 'base64'));
        frames.push([file, f.metadata.timestamp]);
        cdp.send('Page.screencastFrameAck', { sessionId: f.sessionId }).catch(() => {});
      };
      cdp.on('Page.screencastFrame', onFrame);
      await cdp.send('Page.startScreencast', { format: 'jpeg', quality: 93, maxWidth: W, maxHeight: H, everyNthFrame: 1 });
      const t0 = Date.now();
      try { await action(); } catch (e) { log(`  ${name}: ${e.message}`); }
      const left = secs * 1000 - (Date.now() - t0);
      if (left > 0) await sleep(left);
      await cdp.send('Page.stopScreencast').catch(() => {});
      cdp.off('Page.screencastFrame', onFrame);
      const end = frames.length ? frames[frames.length - 1][1] + 0.05 : 0;
      fs.writeFileSync(path.join(dir, 'frames.json'), JSON.stringify({ name, w: W, h: H, end, frames }));
      const span = frames.length > 1 ? frames[frames.length - 1][1] - frames[0][1] : 0;
      log(`  ${name}: ${frames.length} frames over ${span.toFixed(1)} s (${span ? (frames.length / span).toFixed(0) : 0} fps)`);
      shots.push(name);
    },
    shots,
  };
  return kit;
}

// ---- desktop windows (launcher, Forge): ffmpeg films the window by its title ----------------------
function grabWindow(title, secs, file) {
  const r = spawnSync(PY[0], [...PY.slice(1), ENCODE, 'grab', '--title', title, '--secs', String(secs), '--fps', String(FPS), '--out', file], { stdio: 'inherit' });
  return r.status === 0;
}

// ---- run --------------------------------------------------------------------------------------
const done = [], skipped = [];
for (const scene of todo) {
  const why = scene.ready ? scene.ready(ENV) : true;
  if (why !== true) { log(`skip ${scene.name}: ${why}`); skipped.push([scene.name, why]); continue; }
  log(`scene ${scene.name}: ${scene.title}`);
  const sceneDir = path.join(OUT, scene.name);
  fs.mkdirSync(sceneDir, { recursive: true });
  let cleanup = null;
  try {
    if (scene.kind === 'desktop') {
      const shots = [];
      const kit = {
        env: ENV, root: ROOT, log: (m) => log(m), sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
        start(cmd, args, cwd) { const p = spawn(cmd, args, { cwd, detached: false, stdio: 'ignore', shell: process.platform === 'win32' }); cleanup = () => { try { p.kill(); } catch { /* gone */ } }; return p; },
        async shot(name, title, secs) { const f = path.join(sceneDir, name + '.mp4'); if (grabWindow(title, secs, f)) shots.push(name); else log(`  ${name}: could not film the "${title}" window`); },
        shots,
      };
      await scene.run(kit);
      if (shots.length) spawnSync(PY[0], [...PY.slice(1), ENCODE, 'join', '--dir', sceneDir, '--out', path.join(OUT, scene.name + '.mp4'), '--fps', String(FPS), '--files', ...shots.map((s) => s + '.mp4')], { stdio: 'inherit' });
    } else {
      const b = await getBrowser();
      const ctx = await b.newContext({ viewport: { width: W, height: H }, deviceScaleFactor: 1 });
      await ctx.addInitScript(CURSOR_JS);
      const page = await ctx.newPage();
      const cdp = await ctx.newCDPSession(page);
      const kit = makeKit(page, cdp, sceneDir);
      if (scene.setup) cleanup = await scene.setup(kit);
      await scene.run(kit);
      await ctx.close();
      if (kit.shots.length) {
        const r = spawnSync(PY[0], [...PY.slice(1), ENCODE, 'scene', '--dir', sceneDir, '--out', path.join(OUT, scene.name + '.mp4'), '--fps', String(FPS), '--shots', ...kit.shots], { stdio: 'inherit' });
        if (r.status !== 0) throw new Error('encoding failed');
      }
    }
    done.push(scene.name);
  } catch (e) {
    log(`${scene.name} failed: ${e.message}`);
    skipped.push([scene.name, e.message]);
  } finally {
    if (cleanup) { try { await cleanup(); } catch { /* best effort */ } }
  }
}
if (browser) await browser.close();
fs.writeFileSync(path.join(OUT, 'take.json'), JSON.stringify({ at: new Date().toISOString(), size: [W, H], fps: FPS, done, skipped }, null, 1));
log(`done: ${done.length} video(s) in ${OUT}${skipped.length ? `; skipped ${skipped.map((s) => s[0]).join(', ')}` : ''}`);
process.exit(done.length || !todo.length ? 0 : 1);
