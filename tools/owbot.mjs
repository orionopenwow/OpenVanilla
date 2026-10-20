#!/usr/bin/env node
// tools/owbot.mjs — Open Vanilla's test bot, "Herald": a headless browser that signs in to the realm,
// enters the world as Herald (a Human Hunter), runs the owdiag checks
// (realm/www/owdiag-checks.js) and Herald's data routines (realm/www/owdiag-capture.js), and
// prints ONE line of JSON. No screenshots unless something fails, no model calls: a whole run is a
// few KB of text.
//
//   REALM_URL=https://play.example.org OWBOT_USER=owbot OWBOT_PASS=... node tools/owbot.mjs
//   ... node tools/owbot.mjs --full              also move the character and open the UI panels
//   ... node tools/owbot.mjs --patrol 10         walk around for 10 minutes, sampling the checks
//   ... node tools/owbot.mjs --shots             save screenshots of every screen it passes
//   ... node tools/owbot.mjs --no-snapshot       skip the data routines
//
// Also writes owbot-report.json (everything) and owbot-summary.txt (a dozen lines for people).
// OWBOT_CHAR (default Herald), OWBOT_RACE (Human), OWBOT_CLASS (Hunter): the character it expects.
// OWBOT_WEBHOOK: a Discord webhook URL; when set, the summary is posted there.
//
// Needs: npm i playwright (no browser download needed if Chromium is already installed; set
// CHROMIUM=/path/to/chrome). WebGPU runs on the CPU (SwiftShader), so no graphics card is needed:
// the world is slow (a few fps) but every check still means the same thing.
//
// The account (a web login made for the bot in the realm's admin panel) needs one character:
// Herald, a Human Hunter. Make it once by signing in as the bot at the realm. The character
// screens have no Lua, so the bot presses Enter on whatever is selected and then checks the name.
// Screenshots are taken only when something fails (or with --shots), into owbot-shots/.
// Exit code: 0 all checks passed, 1 a check failed, 2 the bot could not get in.
import { chromium } from 'playwright';
import fs from 'node:fs';

const arg = (name) => process.argv.includes(name);
const val = (name, d) => { const i = process.argv.indexOf(name); return i > 0 ? process.argv[i + 1] : d; };
const URL_ = (process.env.REALM_URL || '').replace(/\/$/, '');
const USER = process.env.OWBOT_USER, PASS = process.env.OWBOT_PASS;
if (!URL_ || !USER || !PASS) { console.error('set REALM_URL, OWBOT_USER and OWBOT_PASS'); process.exit(2); }

const SHOTS = arg('--shots');
const CHAR = process.env.OWBOT_CHAR || 'Herald';
const RACE = process.env.OWBOT_RACE || 'Human';
const CLASS = process.env.OWBOT_CLASS || 'Hunter';
const t0 = Date.now();
const out = { at: new Date().toISOString(), realm: URL_, steps: [] };
const step = (s) => { out.steps.push(`${((Date.now() - t0) / 1000).toFixed(0)}s ${s}`); };

const browser = await chromium.launch({
  headless: true,
  executablePath: process.env.CHROMIUM || undefined,
  args: ['--enable-unsafe-webgpu', '--use-webgpu-adapter=swiftshader', '--enable-features=Vulkan',
    '--autoplay-policy=no-user-gesture-required', '--mute-audio'],
});
const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });
const consoleErrors = [];
page.on('console', (m) => { if (m.type() === 'error') consoleErrors.push(m.text().slice(0, 200)); });
page.on('pageerror', (e) => consoleErrors.push(String(e.message).slice(0, 200)));

const shot = async (name) => {
  fs.mkdirSync('owbot-shots', { recursive: true });
  await page.screenshot({ path: `owbot-shots/${name}.png` }).catch(() => {});
};
const screen = () => page.evaluate(() => window.wenilla?.state?.session?.state || null).catch(() => null);
async function waitScreen(want, secs) {
  for (let i = 0; i < secs; i++) {
    const s = await screen();
    if (want.includes(s)) return s;
    await page.waitForTimeout(1000);
  }
  return await screen();
}
// A dozen lines a person reads in five seconds.
function summary() {
  const r = out.report || {}, sn = out.snapshot || {}, me = sn.self || {};
  const L = [];
  L.push(`${out.ok ? 'PASS' : 'FAIL'} owbot ${out.at} on ${out.realm} in ${out.secs ?? '?'}s`);
  if (out.error) L.push(`stopped: ${out.error}`);
  if (r.pass !== undefined) L.push(`checks: ${r.pass} pass, ${r.fail.length} fail, ${r.warn.length} warn, ${r.skip} skipped`);
  for (const f of r.fail || []) L.push(`  FAIL ${f}`);
  for (const w of r.warn || []) L.push(`  warn ${w}`);
  if (me.name) L.push(`${me.name}: level ${me.level} ${me.race} ${me.class}, ${me.zone}${me.sub ? ' / ' + me.sub : ''} (${me.map?.join(', ')}), ${Math.floor((me.copper || 0) / 10000)}g`);
  if (sn.suite?.addons) {
    const off = Object.entries(sn.suite.addons).filter(([, v]) => v !== 'on').map(([k]) => k);
    L.push(`suite: ${Object.keys(sn.suite.addons).length} addons${off.length ? ', off: ' + off.join(' ') : ', all on'}; server hook ${sn.suite.serverHook ? 'up' : 'DOWN'}; Persona ${sn.suite.persona || 'missing'}`);
  }
  if (sn.skills) {
    const w = sn.skills['Weapon Skills'] || {};
    L.push(`weapon skills: ${Object.keys(w).join(', ') || 'none'}`);
  }
  if (sn.nearby?.enemies?.length) L.push(`nearby: ${sn.nearby.enemies.slice(0, 4).join(', ')}`);
  const lg = out.log || {};
  if (lg.errors?.length) L.push(`page errors: ${lg.errors.slice(0, 3).join(' | ')}`);
  if (lg.failedRequests?.length) L.push(`failed requests: ${lg.failedRequests.slice(0, 3).join(' | ')}`);
  L.push(`steps: ${out.steps.join(' > ')}`);
  return L.join('\n');
}

async function finish() {
  const text = summary();
  try {
    fs.writeFileSync('owbot-report.json', JSON.stringify(out, null, 1));
    fs.writeFileSync('owbot-summary.txt', text + '\n');
  } catch { /* read-only cwd: stdout still has it */ }
  console.log(JSON.stringify(out));
  console.error(text);
  const hook = process.env.OWBOT_WEBHOOK;
  if (hook) {
    await fetch(hook, { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'Herald', content: '```\n' + text.slice(0, 1900) + '\n```' }) }).catch(() => {});
  }
  await browser.close().catch(() => {});
}

async function bail(why) {
  out.ok = false; out.error = why; out.consoleErrors = [...new Set(consoleErrors)].slice(0, 10);
  await shot('bail');
  out.secs = Math.round((Date.now() - t0) / 1000);
  await finish();
  process.exit(2);
}

try {
  await page.goto(`${URL_}/login`, { waitUntil: 'domcontentloaded' });
  await page.fill('input[name=username]', USER);
  await page.fill('input[name=password]', PASS);
  await Promise.all([page.waitForLoadState('domcontentloaded'), page.click('form[action="/login"] [type=submit]')]);
  step(`signed in -> ${new URL(page.url()).pathname}`);
  if (!/\/(play)?$/.test(new URL(page.url()).pathname)) await page.goto(`${URL_}/`, { waitUntil: 'domcontentloaded' });

  // Boot: download + compile the client, then it logs in by itself with the session's game account.
  let s = await waitScreen(['login', 'charselect', 'inworld'], 300);
  step(`boot -> ${s}`);
  if (SHOTS) await shot('1-boot');
  if (s === 'login') s = await waitScreen(['charselect', 'inworld'], 120);
  if (s !== 'charselect' && s !== 'inworld') await bail(`never reached character select (screen: ${s})`);
  if (SHOTS) await shot('2-charselect');
  if (s === 'charselect') {
    await page.waitForTimeout(3000);
    await page.waitForTimeout(1000);
    await page.click('#benilla', { position: { x: 640, y: 360 }, trial: true }).catch(() => {});
    await page.focus('#benilla').catch(() => {});
    await page.keyboard.press('Enter');
    s = await waitScreen(['inworld'], 240);
    if (s !== 'inworld') await bail(`Enter World did not get in (screen: ${s})`);
  }
  step('in world');
  // Let the world and the addon suite settle.
  await page.waitForFunction(() => window.wenilla?.state?.self, null, { timeout: 120000 }).catch(() => {});
  await page.waitForTimeout(15000);
  if (SHOTS) await shot('3-world');

  const patrol = Number(val('--patrol', 0));
  if (patrol > 0) {
    out.patrol = await page.evaluate((m) => window.owdiag.bot(m), patrol);
    out.report = out.patrol.last;
  } else {
    out.report = await page.evaluate((lvl) => window.owdiag.run(lvl), arg('--full') ? 'full' : 'quick');
  }
  out.log = await page.evaluate(() => window.owdiag.log());
  if (!arg('--no-snapshot')) {
    out.snapshot = await page.evaluate(() => window.owdiag.snapshot()).catch((e) => ({ error: e.message }));
    step(`snapshot ${out.snapshot?.ms ?? '?'} ms`);
    const me = out.snapshot?.self;
    if (me?.name && (me.name !== CHAR || me.race !== RACE || me.class.toLowerCase() !== CLASS.toLowerCase())) {
      out.report.warn.push(`owbot.character: playing ${me.name} (${me.race} ${me.class}), expected ${CHAR} (${RACE} ${CLASS})`);
    }
  }
  out.ok = out.report.ok;
  if (!out.ok) await shot('fail-world');
} catch (e) {
  await bail(`bot error: ${e.message.split('\n')[0]}`);
}
out.secs = Math.round((Date.now() - t0) / 1000);
await finish();
process.exit(out.ok ? 0 : 1);
