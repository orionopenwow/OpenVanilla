// ow/workshop.js — Workshop addons in browser play (page layer, loaded by openvanilla.js).
//
//   * The list: the Workshop's hosted packages that browser play can run (`browser: true` in
//     https://openvanilla.app/community/workshop/index.json, set by tools/workshop_build.py: Lua-only
//     addons whose dependencies are in the same package). XML-frame addons still need the desktop app.
//   * Add: the package zip is fetched from the Workshop, checked against the SHA-256 the Workshop
//     lists, unpacked here (no server in between), and kept in this browser (IndexedDB), with the
//     .toc files and the Lua files they list. Nothing else from the zip is kept or run.
//   * Load: addons-loader.js asks loadList() after world entry and runs the files like the suite's,
//     with SavedVariables kept in this browser. ?noaddons=1 in the address skips them (safe mode).
//   * Deep link: play.openvanilla.app/?addon=shagutweaks,shaguchat (the Workshop's "Play it in your
//     browser" button) asks once, adds them, and takes the parameter out of the address.
//   * The dock gets an "Addons" button: what is added, on/off, remove, add more, reload the UI.
//
// Never load-bearing: any failure leaves the game exactly as it was.

export const CATALOG = 'https://openvanilla.app/community/workshop/';
const DB_NAME = 'ow-workshop', STORE = 'addons';
const MAX_ZIP = 8 * 1024 * 1024, MAX_ENTRIES = 3000, MAX_UNPACKED = 32 * 1024 * 1024;

// -- storage -----------------------------------------------------------------------------------

function db() {
  return new Promise((res, rej) => {
    const r = indexedDB.open(DB_NAME, 1);
    r.onupgradeneeded = () => r.result.createObjectStore(STORE, { keyPath: 'id' });
    r.onsuccess = () => res(r.result);
    r.onerror = () => rej(r.error);
  });
}
async function tx(mode, fn) {
  const d = await db();
  return new Promise((res, rej) => {
    const t = d.transaction(STORE, mode);
    const req = fn(t.objectStore(STORE));
    t.oncomplete = () => { d.close(); res(req && req.result); };
    t.onerror = () => { d.close(); rej(t.error); };
  });
}
export const installed = () => tx('readonly', (s) => s.getAll()).catch(() => []);
export const remove = (id) => tx('readwrite', (s) => s.delete(id));
export async function setOn(id, on) {
  const all = await installed();
  const rec = all.find((r) => r.id === id);
  if (!rec) return;
  rec.on = !!on;
  await tx('readwrite', (s) => s.put(rec));
}

// -- the catalogue -----------------------------------------------------------------------------

let catalogP = null;
export function catalog() {
  if (!catalogP) {
    catalogP = fetch(CATALOG + 'index.json', { cache: 'no-cache' })
      .then((r) => { if (!r.ok) throw new Error('Workshop unreachable (' + r.status + ')'); return r.json(); })
      .catch((e) => { catalogP = null; throw e; });
  }
  return catalogP;
}
export async function browserList() {
  const d = await catalog();
  return (d.addons || []).filter((a) => a.browser && a.install && !a.ours);
}

// -- zip (stored and deflate only, which is what the Workshop builder writes) ------------------

export async function unzip(buf) {
  const u8 = new Uint8Array(buf), v = new DataView(buf);
  if (u8.length > MAX_ZIP) throw new Error('package too big');
  let e = u8.length - 22;
  while (e >= 0 && v.getUint32(e, true) !== 0x06054b50) e--;
  if (e < 0) throw new Error('not a zip file');
  const n = v.getUint16(e + 10, true);
  if (n > MAX_ENTRIES) throw new Error('too many files');
  let p = v.getUint32(e + 16, true), total = 0;
  const out = {}, dec = new TextDecoder();
  for (let i = 0; i < n; i++) {
    if (p + 46 > u8.length || v.getUint32(p, true) !== 0x02014b50) throw new Error('damaged zip');
    const flags = v.getUint16(p + 8, true), method = v.getUint16(p + 10, true);
    const csize = v.getUint32(p + 20, true), usize = v.getUint32(p + 24, true);
    const nl = v.getUint16(p + 28, true), xl = v.getUint16(p + 30, true), cl = v.getUint16(p + 32, true);
    const lho = v.getUint32(p + 42, true);
    const name = dec.decode(u8.subarray(p + 46, p + 46 + nl)).replace(/\\/g, '/');
    p += 46 + nl + xl + cl;
    if (name.endsWith('/')) continue;
    if (flags & 1) throw new Error('encrypted zip');
    if (name.startsWith('/') || name.split('/').some((s) => s === '..' || s === '') || /^[a-z]:/i.test(name)) throw new Error('unsafe path in zip: ' + name);
    total += usize;
    if (total > MAX_UNPACKED) throw new Error('package unpacks too big');
    if (lho + 30 > u8.length || v.getUint32(lho, true) !== 0x04034b50) throw new Error('damaged zip');
    const start = lho + 30 + v.getUint16(lho + 26, true) + v.getUint16(lho + 28, true);
    const data = u8.subarray(start, start + csize);
    let bytes;
    if (method === 0) bytes = data;
    else if (method === 8) bytes = new Uint8Array(await new Response(new Blob([data]).stream().pipeThrough(new DecompressionStream('deflate-raw'))).arrayBuffer());
    else throw new Error('unsupported compression in ' + name);
    if (bytes.length !== usize) throw new Error('damaged file in zip: ' + name);
    out[name] = bytes;
  }
  return out;
}

export function parseToc(t) {
  const meta = {}, files = [];
  for (let line of t.replace(/^﻿/, '').split(/\r?\n/)) {
    line = line.trim();
    if (line.startsWith('##')) {
      const i = line.indexOf(':');
      if (i > 0) meta[line.slice(2, i).trim()] = line.slice(i + 1).trim();
    } else if (line && !line.startsWith('#')) files.push(line.replace(/\\/g, '/'));
  }
  const list = (k) => (meta[k] || '').split(',').map((s) => s.trim()).filter(Boolean);
  return { meta, files, deps: [...list('Dependencies'), ...list('RequiredDeps'), ...list('Dep')], sv: [...list('SavedVariables'), ...list('SavedVariablesPerCharacter')] };
}

const hex = (buf) => [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');

// The package's addon folders: [{ name, tocText, files: { 'Folder/file.lua': text } }]. Throws
// (in words a player can read) when browser play cannot run it.
export async function readPackage(buf) {
  const entries = await unzip(buf);
  const latin = new TextDecoder('latin1');
  const text = (b) => { try { return new TextDecoder('utf-8', { fatal: true }).decode(b); } catch { return latin.decode(b); } };
  const byLower = {};
  for (const k of Object.keys(entries)) byLower[k.toLowerCase()] = k;
  const tops = [...new Set(Object.keys(entries).filter((k) => k.includes('/')).map((k) => k.split('/')[0]))];
  const folders = [];
  for (const top of tops) {
    const tocKey = byLower[(top + '/' + top + '.toc').toLowerCase()];
    if (!tocKey) continue;
    const tocText = text(entries[tocKey]);
    const toc = parseToc(tocText);
    const files = {};
    for (const f of toc.files) {
      if (!/\.lua$/i.test(f)) throw new Error(top + ' uses ' + f.split('.').pop().toUpperCase() + ' frames, which browser play cannot load yet. It works in the desktop app.');
      const key = byLower[(top + '/' + f).toLowerCase()];
      if (!key) throw new Error(top + ' is missing ' + f);
      files[top + '/' + f] = text(entries[key]);
    }
    folders.push({ name: top, tocText, files });
  }
  if (!folders.length) throw new Error('no addon in this package');
  const names = new Set(folders.map((f) => f.name));
  for (const f of folders) {
    for (const d of parseToc(f.tocText).deps) {
      if (!names.has(d)) throw new Error(f.name + ' needs ' + d + ', which is not in this package.');
    }
  }
  return folders;
}

// -- adding --------------------------------------------------------------------------------------

export async function add(id) {
  const base = (await catalog()).base || 'https://openvanilla.app/';
  const r = await fetch(CATALOG + encodeURIComponent(id) + '.json', { cache: 'no-cache' });
  if (!r.ok) throw new Error('no Workshop entry called ' + id);
  const a = await r.json();
  if (!a.install || a.ours || !a.files || a.files.length !== 1) throw new Error(a.name + ' is not a hosted package browser play can add.');
  const file = a.files[0];
  const zr = await fetch(new URL(file.url, base).href, { cache: 'no-cache' });
  if (!zr.ok) throw new Error('could not download ' + a.name + ' (' + zr.status + ')');
  const buf = await zr.arrayBuffer();
  const sum = hex(await crypto.subtle.digest('SHA-256', buf));
  if (sum !== String(file.sha256).toLowerCase()) throw new Error(a.name + "'s download does not match the Workshop's checksum; not added.");
  const folders = await readPackage(buf);
  const rec = { id: a.id, name: a.name, author: a.author, license: a.license, version: a.version, compat: a.compat,
    sha256: sum, folders, on: true, added: Date.now() };
  await tx('readwrite', (s) => s.put(rec));
  return rec;
}

// -- loading (addons-loader.js) -------------------------------------------------------------------

// The addon folders to run, in load order (dependencies first). [] in safe mode.
export async function loadList() {
  try { if (new URLSearchParams(location.search).get('noaddons') === '1') return []; } catch { /* no location */ }
  const recs = (await installed()).filter((r) => r.on);
  const out = [];
  for (const r of recs.sort((x, y) => x.added - y.added)) {
    const byName = Object.fromEntries(r.folders.map((f) => [f.name, f]));
    const seen = new Set();
    const visit = (name) => {
      const f = byName[name];
      if (!f || seen.has(name)) return;
      seen.add(name);
      const toc = parseToc(f.tocText);
      toc.deps.forEach(visit);
      out.push({ id: r.id, name, toc, files: f.files });
    };
    Object.keys(byName).sort().forEach(visit);
  }
  return out;
}

// -- the page: dock button, panel, deep link ------------------------------------------------------

const CSS = `
  #ow-ws { position: fixed; inset: 0; z-index: 60; display: flex; align-items: center; justify-content: center;
    background: rgba(5,4,10,.6); font: 13px system-ui, sans-serif; color: #e8e2d0; }
  #ow-ws .box { width: min(560px, calc(100vw - 32px)); max-height: calc(100vh - 64px); overflow: auto; padding: 16px 18px;
    background: #15121d; border: 1px solid rgba(201,162,39,.45); border-radius: 8px; box-shadow: 0 10px 40px #000; }
  #ow-ws h2 { margin: 0 0 4px; font: 600 17px Cinzel, Georgia, serif; color: #f0d78a; }
  #ow-ws p { margin: 4px 0 10px; color: #b9b1a0; line-height: 1.4; }
  #ow-ws .row { display: flex; gap: 10px; align-items: center; padding: 8px 0; border-top: 1px solid rgba(201,162,39,.15); }
  #ow-ws .row .t { flex: 1; min-width: 0; }
  #ow-ws .row b { color: #f3ead2; }
  #ow-ws .row small { display: block; color: #9a927f; }
  #ow-ws button { font: inherit; color: #f3ead2; background: rgba(201,162,39,.18); border: 1px solid rgba(201,162,39,.5);
    border-radius: 5px; padding: 6px 10px; cursor: pointer; white-space: nowrap; }
  #ow-ws button:hover { background: rgba(201,162,39,.3); }
  #ow-ws button.primary { background: #8a6a12; border-color: #c9a227; }
  #ow-ws .msg { min-height: 1.2em; color: #f0d78a; }
  #ow-ws .msg.bad { color: #ff8a7a; }
  #ow-ws .foot { display: flex; gap: 8px; justify-content: flex-end; margin-top: 12px; flex-wrap: wrap; }
  #ow-ws a { color: #f0d78a; }
`;

function el(tag, props, ...kids) {
  const e = document.createElement(tag);
  if (props) for (const [k, v] of Object.entries(props)) {
    if (k === 'class') e.className = v; else if (k.startsWith('on')) e.addEventListener(k.slice(2), v); else e.setAttribute(k, v);
  }
  for (const k of kids) if (k != null) e.append(k);
  return e;
}

function overlay() {
  if (!document.getElementById('ow-ws-style')) document.head.append(el('style', { id: 'ow-ws-style' }, CSS));
  document.getElementById('ow-ws')?.remove();
  const box = el('div', { class: 'box', role: 'dialog', 'aria-modal': 'true', 'aria-labelledby': 'ow-ws-h' });
  const root = el('div', { id: 'ow-ws', onpointerdown: (e) => { if (e.target === root) root.remove(); } }, box);
  addEventListener('keydown', function esc(e) { if (e.key === 'Escape') { root.remove(); removeEventListener('keydown', esc); } });
  document.body.append(root);
  return box;
}

let wenillaRef = null;
async function reloadUI() {
  try { await wenillaRef?.lua?.('ReloadUI() return 1', 5000); } catch { location.reload(); }
}

export async function openPanel() {
  const box = overlay();
  const msg = el('div', { class: 'msg', 'aria-live': 'polite' });
  const say = (t, bad) => { msg.textContent = t || ''; msg.className = 'msg' + (bad ? ' bad' : ''); };
  let changed = false;
  async function render() {
    box.replaceChildren(
      el('h2', { id: 'ow-ws-h' }, 'Addons in browser play'),
      el('p', null, 'Workshop addons that run in the browser. They stay in this browser only. Changes apply after Reload UI. ',
        el('a', { href: 'https://openvanilla.app/workshop.html', target: '_blank', rel: 'noopener' }, 'Browse the whole Workshop')),
      msg);
    const mine = await installed();
    if (mine.length) {
      box.append(el('p', null, el('b', null, 'Added')));
      for (const r of mine) {
        const tog = el('button', { type: 'button', onclick: async () => { await setOn(r.id, !r.on); changed = true; render(); } }, r.on ? 'Turn off' : 'Turn on');
        const rm = el('button', { type: 'button', onclick: async () => { await remove(r.id); changed = true; say(r.name + ' removed.'); render(); } }, 'Remove');
        box.append(el('div', { class: 'row' }, el('div', { class: 't' }, el('b', null, r.name), el('small', null,
          (r.on ? 'On' : 'Off') + ' · ' + (r.author || '') + ' · ' + (r.license || '') + ' · v' + (r.version || '?'))), tog, rm));
      }
    }
    let list = [];
    try { list = await browserList(); } catch (e) { say(String(e.message || e), true); }
    const have = new Set(mine.map((r) => r.id));
    const more = list.filter((a) => !have.has(a.id));
    if (more.length) box.append(el('p', null, el('b', null, 'Add from the Workshop')));
    for (const a of more) {
      const b = el('button', { type: 'button', class: 'primary', onclick: async () => {
        b.disabled = true; say('Adding ' + a.name + '...');
        try { await add(a.id); changed = true; say(a.name + ' added. Reload UI to start it.'); render(); } catch (e) { say(String(e.message || e), true); b.disabled = false; }
      } }, 'Add');
      box.append(el('div', { class: 'row' }, el('div', { class: 't' }, el('b', null, a.name), el('small', null, a.summary || '')), b));
    }
    box.append(el('div', { class: 'foot' },
      el('button', { type: 'button', onclick: () => box.parentElement.remove() }, 'Close'),
      el('button', { type: 'button', class: 'primary', onclick: () => { box.parentElement.remove(); reloadUI(); } }, changed ? 'Reload UI now' : 'Reload UI')));
  }
  await render();
}

async function deepLink() {
  let ids;
  try { ids = (new URLSearchParams(location.search).get('addon') || '').split(',').map((s) => s.trim()).filter((s) => /^[a-z0-9][a-z0-9-]{0,63}$/.test(s)); } catch { return; }
  if (!ids.length) return;
  const u = new URL(location.href);
  u.searchParams.delete('addon');
  history.replaceState(null, '', u.pathname + (u.search || '') + u.hash);
  const list = await browserList().catch(() => []);
  const byId = Object.fromEntries(list.map((a) => [a.id, a]));
  const box = overlay();
  const msg = el('div', { class: 'msg', 'aria-live': 'polite' });
  box.append(el('h2', { id: 'ow-ws-h' }, 'Add Workshop addons to browser play?'),
    el('p', null, 'They are checked against the Workshop and kept in this browser. You can turn them off or remove them from the menu (Addons).'));
  const ok = [];
  for (const id of ids.slice(0, 12)) {
    const a = byId[id];
    box.append(el('div', { class: 'row' }, el('div', { class: 't' }, el('b', null, a ? a.name : id),
      el('small', null, a ? (a.author + ' · ' + a.license + ' · ' + (a.summary || '')) : 'Not available in the browser (it may need the desktop app).'))));
    if (a) ok.push(a);
  }
  box.append(msg);
  const go = el('button', { type: 'button', class: 'primary', onclick: async () => {
    go.disabled = true;
    const bad = [];
    for (const a of ok) { msg.textContent = 'Adding ' + a.name + '...'; try { await add(a.id); } catch (e) { bad.push(a.name + ': ' + (e.message || e)); } }
    msg.className = 'msg' + (bad.length ? ' bad' : '');
    msg.textContent = bad.length ? bad.join(' ') : 'Added. They start when you are in the world (or after Reload UI).';
    go.remove();
  } }, ok.length ? 'Add ' + ok.length : 'Nothing to add');
  if (!ok.length) go.disabled = true;
  box.append(el('div', { class: 'foot' }, el('button', { type: 'button', onclick: () => box.parentElement.remove() }, 'Close'), go));
}

export function installWorkshop(wenilla) {
  wenillaRef = wenilla;
  const addButton = () => {
    const panel = document.getElementById('ow-dock-panel');
    if (!panel || document.getElementById('ow-addons')) return !!panel;
    const b = el('button', { type: 'button', id: 'ow-addons', title: 'Workshop addons in browser play', onclick: () => openPanel() }, 'Addons');
    panel.append(b);
    return true;
  };
  if (!addButton()) { let n = 0; const t = setInterval(() => { if (addButton() || ++n > 40) clearInterval(t); }, 500); }
  deepLink().catch((e) => console.warn('ow/workshop.js deep link', e));
  window.owWorkshop = { openPanel, installed, add, remove, setOn, loadList };
}
