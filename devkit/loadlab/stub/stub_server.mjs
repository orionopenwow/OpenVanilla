// devkit/loadlab/stub/stub_server.mjs — a fake realm play page for testing measure.mjs, the
// service worker and the glue prefetch without a realm. No dependencies.
//
//   node devkit/loadlab/stub/stub_server.mjs [port]      then open http://127.0.0.1:<port>/
//
// The page (stub.html) behaves like the real one where it matters for loading: it downloads a
// "wasm" (application/wasm, revalidated like the realm's no-cache static files), prefetches
// boot-manifest.json's /data files 8 at a time, reads more with synchronous XHR (the client's
// Chain path), shows the login then the character screen (window.wenilla.state.session.state),
// enters the world on Enter, and reads a world set (fetch, like the client's asset reader). /data
// is immutable for a year, like data.rs. /ow/* serves realm/www/* (the live page layer). GET
// /__stats -> request counts.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PAGE = path.join(HERE, '..', '..', '..', 'realm', 'www');

export const BOOT = Array.from({ length: 40 }, (_, i) => `Interface\\Glues\\Stub\\boot${i}.blp`);
export const SYNC = ['DBFilesClient\\Map.dbc', 'DBFilesClient\\AreaTable.dbc', 'Interface\\FrameXML\\UI.lua'];
export const WORLD = Array.from({ length: 20 }, (_, i) => `World/Stub/doodad${i}.m2`);
export const ZONE = 'Elwynn Forest';
export const POS = [-8913, -137, 82];  // Northshire: Azeroth tile (32, 48)

function bytesFor(name) {
  const h = crypto.createHash('sha256').update(name).digest();
  const n = 2000 + (h.readUInt16LE(0) % 30000);
  return Buffer.alloc(n, h[2]);
}

export function mapDbc() {
  // WDBC with 42 fields; field 0 id, field 1 directory string offset.
  const rows = [[0, 'Azeroth'], [1, 'Kalimdor']];
  let strings = Buffer.from([0]);
  const offs = rows.map(([, s]) => { const o = strings.length; strings = Buffer.concat([strings, Buffer.from(s + '\0')]); return o; });
  const rec = 42 * 4;
  const b = Buffer.alloc(20 + rows.length * rec);
  b.write('WDBC', 0);
  b.writeUInt32LE(rows.length, 4); b.writeUInt32LE(42, 8); b.writeUInt32LE(rec, 12); b.writeUInt32LE(strings.length, 16);
  rows.forEach(([id], i) => { b.writeUInt32LE(id, 20 + i * rec); b.writeUInt32LE(offs[i], 24 + i * rec); });
  return Buffer.concat([b, strings]);
}

const WASM = Buffer.alloc(3 * 1024 * 1024, 7);
const WASM_DATE = new Date(Date.now() - 3600_000).toUTCString();

export function start(port = 0, opts = {}) {
  const stats = { data: 0, dataByName: {}, wasm200: 0, wasm304: 0, lite: 0, version: opts.patchZ ?? 't1' };
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://x');
    const p = url.pathname;
    const send = (code, body, headers = {}) => { res.writeHead(code, headers); res.end(req.method === 'HEAD' ? undefined : body); };
    const coi = { 'Cross-Origin-Opener-Policy': 'same-origin', 'Cross-Origin-Embedder-Policy': 'require-corp' };
    if (p === '/' || p === '/index.html') {
      return send(200, fs.readFileSync(path.join(HERE, 'stub.html')), { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-cache', ...coi });
    }
    if (p === '/__stats') return send(200, JSON.stringify(stats), { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    if (p === '/__reset') { stats.data = 0; stats.dataByName = {}; stats.wasm200 = 0; stats.wasm304 = 0; stats.lite = 0; return send(200, 'ok'); }
    if (p === '/__patchz') { stats.version = url.searchParams.get('v'); return send(200, 'ok'); }
    if (p === '/boot-manifest.json') return send(200, JSON.stringify({ version: 1, names: BOOT }), { 'Content-Type': 'application/json', 'Cache-Control': 'no-cache' });
    if (p === '/world-manifest.json') return send(200, JSON.stringify({ version: 1, names: [] }), { 'Content-Type': 'application/json', 'Cache-Control': 'no-cache' });
    if (p === '/wenilla_bg.wasm') {
      if (req.headers['if-modified-since'] === WASM_DATE) { stats.wasm304++; return send(304, '', { 'Last-Modified': WASM_DATE, 'Cache-Control': 'no-cache' }); }
      stats.wasm200++;
      return send(200, WASM, { 'Content-Type': 'application/wasm', 'Cache-Control': 'no-cache', 'Last-Modified': WASM_DATE, 'Content-Length': WASM.length });
    }
    if (p === '/ow/data-version.json') {
      const body = stats.version ? { patchZ: stats.version, sw: opts.sw || 'opt-in' } : { sw: opts.sw || 'opt-in' };
      return send(200, JSON.stringify(body), { 'Content-Type': 'application/json', 'Cache-Control': 'no-cache' });
    }
    if (p === '/ow/manifests/elwynn-forest.json') {
      return send(200, JSON.stringify({ version: 1, zone: ZONE, urls: ['/data/' + encodeURIComponent('World\\Stub\\zone-only.m2')] }), { 'Content-Type': 'application/json', 'Cache-Control': 'no-cache' });
    }
    if (p.startsWith('/ow/')) {
      const f = path.join(PAGE, path.normalize(p.slice(4)).replace(/^(\.\.[/\\])+/, ''));
      if (!f.startsWith(PAGE) || !fs.existsSync(f)) return send(404, 'nope');
      const type = f.endsWith('.json') ? 'application/json' : f.endsWith('.webp') ? 'image/webp' : 'text/javascript; charset=utf-8';
      const h = { 'Content-Type': type, 'Cache-Control': 'no-cache' };
      if (p === '/ow/sw.js' && !opts.noSwAllowed) h['Service-Worker-Allowed'] = '/';
      return send(200, fs.readFileSync(f), h);
    }
    if (p.startsWith('/data/')) {
      const name = decodeURIComponent(p.slice(6)).replace(/\//g, '\\');
      stats.data++;
      stats.dataByName[name] = (stats.dataByName[name] || 0) + 1;
      let body = name.toLowerCase() === 'dbfilesclient\\map.dbc' ? mapDbc() : bytesFor(name + (name.toLowerCase().startsWith('interface\\addons') ? stats.version : ''));
      const h = { 'Content-Type': 'application/octet-stream', 'Cache-Control': 'private, max-age=31536000, immutable', 'Cross-Origin-Resource-Policy': 'same-origin' };
      if (url.searchParams.get('lite') === '1' && name.toLowerCase().endsWith('.blp')) { stats.lite++; body = body.subarray(0, body.length >> 2); h['X-OW-Lite'] = '1'; }
      return send(200, body, h);
    }
    send(404, 'not found');
  });
  return new Promise((resolve) => server.listen(port, '127.0.0.1', () => resolve({ server, port: server.address().port, stats })));
}

if (process.argv[1] && fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url))) {
  const { port } = await start(Number(process.argv[2] || 8099));
  console.log(`stub realm on http://127.0.0.1:${port}/`);
}
