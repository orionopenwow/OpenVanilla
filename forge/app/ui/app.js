// Vanilla Forge UI. One API: forge_core::api, reached through the desktop shell (Tauri's
// `forge` command) or, in a browser, `forge serve`'s POST /api/<command>.
'use strict';

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

async function api(cmd, args = {}, quiet = false) {
  if (!quiet) setStatus('…');
  try {
    let data;
    if (window.__TAURI__?.core?.invoke) {
      data = await window.__TAURI__.core.invoke('forge', { cmd, args });
    } else {
      const r = await fetch('/api/' + cmd, { method: 'POST', body: JSON.stringify(args) });
      const j = await r.json();
      if (!j.ok) throw new Error(j.error);
      data = j.data;
    }
    if (!quiet) setStatus('Ready.');
    return data;
  } catch (e) {
    const msg = String(e?.message ?? e);
    if (!quiet) setStatus(msg);
    throw new Error(msg);
  }
}

function setStatus(t) { $('#status').textContent = t; }
// a key is for a text field (not a checkbox, a slider or a button that happens to have focus)
function isTyping() {
  const a = document.activeElement; if (!a) return false;
  if (a.tagName === 'TEXTAREA' || a.tagName === 'SELECT' || a.isContentEditable) return true;
  return a.tagName === 'INPUT' && !['checkbox', 'radio', 'range', 'button', 'submit', 'color', 'file'].includes(a.type);
}

// ---- pictures: small renders of models, creatures, objects, textures and icons ----------------
// thumbHtml() leaves a placeholder; fillThumbs() asks for the ones scrolled into view, a few at
// a time (forge_core::thumbs draws and caches them on this PC).
const TH = { pics: new Map(), why: new Map(), want: new Set(), busy: false, io: null };
const thKey = (spec) => JSON.stringify(spec);
function thumbHtml(spec, glyph = '◆', cls = '') {
  if (!spec) return `<span class="th none ${cls}"><i>${glyph}</i></span>`;
  const k = thKey(spec);
  const pic = TH.pics.get(k);
  if (pic) return `<span class="th ${cls}"><img src="${pic}" alt=""></span>`;
  if (TH.pics.has(k)) return `<span class="th none ${cls}" title="${esc(TH.why.get(k) || '')}"><i>${glyph}</i></span>`;
  return `<span class="th wait ${cls}" data-th="${esc(k)}"><i>${glyph}</i></span>`;
}
function fillThumbs(root = document) {
  if (!S.project) return;
  TH.io ||= new IntersectionObserver((es) => {
    for (const e of es) if (e.isIntersecting) { TH.io.unobserve(e.target); if (e.target.dataset.th) TH.want.add(e.target.dataset.th); }
    pumpThumbs();
  }, { rootMargin: '300px' });
  for (const el of $$('[data-th]', root)) if (!el.dataset.obs) { el.dataset.obs = '1'; TH.io.observe(el); }
}
async function pumpThumbs() {
  if (TH.busy) return;
  TH.busy = true;
  try {
    while (TH.want.size && S.project) {
      const keys = [...TH.want].slice(0, 12);
      keys.forEach((k) => TH.want.delete(k));
      const todo = keys.filter((k) => !TH.pics.has(k));
      if (!todo.length) { keys.forEach(paintThumb); continue; }
      let r = { pics: {}, why: {} };
      try { r = await api('thumbs', { dir: S.project.dir, items: todo.map((k) => ({ key: k, ...JSON.parse(k) })), size: 128 }, true); } catch { /* drawn as "none" */ }
      for (const k of todo) { const p = r.pics?.[k]; TH.pics.set(k, p ? 'data:image/png;base64,' + p : null); if (r.why?.[k]) TH.why.set(k, r.why[k]); }
      keys.forEach(paintThumb);
    }
  } finally { TH.busy = false; }
}
function paintThumb(k) {
  const pic = TH.pics.get(k);
  for (const el of document.querySelectorAll(`[data-th="${CSS.escape(k)}"]`)) {
    el.classList.remove('wait'); el.removeAttribute('data-th');
    if (pic) el.innerHTML = `<img src="${pic}" alt="">`;
    else { el.classList.add('none'); el.title = TH.why.get(k) || ''; }
  }
}
// forget the pictures of the pack's own art (after a port, a new look …)
function thumbsForget(test = (k) => k.includes('model:') || k.includes('display') || k.includes('icon')) {
  for (const k of [...TH.pics.keys()]) if (test(k)) TH.pics.delete(k);
}
const fileLabel = (p) => String(p || '').replace(/^model:/, '').split(/[\\/]/).pop().replace(/\.(mdx|m2|wmo|blp)$/i, '');
// a grid of pictures for choosing: groups of {value, label, th, glyph, title, note}; picking one
// sets `sel` (a hidden <select> or a plain {value} holder) and calls onPick
function pickGrid(box, groups, current, onPick, empty = '') {
  const any = groups.some((g) => g.items.length);
  box.innerHTML = any ? groups.filter((g) => g.items.length).map((g) => `${g.title ? `<div class="pickhead">${esc(g.title)}</div>` : ''}<div class="pickgrid">${g.items.map((it) =>
    `<button type="button" class="pick${it.value === current ? ' on' : ''}" data-v="${esc(it.value)}" title="${esc(it.title || it.label)}"${it.th && (it.th.model || it.th.display || it.th.object) ? ` data-spin="${esc(thKey(it.th))}"` : ''}>${thumbHtml(it.th, it.glyph)}<span class="pl">${esc(it.label)}</span>${it.note ? `<span class="pn">${esc(it.note)}</span>` : ''}</button>`).join('')}</div>`).join('')
    : `<p class="hint">${empty}</p>`;
  $$('.pick', box).forEach((b) => b.addEventListener('click', () => { $$('.pick', box).forEach((x) => x.classList.toggle('on', x.dataset.v === b.dataset.v)); onPick(b.dataset.v, b); }));
  fillThumbs(box);
}
// point at a model, a creature or an object for a moment: it turns round, bigger, beside it
const SPIN = { pics: new Map(), timer: 0, el: null, frames: 12, size: 176 };
document.addEventListener('mouseover', (e) => {
  const b = e.target.closest?.('[data-spin]');
  if (b === SPIN.el) return;
  clearTimeout(SPIN.timer); spinHide(); SPIN.el = b;
  if (!b || !S.project) return;
  SPIN.timer = setTimeout(async () => {
    const k = b.dataset.spin;
    if (!SPIN.pics.has(k)) {
      try {
        const r = await api('thumbs', { dir: S.project.dir, items: [{ key: 's', ...JSON.parse(k), spin: SPIN.frames }], size: SPIN.size }, true);
        SPIN.pics.set(k, r.pics.s ? 'data:image/png;base64,' + r.pics.s : null);
      } catch { SPIN.pics.set(k, null); }
    }
    const pic = SPIN.pics.get(k);
    if (!pic || SPIN.el !== b) return;
    // a big picture turns where it is
    if ('spinInline' in b.dataset) {
      const th = $('.th', b); if (!th) return;
      b.dataset.still = th.innerHTML;
      th.innerHTML = `<div class="sp" style="--n:${SPIN.frames};--w:${th.clientWidth}px;background-image:url(${pic})"></div>`;
      return;
    }
    let pop = $('#spinpop');
    if (!pop) { pop = document.createElement('div'); pop.id = 'spinpop'; pop.innerHTML = '<div class="sp"></div><div class="cap"></div>'; document.body.appendChild(pop); }
    const r = b.getBoundingClientRect(), W = SPIN.size + 16;
    pop.style.left = `${r.right + 8 + W < innerWidth ? r.right + 8 : Math.max(8, r.left - 8 - W)}px`;
    pop.style.top = `${Math.min(innerHeight - W - 30, Math.max(8, r.top + r.height / 2 - W / 2))}px`;
    const sp = $('.sp', pop);
    sp.style.backgroundImage = `url(${pic})`;
    sp.style.setProperty('--n', SPIN.frames); sp.style.setProperty('--w', SPIN.size + 'px');
    $('.cap', pop).textContent = b.querySelector('.pl')?.textContent || '';
    pop.hidden = false;
  }, 450);
});
function spinHide() {
  const p = $('#spinpop'); if (p) p.hidden = true;
  for (const b of $$('[data-still]')) { const th = $('.th', b); if (th) th.innerHTML = b.dataset.still; delete b.dataset.still; }
}
window.addEventListener('scroll', spinHide, true);
// what was picked lately, per project (models, textures)
function recent(kind, add) {
  const k = `forge.recent.${kind}.${S.project?.dir}`;
  let list = [];
  try { list = JSON.parse(localStorage.getItem(k) || '[]'); } catch {}
  if (add) { list = [add, ...list.filter((x) => x !== add)].slice(0, 12); try { localStorage.setItem(k, JSON.stringify(list)); } catch {} }
  return list;
}
let toastTimer = 0;
// a second click within 4 s confirms
const armedAt = {};
function armed(key, msg) {
  if (armedAt[key] && Date.now() - armedAt[key] < 4000) { delete armedAt[key]; return true; }
  armedAt[key] = Date.now(); toast(msg, true); return false;
}
// a note at the bottom; with `action` ({label, run}) it carries a button and stays longer
function toast(msg, bad, action) {
  const t = $('#toast');
  t.textContent = msg;
  if (action) {
    const b = document.createElement('button');
    b.className = 'btn small gold'; b.textContent = action.label;
    b.addEventListener('click', () => { t.hidden = true; safe(action.run); });
    t.append(' ', b);
  }
  t.className = bad ? 'err' : '';
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.hidden = true; }, action ? 12000 : bad ? 7000 : 3500);
}
async function safe(fn) { try { return await fn(); } catch (e) { toast(e.message, true); } }

// ---- state & navigation -------------------------------------------------------------------------
const S = { status: null, project: null, view: 'home', folder: '', selected: null };

function show(view) {
  S.view = view;
  for (const v of ['home', 'project', 'models', 'world', 'content', 'behaviour', 'data', 'code', 'test', 'publish', 'assets']) $('#view-' + v).hidden = v !== view;
  $$('.mod[data-view]').forEach((b) => b.classList.toggle('active', b.dataset.view === view));
  if (view === 'assets') loadFolder(S.folder);
  if (view === 'project') loadUsage();
  if (view === 'data') loadData();
  if (view === 'models') loadModels();
  if (view === 'world') loadWorld();
  if (view === 'content') loadContent();
  if (view === 'behaviour') loadBehaviour();
  if (view === 'test') loadTest();
  if (view === 'publish') loadPublish();
  if (view === 'code') loadCode();
  studioBody();
}
$$('.mod[data-view]').forEach((b) => b.addEventListener('click', () => show(b.dataset.view)));

// ---- home ---------------------------------------------------------------------------------------
const TEMPLATE_TEXT = {
  addon: 'One addon with a window and a /hello command.',
  pack: 'Art, files, and room for models and data.',
  empty: 'Just the project files.',
};
let pickedTemplate = null;

async function loadHome() {
  S.status = await api('status');
  $('#ver').textContent = 'Forge ' + S.status.version;
  $('#templates').innerHTML = S.status.templates.map((t) =>
    `<button class="tpl" data-t="${t.id}"><b>${esc(t.label)}</b><span>${esc(TEMPLATE_TEXT[t.id] || '')}</span></button>`).join('');
  $$('.tpl').forEach((b) => b.addEventListener('click', () => pickTemplate(b.dataset.t)));
  const g = S.status.game;
  const setup = [];
  setup.push(g ? `<li class="ok">Game found: ${esc(g.files.toLocaleString())} files in ${g.archives.length} archive${g.archives.length === 1 ? '' : 's'}</li>`
    : `<li class="bad">${esc(S.status.gameError || 'Choose your game folder below')}</li>`);
  setup.push('<li class="ok">Checks and builds run on this computer</li>');
  setup.push('<li>Sharing: Publish makes a signed pack to send to a realm (Workshop uploads come later)</li>');
  if (S.status.cli) setup.push(`<li>Your own AI (optional): add Vanilla Forge to an AI assistant that takes MCP servers, with the command <code>"${esc(S.status.cli)}" mcp</code>. It works through the same tools you do, on your PC.</li>`);
  $('#setup').innerHTML = setup.join('');
  if (S.status.config.game_dir) $('#game-dir').value = S.status.config.game_dir;
  $('#licenses').innerHTML = ['MIT', 'Apache-2.0', 'GPL-3.0-or-later', 'MPL-2.0', 'CC-BY-4.0', 'CC-BY-SA-4.0', 'CC0-1.0', 'Unlicense'].map((l) => `<option value="${l}">`).join('');
  $('#id-table').innerHTML = S.status.idTables.map((t) => `<option value="${t.table}">${esc(t.table)} — ${esc(t.what)}</option>`).join('');
  loadRecent();  if (!g && !S.detected) autoDetectGame();
  checkUpdate();
}

// ---- desktop helpers: pickers, links, the game folder, updates -------------------------------------
const DESKTOP = !!window.__TAURI__?.core?.invoke;
$$('.browse').forEach((b) => {
  b.hidden = !DESKTOP; // in a browser (forge serve) paths are typed
  b.addEventListener('click', () => safe(async () => {
    const input = $('#' + b.dataset.for);
    const picked = b.dataset.kind === 'file'
      ? await api('pick_file', { title: 'Choose a file', filter: b.dataset.filter || 'Files', extensions: (b.dataset.ext || '').split(',').filter(Boolean) })
      : await api('pick_folder', { title: 'Choose a folder', start: input.value || '' });
    if (!picked) return;
    input.value = picked;
    input.dataset.touched = '1';
    input.dispatchEvent(new Event('input'));
    if (b.dataset.then) $('#' + b.dataset.then).requestSubmit();
  }));
});
function openUrl(url) {
  if (DESKTOP) safe(() => api('open_url', { url }));
  else window.open(url, '_blank', 'noopener');
}
document.addEventListener('click', (e) => {
  const a = e.target.closest('[data-url]');
  if (!a) return;
  e.preventDefault();
  openUrl(a.dataset.url);
});
async function autoDetectGame() {
  S.detected = true;
  const found = await api('detect_game').catch(() => []);
  if (!found.length) { $('#game-found').textContent = 'Forge looked in the usual places and in the Open Vanilla launcher’s settings: point it at your game folder.'; return; }
  $('#game-dir').value = found[0];
  await safe(async () => {
    const s = await api('set_game', { dir: found[0] });
    toast(`Found your game: ${found[0]} (${s.files.toLocaleString()} files).`);
    await loadHome();
  });
}
// a newer Forge on the website: say so on Home (no downloads from inside the app)
const UPDATE_URL = 'https://openvanilla.app/downloads/forge.json';
async function checkUpdate() {
  if (S.updateChecked) return;
  S.updateChecked = true;
  try {
    const r = await fetch(UPDATE_URL, { cache: 'no-store' });
    if (!r.ok) return;
    const j = await r.json();
    const newer = (a, b) => { const x = a.split('.').map(Number), y = b.split('.').map(Number); for (let i = 0; i < 3; i++) { if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) > (y[i] || 0); } return false; };
    if (j.version && newer(j.version, S.status.version)) {
      $('#update').innerHTML = `Vanilla Forge ${esc(j.version)} is out${j.notes ? `: ${esc(j.notes)}` : ''}. <a href="#" data-url="https://openvanilla.app/forge.html#download">Get it</a>`;
      $('#update').hidden = false;
    }
  } catch { /* offline: nothing to say */ }
}

async function loadRecent() {
  const list = await api('recent');
  $('#recent').innerHTML = list.length ? list.map((p) => p.ok
    ? `<li data-dir="${esc(p.dir)}" class="withth"><span class="th sm cover" data-cover="${esc(p.dir)}"><i>${p.kind === 'addon' ? '{ }' : '▲'}</i></span><span><b>${esc(p.name)}</b> <span class="meta">${esc(p.version)}</span></span><span class="tag">${esc(p.kind)}</span></li>`
    : `<li class="dead" data-dir="${esc(p.dir)}"><span>${esc(p.dir)}</span><span class="meta">missing</span></li>`).join('')
    : '<li class="meta">No projects yet: pick a template above.</li>';
  $$('#recent li[data-dir]').forEach((li) => li.addEventListener('click', () => {
    if (li.classList.contains('dead')) safe(async () => { await api('forget_recent', { dir: li.dataset.dir }); loadRecent(); });
    else openProject(li.dataset.dir);
  }));
  // each project's picture: its world's first tile (projects without a world keep their sign)
  if (S.status?.game) for (const el of $$('#recent [data-cover]')) {
    const dir = el.dataset.cover;
    api('thumbs', { dir, items: [{ key: 'c', cover: true }], size: 96 }, true).then((r) => { if (r.pics.c) el.innerHTML = `<img src="data:image/png;base64,${r.pics.c}" alt="">`; }).catch(() => {});
  }
}

async function pickTemplate(t) {
  pickedTemplate = t;
  $$('.tpl').forEach((b) => b.classList.toggle('on', b.dataset.t === t));
  $('#new-form').hidden = false;
  $('#new-name').focus();
  await suggestDir();
}
async function suggestDir() {
  if ($('#new-dir').dataset.touched) return;
  $('#new-dir').value = await api('suggest_dir', { name: $('#new-name').value || 'my-pack' });
}
$('#new-name').addEventListener('input', () => { clearTimeout(suggestDir.t); suggestDir.t = setTimeout(suggestDir, 250); });
$('#new-dir').addEventListener('input', () => { $('#new-dir').dataset.touched = '1'; });
$('#new-cancel').addEventListener('click', () => { $('#new-form').hidden = true; $$('.tpl').forEach((b) => b.classList.remove('on')); });
$('#new-form').addEventListener('submit', (e) => {
  e.preventDefault();
  safe(async () => {
    const p = await api('new_project', { dir: $('#new-dir').value, name: $('#new-name').value, author: $('#new-author').value, template: pickedTemplate });
    $('#new-form').hidden = true;
    delete $('#new-dir').dataset.touched;
    toast(`Made ${p.manifest.pack.name}.`);
    showProject(p);
  });
});
$('#open-form').addEventListener('submit', (e) => { e.preventDefault(); if ($('#open-dir').value) openProject($('#open-dir').value); });
$('#game-form').addEventListener('submit', (e) => {
  e.preventDefault();
  safe(async () => {
    const s = await api('set_game', { dir: $('#game-dir').value });
    toast(`Game found: ${s.files.toLocaleString()} files.`);
    S.folder = '';
    loadHome();
  });
});

// ---- project ------------------------------------------------------------------------------------
async function openProject(dir) { await safe(async () => showProject(await api('open_project', { dir }))); }

function showProject(p) {
  if (S.project && S.project.dir !== p.dir) { D.t = null; D.rows = []; D.dirty = false; C.path = null; MD.sel = null; $('#sim-live').hidden = true; thumbsForget(() => true); WV.nb?.clear(); }
  S.project = p;
  $('.mod[data-view="project"]').disabled = false;
  $('.mod[data-view="data"]').disabled = false;
  $('.mod[data-view="code"]').disabled = false;
  $('.mod[data-view="models"]').disabled = false;
  $('.mod[data-view="world"]').disabled = false;
  $('.mod[data-view="content"]').disabled = false;
  $('.mod[data-view="behaviour"]').disabled = false;
  $('.mod[data-view="test"]').disabled = false;
  $('.mod[data-view="publish"]').disabled = false;
  $('#btn-check').disabled = $('#btn-build').disabled = false;
  $('#crumb-project').textContent = `${p.manifest.pack.name} ${p.manifest.pack.version}`;
  const f = $('#manifest-form').elements;   // .elements: a form's own .name/.id would shadow the fields
  const m = p.manifest.pack;
  f.name.value = m.name; f.id.value = m.id; f.version.value = m.version; f.license.value = m.license;
  f.authors.value = (m.authors || []).join(', ');
  f.realms.value = (p.manifest.targets?.realms || []).join(', ');
  f.description.value = m.description || '';
  renderFindings(p.findings);
  $('#file-count').textContent = p.files.length;
  $('#files').innerHTML = p.files.length ? p.files.map((x) =>
    `<tr data-path="${esc(x.path)}"><td><code>${esc(x.path)}</code></td><td>${esc(x.source)}</td><td class="how">${x.how === 'pngtoblp' ? 'PNG → BLP' : ''}</td></tr>`).join('')
    : '<tr><td colspan="3" class="hint">No files yet. Put an addon in addons/, art in art/, anything else in files/.</td></tr>';
  $$('#files tr[data-path]').forEach((tr) => tr.addEventListener('click', () => packPreview(tr.dataset.path)));
  $('#pack-preview').hidden = true;
  renderIds(p.ids);
  renderBuild(p.lastBuild);
  show('project');
  loadRecent();
  setTimeout(startTour, 500); // the first time a project is open
}

// "Fix it" where Forge has one safe answer; "Go there" for the rest (fixes.rs keeps the same lists)
const FIXABLE = ['addon.interface', 'addon.title', 'credits.missing', 'manifest.version'];
const SCREEN = (code) => ({ addon: 'code', lua: 'code', lua50: 'code', data: 'data', ids: 'data', world: 'world', models: 'models', publish: 'publish' }[code.split('.')[0]] || 'project');
function renderFindings(list) {
  const errs = list.filter((x) => x.level === 'error').length;
  const warns = list.filter((x) => x.level === 'warning').length;
  const c = $('#check-count');
  c.textContent = errs ? `${errs} error${errs > 1 ? 's' : ''}` : warns ? `${warns} warning${warns > 1 ? 's' : ''}` : 'clear';
  c.className = 'pill ' + (errs ? 'bad' : 'ok');
  $('#findings').innerHTML = list.length ? list.map((x, i) =>
    `<li class="${x.level}">${esc(x.message)}<span class="where">${esc(x.path || '')}${x.path ? ' · ' : ''}${esc(x.code)}</span>
      <span class="fixes">${FIXABLE.includes(x.code) ? `<button class="btn small gold" data-fix="${i}">Fix it</button>` : ''}${SCREEN(x.code) !== 'project' ? `<button class="btn small" data-goto="${i}">Go there</button>` : ''}</span></li>`).join('')
    : '<li class="clear">All checks pass.</li>';
  $$('#findings [data-fix]').forEach((b) => b.addEventListener('click', () => safe(async () => {
    const f = list[+b.dataset.fix];
    toast(await api('fix', { dir: S.project.dir, code: f.code, path: f.path }));
    $('#btn-check').click();
  })));
  $$('#findings [data-goto]').forEach((b) => b.addEventListener('click', () => show(SCREEN(list[+b.dataset.goto].code))));
}

function renderIds(lock) {
  const rows = Object.entries(lock?.tables || {});
  $('#ids').innerHTML = rows.length ? rows.map(([t, r]) =>
    `<tr><td>${esc(t)}</td><td>${r.start.toLocaleString()}–${(r.end - 1).toLocaleString()} <span class="hint">${esc(r.source)}</span></td><td>${r.next.toLocaleString()}</td></tr>`).join('')
    : '<tr><td colspan="3" class="hint">No IDs taken yet. A table gets its range the first time.</td></tr>';
}

function renderBuild(r) {
  if (!r) { $('#build-card').innerHTML = '<span class="hint">Not built yet.</span>'; return; }
  $('#build-card').innerHTML = `<div class="big">${esc(r.mpq || 'No MPQ (no files)')}</div>
    <dl><dt>Files</dt><dd>${r.files} (${(r.bytes / 1024).toFixed(1)} KB)</dd>
    <dt>MPQ</dt><dd>${(r.mpq_bytes / 1024).toFixed(1)} KB</dd>
    <dt>Build hash</dt><dd><code>${esc(r.build_hash.slice(0, 16))}</code></dd>
    <dt>Output</dt><dd><code>build/</code> (MPQ, loose files, manifest.json, report.json)</dd></dl>`;
}

async function packPreview(path) {
  const box = $('#pack-preview');
  box.hidden = false;
  await safe(async () => renderPreview(box, path, await api('pack_preview', { dir: S.project.dir, path })));
}

$('#manifest-form').addEventListener('submit', (e) => {
  e.preventDefault();
  const f = e.target.elements;
  const split = (s) => s.split(',').map((x) => x.trim()).filter(Boolean);
  const m = structuredClone(S.project.manifest);
  Object.assign(m.pack, { name: f.name.value, id: f.id.value, version: f.version.value, license: f.license.value, authors: split(f.authors.value), description: f.description.value });
  m.targets = { realms: split(f.realms.value) };
  safe(async () => { showProject(await api('save_manifest', { dir: S.project.dir, manifest: m })); $('#manifest-saved').textContent = 'Saved.'; setTimeout(() => { $('#manifest-saved').textContent = ''; }, 2000); });
});

$('#btn-check').addEventListener('click', () => safe(async () => {
  const f = await api('check', { dir: S.project.dir });
  renderFindings(f);
  show('project');
  const errs = f.filter((x) => x.level === 'error').length;
  toast(errs ? `${errs} error(s) to fix before a build.` : 'All checks pass.', errs > 0);
}));
$('#btn-build').addEventListener('click', () => safe(async () => {
  const r = await api('build', { dir: S.project.dir });
  showProject(await api('open_project', { dir: S.project.dir }));
  toast(`Built ${r.mpq || 'the pack'}: ${r.files} file(s).`);
}));
$('#id-form').addEventListener('submit', (e) => {
  e.preventDefault();
  safe(async () => {
    const r = await api('allocate_id', { dir: S.project.dir, table: $('#id-table').value, name: $('#id-name').value });
    renderIds(r.lock);
    $('#id-name').value = '';
    toast(`${$('#id-table').value}: ${r.id}`);
  });
});

// ---- models -------------------------------------------------------------------------------------
const MD = { list: [], sel: null, kinds: [], sounds: [] };
async function loadModels(pick) {
  if (!S.project) return;
  await safe(async () => {
    const r = await api('models_list', { dir: S.project.dir });
    MD.list = r.models; MD.kinds = r.kinds; MD.sounds = r.sounds;
    if (!$('#mi-kind').options.length) {
      $('#mi-kind').innerHTML = r.kinds.map((k) => `<option>${k}</option>`).join('');
      $('#mi-sound').innerHTML = r.sounds.map((k) => `<option>${k}</option>`).join('');
    }
    if (r.python) $('#py-path').value = r.python;
    if (pick) MD.sel = pick;
    if (MD.sel && !MD.list.some((m) => m.name === MD.sel)) MD.sel = null;
    if (!MD.sel && MD.list.length) MD.sel = MD.list[0].name;
    renderModelList(); renderModel();
  });
}
function modelStatus(m) {
  if (!m.report) return ['not ported', 'bad'];
  if (m.report.source_format === 'modern-m2') return ['converted game model', 'bad'];
  return [m.report.warnings?.length ? `${m.report.warnings.length} warning(s)` : 'ported', 'ok'];
}
function renderModelList() {
  $('#model-list').innerHTML = MD.list.length ? MD.list.map((m) => {
    const [t, c] = modelStatus(m);
    return `<li data-n="${esc(m.name)}" class="withth ${m.name === MD.sel ? 'on' : ''}">${thumbHtml(m.report ? { model: 'model:' + m.name } : null, '◈', 'sm')}<span><b>${esc(m.spec?.title || m.name)}</b> <span class="meta">${esc(m.spec?.kind || '')}</span></span><span class="pill ${c}">${esc(t)}</span></li>`;
  }).join('') : '<li class="meta">No models yet.</li>';
  fillThumbs($('#model-list'));
  $$('#model-list li[data-n]').forEach((li) => li.addEventListener('click', () => { MD.sel = li.dataset.n; renderModelList(); renderModel(); }));
}
function renderModel() {
  const box = $('#model-detail');
  const m = MD.list.find((x) => x.name === MD.sel);
  if (!m) { box.innerHTML = `<div class="empty"><h2>Bring in your own models</h2>
    <p class="hint">Made something in Blender? Export it as <b>.glb</b> and import it on the left. Forge ports it to the game's own format, with its textures and animations.</p>
    <ol class="plain" style="text-align:left">
      <li>Pick the file and give it an in-game name.</li>
      <li><b>Kind</b> says what it is: a creature, or a doodad that sits in the world.</li>
      <li>Rigged? Name the clips Idle, Walk, Run, Attack, Death and they map to the game's animations.</li>
      <li>Then use it: as a creature's look on the Content screen, or place it on the World screen.</li>
    </ol>
    <p class="hint">Only models you made or have the rights to.</p></div>`; return; }
  const sp = m.spec || {};
  const r = m.report;
  const meta = r?.meta || {};
  const anims = meta.animations || [];
  box.innerHTML = `
    <div class="data-head"><h2>${esc(sp.title || m.name)} <span class="hint">models/${esc(m.name)}</span></h2>
      <div class="row"><button class="btn small" id="md-remove">Remove</button><button class="btn small gold" id="md-port">Save &amp; port</button></div></div>
    <form id="md-form" class="form two mt-s">
      <label>In-game name<input name="title" value="${esc(sp.title || '')}"></label>
      <label>Kind<select name="kind">${MD.kinds.map((k) => `<option ${k === sp.kind ? 'selected' : ''}>${k}</option>`).join('')}</select></label>
      <label>Sounds like<select name="sound"><option value="">default</option>${MD.sounds.map((k) => `<option ${k === sp.sound ? 'selected' : ''}>${k}</option>`).join('')}</select></label>
      <label>Height (yards)<input name="height" type="number" step="0.1" min="0" value="${sp.height ?? ''}" placeholder="as modelled"></label>
      <label>Facing<select name="facing">${['+z', '-z', '+x', '-x'].map((f) => `<option ${f === (sp.facing || '+z') ? 'selected' : ''}>${f}</option>`).join('')}</select></label>
      <label>Collision<select name="collision">${[['', sp.kind === 'doodad' ? 'default (its shape)' : 'default (its box)'], ['mesh', 'its shape: doorways, roofs'], ['box', 'its box'], ['none', 'none: walk through']].map(([v, l]) => `<option value="${v}" ${v === (sp.collision || '') ? 'selected' : ''}>${l}</option>`).join('')}</select></label>
      <label>Texture size cap<select name="texture_max">${[256, 512, 1024].map((t) => `<option ${t === (sp.texture_max || 512) ? 'selected' : ''}>${t}</option>`).join('')}</select></label>
      ${sp.kind === 'mount' ? `<label>Mount speed<select name="speed"><option value="normal" ${sp.speed !== 'epic' ? 'selected' : ''}>60% · level 40</option><option value="epic" ${sp.speed === 'epic' ? 'selected' : ''}>100% · level 60</option></select></label>
      <label>Reins<input name="item_name" value="${esc(sp.item_name || '')}" placeholder="Reins of the ${esc(sp.title || m.name)}"></label>` : ''}
    </form>
    ${r ? `
    <div class="viewer"><canvas id="md-canvas"></canvas><div class="chips" id="md-chips"></div><span class="vhint">drag to turn · wheel to zoom</span></div>
    <div class="stats">
      ${sp.kind === 'doodad' ? `<div class="stat"><b>${(meta.height ?? 0).toFixed(1)} yd</b><span>tall</span></div>` : `<div class="stat"><b>${r.ids?.creature ?? '—'}</b><span>creature entry</span></div>
      <div class="stat"><b>${r.ids?.display ?? '—'}</b><span>display ID</span></div>`}
      <div class="stat"><b>${(meta.triangles ?? 0).toLocaleString()}</b><span>triangles</span></div>
      <div class="stat"><b>${meta.bones ?? '—'}</b><span>bones</span></div>
      <div class="stat"><b>${anims.length}</b><span>animations</span></div>
      ${r.ids?.spell ? `<div class="stat"><b>${r.ids.spell}</b><span>summon spell</span></div><div class="stat"><b>${r.ids.item}</b><span>reins item</span></div>` : ''}
    </div>
    <div class="hint">Files: ${r.files.map((f) => `<code>${esc(f)}</code>`).join(', ')} · ${sp.kind === 'doodad' ? 'place it on the World screen' : `in game (GM): <code>.npc add ${r.ids?.creature ?? ''}</code>${r.ids?.item ? ` · <code>.additem ${r.ids.item}</code>` : ''}`}</div>
    <ul class="findings mt-s">${(r.warnings || []).map((w) => `<li class="warning">${esc(w)}</li>`).join('')}${(r.forge_notes || []).map((w) => `<li class="info">${esc(w)}</li>`).join('')}${r.source_format === 'modern-m2' ? '<li class="error">Converted from a newer game model: fine for testing, but Publish refuses it. Ship only models you made or have the rights to.</li>' : ''}</ul>
    <h2 class="mt">Animations</h2>
    <table class="anims"><thead><tr><th>Clip</th><th>Plays as</th><th>Length</th><th>Speed</th><th>Change</th></tr></thead><tbody>
      ${anims.map((a) => `<tr><td><code>${esc(a.clip)}</code></td><td>${esc(a.wow)} <span class="hint">#${a.id}</span></td><td>${a.seconds.toFixed(2)} s ${a.loop ? '↻' : ''}</td><td>${a.speed ? a.speed.toFixed(1) + ' yd/s' : ''}</td>
        <td><input data-clip="${esc(a.clip)}" value="${esc(sp.anims?.[a.clip] || '')}" placeholder="id[:speed] / skip"></td></tr>`).join('')}
    </tbody></table>
    <details class="mt-s"><summary class="hint">What the porter did</summary><ul class="plain">${(r.info || []).map((i) => `<li class="hint">${esc(i)}</li>`).join('')}</ul></details>`
    : '<p class="hint mt-s">Not ported yet: press <b>Save &amp; port</b>.</p>'}`;
  $('#md-port').addEventListener('click', () => portModel(m));
  if (r) showModel3d(m);
  $('#md-remove').addEventListener('click', () => {
    if (!armed('rm:' + m.name, `Click Remove again to delete ${m.name} and its rows.`)) return;
    safe(async () => { await api('model_remove', { dir: S.project.dir, name: m.name }); MD.sel = null; toast(`Removed ${m.name} (its IDs stay taken).`); loadModels(); });
  });
}
// the ported model in 3D (viewer.js, a module: it may load after this script)
let viewer3d = null;
async function showModel3d(m) {
  const canvas = $('#md-canvas');
  if (!canvas) return;
  if (!window.forgeViewer) await new Promise((res) => window.addEventListener('forge-viewer-ready', res, { once: true }));
  try {
    const prev = await api('model_preview', { dir: S.project.dir, name: m.name });
    viewer3d?.dispose();
    viewer3d = window.forgeViewer.createViewer(canvas, $('#md-chips'));
    viewer3d.show(prev, prev.texture_urls, m.spec?.kind);
  } catch (e) {
    canvas.parentElement.innerHTML = `<p class="hint" style="padding:12px">${esc(e.message)}</p>`;
  }
}
async function portModel(m) {
  const f = $('#md-form').elements;
  const anims = {};
  $$('#model-detail input[data-clip]').forEach((i) => { if (i.value.trim()) anims[i.dataset.clip] = i.value.trim(); });
  const spec = { source: '', kind: f.kind.value, title: f.title.value, height: f.height.value ? +f.height.value : null, facing: f.facing.value,
    texture_max: +f.texture_max.value, sound: f.sound.value || null, anims, collision: f.collision.value || null,
    speed: f.speed ? f.speed.value : null, item_name: f.item_name ? f.item_name.value : null };
  await safe(async () => {
    await api('model_save', { dir: S.project.dir, name: m.name, spec });
    setStatus('Porting…');
    const r = await api('model_port', { dir: S.project.dir, name: m.name });
    thumbsForget();
    toast(`Ported ${m.name}: ${r.meta.triangles} triangles, ${r.meta.animations.length} animations.`);
    loadModels(m.name);
  });
}
$('#model-import').addEventListener('submit', (e) => {
  e.preventDefault();
  safe(async () => {
    setStatus('Porting…');
    const r = await api('model_import', { dir: S.project.dir, source: $('#mi-source').value.trim().replace(/^"|"$/g, ''), name: $('#mi-name').value, title: $('#mi-title').value,
      kind: $('#mi-kind').value, sound: $('#mi-sound').value, height: $('#mi-height').value ? +$('#mi-height').value : null });
    toast(`Imported ${r.name}: creature ${r.report.ids.creature}.`);
    $('#mi-source').value = $('#mi-name').value = $('#mi-title').value = $('#mi-height').value = '';
    loadModels(r.name);
  });
});
$('#py-form').addEventListener('submit', (e) => {
  e.preventDefault();
  safe(async () => toast('The porter runs with ' + await api('set_python', { python: $('#py-path').value })));
});

// ---- content (wizards) --------------------------------------------------------------------------
const W = { kind: 'creature', list: null, sel: null };
const QUALITY = ['Poor', 'Common', 'Uncommon', 'Rare', 'Epic', 'Legendary'];
const STATS = [[3, 'Agility'], [4, 'Strength'], [5, 'Intellect'], [6, 'Spirit'], [7, 'Stamina'], [1, 'Health'], [0, 'Mana']];
const ITEM_KINDS = [ // [label, class, subclass, inventory type]
  ['One-hand sword', 2, 7, 13], ['Two-hand sword', 2, 8, 17], ['One-hand axe', 2, 0, 13], ['Two-hand axe', 2, 1, 17], ['One-hand mace', 2, 4, 13],
  ['Dagger', 2, 15, 13], ['Staff', 2, 10, 17], ['Bow', 2, 2, 15], ['Shield', 4, 6, 14],
  ['Cloth chest', 4, 1, 5], ['Leather chest', 4, 2, 5], ['Mail chest', 4, 3, 5], ['Plate chest', 4, 4, 5], ['Cloak', 4, 1, 16], ['Ring', 4, 0, 11], ['Neck', 4, 0, 2],
  ['Head (cloth)', 4, 1, 1], ['Hands (leather)', 4, 2, 10], ['Feet (mail)', 4, 3, 8], ['Legs (plate)', 4, 4, 7],
  ['Potion / food', 0, 0, 0], ['Quest item', 12, 0, 0], ['Trade goods', 7, 0, 0], ['Junk', 15, 0, 0],
];

async function loadContent(keep) {
  if (!S.project) return;
  await safe(async () => {
    W.list = await api('wiz_list', { dir: S.project.dir });
    for (const k of ['made_creatures', 'items', 'quests']) W.list[k].sort((x, y) => x.id - y.id);
    $('#wiz-creatures').innerHTML = W.list.creatures.map((c) => `<option value="${c.id}">${esc(c.name)}</option>`).join('');
    $('#wiz-items').innerHTML = W.list.items.map((i) => `<option value="${i.id}">${esc(i.name)}</option>`).join('');
    renderWizList();
    if (W.want) { const w = W.want; W.want = null; await openWizFrom(w); } else if (!keep) wizDefault();
  });
}
// open the Content screen on one kind, and one thing (or a new one)
async function openWizFrom({ kind, id }) {
  W.kind = kind; $$('#wiz-tabs button').forEach((x) => x.classList.toggle('on', x.dataset.k === kind));
  if (id) await openWiz(id); else { W.sel = null; renderWizList(); showWizForm(null); }
}
// an open tab never sits empty: the first thing in it, the quest chains, or how to start
function wizDefault() {
  const L = W.list;
  const first = { creature: L.made_creatures[0]?.id, quest: null, item: L.items[0]?.id, vendor: L.vendors[0] }[W.kind];
  if (W.kind === 'quest' && L.quests.length) { W.sel = null; renderWizList(); renderChains(); return; }
  if (first) { openWiz(first); return; }
  const what = { creature: ['creature', 'A creature needs a name and a look (a display from the game, or a model you import). Then give it a fight plan and dialogue on the Behaviour screen.'],
    quest: ['quest', 'A quest has someone who gives it, something to do (kill or bring), and a reward. Chains show up here once you have two.'],
    item: ['item', 'Weapons, armour, potions, quest items: pick a kind and a look, set the stats, and see the tooltip as the game draws it.'],
    vendor: ['vendor list', 'Pick one of your creatures and the items it sells.'] }[W.kind];
  $('#wiz-form-panel').innerHTML = `<div class="empty"><h2>No ${what[0]}s yet</h2><p class="hint">${what[1]}</p><button class="btn gold" id="wiz-new2">Make a ${what[0]}</button></div>`;
  $('#wiz-new2').addEventListener('click', () => { W.sel = null; renderWizList(); showWizForm(null); });
}
function renderWizList() {
  const L = W.list;
  const disp = (id) => (L.creatures.find((c) => c.id === id) || {}).display;
  const rows = W.kind === 'creature' ? L.made_creatures.map((c) => [c.id, c.name, c.display && { display: c.display }, '☻'])
    : W.kind === 'quest' ? L.quests.map((q) => [q.id, q.title, null, '!'])
    : W.kind === 'item' ? L.items.map((i) => [i.id, i.name, i.display && { item_display: i.display }, '⚔'])
    : L.vendors.map((v) => [v, (L.creatures.find((c) => c.id === v) || {}).name || `creature ${v}`, disp(v) && { display: disp(v) }, '☻']);
  rows.sort((a, b) => a[0] - b[0]);
  $('#wiz-list').innerHTML = rows.length ? rows.map(([id, n, th, gl]) => `<li data-id="${id}" class="withth ${W.sel === id ? 'on' : ''}">${thumbHtml(th, gl, 'sm')}<span>${esc(n)}</span><span class="n">${id}</span></li>`).join('')
    : `<li class="meta">None yet.</li>`;
  fillThumbs($('#wiz-list'));
  $$('#wiz-list li[data-id]').forEach((li) => li.addEventListener('click', () => openWiz(+li.dataset.id)));
}
$$('#wiz-tabs button').forEach((b) => b.addEventListener('click', () => {
  W.kind = b.dataset.k; W.sel = null;
  $$('#wiz-tabs button').forEach((x) => x.classList.toggle('on', x === b));
  renderWizList(); wizDefault();
}));
// Quest Weaver: the pack's quests as chains (prev → next), with their levels, who gives them and what they pay
function renderChains() {
  const qs = W.list.quests || [];
  if (!qs.length) return;
  const by = new Map(qs.map((q) => [q.id, q]));
  const nextOf = (q) => (q.next && by.get(q.next)) || qs.find((x) => x.prev === q.id && x.id !== q.id);
  const starts = qs.filter((q) => !(q.prev && by.has(q.prev)) && !qs.some((x) => x.next === q.id));
  const seen = new Set(), chains = [];
  for (const s of starts.length ? starts : qs) { const c = []; let q = s; while (q && !seen.has(q.id)) { seen.add(q.id); c.push(q); q = nextOf(q); } if (c.length) chains.push(c); }
  for (const q of qs) if (!seen.has(q.id)) chains.push([q]);
  const money = (q) => { const [g, si, c] = coins(q.money || 0); return q.money ? `${g ? g + 'g ' : ''}${si ? si + 's ' : ''}${c ? c + 'c' : ''}`.trim() : '<span class="meta">no money</span>'; };
  $('#wiz-form-panel').innerHTML = `<h2>Quest chains</h2><p class="hint">Your quests in the order they unlock (Previous / Next in a quest's form). Click one to open it.</p>
    ${chains.map((c) => `<div class="chain">${c.map((q, i) => `${i ? '<span class="chain-arrow">→</span>' : ''}<div class="qnode" data-q="${q.id}"><b>${esc(q.title)}</b>
      <div class="meta">level ${q.level || '?'} · ${q.giver ? esc(q.giver.name || '#' + q.giver.entry) : '<span class="warn">no giver</span>'}${q.ender && q.giver && q.ender.entry !== q.giver.entry ? ` → ${esc(q.ender.name || '#' + q.ender.entry)}` : ''}</div>
      <div class="meta">${q.kills.length ? `kill ${q.kills.length} kind${q.kills.length > 1 ? 's' : ''} · ` : ''}${money(q)}</div></div>`).join('')}</div>`).join('')}`;
  $$('#wiz-form-panel .qnode').forEach((n) => n.addEventListener('click', () => openWiz(+n.dataset.q)));
}
$('#wiz-new').addEventListener('click', () => { W.sel = null; renderWizList(); showWizForm(null); });
async function openWiz(id) {
  W.sel = id; renderWizList();
  await safe(async () => showWizForm(await api('wiz_get', { dir: S.project.dir, kind: W.kind, id }), id));
}

const pairRows = (name, list, n, idList, idPh) => `<div class="pairs" data-pairs="${name}">${Array.from({ length: n }, (_, i) => {
  const p = (list || [])[i] || {};
  return `<div class="pair"><input data-p="id" list="${idList}" placeholder="${idPh}" value="${p.id || ''}"><input data-p="count" type="number" min="0" placeholder="count" value="${p.count || ''}"></div>`;
}).join('')}</div>`;
const readPairs = (box) => $$(`[data-pairs="${box}"] .pair`).map((d) => ({ id: parseInt($('[data-p=id]', d).value, 10) || 0, count: parseInt($('[data-p=count]', d).value, 10) || 0 })).filter((p) => p.id > 0);
const coins = (c) => [Math.floor(c / 10000), Math.floor(c / 100) % 100, c % 100];
const coinInputs = (name, c) => { const [g, s, cu] = coins(c || 0); return `<div class="coin" data-coin="${name}"><input type="number" min="0" value="${g}" title="gold"><input type="number" min="0" max="99" value="${s}" title="silver"><input type="number" min="0" max="99" value="${cu}" title="copper"></div>`; };
const readCoin = (name) => { const [g, s, c] = $$(`[data-coin="${name}"] input`).map((i) => +i.value || 0); return g * 10000 + s * 100 + c; };

function showWizForm(spec, id) {
  const box = $('#wiz-form-panel');
  if (W.kind === 'creature') {
    const c = spec || { min_level: 10, max_level: 11, attitude: 'hostile', rank: 0, loot: [] };
    box.innerHTML = `<div class="data-head"><h2>${id ? esc(c.name) + ` <span class="hint">creature ${id}</span>` : 'New creature'}</h2><div class="row">${id ? '<button class="btn small" id="wiz-bh" title="Fight plan, lines it says, dialogue">Behaviour →</button>' : ''}<button class="btn small gold" id="wiz-save">Save creature</button></div></div>
      <form class="form mt-s" id="wiz-f"><div class="form two">
        <label>Name<input name="name" required value="${esc(c.name || '')}"></label>
        <label>Title under the name<input name="subname" value="${esc(c.subname || '')}" placeholder="Innkeeper"></label>
        <label>Look: search by name, or a number<input name="display" required value="${c.display || ''}" placeholder="wolf, kobold, 58000" autocomplete="off"></label>
        <label>Attitude<select name="attitude">${['hostile', 'neutral', 'friendly'].map((a) => `<option ${a === c.attitude ? 'selected' : ''}>${a}</option>`).join('')}</select></label>
        <label>Level from<input name="min_level" type="number" min="1" max="63" value="${c.min_level || 1}"></label>
        <label>Level to<input name="max_level" type="number" min="1" max="63" value="${c.max_level || c.min_level || 1}"></label>
        <label>Rank<select name="rank">${[[0, 'Normal'], [1, 'Elite'], [4, 'Rare'], [2, 'Rare elite'], [3, 'Boss']].map(([v, l]) => `<option value="${v}" ${v === c.rank ? 'selected' : ''}>${l}</option>`).join('')}</select></label>
        <label>Size<input name="scale" type="number" step="0.1" min="0.1" value="${c.scale || 1}"></label>
        <label>Health ×<input name="health" type="number" step="0.1" min="0.1" value="${c.health || 1}"></label>
        <label>Damage ×<input name="damage" type="number" step="0.1" min="0.1" value="${c.damage || 1}"></label>
        <label class="row"><input type="checkbox" name="quest_giver" ${c.quest_giver ? 'checked' : ''} style="width:auto"> Gives quests</label>
        <label class="row"><input type="checkbox" name="vendor" ${c.vendor ? 'checked' : ''} style="width:auto"> Sells things</label>
        <div class="wide lookpick"><div class="portrait" id="wiz-portrait"></div><div class="grow"><div class="hint" id="wiz-lookhint">Type in Look to see the game's creatures that match, and pick one.</div><div id="wiz-lookgrid" class="pickbox"></div></div></div></div>
        <fieldset><legend>Drops</legend><div class="form two"><label>Gold min (g s c)${coinInputs('gmin', c.gold_min)}</label><label>Gold max${coinInputs('gmax', c.gold_max)}</label></div>
          <div class="pairs mt-s" data-loot>${Array.from({ length: 8 }, (_, i) => { const d = (c.loot || [])[i] || {};
            return `<div class="pair" style="grid-template-columns:1fr 80px 64px 64px"><input data-l="item" list="wiz-items" placeholder="item" value="${d.item || ''}"><input data-l="chance" type="number" step="0.1" placeholder="%" value="${d.chance ?? ''}"><input data-l="min" type="number" min="1" placeholder="min" value="${d.min || ''}"><input data-l="max" type="number" min="1" placeholder="max" value="${d.max || ''}"></div>`; }).join('')}</div>
          <p class="hint">A negative chance drops only for players on a quest that needs the item.</p></fieldset>
      </form><datalist id="wiz-cdisplays"></datalist><ul class="findings mt-s" id="wiz-notes"></ul>`;
    $('#wiz-bh')?.addEventListener('click', () => { BH.entry = id; show('behaviour'); });
    const disp = $('#wiz-f').elements.display;
    const portrait = () => {
      const v = parseInt(disp.value, 10), box = $('#wiz-portrait');
      box.innerHTML = v ? thumbHtml({ display: v }, '☻', 'xl') : '<span class="th xl none"><i>☻</i></span>';
      if (v) { box.dataset.spin = thKey({ display: v }); box.dataset.spinInline = ''; } else delete box.dataset.spin;
      fillThumbs(box);
    };
    portrait();
    disp.addEventListener('input', () => {
      clearTimeout(W.dt); const q = disp.value.trim();
      if (/^\d+$/.test(q)) { W.dt = setTimeout(portrait, 300); return; }
      if (q.length < 2) return;
      W.dt = setTimeout(async () => { try {
        const h = await api('data_search', { table: 'CreatureDisplayInfo', q, limit: 36 }, true);
        $('#wiz-lookhint').textContent = h.length ? `${h.length} look(s) for "${q}": pick one.` : `Nothing for "${q}".`;
        pickGrid($('#wiz-lookgrid'), [{ items: h.map((x) => ({ value: String(x.ID), label: x.label, title: `${x.label} (${x.ID})`, th: { display: x.ID }, glyph: '☻' })) }], null,
          (v) => { disp.value = v; portrait(); });
      } catch { /* */ } }, 250);
    });
    $('#wiz-save').addEventListener('click', () => {
      const f = $('#wiz-f').elements;
      if (!$('#wiz-f').reportValidity()) return;
      const loot = $$('[data-loot] .pair').map((d) => ({ item: parseInt($('[data-l=item]', d).value, 10) || 0, chance: +$('[data-l=chance]', d).value || 0,
        min: +$('[data-l=min]', d).value || 1, max: +$('[data-l=max]', d).value || 1 })).filter((d) => d.item > 0);
      wizSave('wiz_creature', { spec: { id: id || null, name: f.name.value, subname: f.subname.value, display: parseInt(f.display.value, 10) || 0,
        attitude: f.attitude.value, min_level: +f.min_level.value, max_level: +f.max_level.value, rank: +f.rank.value, scale: +f.scale.value,
        health: +f.health.value, damage: +f.damage.value, quest_giver: f.quest_giver.checked, vendor: f.vendor.checked,
        gold_min: readCoin('gmin'), gold_max: readCoin('gmax'), loot } });
    });
  } else if (W.kind === 'quest') {
    const q = spec || { level: 10, kill: [], collect: [], reward_items: [], choice_items: [] };
    box.innerHTML = `<div class="data-head"><h2>${id ? esc(q.title) + ` <span class="hint">quest ${id}</span>` : 'New quest'}</h2><button class="btn small gold" id="wiz-save">Save quest</button></div>
      <form class="form mt-s" id="wiz-f">
        <div class="form two"><label>Title<input name="title" required value="${esc(q.title || '')}"></label>
        <label>Level<input name="level" type="number" min="1" max="60" value="${q.level || 10}"></label>
        <label>Given by (creature)<input name="giver" list="wiz-creatures" required value="${q.giver || ''}"></label>
        <label>Turned in to (blank: same)<input name="ender" list="wiz-creatures" value="${q.ender && q.ender !== q.giver ? q.ender : ''}"></label>
        <label>Zone (AreaTable ID, optional)<input name="zone" type="number" min="0" value="${q.zone || ''}"></label>
        <label>After quest (optional)<input name="prev_quest" type="number" min="0" value="${q.prev_quest || ''}"></label></div>
        <label>Story (what the giver says; $N is the player's name)<textarea name="details" rows="4">${esc(q.details || '')}</textarea></label>
        <label>Objectives (the quest log's summary)<textarea name="objectives" rows="2">${esc(q.objectives || '')}</textarea></label>
        <div class="form two"><label>While unfinished<textarea name="request_text" rows="2">${esc(q.request_text || '')}</textarea></label>
        <label>On turn-in<textarea name="reward_text" rows="2">${esc(q.reward_text || '')}</textarea></label></div>
        <div class="form two"><fieldset><legend>Kill</legend>${pairRows('kill', q.kill, 4, 'wiz-creatures', 'creature')}</fieldset>
        <fieldset><legend>Bring</legend>${pairRows('collect', q.collect, 4, 'wiz-items', 'item')}</fieldset>
        <fieldset><legend>Rewards: everyone gets</legend>${pairRows('reward_items', q.reward_items, 4, 'wiz-items', 'item')}<div class="mt-s hint">Money (g s c)</div>${coinInputs('money', q.money)}</fieldset>
        <fieldset><legend>Rewards: choose one</legend>${pairRows('choice_items', q.choice_items, 6, 'wiz-items', 'item')}</fieldset></div>
      </form><ul class="findings mt-s" id="wiz-notes"></ul>`;
    $('#wiz-save').addEventListener('click', () => {
      const f = $('#wiz-f').elements;
      if (!$('#wiz-f').reportValidity()) return;
      const s = { id: id || null, title: f.title.value, level: +f.level.value, giver: parseInt(f.giver.value, 10), ender: parseInt(f.ender.value, 10) || null,
        zone: +f.zone.value || 0, prev_quest: +f.prev_quest.value || 0, details: f.details.value, objectives: f.objectives.value,
        request_text: f.request_text.value, reward_text: f.reward_text.value, kill: readPairs('kill'), collect: readPairs('collect'),
        reward_items: readPairs('reward_items'), choice_items: readPairs('choice_items'), money: readCoin('money') };
      wizSave('wiz_quest', { spec: s });
    });
  } else if (W.kind === 'item') {
    const it = spec || { quality: 2, stats: [], stack: 1 };
    const kindIdx = ITEM_KINDS.findIndex((k) => k[1] === it.class && k[2] === it.subclass && k[3] === it.inventory_type);
    box.innerHTML = `<div class="data-head"><h2>${id ? esc(it.name) + ` <span class="hint">item ${id}</span>` : 'New item'}</h2><button class="btn small gold" id="wiz-save">Save item</button></div>
      <div class="item-grid"><form class="form mt-s" id="wiz-f">
        <div class="form two"><label>Name<input name="name" required value="${esc(it.name || '')}"></label>
        <label>Quality<select name="quality">${QUALITY.map((q, i) => `<option value="${i}" ${i === (it.quality ?? 2) ? 'selected' : ''}>${q}</option>`).join('')}</select></label>
        <label>Kind<select name="kind">${ITEM_KINDS.map((k, i) => `<option value="${i}" ${i === kindIdx ? 'selected' : ''}>${k[0]}</option>`).join('')}${kindIdx < 0 && id ? '<option value="-1" selected>as saved</option>' : ''}</select></label>
        <label>Look: search by name, or a number<input name="display" value="${it.display || ''}" placeholder="sword, robe, 5161" autocomplete="off"></label>
        <div id="wiz-ilookgrid" class="pickbox wide"></div>
        <label>Item level<input name="item_level" type="number" min="0" value="${it.item_level || ''}"></label>
        <label>Requires level<input name="required_level" type="number" min="0" max="60" value="${it.required_level || ''}"></label>
        <label>Armour<input name="armor" type="number" min="0" value="${it.armor || ''}"></label>
        <label>Durability<input name="durability" type="number" min="0" value="${it.durability || ''}"></label>
        <label>Damage min<input name="dmg_min" type="number" min="0" step="0.1" value="${it.dmg_min || ''}"></label>
        <label>Damage max<input name="dmg_max" type="number" min="0" step="0.1" value="${it.dmg_max || ''}"></label>
        <label>Speed (seconds)<input name="delay" type="number" min="0" step="0.1" value="${it.delay ? it.delay / 1000 : ''}"></label>
        <label>Binds<select name="bonding">${[[0, 'Never'], [1, 'When picked up'], [2, 'When equipped'], [4, 'Quest item']].map(([v, l]) => `<option value="${v}" ${v === (it.bonding || 0) ? 'selected' : ''}>${l}</option>`).join('')}</select></label>
        <label>Stacks to<input name="stack" type="number" min="1" value="${it.stack || 1}"></label></div>
        <fieldset><legend>Stats</legend><div class="pairs">${Array.from({ length: 5 }, (_, i) => { const s = (it.stats || [])[i] || {};
          return `<div class="pair" data-stat><select>${['<option value="">—</option>'].concat(STATS.map(([v, l]) => `<option value="${v}" ${s.value && s.kind === v ? 'selected' : ''}>${l}</option>`)).join('')}</select><input type="number" value="${s.value || ''}"></div>`; }).join('')}</div></fieldset>
        <div class="form two"><label>Vendor price (g s c)${coinInputs('buy', it.buy_price)}</label><label>Description<input name="description" value="${esc(it.description || '')}"></label></div>
        <div class="form two"><label>Your own icon (a picture; optional)<input name="icon" type="file" accept="image/png,image/jpeg,image/x-tga"></label>
        <p class="hint">Squared and fitted to the game's 64 × 64; the item keeps the Look's model and gets your icon.</p></div>
      </form>
      <div class="tip-wrap"><div class="tip-icon" id="tip-icon"></div><div class="wowtip" id="wowtip"></div></div></div>
      <datalist id="wiz-displays"></datalist><ul class="findings mt-s" id="wiz-notes"></ul>`;
    // the tooltip as the game draws it, while you type
    const tip = () => {
      const f = $('#wiz-f').elements;
      const k = ITEM_KINDS[+f.kind.value];
      const qcol = ['#9d9d9d', '#ffffff', '#1eff00', '#0070dd', '#a335ee', '#ff8000'][+f.quality.value] || '#fff';
      const slot = { 13: 'One-Hand', 17: 'Two-Hand', 15: 'Ranged', 14: 'Off Hand', 5: 'Chest', 16: 'Back', 11: 'Finger', 2: 'Neck', 1: 'Head', 10: 'Hands', 8: 'Feet', 7: 'Legs' }[k?.[3]];
      const type = k ? k[0].replace(/^(One|Two)-hand /, '').replace(/ \(.*\)$/, '').replace(/^(Cloth|Leather|Mail|Plate) chest$/, (m, x) => x) : '';
      const lines = [`<div style="color:${qcol}">${esc(f.name.value || 'Item name')}</div>`];
      const bind = { 1: 'Binds when picked up', 2: 'Binds when equipped', 4: 'Quest Item' }[+f.bonding.value];
      if (bind) lines.push(`<div>${bind}</div>`);
      if (slot) lines.push(`<div class="two-col"><span>${slot}</span><span>${esc(['Ring', 'Neck', 'Cloak'].includes(k[0]) ? '' : type.charAt(0).toUpperCase() + type.slice(1))}</span></div>`);
      const lo = +f.dmg_min.value, hi = +f.dmg_max.value, sp = +f.delay.value;
      if (hi) { lines.push(`<div class="two-col"><span>${Math.round(lo)} - ${Math.round(hi)} Damage</span><span>Speed ${(sp || 2).toFixed(2)}</span></div>`); lines.push(`<div>(${((lo + hi) / 2 / (sp || 2)).toFixed(1)} damage per second)</div>`); }
      if (+f.armor.value) lines.push(`<div>${+f.armor.value} Armor</div>`);
      for (const d of $$('[data-stat]')) { const kind = $('select', d).value, v = +$('input', d).value; if (kind !== '' && v) lines.push(`<div>${v > 0 ? '+' : ''}${v} ${esc(STATS.find((x) => String(x[0]) === kind)?.[1] || '')}</div>`); }
      if (+f.durability.value) lines.push(`<div>Durability ${+f.durability.value} / ${+f.durability.value}</div>`);
      if (+f.required_level.value > 1) lines.push(`<div>Requires Level ${+f.required_level.value}</div>`);
      if (f.description.value) lines.push(`<div style="color:#ffd100">"${esc(f.description.value)}"</div>`);
      const sell = Math.floor(readCoin('buy') / 4);
      if (sell) { const [g, si, c] = coins(sell); lines.push(`<div class="money">Sell Price: ${g ? g + '<i class="g"></i> ' : ''}${si ? si + '<i class="s"></i> ' : ''}${c ? c + '<i class="c"></i>' : ''}</div>`); }
      $('#wowtip').innerHTML = lines.join('');
      if (!f.icon.files[0]) {
        const d = parseInt(f.display.value, 10), k = d ? thKey({ item_display: d }) : null;
        const set = () => { const pic = k && TH.pics.get(k); $('#tip-icon').style.backgroundImage = pic ? `url(${pic})` : ''; };
        if (k && !TH.pics.has(k)) { TH.want.add(k); pumpThumbs().then(set); } else set();
      }
    };
    $('#wiz-f').addEventListener('input', tip); $('#wiz-f').addEventListener('change', tip); tip();
    $('#wiz-f').elements.icon.addEventListener('change', () => {
      const file = $('#wiz-f').elements.icon.files[0];
      $('#tip-icon').style.backgroundImage = file ? `url(${URL.createObjectURL(file)})` : '';
    });
    $('#wiz-bh')?.addEventListener('click', () => { BH.entry = id; show('behaviour'); });
    const disp = $('#wiz-f').elements.display;
    disp.addEventListener('input', () => {
      clearTimeout(W.dt); const q = disp.value.trim(); if (!q || /^\d+$/.test(q)) return;
      W.dt = setTimeout(async () => { try {
        const h = await api('data_search', { table: 'ItemDisplayInfo', q, limit: 36 }, true);
        pickGrid($('#wiz-ilookgrid'), [{ items: h.map((x) => ({ value: String(x.ID), label: x.label, title: `${x.label} ${x.more || ''} (${x.ID})`, th: { item_display: x.ID }, glyph: '⚔' })) }], null,
          (v) => { disp.value = v; disp.dispatchEvent(new Event('change', { bubbles: true })); }, `Nothing for "${q}".`);
      } catch { /* */ } }, 250);
    });
    $('#wiz-save').addEventListener('click', () => safe(async () => {
      const f = $('#wiz-f').elements;
      if (!$('#wiz-f').reportValidity()) return;
      if (f.icon.files[0]) {
        const b64 = await new Promise((ok) => { const fr = new FileReader(); fr.onload = () => ok(String(fr.result).split(',')[1]); fr.readAsDataURL(f.icon.files[0]); });
        const disp = await api('wiz_item_icon', { dir: S.project.dir, base: parseInt(f.display.value, 10) || 0, name: f.name.value, png: b64 });
        f.display.value = disp; f.icon.value = '';
        toast(`Your icon is display ${disp}.`);
      }
      const k = ITEM_KINDS[+f.kind.value] || [null, it.class, it.subclass, it.inventory_type];
      const stats = $$('[data-stat]').map((d) => ({ kind: +$('select', d).value, value: +$('input', d).value || 0, set: $('select', d).value !== '' })).filter((x) => x.set && x.value).map(({ kind, value }) => ({ kind, value }));
      const s = { id: id || null, name: f.name.value, quality: +f.quality.value, class: k[1], subclass: k[2], inventory_type: k[3],
        display: parseInt(f.display.value, 10) || 0, item_level: +f.item_level.value || 0, required_level: +f.required_level.value || 0,
        armor: +f.armor.value || 0, durability: +f.durability.value || 0, dmg_min: +f.dmg_min.value || 0, dmg_max: +f.dmg_max.value || 0,
        delay: Math.round((+f.delay.value || 0) * 1000), bonding: +f.bonding.value, stack: +f.stack.value || 1, stats,
        buy_price: readCoin('buy'), description: f.description.value };
      wizSave('wiz_item', { spec: s });
    }));
  } else {
    box.innerHTML = `<div class="data-head"><h2>${id ? 'Vendor ' + id : 'New vendor list'}</h2><button class="btn small gold" id="wiz-save">Save list</button></div>
      <form class="form mt-s" id="wiz-f"><label>Vendor (creature)<input name="creature" list="wiz-creatures" required value="${id || ''}"></label>
      <fieldset><legend>Sells (count 0 = unlimited)</legend>${pairRows('sells', spec || [], 12, 'wiz-items', 'item')}</fieldset></form><ul class="findings mt-s" id="wiz-notes"></ul>`;
    $('#wiz-save').addEventListener('click', () => {
      if (!$('#wiz-f').reportValidity()) return;
      wizSave('wiz_vendor', { creature: parseInt($('#wiz-f').elements.creature.value, 10), items: readPairs('sells') });
    });
  }
}
async function wizSave(cmd, args) {
  await safe(async () => {
    const r = await api(cmd, { dir: S.project.dir, ...args });
    W.sel = r.id;
    await loadContent(true);
    await openWiz(r.id);
    $('#wiz-notes').innerHTML = r.notes.map((n) => `<li class="warning">${esc(n)}</li>`).join('');
    toast(`Saved (${r.id}).`);
  });
}

// ---- world --------------------------------------------------------------------------------------
// One terrain tile from the creator's game, drawn as shaded relief; click to place a doodad.
const WV = { info: null, tile: null, sel: null };
async function loadWorld() {
  if (!S.project) return;
  await safe(async () => {
    WV.info = await api('world_list', { dir: S.project.dir });
    await loadPortals();
    const own = WV.info.own_maps || [];
    $('#w-lsform').hidden = !own.length;
    $('#ls-map').innerHTML = own.map((m) => `<option>${esc(m)}</option>`).join('');
    if ($('#w-map').options.length !== WV.info.maps.length) {
      const keepMap = $('#w-map').value;
      $('#w-map').innerHTML = WV.info.maps.map((m) => `<option value="${esc(m.name)}">${m.id} · ${esc(m.name)}</option>`).join('');
      if (keepMap) $('#w-map').value = keepMap;
    }
    const keep = $('#w-model').value;
    $('#w-model').innerHTML = (WV.info.doodads.length ? `<optgroup label="Your doodads">${WV.info.doodads.map((d) => `<option value="${esc(d.model)}">${esc(d.name)}</option>`).join('')}</optgroup>` : '')
      + (WV.found ? `<optgroup label="The game's models">${WV.found.map((m) => `<option value="${esc(m)}">${esc(m.split('\\').pop())}</option>`).join('')}</optgroup>` : '');
    if (keep) setSelect($('#w-model'), keep);
    renderModelGrid();
    renderWorldList();
    if (WV.tile && WV.forProject === S.project.dir) drawTile();
    // first visit for this project: the tile you were last on, or one the pack has changed, or
    // Northshire, so the screen is never empty
    else if (S.status?.game) {
      WV.forProject = S.project.dir; WV.tile = null;
      let at = null;
      try { at = JSON.parse(localStorage.getItem('forge.tile.' + S.project.dir) || 'null'); } catch {}
      at = at || WV.info.start;
      if (at && WV.info.maps.some((m) => m.name === at.map)) { $('#w-map').value = at.map; $('#w-a').value = at.a; $('#w-b').value = at.b; }
      await showTile().catch(() => {});
    }
  });
}
$('#w-newform').addEventListener('submit', (e) => {
  e.preventDefault();
  const [lo, hi] = $('#nm-levels').value.split(/[-–]/).map((x) => parseInt(x, 10));
  safe(async () => {
    await checkpoint('new map');
    const r = await api('world_new_map', { dir: S.project.dir, spec: {
      name: $('#nm-name').value.trim(), kind: $('#nm-kind').value, size: +$('#nm-size').value,
      height: +$('#nm-height').value || 0, texture: $('#nm-tex').value.trim(), min_level: lo || 1, max_level: hi || lo || 60 } });
    WV.info = await api('world_list', { dir: S.project.dir });
    await loadWorld();
    $('#w-map').value = r.map; $('#w-a').value = r.tiles[0][0]; $('#w-b').value = r.tiles[0][1];
    $('#w-newmap').open = false;
    await showTile();
    toast(`${r.map} (map ${r.id}) is ready. In game, GMs reach it with ${r.tele}.`);
  });
});
$('#w-lsform').addEventListener('submit', (e) => {
  e.preventDefault();
  const f = $('#ls-file').files[0];
  if (!f) { toast('Choose a picture first.', true); return; }
  safe(async () => {
    const b64 = await new Promise((ok, bad) => { const r = new FileReader(); r.onload = () => ok(String(r.result).split(',')[1]); r.onerror = bad; r.readAsDataURL(f); });
    await checkpoint('loading screen');
    const r = await api('world_loading_screen', { dir: S.project.dir, map: $('#ls-map').value, image: b64 });
    toast(`Loading screen set (${r.art}).`);
  });
});
function renderWorldList() {
  const map = $('#w-map').value;
  const list = (WV.info?.placements || {})[map] || [];
  $('#w-count').textContent = list.length;
  $('#w-list').innerHTML = list.length ? list.map((p) => `<li data-uid="${p.uid}"><span>${esc(p.model.replace(/^model:/, '').split('\\').pop())}</span><span class="n">${p.x.toFixed(0)}, ${p.y.toFixed(0)} <button class="del" data-rm="${p.uid}" title="Remove">×</button></span></li>`).join('')
    : '<li class="meta">Nothing placed yet.</li>';
  $$('#w-list [data-rm]').forEach((b) => b.addEventListener('click', (e) => {
    e.stopPropagation();
    safe(async () => { await checkpoint('remove'); await api('world_remove', { dir: S.project.dir, map, uid: +b.dataset.rm }); await loadWorld(); if (WV.tile) await showTile(); });
  }));
  $$('#w-list li[data-uid]').forEach((li) => li.addEventListener('click', () => {
    const p = list.find((x) => x.uid === +li.dataset.uid);
    safe(async () => { const r = await api('world_locate', { where: `${0} ${p.x} ${p.y} ${p.z}` }); $('#w-a').value = r.a; $('#w-b').value = r.b; await showTile(); });
  }));
}
$('#w-search').addEventListener('submit', (e) => {
  e.preventDefault();
  safe(async () => {
    const q = $('#w-q').value;
    const hits = (await api('assets_search', { q: `${q} .m2`, limit: 200 })).concat(await api('assets_search', { q: `${q} .wmo`, limit: 200 }));
    // doodads (.m2) and buildings (a .wmo root, not its _000 groups)
    WV.found = hits.filter((h) => /^world\\/i.test(h) && (/\.m2$/i.test(h) || (/\.wmo$/i.test(h) && !/_\d{3}\.wmo$/i.test(h))));
    await loadWorld();
    if (WV.found.length) { setSelect($('#w-model'), WV.found[0]); renderModelGrid(); }
    toast(`${WV.found.length} model(s) found.`);
  });
});
$('#w-go').addEventListener('submit', (e) => {
  e.preventDefault();
  safe(async () => {
    if ($('#w-gps').value.trim()) {
      const r = await api('world_locate', { where: $('#w-gps').value });
      if (r.map) $('#w-map').value = r.map;
      $('#w-a').value = r.a; $('#w-b').value = r.b;
      WV.mark = r.pos;
    }
    await showTile();
    $('#w-tilebox').open = false;
  });
});
async function showTile() {
  WV.tile = await api('world_tile', { dir: S.project.dir, map: $('#w-map').value, a: +$('#w-a').value, b: +$('#w-b').value });
  WV.forProject = S.project.dir;
  try { localStorage.setItem('forge.tile.' + S.project.dir, JSON.stringify({ map: WV.tile.map, a: WV.tile.tile[0], b: WV.tile.tile[1] })); } catch {}
  $('#w-tilename').innerHTML = `<b>${esc(WV.tile.map)} ${WV.tile.tile[0]}_${WV.tile.tile[1]}</b> <span class="meta">${WV.tile.stock.length} of the game's props${WV.tile.reshaped ? ' · edited' : ''}</span>`;
  if (!WV.tileShownOnce) { WV.tileShownOnce = true; $('#w-tilebox').open = false; setTimeout(() => startEditorTour(), 900); }
  renderWorldList();
  renderSpawns();
  fillTextures();
  renderModelGrid(); renderInUse(); hiddenLine(); safeQuiet(renderNav);
  $('#w-shadowline').hidden = !WV.tile.shadows; $('#w-shadown').textContent = `${WV.tile.shadows} chunk${WV.tile.shadows === 1 ? ' has' : 's have'} baked shadows.`; if ($('#w-swap').open) renderSwapGrid(); if (WV.tool === 'area') renderAreas();
  await loadMini();
  drawTile();
}
// the ground's look: the real textures (True View), plain relief, or the minimap bake
const look = () => $('#w-look').value;
WV.lookCache = new Map();
async function loadMini() {
  WV.mini = null;
  if (!WV.tile || look() === 'relief') return;
  const key = `${look()}|${WV.tile.map}_${WV.tile.tile}|${WV.tileRev || 0}`;
  let im = WV.lookCache.get(key);
  if (!im) {
    const args = { dir: S.project.dir, map: WV.tile.map, a: WV.tile.tile[0], b: WV.tile.tile[1] };
    let r;
    try { r = look() === 'real' ? await api('world_trueground', { ...args, size: 1024, shade: true }) : await api('world_minimap', args); }
    catch (e) { toast(e.message, true); return; }
    im = new Image();
    await new Promise((ok) => { im.onload = ok; im.onerror = ok; im.src = 'data:image/png;base64,' + r.png; });
    if (WV.lookCache.size > 12) WV.lookCache.clear();
    WV.lookCache.set(key, im);
  }
  WV.mini = im;
}
$('#w-look').addEventListener('change', () => safe(async () => { try { localStorage.setItem('forge.look', look()); } catch {} await loadMini(); if (WV.tile) { WV.t3tile = null; drawTile(); } }));
try { const l = localStorage.getItem('forge.look'); if (l) $('#w-look').value = l; } catch {}
// the 2D map is drawn at twice its on-screen size (sharper ground, and a sharper drape in 3D)
const MAPW = 645;
function drawTile() {
  const t = WV.tile, cv = $('#w-canvas'), g = cv.getContext('2d');
  g.setTransform(cv.width / MAPW, 0, 0, cv.width / MAPW, 0, 0);
  const c = { width: MAPW, height: MAPW };
  const N = 129, H = t.heights;
  let lo = Infinity, hi = -Infinity;
  for (const h of H) { if (h < lo) lo = h; if (h > hi) hi = h; }
  const img = g.createImageData(N, N);
  for (let i = 0; i < N; i++) for (let j = 0; j < N; j++) {
    const h = H[i * N + j];
    const dx = (H[i * N + Math.min(N - 1, j + 1)] - H[i * N + Math.max(0, j - 1)]);
    const dz = (H[Math.min(N - 1, i + 1) * N + j] - H[Math.max(0, i - 1) * N + j]);
    const shade = Math.max(0.35, Math.min(1.25, 0.85 - (dx + dz) * 0.05));
    const k = hi > lo ? (h - lo) / (hi - lo) : 0.5;
    // low: deep green, high: dry stone
    const r = (60 + 120 * k) * shade, gg = (85 + 85 * k) * shade, b = (45 + 70 * k) * shade;
    const o = (i * N + j) * 4;
    img.data[o] = r; img.data[o + 1] = gg; img.data[o + 2] = b; img.data[o + 3] = 255;
  }
  const off = document.createElement('canvas'); off.width = off.height = N; off.getContext('2d').putImageData(img, 0, 0);
  g.imageSmoothingEnabled = true;
  g.drawImage(WV.mini || off, 0, 0, c.width, c.height);
  const s = c.width / t.size;
  if (WV.tool === 'paint' && t.ground && !WV.mini) {
    // the ground's textures: one colour per texture, over the relief
    const pal = (i) => `hsla(${(i * 137) % 360}, 55%, 55%, .45)`;
    const cell = c.width / 128;
    for (let i = 0; i < 128; i++) for (let j = 0; j < 128; j++) {
      const k = t.ground[i * 128 + j]; if (!k) continue;
      g.fillStyle = pal(k); g.fillRect(j * cell, i * cell, cell + .5, cell + .5);
    }
  }
  if (WV.tool === 'impass' && t.impass) {
    const cell = c.width / 16;
    g.save(); g.strokeStyle = 'rgba(224,80,60,.85)'; g.fillStyle = 'rgba(224,80,60,.22)'; g.lineWidth = 1;
    for (let k = 0; k < 256; k++) {
      if (!t.impass[k]) continue;
      const x = (k % 16) * cell, y = Math.floor(k / 16) * cell;
      g.fillRect(x, y, cell, cell);
      g.beginPath(); for (let d = -cell; d < cell; d += 6) { g.moveTo(x + Math.max(0, d), y + Math.max(0, -d)); g.lineTo(x + Math.min(cell, d + cell), y + Math.min(cell, cell - d)); } g.stroke();
    }
    g.restore();
  }
  if (WV.tool === 'area' && t.areas) {
    const cell = c.width / 16;
    g.font = '11px sans-serif'; g.textAlign = 'center';
    for (let k = 0; k < 256; k++) {
      const a = t.areas[k]; g.fillStyle = `hsla(${(a * 97) % 360}, 60%, 50%, .28)`;
      g.fillRect((k % 16) * cell, Math.floor(k / 16) * cell, cell, cell);
      g.fillStyle = 'rgba(0,0,0,.65)'; g.fillText(a, (k % 16 + .5) * cell, (Math.floor(k / 16) + .55) * cell);
    }
  }
  if (t.water) {
    const cell = c.width / 128;
    const col = { water: 'rgba(40,110,200,.55)', ocean: 'rgba(20,70,160,.6)', magma: 'rgba(230,90,20,.7)', slime: 'rgba(90,170,40,.6)' };
    for (let k = 0; k < 256; k++) {
      const w = t.water[k]; if (!w) continue;
      g.fillStyle = col[w.kind] || col.water;
      for (let i = 0; i < 64; i++) if (w.tiles[i] === '1') g.fillRect(((k % 16) * 8 + i % 8) * cell, (Math.floor(k / 16) * 8 + Math.floor(i / 8)) * cell, cell + .5, cell + .5);
    }
  }
  if (t.holes) {
    const cell = c.width / 64; g.fillStyle = 'rgba(8,6,4,.85)';
    for (let k = 0; k < 256; k++) {
      const hm = t.holes[k]; if (!hm) continue;
      for (let bit = 0; bit < 16; bit++) if (hm & (1 << bit)) g.fillRect(((k % 16) * 4 + bit % 4) * cell, (Math.floor(k / 16) * 4 + Math.floor(bit / 4)) * cell, cell, cell);
    }
  }
  g.strokeStyle = 'rgba(0,0,0,.18)'; g.lineWidth = 1;
  for (let k = 1; k < 16; k++) { const p = k * c.width / 16; g.beginPath(); g.moveTo(p, 0); g.lineTo(p, c.height); g.moveTo(0, p); g.lineTo(c.width, p); g.stroke(); }
  // file x runs across (u), file z down (v)
  // buildings: their footprint boxes (the game's grey, yours gold)
  g.lineWidth = 1.5;
  // in 3D with Models on, the game's own trees and buildings stand there themselves
  const real3d = $('#w-is3d').checked && $('#w-models').checked;
  if (!real3d) for (const w of t.buildings || []) { if (w.hidden) continue; g.strokeStyle = 'rgba(20,20,20,.6)'; g.strokeRect(w.box[0] * s, w.box[1] * s, (w.box[2] - w.box[0]) * s, (w.box[3] - w.box[1]) * s); }
  for (const m of t.mine) if (m.box) { g.strokeStyle = '#e2b65a'; g.fillStyle = 'rgba(226,182,90,.15)'; g.fillRect(m.box[0] * s, m.box[1] * s, (m.box[2] - m.box[0]) * s, (m.box[3] - m.box[1]) * s); g.strokeRect(m.box[0] * s, m.box[1] * s, (m.box[2] - m.box[0]) * s, (m.box[3] - m.box[1]) * s); }
  g.fillStyle = 'rgba(20,20,20,.55)';
  if (!real3d) for (const d of t.stock) { if (d.hidden) continue; g.beginPath(); g.arc(d.u * s, d.v * s, 2, 0, 7); g.fill(); }
  for (const m of t.mine) {
    g.fillStyle = '#e2b65a'; g.strokeStyle = '#1a1408'; g.lineWidth = 1.5;
    g.beginPath(); g.arc(m.u * s, m.v * s, 5, 0, 7); g.fill(); g.stroke();
  }
  // spawns: creatures (red, pointing where they face), objects (blue)
  for (const x of t.spawns || []) {
    const cx = x.u * s, cy = x.v * s;
    if (x.table === 'creature') {
      // facing 0 = north (up on the map), turning counter-clockwise
      const a = -x.o - Math.PI / 2;
      g.fillStyle = '#e06650'; g.strokeStyle = '#1a0a06'; g.lineWidth = 1;
      g.beginPath(); g.moveTo(cx + Math.cos(a) * 7, cy + Math.sin(a) * 7); g.lineTo(cx + Math.cos(a + 2.5) * 5, cy + Math.sin(a + 2.5) * 5); g.lineTo(cx + Math.cos(a - 2.5) * 5, cy + Math.sin(a - 2.5) * 5); g.closePath(); g.fill(); g.stroke();
      if (x.wander > 0) { g.strokeStyle = 'rgba(224,102,80,.5)'; g.beginPath(); g.arc(cx, cy, x.wander * s, 0, 7); g.stroke(); }
    } else {
      g.fillStyle = '#6aa8e8'; g.strokeStyle = '#06101a'; g.lineWidth = 1; g.fillRect(cx - 4, cy - 4, 8, 8); g.strokeRect(cx - 4, cy - 4, 8, 8);
    }
  }
  drawPaths(g, s);
  drawKit(g, s);
  drawHighlight(g, s);
  // portals: the entrance's circle (purple), the arrival (green)
  for (const pt of t.portals || []) {
    const entry = pt.end === 'from';
    g.strokeStyle = entry ? '#b48cff' : '#7fd38a'; g.fillStyle = entry ? 'rgba(180,140,255,.25)' : 'rgba(127,211,138,.25)'; g.lineWidth = 2;
    g.beginPath(); g.arc(pt.u * s, pt.v * s, Math.max(5, (entry ? pt.radius : 2) * s), 0, 7); g.fill(); g.stroke();
    g.fillStyle = '#e8e0d0'; g.font = '11px sans-serif'; g.textAlign = 'left';
    g.fillText(entry ? `→ ${pt.other}` : `← ${pt.other}`, pt.u * s + 9, pt.v * s - 6);
  }
  if (WV.portalFrom && WV.portalFrom.map === t.map) {
    const u = (17066.666666 - WV.portalFrom.y) - t.tile[0] * t.size, v = (17066.666666 - WV.portalFrom.x) - t.tile[1] * t.size;
    g.strokeStyle = '#b48cff'; g.setLineDash([4, 3]); g.lineWidth = 2; g.beginPath(); g.arc(u * s, v * s, Math.max(5, (+$('#pt-radius').value || 5) * s), 0, 7); g.stroke(); g.setLineDash([]);
  }
  if (WV.mark) {
    const u = (17066.666666 - WV.mark.y) - t.tile[0] * t.size, v = (17066.666666 - WV.mark.x) - t.tile[1] * t.size;
    if (u >= 0 && v >= 0 && u < t.size && v < t.size) { g.strokeStyle = '#8ab4e8'; g.lineWidth = 2; g.beginPath(); g.arc(u * s, v * s, 9, 0, 7); g.stroke(); }
  }  sync3d();
}
// a pointer on the map: a mouse event on the 2D canvas, or { u, v } picked on the 3D ground
function canvasToWorld(e) {
  const c = $('#w-canvas'), r = c.getBoundingClientRect(), t = WV.tile;
  const u = 'u' in e ? e.u : (e.clientX - r.left) / r.width * t.size, v = 'u' in e ? e.v : (e.clientY - r.top) / r.height * t.size;
  const N = 129, i = Math.round(v / t.size * 128), j = Math.round(u / t.size * 128);
  return { x: t.origin.x - v, y: t.origin.y - u, h: t.heights[i * N + j] };
}
function showHover(e) {
  if (!WV.tile) return;
  const w = canvasToWorld(e);
  WV.hover = w;
  $('#w-hover').textContent = `X ${w.x.toFixed(1)}  Y ${w.y.toFixed(1)}  ground ${w.h.toFixed(1)}`;
}
$('#w-canvas').addEventListener('mousemove', showHover);
// tools: place, or the terrain brushes (hold to keep shaping)
WV.tool = 'place';
const TOOLHINT = {
  place: 'Pick a prop or building below (yours, or search the game\'s), then click the map. Alt-click one of the game\'s own to make it yours or hide it.',
  scatter: 'Add one or more props below, then click: they scatter in the brush circle. Shift-click clears.',
  prefab: 'Stamp a saved group with a click, or make one from a box of your props and spawns.',
  spawn: 'Pick a creature or object, click the map. Press Path on a spawn to draw its patrol.',
  portal: 'Click the entrance, then go to where players arrive and click there.',
  raise: 'Hold the mouse to raise the ground in the brush circle.', lower: 'Hold the mouse to lower the ground.',
  smooth: 'Hold to soften bumps and cliffs.', flatten: 'Hold to flatten to the height where you first press.',
  vsel: 'Brush over the ground to pick its points (Shift-brush drops them), then raise, lower, level or smooth just those.',
  road: 'Click points along the road, then Lay road.',
  ramp: 'Click the foot of the ramp, then its top; Lay ramp.', clip: 'Click two corners to copy a block of ground; then click to paste it. R turns, M mirrors.',
  script: 'Pick or write a script, then click the map: it runs where you click. Every run is one undo step.',
  measure: 'Click two points: how far apart, how much higher, how steep. Click again to start over.', stamp: 'Pick a stamp, then click to press it into the ground.',
  paint: 'Pick a ground texture, then paint with the brush.', water: 'Click to pour water with its surface at that height (a chunk\'s water is level across it); shift-click drains.',
  hole: 'Click to cut an 8-yard hole in the ground (cave mouths, cellars); shift-click fills it.', area: 'Paint which zone the ground belongs to.',
  impass: 'Paint the chunks players can\'t walk onto (red); shift-click makes them passable again.',
  light: 'Pick a light: its sky, sun and fog through the day. Click a colour strip to set the colour at that hour; slide ☀ to see it.',
};
$('#w-toolhint').textContent = TOOLHINT.place;
$$('#w-tools button').forEach((b) => b.addEventListener('click', () => {
  WV.tool = b.dataset.t;
  $$('#w-tools button').forEach((x) => x.classList.toggle('on', x === b));
  $('#w-brush').hidden = ['place', 'hole', 'portal', 'spawn', 'road', 'prefab', 'light', 'ramp', 'stamp', 'clip', 'script', 'measure'].includes(WV.tool);
  $('#w-scatterbox').hidden = WV.tool !== 'scatter';
  $('#w-placebox').hidden = !['place', 'scatter'].includes(WV.tool);
  $('#w-toolhint').textContent = TOOLHINT[WV.tool] || '';
  $('#w-roadbox').hidden = WV.tool !== 'road';
  $('#w-rampbox').hidden = WV.tool !== 'ramp';
  $('#w-vselbox').hidden = WV.tool !== 'vsel';
  $('#w-wmodebox').hidden = WV.tool !== 'water';
  $('#w-stampbox').hidden = WV.tool !== 'stamp';
  $('#w-clipbox').hidden = WV.tool !== 'clip';
  $('#w-measbox').hidden = WV.tool !== 'measure';
  if (WV.tool !== 'place' && WV.game) gameDone();
  hiddenLine();
  $('#w-scriptbox').hidden = WV.tool !== 'script';
  if (WV.tool === 'script') safe(loadScripts);
  if (WV.tool === 'clip') safe(clipInfo);
  if (WV.tool === 'stamp') renderStamps();
  $('#w-prefabbox').hidden = WV.tool !== 'prefab';
  if (WV.tool === 'prefab') loadPrefabs();
  if (WV.tool === 'road') fillRoadTex();
  if (WV.tool !== 'prefab') WV.capture = null;
  $('#w-paintbox').hidden = WV.tool !== 'paint';
  $('#w-areabox').hidden = WV.tool !== 'area';
  $('#w-lightbox').hidden = WV.tool !== 'light';
  if (WV.tool === 'light') safe(renderLights); else WV.t3?.setLights([], null, WV.tile?.origin || { x: 0, y: 0 });
  if (WV.tool === 'area') renderAreas();
  $('#w-waterbox').hidden = WV.tool !== 'water';
  $('#w-portalbox').hidden = WV.tool !== 'portal';
  $('#w-spawnbox').hidden = WV.tool !== 'spawn';
  if (WV.tool === 'spawn') loadSpawnables();
  if (WV.tool !== 'portal') WV.portalFrom = null;
  if (WV.tool !== 'spawn' && WV.path) endPath();
  portalStep();
  $('#w-toolname').textContent = b.textContent.trim();
  $('#w-strengthrow').hidden = ['water', 'area', 'impass', 'vsel', 'hole'].includes(WV.tool);
  $('#w-resetline').hidden = !['raise', 'lower', 'smooth', 'flatten', 'vsel'].includes(WV.tool);
  // the Points tool only picks: no falloff or hardness
  for (const el of [$('#w-falloff'), $('[data-for="w-inner"]')?.closest('.slider')]) if (el) el.hidden = WV.tool === 'vsel';
  if (WV.tool === 'water') waterMode();
  if (WV.tile) drawTile();
}));
function fillTextures() {
  const have = new Set();
  const opts = [];
  for (const t of (WV.tile?.textures || []).concat(WV.texFound || [])) {
    if (have.has(t.toLowerCase())) continue;
    have.add(t.toLowerCase()); opts.push(t);
  }
  const keep = $('#w-tex').value;
  $('#w-tex').innerHTML = opts.map((t) => `<option value="${esc(t)}">${esc(t.split('\\').pop())}</option>`).join('');
  if (keep && have.has(keep.toLowerCase())) $('#w-tex').value = keep;
  renderTexGrid();
}
$('#w-texsearch').addEventListener('submit', (e) => {
  e.preventDefault();
  safe(async () => {
    const hits = await api('assets_search', { q: `tileset ${$('#w-texq').value} blp`, limit: 300 });
    WV.texFound = hits.filter((h) => /^tileset\\/i.test(h) && !/_s\.blp$/i.test(h));
    fillTextures();
    if (WV.texFound.length) { $('#w-tex').value = WV.texFound[0]; renderTexGrid(); }
    toast(`${WV.texFound.length} texture(s).`);
  });
});
$('#w-reset').addEventListener('click', (e) => {
  e.preventDefault();
  if (!WV.tile || !armed('reset-tile', 'Click again to undo all shaping on this tile.')) return;
  safe(async () => { await checkpoint('reset tile'); await api('world_reset_tile', { dir: S.project.dir, map: WV.tile.map, a: WV.tile.tile[0], b: WV.tile.tile[1] }); await showTile(); });
});
let strokeTimer = 0, strokeBusy = false, lastEv = null;
const holeClicks = []; // hole clicks land one at a time; none are dropped while the tile reloads
async function stroke() {
  if (strokeBusy || !lastEv || !WV.tile) return;
  strokeBusy = true;
  if (WV.cp) { await WV.cp; WV.cp = null; }
  const ev = WV.tool === 'hole' && holeClicks.length ? holeClicks.shift() : lastEv;
  const w = canvasToWorld(ev);
  try {
    const common = { dir: S.project.dir, map: WV.tile.map, x: w.x, y: w.y, radius: +$('#w-radius').value || 20, strength: +$('#w-strength').value || 1, shape: { falloff: WV.falloff, inner: +$('#w-inner').value || 0, spray: WV.tool === 'paint' ? (+$('#w-spray').value || 0) / 100 : 0, seed: WV.seed || 1 } };
    if (WV.tool === 'vsel') { vselBrush(w, common.radius, ev.shiftKey); return; }
    if (WV.tool === 'paint' && $('#w-swapbrush').checked && WV.swapFrom) {
      await api('world_swap', { dir: S.project.dir, map: WV.tile.map, a: WV.tile.tile[0], b: WV.tile.tile[1], from: WV.swapFrom, to: $('#w-tex').value, x: w.x, y: w.y, radius: common.radius });
    } else if (WV.tool === 'paint') {
      const notes = await api('world_paint', { ...common, strength: Math.min(1, common.strength), texture: $('#w-tex').value });
      if (notes.length) toast(notes[0]);
    } else if (WV.tool === 'area') await api('world_area', { ...common, area: +$('#w-area').value || 0 });
    else if (WV.tool === 'impass') await api('world_impass', { ...common, on: !ev.shiftKey });
    else if (WV.tool === 'water' && WV.wmode === 'crop') await api('world_water_crop', { dir: S.project.dir, map: WV.tile.map, x: w.x, y: w.y, radius: common.radius });
    else if (WV.tool === 'water') {
      if (!ev.shiftKey && $('#w-level').value === '') $('#w-level').value = (Math.round((w.h + 2) * 2) / 2).toFixed(1);
      await api('world_water', { ...common, level: +$('#w-level').value, kind: $('#w-wkind').value, erase: ev.shiftKey });
    }
    else if (WV.tool === 'hole') { await api('world_hole', { ...common, hole: !ev.shiftKey }); }
    else {
      const touched = await api('world_sculpt', { ...common, brush: WV.tool });
      // a stroke near an edge changes the next tile too: show it again
      for (const [a, b] of touched || []) if (a !== WV.tile.tile[0] || b !== WV.tile.tile[1]) WV.nb.delete(`${WV.tile.map}_${a}_${b}`);
    }
    WV.tile = await api('world_tile', { dir: S.project.dir, map: WV.tile.map, a: WV.tile.tile[0], b: WV.tile.tile[1] });
    WV.tileRev = (WV.tileRev || 0) + 1;
    await loadMini();
    drawTile(); drawBrush(lastEv); redrape3d();
  } catch (err) { toast(err.message, true); clearInterval(strokeTimer); holeClicks.length = 0; }
  strokeBusy = false;
  if (WV.tool === 'hole' && holeClicks.length) stroke();
}
// ---- undo: a step before every edit, Ctrl+Z (or the button) goes back one
const checkpoint = (what) => api('world_checkpoint', { dir: S.project.dir, what }).catch(() => {});
async function undoWorld(steps = 1, redo = false) {
  WV.nb?.clear();
  if (!S.project) return;
  await safe(async () => {
    const r = await api(redo ? 'world_redo' : 'world_undo', { dir: S.project.dir, steps });
    WV.info = await api('world_list', { dir: S.project.dir });
    await loadWorld();
    if (WV.tile) await showTile().catch(() => { WV.tile = null; });
    toast(redo ? `Redid ${r.redone}.` : `Undid ${r.undone || 'the last edit'} (${r.left} more step${r.left === 1 ? '' : 's'}${r.redo ? ', Ctrl+Y redoes' : ''}).`);
    if (!$('#w-hist').hidden) renderHistory();
  });
}

document.addEventListener('keydown', (e) => {
  if ((e.ctrlKey || e.metaKey) && !$('#view-world').hidden && !isTyping()) {
    const k = e.key.toLowerCase();
    if (k === 'z' && !e.shiftKey) { e.preventDefault(); undoWorld(); }
    else if (k === 'y' || (k === 'z' && e.shiftKey)) { e.preventDefault(); undoWorld(1, true); }
  }
});
function onDown(e) {
  WV.seed = Math.floor(Math.random() * 1e9);
  if (!WV.tile || ['place', 'portal', 'spawn', 'scatter', 'road', 'prefab', 'light', 'ramp', 'stamp', 'clip', 'script', 'measure'].includes(WV.tool)) return;
  if (WV.tool === 'water' && WV.wmode === 'angled') return;
  if (WV.tool === 'paint' && !$('#w-tex').value) { toast('Pick a texture (the tile\'s own, or search).', true); return; }
  if (WV.tool !== 'vsel') WV.cp = checkpoint(WV.tool); // one undo step per stroke (or hole click)
  lastEv = e;
  if (WV.tool === 'hole') { holeClicks.push(e); stroke(); return; }
  stroke(); clearInterval(strokeTimer); strokeTimer = setInterval(stroke, 120);
}
$('#w-canvas').addEventListener('mousedown', onDown);
window.addEventListener('mouseup', () => clearInterval(strokeTimer));
function drawBrush(e) {
  if (['place', 'hole', 'road', 'prefab', 'portal', 'spawn', 'light', 'ramp', 'stamp', 'clip', 'script', 'measure'].includes(WV.tool) || (WV.tool === 'water' && WV.wmode === 'angled') || !WV.tile) return;
  const cv = $('#w-canvas'), r = cv.getBoundingClientRect(), g = cv.getContext('2d');
  g.setTransform(cv.width / MAPW, 0, 0, cv.width / MAPW, 0, 0);
  const c = { width: MAPW, height: MAPW };
  const s = c.width / WV.tile.size, rad = (+$('#w-radius').value || 20) * s;
  const x = 'u' in e ? e.u * s : (e.clientX - r.left) / r.width * c.width, y = 'u' in e ? e.v * s : (e.clientY - r.top) / r.height * c.height;
  g.strokeStyle = WV.tool === 'lower' ? '#8ab4e8' : '#e2b65a'; g.lineWidth = 1.5;
  g.beginPath(); g.arc(x, y, rad, 0, 7); g.stroke();
  if (WV.t3 && $('#w-is3d').checked) WV.t3.setBrush({ u: x / s, v: y / s, r: rad / s, color: WV.tool === 'lower' ? 0x8ab4e8 : 0xf3d189 });
}
function onMove(e) { lastEv = e; if (WV.tool !== 'place' && WV.tile && !strokeBusy) { drawTile(); drawBrush(e); redrape3d(); } }
$('#w-canvas').addEventListener('mousemove', onMove);
$('#w-canvas').addEventListener('click', onClick);
function portalStep() {
  const f = WV.portalFrom;
  $('#pt-step').innerHTML = f
    ? `Entrance: ${esc(f.map)} at ${f.x.toFixed(0)}, ${f.y.toFixed(0)}. Now go to where players arrive (any map or tile: Show tile, or New map) and click there. <a href="#" id="pt-cancel">Start again</a>`
    : 'Click where the portal stands: walking into it takes a player through.';
  $('#pt-cancel')?.addEventListener('click', (e) => { e.preventDefault(); WV.portalFrom = null; portalStep(); if (WV.tile) drawTile(); });
}
async function loadPortals() {
  WV.portals = await api('world_portals', { dir: S.project.dir });
  $('#pt-count').textContent = WV.portals.length;
  $('#pt-list').innerHTML = WV.portals.length ? WV.portals.map((p) => `<li><span>${esc(p.name)}</span><span class="n">${esc(p.from.map)} → ${esc(p.to.map)} <button class="del" data-pt="${p.id}" title="Remove">×</button></span></li>`).join('')
    : '<li class="meta">No portals yet. The Portal tool links two places.</li>';
  $$('#pt-list [data-pt]').forEach((b) => b.addEventListener('click', () => safe(async () => {
    await checkpoint('remove portal');
    await api('world_portal_remove', { dir: S.project.dir, id: +b.dataset.pt });
    await loadPortals(); await showTile();
  })));
}
function portalClick(e) {
  const w = canvasToWorld(e);
  if (!WV.portalFrom) {
    WV.portalFrom = { map: WV.tile.map, x: w.x, y: w.y, z: w.h };
    portalStep(); drawTile();
    return;
  }
  safe(async () => {
    await checkpoint('portal');
    const r = await api('world_portal_add', { dir: S.project.dir, spec: {
      name: $('#pt-name').value, radius: +$('#pt-radius').value || 5, min_level: +$('#pt-level').value || 0,
      from: WV.portalFrom, to: { map: WV.tile.map, x: w.x, y: w.y, z: w.h + 0.5, o: 0 } } });
    WV.portalFrom = null; portalStep();
    await loadPortals(); await showTile();
    toast(`${r.name}: the portal is in (area trigger ${r.id}).`);
  });
}
async function loadSpawnables() {
  WV.spawnables = await api('world_spawnables', { dir: S.project.dir });
  fillSpawnables();
}
function fillSpawnables() {
  const t = $('#sp-table').value, list = (WV.spawnables || {})[t === 'creature' ? 'creatures' : 'objects'] || [];
  $('#sp-mine').innerHTML = '<option value="">—</option>' + list.map((x) => `<option value="${x.entry}">${esc(x.name || '#' + x.entry)}</option>`).join('');
  $('#sp-wanderl').hidden = t !== 'creature';
  renderSpawnGrid();
}
function renderSpawnGrid() {
  const t = $('#sp-table').value, list = (WV.spawnables || {})[t === 'creature' ? 'creatures' : 'objects'] || [];
  pickGrid($('#sp-grid'), [{ items: list.map((x) => ({ value: String(x.entry), label: x.name || '#' + x.entry, title: `${x.name} (${x.entry})`,
    th: x.display ? (t === 'creature' ? { display: x.display } : { object: x.display }) : null, glyph: t === 'creature' ? '☻' : '▣' })) }],
  $('#sp-mine').value, (v) => { $('#sp-mine').value = v; $('#sp-entry').value = ''; },
  t === 'creature' ? 'No creatures of your own yet: make one on the Content screen (or type a game entry above).' : 'No objects of your own yet (type a game entry above).');
}
$('#sp-table').addEventListener('change', fillSpawnables);
function renderSpawns() {
  const sp = WV.tile?.spawns || [];
  $('#sp-count').textContent = sp.length;
  $('#sp-list').innerHTML = sp.length ? sp.map((x) => `<li><span>${x.table === 'creature' ? '◆' : '■'} ${esc(x.name)}${x.path?.length ? ` <span class="meta">walks ${x.path.length} points</span>` : ''}</span><span class="n">${x.u.toFixed(0)}, ${x.v.toFixed(0)} ${x.table === 'creature' ? `<button class="btn small" data-path="${x.guid}" title="Draw a patrol path for this spawn">Path</button>` : ''} <button class="del" data-sp="${x.table}:${x.guid}" title="Remove">×</button></span></li>`).join('')
    : '<li class="meta">Nothing spawned here. The Spawn tool puts creatures and objects on the map.</li>';
  $$('#sp-list [data-path]').forEach((b) => b.addEventListener('click', () => startPath(+b.dataset.path)));
  $$('#sp-list [data-sp]').forEach((b) => b.addEventListener('click', () => safe(async () => {
    const [table, guid] = b.dataset.sp.split(':');
    await checkpoint('remove spawn');
    await api('world_spawn_remove', { dir: S.project.dir, table, guid: +guid });
    await showTile();
  })));
}
// patrol paths: click points in order; saved as the spawn's route (it walks them, then back to the first)
WV.path = null;
function startPath(guid) {
  const sp = (WV.tile?.spawns || []).find((x) => x.guid === guid); if (!sp) return;
  WV.path = { guid, points: (sp.path || []).map((p) => ({ x: p.x, y: p.y, z: p.z, wait: p.wait, u: p.u, v: p.v })) };
  if (!WV.path.points.length) { const w = { x: WV.tile.origin.x - sp.v, y: WV.tile.origin.y - sp.u }; const h = canvasToWorld({ u: sp.u, v: sp.v }).h; WV.path.points.push({ x: w.x, y: w.y, z: h + 0.1, wait: 0, u: sp.u, v: sp.v }); }
  $('#pa-who').textContent = sp.name; $('#w-pathbox').hidden = false; drawTile();
}
function endPath() { WV.path = null; $('#w-pathbox').hidden = true; drawTile(); }
$('#pa-cancel').addEventListener('click', endPath);
$('#pa-undo').addEventListener('click', () => { if (WV.path?.points.length > 1) { WV.path.points.pop(); drawTile(); } });
async function savePath(points) {
  await checkpoint('path');
  await api('path_save', { dir: S.project.dir, path: { guid: WV.path.guid, points: points.map(({ x, y, z, wait }) => ({ x, y, z, wait })) } });
  endPath(); await showTile();
}
$('#pa-save').addEventListener('click', () => safe(async () => {
  if (WV.path.points.length < 2) { toast('Click at least one more point on the map.', true); return; }
  await savePath(WV.path.points); toast('Path saved: it walks it in the game (Test & Play).');
}));
$('#pa-clear').addEventListener('click', () => safe(() => savePath([])));
function pathClick(e) {
  const w = canvasToWorld(e), u = 'u' in e ? e.u : null;
  const t = WV.tile;
  WV.path.points.push({ x: w.x, y: w.y, z: w.h + 0.1, wait: +$('#pa-wait').value || 0, u: t.origin.y - w.y, v: t.origin.x - w.x });
  drawTile();
}
function drawPaths(g, s) {
  const lines = (pts, colour, dash) => {
    if (!pts.length) return;
    g.strokeStyle = colour; g.lineWidth = 2; g.setLineDash(dash);
    g.beginPath(); pts.forEach((p, i) => (i ? g.lineTo(p.u * s, p.v * s) : g.moveTo(p.u * s, p.v * s)));
    if (pts.length > 2) g.lineTo(pts[0].u * s, pts[0].v * s);
    g.stroke(); g.setLineDash([]);
    pts.forEach((p, i) => { g.fillStyle = colour; g.beginPath(); g.arc(p.u * s, p.v * s, i ? 3 : 4.5, 0, 7); g.fill(); if (p.wait > 0) { g.fillStyle = '#e8e0d0'; g.font = '10px sans-serif'; g.fillText(p.wait + 's', p.u * s + 5, p.v * s - 5); } });
  };
  for (const x of WV.tile.spawns || []) if (x.path?.length && WV.path?.guid !== x.guid) lines(x.path, 'rgba(224,102,80,.75)', [5, 4]);
  if (WV.path) lines(WV.path.points, '#ffd27a', []);
}
function spawnClick(e) {
  const entry = +$('#sp-mine').value || +$('#sp-entry').value;
  if (!entry) { toast('Pick one of yours, or type a game entry.', true); return; }
  const w = canvasToWorld(e);
  safe(async () => {
    await checkpoint('spawn');
    const r = await api('world_spawn', { dir: S.project.dir, map: WV.tile.map, table: $('#sp-table').value, entry,
      x: w.x, y: w.y, z: w.h + 0.1, o: ((+$('#sp-face').value || 0) % 360) * Math.PI / 180,
      respawn: +$('#sp-respawn').value || 0, wander: +$('#sp-wander').value || 0 });
    await showTile();
    toast(`Spawned (guid ${r.guid}).`);
  });
}
function onClick(e) {
  if (WV.tile && WV.tool === 'portal') { portalClick(e); return; }
  if (WV.tile && WV.tool === 'spawn' && WV.path) { pathClick(e); return; }
  if (WV.tile && WV.tool === 'scatter') { scatterClick(e); return; }
  if (WV.tile && WV.tool === 'road') { roadClick(e); return; }
  if (WV.tile && WV.tool === 'ramp') { rampClick(e); return; }
  if (WV.tile && WV.tool === 'water' && WV.wmode === 'angled') { angledClick(e); return; }
  if (WV.tile && WV.tool === 'stamp') { stampClick(e); return; }
  if (WV.tile && WV.tool === 'clip') { clipClick(e); return; }
  if (WV.tile && WV.tool === 'measure') { measureClick(e); return; }
  if (WV.tile && WV.tool === 'script') { runScript(canvasToWorld(e)); return; }
  if (WV.tile && WV.tool === 'prefab') { prefabClick(e); return; }
  if (WV.tile && WV.tool === 'spawn') { spawnClick(e); return; }
  if (!WV.tile || WV.tool !== 'place') return;
  // Alt-click: one of the game's own doodads or buildings
  if (e.altKey && !('u' in e)) {
    const r = $('#w-canvas').getBoundingClientRect(), t = WV.tile, k = t.size / r.width;
    const u = (e.clientX - r.left) * k, v = (e.clientY - r.top) * k;
    const near = (t.stock || []).filter((d) => !d.hidden).map((d) => [d, Math.hypot(d.u - u, d.v - v)]).sort((a, b) => a[1] - b[1])[0];
    const inBox = (t.buildings || []).find((b) => !b.hidden && u >= b.box[0] && u <= b.box[2] && v >= b.box[1] && v <= b.box[3]);
    const hit = near && near[1] < 9 * k ? near[0] : inBox;
    if (hit) pickGameObject({ uid: hit.uid, path: hit.path }); else toast('None of the game\'s own just there.', true);
    return;
  }
  // on the 2D map, a click on one of your own (gold) picks it up
  if (!('u' in e)) {
    const r = $('#w-canvas').getBoundingClientRect(), t = WV.tile, k = t.size / r.width;
    const u = (e.clientX - r.left) * k, v = (e.clientY - r.top) * k;
    const hit = (t.mine || []).filter((m) => !m.box).map((m) => [m, Math.hypot(m.u - u, m.v - v)]).sort((a, b) => a[1] - b[1])[0];
    if (Date.now() - (WV.boxed || 0) < 300) return;
    if (hit && hit[1] < 9 * k) { selectPlacement(hit[0].placement.uid, e.shiftKey); return; }
    if (WV.sels.length) { selectPlacement(null); return; }
  }
  const model = $('#w-model').value;
  if (!model) { toast('Pick a doodad first: port one on the Models screen (kind: doodad), or search the game\'s models.', true); return; }
  const w = canvasToWorld(e);
  safe(async () => {
    await checkpoint('place');
    await api('world_place', { dir: S.project.dir, map: WV.tile.map, ground: true,
      placement: { model, x: w.x, y: w.y, z: 0, turn: +$('#w-turn').value || 0, scale: +$('#w-scale').value || 1, uid: 0 } });
    WV.info = await api('world_list', { dir: S.project.dir });
    await showTile();
  });
}
// the 3D view: the same map draped on the ground, the same tools picked on it
WV.t3 = null; WV.t3tile = null;
async function want3d() {
  const on = $('#w-is3d').checked;
  $('#w-3d').hidden = !on; $('#w-canvas').hidden = on; $('#w-3dhint').hidden = !on;
  // a quick fade into the other view, not a jump
  const into = on ? $('#w-3d') : $('#w-canvas');
  into.classList.remove('fadein'); void into.offsetWidth; into.classList.add('fadein');
  $('#w-v2d').classList.toggle('on', !on); $('#w-v3d').classList.toggle('on', on);
  if (!on && WV.t3?.isWalking()) stopWalk();
  try { localStorage.setItem('forge.3d', on ? '1' : '0'); } catch {}
  if (on && !WV.t3) {
    if (!window.forgeTerrain) await new Promise((res) => window.addEventListener('forge-terrain-ready', res, { once: true }));
    WV.t3 = window.forgeTerrain.createTerrain($('#w-3d'));
    applyView(viewNow(), false);
    wireGizmo();
    WV.t3.onProgress((n, of) => loadChip(n < of ? `Models ${n} / ${of}` : null, n / of));
    WV.t3.setModels($('#w-models').checked,
      (path) => api('world_mesh', { dir: S.project.dir, path }, true),
      (path) => api('world_texture', { dir: S.project.dir, path, max: 512 }, true).then((r) => 'data:image/png;base64,' + r.png));
  }
  if (on && WV.tile) { WV.t3tile = null; drawTile(); }
}
$('#w-is3d').addEventListener('change', () => safe(want3d));
$('#w-models').addEventListener('change', () => { WV.t3?.setModels($('#w-models').checked); if (WV.tile) drawTile(); });
function sync3d() {
  if (!WV.t3 || !$('#w-is3d').checked || !WV.tile) return;
  if (WV.t3tile !== WV.tile) { WV.t3.update(WV.tile, $('#w-canvas')); WV.t3tile = WV.tile; splatSoon(); neighboursSoon(); safeQuiet(applySky); } else WV.t3.redrape();
  WV.t3.setSplatMode(splatWanted());
  if (splatWanted() && !WV.t3.hasSplat()) splatSoon();
  if (['place', 'hole', 'road', 'prefab', 'portal', 'spawn', 'light', 'ramp', 'stamp', 'clip', 'script', 'measure'].includes(WV.tool)) WV.t3.setBrush(null);
}
// in 3D the "Real" ground is painted by its own textures, like the game (the Area tool and the
// other looks keep the 2D map draped, with its marks)
const splatWanted = () => $('#w-is3d').checked && look() === 'real' && !['area', 'impass', 'vsel'].includes(WV.tool);
let splatTimer = 0;
function splatSoon() { clearTimeout(splatTimer); if (splatWanted() || walking()) splatTimer = setTimeout(() => loadSplat(), 200); }
function redrape3d() { if (WV.t3 && $('#w-is3d').checked) WV.t3.redrape(); }
function pick3d(e) {
  const p = WV.t3?.pick(e);
  return p ? { u: p.u, v: p.v, shiftKey: e.shiftKey } : null;
}
// while walking, the mouse looks around: the tools wait
const walking = () => !!WV.t3?.isWalking();
$('#w-3d').addEventListener('mousedown', (e) => { if (e.button !== 0 || walking() || WV.t3?.gizmoHover()) return; const p = pick3d(e); if (p) onDown(p); });
$('#w-3d').addEventListener('mousemove', (e) => { if (walking()) return; const p = pick3d(e); if (p) { showHover(p); onMove(p); } });
$('#w-3d').addEventListener('click', (e) => {
  if (e.button !== 0 || walking()) return;
  if (WV.t3?.gizmoDragged() || WV.t3?.gizmoHover()) return;
  // Place: clicking one of your models picks it up instead of placing another
  if (WV.tool === 'place') {
    if (Date.now() - (WV.boxed || 0) < 300) return;
    if (e.altKey) { const gh = WV.t3?.pickGame(e); if (gh) pickGameObject(gh); else toast('None of the game\'s own just there.', true); return; }
    const uid = WV.t3?.pickMine(e);
    if (uid) { selectPlacement(uid, e.shiftKey); return; }
    if (WV.sels.length) { selectPlacement(null); return; }
  }
  const p = pick3d(e); if (p) onClick(p);
});

// ---- data ---------------------------------------------------------------------------------------
// The pack's rows for one table, edited as a grid; saved to data/<kind>/<Table>.toml.
const D = { overview: null, t: null, rows: [], cols: [], dirty: false, findings: [] };

// what each table is, in plain words (the real name stays under it)
const TABLE_NAMES = {
  creature_template: 'Creatures', creature: 'Creature spawns', creature_ai_scripts: 'Fight plans (Behaviour)', custom_texts: 'Lines creatures say',
  creature_movement: 'Patrol paths', creature_loot_template: 'Creature loot', creature_questrelation: 'Who gives which quest', creature_involvedrelation: 'Who takes which quest back',
  creature_equip_template: 'What creatures hold', creature_model_info: 'Creature model sizes', item_template: 'Items', item_loot_template: 'Loot inside items',
  reference_loot_template: 'Shared loot tables', quest_template: 'Quests', npc_text: 'Dialogue texts', gossip_menu: 'Dialogue pages', gossip_menu_option: 'Dialogue choices',
  npc_vendor: 'Vendor lists', npc_trainer: 'Trainer lists', gameobject_template: 'Objects', gameobject: 'Object spawns', gameobject_loot_template: 'Object loot',
  instance_template: 'Dungeons and raids', areatrigger_teleport: 'Portals (server side)', game_tele: 'Teleport spots (.tele)', game_event: 'World events',
  game_event_creature: 'Event creatures', game_event_gameobject: 'Event objects', skinning_loot_template: 'Skinning loot', pickpocketing_loot_template: 'Pickpocket loot',
  CreatureDisplayInfo: 'Creature looks', CreatureModelData: 'Creature models', ItemDisplayInfo: 'Item looks and icons', Spell: 'Spells', SpellIcon: 'Spell icons',
  Map: 'Maps', AreaTable: 'Zones and areas', AreaTrigger: 'Portals (client side)', LoadingScreens: 'Loading screens',
};
async function loadData() {
  if (!S.project) return;
  await safe(async () => {
    D.overview = await api('data_overview', { dir: S.project.dir });
    renderTables();
    if (D.t) await pickTable(D.t.kind, D.t.table, true);
    else { const f = D.overview.world.find((t) => t.table === 'creature_template' && t.rows) || D.overview.world.find((t) => t.rows) || D.overview.dbc.find((t) => t.rows); if (f) await pickTable(D.overview.world.includes(f) ? 'world' : 'dbc', f.table); }
  });
}

function renderTables() {
  for (const kind of ['world', 'dbc']) {
    $('#data-' + kind).innerHTML = [...D.overview[kind]].sort((a, b) => (!!b.rows - !!a.rows) || (TABLE_NAMES[a.table] || a.table).localeCompare(TABLE_NAMES[b.table] || b.table)).map((t) =>
      `<li data-k="${kind}" data-t="${esc(t.table)}" class="${D.t?.table === t.table ? 'on' : ''}" title="${esc(t.table)}"><span>${esc(TABLE_NAMES[t.table] || t.table)}${TABLE_NAMES[t.table] ? `<small>${esc(t.table)}</small>` : ''}</span>${t.rows ? `<span class="n">${t.rows}</span>` : ''}</li>`).join('');
  }
  $$('.tlist li').forEach((li) => li.addEventListener('click', () => {
    if (D.dirty && !confirmLeave()) return;
    pickTable(li.dataset.k, li.dataset.t);
  }));
}
function confirmLeave() { toast('This table has unsaved changes: Save them, or click the table again to drop them.', true); D.dirty = false; return false; }

function meta(kind, table) { return D.overview[kind].find((t) => t.table === table); }
// the table's columns as {name, type, count, comment, key}
function columnsOf(t) {
  if (t.kind === 'world') return t.columns.map((c) => ({ name: c.name, type: c.type, count: 1, comment: [c.sql, c.comment].filter(Boolean).join(' · '), key: t.key.includes(c.name), def: c.default }));
  return t.fields.map((f) => ({ name: f.name, type: f.type, count: f.count, comment: f.type + (f.count > 1 ? `[${f.count}]` : ''), key: f.name === 'ID' }));
}

async function pickTable(kind, table, keep) {
  const t = meta(kind, table);
  D.t = t;
  D.all = columnsOf(t);
  if (!keep || !D.dirty) {
    D.rows = await api('data_rows', { dir: S.project.dir, kind, table });
    D.dirty = false;
  }
  const used = new Set(D.all.filter((c) => c.key).map((c) => c.name));
  for (const r of D.rows) for (const k of Object.keys(r)) if (!['override', 'clone', 'comment'].includes(k)) used.add(D.all.find((c) => c.name.toLowerCase() === k.toLowerCase())?.name || k);
  D.cols = D.all.map((c) => c.name).filter((n) => used.has(n)).concat([...used].filter((n) => !D.all.some((c) => c.name === n)));
  $$('.tlist li').forEach((li) => li.classList.toggle('on', li.dataset.t === table));
  $('#data-title').textContent = table;
  $('#data-sub').innerHTML = kind === 'world'
    ? `Realm table · key ${t.key.map((k) => `<code>${esc(k)}</code>`).join(' + ') || '(none)'} · saved to <code>data/world/${esc(table)}.toml</code> → <code>server/sql/install.sql</code>`
    : `Client DBC · key <code>ID</code> · saved to <code>data/dbc/${esc(table)}.toml</code> → a delta the realm merges (a dev build merges it into your own client)`;
  $('#data-tools').hidden = $('#data-colbar').hidden = false;
  $('#data-clone-wrap').hidden = kind !== 'dbc' || !S.status?.game;   // world clones: type the stock key in the clone column
  $('#data-cols').innerHTML = D.all.map((c) => `<option value="${esc(c.name)}">${esc(c.comment)}</option>`).join('');
  $('#data-sqlbox').hidden = true;
  renderGrid();
  dataFindings(S.project.findings);
}

function cellText(v) {
  if (v === undefined || v === null) return '';
  if (Array.isArray(v)) return JSON.stringify(v);
  return String(v);
}
function parseCell(col, text) {
  if (text === '') return undefined;
  if (col.count > 1) {
    try { const a = JSON.parse(text); if (Array.isArray(a)) return a; } catch { /* fall through */ }
    return text.split(',').map((x) => parseCell({ ...col, count: 1 }, x.trim()));
  }
  if (col.type === 'int' || col.type === 'uint') { const n = Number(text); return Number.isInteger(n) ? n : text; }
  if (col.type === 'float') { const n = Number(text); return Number.isFinite(n) ? n : text; }
  return text;
}

// tables whose rows have a look: the column, and what kind of picture it is
const LOOK_COL = { creature_template: ['DisplayId1', 'display'], item_template: ['displayid', 'item_display'], gameobject_template: ['displayId', 'object'],
  CreatureDisplayInfo: ['ID', 'display'], ItemDisplayInfo: ['ID', 'item_display'] };
function rowPic(r) {
  const lc = LOOK_COL[D.t?.table]; if (!lc) return '';
  const k = Object.keys(r).find((x) => x.toLowerCase() === lc[0].toLowerCase());
  const v = +(k === undefined ? 0 : r[k]) || +(lc[0] === 'ID' ? r.clone : 0) || 0;
  return thumbHtml(v ? { [lc[1]]: v } : null, lc[1] === 'item_display' ? '⚔' : lc[1] === 'object' ? '▣' : '☻', 'sm');
}
function renderGrid() {
  const cols = D.cols.map((n) => D.all.find((c) => c.name === n) || { name: n, type: 'string', count: 1, comment: 'not a column of this table' });
  const isDbc = D.t.kind === 'dbc' || D.t.key.length === 1;   // a clone column: DBCs, and world tables with one key
  const pics = !!LOOK_COL[D.t.table];
  $('#dgrid-head').innerHTML = `<tr><th></th>${pics ? '<th>Look</th>' : ''}<th title="Change a stock row (the rollback restores it)">override</th>${isDbc ? '<th title="Copy every field from this stock ID first">clone</th>' : ''}${cols.map((c) =>
    `<th class="${c.key ? 'key' : ''}" title="${esc(c.comment)}">${esc(c.name)}${c.key ? '' : `<span class="x" data-col="${esc(c.name)}" title="Drop this column from every row">×</span>`}</th>`).join('')}</tr>`;
  $('#dgrid-body').innerHTML = D.rows.length ? D.rows.map((r, i) => {
    const get = (n) => { const k = Object.keys(r).find((x) => x.toLowerCase() === n.toLowerCase()); return k === undefined ? undefined : r[k]; };
    return `<tr data-i="${i}" class="${r.override ? 'override' : ''}"><td><button class="del" data-i="${i}" title="Remove row">×</button></td>${pics ? `<td class="pic" data-pic="${i}">${rowPic(r)}</td>` : ''}
      <td class="ov"><input type="checkbox" data-i="${i}" data-meta="override" ${r.override ? 'checked' : ''}></td>
      ${isDbc ? `<td><input data-i="${i}" data-meta="clone" value="${esc(cellText(r.clone))}" placeholder="—"></td>` : ''}
      ${cols.map((c) => `<td><input class="${c.type === 'string' || c.type === 'locstring' || c.count > 1 ? 'str' : ''}" data-i="${i}" data-col="${esc(c.name)}" value="${esc(cellText(get(c.name)))}" placeholder="${esc(c.def ?? '')}"></td>`).join('')}</tr>`;
  }).join('') : `<tr><td colspan="${cols.length + 4}" class="hint" style="padding:14px">No rows yet. <b>New row</b> takes the next ID from the pack's range${isDbc ? '; <b>Clone</b> copies a stock record' : ''}.</td></tr>`;
  $$('#dgrid-body input').forEach((inp) => inp.addEventListener('change', () => {
    const r = D.rows[+inp.dataset.i];
    if (inp.dataset.meta === 'override') { if (inp.checked) r.override = true; else delete r.override; inp.closest('tr').classList.toggle('override', inp.checked); }
    else if (inp.dataset.meta === 'clone') { const v = parseCell({ type: 'int', count: 1 }, inp.value.trim()); if (v === undefined) delete r.clone; else r.clone = v; }
    else {
      const col = cols.find((c) => c.name === inp.dataset.col);
      for (const k of Object.keys(r)) if (k.toLowerCase() === col.name.toLowerCase()) delete r[k];
      const v = parseCell(col, inp.value.trim());
      if (v !== undefined) r[col.name] = v;
    }
    const pc = $(`#dgrid-body [data-pic="${inp.dataset.i}"]`);
    if (pc) { pc.innerHTML = rowPic(r); fillThumbs(pc); }
    dirty();
  }));
  fillThumbs($('#dgrid-body'));
  $$('#dgrid-body .del').forEach((b) => b.addEventListener('click', () => { D.rows.splice(+b.dataset.i, 1); dirty(); renderGrid(); }));
  $$('#dgrid-head .x').forEach((x) => x.addEventListener('click', () => {
    const n = x.dataset.col;
    for (const r of D.rows) for (const k of Object.keys(r)) if (k.toLowerCase() === n.toLowerCase()) delete r[k];
    D.cols = D.cols.filter((c) => c !== n);
    dirty(); renderGrid();
  }));
}
function dirty() { D.dirty = true; $('#data-save').disabled = false; }

function keyCol() { return D.all.find((c) => c.key)?.name; }
async function newRow(override) {
  const r = {};
  if (override) r.override = true;
  else if (D.t.idTable) {
    const got = await api('allocate_id', { dir: S.project.dir, table: D.t.idTable, name: '' });
    r[keyCol()] = got.id;
    S.project.ids = got.lock;
  }
  D.rows.push(r);
  dirty(); renderGrid();
  $(`#dgrid-body tr[data-i="${D.rows.length - 1}"] input[data-col]`)?.focus();
}
$('#data-add').addEventListener('click', () => safe(() => newRow(false)));
$('#data-override').addEventListener('click', () => safe(() => newRow(true)));
$('#data-clone').addEventListener('click', () => safe(async () => {
  const donor = parseInt($('#data-clone-id').value, 10);
  if (!Number.isInteger(donor)) return;
  const stock = await api('data_stock', { table: D.t.table, id: donor });
  const got = await api('allocate_id', { dir: S.project.dir, table: D.t.idTable, name: `clone of ${donor}` });
  D.rows.push({ ID: got.id, clone: donor });
  dirty(); renderGrid();
  const name = stock.Name_lang || stock.ModelName || stock.TextureFilename || stock.InventoryIcon || '';
  toast(`${D.t.table} ${got.id}: a copy of ${donor}${name ? ` (${Array.isArray(name) ? name[0] : name})` : ''}. Change only the fields you want different.`);
}));
// donor search: the game's own records by name or ID
$('#data-clone-id').addEventListener('input', () => {
  clearTimeout(D.searchT);
  const q = $('#data-clone-id').value.trim();
  if (!q || /^\d+ ·/.test(q)) return;
  D.searchT = setTimeout(async () => {
    try {
      const hits = await api('data_search', { table: D.t.table, q, limit: 40 });
      $('#data-clone-list').innerHTML = hits.map((h) => `<option value="${h.ID} · ${esc(h.label)}">${esc(h.more || '')}</option>`).join('');
    } catch { /* status line shows it */ }
  }, 250);
});
$('#data-col-add').addEventListener('click', () => {
  const want = $('#data-col').value.trim();
  const c = D.all.find((x) => x.name.toLowerCase() === want.toLowerCase());
  if (!c) { toast(`${D.t.table} has no column “${want}”.`, true); return; }
  if (!D.cols.includes(c.name)) D.cols.push(c.name);
  $('#data-col').value = '';
  renderGrid();
});
$('#data-col').addEventListener('input', () => {
  const c = D.all.find((x) => x.name.toLowerCase() === $('#data-col').value.trim().toLowerCase());
  $('#data-col-help').textContent = c ? c.comment : '';
});
$('#data-col').addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); $('#data-col-add').click(); } });
$('#data-save').addEventListener('click', () => safe(async () => {
  const r = await api('data_save', { dir: S.project.dir, kind: D.t.kind, table: D.t.table, rows: D.rows });
  D.rows = r.rows; D.dirty = false;
  $('#data-save').disabled = true;
  S.project.findings = r.findings;
  renderFindings(r.findings);
  D.overview = await api('data_overview', { dir: S.project.dir });
  renderTables(); renderGrid(); dataFindings(r.findings);
  const errs = r.findings.filter((x) => x.level === 'error' && x.path.includes(D.t.table + '.toml')).length;
  toast(errs ? `Saved, with ${errs} problem(s) to fix below.` : 'Saved.', errs > 0);
}));
$('#data-sql').addEventListener('click', () => safe(async () => {
  const box = $('#data-sqlbox');
  if (!box.hidden) { box.hidden = true; return; }
  const s = await api('data_sql', { dir: S.project.dir });
  box.textContent = `${s.install}\n-- ---------------------------------------------------- rollback.sql\n${s.rollback}`;
  box.hidden = false;
}));

function dataFindings(all) {
  const file = D.t ? `data/${D.t.kind}/${D.t.table}.toml` : '';
  const mine = (all || []).filter((x) => x.path.startsWith(file) && x.code.startsWith('data.'));
  $('#data-findings').innerHTML = mine.map((x) => `<li class="${x.level}">${esc(x.message)}<span class="where">${esc(x.path)} · ${esc(x.code)}</span></li>`).join('');
  $$('#dgrid-body tr').forEach((tr) => tr.classList.toggle('bad', mine.some((x) => x.level === 'error' && x.path.endsWith(`row ${+tr.dataset.i + 1}`))));
}

// ---- code (Addon Studio) ------------------------------------------------------------------------
const C = { files: [], path: null, saved: '', lint: [], lintTimer: 0 };

async function loadCode() {
  if (!S.project) return;
  await safe(async () => { C.files = await api('code_files', { dir: S.project.dir }); renderCodeFiles(); });
  if (!C.path && C.files.length) openCode((C.files.find((f) => f.path.endsWith('.lua')) || C.files[0]).path);
  if (!C.files.length) {
    $('#code-name').textContent = 'No addons yet';
    $('#code-text').placeholder = 'An addon is a .toc (its name and file list) and .lua files (what it does).\n\n1. Name one on the left and press New addon: it comes with a /command that says hello.\n2. Press Run on the right: a pretend client loads it, and you type the /command there.\n3. Change the Lua, Save (Ctrl+S), Run again. Test puts it in your real client.';
  } else $('#code-text').placeholder = '';
}
// a new addon: its .toc and a starter .lua with a slash command, ready for the sim
$('#addon-new').addEventListener('submit', (e) => {
  e.preventDefault();
  const name = $('#addon-new-name').value.trim();
  if (!/^[A-Za-z][A-Za-z0-9_]*$/.test(name)) { toast('An addon name is letters, digits and _, starting with a letter.', true); return; }
  if (C.files.some((f) => f.path.startsWith(`addons/${name}/`))) { toast(`${name} is already here.`, true); return; }
  safe(async () => {
    const slash = name.toLowerCase();
    await api('code_write', { dir: S.project.dir, path: `addons/${name}/${name}.toc`, text: `## Interface: 11200\n## Title: ${name}\n## Notes: \n## SavedVariables: ${name}DB\n` });
    const r = await api('code_write', { dir: S.project.dir, path: `addons/${name}/${name}.lua`, text:
`-- ${name}: type /${slash} in the game (or in the sim on the right)
SLASH_${name.toUpperCase()}1 = "/${slash}"
SlashCmdList["${name.toUpperCase()}"] = function(msg)
  DEFAULT_CHAT_FRAME:AddMessage("${name}: hello, " .. UnitName("player") .. "!")
end

local f = CreateFrame("Frame")
f:RegisterEvent("VARIABLES_LOADED")
f:SetScript("OnEvent", function()
  ${name}DB = ${name}DB or {}
end)
` });
    C.files = r.files; $('#addon-new-name').value = ''; renderCodeFiles();
    toast(`Made ${name}: run it in the sim and type /${slash}.`);
    await openCode(`addons/${name}/${name}.lua`);
  });
});
function renderCodeFiles() {
  $('#code-files').innerHTML = C.files.length ? C.files.map((f) =>
    `<li data-p="${esc(f.path)}" class="${f.path === C.path ? 'on' : ''}"><span class="ic">${f.path.endsWith('.lua') ? '◆' : '·'}</span>${esc(f.path.replace(/^addons\//, ''))}</li>`).join('')
    : '<li class="meta">No addons yet: name one below and press New addon.</li>';
  $$('#code-files li[data-p]').forEach((li) => li.addEventListener('click', () => {
    if (codeDirty() && !confirmDrop()) return;
    openCode(li.dataset.p);
  }));
}
let dropArmed = false;
function confirmDrop() {
  if (dropArmed) { dropArmed = false; return true; }
  dropArmed = true; toast('Unsaved changes: Save (Ctrl+S), or click again to drop them.', true); return false;
}
function codeDirty() { return C.path && $('#code-text').value !== C.saved; }

async function openCode(path) {
  await safe(async () => {
    const r = await api('code_read', { dir: S.project.dir, path });
    C.path = path; C.saved = r.text; C.lint = r.lint;
    const t = $('#code-text');
    t.value = r.text; t.disabled = false; t.scrollTop = 0;
    $('#code-name').textContent = path;
    codeState(); renderGutter(); renderLint(); renderCodeFiles();
  });
}
function codeState() {
  const d = codeDirty();
  $('#code-save').disabled = !d;
  $('#code-state').textContent = d ? 'edited' : '';
}
function renderGutter() {
  const n = $('#code-text').value.split('\n').length;
  const bad = new Map(C.lint.map((l) => [l.line, l.kind]));
  let s = '';
  for (let i = 1; i <= n; i++) s += (bad.has(i) ? (bad.get(i) === 'syntax' ? `<b>${i}</b>` : `<i>${i}</i>`) : i) + '\n';
  $('#code-gutter').innerHTML = s;
  $('#code-gutter').scrollTop = $('#code-text').scrollTop;
}
function renderLint() {
  $('#code-lint').innerHTML = C.lint.map((l) =>
    `<li class="${l.kind === 'syntax' ? 'error' : 'warning'}" data-line="${l.line}">${esc(l.message)}<span class="where">line ${l.line} · ${l.kind === 'syntax' ? 'syntax' : 'Lua 5.0'}</span></li>`).join('')
    || (C.path?.endsWith('.lua') ? '<li class="clear">Parses, and stays inside Lua 5.0.</li>' : '');
  $$('#code-lint li[data-line]').forEach((li) => li.addEventListener('click', () => gotoLine(+li.dataset.line)));
}
function gotoLine(n) {
  const t = $('#code-text');
  const lines = t.value.split('\n');
  const start = lines.slice(0, n - 1).reduce((a, l) => a + l.length + 1, 0);
  t.focus(); t.setSelectionRange(start, start + (lines[n - 1] || '').length);
  t.scrollTop = Math.max(0, (n - 5) * 19.5);
}
$('#code-text').addEventListener('scroll', () => { $('#code-gutter').scrollTop = $('#code-text').scrollTop; });
$('#code-text').addEventListener('input', () => {
  codeState(); renderGutter();
  clearTimeout(C.lintTimer);
  C.lintTimer = setTimeout(async () => {
    if (!C.path) return;
    try { C.lint = await api('code_lint', { dir: S.project.dir, path: C.path, text: $('#code-text').value }); renderGutter(); renderLint(); } catch { /* status shows it */ }
  }, 500);
});
$('#code-text').addEventListener('keydown', (e) => {
  const t = e.target;
  if (e.key === 'Tab') {
    e.preventDefault();
    const { selectionStart: a, selectionEnd: b } = t;
    t.setRangeText('    ', a, b, 'end');
    t.dispatchEvent(new Event('input'));
  } else if (e.key === 'Enter') {
    // keep the line's indentation
    const a = t.selectionStart;
    const lineStart = t.value.lastIndexOf('\n', a - 1) + 1;
    const indent = t.value.slice(lineStart, a).match(/^\s*/)[0];
    if (indent) { e.preventDefault(); t.setRangeText('\n' + indent, a, t.selectionEnd, 'end'); t.dispatchEvent(new Event('input')); }
  }
});
document.addEventListener('keydown', (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's' && S.view === 'code') { e.preventDefault(); saveCode(); }
});
$('#code-save').addEventListener('click', () => saveCode());
async function saveCode() {
  if (!C.path || !codeDirty()) return;
  await safe(async () => {
    const text = $('#code-text').value;
    const r = await api('code_write', { dir: S.project.dir, path: C.path, text });
    C.saved = text; C.lint = r.lint; C.files = r.files;
    codeState(); renderGutter(); renderLint(); renderCodeFiles();
    toast(r.lint.some((l) => l.kind === 'syntax') ? 'Saved — it has a syntax error.' : 'Saved.', r.lint.some((l) => l.kind === 'syntax'));
  });
}
$('#code-new').addEventListener('submit', (e) => {
  e.preventDefault();
  let p = $('#code-new-path').value.trim().replace(/\\/g, '/');
  if (!p) return;
  if (!p.startsWith('addons/')) p = 'addons/' + p;
  safe(async () => {
    const name = p.split('/')[1];
    const base = p.split('/').pop();
    const text = base.toLowerCase().endsWith('.toc') ? `## Interface: 11200\n## Title: ${name}\n## Notes: \n` : base.toLowerCase().endsWith('.lua') ? `-- ${base}\n` : '';
    const r = await api('code_write', { dir: S.project.dir, path: p, text });
    C.files = r.files; $('#code-new-path').value = '';
    if (r.addedToToc) toast(`Made ${p}, and added it to ${r.addedToToc}.`);
    await openCode(p);
  });
});

// the sim
function simLog(lines, cls) {
  const box = $('#sim-log');
  for (const l of lines) {
    const d = document.createElement('div');
    if (cls) d.className = cls;
    d.textContent = l;
    box.appendChild(d);
  }
  box.scrollTop = box.scrollHeight;
}
function simShow(snap) {
  simLog(snap.chat);
  if (snap.result !== null && snap.result !== undefined) simLog(['= ' + snap.result], 'res');
  simLog(snap.errors, 'err');
  $('#sim-windows').innerHTML = snap.windows.length ? snap.windows.map((w) =>
    `<div class="sim-win"><b>${esc(w.name)}</b><div>${w.texts.slice(0, 40).map((t) => `<span class="t" title="Click it">${esc(t)}</span>`).join('') || '<span class="hint">(no text)</span>'}</div></div>`).join('')
    : '<p class="hint">None of your addons\' windows are open.</p>';
  $$('#sim-windows .t').forEach((t) => t.addEventListener('click', () => simDo('sim_click', { text: t.textContent }, `[click] ${t.textContent}`)));
  if (snap.errors.length) toast(`${snap.errors.length} Lua error(s): see the console.`, true);
}
async function simDo(cmd, args, echo) {
  if (echo) simLog([echo], 'me');
  await safe(async () => simShow(await api(cmd, args)));
}
$('#sim-form').addEventListener('submit', (e) => {
  e.preventDefault();
  safe(async () => {
    if (codeDirty()) await saveCode();
    const r = await api('sim_start', { dir: S.project.dir, class: $('#sim-class').value, level: +$('#sim-level').value });
    $('#sim-log').innerHTML = '';
    $('#sim-live').hidden = false;
    simLog([`Logged in with ${r.addons.join(', ')}.`], 'me');
    simShow(r.snap);
    $('#sim-line').focus();
  });
});
const simHistory = [];
let simHi = 0;
$('#sim-cmd').addEventListener('submit', (e) => {
  e.preventDefault();
  const line = $('#sim-line').value.trim();
  if (!line) return;
  simHistory.push(line); simHi = simHistory.length;
  $('#sim-line').value = '';
  if (line.startsWith('/')) simDo('sim_slash', { line }, '> ' + line);
  else simDo('sim_run', { code: line }, '> ' + line);
});
$('#sim-line').addEventListener('keydown', (e) => {
  if (e.key === 'ArrowUp' && simHi > 0) { simHi--; $('#sim-line').value = simHistory[simHi]; e.preventDefault(); }
  if (e.key === 'ArrowDown' && simHi < simHistory.length) { simHi++; $('#sim-line').value = simHistory[simHi] || ''; e.preventDefault(); }
});
$$('[data-tick]').forEach((b) => b.addEventListener('click', () => simDo('sim_tick', { seconds: +b.dataset.tick }, `[+${b.dataset.tick} s]`)));
$('#sim-saved').addEventListener('click', () => safe(async () => simLog([JSON.stringify(await api('sim_saved'), null, 2)], 'res')));
$('#sim-stop').addEventListener('click', () => safe(async () => { await api('sim_stop'); $('#sim-live').hidden = true; }));

// ---- test & play --------------------------------------------------------------------------------
async function loadTest() {
  if (!S.project) return;
  loadLive();
  await safe(async () => {
    const s = await api('play_status', { dir: S.project.dir });
    const li = (ok, t) => `<li class="${ok ? 'ok' : 'bad'}">${t}</li>`;
    $('#play-state').innerHTML = [
      li(!!s.gameData, s.gameData ? `Your game: <code>${esc(s.gameData)}</code> <span class="meta">untouched</span>` : 'Set your game folder on Home'),
      s.testGame ? li(s.clientIsThis, s.clientIsThis ? `Test copy: <code>${esc(s.testGame)}</code> · this pack, build <code>${esc(s.client.build_hash.slice(0, 12))}</code>` : s.client ? `Test copy has <b>${esc(s.client.name)}</b> in it` : `Test copy: <code>${esc(s.testGame)}</code> <span class="meta">made on the first install</span>`) : '',
      li(!!s.openvanilla, s.openvanilla ? `Open Vanilla: <code>${esc(s.openvanilla)}</code>` : 'Open Vanilla folder not found: set it below'),
      s.openvanilla ? li(s.soloReady, s.soloReady ? `Test realm: <code>${esc(s.solo)}</code>${s.realm ? ` · rows ${s.realm === 'installed' ? 'installed' : 'removed'} (applied when it starts)` : ''}` : 'Play Solo isn\'t set up yet: run it once from the launcher (the test realm is copied from it)') : '',
    ].join('');
    $('#play-leftovers').hidden = !s.realLeftovers;
    if (s.openvanilla) $('#ov-dir').value = s.openvanilla;
    $('#play-gm').innerHTML = s.gm.length ? s.gm.map((g) => `<tr><td><code>${esc(g.cmd)}</code></td><td>${esc(g.what)}</td></tr>`).join('')
      : '<tr><td class="hint">The pack adds no creatures, items or spells yet.</td></tr>';
    $('#play-solo').disabled = !s.soloReady || !s.testMade;
    $('#play-solo-why').innerHTML = s.soloReady && !s.testMade ? 'Build &amp; install first: it makes the test realm from your Play Solo (stop Play Solo for that).'
      : s.soloReady ? 'Forge\'s copy of Play Solo, with the pack\'s rows applied as it starts, and the test copy of your game.'
      : !s.openvanilla ? '<span class="warn">Needs your Open Vanilla folder: set it below.</span>' : '<span class="warn">Run Play Solo once from the Open Vanilla launcher to set it up.</span>';
    $('#play-install').disabled = !s.gameData;
    $('#play-install').title = s.gameData ? '' : 'Set your game folder on Home first';
    $('#spawn-entries').innerHTML = s.gm.filter((g) => g.cmd.startsWith('.npc add')).map((g) => `<option value="${g.cmd.split(' ').pop()}">${esc(g.what)}</option>`).join('');
  });
}
$('#play-install').addEventListener('click', () => safe(async () => {
  setStatus('Building and installing…');
  const r = await api('play_install', { dir: S.project.dir });
  $('#play-notes').innerHTML = [
    r.client ? `<li class="clear">Test copy of your game: <code>${esc(r.client)}</code></li>` : '<li class="info">No client files to install.</li>',
    r.realm ? `<li class="clear">Test realm: <code>${esc(r.realm)}</code>${r.server_dbc.length ? ` · server tables: ${esc(r.server_dbc.join(', '))}` : ''}</li>` : '',
    ...r.notes.map((n) => `<li class="info">${esc(n)}</li>`),
  ].join('');
  toast('Installed for testing.');
  loadTest();
}));
$('#play-remove').addEventListener('click', () => safe(async () => {
  const did = await api('play_remove', { dir: S.project.dir });
  $('#play-notes').innerHTML = did.map((n) => `<li class="clear">${esc(n)}</li>`).join('');
  loadTest();
}));
$('#play-solo').addEventListener('click', () => safe(async () => { await api('play_solo'); toast('The test realm is starting in its own window.'); }));
$('#play-cleanup').addEventListener('click', () => safe(async () => {
  const notes = await api('play_cleanup_real');
  $('#play-notes').innerHTML = notes.map((n) => `<li class="clear">${esc(n)}</li>`).join('') || '<li class="info">Nothing of Forge\'s was left there.</li>';
  loadTest();
}));
$('#spawn-form').addEventListener('submit', (e) => {
  e.preventDefault();
  safe(async () => {
    const r = await api('spawn_add', { dir: S.project.dir, entry: parseInt($('#spawn-entry').value, 10), where: $('#spawn-where').value,
      respawn: +$('#spawn-respawn').value, wander: +$('#spawn-wander').value });
    $('#spawn-done').textContent = `Spawn ${r.guid} on map ${r.pos.map} at ${r.pos.x.toFixed(1)}, ${r.pos.y.toFixed(1)}, ${r.pos.z.toFixed(1)}.`;
    $('#spawn-where').value = '';
  });
});
$('#ov-form').addEventListener('submit', (e) => { e.preventDefault(); safe(async () => { await api('set_openvanilla', { dir: $('#ov-dir').value.trim() }); loadTest(); }); });

// ---- publish ------------------------------------------------------------------------------------
async function loadPublish() {
  if (!S.project) return;
  await safe(async () => {
    const g = await api('publish_gate', { dir: S.project.dir });
    const errs = g.findings.filter((f) => f.level === 'error');
    const of = (pred) => g.findings.filter(pred);
    const step = (title, list, okText) => {
      const e = list.filter((f) => f.level === 'error');
      const w = list.filter((f) => f.level === 'warning');
      const pill = e.length ? `<span class="pill bad">${e.length} to fix</span>` : w.length ? `<span class="pill">${w.length} warning(s)</span>` : '<span class="pill ok">ok</span>';
      return `<li class="${e.length ? 'bad' : ''}"><div><b>${title}</b><div class="d">${e.concat(w).map((f) => esc(f.message)).join('<br>') || okText}</div></div>${pill}</li>`;
    };
    const m = S.project.manifest.pack;
    $('#pub-name').textContent = `${m.name} ${m.version}`;
    $('#pub-steps').innerHTML = [
      step('Contents', [], `${g.addons} addon(s), ${g.models} model(s), ${g.worldRows} realm row(s), ${g.dbcRows} client row(s)`),
      step('Checks', of((f) => !/^(publish|credits|manifest\.(license|authors)|models\.retail|files\.stock)/.test(f.code)), 'No errors.'),
      step('Licence &amp; credits', of((f) => /^(credits|publish\.credits|manifest\.(license|authors)|models\.retail)/.test(f.code)), `${esc(g.license)}, credits.toml in order.`),
      step('None of the game’s files', of((f) => /^(publish\.game|files\.stock)/.test(f.code)), 'Checked against your own game.'),
      step('Page', of((f) => f.code === 'publish.description'), 'Description set.'),
      step('Targets', [], g.realms.length ? esc(g.realms.join(', ')) : 'Any realm (set Realms on the Project page)'),
    ].join('');
    $('#pub-key').textContent = g.key;
    $('#pub-go').disabled = errs.length > 0;
  });
}
$('#pub-refresh').addEventListener('click', () => loadPublish());
$('#pub-go').addEventListener('click', () => safe(async () => {
  setStatus('Building and signing…');
  const r = await api('publish', { dir: S.project.dir });
  $('#pub-result').innerHTML = `<div class="build-card"><div class="big">${esc(r.package.split(/[\\/]/).pop())}</div>
    <dl><dt>Where</dt><dd><code>${esc(r.package)}</code></dd><dt>Size</dt><dd>${(r.bytes / 1024).toFixed(1)} KB</dd>
    <dt>Build</dt><dd><code>${esc(r.signature.build_hash.slice(0, 16))}</code></dd><dt>Signed</dt><dd><code>${esc(r.signature.public_key.slice(0, 16))}…</code></dd>
    <dt>Holds</dt><dd>${r.contents.map((c) => `<code>${esc(c)}</code>`).join(' ')}</dd></dl></div>`;
  toast('Packed and signed. Ready for review.');
}));

// ---- assets -------------------------------------------------------------------------------------
async function loadFolder(folder) {
  if (!S.status?.game) {
    $('#asset-list').innerHTML = '<li class="meta">Choose your game folder on the Home page first.</li>';
    $('#asset-path').innerHTML = '';
    return;
  }
  S.folder = folder;
  const parts = folder ? folder.split('\\') : [];
  $('#asset-path').innerHTML = ['<a data-f="">Game</a>'].concat(parts.map((p, i) => `<span>\\</span><a data-f="${esc(parts.slice(0, i + 1).join('\\'))}">${esc(p)}</a>`)).join('');
  $$('#asset-path a').forEach((a) => a.addEventListener('click', () => loadFolder(a.dataset.f)));
  await safe(async () => {
    const kids = await api('assets_children', { folder });
    renderAssetList(kids.map((k) => ({ name: k.name, folder: k.folder, path: (folder ? folder + '\\' : '') + k.name })));
  });
}
// a picture for models, buildings and textures in the list (with a project open: it reads its art too)
function assetThumb(x) {
  if (x.folder || !S.project) return '';
  const p = x.path;
  if (/\.(m2|mdx)$/i.test(p) || (/\.wmo$/i.test(p) && !/_\d{3}\.wmo$/i.test(p))) return thumbHtml({ model: p }, '◆', 'sm');
  if (/\.blp$/i.test(p)) return thumbHtml({ texture: p }, '▦', 'sm');
  return '';
}
function renderAssetList(items) {
  $('#asset-list').innerHTML = items.length ? items.slice(0, 3000).map((x) =>
    `<li class="${x.folder ? 'dir' : ''}${assetThumb(x) ? ' withth' : ''}" data-path="${esc(x.path)}" data-folder="${x.folder ? 1 : 0}">${assetThumb(x) || `<span class="ic">${x.folder ? '▸' : '·'}</span>`}<span>${esc(x.label || x.name)}</span></li>`).join('')
    : '<li class="meta">Nothing here.</li>';
  fillThumbs($('#asset-list'));
  $$('#asset-list li[data-path]').forEach((li) => li.addEventListener('click', () => {
    if (li.dataset.folder === '1') loadFolder(li.dataset.path);
    else { $$('#asset-list li.on').forEach((x) => x.classList.remove('on')); li.classList.add('on'); assetPreview(li.dataset.path); }
  }));
}
$('#asset-search').addEventListener('submit', (e) => {
  e.preventDefault();
  const q = $('#asset-q').value.trim();
  if (!q) { loadFolder(S.folder); return; }
  safe(async () => {
    const hits = await api('assets_search', { q, limit: 500 });
    $('#asset-path').innerHTML = `<a data-f="">Game</a><span> · ${hits.length}${hits.length === 500 ? '+' : ''} matches for “${esc(q)}”</span>`;
    $('#asset-path a').addEventListener('click', () => loadFolder(''));
    renderAssetList(hits.map((p) => ({ name: p, label: p, path: p, folder: false })));
  });
});
async function assetPreview(path) {
  S.selected = path;
  $('#preview-name').textContent = path;
  $('#copy-path').hidden = false;
  await safe(async () => renderPreview($('#preview'), path, await api('assets_preview', { path })));
}
$('#copy-path').addEventListener('click', () => { navigator.clipboard?.writeText(S.selected); toast('Copied.'); });

function renderPreview(box, path, pv) {
  if (pv.kind === 'image') {
    const scale = Math.max(1, Math.min(4, Math.floor(256 / Math.max(pv.width, pv.height))));
    box.innerHTML = `<div><img alt="" src="data:image/png;base64,${pv.png}" width="${pv.width * scale}" height="${pv.height * scale}"><div class="cap">${pv.width} × ${pv.height} · ${esc(pv.format)}</div></div>`;
  } else if (pv.kind === 'text') {
    box.innerHTML = `<pre>${esc(pv.text)}${pv.truncated ? '\n…' : ''}</pre>`;
  } else {
    box.innerHTML = `<div class="cap">${pv.size.toLocaleString()} bytes<br><code>${esc(pv.head)}</code></div>`;
  }
}

loadHome().then(() => show('home')).catch((e) => toast(e.message, true));


// ---- Behaviour Studio: cards (When → Do), lines, dialogue -------------------------------------
const BH = { entry: null, tab: 'cards', cards: [], dialogue: null };
const WHEN = {
  aggro: ['A fight starts', []],
  combat_timer: ['In a fight, on a timer', ['first', 'every']],
  idle_timer: ['Out of combat, on a timer', ['first', 'every']],
  health_below: ['Its health drops below', ['below', 'every']],
  mana_below: ['Its mana drops below', ['below', 'every']],
  target_health_below: ["Its target's health drops below", ['below', 'every']],
  kill: ['It kills someone', []],
  death: ['It dies', []],
  evade: ['It gives up the chase', []],
  spell_hit: ['A spell hits it', ['spell']],
  in_range: ['Its target comes within', ['max', 'every']],
  player_near: ['A player comes near (idle)', ['max', 'every']],
  spawned: ['It appears', []],
  reached_home: ["It's back home", []],
  friend_hurt: ['A friend nearby is hurt', ['deficit', 'radius', 'every']],
};
const DO = {
  say: ['Say', ['text', 'style']],
  cast: ['Cast a spell', ['spell', 'target', 'interrupt']],
  summon: ['Summon', ['entry', 'seconds']],
  phase: ['Go to phase', ['phase']],
  call_for_help: ['Call for help', ['radius']],
  flee: ['Run for help', []],
  emote: ['Emote', ['emote']],
  sound: ['Play a sound', ['sound']],
  morph: ['Change look', ['display']],
  stand: ['Stand still / move', ['still']],
  despawn: ['Disappear', ['ms']],
  quest_credit: ['Quest credit', ['entry']],
};
const FIELD = {
  first: ['First after (s)', 'range', [5, 8]], every: ['Again every (s)', 'range', [0, 0]], below: ['%', 'num', 50],
  spell: ['Spell ID', 'num', 0], max: ['Yards', 'num', 10], deficit: ['Health missing', 'num', 500], radius: ['Radius (yd)', 'num', 20],
  text: ['Line', 'text', ''], style: ['How', 'sel', 'say', ['say', 'yell', 'emote']], target: ['At', 'sel', 'victim', ['victim', 'self', 'random', 'random_player', 'invoker', 'farthest', 'second']],
  interrupt: ['Interrupt', 'bool', false], entry: ['Creature entry', 'num', 0], seconds: ['For (s, 0 = until it dies)', 'num', 0], phase: ['Phase (0–31)', 'num', 1],
  emote: ['Emote ID', 'num', 5], sound: ['Sound ID', 'num', 0], display: ['Display ID (0: back)', 'num', 0], still: ['Stand still', 'bool', true], ms: ['After (ms)', 'num', 0],
};
function fieldHtml(key, val, path) {
  const [label, kind, def, opts] = FIELD[key];
  const v = val ?? def;
  const at = `data-path="${path}" data-key="${key}"`;
  if (kind === 'range') return `<label>${label}<span class="row" style="gap:4px"><input type="number" step="0.5" ${at} data-i="0" value="${v[0]}" style="width:70px"><input type="number" step="0.5" ${at} data-i="1" value="${v[1]}" style="width:70px"></span></label>`;
  if (kind === 'sel') return `<label>${label}<select ${at}>${opts.map((o) => `<option ${o === v ? 'selected' : ''}>${o}</option>`).join('')}</select></label>`;
  if (kind === 'bool') return `<label class="check"><input type="checkbox" ${at} ${v ? 'checked' : ''}> ${label}</label>`;
  if (kind === 'text') return `<label class="grow">${label}<input ${at} value="${esc(v)}" placeholder="You dare enter my lair?"></label>`;
  return `<label>${label}<input type="number" ${at} value="${v}" style="width:90px"></label>`;
}
function defaults(spec) {
  const o = {};
  for (const k of spec) { const d = FIELD[k][2]; o[k] = Array.isArray(d) ? [...d] : d; }
  return o;
}
async function loadBehaviour() {
  if (!S.project) return;
  const o = await api('behaviour_overview', { dir: S.project.dir });
  BH.overview = o;
  $('#bh-list').innerHTML = o.creatures.length ? o.creatures.map((c) => `<li data-e="${c.entry}" class="withth ${c.entry === BH.entry ? 'on' : ''}">${thumbHtml(c.display && { display: c.display }, '☻', 'sm')}<span><b>${esc(c.name || '#' + c.entry)}</b><br><span class="meta">${c.cards} card${c.cards === 1 ? '' : 's'}${c.dialogue ? ' · dialogue' : ''}</span></span></li>`).join('')
    : '<li class="meta">No creatures of your own yet: make one on the Content screen.</li>';
  fillThumbs($('#bh-list'));
  $$('#bh-list li[data-e]').forEach((li) => li.addEventListener('click', () => safe(() => openBehaviour(+li.dataset.e))));
  if (BH.entry && !o.creatures.some((c) => c.entry === BH.entry)) BH.entry = null;
  if (!BH.entry && o.creatures.length) await openBehaviour(o.creatures[0].entry);
  else if (BH.entry && BH.shown !== BH.entry) await openBehaviour(BH.entry);
  else if (!o.creatures.length) $('#bh-panel').innerHTML = '<div class="empty"><h2>No creatures yet</h2><p class="hint">Make a creature on the Content screen first: a name and a look. Then come back here to give it a fight plan, lines and dialogue.</p><button class="btn gold" id="bh-make">Make a creature</button></div>';
  $('#bh-make')?.addEventListener('click', () => { W.want = { kind: 'creature' }; show('content'); });
}
async function openBehaviour(entry) {
  BH.entry = entry;
  $$('#bh-list li').forEach((li) => li.classList.toggle('on', +li.dataset.e === entry));
  const b = await api('behaviour_get', { dir: S.project.dir, entry });
  BH.cards = b.cards;
  BH.dialogue = await api('dialogue_get', { dir: S.project.dir, entry });
  renderBehaviour();
}
function renderBehaviour() {
  BH.shown = BH.entry;
  const c = BH.overview.creatures.find((x) => x.entry === BH.entry) || { name: '#' + BH.entry };
  $('#bh-panel').innerHTML = `
    <div class="row between"><div class="row bh-who">${thumbHtml(c.display && { display: c.display }, '☻')}<h2>${esc(c.name)} <span class="meta">${BH.entry}</span> <button class="btn small" id="bh-edit" title="Name, look, level, loot">Edit creature</button></h2></div>
      <div class="tabs" id="bh-tabs"><button data-t="cards" class="${BH.tab === 'cards' ? 'on' : ''}">Fight plan</button><button data-t="dialogue" class="${BH.tab === 'dialogue' ? 'on' : ''}">Dialogue</button></div></div>
    <div id="bh-body"></div>`;
  $$('#bh-tabs button').forEach((b) => b.addEventListener('click', () => { BH.tab = b.dataset.t; renderBehaviour(); }));
  $('#bh-edit').addEventListener('click', () => { W.want = { kind: 'creature', id: BH.entry }; show('content'); });
  fillThumbs($('#bh-panel'));
  if (BH.tab === 'cards') renderCards(); else renderDialogue();
}
function renderCards() {
  const body = $('#bh-body');
  body.innerHTML = `
    <p class="hint">Each card: <b>when</b> something happens, it <b>does</b> up to three things. Lines it says become the game's own text rows. Phases let a fight change halfway (go to phase 1 at 50% health; cards limited to phase 1 only fire after that).</p>
    <div id="bh-cards"></div>
    <div class="row mt-s savebar"><button class="btn small" id="bh-add">+ Card</button>
      <button class="btn small" data-tpl="caster">+ A caster</button><button class="btn small" data-tpl="boss">+ A boss in two phases</button><button class="btn small" data-tpl="coward">+ Runs at low health</button>
      <span class="grow"></span><button class="btn gold" id="bh-save">Save</button></div>
    <h3 class="mt">In plain words</h3><ol id="bh-plain" class="plain"></ol>`;
  const box = $('#bh-cards');
  box.innerHTML = BH.cards.map((card, i) => {
    const wk = card.when.kind, [, wspec] = WHEN[wk] || ['', []];
    return `<div class="card" data-i="${i}">
      <div class="row wrap"><label>When<select data-path="${i}.when" data-key="kind">${Object.entries(WHEN).map(([k, [l]]) => `<option value="${k}" ${k === wk ? 'selected' : ''}>${l}</option>`).join('')}</select></label>
        ${wspec.map((k) => fieldHtml(k, card.when[k], `${i}.when`)).join('')}
        <label>Only in phase<select data-path="${i}" data-key="phase"><option value="">any</option>${[...Array(8).keys()].map((n) => `<option ${card.phase === n ? 'selected' : ''}>${n}</option>`).join('')}</select></label>
        <label>Chance %<input type="number" data-path="${i}" data-key="chance" value="${card.chance ?? 100}" style="width:64px"></label>
        <button class="btn small x" data-del="${i}" title="Remove this card">✕</button></div>
      ${card.do.map((a, j) => { const [, dspec] = DO[a.kind] || ['', []]; return `<div class="row wrap do"><span class="arrow">→</span><label>Do<select data-path="${i}.do.${j}" data-key="kind">${Object.entries(DO).map(([k, [l]]) => `<option value="${k}" ${k === a.kind ? 'selected' : ''}>${l}</option>`).join('')}</select></label>${dspec.map((k) => fieldHtml(k, a[k], `${i}.do.${j}`)).join('')}<button class="btn small x" data-deldo="${i}.${j}" title="Remove">✕</button></div>`; }).join('')}
      ${card.do.length < 3 ? `<button class="btn small link" data-adddo="${i}">+ and then…</button>` : ''}
    </div>`;
  }).join('') || '<p class="meta">No cards yet: it fights the plain way (melee).</p>';
  const target = (path) => path.split('.').reduce((o, k) => o[isNaN(k) ? k : +k], BH.cards);
  $$('#bh-cards [data-path]').forEach((el) => el.addEventListener('change', () => {
    const t = target(el.dataset.path), k = el.dataset.key;
    let v = el.type === 'checkbox' ? el.checked : el.value;
    if (k === 'kind') {
      const isDo = el.dataset.path.includes('.do.');
      const spec = (isDo ? DO : WHEN)[v][1];
      for (const key of Object.keys(t)) delete t[key];
      Object.assign(t, { kind: v }, defaults(spec));
      renderCards(); return;
    }
    if (k === 'phase') v = v === '' ? null : +v;
    else if (el.dataset.i !== undefined) { t[k] = t[k] || [0, 0]; t[k][+el.dataset.i] = +v; plain(); return; }
    else if (el.type === 'number') v = +v;
    t[k] = v; plain();
  }));
  $$('#bh-cards [data-del]').forEach((b) => b.addEventListener('click', () => { BH.cards.splice(+b.dataset.del, 1); renderCards(); }));
  $$('#bh-cards [data-deldo]').forEach((b) => b.addEventListener('click', () => { const [i, j] = b.dataset.deldo.split('.').map(Number); BH.cards[i].do.splice(j, 1); if (!BH.cards[i].do.length) BH.cards[i].do.push({ kind: 'say', ...defaults(DO.say[1]) }); renderCards(); }));
  $$('#bh-cards [data-adddo]').forEach((b) => b.addEventListener('click', () => { BH.cards[+b.dataset.adddo].do.push({ kind: 'say', ...defaults(DO.say[1]) }); renderCards(); }));
  $('#bh-add').addEventListener('click', () => { BH.cards.push({ when: { kind: 'aggro' }, do: [{ kind: 'say', ...defaults(DO.say[1]) }], chance: 100, phase: null }); renderCards(); });
  $$('#bh-body [data-tpl]').forEach((b) => b.addEventListener('click', () => { BH.cards.push(...TEMPLATES[b.dataset.tpl]()); renderCards(); }));
  $('#bh-save').addEventListener('click', () => safe(async () => {
    await api('behaviour_save', { dir: S.project.dir, behaviour: { entry: BH.entry, cards: BH.cards } });
    toast('Saved: ' + BH.cards.length + ' card' + (BH.cards.length === 1 ? '' : 's') + '. Build or Test & Play to try it.');
    loadBehaviour();
  }));
  plain();
}
const TEMPLATES = {
  caster: () => [
    { when: { kind: 'aggro' }, do: [{ kind: 'stand', still: true }], chance: 100, phase: null },
    { when: { kind: 'combat_timer', first: [0, 1], every: [3.5, 4] }, do: [{ kind: 'cast', spell: 133, target: 'victim', interrupt: false }], chance: 100, phase: null },
    { when: { kind: 'mana_below', below: 15, every: [0, 0] }, do: [{ kind: 'stand', still: false }], chance: 100, phase: null },
  ],
  boss: () => [
    { when: { kind: 'aggro' }, do: [{ kind: 'say', text: 'You should not have come here!', style: 'yell' }], chance: 100, phase: null },
    { when: { kind: 'combat_timer', first: [6, 9], every: [12, 15] }, do: [{ kind: 'cast', spell: 845, target: 'victim', interrupt: false }], chance: 100, phase: 0 },
    { when: { kind: 'health_below', below: 50, every: [0, 0] }, do: [{ kind: 'say', text: 'Enough! Now you face my true power!', style: 'yell' }, { kind: 'phase', phase: 1 }], chance: 100, phase: null },
    { when: { kind: 'combat_timer', first: [3, 4], every: [8, 10] }, do: [{ kind: 'cast', spell: 116, target: 'random', interrupt: false }], chance: 100, phase: 1 },
    { when: { kind: 'death' }, do: [{ kind: 'say', text: 'This... is not... the end...', style: 'yell' }], chance: 100, phase: null },
  ],
  coward: () => [{ when: { kind: 'health_below', below: 15, every: [0, 0] }, do: [{ kind: 'say', text: '%s attempts to run away in fear!', style: 'emote' }, { kind: 'flee' }], chance: 100, phase: null }],
};
let plainTimer = 0;
function plain() {
  clearTimeout(plainTimer);
  plainTimer = setTimeout(() => safe(async () => {
    const lines = await api('behaviour_describe', { cards: BH.cards });
    const el = $('#bh-plain'); if (el) el.innerHTML = lines.map((l) => `<li>${esc(l)}</li>`).join('') || '<li class="meta">Nothing yet.</li>';
  }), 150);
}
// dialogue: pages with choices, and a preview of the game's gossip window
function renderDialogue() {
  const d = BH.dialogue;
  if (!d.pages.length) d.pages.push({ key: 'hello', text: 'Greetings, $N. What brings you here?', choices: [{ text: 'Farewell.', to: 'close' }] });
  const ends = ['close', 'vendor', 'trainer', 'innkeeper', 'banker'];
  $('#bh-body').innerHTML = `
    <p class="hint">The first page is what the creature says when a player talks to it. Each choice leads to another page, or closes the window, or opens its shop or training. <code>$N</code> is the player's name, <code>$C</code> their class, <code>$R</code> their race.</p>
    <div class="dlg">
      <div id="dl-pages"></div>
      <div class="gossip-wrap"><div class="gossip" id="dl-preview"></div><p class="hint">Preview: click the choices.</p></div>
    </div>
    <div class="row mt-s"><button class="btn small" id="dl-add">+ Page</button><span class="grow"></span><button class="btn small" id="dl-clear">Remove dialogue</button><button class="btn gold" id="dl-save">Save</button></div>`;
  $('#dl-pages').innerHTML = d.pages.map((pg, i) => `<div class="card" data-i="${i}">
      <div class="row"><label>Page<input data-k="key" value="${esc(pg.key)}" style="width:140px"></label>${i === 0 ? '<span class="meta">first page</span>' : `<button class="btn small x" data-delpage="${i}">✕</button>`}</div>
      <label>What it says<textarea data-k="text" rows="3">${esc(pg.text)}</textarea></label>
      ${pg.choices.map((ch, j) => `<div class="row wrap do"><span class="arrow">◆</span><label class="grow">Choice<input data-c="${j}" data-ck="text" value="${esc(ch.text)}"></label>
        <label>Leads to<select data-c="${j}" data-ck="to">${[...d.pages.map((p) => p.key), ...ends].map((k) => `<option ${k === ch.to ? 'selected' : ''}>${esc(k)}</option>`).join('')}</select></label>
        <button class="btn small x" data-delch="${j}">✕</button></div>`).join('')}
      <button class="btn small link" data-addch>+ choice</button></div>`).join('');
  $$('#dl-pages .card').forEach((cardEl) => {
    const pg = d.pages[+cardEl.dataset.i];
    $$('[data-k]', cardEl).forEach((el) => el.addEventListener('input', () => {
      if (el.dataset.k === 'key') { const old = pg.key; pg.key = el.value.trim(); for (const p of d.pages) for (const ch of p.choices) if (ch.to === old) ch.to = pg.key; }
      else pg.text = el.value;
      preview();
    }));
    $$('[data-ck]', cardEl).forEach((el) => el.addEventListener('change', () => { pg.choices[+el.dataset.c][el.dataset.ck] = el.value; preview(); }));
    $$('[data-ck="text"]', cardEl).forEach((el) => el.addEventListener('input', () => { pg.choices[+el.dataset.c].text = el.value; preview(); }));
    $$('[data-delch]', cardEl).forEach((b) => b.addEventListener('click', () => { pg.choices.splice(+b.dataset.delch, 1); renderDialogue(); }));
    $('[data-addch]', cardEl).addEventListener('click', () => { pg.choices.push({ text: '', to: 'close' }); renderDialogue(); });
    $('[data-delpage]', cardEl)?.addEventListener('click', () => { d.pages.splice(+cardEl.dataset.i, 1); renderDialogue(); });
  });
  $('#dl-add').addEventListener('click', () => { const key = 'page' + (d.pages.length + 1); d.pages.push({ key, text: '', choices: [{ text: 'Back.', to: d.pages[0].key }] }); renderDialogue(); });
  $('#dl-save').addEventListener('click', () => safe(async () => {
    await api('dialogue_save', { dir: S.project.dir, dialogue: d }); toast('Dialogue saved. Build or Test & Play to talk to it.'); loadBehaviour();
  }));
  $('#dl-clear').addEventListener('click', () => { if (armed('dlclear', 'Click again to clear this dialogue (Save to make it stick).')) { d.pages = []; renderDialogue(); } });
  BH.page = d.pages[0].key; preview();
}
function preview() {
  const d = BH.dialogue, pg = d.pages.find((p) => p.key === BH.page) || d.pages[0];
  if (!pg) return;
  const sub = (t) => esc(t).replace(/\$N/g, 'Aldric').replace(/\$C/g, 'Paladin').replace(/\$R/g, 'Human').replace(/\$B/g, '<br>');
  const ico = { close: '💬', vendor: '💰', trainer: '📖', innkeeper: '🍺', banker: '🏦' };
  $('#dl-preview').innerHTML = `<div class="g-text">${sub(pg.text) || '<i>(nothing yet)</i>'}</div>` + pg.choices.map((ch) => `<a data-to="${esc(ch.to)}"><span>${ico[ch.to] || '💬'}</span>${sub(ch.text) || '<i>(no text)</i>'}</a>`).join('');
  $$('#dl-preview a').forEach((a) => a.addEventListener('click', () => {
    const to = a.dataset.to;
    if (d.pages.some((p) => p.key === to)) { BH.page = to; preview(); } else toast(to === 'close' ? 'The window closes.' : `Opens the ${to} window.`);
  }));
}


// ---- World kit: scatter, roads, prefabs, heightmaps --------------------------------------------
WV.scatter = []; WV.road = []; WV.capture = null;
const localOf = (w) => ({ u: WV.tile.origin.y - w.y, v: WV.tile.origin.x - w.x });
function renderScatterModels() {
  $('#sc-models').innerHTML = WV.scatter.length ? WV.scatter.map((m, i) => `<li class="withth">${thumbHtml({ model: m }, '◆', 'sm')}<span>${esc(fileLabel(m))}</span><button class="del" data-i="${i}">×</button></li>`).join('') : '<li class="meta">None yet: pick a doodad under Place, then Add.</li>';
  fillThumbs($('#sc-models'));
  $$('#sc-models [data-i]').forEach((b) => b.addEventListener('click', () => { WV.scatter.splice(+b.dataset.i, 1); renderScatterModels(); }));
}
renderScatterModels();
$('#sc-add').addEventListener('click', () => {
  const m = $('#w-model').value;
  if (!m) { toast('Pick a doodad under Place first (yours, or search the game\'s).', true); return; }
  if (/\.wmo$/i.test(m)) { toast('Buildings are placed one by one, not scattered.', true); return; }
  if (!WV.scatter.includes(m)) WV.scatter.push(m);
  renderScatterModels();
});
function scatterClick(e) {
  const w = canvasToWorld(e), radius = +$('#w-radius').value || 20;
  safe(async () => {
    await checkpoint(e.shiftKey ? 'clear doodads' : 'scatter');
    if (e.shiftKey) { const r = await api('kit_clear', { dir: S.project.dir, map: WV.tile.map, x: w.x, y: w.y, radius }); toast(`Cleared ${r.removed}.`); }
    else {
      if (!WV.scatter.length) { toast('Add one or more models to scatter first.', true); return; }
      const r = await api('kit_scatter', { dir: S.project.dir, spec: { map: WV.tile.map, x: w.x, y: w.y, radius, models: WV.scatter,
        count: +$('#sc-count').value || 10, spacing: +$('#sc-spacing').value || 4, size: [+$('#sc-min').value || 1, +$('#sc-max').value || 1], max_slope: +$('#sc-slope').value || 30, seed: Date.now() % 100000 } });
      toast(r.placed ? `Scattered ${r.placed}.` : 'Nothing fitted: try fewer, closer together, or a gentler slope limit.', !r.placed);
    }
    WV.info = await api('world_list', { dir: S.project.dir });
    await showTile();
  });
}
function fillRoadTex() {
  const keep = $('#rd-tex').value;
  $('#rd-tex').innerHTML = '<option value="">(don\'t paint)</option>' + $$('#w-tex option').map((o) => `<option value="${esc(o.value)}">${esc(o.textContent)}</option>`).join('');
  if (keep) $('#rd-tex').value = keep;
  else { const dirt = $$('#rd-tex option').find((o) => /dirt|road|path/i.test(o.value)); if (dirt) $('#rd-tex').value = dirt.value; }
  $('#rd-tex').dispatchEvent(new Event('change'));
}
function roadCount() { $('#rd-count').textContent = WV.road.length ? `${WV.road.length} point${WV.road.length === 1 ? '' : 's'}.` : ''; }
function roadClick(e) { const w = canvasToWorld(e); WV.road.push({ x: w.x, y: w.y }); roadCount(); drawTile(); }
$('#rd-clear').addEventListener('click', () => { WV.road = []; roadCount(); if (WV.tile) drawTile(); });
$('#rd-go').addEventListener('click', () => safe(async () => {
  if (WV.road.length < 2) { toast('Click two points or more along the road.', true); return; }
  await checkpoint('road');
  const r = await api('kit_road', { dir: S.project.dir, spec: { map: WV.tile.map, points: WV.road.map((p) => [p.x, p.y]), width: +$('#rd-width').value || 6, texture: $('#rd-tex').value, smooth: $('#rd-smooth').checked } });
  WV.road = []; roadCount(); toast(`Road laid across ${r.tiles.length} tile${r.tiles.length === 1 ? '' : 's'}.`);
  WV.tileRev = (WV.tileRev || 0) + 1;
  await showTile();
}));
// Points: pick the ground's points with the brush, then move just those
WV.vsel = new Set(); WV.vselFor = null;
const N129 = 129;
function vselCount() { $('#vs-count').textContent = WV.vsel.size ? `${WV.vsel.size} point${WV.vsel.size === 1 ? '' : 's'} picked.` : 'No points picked.'; }
function vselBrush(w, radius, drop) {
  const t = WV.tile; if (WV.vselFor !== t.map + t.tile) { WV.vsel.clear(); WV.vselFor = t.map + t.tile; }
  const u = t.origin.y - w.y, v = t.origin.x - w.x, step = t.size / 128, r = radius / step;
  const ci = v / step, cj = u / step;
  for (let i = Math.max(0, Math.floor(ci - r)); i <= Math.min(128, Math.ceil(ci + r)); i++)
    for (let j = Math.max(0, Math.floor(cj - r)); j <= Math.min(128, Math.ceil(cj + r)); j++)
      if (Math.hypot(i - ci, j - cj) <= r) { if (drop) WV.vsel.delete(i * N129 + j); else WV.vsel.add(i * N129 + j); }
  vselCount(); drawTile(); redrape3d();
}
function drawVsel(g, s) {
  if (WV.tool !== 'vsel' || !WV.vsel.size || WV.vselFor !== WV.tile.map + WV.tile.tile) return;
  const step = WV.tile.size / 128 * s;
  g.fillStyle = 'rgba(255,210,122,.75)';
  for (const k of WV.vsel) { const i = Math.floor(k / N129), j = k % N129; g.fillRect(j * step - 1.5, i * step - 1.5, 3, 3); }
}
// the picked points' new heights → a field over the tile (points not picked are left alone)
async function vselApply(what, fn) {
  const t = WV.tile; if (!t || !WV.vsel.size) { toast('Brush over the ground to pick points first.', true); return; }
  const H = t.heights, HALF = 32 * 1600 / 3, step = t.size / 128;
  const values = new Array(N129 * N129).fill(null);
  const want = fn([...WV.vsel].map((k) => [k, H[k]]));
  for (const [k, h] of want) values[k] = h;
  // the soft edge: points around the picked ones take part of the nearest picked point's change
  const r = Math.max(0, +$('#vs-soft').value || 0) / step;
  if (r > 0) {
    const best = new Map(), R = Math.ceil(r);
    for (const [k, h] of want) {
      const i = Math.floor(k / N129), j = k % N129, d0 = h - H[k];
      for (let a = Math.max(0, i - R); a <= Math.min(128, i + R); a++) for (let b = Math.max(0, j - R); b <= Math.min(128, j + R); b++) {
        const kk = a * N129 + b; if (WV.vsel.has(kk)) continue;
        const d = Math.hypot(a - i, b - j); if (d > r) continue;
        const cur = best.get(kk); if (!cur || d < cur[0]) best.set(kk, [d, d0]);
      }
    }
    for (const [kk, [d, d0]] of best) { const t = 1 - d / r, e = t * t * (3 - 2 * t); values[kk] = H[kk] + d0 * e; }
  }
  // the grid runs along file x (columns, u) and file z (rows, v) from the tile's corner
  const fx = HALF - t.origin.y, fz = HALF - t.origin.x;
  await checkpoint('points ' + what);
  await api('kit_field', { dir: S.project.dir, spec: { map: t.map, fx, fz, step, w: N129, h: N129, values, blend: 1 } });
  WV.tileRev = (WV.tileRev || 0) + 1; await showTile();
}
const by = () => +$('#vs-by').value || 0;
$('#vs-up').addEventListener('click', () => safe(() => vselApply('raise', (l) => l.map(([k, h]) => [k, h + by()]))));
$('#vs-down').addEventListener('click', () => safe(() => vselApply('lower', (l) => l.map(([k, h]) => [k, h - by()]))));
$('#vs-level').addEventListener('click', () => safe(() => vselApply('level', (l) => { const m = l.reduce((a, x) => a + x[1], 0) / l.length; return l.map(([k]) => [k, m]); })));
$('#vs-smooth').addEventListener('click', () => safe(() => vselApply('smooth', (l) => {
  const H = WV.tile.heights;
  return l.map(([k, h]) => { const i = Math.floor(k / N129), j = k % N129; let s = 0, n = 0; for (let di = -1; di <= 1; di++) for (let dj = -1; dj <= 1; dj++) { const a = i + di, b = j + dj; if (a >= 0 && b >= 0 && a <= 128 && b <= 128) { s += H[a * N129 + b]; n++; } } return [k, h * 0.4 + (s / n) * 0.6]; });
})));
$('#vs-tilt').addEventListener('click', () => safe(() => vselApply('plane', (l) => {
  // least squares: h = a + b·i + c·j
  let n = 0, si = 0, sj = 0, sh = 0, sii = 0, sjj = 0, sij = 0, sih = 0, sjh = 0;
  for (const [k, h] of l) { const i = Math.floor(k / N129), j = k % N129; n++; si += i; sj += j; sh += h; sii += i * i; sjj += j * j; sij += i * j; sih += i * h; sjh += j * h; }
  const M = [[n, si, sj], [si, sii, sij], [sj, sij, sjj]], r = [sh, sih, sjh];
  const det = (m) => m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
  const D = det(M); if (Math.abs(D) < 1e-9) return l.map(([k]) => [k, sh / n]);
  const col = (c) => M.map((row, q) => row.map((x, p) => (p === c ? r[q] : x)));
  const [a, b, c] = [det(col(0)) / D, det(col(1)) / D, det(col(2)) / D];
  return l.map(([k]) => [k, a + b * Math.floor(k / N129) + c * (k % N129)]);
})));
$('#vs-clear').addEventListener('click', () => { WV.vsel.clear(); vselCount(); if (WV.tile) { drawTile(); redrape3d(); } });

// ramps: two points, a straight slope between them
WV.ramp = [];
function rampCount() { $('#rp-count').textContent = WV.ramp.length === 1 ? 'Now click its top.' : WV.ramp.length === 2 ? 'Ready.' : ''; }
function rampClick(e) { const w = canvasToWorld(e); if (WV.ramp.length >= 2) WV.ramp = []; WV.ramp.push({ x: w.x, y: w.y }); rampCount(); drawTile(); }
$('#rp-clear').addEventListener('click', () => { WV.ramp = []; rampCount(); if (WV.tile) drawTile(); });
$('#rp-go').addEventListener('click', () => safe(async () => {
  if (WV.ramp.length < 2) { toast('Click where the ramp starts, then where it ends.', true); return; }
  const num = (id) => ($(id).value === '' ? null : +$(id).value);
  await checkpoint('ramp');
  const [a, b] = WV.ramp;
  const r = await api('kit_ramp', { dir: S.project.dir, spec: { map: WV.tile.map, from: [a.x, a.y], to: [b.x, b.y], from_z: num('#rp-from'), to_z: num('#rp-to'), width: +$('#rp-width').value || 10 } });
  WV.ramp = []; rampCount(); toast(`Ramp laid across ${r.length} tile${r.length === 1 ? '' : 's'}.`);
  WV.tileRev = (WV.tileRev || 0) + 1;
  await showTile();
}));
// water modes: level (the brush), angled (two points, a sloping strip), crop (to the ground)
WV.wmode = 'level'; WV.wpts = [];
function waterMode() {
  $$('#w-wmode button').forEach((b) => b.classList.toggle('on', b.dataset.m === WV.wmode));
  const on = WV.tool === 'water';
  $('#w-wangled').hidden = !on || WV.wmode !== 'angled';
  $('#w-waterbox').hidden = !on || WV.wmode === 'crop';
  $('#w-level').closest('label').hidden = WV.wmode !== 'level';
  $('#w-brush').hidden = !on ? $('#w-brush').hidden : WV.wmode === 'angled';
  if (on) $('#w-toolhint').textContent = { level: TOOLHINT.water, angled: 'Click where the water starts, then where it ends; Pour.', crop: 'Brush over water to take it away wherever the ground stands above it.' }[WV.wmode];
  if (WV.tile) drawTile();
}
$('#w-wmode').addEventListener('click', (e) => { const b = e.target.closest('[data-m]'); if (!b) return; WV.wmode = b.dataset.m; WV.wpts = []; angledCount(); waterMode(); });
function angledCount() { $('#wa-count').textContent = WV.wpts.length === 1 ? 'Now click where it ends.' : WV.wpts.length === 2 ? 'Ready.' : ''; }
function angledClick(e) { const w = canvasToWorld(e); if (WV.wpts.length >= 2) WV.wpts = []; WV.wpts.push({ x: w.x, y: w.y, h: w.h }); angledCount(); drawTile(); }
$('#wa-clear').addEventListener('click', () => { WV.wpts = []; angledCount(); if (WV.tile) drawTile(); });
$('#wa-go').addEventListener('click', () => safe(async () => {
  if (WV.wpts.length < 2) { toast('Click where the water starts, then where it ends.', true); return; }
  const [a, b] = WV.wpts, hz = (id, p) => ($(id).value === '' ? Math.round(((p.h ?? 0) + 2) * 2) / 2 : +$(id).value);
  await checkpoint('angled water');
  const n = await api('world_water_slope', { dir: S.project.dir, map: WV.tile.map, from: [a.x, a.y, hz('#wa-from', a)], to: [b.x, b.y, hz('#wa-to', b)], width: +$('#wa-width').value || 24, kind: $('#w-wkind').value });
  WV.wpts = []; angledCount(); toast(`Poured ${n} water tile${n === 1 ? '' : 's'}.`);
  WV.tileRev = (WV.tileRev || 0) + 1;
  await showTile();
}));
// copy a block of chunks and paste it anywhere, turned and mirrored
const CHUNK_YD = 1600 / 3 / 16;
WV.clip = null; WV.clipA = null; WV.clipTurn = 0; WV.clipMirror = false; WV.clipFit = true;
async function clipInfo() {
  WV.clip = await api('world_chunk_clip', { dir: S.project.dir });
  clipState();
}
function clipState() {
  const c = WV.clip, turned = WV.clipTurn % 2 ? [c?.h, c?.w] : [c?.w, c?.h];
  $('#cl-state').textContent = WV.clipA ? 'Now click the other corner.'
    : c ? `${turned[0]} × ${turned[1]} chunk${turned[0] * turned[1] === 1 ? '' : 's'} copied${c.map !== WV.tile?.map ? ` from ${c.map}` : ''}. Click to paste${WV.clipMirror ? ' (mirrored)' : ''}.`
    : 'Click two corners to copy the chunks between them.';
  $('#cl-turnv').textContent = `${WV.clipTurn * 90}°`;
  $('#cl-mirror').classList.toggle('on', WV.clipMirror);
}
function clipCopying() { return !WV.clip || WV.clipA || WV.clipFresh; }
async function clipClick(e) {
  const w = canvasToWorld(e);
  if (clipCopying()) {
    if (!WV.clipA) { WV.clipA = w; WV.clipFresh = true; clipState(); drawTile(); return; }
    const a = WV.clipA; WV.clipA = null;
    await safe(async () => {
      const c = await api('world_chunk_copy', { dir: S.project.dir, map: WV.tile.map, from: [a.x, a.y], to: [w.x, w.y] });
      WV.clip = c; WV.clipFresh = false; WV.clipTurn = 0; WV.clipMirror = false;
      toast(`Copied ${c.w} × ${c.h} chunk${c.w * c.h === 1 ? '' : 's'}: click anywhere to paste.`);
    });
    clipState(); drawTile(); return;
  }
  await safe(async () => {
    await checkpoint('paste ground');
    const r = await api('world_chunk_paste', { dir: S.project.dir, spec: { map: WV.tile.map, x: w.x, y: w.y, turn: WV.clipTurn, mirror: WV.clipMirror, absolute: !WV.clipFit,
      heights: $('#cl-h').checked, textures: $('#cl-t').checked, water: $('#cl-w').checked, holes: $('#cl-o').checked, area: $('#cl-a').checked, impass: $('#cl-i').checked } });
    toast(`Pasted across ${r.length} tile${r.length === 1 ? '' : 's'}.`);
    WV.tileRev = (WV.tileRev || 0) + 1;
    await showTile();
  });
}
function clipTurn(d = 1) { WV.clipTurn = (WV.clipTurn + d + 4) % 4; clipState(); if (WV.tile) drawTile(); }
function clipMirror() { WV.clipMirror = !WV.clipMirror; clipState(); if (WV.tile) drawTile(); }
$('#cl-turn').addEventListener('click', () => clipTurn());
$('#cl-mirror').addEventListener('click', clipMirror);
$('#cl-new').addEventListener('click', () => { WV.clipFresh = true; WV.clipA = null; clipState(); });
$('#cl-fit').addEventListener('click', (e) => { const b = e.target.closest('[data-f]'); if (!b) return; WV.clipFit = b.dataset.f === 'fit'; $$('#cl-fit button').forEach((x) => x.classList.toggle('on', x === b)); });
function drawClip(g, s) {
  const m = WV.mouseLocal; if (!m) return;
  const C = CHUNK_YD * s;
  g.save(); g.lineWidth = 1.5;
  if (clipCopying()) {
    if (!WV.clipA) { g.restore(); return; }
    const a = localOf(WV.clipA);
    const c0 = Math.floor(Math.min(a.u, m.u) / CHUNK_YD), c1 = Math.floor(Math.max(a.u, m.u) / CHUNK_YD);
    const r0 = Math.floor(Math.min(a.v, m.v) / CHUNK_YD), r1 = Math.floor(Math.max(a.v, m.v) / CHUNK_YD);
    g.fillStyle = 'rgba(138,180,232,.16)'; g.strokeStyle = '#8ab4e8'; g.setLineDash([5, 4]);
    g.fillRect(c0 * C, r0 * C, (c1 - c0 + 1) * C, (r1 - r0 + 1) * C); g.strokeRect(c0 * C, r0 * C, (c1 - c0 + 1) * C, (r1 - r0 + 1) * C);
  } else {
    const [w, h] = WV.clipTurn % 2 ? [WV.clip.h, WV.clip.w] : [WV.clip.w, WV.clip.h];
    const c0 = Math.round(m.u / CHUNK_YD - w / 2), r0 = Math.round(m.v / CHUNK_YD - h / 2);
    g.fillStyle = 'rgba(255,210,122,.14)'; g.strokeStyle = '#ffd27a'; g.setLineDash([]);
    g.fillRect(c0 * C, r0 * C, w * C, h * C); g.strokeRect(c0 * C, r0 * C, w * C, h * C);
    // which way the copy faces: a notch on its (turned) top edge
    g.setLineDash([3, 3]);
    for (let i = 1; i < w; i++) { g.beginPath(); g.moveTo((c0 + i) * C, r0 * C); g.lineTo((c0 + i) * C, (r0 + h) * C); g.stroke(); }
    for (let j = 1; j < h; j++) { g.beginPath(); g.moveTo(c0 * C, (r0 + j) * C); g.lineTo((c0 + w) * C, (r0 + j) * C); g.stroke(); }
  }
  g.restore();
}
// scripts: your own brushes in a few lines of JavaScript, run in this window against Forge's tools
const SCRIPT_SAMPLES = {
  'Terraces': `// Steps cut into the slope around where you click, like rice terraces.
const step = 6, radius = 60;
await forge.shape((x, y, h) => Math.round(h / step) * step, { x: click.x, y: click.y, radius, soft: 0.25 });`,
  'Crater field': `// A handful of craters scattered around the click.
const rnd = forge.random(click.x * 7 + click.y);
for (let i = 0; i < 6; i++) {
  const a = rnd() * Math.PI * 2, d = rnd() * 60, r = 8 + rnd() * 14;
  const cx = click.x + Math.cos(a) * d, cy = click.y + Math.sin(a) * d;
  await forge.shape((x, y, h) => {
    const t = Math.hypot(x - cx, y - cy) / r;            // 0 in the middle, 1 at the rim
    return h + (t < 1 ? -r * 0.35 * (1 - t * t) : r * 0.2 * Math.exp(-((t - 1) ** 2) * 12));
  }, { x: cx, y: cy, radius: r * 1.6 });
}`,
  'Rolling hills': `// Soft hills from noise, up to 18 yards high, fading out at the edge.
await forge.shape((x, y, h) => h + 18 * forge.noise(x / 70, y / 70), { x: click.x, y: click.y, radius: 120, soft: 0.5 });`,
  'Ring of stones': `// A ring of the tile's own rocks (or its first prop) standing round the click.
const rock = forge.models(/rock|stone|boulder/i)[0] || forge.models()[0];
if (!rock) return log('No props on this tile to use.');
const n = 12, r = 18, list = [];
for (let i = 0; i < n; i++) {
  const a = i / n * Math.PI * 2;
  list.push({ model: rock, x: click.x + Math.cos(a) * r, y: click.y + Math.sin(a) * r, turn: a * 180 / Math.PI, scale: 1.3 });
}
await forge.placeMany(list);
log('Placed', n, rock.split('\\\\').pop());`,
  'Forest on the slopes': `// Trees from this tile, only on ground between two heights and not too steep.
const trees = forge.models(/tree/i);
if (!trees.length) return log('No trees on this tile to use.');
const rnd = forge.random(42), list = [];
for (let i = 0; i < 400 && list.length < 40; i++) {
  const x = click.x + (rnd() - 0.5) * 120, y = click.y + (rnd() - 0.5) * 120, h = forge.at(x, y);
  if (h == null || forge.slope(x, y) > 30) continue;
  list.push({ model: trees[Math.floor(rnd() * trees.length)], x, y, turn: rnd() * 360, scale: 0.8 + rnd() * 0.5 });
}
await forge.placeMany(list);
log('Planted', list.length, 'trees');`,
  'Pond with a shore': `// Dig a bowl, pour water in, paint the shore with the tile's second texture.
await forge.shape((x, y, h) => { const t = Math.hypot(x - click.x, y - click.y) / 25; return h - 6 * Math.max(0, 1 - t * t); }, { x: click.x, y: click.y, radius: 30 });
await forge.water({ x: click.x, y: click.y, radius: 22, level: click.h - 1 });
if (forge.textures[1]) await forge.paint(forge.textures[1], { x: click.x, y: click.y, radius: 30, strength: 0.6 });`,
};
WV.scripts = [];
async function loadScripts() {
  WV.scripts = await api('world_scripts', { dir: S.project.dir });
  const keep = $('#sc2-list').value;
  $('#sc2-list').innerHTML = `<optgroup label="Samples">${Object.keys(SCRIPT_SAMPLES).map((k) => `<option value="s:${esc(k)}">${esc(k)}</option>`).join('')}</optgroup>`
    + (WV.scripts.length ? `<optgroup label="Your pack">${WV.scripts.map((x) => `<option value="p:${esc(x.name)}">${esc(x.name)}</option>`).join('')}</optgroup>` : '');
  if (keep && $$('#sc2-list option').some((o) => o.value === keep)) $('#sc2-list').value = keep;
  if (!$('#sc2-code').value) openScript();
}
function openScript() {
  const v = $('#sc2-list').value || '', name = v.slice(2);
  const code = v.startsWith('s:') ? SCRIPT_SAMPLES[name] : WV.scripts.find((x) => x.name === name)?.code;
  $('#sc2-name').value = name; $('#sc2-code').value = code || '';
  $('#sc2-del').disabled = !v.startsWith('p:');
}
$('#sc2-list').addEventListener('change', openScript);
$('#sc2-code').addEventListener('keydown', (e) => {
  if (e.key === 'Tab' && !e.shiftKey) { e.preventDefault(); e.stopPropagation(); document.execCommand('insertText', false, '  '); }
  if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) { e.preventDefault(); e.stopPropagation(); $('#sc2-run').click(); }
});
$('#sc2-new').addEventListener('click', () => { $('#sc2-name').value = 'My brush'; $('#sc2-code').value = '// click is where you clicked: { x, y, h }\nawait forge.raise({ x: click.x, y: click.y, radius: 20, strength: 5 });\n'; $('#sc2-code').focus(); });
$('#sc2-save').addEventListener('click', () => safe(async () => {
  const n = await api('world_script_save', { dir: S.project.dir, name: $('#sc2-name').value || 'My brush', code: $('#sc2-code').value });
  await loadScripts(); $('#sc2-list').value = 'p:' + n; $('#sc2-del').disabled = false; toast(`Saved “${n}” in the pack (world_scripts).`);
}));
$('#sc2-del').addEventListener('click', () => safe(async () => {
  const v = $('#sc2-list').value; if (!v.startsWith('p:') || !armed('del-script', 'Click again to delete this script.')) return;
  await api('world_script_remove', { dir: S.project.dir, name: v.slice(2) }); $('#sc2-list').value = ''; await loadScripts(); openScript();
}));
$('#sc2-run').addEventListener('click', () => {
  if (!WV.tile) { toast('Show a tile first.', true); return; }
  const half = WV.tile.size / 2; runScript({ x: WV.tile.origin.x - half, y: WV.tile.origin.y - half, h: canvasToWorld({ u: half, v: half }).h });
});
$('#sc2-help').addEventListener('click', () => {
  const d = $('#sc2-doc'); d.hidden = !d.hidden;
  d.innerHTML = `A script is the body of an <code>async</code> function. It gets <code>click</code> (<code>{x, y, h}</code>, world yards) and <code>forge</code>:
  <ul class="tight"><li><code>forge.at(x, y)</code>, <code>forge.slope(x, y)</code>: the ground's height, and how steep in degrees</li>
  <li><code>await forge.shape((x, y, h) =&gt; newH, {x, y, radius, soft})</code>: set the ground to anything you can compute</li>
  <li><code>await forge.raise / lower / smooth / flatten({x, y, radius, strength})</code></li>
  <li><code>await forge.paint(texture, {x, y, radius, strength})</code>, <code>forge.textures</code> (the tile's)</li>
  <li><code>await forge.place(model, {x, y, turn, scale})</code>, <code>forge.placeMany([...])</code>, <code>forge.models(/tree/i)</code> (the tile's)</li>
  <li><code>await forge.water({x, y, radius, level, kind})</code>, <code>forge.ramp</code>, <code>forge.call(command, args)</code></li>
  <li><code>forge.random(seed)</code>, <code>forge.noise(x, y)</code> (−1…1), <code>log(...)</code></li></ul>`;
});
function scriptApi() {
  const t = WV.tile, dir = S.project.dir, map = t.map, N = 129;
  const local = (x, y) => ({ u: t.origin.y - y, v: t.origin.x - x });
  const at = (x, y) => {
    const { u, v } = local(x, y), gx = u / t.size * 128, gz = v / t.size * 128;
    if (gx < 0 || gz < 0 || gx > 128 || gz > 128) return null;
    const i = Math.min(127, Math.floor(gz)), j = Math.min(127, Math.floor(gx)), fz = gz - i, fx = gx - j, H = t.heights;
    return (H[i * N + j] * (1 - fx) + H[i * N + j + 1] * fx) * (1 - fz) + (H[(i + 1) * N + j] * (1 - fx) + H[(i + 1) * N + j + 1] * fx) * fz;
  };
  const HALF = 32 * 1600 / 3;
  let changed = false;
  const call = async (cmd, args) => { const r = await api(cmd, { dir, map, ...args }); changed = true; return r; };
  const sculpt = (brush) => (o) => call('world_sculpt', { x: o.x, y: o.y, radius: o.radius || 20, strength: o.strength ?? 2, brush });
  const random = (seed = 1) => { let a = (seed * 2654435761) >>> 0 || 1; return () => { a |= 0; a = (a + 0x6d2b79f5) | 0; let q = Math.imul(a ^ (a >>> 15), 1 | a); q = (q + Math.imul(q ^ (q >>> 7), 61 | q)) ^ q; return ((q ^ (q >>> 14)) >>> 0) / 4294967296; }; };
  const hash = (i, j) => { const s = Math.sin(i * 127.1 + j * 311.7) * 43758.5453; return s - Math.floor(s); };
  const noise = (x, y) => {
    let sum = 0, amp = 1, norm = 0;
    for (let o = 0; o < 4; o++) {
      const i = Math.floor(x), j = Math.floor(y), fx = x - i, fy = y - j, sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy);
      const v = (hash(i, j) * (1 - sx) + hash(i + 1, j) * sx) * (1 - sy) + (hash(i, j + 1) * (1 - sx) + hash(i + 1, j + 1) * sx) * sy;
      sum += (v * 2 - 1) * amp; norm += amp; amp *= 0.5; x *= 2.03; y *= 2.03;
    }
    return sum / norm;
  };
  return {
    map, tile: { a: t.tile[0], b: t.tile[1] }, textures: t.textures || [],
    at, slope(x, y) { const d = 2, a = at(x + d, y), b = at(x - d, y), c = at(x, y + d), e = at(x, y - d); if ([a, b, c, e].some((q) => q == null)) return 0; return Math.atan(Math.hypot((a - b) / (2 * d), (c - e) / (2 * d))) * 180 / Math.PI; },
    models(re) { return tileModels('props').map((m) => m.path).filter((p) => !re || re.test(p)); },
    random, noise, call,
    // the ground set by a function over a circle (soft: how much of the edge fades)
    async shape(fn, o) {
      const r = o.radius || 30, step = o.step || Math.max(2, r / 60), soft = o.soft ?? 0.2;
      const fx0 = HALF - o.y - r, fz0 = HALF - o.x - r, w = Math.floor(2 * r / step) + 1, values = new Array(w * w);
      for (let j = 0; j < w; j++) for (let i = 0; i < w; i++) {
        const fx = fx0 + i * step, fz = fz0 + j * step, x = HALF - fz, y = HALF - fx, d = Math.hypot(x - o.x, y - o.y) / r;
        const h = at(x, y);
        if (d > 1 || h == null) { values[j * w + i] = null; continue; }
        const want = fn(x, y, h), k = soft > 0 ? Math.min(1, (1 - d) / soft) : 1, e = k * k * (3 - 2 * k);
        values[j * w + i] = Number.isFinite(want) ? h + (want - h) * e : null;
      }
      return call('kit_field', { spec: { map, fx: fx0, fz: fz0, step, w, h: w, values, blend: 1 } });
    },
    raise: sculpt('raise'), lower: sculpt('lower'), smooth: sculpt('smooth'), flatten: sculpt('flatten'),
    paint: (texture, o) => call('world_paint', { x: o.x, y: o.y, radius: o.radius || 20, strength: Math.min(1, o.strength ?? 0.5), texture }),
    place: (model, o) => call('world_place', { placement: { model, x: o.x, y: o.y, z: 0, turn: o.turn || 0, scale: o.scale || 1, uid: 0 } }),
    placeMany: (list) => call('world_place_many', { placements: list.map((o) => ({ model: o.model, x: o.x, y: o.y, z: 0, turn: o.turn || 0, scale: o.scale || 1, uid: 0 })) }),
    water: (o) => call('world_water', { x: o.x, y: o.y, radius: o.radius || 20, level: o.level, kind: o.kind || 'water', erase: false }),
    ramp: (from, to, o = {}) => call('kit_ramp', { spec: { map, from, to, width: o.width || 10, from_z: o.fromZ ?? null, to_z: o.toZ ?? null } }),
    get changed() { return changed; },
  };
}
async function runScript(click) {
  if (WV.scriptBusy) return;
  const out = $('#sc2-log'), lines = [];
  const log = (...a) => { lines.push(a.map((x) => (typeof x === 'string' ? x : JSON.stringify(x))).join(' ')); out.hidden = false; out.textContent = lines.slice(-30).join('\n'); };
  let fn;
  try { fn = new (Object.getPrototypeOf(async function () {}).constructor)('forge', 'click', 'log', $('#sc2-code').value); }
  catch (e) { log('✗ ' + e.message); return; }
  WV.scriptBusy = true; loadChip('Running script…', 0.5);
  const t0 = performance.now();
  try {
    await checkpoint('script ' + ($('#sc2-name').value || ''));
    const forge = scriptApi();
    await fn(forge, { x: click.x, y: click.y, h: click.h }, log);
    log(`✓ done in ${((performance.now() - t0) / 1000).toFixed(1)} s`);
    if (forge.changed) { WV.tileRev = (WV.tileRev || 0) + 1; await showTile(); }
  } catch (e) { log('✗ ' + (e?.message || e)); }
  finally { WV.scriptBusy = false; loadChip(); }
}
// stamps: a greyscale picture pressed into the ground. Forge draws a few of its own; any PNG works.
const STAMPS = {
  Crater: (x, y) => { const d = Math.hypot(x, y); return d > 1 ? 0 : 0.35 + 0.65 * Math.exp(-((d - 0.72) ** 2) / 0.012) - 0.35 * (1 - Math.min(1, d / 0.6)); },
  Hill: (x, y) => { const d = Math.hypot(x, y); return d > 1 ? 0 : 0.5 + 0.5 * Math.cos(Math.PI * d); },
  Mesa: (x, y) => { const d = Math.hypot(x, y); return d > 1 ? 0 : 1 / (1 + Math.exp((d - 0.6) * 22)); },
  Ridges: (x, y) => { const d = Math.hypot(x, y); return d > 1 ? 0 : (0.5 + 0.5 * Math.cos(x * 9 + Math.sin(y * 3) * 1.5)) * (0.5 + 0.5 * Math.cos(Math.PI * d)); },
  Dunes: (x, y) => { const d = Math.max(Math.abs(x), Math.abs(y)); const f = (0.5 + 0.5 * Math.sin(x * 7 + y * 2)) ** 2; return f * Math.min(1, (1 - d) * 4); },
  Spire: (x, y) => { const d = Math.hypot(x, y); return d > 1 ? 0 : (1 - d) ** 2.4; },
};
WV.stamp = { name: 'Hill', data: null };
function stampCanvas(f, n = 128) {
  const c = document.createElement('canvas'); c.width = c.height = n; const g = c.getContext('2d'), im = g.createImageData(n, n);
  for (let j = 0; j < n; j++) for (let i = 0; i < n; i++) {
    const v = Math.max(0, Math.min(1, f((i / (n - 1)) * 2 - 1, (j / (n - 1)) * 2 - 1))) * 255, k = (j * n + i) * 4;
    im.data[k] = im.data[k + 1] = im.data[k + 2] = v; im.data[k + 3] = 255;
  }
  g.putImageData(im, 0, 0); return c;
}
function renderStamps() {
  const grid = $('#st-grid'); if (grid.dataset.done) { $$('button', grid).forEach((b) => b.classList.toggle('on', b.dataset.st === WV.stamp.name)); return; }
  grid.dataset.done = 1;
  grid.innerHTML = Object.keys(STAMPS).map((k) => `<button type="button" class="stamp" data-st="${k}" title="${k}"><img alt="" src="${stampCanvas(STAMPS[k], 64).toDataURL()}"><span>${k}</span></button>`).join('');
  grid.addEventListener('click', (e) => {
    const b = e.target.closest('[data-st]'); if (!b) return;
    WV.stamp = { name: b.dataset.st, data: null }; $('#st-name').textContent = ''; renderStamps();
  });
  renderStamps();
}
$('#st-pick').addEventListener('click', () => $('#st-file').click());
$('#st-file').addEventListener('change', () => safe(async () => {
  const f = $('#st-file').files[0]; if (!f) return;
  const b = new Uint8Array(await f.arrayBuffer()); let s = ''; for (let i = 0; i < b.length; i += 0x8000) s += String.fromCharCode(...b.subarray(i, i + 0x8000));
  WV.stamp = { name: f.name, data: btoa(s) }; $('#st-name').textContent = f.name; $('#st-file').value = ''; renderStamps();
}));
function stampData() { return WV.stamp.data || stampCanvas(STAMPS[WV.stamp.name] || STAMPS.Hill, 256).toDataURL('image/png').split(',')[1]; }
async function stampClick(e) {
  const w = canvasToWorld(e);
  await safe(async () => {
    await checkpoint('stamp');
    const r = await api('kit_stamp', { dir: S.project.dir, spec: { map: WV.tile.map, x: w.x, y: w.y, radius: +$('#st-radius').value || 40, strength: +$('#st-strength').value || 10, turn: +$('#st-turn').value || 0, lower: $('#st-lower').checked, image: stampData() } });
    toast(`Pressed “${WV.stamp.name}” into ${r.length} tile${r.length === 1 ? '' : 's'}.`);
    WV.tileRev = (WV.tileRev || 0) + 1;
    await showTile();
  });
}
async function loadPrefabs() {
  const list = await api('kit_prefabs', { dir: S.project.dir });
  const keep = $('#pf-list').value;
  $('#pf-list').innerHTML = list.length ? list.map((p) => `<option value="${esc(p.name)}">${esc(p.name)} (${p.objects.length} doodad${p.objects.length === 1 ? '' : 's'}${p.spawns.length ? `, ${p.spawns.length} spawn${p.spawns.length === 1 ? '' : 's'}` : ''})</option>`).join('') : '<option value="">(none yet: New from a box…)</option>';
  if (keep) $('#pf-list').value = keep;
}
function prefabClick(e) {
  const w = canvasToWorld(e);
  if (WV.capture) {
    WV.capture.push({ x: w.x, y: w.y });
    if (WV.capture.length < 2) { $('#pf-step').textContent = 'Now the opposite corner.'; drawTile(); return; }
    const [a, b] = WV.capture; WV.capture = null; $('#pf-capbox').hidden = true;
    safe(async () => {
      const pf = await api('kit_prefab_capture', { dir: S.project.dir, map: WV.tile.map, name: $('#pf-name').value || 'Prefab', a: [a.x, a.y], b: [b.x, b.y] });
      toast(`Saved prefab “${pf.name}”: ${pf.objects.length} doodads, ${pf.spawns.length} spawns.`);
      await loadPrefabs(); $('#pf-list').value = pf.name; drawTile();
    });
    return;
  }
  const name = $('#pf-list').value;
  if (!name) { toast('Make a prefab first: New from a box…', true); return; }
  safe(async () => {
    await checkpoint('prefab');
    const r = await api('kit_prefab_stamp', { dir: S.project.dir, map: WV.tile.map, name, x: w.x, y: w.y, turn: +$('#pf-turn').value || 0, level: $('#pf-level').checked });
    toast(`Stamped: ${r.objects} doodads, ${r.spawns} spawns.`);
    WV.info = await api('world_list', { dir: S.project.dir });
    WV.tileRev = (WV.tileRev || 0) + 1;
    await showTile();
  });
}
$('#pf-capture').addEventListener('click', () => { WV.capture = []; $('#pf-capbox').hidden = false; $('#pf-step').textContent = 'First corner.'; $('#pf-name').focus(); });
$('#pf-cancel').addEventListener('click', (e) => { e.preventDefault(); WV.capture = null; $('#pf-capbox').hidden = true; if (WV.tile) drawTile(); });
$('#pf-del').addEventListener('click', () => safe(async () => {
  const name = $('#pf-list').value; if (!name) return;
  if (!armed('pfdel', `Click Delete again to delete the prefab “${name}”.`)) return;
  await api('kit_prefab_remove', { dir: S.project.dir, name }); await loadPrefabs();
}));
$('#pf-import').addEventListener('click', () => $('#pf-file').click());
$('#pf-file').addEventListener('change', () => safe(async () => {
  const f = $('#pf-file').files[0]; if (!f) return;
  const pf = await api('kit_prefab_add', { dir: S.project.dir, json: await f.text() });
  toast(`Brought in “${pf.name}”.`); await loadPrefabs(); $('#pf-list').value = pf.name; $('#pf-file').value = '';
}));
function drawKit(g, s) {
  if (WV.tool === 'road' && WV.road.length) {
    const pts = WV.road.map(localOf), wd = (+$('#rd-width').value || 6) * s;
    g.strokeStyle = 'rgba(200,160,90,.55)'; g.lineWidth = Math.max(2, wd); g.lineCap = 'round'; g.lineJoin = 'round';
    g.beginPath(); pts.forEach((p, i) => (i ? g.lineTo(p.u * s, p.v * s) : g.moveTo(p.u * s, p.v * s))); g.stroke();
    g.lineWidth = 1; g.lineCap = 'butt';
    for (const p of pts) { g.fillStyle = '#ffd27a'; g.beginPath(); g.arc(p.u * s, p.v * s, 3.5, 0, 7); g.fill(); }
  }
  if (WV.tool === 'ramp' && WV.ramp.length) {
    const pts = WV.ramp.map(localOf), m = WV.mouseLocal, wd = (+$('#rp-width').value || 10) * s;
    const end = pts[1] || m;
    if (end) { g.strokeStyle = 'rgba(255,210,122,.45)'; g.lineWidth = Math.max(2, wd); g.beginPath(); g.moveTo(pts[0].u * s, pts[0].v * s); g.lineTo(end.u * s, end.v * s); g.stroke(); g.lineWidth = 1; }
    pts.forEach((p, i) => { g.fillStyle = i ? '#ffd27a' : '#9fc4ff'; g.beginPath(); g.arc(p.u * s, p.v * s, 4, 0, 7); g.fill(); });
  }
  if (WV.tool === 'water' && WV.wmode === 'angled' && WV.wpts.length) {
    const pts = WV.wpts.map(localOf), end = pts[1] || WV.mouseLocal, wd = (+$('#wa-width').value || 24) * s;
    if (end) { g.strokeStyle = 'rgba(110,170,240,.45)'; g.lineWidth = Math.max(2, wd); g.beginPath(); g.moveTo(pts[0].u * s, pts[0].v * s); g.lineTo(end.u * s, end.v * s); g.stroke(); g.lineWidth = 1; }
    pts.forEach((p) => { g.fillStyle = '#8ab4e8'; g.beginPath(); g.arc(p.u * s, p.v * s, 4, 0, 7); g.fill(); });
  }
  if (WV.tool === 'clip') drawClip(g, s);
  if (WV.tool === 'measure') drawMeasure(g, s);
  drawVsel(g, s);
  if (WV.game && WV.tile) {
    const d = [...(WV.tile.stock || []), ...(WV.tile.buildings || [])].find((x) => x.uid === WV.game.uid);
    if (d) { g.strokeStyle = '#8ab4e8'; g.lineWidth = 2; g.beginPath(); g.arc(d.u * s, d.v * s, 9, 0, 7); g.stroke(); g.lineWidth = 1; }
  }
  if (WV.tool === 'stamp' && WV.mouseLocal) {
    const m = WV.mouseLocal, r = (+$('#st-radius').value || 40) * s, t = ((+$('#st-turn').value || 0) * Math.PI) / 180;
    g.save(); g.translate(m.u * s, m.v * s); g.rotate(-t); g.strokeStyle = '#ffd27a'; g.setLineDash([5, 4]); g.strokeRect(-r, -r, 2 * r, 2 * r);
    g.setLineDash([]); g.beginPath(); g.moveTo(0, -r); g.lineTo(0, -r - 8); g.stroke(); g.restore();
  }
  if (WV.capture?.length === 1) {
    const p = localOf(WV.capture[0]); g.strokeStyle = '#ffd27a'; g.setLineDash([4, 3]);
    const m = WV.mouseLocal; if (m) g.strokeRect(Math.min(p.u, m.u) * s, Math.min(p.v, m.v) * s, Math.abs(m.u - p.u) * s, Math.abs(m.v - p.v) * s);
    g.setLineDash([]);
  }
}
$('#w-canvas').addEventListener('mousemove', (e) => { if (WV.tile && (WV.tool === 'stamp' || WV.tool === 'clip' || (WV.tool === 'measure' && WV.meas.length === 1) || (WV.tool === 'ramp' && WV.ramp.length === 1) || (WV.tool === 'water' && WV.wmode === 'angled' && WV.wpts.length === 1))) { WV.mouseLocal = localOf(canvasToWorld(e)); drawTile(); return; } if (WV.capture?.length === 1 && WV.tile) { const w = canvasToWorld(e); WV.mouseLocal = localOf(w); drawTile(); } });
// heightmaps
$('#hm-export').addEventListener('click', () => safe(async () => {
  if (!WV.tile) { toast('Show a tile first.', true); return; }
  const r = await api('kit_heightmap_export', { dir: S.project.dir, map: WV.tile.map, a: WV.tile.tile[0], b: WV.tile.tile[1] });
  $('#hm-lo').value = Math.floor(r.lo); $('#hm-hi').value = Math.ceil(r.hi);
  if (!DESKTOP) { const a = document.createElement('a'); a.href = 'data:image/png;base64,' + r.png; a.download = r.name; a.click(); }
  toast(`Saved ${r.name} (black ${r.lo.toFixed(1)}, white ${r.hi.toFixed(1)}) in your project's exports folder.`);
}));
$('#hm-import').addEventListener('click', () => safe(async () => {
  const f = $('#hm-file').files[0];
  if (!f || !WV.tile) { toast('Show a tile and pick a PNG first.', true); return; }
  const pair = (s, d) => { const m = String(s || '').match(/(-?\d+)\D+(-?\d+)/); return m ? [+m[1], +m[2]] : d; };
  const here = [WV.tile.tile[0], WV.tile.tile[1]];
  const b64 = await new Promise((ok) => { const fr = new FileReader(); fr.onload = () => ok(String(fr.result).split(',')[1]); fr.readAsDataURL(f); });
  await checkpoint('heightmap');
  const r = await api('kit_heightmap_import', { dir: S.project.dir, png: b64, spec: { map: WV.tile.map, from: pair($('#hm-from').value, here), to: pair($('#hm-to').value, pair($('#hm-from').value, here)), lo: +$('#hm-lo').value, hi: +$('#hm-hi').value, strength: +$('#hm-strength').value || 1 } });
  toast(`Shaped ${r.tiles} tile${r.tiles === 1 ? '' : 's'}${r.missing.length ? ` (the map has no ${r.missing.join(', ')})` : ''}.`);
  WV.tileRev = (WV.tileRev || 0) + 1;
  await showTile();
}));


// ---- Live Link ------------------------------------------------------------------------------
try { const c = localStorage.getItem('forge.char'); if (c) $('#ll-char').value = c; } catch {}
$('#ll-char').addEventListener('change', () => { try { localStorage.setItem('forge.char', $('#ll-char').value.trim()); } catch {} });
async function loadLive() {
  const st = await api('live_status').catch(() => null);
  if (!st) return;
  $('#ll-state').textContent = !st.setup || st.own ? `(${st.why})` : st.running ? '● The test realm is running.' : st.fresh ? '○ The test realm is made on the first install.' : '○ The test realm isn\'t running: press Start.';
  $('#ll-state').className = st.running ? 'ok' : '';
  for (const id of ['#ll-gm', '#ll-apply']) { const b = $(id); if (!('t' in b.dataset)) b.dataset.t = b.title; b.disabled = !st.running; b.title = st.running ? b.dataset.t : 'Start the test realm first (step 2 on the left)'; }
  const m = st.mark;
  if (m) {
    if (!$('#ll-char').value && m.char) $('#ll-char').value = m.char;
    $('#ll-mark').innerHTML = `<b>${esc(m.char || 'You')}</b> marked ${esc(m.zone || 'map ' + m.map)} at ${(+m.x).toFixed(1)}, ${(+m.y).toFixed(1)}, ${(+m.z).toFixed(1)}${m.target ? `, targeting <b>${esc(m.target)}</b>${m.entry ? ` (${m.entry})` : ''}` : ''}.
      <div class="row mt-s"><button class="btn small" id="ll-show">Show on the World map</button>${m.entry ? '<button class="btn small" id="ll-open">Open its behaviour</button>' : ''}</div>`;
    $('#ll-show').addEventListener('click', () => safe(() => goToMark(m)));
    $('#ll-open')?.addEventListener('click', () => { BH.entry = +m.entry; show('behaviour'); });
  }
}
$('#ll-refresh').addEventListener('click', () => safe(loadLive));
$('#ll-gm').addEventListener('click', () => safe(async () => { const r = await api('live_gm'); toast(r || 'Done: the solo account is a GM until the test realm restarts.'); }));
$('#ll-apply').addEventListener('click', () => safe(async () => {
  const r = await api('live_apply', { dir: S.project.dir });
  $('#ll-out').innerHTML = (r.reloaded.length ? `Reloaded now: ${r.reloaded.map(esc).join(', ')}. ` : '') + (r.restart.length ? `<br>Needs the test realm restarted to show: ${r.restart.map(esc).join(', ')}.` : '');
  toast('Applied to the running realm.');
}));
WV.lastPick = null;
$('#w-canvas').addEventListener('click', (e) => { if (WV.tile) WV.lastPick = canvasToWorld(e); });
$('#w-3d').addEventListener('click', (e) => { const p = pick3d(e); if (p && WV.tile) WV.lastPick = canvasToWorld(p); });
// (Send me here is Test in game: with the test realm up it only sends you)


// ---- the sample island ------------------------------------------------------------------------
$('#sample-go').addEventListener('click', () => safe(async () => {
  if (!S.status?.game) { toast('Set your game folder first (Setup, on the right): the sample uses your game\'s trees and textures.', true); return; }
  $('#sample-go').disabled = true; $('#sample-go').textContent = 'Building Ember Isle…';
  try {
    const p = await api('sample_create');
    showProject(p); toast('Ember Isle is ready: open World to see it, Behaviour for its creatures.');
    try { localStorage.removeItem('forge.toured'); } catch {}
    setTimeout(startTour, 600);
  } finally { $('#sample-go').disabled = false; $('#sample-go').textContent = 'Make the sample island'; }
}));

// ---- Ctrl+K: go anywhere ------------------------------------------------------------------------
const PAL = { items: [], sel: 0 };
async function paletteItems() {
  const items = [];
  const go = (v, label, hint) => items.push({ label, hint, run: () => show(v) });
  if (S.project) {
    go('project', 'Project', 'name, version, checks, files');
    go('world', 'World', 'the map: sculpt, paint, place, spawn');
    go('models', 'Models', 'import your own .glb');
    go('content', 'Content', 'creatures, quests, items, vendors');
    go('behaviour', 'Behaviour', 'fight plans, lines, dialogue');
    go('data', 'Data', 'every table as rows');
    go('code', 'Code', 'addons');
    go('test', 'Test & Play', 'test copies of your game and Play Solo, Live Link');
    go('publish', 'Publish', 'a signed pack');
    for (const t of $$('#w-tools button')) items.push({ label: 'World: ' + t.textContent, hint: t.title || 'tool', run: async () => { show('world'); t.click(); } });
    items.push({ label: 'Check', hint: 'what needs fixing', run: () => $('#btn-check').click() });
    items.push({ label: 'Build', hint: 'the patch and server files', run: () => $('#btn-build').click() });
    try {
      const o = await api('behaviour_overview', { dir: S.project.dir });
      for (const c of o.creatures) items.push({ label: `${c.name || '#' + c.entry}`, hint: `creature ${c.entry} · behaviour`, run: () => { BH.entry = c.entry; show('behaviour'); } });
      const w = await api('wiz_list', { dir: S.project.dir });
      for (const q of w.quests || []) items.push({ label: q.title, hint: `quest ${q.id}`, run: () => { show('content'); } });
      for (const it of w.items || []) items.push({ label: it.name, hint: `item ${it.id}`, run: () => { show('content'); } });
    } catch {}
  }
  go('home', 'Home', 'projects, setup');
  go('assets', 'Assets', 'the game\'s files');
  items.push({ label: 'Take the tour', hint: 'five steps around Forge', run: () => { try { localStorage.removeItem('forge.toured'); } catch {} startTour(); } });
  items.push({ label: 'Tour the World editor', hint: 'six stops around the map editor', run: () => { show('world'); setTimeout(() => startEditorTour(true), 400); } });
  return items;
}
function score(label, q) {
  const l = label.toLowerCase(); q = q.toLowerCase();
  if (!q) return 1;
  if (l.startsWith(q)) return 3;
  if (l.includes(q)) return 2;
  let i = 0; for (const ch of l) if (ch === q[i]) i++;
  return i === q.length ? 1 : 0;
}
function renderPalette() {
  const q = $('#pal-q').value;
  const list = PAL.items.map((it) => ({ it, s: Math.max(score(it.label, q), score(it.hint || '', q) ? 0.5 : 0) })).filter((x) => x.s > 0).sort((a, b) => b.s - a.s).slice(0, 12);
  PAL.shown = list.map((x) => x.it);
  PAL.sel = Math.min(PAL.sel, Math.max(0, PAL.shown.length - 1));
  $('#pal-list').innerHTML = PAL.shown.map((it, i) => `<li class="${i === PAL.sel ? 'on' : ''}" data-i="${i}"><b>${esc(it.label)}</b><span class="meta">${esc(it.hint || '')}</span></li>`).join('') || '<li class="meta">Nothing matches.</li>';
  $$('#pal-list li[data-i]').forEach((li) => li.addEventListener('click', () => runPal(+li.dataset.i)));
}
function runPal(i) { const it = PAL.shown?.[i]; closePalette(); if (it) safe(async () => it.run()); }
async function openPalette() {
  $('#palette').hidden = false; $('#pal-q').value = ''; PAL.sel = 0; PAL.items = []; renderPalette(); $('#pal-q').focus();
  PAL.items = await paletteItems(); renderPalette();
}
function closePalette() { $('#palette').hidden = true; }
document.addEventListener('keydown', (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); $('#palette').hidden ? openPalette() : closePalette(); return; }
  if ($('#palette').hidden) return;
  if (e.key === 'Escape') closePalette();
  else if (e.key === 'ArrowDown') { PAL.sel++; renderPalette(); e.preventDefault(); }
  else if (e.key === 'ArrowUp') { PAL.sel = Math.max(0, PAL.sel - 1); renderPalette(); e.preventDefault(); }
  else if (e.key === 'Enter') { runPal(PAL.sel); e.preventDefault(); }
});
$('#pal-q').addEventListener('input', () => { PAL.sel = 0; renderPalette(); });
$('#palette').addEventListener('click', (e) => { if (e.target.id === 'palette') closePalette(); });

// ---- the tour: five steps on the real screens ---------------------------------------------------
const TOUR = [
  { at: '.mod[data-view="world"]', view: 'world', text: '<b>World</b> is the map. Type a map and tile (or paste <code>.gps</code>), then pick a tool: shape the ground, paint it, pour water, place the game\'s trees and buildings, scatter, lay roads, spawn creatures. <b>3D</b> and <b>Real ground</b> show it as the game does.' },
  { at: '.mod[data-view="content"]', view: 'content', text: '<b>Content</b> makes creatures, quests, items and vendors from short forms. No tables to learn.' },
  { at: '.mod[data-view="behaviour"]', view: 'behaviour', text: '<b>Behaviour</b> gives your creatures a fight plan (when this happens, do that), lines to say, and dialogue. Patrol paths are drawn on the World map with the Spawn tool.' },
  { at: '.mod[data-view="test"]', view: 'test', text: '<b>Test &amp; Play</b> puts your pack in Forge\'s own copies of your game and Play Solo (yours are never changed). With the test realm running, <b>Live Link</b> applies changes straight away and sends your character to any spot.' },
  { at: '#btn-check', view: null, text: '<b>Check</b> tells you what still needs fixing, in plain words, and <b>Publish</b> makes a signed pack for a realm. Press <b>Ctrl+K</b> any time to jump anywhere.' },
];
// the World editor's own first look: six stops, the box beside what it explains
const EDITOR_TOUR = [
  { at: '#w-strip', text: '<b>Tools</b> down the left: Place, Shape and Surface. Keys <kbd>1</kbd>–<kbd>0</kbd> pick the first ten; each tool\'s settings are on the right.' },
  { at: '#w-v3d', text: '<b>2D or 3D.</b> In 3D, fly with <kbd>W</kbd><kbd>A</kbd><kbd>S</kbd><kbd>D</kbd> and right-drag to look. ☀ sets the hour: the game\'s own sky, sun and fog.' },
  { at: '#w-walk', text: '<b>Walk</b> drops you in as a character. <b>▶ Test in game</b> (<kbd>T</kbd>) puts you on the spot you clicked, in the real game (Forge\'s test copy: your own game isn\'t changed).' },
  { at: '#w-tilebox', text: '<b>The tile</b> you\'re on. Open it to go to another tile or map (or paste <code>.gps</code> from the game), clear baked shadows, bring in a heightmap or make a new map.' },
  { at: '#w-inuse', text: '<b>On this tile</b>: its ground textures, props, buildings and spawns. Point at one to find it on the map; click to use it.' },
  { at: '#w-histbtn', text: 'Every edit is a step: <b>Undo</b>, <b>Redo</b> and <b>History</b> to go back to any of them. <kbd>?</kbd> shows every key.' },
];
let tourStep = 0, tourList = TOUR, tourKey = 'forge.toured';
function startTour() {
  if (!S.project) return;
  try { if (localStorage.getItem('forge.toured')) return; } catch {}
  tourList = TOUR; tourKey = 'forge.toured'; tourStep = 0; showStep();
}
function startEditorTour(force = false) {
  if (!force) { try { if (localStorage.getItem('forge.toured.editor') || !localStorage.getItem('forge.toured')) return; } catch { return; } }
  if (!$('#tour').hidden || !$('#w-root')?.classList.contains('studio')) return;
  tourList = EDITOR_TOUR; tourKey = 'forge.toured.editor'; tourStep = 0; showStep();
}
function showStep() {
  const st = tourList[tourStep];
  if (!st) { endTour(); return; }
  if (st.view) show(st.view);
  $$('.tour-glow').forEach((x) => x.classList.remove('tour-glow'));
  const el = $(st.at); if (el) el.classList.add('tour-glow');
  const box = $('#tour .tour-box');
  $('#tour-text').innerHTML = st.text; $('#tour-n').textContent = `${tourStep + 1} / ${tourList.length}`;
  $('#tour-next').textContent = tourStep === tourList.length - 1 ? 'Done' : 'Next';
  $('#tour').hidden = false;
  box.style.left = box.style.top = box.style.right = box.style.bottom = 'auto';
  const r = el?.getBoundingClientRect();
  if (tourList === TOUR || !r || !r.width) { box.style.right = '24px'; box.style.bottom = '48px'; return; }
  // beside it: to its right, else below, else to its left; always on screen
  const W = innerWidth, H = innerHeight, bw = box.offsetWidth || 360, bh = box.offsetHeight || 160, gap = 14;
  let x = r.right + gap, y = r.top;
  if (r.width > W * 0.4) { x = r.left + 24; y = r.top - bh - gap > 8 ? r.top - bh - gap : r.bottom + gap; } // a wide strip: above it (or below)
  else {
    if (x + bw > W - 8) { x = r.left; y = r.bottom + gap; }
    if (y + bh > H - 8) { x = r.left - bw - gap; y = r.top; }
  }
  box.style.left = `${Math.max(8, Math.min(W - bw - 8, x))}px`; box.style.top = `${Math.max(8, Math.min(H - bh - 8, y))}px`;
}
function endTour() { $('#tour').hidden = true; $$('.tour-glow').forEach((x) => x.classList.remove('tour-glow')); try { localStorage.setItem(tourKey, '1'); } catch {} }
$('#tour-next').addEventListener('click', () => { tourStep++; showStep(); });
$('#tour-skip').addEventListener('click', (e) => { e.preventDefault(); endTour(); });

// ---- World: pictures to pick from, and what's on the tile -------------------------------------
// a <select>'s value, adding the option when it isn't there yet
function setSelect(sel, v, label) {
  if (![...sel.options].some((o) => o.value === v)) sel.add(new Option(label || fileLabel(v), v));
  sel.value = v;
}
// the tile's models: path → {path, count, building, mine}
function tileModels(kind) {
  const t = WV.tile, m = new Map();
  if (!t) return [];
  const add = (path, building, mine) => {
    if (!path) return;
    const k = path.toLowerCase();
    const e = m.get(k) || { path, count: 0, building, mine: false };
    e.count++; e.mine = e.mine || mine; m.set(k, e);
  };
  if (kind !== 'buildings') for (const d of t.stock || []) if (!d.hidden) add(d.path, false, false);
  if (kind !== 'props') for (const b of t.buildings || []) add(b.path, true, false);
  for (const x of t.mine || []) { const b = /\.wmo$/i.test(x.placement.model); if ((kind === 'buildings') === b || !kind) add(x.placement.model.startsWith('model:') ? x.placement.model : x.path || x.placement.model, b, true); }
  return [...m.values()].sort((a, b) => b.count - a.count);
}
function renderModelGrid() {
  const box = $('#w-modelgrid'); if (!box || !WV.info) return;
  const item = (v, note) => ({ value: v, label: fileLabel(v), th: { model: v }, title: v, note });
  const yours = (WV.info.doodads || []).map((d) => ({ value: d.model, label: d.name, th: { model: d.model }, note: 'yours' }));
  const here = tileModels().slice(0, 18).map((x) => item(x.path, `×${x.count}`));
  const seen = new Set([...yours, ...here].map((x) => x.value.toLowerCase()));
  const rec = recent('models').filter((v) => !seen.has(v.toLowerCase())).map((v) => item(v));
  pickGrid(box, [
    { title: 'Your models', items: yours },
    { title: 'Recently used', items: rec },
    { title: (WV.found || []).length ? `Found (${WV.found.length})` : '', items: (WV.found || []).slice(0, 60).map((v) => item(v)) },
    // the editor layout shows the tile's own props in "On this tile" below the map: not twice
    { title: $('#w-root')?.classList.contains('studio') ? '' : 'Already on this tile', items: $('#w-root')?.classList.contains('studio') ? [] : here },
  ], $('#w-model').value, (v) => { setSelect($('#w-model'), v); recent('models', v); }, $('#w-root')?.classList.contains('studio')
    ? 'Search the game\'s models above, pick one under On this tile → Props, or import your own on the Models screen.'
    : 'Search the game\'s models above, or import your own on the Models screen.');
}
function renderTexGrid() {
  const box = $('#w-texgrid'); if (!box) return;
  const t = WV.tile, cover = new Map();
  if (t?.ground) { for (const k of t.ground) if (k) cover.set(k - 1, (cover.get(k - 1) || 0) + 1); }
  const pct = (i) => cover.get(i) ? `${Math.max(1, Math.round(cover.get(i) / 163.84))}%` : '';
  const item = (v, note) => ({ value: v, label: fileLabel(v), th: { texture: v }, title: v, note });
  const here = (t?.textures || []).map((v, i) => item(v, pct(i)));
  const seen = new Set(here.map((x) => x.value.toLowerCase()));
  const rec = recent('textures').filter((v) => !seen.has(v.toLowerCase())).map((v) => item(v));
  pickGrid(box, [
    { title: 'On this tile', items: here },
    { title: 'Recently used', items: rec },
    { title: (WV.texFound || []).length ? `Found (${WV.texFound.length})` : '', items: (WV.texFound || []).filter((v) => !seen.has(v.toLowerCase())).slice(0, 60).map((v) => item(v)) },
  ], $('#w-tex').value, (v) => { setSelect($('#w-tex'), v); recent('textures', v); }, 'Search the game\'s ground textures above.');
}
// "On this tile": the ground's textures, the props and buildings, the spawns, with pictures
const IU = { tab: 'ground' };
$$('#iu-tabs button').forEach((b) => b.addEventListener('click', () => { IU.tab = b.dataset.k; $$('#iu-tabs button').forEach((x) => x.classList.toggle('on', x === b)); renderInUse(); }));
function useTool(t) { const b = $(`#w-tools [data-t="${t}"]`); if (b && !b.classList.contains('on')) b.click(); }
function renderInUse() {
  const box = $('#iu-grid'), t = WV.tile; if (!box || !t) return;
  let groups = [], pick = () => {}, empty = '';
  if (IU.tab === 'ground') {
    const cover = new Map();
    for (const k of t.ground || []) if (k) cover.set(k - 1, (cover.get(k - 1) || 0) + 1);
    groups = [{ items: (t.textures || []).map((v, i) => ({ value: v, label: fileLabel(v), th: { texture: v }, title: v, note: cover.get(i) ? `${Math.max(1, Math.round(cover.get(i) / 163.84))}%` : 'under' })) }];
    pick = (v) => { useTool('paint'); setSelect($('#w-tex'), v); recent('textures', v); renderTexGrid(); toast(`Painting with ${fileLabel(v)}: click or drag on the map.`); };
    empty = 'This tile has no ground textures.';
  } else if (IU.tab === 'props' || IU.tab === 'buildings') {
    const list = tileModels(IU.tab);
    groups = [{ items: list.map((x) => ({ value: x.path, label: fileLabel(x.path), th: { model: x.path }, title: x.path, note: `${x.mine ? 'yours ' : ''}×${x.count}` })) }];
    pick = (v) => { useTool('place'); setSelect($('#w-model'), v); recent('models', v); renderModelGrid(); toast(`Placing ${fileLabel(v)}: click the map.`); };
    empty = IU.tab === 'props' ? 'No props on this tile.' : 'No buildings on this tile.';
  } else {
    const m = new Map();
    for (const x of t.spawns || []) { const k = `${x.table}:${x.entry}`; const e = m.get(k) || { ...x, count: 0 }; e.count++; m.set(k, e); }
    groups = [{ items: [...m.values()].map((x) => ({ value: `${x.table}:${x.entry}`, label: x.name, note: `×${x.count}`, glyph: x.table === 'creature' ? '☻' : '▣',
      th: x.display ? (x.table === 'creature' ? { display: x.display } : { object: x.display }) : null })) }];
    pick = (v) => { const [table, entry] = v.split(':'); useTool('spawn'); $('#sp-table').value = table; fillSpawnables(); $('#sp-mine').value = entry; renderSpawnGrid(); toast('Click the map to spawn another.'); };
    empty = 'No spawns of yours on this tile: use the Spawn tool.';
  }
  for (const b of $$('#iu-tabs button')) {
    const n = b.dataset.k === 'ground' ? (t.textures || []).length : b.dataset.k === 'spawns' ? new Set((t.spawns || []).map((x) => x.table + x.entry)).size : tileModels(b.dataset.k).length;
    b.textContent = `${{ ground: 'Ground', props: 'Props', buildings: 'Buildings', spawns: 'Spawns' }[b.dataset.k]} ${n}`;
  }
  pickGrid(box, groups, null, pick, empty);
  $$('.pick', box).forEach((b) => {
    b.addEventListener('mouseenter', () => { WV.hl = { tab: IU.tab, v: b.dataset.v }; drawTile(); });
    b.addEventListener('mouseleave', () => { WV.hl = null; drawTile(); });
  });
}
// the hovered thing, outlined on the map
function drawHighlight(g, s) {
  const t = WV.tile;
  const h = WV.hl || (WV.sels.length ? { tab: 'sel', v: WV.sels } : null); if (!h || !t) return;
  g.save();
  g.strokeStyle = '#f3d189'; g.lineWidth = 2; g.shadowColor = 'rgba(0,0,0,.8)'; g.shadowBlur = 4;
  if (h.tab === 'sel') {
    for (const m of t.mine || []) if (h.v.includes(m.placement.uid)) { g.beginPath(); g.arc(m.u * s, m.v * s, 10, 0, 7); g.stroke(); g.beginPath(); g.arc(m.u * s, m.v * s, 14, 0, 7); g.stroke(); }
  } else if (h.tab === 'ground') {
    const i = (t.textures || []).indexOf(h.v) + 1, cell = MAPW / 128;
    g.fillStyle = 'rgba(243,209,137,.55)'; g.shadowBlur = 0;
    for (let r = 0; r < 128; r++) for (let c = 0; c < 128; c++) if (t.ground[r * 128 + c] === i) g.fillRect(c * cell, r * cell, cell + .5, cell + .5);
  } else if (h.tab === 'spawns') {
    for (const x of t.spawns || []) if (`${x.table}:${x.entry}` === h.v) { g.beginPath(); g.arc(x.u * s, x.v * s, 11, 0, 7); g.stroke(); }
  } else {
    const k = h.v.toLowerCase();
    const ring = (u, v, r) => { g.beginPath(); g.arc(u * s, v * s, r, 0, 7); g.stroke(); };
    for (const d of t.stock || []) if (d.path?.toLowerCase() === k) ring(d.u, d.v, 7);
    for (const b of t.buildings || []) if (b.path?.toLowerCase() === k) g.strokeRect(b.box[0] * s, b.box[1] * s, (b.box[2] - b.box[0]) * s, (b.box[3] - b.box[1]) * s);
    for (const m of t.mine || []) if ((m.path || '').toLowerCase() === k || m.placement.model.toLowerCase() === k) ring(m.u, m.v, 9);
  }
  g.restore();
}
$('#rd-tex').addEventListener('change', () => { $('#rd-sw').innerHTML = $('#rd-tex').value ? thumbHtml({ texture: $('#rd-tex').value }, '▦', 'sw') : ''; fillThumbs($('#rd-sw')); });

// ---- Project: what the pack uses, with pictures ------------------------------------------------
const US = { tab: null, data: null };
const US_TABS = [
  ['models', 'Placed models', 'The props and buildings your pack places: click one to place more on the World screen.'],
  ['textures', 'Painted ground', 'The ground textures your pack paints with: click one to paint with it.'],
  ['creatures', 'Creatures', 'Your creatures, and how many times each is spawned: click one to edit it.'],
  ['items', 'Items', 'Your items: click one to edit it.'],
  ['objects', 'Objects', 'Your objects (chests, signs, doors), and their spawns.'],
  ['own_models', 'Your models', 'Models you imported, and where they\'re used: click one to open it.'],
];
async function loadUsage() {
  if (!S.project) return;
  try { US.data = await api('usage', { dir: S.project.dir }, true); } catch { return; }
  const u = US.data;
  const have = US_TABS.filter(([k]) => (u[k] || []).length);
  $('#usage-panel').hidden = !have.length;
  if (!have.length) return;
  if (!have.some(([k]) => k === US.tab)) US.tab = have[0][0];
  $('#us-tabs').innerHTML = have.map(([k, label]) => `<button data-k="${k}" class="${k === US.tab ? 'on' : ''}">${label} ${u[k].length}</button>`).join('');
  $$('#us-tabs button').forEach((b) => b.addEventListener('click', () => { US.tab = b.dataset.k; loadUsageGrid(); $$('#us-tabs button').forEach((x) => x.classList.toggle('on', x === b)); }));
  loadUsageGrid();
}
function loadUsageGrid() {
  const u = US.data, k = US.tab, plural = (n, w) => `${n} ${w}${n === 1 ? '' : 's'}`;
  $('#us-hint').textContent = (US_TABS.find((x) => x[0] === k) || [])[2] || '';
  let items = [], pick = () => {};
  if (k === 'models') {
    items = u.models.map((m) => ({ value: m.model, label: m.label.replace(/\.(mdx|m2|wmo)$/i, ''), th: { model: m.model }, note: `×${m.count}`, title: `${m.model}\n${plural(m.count, 'placement')} on ${m.maps.join(', ')}` }));
    pick = (v) => { show('world'); useTool('place'); setSelect($('#w-model'), v); recent('models', v); renderModelGrid(); };
  } else if (k === 'textures') {
    items = u.textures.map((t) => ({ value: t.texture, label: t.label, th: { texture: t.texture }, note: plural(t.tiles, 'tile'), title: `${t.texture}\n${plural(t.chunks, 'chunk')} on ${plural(t.tiles, 'tile')}` }));
    pick = (v) => { show('world'); useTool('paint'); setSelect($('#w-tex'), v); recent('textures', v); };
  } else if (k === 'creatures') {
    items = u.creatures.map((c) => ({ value: String(c.entry), label: c.name || '#' + c.entry, th: c.display ? { display: c.display } : null, glyph: '☻', note: c.spawns ? `×${c.spawns}` : '', title: `${c.name} (${c.entry})${c.level ? ', level ' + c.level : ''}\n${c.spawns ? plural(c.spawns, 'spawn') : 'not spawned yet'}` }));
    pick = (v) => { W.want = { kind: 'creature', id: +v }; show('content'); };
  } else if (k === 'items') {
    items = u.items.map((i) => ({ value: String(i.entry), label: i.name, th: i.display ? { item_display: i.display } : null, glyph: '⚔', title: `${i.name} (${i.entry})`, quality: i.quality }));
    pick = (v) => { W.want = { kind: 'item', id: +v }; show('content'); };
  } else if (k === 'objects') {
    items = u.objects.map((o) => ({ value: String(o.entry), label: o.name || '#' + o.entry, th: o.display ? { object: o.display } : null, glyph: '▣', note: o.spawns ? `×${o.spawns}` : '', title: `${o.name} (${o.entry})` }));
    pick = () => { show('data'); };
  } else if (k === 'own_models') {
    items = u.own_models.map((m) => ({ value: m.name, label: m.name, th: m.ported ? { model: 'model:' + m.name } : null, glyph: '◈',
      note: m.placed ? `×${m.placed}` : m.creatures ? `${m.creatures}☻` : '', title: `${m.name} (${m.kind || ''})\n${m.ported ? '' : 'not ported yet\n'}${m.placed ? plural(m.placed, 'placement') + '\n' : ''}${m.creatures ? plural(m.creatures, 'creature') + ' look like it' : ''}` }));
    pick = (v) => { MD.sel = v; show('models'); };
  }
  pickGrid($('#us-grid'), [{ items }], null, pick);
  // items show their quality as the name's colour, as the game does
  const qc = ['#9d9d9d', '#ffffff', '#1eff00', '#0070dd', '#a335ee', '#ff8000'];
  for (const it of items) if (it.quality != null) { const b = $(`#us-grid .pick[data-v="${CSS.escape(it.value)}"] .pl`); if (b) b.style.color = qc[it.quality] || ''; }
}

// ---- the World editor layout: tools down the left, the view in the middle, the tool's settings
// on the right, a toolbar on top and a status bar below (Classic puts it back as it was) -------
const TOOL_ICONS = {
  place: '<path d="M12 3v18M3 12h18"/><circle cx="12" cy="12" r="4"/>',
  scatter: '<circle cx="6" cy="7" r="2"/><circle cx="16" cy="5" r="2"/><circle cx="11" cy="13" r="2"/><circle cx="18" cy="15" r="2"/><circle cx="6" cy="18" r="2"/>',
  prefab: '<rect x="3" y="3" width="8" height="8"/><rect x="13" y="3" width="8" height="8"/><rect x="3" y="13" width="8" height="8"/><path d="M13 17h8M17 13v8"/>',
  spawn: '<circle cx="12" cy="7" r="3.5"/><path d="M5 21c0-4 3-7 7-7s7 3 7 7"/>',
  portal: '<ellipse cx="12" cy="12" rx="6" ry="9"/><ellipse cx="12" cy="12" rx="2.5" ry="5"/>',
  raise: '<path d="M3 20h18M6 20l6-12 6 12"/><path d="M12 3v4M10 5l2-2 2 2"/>',
  lower: '<path d="M3 8h18M6 8l6 12 6-12"/>',
  smooth: '<path d="M3 15c3-6 6-6 9 0s6 6 9 0"/>',
  flatten: '<path d="M3 16h18M6 12h12"/><path d="M3 20h18"/>',
  road: '<path d="M8 21L11 3M16 21L13 3M12 6v2M12 11v2M12 16v2"/>',
  ramp: '<path d="M3 19h18M3 19L19 7v12"/>',
  stamp: '<path d="M7 14h10v3H7zM5 20h14M10 14V9a2 2 0 1 1 4 0v5"/>',
  vsel: '<path d="M4 18l5-6 4 3 7-9"/><circle cx="4" cy="18" r="1.5"/><circle cx="9" cy="12" r="1.5"/><circle cx="13" cy="15" r="1.5"/><circle cx="20" cy="6" r="1.5"/>',
  clip: '<path d="M8 8h11v11H8zM5 16V5h11"/>',
  measure: '<path d="M3 17L17 3l4 4L7 21zM7 13l2 2M10 10l2 2M13 7l2 2"/>',
  script: '<path d="M9 7l-5 5 5 5M15 7l5 5-5 5"/>',
  paint: '<path d="M14 4l6 6-9 9H5v-6z"/><path d="M12 6l6 6"/>',
  water: '<path d="M3 9c2-2 4-2 6 0s4 2 6 0 4-2 6 0M3 15c2-2 4-2 6 0s4 2 6 0 4-2 6 0"/>',
  hole: '<ellipse cx="12" cy="14" rx="8" ry="4"/><path d="M4 14V9M20 14V9"/>',
  area: '<path d="M4 4h16v16H4z" stroke-dasharray="3 2"/><path d="M8 9h8M8 13h5"/>',
  impass: '<circle cx="12" cy="12" r="8"/><path d="M6.5 6.5l11 11"/>',
  light: '<circle cx="12" cy="12" r="4"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M5 5l2 2M17 17l2 2M5 19l2-2M17 7l2-2"/>',
};
const svgIcon = (k) => `<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${TOOL_ICONS[k] || ''}</svg>`;
// number keys pick tools, in the strip's order (1–9, then 0)
const TOOL_KEYS = ['place', 'scatter', 'prefab', 'spawn', 'portal', 'raise', 'lower', 'smooth', 'flatten', 'paint'];
const toolKey = (t) => { const i = TOOL_KEYS.indexOf(t); return i < 0 ? '' : String((i + 1) % 10); };
function buildStrip() {
  const strip = $('#w-strip'); if (!strip) return;
  strip.innerHTML = $$('#w-tools .tg').map((g, gi) => (gi ? '<span class="gap"></span>' : '') + $$('button', g).map((b) =>
    `<button type="button" data-t="${b.dataset.t}" aria-label="${esc(b.textContent)}">${svgIcon(b.dataset.t)}<span>${esc(b.textContent)}${toolKey(b.dataset.t) ? `<kbd>${toolKey(b.dataset.t)}</kbd>` : ''}${b.title ? `<small>${esc(b.title)}</small>` : ''}</span></button>`).join('')).join('');
  $$('button', strip).forEach((b) => b.addEventListener('click', () => { if (walking()) stopWalk(); $(`#w-tools [data-t="${b.dataset.t}"]`).click(); syncStrip(); }));
  syncStrip();
}
function syncStrip() { const on = $('#w-tools button.on')?.dataset.t; $$('#w-strip button').forEach((b) => b.classList.toggle('on', b.dataset.t === on)); }
$$('#w-tools button').forEach((b) => b.addEventListener('click', syncStrip));
buildStrip();
const studioOn = () => { try { return localStorage.getItem('forge.layout') !== 'classic'; } catch { return true; } };
function studioBody() {
  const on = studioOn();
  $('#w-root').classList.toggle('studio', on);
  $('#w-layout').textContent = on ? 'Switch to the classic layout' : 'Switch to the editor layout';
  document.body.classList.toggle('studio-on', on && S.view === 'world');
  fit2d();
}
$('#w-layout').addEventListener('click', () => { try { localStorage.setItem('forge.layout', studioOn() ? 'classic' : 'studio'); } catch {} studioBody(); });
$('#w-v2d').addEventListener('click', () => { $('#w-is3d').checked = false; safe(want3d); });
$('#w-v3d').addEventListener('click', () => { $('#w-is3d').checked = true; safe(want3d); });
$('#w-undo2').addEventListener('click', () => undoWorld());
// the 2D map: the largest square the stage holds
function fit2d() {
  const st = $('#w-stage'), cv = $('#w-canvas'); if (!st || !cv) return;
  if (!$('#w-root').classList.contains('studio')) { cv.style.width = cv.style.height = ''; return; }
  const r = st.getBoundingClientRect(), side = Math.max(200, Math.floor(Math.min(r.width, r.height) - 16));
  cv.style.width = cv.style.height = side + 'px';
}
new ResizeObserver(fit2d).observe($('#w-stage'));
studioBody();
try { if (localStorage.getItem('forge.3d') === '1' && studioOn()) { $('#w-is3d').checked = true; } } catch {}

// the status bar: where the pointer (or the walker) is, the tile, the frame rate
setInterval(() => {
  if (S.view !== 'world' || !WV.tile) return;
  $('#w-tileinfo').textContent = `${WV.tile.map} ${WV.tile.tile[0]}_${WV.tile.tile[1]}`;
  const s3 = WV.t3 && $('#w-is3d').checked ? WV.t3.stats() : null;
  $('#w-fps').textContent = s3 ? `${s3.fps} fps · ${(s3.tris / 1000).toFixed(0)}k triangles` : '2D';
  // slow for a while: say where the faster view is (once a session)
  if (s3 && s3.fps > 0 && s3.fps < 15 && !document.hidden) WV.slow = (WV.slow || 0) + 1; else WV.slow = 0;
  if (WV.slow > 8 && !WV.slowTold && viewNow().distance > VIEW_PRESETS.fast.distance) {
    WV.slowTold = true;
    toast('3D is slow on this PC: View → Fast draws less and moves less.', false, { label: 'Use Fast', run: () => applyView({ ...VIEW_PRESETS.fast }) });
  }
  if (walking()) {
    const w = WV.t3.walker(), p = canvasToWorld({ u: w.u, v: w.v });
    $('#w-statmore').textContent = `walking at X ${p.x.toFixed(1)}  Y ${p.y.toFixed(1)}  Z ${w.y.toFixed(1)}${w.swimming ? ' · swimming' : ''}`;
  } else $('#w-statmore').textContent = s3 ? 'right-drag turns · wheel zooms · middle-drag pans' : '';
}, 400);

// ---- Walk: go in as a character ------------------------------------------------------------------
async function startWalk() {
  if (!WV.tile) { toast('Show a tile first.', true); return; }
  if (!$('#w-is3d').checked) { $('#w-is3d').checked = true; await want3d(); }
  if (!WV.t3) return;
  WV.t3.onWalk(walkEdge, null);
  const t = WV.tile, at = WV.lastPick ? { u: t.origin.y - WV.lastPick.y, v: t.origin.x - WV.lastPick.x } : { u: t.size / 2, v: t.size / 2 };
  WV.t3.walk(true, at);
  walkGround();
  $('#w-walkhud').hidden = false; $('#w-walk').classList.add('on'); $('#w-walk').textContent = '■ Stop walking';
  $('#w-3d').focus?.();
}
// the tile's ground as the game paints it, sharp, for walking on
const walkGround = () => loadSplat();
async function loadSplat() {
  const t = WV.tile; if (!t || !WV.t3) return;
  const img = async (b64) => { const im = new Image(); im.src = 'data:image/png;base64,' + b64; await im.decode(); return im; };
  try {
    // the textures themselves, blended on the graphics card: sharp underfoot
    const r = await api('world_splat', { dir: S.project.dir, map: t.map, a: t.tile[0], b: t.tile[1] }, true);
    const sp = { textures: r.textures, size: r.size, atlas: await img(r.atlas), index: await img(r.index), alpha: await img(r.alpha), shadow: r.shadow ? await img(r.shadow) : null };
    if (WV.tile === t) WV.t3.setSplat(sp);
  } catch {
    // else a big picture of it
    WV.t3.setSplat(null);
    try {
      const r = await api('world_trueground', { dir: S.project.dir, map: t.map, a: t.tile[0], b: t.tile[1], size: 2048, shade: false }, true);
      if (WV.tile === t) WV.t3.setWalkGround(await img(r.png));
    } catch { WV.t3.setWalkGround(null); }
  }
}
function stopWalk() {
  WV.t3?.walk(false);
  $('#w-walkhud').hidden = true; $('#w-walk').classList.remove('on'); $('#w-walk').textContent = '🚶 Walk';
}
$('#w-walk').addEventListener('click', () => safe(async () => { if (walking()) stopWalk(); else await startWalk(); }));
// over a tile's edge: show the next one and go on walking there
async function walkEdge(e) {
  const a = WV.tile.tile[0] + e.da, b = WV.tile.tile[1] + e.db;
  try {
    $('#w-a').value = a; $('#w-b').value = b;
    await showTile();
    if (WV.tile.tile[0] !== a || WV.tile.tile[1] !== b) throw new Error('no tile');
    WV.t3.walkResume({ u: e.u, v: e.v, y: e.y, yaw: e.yaw, look: e.look });
    walkGround();
  } catch {
    const s = WV.tile.size;
    WV.t3.walkResume({ u: Math.max(1, Math.min(s - 1, e.u + e.da * s)), v: Math.max(1, Math.min(s - 1, e.v + e.db * s)), y: e.y, yaw: e.yaw + Math.PI, look: e.look + Math.PI });
    toast('The map ends here.', true);
  }
}
document.addEventListener('keydown', (e) => {
  if (!walking() || isTyping()) return;
  if (e.key === 'Escape') { e.preventDefault(); stopWalk(); }
  if (e.key.toLowerCase() === 't' && !e.ctrlKey) { e.preventDefault(); const w = WV.t3.walker(); testInGame({ u: w.u, v: w.v, h: w.y }, w.yaw); }
});

// ---- Test in game: build, start Play Solo, put your character on this spot -----------------------
function charName() {
  let c = $('#ll-char').value.trim();
  if (!c) { try { c = localStorage.getItem('forge.char') || ''; } catch {} }
  return c;
}
async function askChar() {
  return new Promise((done) => {
    const box = document.createElement('div');
    box.className = 'modal-back';
    box.innerHTML = `<form class="modal panel"><h2>Which character?</h2><p class="hint">The name of a character on the test realm (account <code>solo</code>; your Play Solo characters come along when it's first made). Forge moves it here, online or not: sign in and you're on the spot.</p>
      <input name="c" placeholder="Aldric" required pattern="[A-Za-zÀ-ſ]{2,12}" autofocus><div class="row mt-s"><span class="grow"></span><button type="button" class="btn" data-x>Cancel</button><button class="btn gold">Go</button></div></form>`;
    document.body.appendChild(box);
    const f = $('form', box);
    $('[data-x]', box).addEventListener('click', () => { box.remove(); done(''); });
    f.addEventListener('submit', (e) => { e.preventDefault(); const c = f.c.value.trim(); $('#ll-char').value = c; try { localStorage.setItem('forge.char', c); } catch {} box.remove(); done(c); });
    f.c.focus();
  });
}
async function testInGame(at, yaw = 0) {
  if (!WV.tile) { toast('Show a tile first.', true); return; }
  const st = await api('live_status').catch(() => null);
  if (!st?.setup || st.own) { toast(`Can't test yet: ${st?.why || 'set your Open Vanilla folder on the Test screen'}.`, true); show('test'); return; }
  const character = charName() || await askChar();
  if (!character) return;
  const t = WV.tile;
  const spot = at || (WV.lastPick ? { u: t.origin.y - WV.lastPick.y, v: t.origin.x - WV.lastPick.x } : { u: t.size / 2, v: t.size / 2 });
  const w = canvasToWorld(spot), z = (spot.h ?? w.h) + 1.5;
  // facing: the game's 0 is north (+x), turning left (+y); the walker's yaw 0 faces +u (east, −y)
  const o = (Math.atan2(-Math.cos(yaw), -Math.sin(yaw)) + 2 * Math.PI) % (2 * Math.PI);
  if (!st.running) {
    setStatus('Building your pack for the game…');
    await api('play_install', { dir: S.project.dir });
    await api('play_solo');
    toast('The test realm is starting in its own window. Forge puts your character here as soon as it\'s up.');
    for (let i = 0; i < 90; i++) {
      await new Promise((r) => setTimeout(r, 2000));
      const s2 = await api('live_status', {}, true).catch(() => null);
      if (s2?.running) break;
      setStatus(`Waiting for the test realm… ${i * 2}s`);
      if (i === 89) { toast('The test realm didn\'t come up in 3 minutes: start it from the Test screen, then press Test in game again.', true); return; }
    }
  } else {
    await api('live_apply', { dir: S.project.dir }).catch(() => null);
  }
  const r = await api('live_bring', { dir: S.project.dir, character, map: t.map, x: w.x, y: w.y, z, o });
  toast(/offline/i.test(r || '') ? `${character} will be here when you sign in (account solo).` : (r || `${character} is on the way.`));
  setStatus('Ready.');
}
$('#w-testgame').addEventListener('click', () => safe(() => testInGame(null)));

// ---- the brush: sliders with their numbers, falloff curves, [ and ] for the radius ----------------
const FALLOFFS = {
  flat: [(u) => 1, 'Flat: the same everywhere in the circle'],
  linear: [(u) => 1 - u, 'Linear: a straight slope to the edge'],
  smooth: [(u) => 0.5 * (1 + Math.cos(Math.PI * u)), 'Smooth: soft at the middle and the edge'],
  quadratic: [(u) => 1 - u * u, 'Quadratic: a full middle, a quick edge'],
  trigonometric: [(u) => Math.cos(u * Math.PI / 2), 'Rounded: like a dome'],
  gaussian: [(u) => (Math.exp(-u * u * 4.5) - Math.exp(-4.5)) / (1 - Math.exp(-4.5)), 'Gaussian: a peak that tapers far'],
};
WV.falloff = 'smooth';
try { const b = JSON.parse(localStorage.getItem('forge.brush') || 'null'); if (b) { WV.falloff = FALLOFFS[b.falloff] ? b.falloff : 'smooth'; for (const k of ['radius', 'strength', 'inner']) if (b[k] != null) $('#w-' + k).value = b[k]; } } catch {}
function saveBrush() { try { localStorage.setItem('forge.brush', JSON.stringify({ falloff: WV.falloff, radius: +$('#w-radius').value, strength: +$('#w-strength').value, inner: +$('#w-inner').value })); } catch {} }
function renderFalloffs() {
  const inner = +$('#w-inner').value || 0;
  $('#w-falloff').innerHTML = Object.entries(FALLOFFS).map(([k, [f, t]]) => {
    const pts = [];
    for (let i = 0; i <= 24; i++) { const x = i / 24, u = x <= inner ? 0 : (x - inner) / (1 - inner); pts.push(`${(2 + x * 40).toFixed(1)},${(22 - f(Math.min(1, u)) * 18).toFixed(1)}`); }
    return `<button type="button" role="radio" aria-checked="${k === WV.falloff}" class="${k === WV.falloff ? 'on' : ''}" data-f="${k}" title="${esc(t)}"><svg viewBox="0 0 44 26" width="44" height="26"><polyline points="${pts.join(' ')}" fill="none" stroke="currentColor" stroke-width="1.8"/></svg></button>`;
  }).join('');
  $$('#w-falloff button').forEach((b) => b.addEventListener('click', () => { WV.falloff = b.dataset.f; saveBrush(); renderFalloffs(); }));
}
for (const r of $$('.slider input[type=range][data-for]')) {
  const n = $('#' + r.dataset.for);
  r.value = n.value;
  r.addEventListener('input', () => { n.value = r.value; saveBrush(); if (r.dataset.for === 'w-inner') renderFalloffs(); if (lastEv) { drawTile(); drawBrush(lastEv); redrape3d(); } });
  n.addEventListener('input', () => { r.value = n.value; saveBrush(); if (r.dataset.for === 'w-inner') renderFalloffs(); });
}
renderFalloffs();
document.addEventListener('keydown', (e) => {
  if (S.view !== 'world' || walking() || isTyping() || e.ctrlKey || e.metaKey || e.altKey) return;
  if (e.key === '[' || e.key === ']') {
    const n = $('#w-radius'), v = Math.max(2, Math.min(200, Math.round((+n.value || 20) * (e.key === ']' ? 1.15 : 0.87))));
    n.value = v; $('.slider [data-for="w-radius"]').value = v; saveBrush();
    if (lastEv) { drawTile(); drawBrush(lastEv); redrape3d(); }
    e.preventDefault();
  }
  if (WV.tool === 'clip' && !clipCopying() && ['r', 'm'].includes(e.key.toLowerCase())) { if (e.key.toLowerCase() === 'r') clipTurn(e.shiftKey ? -1 : 1); else clipMirror(); e.preventDefault(); }
  if (WV.tool === 'stamp' && e.key.toLowerCase() === 'r') {
    const t = $('#st-turn'); t.value = ((+t.value || 0) + (e.shiftKey ? -15 : 15) + 360) % 360; if (WV.tile) drawTile(); e.preventDefault();
  }
});

// ---- World shortcuts: 1–0 tools, Tab hides the panels, F7 lines, Shift+F2 slope, T test in game -----
document.addEventListener('keydown', (e) => {
  if (S.view !== 'world' || walking() || isTyping() || e.ctrlKey || e.metaKey || e.altKey) return;
  const k = e.key;
  if (/^[0-9]$/.test(k) && !e.shiftKey) {
    const t = TOOL_KEYS[(+k + 9) % 10];
    if (t) { $(`#w-tools [data-t="${t}"]`)?.click(); syncStrip(); e.preventDefault(); }
  } else if (k === 'Tab' && studioOn()) {
    e.preventDefault(); $('#w-root').classList.toggle('bare'); fit2d();
  } else if (k === 'F7') {
    e.preventDefault(); const on = !WV.t3?.overlays().lines; WV.t3?.setOverlay('lines', on); toast(on ? 'Chunk lines on (F7): red chunks, green tile edges.' : 'Chunk lines off.');
  } else if (k === 'F2' && e.shiftKey) {
    e.preventDefault(); const on = !WV.t3?.overlays().slope; WV.t3?.setOverlay('slope', on); toast(on ? 'Slope on (Shift+F2): red is too steep to walk up.' : 'Slope off.');
  } else if (k.toLowerCase() === 't' && !e.shiftKey) {
    e.preventDefault(); safe(() => testInGame(null));
  } else if (k.toLowerCase() === 'b' && !e.shiftKey) {
    e.preventDefault(); $('#w-bmbtn').click();
  } else if (k.toLowerCase() === 'n' && !e.shiftKey && !(WV.tool === 'clip')) {
    e.preventDefault(); const off = $('#w-nav').classList.toggle('off'); try { localStorage.setItem('forge.nav', off ? 'off' : 'on'); } catch {}
  }
});
try { if (localStorage.getItem('forge.nav') === 'off') $('#w-nav').classList.add('off'); } catch {}

// ---- the tiles around the one you're on, in 3D: fetched in the background, kept while you move ----
WV.nb = new Map();   // "map_a_b" → { tile, splat } (or { none: true } where there's no tile)
WV.far = new Map();  // "map_a_b" → { heights, water, image }: the ring two tiles out
let nbTimer = 0, nbGen = 0;
function neighboursSoon() { clearTimeout(nbTimer); nbTimer = setTimeout(() => safeQuiet(loadNeighbours), 400); }
const safeQuiet = (f) => f().catch(() => {});
async function loadNeighbours() {
  const t = WV.tile; if (!t || !WV.t3 || !$('#w-is3d').checked) return;
  const gen = ++nbGen, [ca, cb] = t.tile, map = t.map;
  const keys = [];
  for (let db = -1; db <= 1; db++) for (let da = -1; da <= 1; da++) if (da || db) keys.push([ca + da, cb + db]);
  const img = async (b64) => { const im = new Image(); im.src = 'data:image/png;base64,' + b64; await im.decode(); return im; };
  const show = () => {
    const list = [];
    for (const [a, b] of keys) { const n = WV.nb.get(`${map}_${a}_${b}`); if (n && !n.none) list.push({ key: `${map}_${a}_${b}`, a, b, tile: n.tile, splat: n.splat }); }
    WV.t3.setNeighbours(list, { a: ca, b: cb });
  };
  show();
  // the ring past them, far off and simple (after the near ones)
  const ring = [];
  for (let db = -2; db <= 2; db++) for (let da = -2; da <= 2; da++) if (Math.max(Math.abs(da), Math.abs(db)) === 2) ring.push([ca + da, cb + db]);
  const showFar = () => {
    const list = [];
    for (const [a, b] of ring) { const n = WV.far.get(`${map}_${a}_${b}`); if (n && !n.none) list.push({ key: `${map}_${a}_${b}`, a, b, far: n }); }
    WV.t3.setFar?.(list, { a: ca, b: cb });
  };
  const loadFar = async () => {
    showFar();
    for (const [a, b] of ring) {
      const key = `${map}_${a}_${b}`;
      if (WV.far.has(key)) continue;
      try { const f = await api('world_far', { dir: S.project.dir, map, a, b, size: 128 }, true); f.image = await img(f.png); delete f.png; WV.far.set(key, f); }
      catch { WV.far.set(key, { none: true }); }
      if (gen !== nbGen || WV.tile !== t) return;
      showFar();
    }
  };
  // the far ring is quick (a few heights and a small picture): it comes in alongside
  safeQuiet(loadFar);
  for (const [a, b] of keys) {
    const key = `${map}_${a}_${b}`;
    if (WV.nb.has(key)) continue;
    try {
      const tile = await api('world_tile', { dir: S.project.dir, map, a, b }, true);
      let splat = null;
      try {
        const r = await api('world_splat', { dir: S.project.dir, map, a, b }, true);
        splat = { textures: r.textures, size: r.size, atlas: await img(r.atlas), index: await img(r.index), alpha: await img(r.alpha), shadow: r.shadow ? await img(r.shadow) : null };
      } catch { /* plain ground */ }
      WV.nb.set(key, { tile, splat });
    } catch { WV.nb.set(key, { none: true }); }
    if (gen !== nbGen || WV.tile !== t) return;
    show();
  }
}

// ---- Back to Forge: a /forge mark in the game brings you to that spot here ------------------------
async function goToMark(m) {
  show('world'); await loadWorld();
  const opt = $$('#w-map option').find((o) => o.textContent.trim().startsWith(m.map + ' ·'));
  if (opt) $('#w-map').value = opt.value;
  const HALF = 17066.666666, TILE = 533.33333;
  $('#w-a').value = Math.floor((HALF - m.y) / TILE); $('#w-b').value = Math.floor((HALF - m.x) / TILE);
  WV.mark = { x: +m.x, y: +m.y, z: +m.z }; WV.lastPick = { x: +m.x, y: +m.y, h: +m.z };
  await showTile();
  const t = WV.tile;
  if (t && WV.t3 && $('#w-is3d').checked) WV.t3.focus(t.origin.y - m.y, t.origin.x - m.x);
}
const LL = { last: null };
setInterval(async () => {
  if (!S.project || document.hidden) return;
  const st = await api('live_status', {}, true).catch(() => null);
  livePill(st);
  if (!st?.running || !st.mark) return;
  const k = JSON.stringify(st.mark);
  if (LL.last === null) { LL.last = k; return; }
  if (k === LL.last) return;
  LL.last = k;
  const m = st.mark;
  toast(`${m.char || 'You'} marked ${m.zone || 'a spot'} in the game${m.target ? `, at ${m.target}` : ''}.`, false, { label: 'Show in Forge', run: () => goToMark(m) });
}, 6000);

// the realm's state in the World toolbar: off, or up (click: send your changes to it now)
function livePill(st) {
  const b = $('#w-live'); if (!b) return;
  const up = !!st?.running;
  b.classList.toggle('up', up);
  b.textContent = up ? '● Realm up · Apply' : st?.setup === false ? '○ Realm not set up' : '○ Realm off';
  b.textContent = st?.own ? '○ Your Play Solo is on' : b.textContent;
  b.title = up ? 'Forge\'s test realm is running: click to send your changes to it now (rows reload live; the ground and new art need a relog)' : st?.own ? 'Your own Play Solo is running. Forge tests in its own copy: close yours first.' : 'Forge\'s test realm (a copy of your Play Solo): Test in game starts it';
}
$('#w-live').addEventListener('click', () => safe(async () => {
  if (!$('#w-live').classList.contains('up')) { await testInGame(null); return; }
  const r = await api('live_apply', { dir: S.project.dir });
  toast(`${r.reloaded.length ? 'Live now: ' + r.reloaded.join(', ') + '.' : 'Sent.'}${r.restart.length ? ` After a relog: ${r.restart.join(', ')}.` : ''}`);
}));
api('live_status', {}, true).then(livePill).catch(() => livePill(null));

// ---- texture swap: one of the tile's textures becomes the picked one ------------------------------
WV.swapFrom = null;
function renderSwapGrid() {
  const t = WV.tile, box = $('#w-swapgrid'); if (!t || !box) return;
  if (WV.swapFrom && !(t.textures || []).includes(WV.swapFrom)) WV.swapFrom = null;
  pickGrid(box, [{ items: (t.textures || []).map((v) => ({ value: v, label: fileLabel(v), th: { texture: v }, title: v })) }], WV.swapFrom, (v) => { WV.swapFrom = v; });
}
$('#w-swap').addEventListener('toggle', renderSwapGrid);
$('#w-swaptile').addEventListener('click', () => safe(async () => {
  const to = $('#w-tex').value, t = WV.tile;
  if (!WV.swapFrom) { toast('Pick the texture to swap out, in the grid above.', true); return; }
  if (!to) { toast('Pick the texture to swap in, under Paint.', true); return; }
  await checkpoint('swap texture');
  const r = await api('world_swap', { dir: S.project.dir, map: t.map, a: t.tile[0], b: t.tile[1], from: WV.swapFrom, to });
  toast(`${fileLabel(WV.swapFrom)} → ${fileLabel(to)} in ${r.chunks} chunk${r.chunks === 1 ? '' : 's'}.`);
  WV.swapFrom = null;
  await showTile(); renderSwapGrid();
}));

// ---- the selection: one or many of your models; handles in 3D, numbers on the right, copy/paste ----
WV.sel = null; WV.sels = []; WV.clip = null;
const placementsHere = () => (WV.info?.placements || {})[WV.tile?.map] || [];
function selPlacement() { return placementsHere().find((p) => p.uid === WV.sel) || null; }
// uid null: nothing; add: Shift/Ctrl-click adds or takes away; a list: exactly those
$('#w-shadowclear').addEventListener('click', () => safe(async () => {
  const t = WV.tile; if (!t) return;
  await checkpoint('clear shadows');
  const n = await api('world_shadows_clear', { dir: S.project.dir, map: t.map, a: t.tile[0], b: t.tile[1] });
  toast(`Cleared the baked shadows of ${n} chunk${n === 1 ? '' : 's'}.`); WV.tileRev = (WV.tileRev || 0) + 1; await showTile();
}));
$('#w-texoff').addEventListener('click', () => safe(async () => {
  const t = WV.tile, tex = $('#w-tex').value;
  if (!t || !tex) { toast('Pick one of the tile\'s textures first.', true); return; }
  if (!armed('tex-off', `Click again to take ${tex.split('\\').pop()} off this tile.`)) return;
  await checkpoint('take texture off');
  const n = await api('world_remove_texture', { dir: S.project.dir, map: t.map, a: t.tile[0], b: t.tile[1], texture: tex });
  toast(n ? `Taken off ${n} chunk${n === 1 ? '' : 's'}${n < 256 ? ' (where it was the only texture, it stays)' : ''}.` : 'It\'s the only texture wherever it is: nothing to show under it.');
  WV.tileRev = (WV.tileRev || 0) + 1; await showTile();
}));

// measure: two points, how far (straight and along the ground), how much higher, how steep
WV.meas = [];
function heightAtLocal(u, v) {
  const t = WV.tile, N = 129, gx = Math.max(0, Math.min(128, u / t.size * 128)), gz = Math.max(0, Math.min(128, v / t.size * 128));
  const i = Math.min(127, Math.floor(gz)), j = Math.min(127, Math.floor(gx)), fz = gz - i, fx = gx - j, H = t.heights;
  return (H[i * N + j] * (1 - fx) + H[i * N + j + 1] * fx) * (1 - fz) + (H[(i + 1) * N + j] * (1 - fx) + H[(i + 1) * N + j + 1] * fx) * fz;
}
function measureClick(e) {
  const w = canvasToWorld(e);
  if (WV.meas.length >= 2) WV.meas = [];
  WV.meas.push(w); measureShow(); drawTile();
}
function measureShow() {
  const m = WV.meas, out = $('#ms-out');
  if (m.length < 2) { out.innerHTML = m.length ? '<span class="hint">Now the second point.</span>' : '<span class="hint">Click two points.</span>'; return; }
  const [a, b] = m.map(localOf), flat = Math.hypot(b.u - a.u, b.v - a.v), ha = heightAtLocal(a.u, a.v), hb = heightAtLocal(b.u, b.v);
  let along = 0, prev = ha; const n = Math.max(8, Math.ceil(flat / 2));
  for (let k = 1; k <= n; k++) { const t = k / n, h = heightAtLocal(a.u + (b.u - a.u) * t, a.v + (b.v - a.v) * t); along += Math.hypot(flat / n, h - prev); prev = h; }
  const rise = hb - ha, slope = Math.atan2(Math.abs(rise), flat) * 180 / Math.PI;
  // about 7 yards a second on foot (the game's run speed)
  out.innerHTML = `<div class="ms"><b>${flat.toFixed(1)}</b><span>yards apart</span></div><div class="ms"><b>${along.toFixed(1)}</b><span>along the ground · ${(along / 7).toFixed(0)} s on foot</span></div>
    <div class="ms"><b>${rise >= 0 ? '+' : ''}${rise.toFixed(1)}</b><span>yards higher</span></div><div class="ms"><b>${slope.toFixed(0)}°</b><span>${slope > 50 ? 'too steep to walk up' : 'slope'}</span></div>`;
}
function drawMeasure(g, s) {
  const m = WV.meas.map(localOf); if (!m.length) return;
  const end = m[1] || WV.mouseLocal; if (!end) return;
  g.save(); g.strokeStyle = '#8ab4e8'; g.lineWidth = 2; g.setLineDash([6, 4]);
  g.beginPath(); g.moveTo(m[0].u * s, m[0].v * s); g.lineTo(end.u * s, end.v * s); g.stroke(); g.setLineDash([]);
  for (const p of [m[0], end]) { g.fillStyle = '#8ab4e8'; g.beginPath(); g.arc(p.u * s, p.v * s, 4, 0, 7); g.fill(); }
  const d = Math.hypot(end.u - m[0].u, end.v - m[0].v);
  g.font = '600 12px system-ui'; g.fillStyle = '#e8e1d3'; g.strokeStyle = 'rgba(0,0,0,.7)'; g.lineWidth = 3;
  const tx = (m[0].u + end.u) / 2 * s + 6, ty = (m[0].v + end.v) / 2 * s - 6, label = `${d.toFixed(1)} yd`;
  g.strokeText(label, tx, ty); g.fillText(label, tx, ty); g.restore();
}

// the view's settings: presets, sliders and switches; kept on this PC
const VIEW_PRESETS = {
  fast: { distance: 900, detail: 140, neighbours: true, far: false, particles: false, animate: false },
  balanced: { distance: 1700, detail: 260, neighbours: true, far: true, particles: true, animate: true },
  beautiful: { distance: 3000, detail: 700, neighbours: true, far: true, particles: true, animate: true },
};
function viewNow() { try { return { ...VIEW_PRESETS.balanced, ...JSON.parse(localStorage.getItem('forge.view') || '{}') }; } catch { return { ...VIEW_PRESETS.balanced }; } }
function applyView(v, save = true) {
  WV.t3?.setViewSettings(v);
  if (save) try { localStorage.setItem('forge.view', JSON.stringify(v)); } catch {}
  $('#vw-dist').value = v.distance; $('#vw-distv').textContent = `${v.distance} yd`;
  $('#vw-detail').value = v.detail; $('#vw-detailv').textContent = `${v.detail} yd`;
  $('#vw-nb').checked = v.neighbours; $('#vw-far').checked = v.far; $('#vw-parts').checked = v.particles; $('#vw-anim').checked = v.animate;
  const p = Object.entries(VIEW_PRESETS).find(([, x]) => Object.keys(x).every((k) => x[k] === v[k]))?.[0];
  $$('#vw-preset button').forEach((b) => b.classList.toggle('on', b.dataset.p === p));
}
$('#vw-preset').addEventListener('click', (e) => { const b = e.target.closest('[data-p]'); if (b) applyView({ ...VIEW_PRESETS[b.dataset.p] }); });
for (const [id, k, num] of [['#vw-dist', 'distance', 1], ['#vw-detail', 'detail', 1], ['#vw-nb', 'neighbours'], ['#vw-far', 'far'], ['#vw-parts', 'particles'], ['#vw-anim', 'animate']]) {
  $(id).addEventListener('input', () => applyView({ ...viewNow(), [k]: num ? +$(id).value : $(id).checked }));
}
$('#w-viewbtn').addEventListener('click', (e) => {
  e.stopPropagation(); const h = $('#w-view'); h.hidden = !h.hidden;
  if (!h.hidden) { applyView(viewNow(), false); const st = WV.t3?.stats(); $('#vw-fps').textContent = st ? `${st.fps} frames a second now, ${Math.round(st.tris / 1000)}k triangles.` : 'Settings for the 3D view.'; }
});
document.addEventListener('click', (e) => { if (!e.target.closest?.('.viewwrap')) $('#w-view').hidden = true; });

// spots: places to come back to (map, tile, and the 3D view), kept in the pack's .forge folder
async function renderBookmarks() {
  const list = await api('world_bookmarks', { dir: S.project.dir }, true);
  WV.bms = Array.isArray(list) ? list : [];
  $('#w-bm').innerHTML = `<form id="bm-form" class="row" style="gap:6px;padding:4px"><input id="bm-name" placeholder="Name this spot" maxlength="80" style="flex:1"><button class="btn small gold" type="submit">Save</button></form>`
    + (WV.bms.length ? `<div class="hh">Spots</div>` + WV.bms.map((b, i) => `<div class="bmrow"><button type="button" data-go="${i}"><span>${esc(b.name)}</span><span class="meta">${esc(b.map)} ${b.a}_${b.b}</span></button><button type="button" class="bmdel" data-del="${i}" title="Forget it">×</button></div>`).join('')
      : '<p class="hint" style="padding:4px 8px">None yet: name this spot and Save.</p>');
  $('#bm-form').addEventListener('submit', (e) => { e.preventDefault(); safe(saveBookmark); });
  $$('#w-bm [data-go]').forEach((b) => b.addEventListener('click', () => safe(() => goBookmark(WV.bms[+b.dataset.go]))));
  $$('#w-bm [data-del]').forEach((b) => b.addEventListener('click', (e) => { e.stopPropagation(); safe(async () => { WV.bms.splice(+b.dataset.del, 1); await api('world_bookmarks_save', { dir: S.project.dir, list: WV.bms }); renderBookmarks(); }); }));
  setTimeout(() => $('#bm-name')?.focus(), 0);
}
async function saveBookmark() {
  const t = WV.tile; if (!t) { toast('Show a tile first.', true); return; }
  const name = $('#bm-name').value.trim() || `${t.map} ${t.tile[0]}_${t.tile[1]}`;
  const is3d = $('#w-is3d').checked && WV.t3;
  WV.bms = [{ name, map: t.map, a: t.tile[0], b: t.tile[1], view: is3d ? WV.t3.getView() : null, pick: WV.lastPick || null }, ...(WV.bms || []).filter((b) => b.name !== name)];
  await api('world_bookmarks_save', { dir: S.project.dir, list: WV.bms });
  toast(`Saved “${name}”.`); renderBookmarks();
}
async function goBookmark(b) {
  if (!b) return;
  $('#w-bm').hidden = true;
  const opt = $$('#w-map option').find((o) => o.value === b.map); if (opt) $('#w-map').value = b.map;
  $('#w-a').value = b.a; $('#w-b').value = b.b;
  await showTile();
  if (b.pick) WV.lastPick = b.pick;
  if (b.view && WV.t3 && $('#w-is3d').checked) setTimeout(() => WV.t3.setView(b.view), 300);
}
$('#w-bmbtn').addEventListener('click', (e) => { e.stopPropagation(); const h = $('#w-bm'); h.hidden = !h.hidden; if (!h.hidden) safe(renderBookmarks); });
document.addEventListener('click', (e) => { if (!e.target.closest?.('.bmwrap')) $('#w-bm').hidden = true; });

// the navigator: the 5 × 5 tiles around this one, small, in the view's corner; click one to go
WV.navPics = new Map();
const NAV = 5, NAVC = 36;
async function renderNav() {
  const t = WV.tile, cv = $('#w-navc'); if (!t || !cv) return;
  const g = cv.getContext('2d'), [ca, cb] = t.tile, map = t.map, mine = WV.navFor = `${map}_${ca}_${cb}`;
  const draw = () => {
    g.fillStyle = '#0d0c0b'; g.fillRect(0, 0, cv.width, cv.height);
    for (let j = 0; j < NAV; j++) for (let i = 0; i < NAV; i++) {
      const a = ca + i - 2, b = cb + j - 2, pic = WV.navPics.get(`${map}_${a}_${b}`);
      // a (file x) runs across, b (file z) down: as the map draws it
      if (pic && pic !== 'none') g.drawImage(pic, i * NAVC, j * NAVC, NAVC, NAVC);
      else { g.fillStyle = pic === 'none' ? '#141210' : '#1d1a15'; g.fillRect(i * NAVC + 1, j * NAVC + 1, NAVC - 2, NAVC - 2); }
    }
    g.strokeStyle = 'rgba(0,0,0,.45)'; g.lineWidth = 1;
    for (let k = 1; k < NAV; k++) { g.beginPath(); g.moveTo(k * NAVC + .5, 0); g.lineTo(k * NAVC + .5, cv.height); g.moveTo(0, k * NAVC + .5); g.lineTo(cv.width, k * NAVC + .5); g.stroke(); }
    g.strokeStyle = '#f3d189'; g.lineWidth = 2; g.strokeRect(2 * NAVC + 1, 2 * NAVC + 1, NAVC - 2, NAVC - 2);
    if (WV.lastPick) { const u = (t.origin.y - WV.lastPick.y) / t.size, v = (t.origin.x - WV.lastPick.x) / t.size; g.fillStyle = '#f3d189'; g.beginPath(); g.arc((2 + u) * NAVC, (2 + v) * NAVC, 2.5, 0, 7); g.fill(); }
  };
  draw();
  $('#w-navlbl').textContent = `${map} ${ca}_${cb}`;
  const img = (b64) => new Promise((ok) => { const im = new Image(); im.onload = () => ok(im); im.onerror = () => ok('none'); im.src = 'data:image/png;base64,' + b64; });
  for (let j = 0; j < NAV; j++) for (let i = 0; i < NAV; i++) {
    const a = ca + i - 2, b = cb + j - 2, key = `${map}_${a}_${b}`;
    if (WV.navPics.has(key)) continue;
    const far = WV.far.get(key);
    if (far?.image) { WV.navPics.set(key, far.image); continue; }
    try { const r = await api('world_far', { dir: S.project.dir, map, a, b, size: 64 }, true); WV.navPics.set(key, await img(r.png)); }
    catch { WV.navPics.set(key, 'none'); }
    if (WV.navFor !== mine) return;
    draw();
  }
  draw();
}
$('#w-navc').addEventListener('click', (e) => {
  const t = WV.tile; if (!t) return;
  const r = e.currentTarget.getBoundingClientRect(), i = Math.floor((e.clientX - r.left) / r.width * NAV), j = Math.floor((e.clientY - r.top) / r.height * NAV);
  const a = t.tile[0] + i - 2, b = t.tile[1] + j - 2;
  if (WV.navPics.get(`${t.map}_${a}_${b}`) === 'none') { toast('No tile there.', true); return; }
  if (a === t.tile[0] && b === t.tile[1]) return;
  $('#w-a').value = a; $('#w-b').value = b; safe(showTile);
});
$('#w-navc').addEventListener('mousemove', (e) => {
  const t = WV.tile; if (!t) return;
  const r = e.currentTarget.getBoundingClientRect(), i = Math.floor((e.clientX - r.left) / r.width * NAV), j = Math.floor((e.clientY - r.top) / r.height * NAV);
  $('#w-navlbl').textContent = `${t.map} ${t.tile[0] + i - 2}_${t.tile[1] + j - 2}`;
});
$('#w-navc').addEventListener('mouseleave', () => { const t = WV.tile; if (t) $('#w-navlbl').textContent = `${t.map} ${t.tile[0]}_${t.tile[1]}`; });

// the game's own doodads and buildings: make one yours (a copy you can move; theirs hidden) or hide it
function pickGameObject(x) {
  selectPlacement(null);
  WV.game = x;
  const name = x.path.split('\\').pop().replace(/\.(mdx|m2|wmo)$/i, '');
  $('#wg-name').innerHTML = `${thumbHtml({ model: x.path }, '◆', 'sm')}<b>${esc(name)}</b>`;
  fillThumbs($('#wg-name'));
  $('#w-gamebox').hidden = false;
  if (WV.tile) drawTile();
}
function gameDone() { WV.game = null; $('#w-gamebox').hidden = true; if (WV.tile) drawTile(); }
function hiddenLine() {
  const t = WV.tile, n = t ? [...(t.stock || []), ...(t.buildings || [])].filter((d) => d.hidden).length : 0;
  $('#w-hiddenline').hidden = !n || WV.tool !== 'place';
  $('#wg-count').textContent = `${n} of the game's own hidden on this tile.`;
}
$('#wg-close').addEventListener('click', gameDone);
$('#wg-take').addEventListener('click', () => safe(async () => {
  const x = WV.game; if (!x) return;
  await checkpoint('make it yours');
  const t = WV.tile, r = await api('world_pickup', { dir: S.project.dir, map: t.map, a: t.tile[0], b: t.tile[1], uids: [x.uid] });
  gameDone(); WV.tileRev = (WV.tileRev || 0) + 1; WV.nb.clear();
  WV.info = await api('world_list', { dir: S.project.dir }); renderWorldList(); await showTile();
  selectPlacement(r.map((p) => p.uid)); toast('Yours now: move, turn, lean or size it.');
}));
$('#wg-hide').addEventListener('click', () => safe(async () => {
  const x = WV.game; if (!x) return;
  await checkpoint('hide');
  const t = WV.tile; await api('world_hide', { dir: S.project.dir, map: t.map, a: t.tile[0], b: t.tile[1], uids: [x.uid], hide: true });
  gameDone(); WV.tileRev = (WV.tileRev || 0) + 1; WV.nb.clear(); await showTile(); toast('Hidden. It stays out of your pack\'s world (Show them again brings it back).');
}));
$('#wg-showall').addEventListener('click', () => safe(async () => {
  const t = WV.tile, uids = [...(t.stock || []), ...(t.buildings || [])].filter((d) => d.hidden).map((d) => d.uid);
  if (!uids.length) return;
  await checkpoint('show hidden');
  await api('world_hide', { dir: S.project.dir, map: t.map, a: t.tile[0], b: t.tile[1], uids, hide: false });
  WV.tileRev = (WV.tileRev || 0) + 1; WV.nb.clear(); await showTile();
}));

function selectPlacement(uid, add = false) {
  if (Array.isArray(uid)) WV.sels = [...new Set(uid)];
  else if (uid == null) WV.sels = [];
  else if (add) WV.sels = WV.sels.includes(uid) ? WV.sels.filter((u) => u !== uid) : [...WV.sels, uid];
  else WV.sels = [uid];
  WV.sel = WV.sels[WV.sels.length - 1] ?? null;
  WV.t3?.select(WV.sels);
  renderSel();
  if (WV.tile) drawTile();
}
$$('#w-tools button').forEach((b) => b.addEventListener('click', () => { if (b.dataset.t !== 'place' && WV.sels.length) selectPlacement(null); }));
function renderSel() {
  const box = $('#w-selbox'), list = placementsHere().filter((p) => WV.sels.includes(p.uid)), p = selPlacement();
  box.hidden = !list.length;
  if (!list.length) return;
  const many = list.length > 1, wmo = /\.wmo$/i.test(p.model);
  $('#ws-name').innerHTML = many
    ? `<span class="stack">${list.slice(0, 4).map((x) => thumbHtml({ model: x.model }, '◆', 'sm')).join('')}</span><span><b>${list.length} selected</b><br><span class="meta">${[...new Set(list.map((x) => fileLabel(x.model)))].slice(0, 3).join(', ')}${list.length > 3 ? '…' : ''}</span></span>`
    : `${thumbHtml({ model: p.model }, '◆', 'sm')}<span><b>${esc(fileLabel(p.model))}</b><br><span class="meta">${wmo ? 'building' : 'prop'} · ${p.uid}</span></span>`;
  fillThumbs($('#ws-name'));
  $('#ws-nums').hidden = many;
  if (!many) for (const k of ['x', 'y', 'z', 'turn', 'scale']) { const i = $('#ws-' + k); if (document.activeElement !== i) i.value = (+p[k]).toFixed(k === 'scale' ? 2 : 1); }
  if (!many) for (const k of [0, 1]) { const i = $('#ws-tilt' + k); if (document.activeElement !== i) i.value = (+(p.tilt?.[k] || 0)).toFixed(1); }
  $('#ws-scale').disabled = wmo;
  $('#ws-setl').hidden = true;
  if (!many && wmo && WV.t3) {
    const path = WV.tile?.mine?.find((m) => m.placement.uid === p.uid)?.path;
    if (path) WV.t3.setsFor(path).then((sets) => {
      if (sets.length < 2 || WV.sel !== p.uid) return;
      $('#ws-set').innerHTML = sets.map((x, i) => `<option value="${i}">${i ? esc(x.name.replace(/^set_?/i, '').replace(/_/g, ' ')) : 'Only the usual'} (${x.doodads.length})</option>`).join('');
      $('#ws-set').value = p.set || 0; $('#ws-setl').hidden = false;
    });
  }
  $('#ws-paste').disabled = !WV.clip;
}
async function afterMove() {
  WV.info = await api('world_list', { dir: S.project.dir });
  renderWorldList();
  await showTile();
  WV.t3?.select(WV.sels);
  renderSel();
}
async function movePlacement(fields) {
  if (!WV.sel || !WV.tile) return;
  await checkpoint('move');
  await api('world_move', { dir: S.project.dir, map: WV.tile.map, uid: WV.sel, ...fields });
  await afterMove();
}
// letting go of the handles: every selected model's new spot, in world coordinates
function wireGizmo() {
  WV.t3?.onGizmo((list) => safe(async () => {
    const t = WV.tile;
    await checkpoint(list.length > 1 ? `move ${list.length}` : 'move');
    await api('world_move_many', { dir: S.project.dir, map: t.map, moves: list.map((g) => ({ uid: g.uid, x: t.origin.x - g.v, y: t.origin.y - g.u, z: g.h, turn: g.yaw, scale: g.scale })) });
    await afterMove();
  }));
}
$$('#ws-mode button').forEach((b) => b.addEventListener('click', () => {
  $$('#ws-mode button').forEach((x) => x.classList.toggle('on', x === b));
  WV.t3?.setGizmoMode(b.dataset.m);
}));
for (const k of ['x', 'y', 'z', 'turn', 'scale']) $('#ws-' + k).addEventListener('change', (e) => safe(() => movePlacement({ [k]: +e.target.value })));
$('#ws-set').addEventListener('change', () => safe(() => movePlacement({ set: +$('#ws-set').value })));
for (const k of [0, 1]) $('#ws-tilt' + k).addEventListener('change', () => safe(() => movePlacement({ tilt: [+$('#ws-tilt0').value || 0, +$('#ws-tilt1').value || 0] })));
const groundUnder = (p) => {
  const t = WV.tile, u = t.origin.y - p.y, v = t.origin.x - p.x;
  const i = Math.max(0, Math.min(128, Math.round(v / t.size * 128))), j = Math.max(0, Math.min(128, Math.round(u / t.size * 128)));
  return t.heights[i * 129 + j];
};
$('#ws-ground').addEventListener('click', () => safe(async () => {
  const list = placementsHere().filter((p) => WV.sels.includes(p.uid)); if (!list.length) return;
  await checkpoint('onto the ground');
  await api('world_move_many', { dir: S.project.dir, map: WV.tile.map, moves: list.map((p) => ({ uid: p.uid, z: groundUnder(p) })) });
  await afterMove();
}));
$('#ws-del').addEventListener('click', () => safe(async () => {
  if (!WV.sels.length) return;
  await checkpoint(WV.sels.length > 1 ? `delete ${WV.sels.length}` : 'delete');
  await api('world_remove_many', { dir: S.project.dir, map: WV.tile.map, uids: WV.sels });
  selectPlacement(null); WV.info = await api('world_list', { dir: S.project.dir }); renderWorldList(); await showTile();
}));
// copy: the selection, as offsets from its middle; paste: at the cursor, with a little variety
function copySel() {
  const list = placementsHere().filter((p) => WV.sels.includes(p.uid)); if (!list.length) return;
  const cx = list.reduce((a, p) => a + p.x, 0) / list.length, cy = list.reduce((a, p) => a + p.y, 0) / list.length;
  WV.clip = list.map((p) => ({ model: p.model, dx: p.x - cx, dy: p.y - cy, turn: p.turn, scale: p.scale, tilt: p.tilt || [0, 0] }));
  toast(`Copied ${list.length}: Ctrl+V pastes where you point.`); renderSel();
}
async function pasteAt(at) {
  if (!WV.clip || !WV.tile) { toast('Copy something first (Ctrl+C on a selection).', true); return; }
  const rt = $('#wp-turn').checked, rs = +$('#wp-size').value || 0, rl = Math.min(45, +$('#wp-tilt').value || 0);
  await checkpoint(`paste ${WV.clip.length}`);
  const r = await api('world_place_many', { dir: S.project.dir, map: WV.tile.map, ground: true, placements: WV.clip.map((c) => {
    const spin = rt ? Math.random() * 360 : 0, k = 1 + (Math.random() * 2 - 1) * rs / 100;
    const lean = () => (Math.random() * 2 - 1) * rl;
    return { model: c.model, x: at.x + c.dx, y: at.y + c.dy, z: 0, turn: (c.turn + spin) % 360, scale: /\.wmo$/i.test(c.model) ? 1 : Math.max(0.05, c.scale * k), uid: 0, tilt: [c.tilt[0] + lean(), c.tilt[1] + lean()] };
  }) });
  WV.info = await api('world_list', { dir: S.project.dir }); renderWorldList(); await showTile();
  selectPlacement(r.map((x) => x.uid));
  toast(`Pasted ${r.length}.`);
}
// move the selection's middle to the cursor
async function moveToCursor(at) {
  const list = placementsHere().filter((p) => WV.sels.includes(p.uid)); if (!list.length) return;
  const cx = list.reduce((a, p) => a + p.x, 0) / list.length, cy = list.reduce((a, p) => a + p.y, 0) / list.length;
  await checkpoint('move to cursor');
  await api('world_move_many', { dir: S.project.dir, map: WV.tile.map, moves: list.map((p) => {
    const n = { x: at.x + p.x - cx, y: at.y + p.y - cy };
    return { uid: p.uid, ...n, z: groundUnder(n) };
  }) });
  await afterMove();
}
const cursorSpot = () => WV.hover || WV.lastPick || (WV.tile && canvasToWorld({ u: WV.tile.size / 2, v: WV.tile.size / 2 }));
$('#ws-copy').addEventListener('click', copySel);
$('#ws-paste').addEventListener('click', () => safe(() => pasteAt(cursorSpot())));
$('#ws-none').addEventListener('click', () => selectPlacement(null));
document.addEventListener('keydown', (e) => {
  if (S.view !== 'world' || isTyping()) return;
  const k = e.key.toLowerCase(), mod = e.ctrlKey || e.metaKey;
  if (mod && k === 'v') { e.preventDefault(); safe(() => pasteAt(cursorSpot())); return; }
  if (!WV.sels.length) return;
  if (e.key === 'Delete') { e.preventDefault(); $('#ws-del').click(); }
  else if (e.key === 'Escape' && !walking()) { selectPlacement(null); if (WV.game) gameDone(); }
  else if (mod && k === 'c') { e.preventDefault(); copySel(); }
  else if (mod && k === 'd') { e.preventDefault(); copySel(); safe(() => pasteAt({ x: cursorSpot().x, y: cursorSpot().y })); }
  else if (!mod && k === 'v') { e.preventDefault(); safe(() => moveToCursor(cursorSpot())); }
  else if (e.key === 'PageDown') { e.preventDefault(); $('#ws-ground').click(); }
});
// Ctrl-drag (Place tool): a box picks up every one of yours inside it
(() => {
  let box = null, el = null;
  const start = (e, view) => {
    if (WV.tool !== 'place' || !(e.ctrlKey || e.metaKey) || e.button !== 0 || walking()) return;
    e.preventDefault(); e.stopImmediatePropagation();
    box = { x0: e.clientX, y0: e.clientY, x1: e.clientX, y1: e.clientY, view, add: e.shiftKey };
    el = document.createElement('div'); el.className = 'selrect'; document.body.appendChild(el);
  };
  for (const [id, view] of [['#w-canvas', '2d'], ['#w-3d', '3d']]) $(id).addEventListener('mousedown', (e) => start(e, view), true);
  window.addEventListener('mousemove', (e) => {
    if (!box) return;
    box.x1 = e.clientX; box.y1 = e.clientY;
    Object.assign(el.style, { left: Math.min(box.x0, box.x1) + 'px', top: Math.min(box.y0, box.y1) + 'px', width: Math.abs(box.x1 - box.x0) + 'px', height: Math.abs(box.y1 - box.y0) + 'px' });
  });
  window.addEventListener('mouseup', () => {
    if (!box) return;
    const r = { x0: Math.min(box.x0, box.x1), x1: Math.max(box.x0, box.x1), y0: Math.min(box.y0, box.y1), y1: Math.max(box.y0, box.y1) };
    el.remove(); el = null;
    const b = box; box = null;
    WV.boxed = Date.now();
    if (r.x1 - r.x0 < 4 && r.y1 - r.y0 < 4) return;
    let uids = [];
    if (b.view === '3d') uids = WV.t3?.inRect(r) || [];
    else {
      const c = $('#w-canvas').getBoundingClientRect(), t = WV.tile, k = t.size / c.width;
      uids = (t.mine || []).filter((m) => { const x = c.left + m.u / k, y = c.top + m.v / k; return x >= r.x0 && x <= r.x1 && y >= r.y0 && y <= r.y1; }).map((m) => m.placement.uid);
    }
    selectPlacement(b.add ? [...WV.sels, ...uids] : uids);
    if (uids.length) toast(`${WV.sels.length} selected: drag the handles, or Ctrl+C / Delete / V (to the cursor).`);
  });
})();

// ---- loading, shown where you look (never a frozen screen) ---------------------------------------
let loadHide = 0;
function loadChip(text, frac) {
  const c = $('#w-load'); if (!c) return;
  clearTimeout(loadHide);
  if (!text) { loadHide = setTimeout(() => { c.hidden = true; }, 400); $('.bar i', c).style.width = '100%'; return; }
  c.hidden = false; $('#w-loadtext').textContent = text; $('.bar i', c).style.width = `${Math.round((frac || 0) * 100)}%`;
}

// ---- ? : every key on one sheet ----------------------------------------------------------------------
const KEYS = [
  ['Tools', [['1 – 0', 'Place, Scatter, Prefab, Spawn, Portal, Raise, Lower, Smooth, Flatten, Paint'], ['[  ]', 'Brush smaller / bigger'], ['Shift + click', 'The other way: drain water, fill a hole, clear scatter'], ['Ctrl + Z', 'Undo'], ['Ctrl + Y', 'Redo']]],
  ['View', [['W A S D', 'Fly (3D)'], ['Q  E', 'Down / up'], ['Shift', 'Faster'], ['Right-drag', 'Turn the view'], ['Wheel', 'Closer / further'], ['Tab', 'Hide the panels'], ['F7', 'Chunk and tile lines'], ['Shift + F2', 'Too steep to walk'], ['N', 'The tiles around (click one to go)'], ['B', 'Spots: save this one, go back to one']]],
  ['Your models', [['Click', 'Pick one up (Place tool)'], ['Shift + click', 'Add one to the selection'], ['Ctrl + drag', 'Box: pick up many'], ['Ctrl + C', 'Copy'], ['Ctrl + V', 'Paste where you point'], ['Ctrl + D', 'Duplicate'], ['V', 'Move them to the cursor'], ['Delete', 'Remove them'], ['PageDown', 'Onto the ground'], ['Esc', 'Put them down']]],
  ['Shaping', [['R  Shift+R', 'Turn the stamp or the copied ground'], ['M', 'Mirror the copied ground'], ['Ctrl + Enter', 'Run the script (in the script box)']]],
  ['Play', [['Walk', 'WASD, Space jumps, drag looks, Esc stops'], ['T', 'Test this spot in the game'], ['Ctrl + K', 'Go anywhere in Forge']]],
];
function keysSheet() {
  let box = $('#keysheet');
  if (box) { box.remove(); return; }
  box = document.createElement('div'); box.id = 'keysheet'; box.className = 'modal-back';
  box.innerHTML = `<div class="modal panel keys"><div class="row between"><h2>Keys</h2><button class="btn small" data-x>Close</button></div><div class="keygrid">${KEYS.map(([h, rows]) =>
    `<section><h3>${h}</h3>${rows.map(([k, w]) => `<div class="krow"><span>${k.split(/\s+\+\s+|\s{2}/).map((x) => `<kbd>${esc(x)}</kbd>`).join(' ')}</span><em>${esc(w)}</em></div>`).join('')}</section>`).join('')}</div></div>`;
  document.body.appendChild(box);
  box.addEventListener('click', (e) => { if (e.target === box || e.target.dataset.x !== undefined) box.remove(); });
}
$('#w-keys').addEventListener('click', keysSheet);
document.addEventListener('keydown', (e) => {
  if (e.key === '?' && !isTyping()) { e.preventDefault(); keysSheet(); }
  else if (e.key === 'Escape' && $('#keysheet')) $('#keysheet').remove();
});

// ---- areas by name: the ones on this tile, a search, a new one ------------------------------------
WV.areaNames = new Map();
async function areaNames(ids) {
  const want = ids.filter((i) => !WV.areaNames.has(i));
  if (want.length) for (const a of await api('area_list', { dir: S.project.dir, ids: want, limit: 200 }, true).catch(() => [])) WV.areaNames.set(a.id, a);
  return ids.map((i) => WV.areaNames.get(i) || { id: i, name: `Area ${i}` });
}
function pickArea(a) {
  $('#w-area').value = a.id;
  if ($('#w-areaedit').open) loadAreaEdit();
  $('#w-areanow').innerHTML = `<span class="meta">Painting</span> <b>${esc(a.name)}</b> <span class="meta">${a.id}${a.level ? ' · level ' + a.level : ''}${a.own ? ' · yours' : ''}</span>`;
  $$('#w-arealist li').forEach((li) => li.classList.toggle('on', +li.dataset.id === a.id));
}
function areaList(list, title) {
  $('#w-arealist').innerHTML = (title ? `<li class="meta">${esc(title)}</li>` : '') + list.map((a) => `<li data-id="${a.id}" class="${a.id === +$('#w-area').value ? 'on' : ''}"><span>${esc(a.name)}${a.own ? ' <span class="pill ok">yours</span>' : ''}</span><span class="n">${a.id}</span></li>`).join('');
  $$('#w-arealist li[data-id]').forEach((li) => li.addEventListener('click', () => pickArea(list.find((a) => a.id === +li.dataset.id))));
}
async function renderAreas() {
  const t = WV.tile; if (!t?.areas || $('#w-areabox').hidden) return;
  const counts = new Map(); for (const a of t.areas) counts.set(a, (counts.get(a) || 0) + 1);
  const ids = [...counts.keys()].sort((a, b) => counts.get(b) - counts.get(a));
  const list = await areaNames(ids);
  areaList(list, 'On this tile');
  const cur = WV.areaNames.get(+$('#w-area').value) || list[0];
  if (cur) pickArea(cur);
}
$('#w-areafind').addEventListener('submit', (e) => {
  e.preventDefault();
  safe(async () => {
    const q = $('#w-areaq').value.trim(); if (!q) { renderAreas(); return; }
    const list = await api('area_list', { dir: S.project.dir, q, limit: 60 });
    for (const a of list) WV.areaNames.set(a.id, a);
    areaList(list, list.length ? `${list.length} for "${q}"` : `Nothing for "${q}"`);
  });
});
$('#an-go').addEventListener('click', () => safe(async () => {
  const name = $('#an-name').value.trim(); if (!name) { toast('Give the area a name.', true); return; }
  const parent = $('#an-inside').checked ? +$('#w-area').value || 0 : 0;
  const r = await api('area_new', { dir: S.project.dir, map: WV.tile.map, name, parent, level: +$('#an-level').value || 1 });
  const a = { id: r.id, name, level: +$('#an-level').value, own: true, parent };
  WV.areaNames.set(a.id, a); pickArea(a); $('#an-name').value = ''; $('#w-areanew').open = false;
  toast(`${name} is area ${r.id}: paint it onto the ground.`);
}));
// Ctrl-click with the Area tool: the area under the pointer
for (const id of ['#w-canvas', '#w-3d']) $(id).addEventListener('click', (e) => {
  if (WV.tool !== 'area' || !(e.ctrlKey || e.metaKey) || !WV.tile) return;
  e.stopImmediatePropagation();
  const p = id === '#w-3d' ? WV.t3?.pick(e) : (() => { const r = $('#w-canvas').getBoundingClientRect(); return { u: (e.clientX - r.left) / r.width * WV.tile.size, v: (e.clientY - r.top) / r.height * WV.tile.size }; })();
  if (!p) return;
  const k = Math.min(15, Math.floor(p.v / WV.tile.size * 16)) * 16 + Math.min(15, Math.floor(p.u / WV.tile.size * 16));
  safe(async () => { const [a] = await areaNames([WV.tile.areas[k]]); pickArea(a); });
}, true);

// ---- History: every edit you can go back to, and back again ---------------------------------------
async function renderHistory() {
  const h = await api('world_history', { dir: S.project.dir }, true);
  const ago = (t) => { const s = Math.max(0, Date.now() / 1000 - t); return s < 60 ? 'just now' : s < 3600 ? `${Math.round(s / 60)} min ago` : s < 86400 ? `${Math.round(s / 3600)} h ago` : `${Math.round(s / 86400)} d ago`; };
  const un = h.undo.slice().reverse(), re = h.redo.slice().reverse();
  $('#w-hist').innerHTML = `<div class="hh">Back to before…</div>${un.length ? un.map((s, i) => `<button type="button" data-u="${i + 1}"><span>${esc(s.what)}</span><em>${ago(s.when)}</em></button>`).join('') : '<p class="hint">Nothing to undo yet.</p>'}
    ${re.length ? `<div class="hh">Undone (redo)</div>${re.map((s, i) => `<button type="button" data-r="${i + 1}" class="redo"><span>${esc(s.what)}</span><em>${ago(s.when)}</em></button>`).join('')}` : ''}
    <p class="hint">Forge saves as you go: every edit is on disk the moment you make it.</p>`;
  $$('#w-hist [data-u]').forEach((b) => b.addEventListener('click', () => { $('#w-hist').hidden = true; undoWorld(+b.dataset.u); }));
  $$('#w-hist [data-r]').forEach((b) => b.addEventListener('click', async () => { $('#w-hist').hidden = true; for (let i = 0; i < +b.dataset.r; i++) await undoWorld(1, true); }));
}
$('#w-histbtn').addEventListener('click', (e) => { e.stopPropagation(); const h = $('#w-hist'); h.hidden = !h.hidden; if (!h.hidden) safe(renderHistory); });
$('#w-redo').addEventListener('click', () => undoWorld(1, true));
document.addEventListener('click', (e) => { if (!e.target.closest?.('.histwrap')) $('#w-hist').hidden = true; });

$('#w-swapmap').addEventListener('click', () => safe(async () => {
  const to = $('#w-tex').value, t = WV.tile;
  if (!WV.swapFrom || !to) { toast('Pick the texture to swap out (above) and the one to swap in (under Paint).', true); return; }
  await checkpoint('swap texture (map)');
  const r = await api('world_swap', { dir: S.project.dir, map: t.map, a: t.tile[0], b: t.tile[1], from: WV.swapFrom, to, scope: 'pack' });
  toast(`${fileLabel(WV.swapFrom)} → ${fileLabel(to)}: ${r.chunks} chunks on ${r.tiles} tile${r.tiles === 1 ? '' : 's'}.`);
  WV.swapFrom = null; WV.nb.clear(); WV.far.clear(); await showTile(); renderSwapGrid();
}));
// spray only means something for Paint
const syncSprayRow = () => { $('#w-sprayrow').hidden = WV.tool !== 'paint'; };
$$('#w-tools button').forEach((b) => b.addEventListener('click', () => setTimeout(syncSprayRow)));
syncSprayRow();

// ---- an area's settings: name, level, territory, music, sanctuary --------------------------------
let AE = null;
async function loadAreaEdit() {
  const id = +$('#w-area').value; if (!id) return;
  AE = await api('area_get', { dir: S.project.dir, id }, true).catch(() => null);
  if (!AE) return;
  $('#ae-name').value = AE.name; $('#ae-level').value = AE.level; $('#ae-faction').value = String(AE.faction & 6);
  $('#ae-music').value = AE.music; $('#ae-parent').value = AE.parent; $('#ae-amb').value = AE.ambience;
  $('#ae-sanct').checked = !!(AE.flags & 0x800);
  $('#ae-note').textContent = AE.own ? 'Your area.' : 'A game area: saving changes it in your pack (an override).';
}
$('#w-areaedit').addEventListener('toggle', () => { if ($('#w-areaedit').open) safe(loadAreaEdit); });
let musicTimer = 0;
$('#ae-musicq').addEventListener('input', () => {
  clearTimeout(musicTimer);
  const q = $('#ae-musicq').value.trim(); if (q.length < 2) { $('#ae-musiclist').innerHTML = ''; return; }
  musicTimer = setTimeout(async () => {
    const h = await api('data_search', { table: 'ZoneMusic', q, limit: 20 }, true).catch(() => []);
    $('#ae-musiclist').innerHTML = h.map((x) => `<li data-id="${x.ID}"><span>${esc(x.label)}</span><span class="n">${x.ID}</span></li>`).join('') || '<li class="meta">Nothing by that name.</li>';
    $$('#ae-musiclist li[data-id]').forEach((li) => li.addEventListener('click', () => { $('#ae-music').value = li.dataset.id; $('#ae-musiclist').innerHTML = ''; $('#ae-musicq').value = li.querySelector('span').textContent; }));
  }, 250);
});
$('#ae-save').addEventListener('click', () => safe(async () => {
  if (!AE) return;
  const flags = $('#ae-sanct').checked ? (AE.flags | 0x800) : (AE.flags & ~0x800);
  await api('area_save', { dir: S.project.dir, id: AE.id, name: $('#ae-name').value, level: +$('#ae-level').value || 0, faction: +$('#ae-faction').value,
    music: +$('#ae-music').value || 0, parent: +$('#ae-parent').value || 0, ambience: +$('#ae-amb').value || 0, flags });
  WV.areaNames.delete(AE.id);
  toast(`${$('#ae-name').value} saved.`);
  await renderAreas(); await loadAreaEdit();
}));

// ---- Lights and the time of day ---------------------------------------------------------------------
// a map's lights (the global one and the spheres), each light's weathers and colour bands
const LT = { map: null, list: [], det: new Map(), sel: null, weather: 0 };
const BANDS_SHOWN = [[0, 'Sun'], [1, 'Ambient'], [2, 'Sky top'], [3, 'Sky middle'], [4, 'Sky lower'], [6, 'Horizon'], [7, 'Fog'], [11, 'Clouds'], [14, 'River near'], [15, 'River far'], [16, 'Ocean near'], [17, 'Ocean far']];
const hhmm = (t) => `${String(Math.floor(t / 120)).padStart(2, '0')}:${String(Math.floor(t % 120 / 2)).padStart(2, '0')}`;
const hex6 = (c) => '#' + (c & 0xffffff).toString(16).padStart(6, '0');
function bandAt(b, t) {
  if (!b || !b.times?.length) return null;
  const n = b.times.length, T = b.times, C = b.colors || b.values;
  if (n === 1) return C[0];
  let i = n - 1;
  for (let k = 0; k < n; k++) if (T[k] <= t) i = k;
  const j = (i + 1) % n, t0 = T[i], t1 = j > i ? T[j] : T[j] + 2880, tt = t < t0 ? t + 2880 : t;
  const f = t1 > t0 ? Math.min(1, Math.max(0, (tt - t0) / (t1 - t0))) : 0;
  if (!b.colors) return C[i] + (C[j] - C[i]) * f;
  const ch = (c, s) => (c >> s) & 255, mix = (s) => Math.round(ch(C[i], s) + (ch(C[j], s) - ch(C[i], s)) * f);
  return (mix(16) << 16) | (mix(8) << 8) | mix(0);
}
async function lightList() {
  const t = WV.tile; if (!t) return [];
  if (LT.map !== t.map) { LT.map = t.map; LT.list = []; LT.det.clear(); }
  if (!LT.list.length) {
    const c = canvasToWorld({ u: t.size / 2, v: t.size / 2 });
    LT.list = await api('light_list', { dir: S.project.dir, map: t.map, x: c.x, y: c.y }, true).catch(() => []);
  }
  return LT.list;
}
async function lightDetail(id) {
  if (!LT.det.has(id)) LT.det.set(id, await api('light_get', { dir: S.project.dir, id }, true));
  return LT.det.get(id);
}
// the sky of the spot you look at, at the hour on the slider: the global light, and a sphere's over it
async function applySky() {
  if (!WV.t3 || !$('#w-is3d').checked || !WV.tile) return;
  const list = await lightList(); if (!list.length) return;
  const at = WV.lastPick || canvasToWorld({ u: WV.tile.size / 2, v: WV.tile.size / 2 });
  const t = +$('#w-tod').value, wi = LT.weather;
  const colours = async (l) => {
    const d = await lightDetail(l.id).catch(() => null), w = d?.weathers?.[wi]?.ints || d?.weathers?.[0]?.ints; if (!w) return null;
    const g = (k) => bandAt(w[k], t) ?? 0;
    return { sun: g(0), ambient: g(1), top: g(2), middle: g(3), horizon: g(6), fog: g(7) };
  };
  let k = null;
  const glob = list.find((l) => l.global);
  if (glob) k = await colours(glob);
  const near = list.filter((l) => !l.global).map((l) => [l, Math.hypot(l.x - at.x, l.y - at.y)]).filter(([l, d]) => d < l.end).sort((a, b) => a[1] - b[1])[0];
  if (near) {
    const [l, d] = near, s = await colours(l);
    const w = l.end > l.start ? Math.min(1, Math.max(0, (l.end - d) / (l.end - l.start))) : 1;
    if (s && k) for (const key of Object.keys(k)) { const a = k[key], b = s[key], m = (sh) => Math.round(((a >> sh) & 255) * (1 - w) + ((b >> sh) & 255) * w); k[key] = (m(16) << 16) | (m(8) << 8) | m(0); }
    else if (s) k = s;
  }
  if (k) WV.t3.setSky(k);
}
$('#w-tod').addEventListener('input', () => { $('#w-todv').textContent = hhmm(+$('#w-tod').value); safe(applySky); if (LT.sel != null) drawBands(); });
async function renderLights() {
  const t = WV.tile; if (!t) return;
  const list = await lightList();
  const here = list.filter((l) => l.global || Math.hypot(l.x - (t.origin.x - t.size / 2), l.y - (t.origin.y - t.size / 2)) < l.end + t.size);
  $('#lt-list').innerHTML = (here.length ? '' : '<li class="meta">No lights on this map.</li>') + here.slice(0, 14).map((l) => `<li data-id="${l.id}" class="${l.id === LT.sel ? 'on' : ''}"><span>${l.global ? '<b>The whole map</b>' : `Light ${l.id}`} <span class="meta">${l.global ? 'everywhere' : `${Math.round(l.end)} yd`}${l.own ? ' · yours' : ''}</span></span><span class="n">${l.id}</span></li>`).join('');
  $$('#lt-list li[data-id]').forEach((li) => li.addEventListener('click', () => safe(() => pickLight(+li.dataset.id))));
  WV.t3?.setLights(here, LT.sel, t.origin);
  if (LT.sel == null && here.length) await pickLight(here[0].id);
}
async function pickLight(id) {
  LT.sel = id;
  $$('#lt-list li').forEach((li) => li.classList.toggle('on', +li.dataset.id === id));
  const d = await lightDetail(id);
  const glob = d.global;
  $('#lt-detail').innerHTML = `
    <div class="row between"><b>${glob ? 'The whole map' : `Light ${d.id}`}</b><span class="meta">${d.own ? 'yours' : 'the game’s: changes go in your pack'}</span></div>
    ${glob ? '<p class="hint">Everywhere on the map, except inside its spheres of light.</p>' : `
    <div class="form three mt-s"><label>X<input id="lt-x" type="number" step="1" value="${d.x.toFixed(1)}"></label><label>Y<input id="lt-y" type="number" step="1" value="${d.y.toFixed(1)}"></label><label>Z<input id="lt-z" type="number" step="1" value="${d.z.toFixed(1)}"></label></div>
    <div class="slider mt-s"><span>Fades from</span><input type="range" id="lt-start-r" min="0" max="1500" step="5" value="${Math.round(d.start)}"><input id="lt-start" type="number" min="0" value="${Math.round(d.start)}"><em>yd</em></div>
    <div class="slider"><span>Ends at</span><input type="range" id="lt-end-r" min="5" max="2000" step="5" value="${Math.round(d.end)}"><input id="lt-end" type="number" min="1" value="${Math.round(d.end)}"><em>yd</em></div>`}
    <label class="mt-s">Weather<select id="lt-weather">${d.weathers.map((w, i) => `<option value="${i}" ${i === LT.weather ? 'selected' : ''} ${w.params ? '' : 'disabled'}>${esc(w.name)}</option>`).join('')}</select></label>
    <div id="lt-bands" class="bands mt-s"></div>
    <p class="hint">Click a strip to set its colour at that hour (a new stop); Shift-click a stop to take it away. ☀ in the toolbar shows any hour.</p>
    <div class="row wrap mt-s">${glob ? '' : '<button type="button" class="btn small" id="lt-here">Move it where I clicked</button>'}<button type="button" class="btn small gold" id="lt-new">New light where I clicked</button>${d.own ? '<button type="button" class="btn small danger" id="lt-del">Remove</button>' : ''}</div>`;
  drawBands();
  $('#lt-weather').addEventListener('change', (e) => { LT.weather = +e.target.value; drawBands(); safe(applySky); });
  const save = async (fields) => { await api('light_set', { dir: S.project.dir, id, ...fields }); LT.det.delete(id); LT.list = []; await renderLights(); await pickLight(id); await applySky(); };
  if (!glob) {
    for (const k of ['x', 'y', 'z']) $('#lt-' + k).addEventListener('change', (e) => safe(() => save({ [k]: +e.target.value })));
    for (const k of ['start', 'end']) {
      const n = $('#lt-' + k), r = $(`#lt-${k}-r`);
      r.addEventListener('input', () => { n.value = r.value; });
      for (const el of [n, r]) el.addEventListener('change', () => safe(() => save({ [k]: +n.value })));
    }
    $('#lt-here').addEventListener('click', () => safe(() => { if (!WV.lastPick) throw new Error('Click the map where it goes first.'); return save({ x: WV.lastPick.x, y: WV.lastPick.y, z: WV.lastPick.h + 20 }); }));
  }
  $('#lt-new').addEventListener('click', () => safe(async () => {
    if (!WV.lastPick) { toast('Click the map where the light goes, then press this.', true); return; }
    await checkpoint('new light');
    const r = await api('light_new', { dir: S.project.dir, map: WV.tile.map, x: WV.lastPick.x, y: WV.lastPick.y, z: WV.lastPick.h + 20, start: 60, end: 160, from: id });
    LT.list = []; await renderLights(); await pickLight(r.id); await applySky();
    toast(`Light ${r.id}: a copy of the one you had, where you clicked. Change its colours below.`);
  }));
  $('#lt-del')?.addEventListener('click', () => safe(async () => { await checkpoint('remove light'); await api('light_remove', { dir: S.project.dir, id }); LT.sel = null; LT.list = []; LT.det.delete(id); await renderLights(); await applySky(); }));
  WV.t3?.setLights(LT.list, id, WV.tile.origin);
}
function drawBands() {
  const d = LT.det.get(LT.sel), box = $('#lt-bands'); if (!d || !box) return;
  const w = d.weathers[LT.weather]; if (!w?.ints) { box.innerHTML = '<p class="hint">This light has no such weather.</p>'; return; }
  const now = +$('#w-tod').value;
  box.innerHTML = BANDS_SHOWN.map(([k, name]) => `<div class="band"><span>${name}</span><canvas data-k="${k}" width="480" height="26"></canvas></div>`).join('');
  for (const cv of $$('canvas', box)) {
    const b = w.ints[+cv.dataset.k], g = cv.getContext('2d');
    for (let x = 0; x < cv.width; x++) { g.fillStyle = hex6(bandAt(b, x / cv.width * 2880) ?? 0); g.fillRect(x, 0, 1, cv.height); }
    for (const tt of b.times) { const x = tt / 2880 * cv.width; g.fillStyle = '#000'; g.fillRect(x - 3, 17, 7, 9); g.fillStyle = '#f3d189'; g.fillRect(x - 2, 18, 5, 7); }
    g.fillStyle = 'rgba(255,255,255,.9)'; g.fillRect(now / 2880 * cv.width - 0.5, 0, 1.5, cv.height);
    cv.title = `${INT_LABEL(cv.dataset.k)}: click to set the colour at that hour`;
    cv.addEventListener('click', (e) => {
      const r = cv.getBoundingClientRect(), time = Math.round((e.clientX - r.left) / r.width * 2880 / 30) * 30;
      const near = b.times.findIndex((x) => Math.abs(x - time) <= 60);
      if (e.shiftKey) { if (near >= 0 && b.times.length > 1) safe(() => setBand(+cv.dataset.k, b.times.filter((_, i) => i !== near), b.colors.filter((_, i) => i !== near))); return; }
      const picker = $('#lt-color');
      picker.value = hex6(near >= 0 ? b.colors[near] : bandAt(b, time) ?? 0);
      picker.onchange = () => {
        const c = parseInt(picker.value.slice(1), 16);
        const T = [...b.times], C = [...b.colors];
        if (near >= 0) C[near] = c; else { const i = T.findIndex((x) => x > time); const at = i < 0 ? T.length : i; T.splice(at, 0, time); C.splice(at, 0, c); }
        if (T.length > 16) { toast('A colour strip holds 16 stops at most.', true); return; }
        safe(() => setBand(+cv.dataset.k, T, C));
      };
      picker.click();
    });
  }
}
const INT_LABEL = (k) => (BANDS_SHOWN.find((x) => x[0] === +k) || [0, 'Band'])[1];
async function setBand(k, times, colors) {
  const d = LT.det.get(LT.sel), w = d.weathers[LT.weather];
  await checkpoint('light colour');
  await api('light_band', { dir: S.project.dir, params: w.params, band: k, times, colors });
  LT.det.delete(LT.sel); await lightDetail(LT.sel); drawBands(); await applySky();
}
