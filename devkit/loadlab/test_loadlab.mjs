#!/usr/bin/env node
// devkit/loadlab/test_loadlab.mjs — checks measure.mjs, the service worker, the glue prefetch and
// the `load` routine against the stub realm (stub/), in a real headless Chromium.
//
//   npm i playwright        (or PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs)
//   CHROMIUM=/path/to/chrome node devkit/loadlab/test_loadlab.mjs
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const run = promisify(execFile);  // async: the stub server lives in this process
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const results = [];
const check = (name, ok, detail = '') => results.push({ name, ok: !!ok, detail });

const pw = await (async () => {
  for (const spec of [process.env.PLAYWRIGHT_MODULE, 'playwright'].filter(Boolean)) {
    try { return await import(spec.startsWith('/') ? pathToFileURL(spec).href : spec); } catch { /* next */ }
  }
  console.error('playwright missing'); process.exit(2);
})();
const { start, mapDbc } = await import('./stub/stub_server.mjs');
const WWW = path.join(HERE, '..', '..', 'realm', 'www');
const pre = await import(pathToFileURL(path.join(WWW, 'prefetch.js')).href);

// -- pure functions ------------------------------------------------------------------------------
check('tileOf matches benilla-wdt world_to_tile (Stormwind)', JSON.stringify(pre.tileOf(-8840.56, 489.7)) === '[31,48]', pre.tileOf(-8840.56, 489.7));
const urls = pre.terrainUrls('Azeroth', 31, 48);
check('terrain URLs in the asset reader form', urls[0] === '/data/World%2FMaps%2FAzeroth%2FAzeroth.wdt' &&
  urls.includes('/data/World%2FMaps%2FAzeroth%2FAzeroth_31_48.adt') && urls.length === 10, urls.slice(0, 2));
const dbc = mapDbc();
const dirs = pre.parseMapDirs(dbc.buffer.slice(dbc.byteOffset, dbc.byteOffset + dbc.length));
check('Map.dbc parse', dirs[0] === 'Azeroth' && dirs[1] === 'Kalimdor', dirs);
check('zone slug', pre.slug('Elwynn Forest') === 'elwynn-forest' && pre.slug("Un'Goro Crater") === 'un-goro-crater');
const sw = fs.readFileSync(path.join(WWW, 'sw.js'), 'utf8');
const patch = fs.readFileSync(path.join(HERE, '0006-openvanilla-lite-textures.patch'), 'utf8');
const swLite = JSON.parse(sw.match(/LITE_PREFIXES = (\[[^\]]*\])/)[1].replace(/'/g, '"'));
const rsLite = [...patch.match(/ELIGIBLE_PREFIXES: \[&str; \d+\] = \[([\s\S]*?)\];/)[1].matchAll(/"([^"]+)"/g)].map((m) => m[1].replace(/\\\\/g, '/'));
// Open Vanilla 1.15 loading: fetch-ahead parsing, the sound order, the combos file, the repeat stats.
const ahead = await import(pathToFileURL(path.join(WWW, 'ahead.js')).href);
const iff = (parts) => Buffer.concat(parts.map(([id, body]) => {
  const h = Buffer.alloc(8); h.write(id.split('').reverse().join(''), 0, 'latin1'); h.writeUInt32LE(body.length, 4);
  return Buffer.concat([h, body]);
}));
const z = (...names) => Buffer.from(names.map((n) => n + '\0').join(''), 'latin1');
const adt = iff([['MVER', Buffer.alloc(4)], ['MTEX', z('Tileset\\Elwynn\\ElwynnGrass.blp')], ['MMDX', z('World\\Azeroth\\Tree01.MDX')],
  ['MWMO', z('World\\wmo\\Inn.wmo')], ['MCNK', Buffer.alloc(16)], ['MTEX', z('ignored.blp')]]);
const refs = ahead.adtRefs(adt.buffer.slice(adt.byteOffset, adt.byteOffset + adt.length));
check('ahead: ADT references in the asset reader form', refs.textures[0] === '/data/tileset%2Felwynn%2Felwynngrass.blp' &&
  refs.m2[0] === '/data/world%2Fazeroth%2Ftree01.m2' && refs.wmo[0] === '/data/world%2Fwmo%2Finn.wmo' && refs.textures.length === 1, refs);
const mohd = Buffer.alloc(64); mohd.writeUInt32LE(3, 4);
const root = iff([['MVER', Buffer.alloc(4)], ['MOHD', mohd], ['MOTX', z('World\\wmo\\Inn.BLP')]]);
const grp = ahead.wmoRefs('/data/world%2Fwmo%2Finn.wmo', root.buffer.slice(root.byteOffset, root.byteOffset + root.length));
check('ahead: WMO groups and textures', grp.length === 4 && grp[0] === '/data/world%2Fwmo%2Finn_000.wmo' && grp[3] === '/data/world%2Fwmo%2Finn.blp', grp);
const along = ahead.tilesAlong(-8913, -137, 1, 0, 400, 2000);
// Heading north (+x): the tile's second index (from x) falls; the first (from y) stays within a tile.
check('ahead: tiles along the heading (north), with the sides', along.length >= 4 && along.every(([a]) => Math.abs(a - 32) <= 1) &&
  along.some(([, b]) => b <= 45) && along.every(([, b]) => b < 48), along);
check('ahead: world map tiles in the sync-read form (benilla-assets sprite_candidates)',
  ahead.mapTileUrls('Elwynn')[0] === '/data/interface%5Cworldmap%5Celwynn%5Celwynn1.blp' && ahead.mapTileUrls('Elwynn').length === 12);
const order = pre.soundOrder(['/data/Sound%5CSpells%5CA.wav', '/data/World%2Fx.m2', '/data/Sound%5CMusic%5CZoneMusic%5CB.mp3', '/data/Sound%5CAmbience%5CC.wav']);
check('prefetch: sounds in priority order (music, ambience, spells), nothing else', order.length === 3 && /Music/.test(order[0]) && /Ambience/.test(order[1]), order);
const combosA = fs.readFileSync(path.join(WWW, 'combos.json'), 'utf8');
const combosB = fs.readFileSync(path.join(HERE, '..', '..', 'realm', 'classicplus', 'combos.json'), 'utf8');
const combos = JSON.parse(combosA).combos;
check('combos.json: realm/www == realm/classicplus, 56 combinations, Paladin Human/Dwarf only', combosA === combosB &&
  Object.values(combos).flat().length === 56 && Object.entries(combos).filter(([, l]) => l.includes(2)).map(([r]) => r).join() === '1,3');
const ms = await import('./measure.mjs');
check('measure: median and p90', ms.pct([5, 1, 3, 2, 4], 50) === 3 && ms.pct([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 90) === 9 && ms.pct([], 50) === null);

check('lite prefixes: sw.js == lite.rs', JSON.stringify(swLite) === JSON.stringify(rsLite), { swLite, rsLite });

// -- measure.mjs cold/warm, no service worker ------------------------------------------------------
const stub = await start(0);
const base = `http://127.0.0.1:${stub.port}`;
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ow-loadlab-'));
const measure = async (out, extra = []) => {
  await run(process.execPath, [path.join(HERE, 'measure.mjs'), '--url', base, '--anonymous', '--until', 'inworld',
    '--world-secs', '2', '--out', out, ...extra], { env: process.env, timeout: 240000 });
  return JSON.parse(fs.readFileSync(out, 'utf8'));
};
try {
  const a = await measure(path.join(tmp, 'a.json'));
  const { cold, warm } = a.runs;
  check('cold reaches the world', cold.reached === 'inworld' && cold.states.login > 0 && cold.states.inworld >= cold.states.charselect, cold.states);
  check('cold: wasm over the network', cold.wasm?.from === 'net' && cold.wasm.mb >= 2.9, cold.wasm);
  check('cold: boot prefetch counted', cold.bootPrefetch.n === 40 && cold.bootPrefetch.mb > 0, cold.bootPrefetch);
  check('cold: boot /data mostly network', cold.data.boot.net >= 40, cold.data.boot);
  check('cold: world reads counted', cold.data.world60.n === 36 && cold.data.world60.net === 36, cold.data.world60);
  check('warm: no /data over the network at boot', warm.data.boot.net === 0 && warm.data.boot.cache === warm.data.boot.n, warm.data.boot);
  check('warm: wasm revalidated (304), not re-downloaded', stub.stats.wasm304 >= 1 && warm.wasm.mb < 0.01, { stats: stub.stats.wasm304, wasm: warm.wasm });
  check('warm: glue prefetch ran from the remembered spot', warm.prefetch?.state === 'done' && warm.prefetch.planned === 11 &&
    /manifest:elwynn-forest/.test(warm.prefetch.source), warm.prefetch);
  check('warm: the zone-manifest file was the one new download', warm.data.glue.net === 1, warm.data.glue);
  const cmp = (await run(process.execPath, [path.join(HERE, 'measure.mjs'), '--compare', path.join(tmp, 'a.json'), path.join(tmp, 'a.json')])).stdout;
  check('--compare runs', cmp.startsWith('compare'), cmp.slice(0, 60));

  // -- measure.mjs --repeat, stages and the quality guard -------------------------------------------
  const shots = path.join(tmp, 'shots');
  const r1 = await measure(path.join(tmp, 'r1.json'), ['--runs', 'cold', '--repeat', '2', '--shot', shots]);
  check('measure --repeat 2: per-stage median and p90', r1.stats?.cold?.n === 2 && r1.stats.cold['world load (ms)'].median != null &&
    r1.stats.cold['inworld (s)'].p90 != null && r1.runs.cold.stages?.marks?.['sound-ready'] != null, r1.stats?.cold);
  const r2 = await measure(path.join(tmp, 'r2.json'), ['--runs', 'cold', '--baseline', shots, '--shot', path.join(tmp, 'shots2')]);
  check('measure --baseline: the settled screenshot matches', r2.quality && r2.quality['cold-0'] && r2.quality['cold-0'].diffPct <= 2, r2.quality);

  // -- capture_manifest.mjs ----------------------------------------------------------------------
  const mdir = path.join(tmp, 'manifests');
  await run(process.execPath, [path.join(HERE, 'capture_manifest.mjs'), '--url', base, '--anonymous', '--secs', '2', '--out-dir', mdir],
    { env: process.env, timeout: 120000 });
  const man = JSON.parse(fs.readFileSync(path.join(mdir, 'elwynn-forest.json'), 'utf8'));
  check('capture_manifest writes the zone manifest (exact URLs, tile, index)', man.urls.length === 36 &&
    man.urls.includes('/data/World%2FMaps%2FAzeroth%2FAzeroth_32_48.adt') && man.urls.includes('/data/World%5CStub%5Ctex0.blp') &&
    JSON.stringify(man.tile) === '[32,48]' && JSON.parse(fs.readFileSync(path.join(mdir, 'index.json'), 'utf8'))['elwynn-forest'].n === 36,
    { n: man.urls.length, tile: man.tile });

  // -- measure.mjs with the service worker -------------------------------------------------------
  const b = await measure(path.join(tmp, 'b.json'), ['--query', 'sw=1']);
  check('sw: page controlled', b.runs.cold.sw === 'controlled' && b.runs.warm.sw === 'controlled', [b.runs.cold.sw, b.runs.warm.sw]);
  check('sw warm: asset-reader reads answered by the worker', b.runs.warm.data.world60.sw === 30, b.runs.warm.data.world60);
  check('sw warm: sync XHR + chain-name reads stay with the HTTP cache', b.runs.warm.data.boot.cache === 54 && b.runs.warm.data.boot.net === 0, b.runs.warm.data.boot);

  // -- service worker probes in one persistent profile -------------------------------------------
  const prof = fs.mkdtempSync(path.join(os.tmpdir(), 'ow-sw-'));
  const ctx = await pw.chromium.launchPersistentContext(prof, { headless: true, executablePath: process.env.CHROMIUM || undefined });
  try {
    const page = ctx.pages()[0] || await ctx.newPage();
    await page.goto(`${base}/?sw=1&auto=1`);
    await page.waitForFunction(() => window.__worldDone === true, null, { timeout: 30000 });
    await page.goto(`${base}/?auto=1`);
    await page.waitForFunction(() => window.__worldDone === true, null, { timeout: 30000 });
    check('sw: remembered (?sw=1 sticks) and controlling', await page.evaluate(() => !!navigator.serviceWorker.controller));
    const sync = await page.evaluate(() => {
      const u = '/data/World%2FStub%2Fdoodad3.m2';
      const x = new XMLHttpRequest(); x.open('GET', u, false); x.send();
      const e = performance.getEntriesByName(location.origin + u).pop();
      return { status: x.status, tagged: (e.serverTiming || []).some((t) => t.name === 'owsw'), workerStart: e.workerStart };
    });
    check('sync XHR never reaches the service worker (so chain names are left to the HTTP cache)', sync.status === 200 && !sync.tagged, sync);
    const asyncProbe = await page.evaluate(async () => {
      const u = '/data/World%2FStub%2Fdoodad3.m2';
      await (await fetch(u)).arrayBuffer();
      const e = performance.getEntriesByName(location.origin + u).pop();
      return (e.serverTiming || []).find((t) => t.name === 'owsw')?.description;
    });
    check('fetch of an asset-reader URL is a worker cache hit', asyncProbe === 'hit', asyncProbe);
    // Lite textures.
    const liteBefore = stub.stats.lite;
    const lite = await page.evaluate(async () => {
      window.owsw.lite('on');
      await new Promise((r) => setTimeout(r, 300));
      const full = (await (await fetch('/data/interface%2Fstub%2Fui.blp')).arrayBuffer()).byteLength;
      const r = await fetch('/data/world%2Fstub%2Ftex9.blp');
      const small = (await r.arrayBuffer()).byteLength;
      window.owsw.lite('off');
      await new Promise((r2) => setTimeout(r2, 300));
      const big = (await (await fetch('/data/world%2Fstub%2Ftex9.blp')).arrayBuffer()).byteLength;
      return { full, small, big };
    });
    check('lite on: world .blp fetched with ?lite=1, UI .blp not', stub.stats.lite === liteBefore + 1 && lite.small * 3 < lite.big, { ...lite, lite: stub.stats.lite - liteBefore });
    // patch-Z versioning.
    const name = 'interface\\addons\\stub\\new.lua';
    const getAddon = () => page.evaluate(async () => (await (await fetch('/data/interface%2Faddons%2Fstub%2Fnew.lua')).arrayBuffer()).byteLength);
    const s1 = await getAddon();
    await getAddon();
    const hits1 = stub.stats.dataByName[name] || 0;
    check('patch-Z family cached under the data version', hits1 === 1, hits1);
    await fetch(`${base}/__patchz?v=t2`);
    await page.evaluate(() => { window.owsw.recheck(); return new Promise((r) => setTimeout(r, 500)); });
    const s2 = await getAddon();
    check('a new data version refetches patch-Z files', (stub.stats.dataByName[name] || 0) === 2 && s2 !== s1, { hits: stub.stats.dataByName[name], s1, s2 });
    // Stage timings (ow/stages.js) from the engine's progress calls and the bridge.
    const stages = await page.evaluate(() => window.owStages?.summary());
    const want = ['engine', 'login', 'charlist', 'world-enter', 'world-ready', 'first-frame', 'sound-ready', 'first-move'];
    check('stages: every stage marked, in order', stages && want.every((k) => stages.marks[k] != null) &&
      stages.marks['world-enter'] <= stages.marks['world-ready'] && stages.marks['world-ready'] <= stages.marks['first-frame'] &&
      stages.spans.worldLoad != null && typeof stages.hitches === 'number', stages);
    // The sync-read memory store: a warmed file is answered from memory, once, byte for byte.
    const mem = await page.evaluate(async () => {
      const u = '/data/World%5CStub%5Cmem.blp';
      const m = await import('/ow/syncread.js');
      await m.warm([u]);
      const before = (await (await fetch('/__stats')).json()).dataByName['World\\Stub\\mem.blp'] || 0;
      const read = () => { const x = new XMLHttpRequest(); x.open('GET', u, false); x.overrideMimeType('text/plain; charset=x-user-defined'); x.send(); return [x.status, x.responseText.length]; };
      const held = window.__ow_has(u);
      const head = (() => { const x = new XMLHttpRequest(); x.open('HEAD', u, false); x.send(); return x.status; })();
      const first = read();
      const mid = (await (await fetch('/__stats')).json()).dataByName['World\\Stub\\mem.blp'] || 0;
      const second = read();
      const after = (await (await fetch('/__stats')).json()).dataByName['World\\Stub\\mem.blp'] || 0;
      return { before, held, head, first, mid, second, after, stats: { ...window.owSyncRead } };
    });
    check('syncread: a warmed file answers the sync XHR from memory (no request), then is let go',
      mem.before === 1 && mem.held && mem.head === 200 && mem.first[0] === 200 && mem.mid === 1 && mem.first[1] === mem.second[1] && mem.second[0] === 200 && mem.stats.hits >= 1, mem);
    // owdiag `load` routine.
    const routine = await page.evaluate(async () => (await import('/ow/owdiag-load.js')).ROUTINE.run());
    check('owdiag load routine reports', routine.v === 1 && routine.data.all.n > 0 && routine.states.inworld != null && routine.sw === 'controlled', JSON.stringify(routine).slice(0, 200));
    check('owdiag load routine carries the stages, the memory store and fetch-ahead', routine.stages?.marks?.['world-ready'] != null &&
      routine.syncRead && typeof routine.syncRead.hits === 'number' && 'ahead' in routine, JSON.stringify({ s: routine.stages, m: routine.syncRead }).slice(0, 300));
    const status = await page.evaluate(() => window.owsw.status());
    check('owsw.status() lists the caches', status.caches && status.caches['ow-data-v1'] > 0 && status.dataVersion === 't2', status);
    // Kill switch.
    await page.goto(`${base}/?nosw=1`);
    await page.waitForTimeout(800);
    const gone = await page.evaluate(async () => ({ regs: (await navigator.serviceWorker.getRegistrations()).length, caches: (await caches.keys()).filter((k) => k.startsWith('ow-')) }));
    check('?nosw=1 unregisters and deletes the caches', gone.regs === 0 && gone.caches.length === 0, gone);
  } finally {
    await ctx.close();
    fs.rmSync(prof, { recursive: true, force: true });
  }
} catch (e) {
  check('no crash', false, String(e.stack || e).slice(0, 600));
} finally {
  stub.server.close();
  fs.rmSync(tmp, { recursive: true, force: true });
}

for (const r of results) console.log(`${r.ok ? 'PASS' : 'FAIL'}  ${r.name}${r.ok ? '' : '   -> ' + JSON.stringify(r.detail)}`);
const failed = results.filter((r) => !r.ok).length;
console.log(`\n${results.length - failed}/${results.length} passed`);
process.exit(failed ? 1 : 0);
