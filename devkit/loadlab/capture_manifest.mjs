#!/usr/bin/env node
// devkit/loadlab/capture_manifest.mjs — record what the client downloads when it enters the world
// in one zone, as a zone manifest for ow/prefetch.js.
//
//   REALM_URL=https://play.openvanilla.app OWBOT_USER=owbot OWBOT_PASS=... \
//     node devkit/loadlab/capture_manifest.mjs [--secs 60] [--walk 20] [--out-dir realm/www/manifests]
//
// Log in the bot's character where you want a manifest (park it in the zone first), then run
// this. It signs in with a FRESH browser profile (nothing cached), presses Enter on the selected
// character, and records every /data request from that moment until --secs after the world is
// up (optionally walking forward for --walk seconds, to pull in the next tiles). The exact URLs
// are kept — '%5C' chain reads and '%2F' asset-reader reads differ, and a prefetch only helps
// when it asks for the very same URL. It drops what every session already gets (boot-manifest
// and world-manifest names), the patch-Z addon files (the loader fetches those itself) and the
// listings, then writes <out-dir>/<zone-slug>.json (merged with an earlier capture of the same
// zone) and refreshes <out-dir>/index.json.
//
// ?boottrace=1 is not used: the trace only sees the synchronous Chain reads, not the asset
// reader's terrain/model/texture fetches, which are most of a zone's bytes. ?noprefetch=1 is,
// so boot.js's own world prefetch doesn't muddy what the zone itself needed.
//
// Options: --url (default $REALM_URL), --anonymous (no web sign-in; dev hosts), --secs N,
// --walk N, --out-dir DIR, --max-mb N (default 60: stop adding URLs past this many MB), --headed.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const has = (n) => argv.includes(n);
const val = (n, d) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : d; };
const slug = (s) => String(s || '').toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');

const url = (val('--url', process.env.REALM_URL || '')).replace(/\/$/, '');
const anonymous = has('--anonymous');
const secs = Number(val('--secs', 60));
const walk = Number(val('--walk', 0));
const maxBytes = Number(val('--max-mb', 60)) * 1048576;
const repoWww = path.join(HERE, '..', '..', 'realm', 'www');
const outDir = val('--out-dir', fs.existsSync(repoWww) ? path.join(repoWww, 'manifests') : 'manifests');
if (!url) { console.error('set REALM_URL or --url'); process.exit(2); }
if (!anonymous && !(process.env.OWBOT_USER && process.env.OWBOT_PASS)) { console.error('set OWBOT_USER and OWBOT_PASS (or --anonymous)'); process.exit(2); }

let pw;
for (const spec of [process.env.PLAYWRIGHT_MODULE, 'playwright'].filter(Boolean)) {
  try { pw = await import(spec.startsWith('/') || /^[A-Za-z]:/.test(spec) ? pathToFileURL(spec).href : spec); break; } catch { /* next */ }
}
if (!pw) { console.error('playwright is missing: npm i playwright'); process.exit(2); }

const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'ow-capture-'));
const ctx = await pw.chromium.launchPersistentContext(profile, {
  headless: !has('--headed'),
  executablePath: process.env.CHROMIUM || undefined,
  viewport: { width: 1280, height: 720 },
  args: ['--enable-unsafe-webgpu', '--use-webgpu-adapter=swiftshader', '--enable-features=Vulkan',
    '--autoplay-policy=no-user-gesture-required', '--mute-audio'],
});
const seen = new Map();   // url path -> bytes
let recording = false;
let code = 0;
try {
  const page = ctx.pages()[0] || await ctx.newPage();
  page.on('requestfinished', async (req) => {
    if (!recording) return;
    const u = new URL(req.url());
    if (u.origin !== new URL(url).origin || !u.pathname.startsWith('/data/') || seen.has(u.pathname)) return;
    let size = 0;
    try { size = (await req.sizes()).responseBodySize; } catch { /* gone */ }
    seen.set(u.pathname, size);
  });
  if (!anonymous) {
    await page.goto(`${url}/login`, { waitUntil: 'domcontentloaded' });
    await page.fill('input[name=username]', process.env.OWBOT_USER);
    await page.fill('input[name=password]', process.env.OWBOT_PASS);
    await Promise.all([page.waitForLoadState('domcontentloaded'), page.click('form[action="/login"] [type=submit]')]);
  }
  await page.goto(`${url}/?noprefetch=1`, { waitUntil: 'domcontentloaded' });
  const state = () => page.evaluate(() => window.wenilla?.state?.session?.state || null).catch(() => null);
  const t0 = Date.now();
  let s = null, pressed = 0;
  while (Date.now() - t0 < 300_000) {
    s = await state();
    if (s === 'inworld') break;
    if (s === 'charselect' && Date.now() - pressed > 5000) {
      recording = true;                       // the entry burst belongs to the zone
      await page.keyboard.press('Enter');
      pressed = Date.now();
    }
    await page.waitForTimeout(250);
  }
  if (s !== 'inworld') throw new Error(`did not reach the world (screen: ${s})`);
  recording = true;
  if (walk > 0) {
    await page.evaluate(() => window.wenilla?.hold?.('MOVEFORWARD'));
    await page.waitForTimeout(walk * 1000);
    await page.evaluate(() => window.wenilla?.release?.('MOVEFORWARD'));
  }
  await page.waitForTimeout(Math.max(0, secs - walk) * 1000);
  recording = false;
  const info = await page.evaluate(async () => {
    const st = window.wenilla.state;
    const names = async (f) => { try { return (await (await fetch(f)).json()).names || []; } catch { return []; } };
    return {
      zone: st.zone?.realZone || st.zone?.name || null, map: st.map?.id ?? null, pos: st.self?.pos || null,
      common: [...(await names('/boot-manifest.json')), ...(await names('/world-manifest.json'))].map((n) => '/data/' + encodeURIComponent(n)),
    };
  });
  if (!info.zone) throw new Error('no zone name in wenilla.state.zone');
  const common = new Set(info.common);
  const skip = (p) => common.has(p) || p === '/data/__index' || p === '/data/__addons' ||
    /^\/data\/interface(%5C|%2F)addons(%5C|%2F)/i.test(p);
  const file = path.join(outDir, `${slug(info.zone)}.json`);
  let prev = { urls: [], bytes: 0 };
  try { prev = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { /* first capture */ }
  const urls = [...(prev.urls || [])];
  let bytes = prev.bytes || 0;
  for (const [p, size] of seen) {
    if (skip(p) || urls.includes(p)) continue;
    if (bytes + size > maxBytes) break;
    urls.push(p);
    bytes += size;
  }
  const tile = info.pos ? [Math.floor((17066.666 - info.pos[1]) / 533.3333), Math.floor((17066.666 - info.pos[0]) / 533.3333)] : null;
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(file, JSON.stringify({ version: 1, zone: info.zone, map: info.map, tile, capturedAt: new Date().toISOString(),
    captures: (prev.captures || 0) + 1, bytes, urls }, null, 1));
  const indexFile = path.join(outDir, 'index.json');
  let index = {};
  try { index = JSON.parse(fs.readFileSync(indexFile, 'utf8')); } catch { /* new */ }
  index[slug(info.zone)] = { zone: info.zone, map: info.map, n: urls.length, mb: Math.round(bytes / 10485.76) / 100 };
  fs.writeFileSync(indexFile, JSON.stringify(index, null, 1));
  console.log(`${info.zone}: ${urls.length} URLs, ${(bytes / 1048576).toFixed(1)} MB (recorded ${seen.size}, ${seen.size - [...seen.keys()].filter((p) => !skip(p)).length} common) -> ${file}`);
} catch (e) {
  console.error('capture failed:', e.message || e);
  code = 1;
} finally {
  await ctx.close();
  fs.rmSync(profile, { recursive: true, force: true });
}
process.exit(code);
