#!/usr/bin/env node
// devkit/loadlab/measure.mjs — how long the realm takes to load, and what it downloads.
//
//   REALM_URL=https://play.openvanilla.app OWBOT_USER=owbot OWBOT_PASS=... node devkit/loadlab/measure.mjs
//   node devkit/loadlab/measure.mjs --url http://127.0.0.1:8090 --anonymous --until login
//   node devkit/loadlab/measure.mjs --compare before.json after.json
//
// Two runs in one browser profile: COLD (fresh profile: nothing cached) and WARM (the same
// profile, browser closed and reopened, page loaded again — a returning player). For each:
// time to the login screen / character screen / world (window.wenilla.state.session.state), the
// wasm download, the boot-manifest prefetch, and every /data request split into boot, glue
// (login + character screens) and the first --world-secs in the world: count, from network /
// HTTP cache / service worker, MB on the wire vs decoded. Writes one JSON (--out) and prints a
// table. The numbers come from the page's Resource Timing via the same summarize() the in-page
// Herald routine uses (realm/www/owdiag-load.js), so the two always agree.
//
// Options:
//   --url URL          the play page (default $REALM_URL)
//   --anonymous        no web sign-in (a wenilla-host or local play page; the realm needs one)
//   --until STATE      login | charselect | inworld (default: inworld signed in, login anonymous)
//   --world-secs N     how long to stay in the world (default 60)
//   --query Q          extra query for the play page, e.g. "sw=1" or "noprefetch=1" (A/B levers)
//   --runs LIST        cold,warm (default) or just one
//   --out FILE         default load-<date>.json
//   --headed           show the browser
//   --repeat N         do the runs N times (fresh profile each time) and report each stage's
//                      median and p90 (`stats` in the JSON, a second table on screen)
//   --shot DIR         save a screenshot after the world has settled (DIR/<run>-<i>.png)
//   --baseline DIR     compare each settled screenshot with DIR/<run>-0.png (the quality guard:
//                      a loading change must not change what the player sees once settled)
//   --max-diff PCT     fail when more than PCT % of pixels differ from the baseline (default 2)
//   --max-hitches N    fail when the first 30 s in the world has more than N frames over 100 ms
//
// Stages (ow/stages.js, from the page): engine (first glue screen), charlist, world-enter,
// world-ready (loading screen cleared), first-frame, sound-ready, first-move — all ms since
// navigation — plus the frame gaps over 100 ms in the first 30 s after world-ready.
// Env: CHROMIUM (browser binary), OWBOT_USER/OWBOT_PASS, PLAYWRIGHT_MODULE (path to playwright
// if it is not resolvable from here). WebGPU runs on SwiftShader headless: times in the world
// are slower than a real GPU, but download counts and bytes mean the same thing.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const has = (n) => argv.includes(n);
const val = (n, d) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : d; };

// -- compare -------------------------------------------------------------------------------------

function flatten(o, pre = '', out = {}) {
  for (const [k, v] of Object.entries(o || {})) {
    const key = pre ? `${pre}.${k}` : k;
    if (v && typeof v === 'object' && !Array.isArray(v)) flatten(v, key, out);
    else if (typeof v === 'number') out[key] = v;
  }
  return out;
}

function compare(a, b) {
  const A = JSON.parse(fs.readFileSync(a, 'utf8')), B = JSON.parse(fs.readFileSync(b, 'utf8'));
  const lines = [`compare  A=${a}  B=${b}   (B - A)`];
  for (const run of Object.keys({ ...A.runs, ...B.runs })) {
    const fa = flatten(A.runs[run]), fb = flatten(B.runs[run]);
    lines.push(`\n[${run}]`);
    for (const k of [...new Set([...Object.keys(fa), ...Object.keys(fb)])]) {
      if (k.startsWith('v') && k.length === 1) continue;
      const x = fa[k], y = fb[k];
      if (x === y) continue;
      const d = x != null && y != null ? y - x : null;
      const pct = d != null && x ? ` (${d > 0 ? '+' : ''}${Math.round((d / x) * 100)}%)` : '';
      lines.push(`  ${k.padEnd(28)} ${String(x ?? '-').padStart(9)} -> ${String(y ?? '-').padStart(9)}  ${d != null ? (d > 0 ? '+' : '') + Math.round(d * 100) / 100 : ''}${pct}`);
    }
  }
  return lines.join('\n');
}

// -- table ---------------------------------------------------------------------------------------

export function table(result) {
  const runs = Object.keys(result.runs);
  const col = (s) => String(s ?? '-').padStart(16);
  const row = (label, f) => `  ${label.padEnd(26)}${runs.map((r) => col(f(result.runs[r]) ?? '-')).join('')}`;
  const b = (r, p) => r?.data?.[p];
  const L = [`load  ${result.url}  ${result.at}`, `  ${''.padEnd(26)}${runs.map((r) => col(r)).join('')}`];
  L.push(row('login screen (s)', (r) => r.states?.login));
  L.push(row('character screen (s)', (r) => r.states?.charselect));
  L.push(row('in world (s)', (r) => r.states?.inworld));
  L.push(row('wasm MB / ms / from', (r) => r.wasm && `${r.wasm.mb}/${r.wasm.ms}/${r.wasm.from}`));
  L.push(row('boot prefetch n / MB / ms', (r) => `${r.bootPrefetch.n}/${r.bootPrefetch.mb}/${r.bootPrefetch.ms}`));
  for (const p of ['boot', 'glue', 'world60', 'all']) {
    L.push(row(`/data ${p}: n (net/cache/sw)`, (r) => b(r, p) && `${b(r, p).n} (${b(r, p).net}/${b(r, p).cache}/${b(r, p).sw})`));
    L.push(row(`/data ${p}: MB wire/decoded`, (r) => b(r, p) && `${b(r, p).mb}/${b(r, p).decodedMB}`));
  }
  L.push(row('glue prefetch done/planned', (r) => r.prefetch && `${r.prefetch.done}/${r.prefetch.planned}`));
  L.push(row('engine up (ms)', (r) => r.stages?.marks?.engine));
  L.push(row('world load (ms)', (r) => r.stages?.spans?.worldLoad));
  L.push(row('to first frame (ms)', (r) => r.stages?.spans?.toFirstFrame));
  L.push(row('to sound (ms)', (r) => r.stages?.spans?.toSound));
  L.push(row('to first move (ms)', (r) => r.stages?.spans?.toFirstMove));
  L.push(row('hitches >100 ms / worst', (r) => r.stages && `${r.stages.hitches}/${r.stages.worstFrameMs}`));
  L.push(row('service worker', (r) => r.sw));
  return L.join('\n');
}

// -- measure -------------------------------------------------------------------------------------

async function loadPlaywright() {
  for (const spec of [process.env.PLAYWRIGHT_MODULE, 'playwright'].filter(Boolean)) {
    try { return await import(spec.startsWith('/') || /^[A-Za-z]:/.test(spec) ? pathToFileURL(spec).href : spec); } catch { /* next */ }
  }
  console.error('playwright is missing: npm i playwright   (or set PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs)');
  process.exit(2);
}

async function loadSummarize() {
  for (const p of [path.join(HERE, '..', '..', 'realm', 'www', 'owdiag-load.js')]) {
    if (fs.existsSync(p)) return (await import(pathToFileURL(p).href)).summarize;
  }
  throw new Error('owdiag-load.js not found in realm/www');
}

const INIT = () => {
  try { performance.setResourceTimingBufferSize(20000); } catch { /* old browser */ }
  window.__owMarks = {};
  const tick = () => {
    const s = window.wenilla?.state?.session?.state;
    if (s && !(s in window.__owMarks)) window.__owMarks[s] = performance.now();
  };
  setInterval(tick, 100);
};

async function oneRun(chromium, opts, kind, profile, summarize) {
  const ctx = await chromium.launchPersistentContext(profile, {
    headless: !opts.headed,
    executablePath: process.env.CHROMIUM || undefined,
    viewport: { width: 1280, height: 720 },
    args: ['--enable-unsafe-webgpu', '--use-webgpu-adapter=swiftshader', '--enable-features=Vulkan',
      '--autoplay-policy=no-user-gesture-required', '--mute-audio'],
  });
  const errors = [];
  try {
    await ctx.addInitScript(INIT);
    const page = ctx.pages()[0] || await ctx.newPage();
    page.on('pageerror', (e) => errors.push(String(e.message).slice(0, 160)));
    const base = opts.url.replace(/\/$/, '');
    if (!opts.anonymous && kind === 'cold') {
      await page.goto(`${base}/login`, { waitUntil: 'domcontentloaded' });
      await page.fill('input[name=username]', opts.user);
      await page.fill('input[name=password]', opts.pass);
      await Promise.all([page.waitForLoadState('domcontentloaded'), page.click('form[action="/login"] [type=submit]')]);
    }
    const t0 = Date.now();
    await page.goto(`${base}/${opts.query ? '?' + opts.query : ''}`, { waitUntil: 'domcontentloaded' });
    const order = ['login', 'charselect', 'inworld'];
    const want = order.indexOf(opts.until);
    const state = () => page.evaluate(() => window.wenilla?.state?.session?.state || null).catch(() => null);
    let s = null, pressed = 0;
    while (Date.now() - t0 < opts.timeoutMs) {
      s = await state();
      if (order.indexOf(s) >= want) break;
      // The character screens are native (no Lua): Enter on whatever is selected, as owbot does.
      if (s === 'charselect' && want === 2 && Date.now() - pressed > 5000) { await page.keyboard.press('Enter'); pressed = Date.now(); }
      await page.waitForTimeout(250);
    }
    if (order.indexOf(s) < want) errors.push(`stopped at ${s} after ${opts.timeoutMs / 1000}s`);
    if (s === 'inworld') await page.waitForTimeout(opts.worldSecs * 1000);
    else await page.waitForTimeout(1500);  // let the glue prefetch show up in the numbers
    const raw = await page.evaluate(async () => {
      let names = [];
      try { names = (await (await fetch('/boot-manifest.json')).json()).names || []; } catch { /* none */ }
      return {
        entries: performance.getEntriesByType('resource').map((e) => e.toJSON()),
        nav: performance.getEntriesByType('navigation')[0]?.toJSON() || null,
        // ow/prefetch.js marks the exact moment of each state change; the 100 ms poll is the fallback.
        marks: Object.fromEntries(['login', 'charselect', 'inworld'].map((s) => {
          const m = performance.getEntriesByName('ow:state:' + s)[0]?.startTime;
          const p = (window.__owMarks || {})[s];
          return [s, m != null && p != null ? Math.min(m, p) : m ?? p];
        }).filter(([, v]) => v != null)),
        boot: names.map((n) => '/data/' + encodeURIComponent(n)),
        prefetch: window.owPrefetch ? { ...window.owPrefetch } : null,
        sw: navigator.serviceWorker?.controller ? 'controlled' : 'none',
      };
    });
    const sum = summarize(raw.entries, raw.nav, raw.marks, new Set(raw.boot), opts.worldSecs);
    const stages = await page.evaluate(() => (window.owStages ? window.owStages.summary() : null)).catch(() => null);
    const hitchList = await page.evaluate(() => (window.owStages ? window.owStages.hitches.slice(0, 50) : [])).catch(() => []);
    let shot = null;
    if (opts.shot && s === 'inworld') {
      fs.mkdirSync(opts.shot, { recursive: true });
      shot = path.join(opts.shot, `${kind}-${opts.iter || 0}.png`);
      await page.screenshot({ path: shot });
    }
    return { ...sum, stages, hitchList, shot, prefetch: raw.prefetch, sw: raw.sw, reached: s, entries: raw.entries.length, errors };
  } finally {
    await ctx.close();
  }
}

// -- repeat statistics and the quality guard -------------------------------------------------------

export const pct = (xs, p) => {
  const v = xs.filter((x) => typeof x === 'number' && Number.isFinite(x)).sort((a, b) => a - b);
  if (!v.length) return null;
  const i = Math.min(v.length - 1, Math.max(0, Math.ceil((p / 100) * v.length) - 1));
  return v[i];
};

/** Per run kind: median and p90 of every stage and span over the repeats. */
export function stats(repeats) {
  const out = {};
  const kinds = [...new Set(repeats.flatMap((r) => Object.keys(r.runs)))];
  for (const k of kinds) {
    const rows = repeats.map((r) => r.runs[k]).filter(Boolean);
    const pick = {
      'login (s)': (r) => r.states?.login,
      'charselect (s)': (r) => r.states?.charselect,
      'inworld (s)': (r) => r.states?.inworld,
      'engine (ms)': (r) => r.stages?.marks?.engine,
      'charlist (ms)': (r) => r.stages?.marks?.charlist,
      'world load (ms)': (r) => r.stages?.spans?.worldLoad,
      'to first frame (ms)': (r) => r.stages?.spans?.toFirstFrame,
      'to sound (ms)': (r) => r.stages?.spans?.toSound,
      'to first move (ms)': (r) => r.stages?.spans?.toFirstMove,
      'hitches >100ms (30s)': (r) => r.stages?.hitches,
      'worst frame (ms)': (r) => r.stages?.worstFrameMs,
      '/data MB (all)': (r) => r.data?.all?.mb,
    };
    out[k] = { n: rows.length };
    for (const [name, f] of Object.entries(pick)) {
      const xs = rows.map(f);
      out[k][name] = { median: pct(xs, 50), p90: pct(xs, 90) };
    }
  }
  return out;
}

export function statsTable(st) {
  const kinds = Object.keys(st);
  const L = [`  ${''.padEnd(24)}${kinds.map((k) => `${k} median / p90`.padStart(26)).join('')}`];
  for (const name of Object.keys(st[kinds[0]] || {}).filter((n) => n !== 'n')) {
    L.push(`  ${name.padEnd(24)}${kinds.map((k) => `${st[k][name].median ?? '-'} / ${st[k][name].p90 ?? '-'}`.padStart(26)).join('')}`);
  }
  return L.join('\n');
}

/** Share of pixels (%) that differ by more than `tol` in any channel, and the mean difference. */
async function imageDiff(chromium, a, b, tol = 24) {
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM || undefined });
  try {
    const page = await browser.newPage();
    const url = (f) => 'data:image/png;base64,' + fs.readFileSync(f).toString('base64');
    return await page.evaluate(async ([ua, ub, t]) => {
      const load = (u) => new Promise((res, rej) => { const i = new Image(); i.onload = () => res(i); i.onerror = rej; i.src = u; });
      const [ia, ib] = await Promise.all([load(ua), load(ub)]);
      const w = Math.min(ia.width, ib.width), h = Math.min(ia.height, ib.height);
      const px = (img) => { const c = new OffscreenCanvas(w, h), x = c.getContext('2d'); x.drawImage(img, 0, 0); return x.getImageData(0, 0, w, h).data; };
      const A = px(ia), B = px(ib);
      let differ = 0, sum = 0;
      for (let i = 0; i < A.length; i += 4) {
        const d = Math.max(Math.abs(A[i] - B[i]), Math.abs(A[i + 1] - B[i + 1]), Math.abs(A[i + 2] - B[i + 2]));
        sum += d;
        if (d > t) differ += 1;
      }
      const n = A.length / 4;
      return { diffPct: Math.round((differ / n) * 10000) / 100, meanDelta: Math.round((sum / n) * 100) / 100, size: [w, h] };
    }, [url(a), url(b), tol]);
  } finally {
    await browser.close();
  }
}

async function main() {
  if (has('--compare')) {
    const i = argv.indexOf('--compare');
    console.log(compare(argv[i + 1], argv[i + 2]));
    return;
  }
  const anonymous = has('--anonymous');
  const opts = {
    url: val('--url', process.env.REALM_URL || ''),
    anonymous,
    user: process.env.OWBOT_USER, pass: process.env.OWBOT_PASS,
    until: val('--until', anonymous ? 'login' : 'inworld'),
    worldSecs: Number(val('--world-secs', 60)),
    query: val('--query', ''),
    headed: has('--headed'),
    timeoutMs: Number(val('--timeout', 300)) * 1000,
    shot: val('--shot', has('--baseline') ? path.join(os.tmpdir(), 'ow-measure-shots') : null),
  };
  const repeat = Math.max(1, Number(val('--repeat', 1)));
  const baseline = val('--baseline', null);
  const maxDiff = Number(val('--max-diff', 2));
  const maxHitches = has('--max-hitches') ? Number(val('--max-hitches', 0)) : null;
  if (!opts.url) { console.error('set REALM_URL or --url'); process.exit(2); }
  if (!anonymous && (!opts.user || !opts.pass)) { console.error('set OWBOT_USER and OWBOT_PASS, or pass --anonymous'); process.exit(2); }
  const runs = val('--runs', 'cold,warm').split(',');
  const { chromium } = await loadPlaywright();
  const summarize = await loadSummarize();
  const result = { at: new Date().toISOString(), url: opts.url, query: opts.query, until: opts.until, runs: {} };
  const repeats = [];
  for (let i = 0; i < repeat; i++) {
    const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'ow-measure-'));
    const one = { runs: {} };
    try {
      for (const kind of runs) one.runs[kind] = await oneRun(chromium, { ...opts, iter: i }, kind, profile, summarize);
    } finally {
      fs.rmSync(profile, { recursive: true, force: true });
    }
    repeats.push(one);
    if (repeat > 1) console.error(`run ${i + 1}/${repeat} done`);
  }
  result.runs = repeats[0].runs;
  if (repeat > 1) {
    result.repeats = repeats.map((r) => Object.fromEntries(Object.entries(r.runs).map(([k, v]) => [k, { states: v.states, stages: v.stages, data: { all: v.data?.all } }])));
    result.stats = stats(repeats);
  }
  // The quality guard: the settled picture against the baseline's.
  if (baseline) {
    result.quality = {};
    for (const [i, rep] of repeats.entries()) {
      for (const [kind, r] of Object.entries(rep.runs)) {
        const ref = path.join(baseline, `${kind}-0.png`);
        if (!r.shot || !fs.existsSync(ref)) continue;
        const q = await imageDiff(chromium, ref, r.shot);
        result.quality[`${kind}-${i}`] = q;
        if (q.diffPct > maxDiff) r.errors.push(`quality: ${q.diffPct}% of pixels differ from ${ref} (max ${maxDiff}%)`);
      }
    }
  }
  if (maxHitches != null) {
    for (const r of repeats.flatMap((x) => Object.values(x.runs))) {
      if ((r.stages?.hitches ?? 0) > maxHitches) r.errors.push(`hitches: ${r.stages.hitches} frames over 100 ms in the first 30 s (max ${maxHitches})`);
    }
  }
  const out = val('--out', `load-${result.at.slice(0, 19).replace(/[:T]/g, '-')}.json`);
  fs.writeFileSync(out, JSON.stringify(result, null, 1));
  console.log(table(result));
  if (result.stats) console.log(`\nstages over ${repeat} repeats\n` + statsTable(result.stats));
  if (result.quality) console.log('\nquality vs baseline: ' + JSON.stringify(result.quality));
  console.log(`\nwrote ${out}`);
  const errs = repeats.flatMap((x) => Object.values(x.runs)).flatMap((r) => r.errors);
  if (errs.length) { console.log('problems:\n  ' + errs.join('\n  ')); process.exitCode = 1; }
}

const isMain = (() => { try { return fs.realpathSync(fileURLToPath(import.meta.url)) === fs.realpathSync(process.argv[1]); } catch { return false; } })();
if (isMain) main().catch((e) => { console.error(e); process.exit(2); });
