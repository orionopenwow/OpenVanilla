// Open Vanilla Server Studio front end. Plain ES module, no build step.
// Every label is live text over the art kit; all data is set with textContent, never innerHTML.

const ROLES = { 0: 'Player', 1: 'Moderator', 2: 'Game Master', 3: 'Administrator' };
const ROLE_HELP = {
  0: 'Plays the game.',
  1: 'Teleport, announce, mute, look things up.',
  2: 'Also spawn NPCs and objects, kick, tickets.',
  3: 'Everything, including bans, restarts and Studio.',
};
const RACES = { 1: 'Human', 2: 'Orc', 3: 'Dwarf', 4: 'Night Elf', 5: 'Undead', 6: 'Tauren', 7: 'Gnome', 8: 'Troll' };
const CLASSES = { 1: 'Warrior', 2: 'Paladin', 3: 'Hunter', 4: 'Rogue', 5: 'Priest', 7: 'Shaman', 8: 'Mage', 9: 'Warlock', 11: 'Druid' };
const GEM = { running: 'green', starting: 'amber', stopped: 'red', unknown: 'grey' };
const STATE_WORD = { running: 'Running', starting: 'Starting', stopped: 'Stopped', unknown: 'Unknown' };

let csrf = '';
let me = null;
let timer = null;

// ── tiny DOM helpers ──────────────────────────────────────────────────────────────────────
function h(tag, attrs = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'text') el.textContent = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const kid of kids.flat()) if (kid != null && kid !== false) el.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  return el;
}
function icon(id) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  const use = document.createElementNS('http://www.w3.org/2000/svg', 'use');
  use.setAttribute('href', '#i-' + id);
  svg.append(use);
  svg.setAttribute('aria-hidden', 'true');
  return svg;
}
function btn(label, { variant = 'stone', ic, sm, onclick, disabled, type = 'button', title } = {}) {
  return h('button', { class: `k-btn k-btn--${variant}${sm ? ' k-btn--sm' : ''}`, type, onclick, disabled, title }, ic ? icon(ic) : null, label);
}
function gem(color, sm = true) { return h('span', { class: `k-gem k-gem--${color}${sm ? ' k-gem--sm' : ''}`, 'aria-hidden': 'true' }); }
function panel(title, ic, ...kids) {
  return h('section', { class: 'k-window panel' }, h('div', { class: 'panel-head' }, h('h2', {}, ic ? icon(ic) : null, title)), ...kids);
}
function panelWith(title, ic, right, ...kids) {
  return h('section', { class: 'k-window panel' }, h('div', { class: 'panel-head' }, h('h2', {}, ic ? icon(ic) : null, title), right), ...kids);
}
function field(label, input, hint) {
  return h('label', { class: 'fld' }, h('span', {}, label), input, hint ? h('small', { class: 'fine', style: 'text-transform:none;letter-spacing:0;font-weight:400' }, hint) : null);
}
function when(ts) {
  if (!ts) return '—';
  const d = typeof ts === 'number' ? new Date(ts * 1000) : new Date(String(ts).replace(' ', 'T'));
  if (isNaN(d)) return String(ts);
  const s = (Date.now() - d.getTime()) / 1000;
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.round(s / 60)} min ago`;
  if (s < 86400) return `${Math.round(s / 3600)} h ago`;
  if (s < 86400 * 14) return `${Math.round(s / 86400)} days ago`;
  return d.toLocaleDateString();
}
function bytes(n) { return n > 2 ** 30 ? (n / 2 ** 30).toFixed(1) + ' GB' : n > 2 ** 20 ? (n / 2 ** 20).toFixed(1) + ' MB' : Math.max(1, Math.round(n / 1024)) + ' KB'; }

// ── API ───────────────────────────────────────────────────────────────────────────────────
class ApiError extends Error { constructor(msg, status) { super(msg); this.status = status; } }
async function api(path, body) {
  const opt = body === undefined ? { credentials: 'same-origin' }
    : { method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json', 'X-Studio-CSRF': csrf }, body: JSON.stringify(body) };
  let r;
  try { r = await fetch('api/' + path, opt); } catch { throw new ApiError('Studio is not answering. Is the server program still running?', 0); }
  let data = {};
  try { data = await r.json(); } catch { /* empty */ }
  if (r.status === 401 && path !== 'login') { showSignin(); throw new ApiError(data.error || 'Please sign in again.', 401); }
  if (!r.ok) throw new ApiError(data.error || `Request failed (${r.status})`, r.status);
  return data;
}
async function act(promise, okMsg) {
  try {
    const d = await promise;
    toast(d.message || okMsg || 'Done.', 'ok');
    return d;
  } catch (e) {
    if (e.status !== 401) toast(e.message, 'err');
    return null;
  }
}

// ── toasts & dialogs ──────────────────────────────────────────────────────────────────────
function toast(text, kind = 'ok') {
  const t = h('div', { class: `k-card toast ${kind}`, role: kind === 'err' ? 'alert' : 'status' }, icon(kind === 'err' ? 'warning' : 'check'), h('div', { text }));
  document.getElementById('toasts').append(t);
  setTimeout(() => t.remove(), kind === 'err' ? 7000 : 3800);
}
function modal(build) {
  const back = document.getElementById('modal');
  back.replaceChildren();
  return new Promise((resolve) => {
    const close = (v) => { back.hidden = true; back.replaceChildren(); document.removeEventListener('keydown', esc); resolve(v); };
    const esc = (e) => { if (e.key === 'Escape') close(null); };
    document.addEventListener('keydown', esc);
    const box = h('div', { class: 'k-window modal', role: 'dialog', 'aria-modal': 'true' });
    build(box, close);
    back.append(box);
    back.hidden = false;
    back.onclick = (e) => { if (e.target === back) close(null); };
    const first = box.querySelector('input, textarea, select, button.k-btn--gold, button.k-btn--blood');
    if (first) first.focus();
  });
}
function confirmBox(title, text, okLabel = 'Confirm', variant = 'gold') {
  return modal((box, close) => {
    box.append(h('h3', { text: title }), h('p', { text }),
      h('div', { class: 'actions' }, btn('Cancel', { onclick: () => close(false) }), btn(okLabel, { variant, onclick: () => close(true) })));
  });
}
function formBox(title, intro, fields, okLabel, variant = 'gold') {
  return modal((box, close) => {
    const form = h('form', { class: 'form' });
    const inputs = {};
    for (const f of fields) {
      let input;
      if (f.options) {
        input = h('select', { class: 'k-field', name: f.name });
        for (const [v, l] of f.options) input.append(h('option', { value: v, selected: String(v) === String(f.value) }, l));
      } else {
        input = h('input', { class: 'k-field', name: f.name, value: f.value ?? '', placeholder: f.placeholder || '', maxlength: f.max || 255,
          type: f.type || 'text', autocomplete: f.autocomplete || 'off', required: f.required });
      }
      inputs[f.name] = input;
      form.append(field(f.label, input, f.hint));
    }
    const err = h('p', { class: 'form-error', hidden: true, role: 'alert' });
    form.append(err, h('div', { class: 'actions' }, btn('Cancel', { onclick: () => close(null) }), btn(okLabel, { variant, type: 'submit' })));
    form.onsubmit = (e) => {
      e.preventDefault();
      const out = {};
      for (const [k, el] of Object.entries(inputs)) out[k] = el.value.trim();
      close(out);
    };
    box.append(h('h3', { text: title }), intro ? h('p', { text: intro }) : null, form);
  });
}

// ── session ───────────────────────────────────────────────────────────────────────────────
function showSignin() {
  clearInterval(timer);
  document.getElementById('app').hidden = true;
  document.getElementById('signin').hidden = false;
  document.querySelector('#signin input[name=username]').focus();
}
async function boot() {
  try {
    const svg = await (await fetch('icons.svg')).text();
    document.getElementById('sprite').innerHTML = svg; // our own static file, same origin
  } catch { /* icons are decoration */ }
  document.getElementById('signin-form').addEventListener('submit', async (e) => {
    e.preventDefault();
    const f = e.currentTarget;
    const err = document.getElementById('signin-error');
    err.hidden = true;
    const b = f.querySelector('button');
    b.disabled = true;
    try {
      await api('login', { username: f.username.value.trim(), password: f.password.value });
      f.password.value = '';
      await enter();
    } catch (ex) {
      err.textContent = ex.message;
      err.hidden = false;
    } finally { b.disabled = false; }
  });
  document.getElementById('signout').addEventListener('click', async () => {
    try { await api('logout', {}); } catch { /* signed out anyway */ }
    showSignin();
  });
  window.addEventListener('hashchange', route);
  try { await enter(); } catch { showSignin(); }
}
async function enter() {
  const s = await api('session');
  csrf = s.csrf;
  me = s;
  document.getElementById('who').textContent = s.user;
  document.getElementById('host-label').textContent = s.host.label;
  document.getElementById('signin').hidden = true;
  document.getElementById('app').hidden = false;
  route();
}

// ── router ────────────────────────────────────────────────────────────────────────────────
const VIEWS = { dashboard, players, messages, backups, realm, logs, history };
function route() {
  if (document.getElementById('app').hidden) return;
  clearInterval(timer);
  const name = (location.hash.replace(/^#\/?/, '').split('/')[0]) || 'dashboard';
  const view = VIEWS[name] ? name : 'dashboard';
  for (const t of document.querySelectorAll('.tabs .k-tab')) {
    if (t.dataset.tab === view) t.setAttribute('aria-current', 'page'); else t.removeAttribute('aria-current');
  }
  const root = document.getElementById('view');
  root.replaceChildren(h('div', { class: 'skeleton', text: 'Loading…' }));
  VIEWS[view](root).catch((e) => { if (e.status !== 401) root.replaceChildren(panel('Something went wrong', 'warning', h('p', { text: e.message }))); });
}
function setRealmChip(realm, services) {
  if (realm && realm.name) document.getElementById('realm-name').textContent = realm.name;
  if (services) {
    const world = services.find((s) => s.id === 'mangosd');
    const g = document.getElementById('realm-gem');
    g.className = `k-gem k-gem--sm k-gem--${GEM[world ? world.state : 'unknown']}`;
  }
}

// ── Dashboard ─────────────────────────────────────────────────────────────────────────────
async function dashboard(root) {
  const d = await api('overview');
  setRealmChip(d.realm, d.services);
  const online = d.info && d.info.online != null ? d.info.online : d.counts && d.counts.online;
  const tiles = h('div', { class: 'tiles' },
    tile('Players online', online ?? '—', d.info && d.info.max != null ? `peak ${d.info.max} since start` : 'right now'),
    tile('Accounts', d.counts && d.counts.accounts != null ? d.counts.accounts : '—', d.counts && d.counts.characters != null ? `${d.counts.characters} characters` : 'database offline'),
    tile('World uptime', d.info && d.info.uptime ? shortUptime(d.info.uptime) : '—', d.info && d.info.uptime ? 'since the last restart' : 'world server not answering'),
    tile('Last backup', d.last_backup ? when(d.last_backup.mtime) : 'never', d.backup_settings.enabled ? `daily at ${String(d.backup_settings.hour).padStart(2, '0')}:00` : 'daily backups are off'));

  const svcBox = h('div', { class: 'list' });
  renderServices(svcBox, d.services);
  const svcPanel = panelWith('Services', 'server', h('div', { class: 'actions' },
    btn('Start all', { variant: 'gold', ic: 'start', sm: true, onclick: () => serviceAction('start', 'all', svcBox) }),
    btn('Restart all', { ic: 'restart', sm: true, onclick: () => serviceAction('restart', 'all', svcBox) }),
    btn('Stop all', { variant: 'blood', ic: 'stop', sm: true, onclick: () => serviceAction('stop', 'all', svcBox) })), svcBox);

  const checks = d.checks || [];
  const attention = panel('Needs attention', 'shield',
    checks.length ? h('div', { class: 'list', style: 'gap:8px' }, checks.map(noticeRow))
      : h('div', { class: 'notice good' }, icon('check'), h('div', { text: 'Nothing needs you right now.' }), h('span')));

  const quick = panel('Quick actions', 'megaphone', h('div', { class: 'actions' },
    btn('Announce', { variant: 'gold', ic: 'megaphone', onclick: () => quickAnnounce() }),
    btn('Back up now', { ic: 'backup', onclick: async (e) => { e.currentTarget.disabled = true; await act(api('backups', {})); route(); } }),
    btn('Restart in 5 min', { ic: 'clock', onclick: async () => { if (await confirmBox('Restart the world in 5 minutes?', 'Players see a countdown in chat and are disconnected when it reaches zero. You can cancel it from Messages.', 'Schedule restart')) { await act(api('restart', { seconds: 300 })); route(); } } })),
    d.restart_at ? h('div', { class: 'notice warning' }, icon('clock'), h('div', {}, 'A world restart is scheduled ', h('b', { text: when(d.restart_at).replace(' ago', '') }), '.'), btn('Cancel', { sm: true, onclick: async () => { await act(api('restart', { cancel: true })); route(); } })) : null);

  const recent = panelWith('Recent changes', 'history', h('a', { href: '#/history', class: 'fine' }, 'All history →'),
    d.changes.length ? h('div', { class: 'list' }, d.changes.map((c) => h('div', { class: 'li' }, h('div', {}, h('div', { text: c.summary }), h('div', { class: 'meta', text: `${c.user} · ${when(c.ts)}` })), c.live ? h('span', { class: 'tag live', text: 'Live' }) : h('span', { class: 'tag restart', text: 'Needs restart' }))))
      : h('div', { class: 'empty', text: 'No changes yet. Everything you change in Studio is listed here, with Undo.' }));

  root.replaceChildren(tiles, h('div', { class: 'grid-2' }, h('div', { class: 'stack' }, svcPanel, recent), h('div', { class: 'stack' }, attention, quick)));
  timer = setInterval(async () => {
    try { const s = await api('services'); renderServices(svcBox, s.services); setRealmChip(null, s.services); } catch { /* keep last view */ }
  }, 5000);
}
function tile(label, value, sub) {
  return h('div', { class: 'k-card tile' }, h('div', { class: 'label', text: label }), h('div', { class: 'value', text: String(value) }), h('div', { class: 'sub', text: sub }));
}
function shortUptime(s) {
  const m = s.match(/(\d+)\s*Day/i), hh = s.match(/(\d+)\s*Hour/i), mm = s.match(/(\d+)\s*Minute/i);
  const parts = [];
  if (m) parts.push(m[1] + 'd');
  if (hh) parts.push(hh[1] + 'h');
  if (mm && !m) parts.push(mm[1] + 'm');
  return parts.join(' ') || s;
}
function renderServices(box, list) {
  box.replaceChildren(...list.map((s) => h('div', { class: 'svc', 'data-svc': s.id },
    h('span', { class: `k-gem k-gem--${GEM[s.state] || 'grey'}`, title: STATE_WORD[s.state] }),
    h('div', {}, h('div', { class: 'name', text: s.label }), h('div', { class: 'detail' }, h('span', { class: `state ${s.state}`, text: STATE_WORD[s.state] || s.state }), s.detail ? ` · ${s.detail}` : '')),
    h('div', { class: 'metrics', text: s.cpu != null ? `${s.cpu}% CPU · ${s.mem_mb ?? '—'} MB` : '' }),
    h('div', { class: 'btns' }, s.controllable ? [
      s.state === 'stopped' ? btn('Start', { variant: 'gold', sm: true, ic: 'start', onclick: () => serviceAction('start', s.id, box) })
        : btn('Restart', { sm: true, ic: 'restart', onclick: () => serviceAction('restart', s.id, box) }),
      s.state !== 'stopped' ? btn('Stop', { variant: 'blood', sm: true, ic: 'stop', onclick: () => serviceAction('stop', s.id, box) }) : null,
    ] : h('span', { class: 'fine', text: 'Studio runs here' })))));
}
async function serviceAction(action, service, box) {
  const named = (box.querySelector(`[data-svc="${service}"] .name`) || {}).textContent;
  const what = service === 'all' ? 'every service' : (named ? `the ${named.toLowerCase()}` : `the ${service} service`);
  if (action !== 'start') {
    const ok = await confirmBox(`${action === 'stop' ? 'Stop' : 'Restart'} ${what}?`,
      service === 'all' || service === 'mangosd' || service === 'mysql'
        ? 'Everyone online is disconnected. The world server saves every character before it stops.'
        : 'Players are not disconnected by this, but nobody can log in while it is down.',
      action === 'stop' ? 'Stop' : 'Restart', action === 'stop' ? 'blood' : 'gold');
    if (!ok) return;
  }
  const label = service === 'all' ? 'All services' : (box.querySelector(`[data-svc="${service}"] .name`) || {}).textContent || service;
  toast(`${{ start: 'Starting', stop: 'Stopping', restart: 'Restarting' }[action]} ${what}…`, 'ok');
  try {
    await api(`services/${action}`, { service });
    toast(`${label} ${{ start: 'started', stop: 'stopped', restart: 'restarted' }[action]}.`, 'ok');
  } catch (e) { if (e.status !== 401) toast(e.message, 'err'); }
  try { const s = await api('services'); renderServices(box, s.services); setRealmChip(null, s.services); } catch { /* next tick */ }
}
function noticeRow(c) {
  const fix = c.fix ? btn('Fix it', { sm: true, variant: 'gold', onclick: async () => { if (await act(api(`fix/${c.fix}`, {}))) route(); } }) : h('span');
  return h('div', { class: `notice ${c.level}` }, icon(c.level === 'info' ? 'info' : 'warning'), h('div', { text: c.text }), fix);
}
async function quickAnnounce() {
  const v = await formBox('Announce to everyone online', 'It appears in every player\'s chat, in the server announcement colour.',
    [{ name: 'text', label: 'Message', max: 255, required: true, placeholder: 'e.g. Double XP starts at 8pm!' }], 'Send', 'gold');
  if (v && v.text) await act(api('announce', { text: v.text }));
}

// ── Players ───────────────────────────────────────────────────────────────────────────────
const pState = { q: '', role: '', offset: 0, limit: 25 };
async function players(root) {
  const search = h('input', { class: 'k-field search', placeholder: 'Search account names', value: pState.q, maxlength: 16, 'aria-label': 'Search account names' });
  const role = h('select', { class: 'k-field', 'aria-label': 'Filter by role' },
    h('option', { value: '' }, 'Everyone'), h('option', { value: '1', selected: pState.role === '1' }, 'Staff (Moderator and up)'), h('option', { value: '3', selected: pState.role === '3' }, 'Administrators'));
  const body = h('div', {}, h('div', { class: 'skeleton', text: 'Loading…' }));
  const pager = h('div', { class: 'pager' });
  let t;
  search.addEventListener('input', () => { clearTimeout(t); t = setTimeout(() => { pState.q = search.value.replace(/[^A-Za-z0-9]/g, ''); pState.offset = 0; load(); }, 250); });
  role.addEventListener('change', () => { pState.role = role.value; pState.offset = 0; load(); });
  root.replaceChildren(panelWith('Players', 'users', btn('New account', { variant: 'gold', ic: 'plus', onclick: newAccount }),
    h('div', { class: 'toolbar' }, search, role), h('div', { class: 'tbl-wrap' }, body), pager,
    h('p', { class: 'fine', text: 'Role changes apply the next time that player logs in. Kick, ban and unban need the world server running.' })));

  async function load() {
    const d = await api(`accounts?q=${encodeURIComponent(pState.q)}&role=${pState.role}&limit=${pState.limit}&offset=${pState.offset}`);
    if (!d.rows.length) { body.replaceChildren(h('div', { class: 'empty', text: pState.q ? 'No account matches that search.' : 'No accounts yet.' })); pager.replaceChildren(); return; }
    const table = h('table', { class: 'tbl cards' }, h('thead', {}, h('tr', {}, ['Account', 'Role', 'Characters', 'Joined', ''].map((x) => h('th', { text: x })))),
      h('tbody', {}, d.rows.map(row)));
    body.replaceChildren(table);
    const from = pState.offset + 1, to = pState.offset + d.rows.length;
    pager.replaceChildren(h('span', { class: 'num', text: `${from}–${to} of ${d.total}` }),
      btn('Previous', { sm: true, disabled: pState.offset === 0, onclick: () => { pState.offset = Math.max(0, pState.offset - pState.limit); load(); } }),
      btn('Next', { sm: true, disabled: to >= d.total, onclick: () => { pState.offset += pState.limit; load(); } }));
  }
  function row(a) {
    const sel = h('select', { class: 'k-field', 'aria-label': `Role of ${a.username}` },
      Object.entries(ROLES).map(([v, l]) => h('option', { value: v, selected: Number(v) === a.gmlevel }, `${l} (GM ${v})`)));
    sel.addEventListener('change', async () => {
      const to = Number(sel.value);
      const ok = await confirmBox(`Make ${a.username} ${ROLES[to]}?`, ROLE_HELP[to] + ' You can undo this from History.', 'Change role');
      if (!ok || !(await act(api(`accounts/${a.id}/role`, { role: to })))) sel.value = String(a.gmlevel); else a.gmlevel = to;
    });
    const chars = a.characters.length ? h('div', { class: 'chars' }, a.characters.map((c) => h('span', { class: `chip${c.online ? ' on' : ''}`, title: `${RACES[c.race] || 'Race ' + c.race} ${CLASSES[c.class] || 'Class ' + c.class}` },
      c.online ? gem('green') : null, `${c.name} · ${c.level}`, h('span', { class: 'muted', text: CLASSES[c.class] || '' }),
      c.online ? h('button', { type: 'button', onclick: async () => { if (await confirmBox(`Kick ${c.name}?`, 'They are disconnected and can log straight back in.', 'Kick', 'blood')) { await act(api(`characters/${encodeURIComponent(c.name)}/kick`, {})); load(); } } }, 'kick') : null)))
      : h('span', { class: 'muted', text: 'none' });
    return h('tr', {},
      h('td', {}, h('div', { class: 'acct' }, gem(a.online ? 'green' : 'grey'), a.username, a.banned ? h('span', { class: 'tag ban', text: 'Banned' }) : null)),
      h('td', { 'data-label': 'Role' }, sel),
      h('td', { 'data-label': 'Characters' }, chars),
      h('td', { class: 'muted', 'data-label': 'Joined', title: a.joindate || '', text: when(a.joindate) }),
      h('td', {}, h('div', { class: 'actions', style: 'justify-content:flex-end;flex-wrap:nowrap' },
        btn('Password', { sm: true, ic: 'key', onclick: () => resetPassword(a) }),
        a.banned ? btn('Unban', { sm: true, variant: 'gold', onclick: async () => { if (await act(api(`accounts/${a.id}/unban`, {}))) load(); } })
          : btn('Ban', { sm: true, variant: 'blood', ic: 'ban', onclick: () => ban(a) }))));
  }
  async function resetPassword(a) {
    const v = await formBox(`New password for ${a.username}`, 'Their old password stops working at once. Tell them the new one.',
      [{ name: 'password', label: 'New password', type: 'password', max: 16, required: true, hint: '4 to 16 letters or digits (the game client\'s limit).', autocomplete: 'new-password' }], 'Set password');
    if (v) await act(api(`accounts/${a.id}/password`, v));
  }
  async function ban(a) {
    const v = await formBox(`Ban ${a.username}`, 'They are disconnected and can\'t log in until the ban ends.',
      [{ name: 'duration', label: 'How long', value: '1d', options: [['1h', '1 hour'], ['1d', '1 day'], ['7d', '7 days'], ['30d', '30 days'], ['-1', 'Permanent']] },
        { name: 'reason', label: 'Reason', max: 120, required: true, placeholder: 'Shown in the ban list' }], 'Ban account', 'blood');
    if (v && await act(api(`accounts/${a.id}/ban`, v))) load();
  }
  async function newAccount() {
    const v = await formBox('New account', 'Players can also sign up on your realm\'s website.', [
      { name: 'username', label: 'Account name', max: 16, required: true, hint: '3 to 16 letters or digits.' },
      { name: 'password', label: 'Password', type: 'password', max: 16, required: true, hint: '4 to 16 letters or digits.', autocomplete: 'new-password' },
      { name: 'role', label: 'Role', value: '0', options: Object.entries(ROLES).map(([k, l]) => [k, `${l} (GM ${k})`]) }], 'Create account');
    if (v && await act(api('accounts', { ...v, role: Number(v.role) }))) load();
  }
  await load();
}

// ── Messages ──────────────────────────────────────────────────────────────────────────────
async function messages(root) {
  const d = await api('messages');
  const motd = h('textarea', { class: 'k-field', maxlength: 255, rows: 3 }, d.motd || '');
  const motdPanel = panel('Message of the day', 'message',
    h('p', { class: 'fine', text: 'Shown in chat to every player when they log in.' }),
    d.motd_error ? h('div', { class: 'notice warning' }, icon('warning'), h('div', { text: d.motd_error }), h('span')) : null,
    motd, h('div', { class: 'actions' }, btn('Save message', { variant: 'gold', ic: 'check', onclick: () => act(api('motd', { text: motd.value })) }),
      h('span', { class: 'fine', text: d.persist_motd ? 'Applies now.' : 'Applies now, until the world server restarts.' })));

  const ann = h('textarea', { class: 'k-field', maxlength: 255, rows: 3, placeholder: 'e.g. The realm restarts in 10 minutes for an update.' });
  const style = h('select', { class: 'k-field', style: 'width:auto' }, h('option', { value: 'announce' }, 'In chat'), h('option', { value: 'notify' }, 'Centre of the screen'));
  const annPanel = panel('Announce', 'megaphone', h('p', { class: 'fine', text: 'Sends a message to everyone online right now.' }), ann,
    h('div', { class: 'actions' }, style, btn('Send to everyone', { variant: 'gold', ic: 'megaphone', onclick: async () => { if (await act(api('announce', { text: ann.value, style: style.value }))) ann.value = ''; } })));

  const cd = h('div', { class: 'countdown' });
  const restartBody = h('div', { class: 'form' });
  const presets = [[60, '1 min'], [300, '5 min'], [900, '15 min'], [1800, '30 min'], [3600, '1 hour']];
  function renderRestart(at) {
    restartBody.replaceChildren(...[
      at ? h('div', { class: 'notice warning' }, icon('clock'), h('div', {}, 'Restart in ', cd), btn('Cancel restart', { variant: 'blood', sm: true, onclick: async () => { if (await act(api('restart', { cancel: true }))) renderRestart(null); } })) : null,
      h('p', { class: 'fine', text: 'Players see a countdown in chat, then the world server saves everyone and restarts.' }),
      h('div', { class: 'presets' }, presets.map(([s, l]) => btn(l, { ic: 'clock', onclick: async () => {
        if (await confirmBox(`Restart the world in ${l}?`, 'Everyone online is disconnected when the countdown ends.', 'Schedule restart')) {
          const r = await act(api('restart', { seconds: s }));
          if (r) renderRestart(r.restart_at);
        }
      } })))].filter(Boolean));
    clearInterval(timer);
    if (at) {
      const tick = () => { const s = Math.max(0, Math.round(at - Date.now() / 1000)); cd.textContent = `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`; };
      tick();
      timer = setInterval(tick, 1000);
    }
  }
  renderRestart(d.restart_at);
  root.replaceChildren(h('div', { class: 'grid-2e' }, h('div', { class: 'stack' }, motdPanel, annPanel), panel('Timed restart', 'restart', restartBody)));
}

// ── Backups ───────────────────────────────────────────────────────────────────────────────
async function backups(root) {
  const d = await api('backups');
  const s = d.settings;
  const enabled = h('input', { type: 'checkbox', checked: s.enabled });
  const hour = h('select', { class: 'k-field', style: 'width:auto' }, Array.from({ length: 24 }, (_, i) => h('option', { value: i, selected: i === s.hour }, `${String(i).padStart(2, '0')}:00`)));
  const keep = h('select', { class: 'k-field', style: 'width:auto' }, [3, 7, 14, 30, 60, 90].map((n) => h('option', { value: n, selected: n === s.keep_days }, `${n} days`)));
  const sched = panel('Daily backup', 'clock',
    h('div', { class: 'inline' }, h('label', { class: 'k-toggle' }, enabled, h('span', { class: 'k-toggle-rail' }), h('span', { class: 'k-toggle-knob' })), h('span', { text: 'Back up every day' })),
    h('div', { class: 'row2' }, field('At', hour), field('Keep for', keep)),
    h('div', { class: 'actions' }, btn('Save schedule', { variant: 'gold', ic: 'check', onclick: () => act(api('backups/settings', { enabled: enabled.checked, hour: Number(hour.value), keep_days: Number(keep.value) })) })),
    h('p', { class: 'fine' }, 'Backups are saved in ', h('code', { text: d.dir }), '. Copy that folder somewhere else now and then: a backup on the same disk doesn\'t survive the disk.'));
  const list = d.backups.length ? h('div', { class: 'list' }, d.backups.map((b) => h('div', { class: 'li' },
    h('div', {}, h('div', { text: b.name }), h('div', { class: 'meta', text: `${when(b.mtime)} · ${bytes(b.size)} · ${b.kind}` })),
    h('a', { class: 'k-btn k-btn--stone k-btn--sm', href: `api/backups/file/${encodeURIComponent(b.name)}`, download: b.name }, icon('download'), 'Download'))))
    : h('div', { class: 'empty', text: 'No backups yet.' });
  const now = btn('Back up now', { variant: 'gold', ic: 'backup', disabled: d.running, onclick: async (e) => { e.currentTarget.disabled = true; e.currentTarget.lastChild.textContent = 'Backing up…'; await act(api('backups', {})); route(); } });
  root.replaceChildren(h('div', { class: 'grid-2' }, panelWith('Backups', 'backup', now, h('p', { class: 'fine', text: 'A full backup holds accounts, characters and the whole world database. To restore one, follow chapter 10 of the Host Guidebook; one-click restore comes next.' }), list), sched));
}

// ── Realm ─────────────────────────────────────────────────────────────────────────────────
async function realm(root) {
  const d = await api('realm');
  const r = d.realm;
  setRealmChip(r);
  const name = h('input', { class: 'k-field', value: r.name, maxlength: 32 });
  const custom = h('input', { class: 'k-field', placeholder: 'Your public IP or a domain, e.g. play.example.com', maxlength: 253 });
  const opts = [
    ['this', 'Only this computer', 'You alone, for testing', d.suggestions.this_pc],
    ['lan', 'Home network', 'Friends on the same Wi-Fi or router', d.suggestions.lan],
    ['net', 'The internet', 'Anyone, after you open ports 3724 and 8085', null],
  ];
  let current = opts.find((o) => o[3] && o[3] === r.address) ? opts.find((o) => o[3] === r.address)[0] : 'net';
  if (current === 'net') custom.value = r.address;
  const cards = h('div', { class: 'radio-cards', role: 'radiogroup', 'aria-label': 'Who can connect' });
  function draw() {
    cards.replaceChildren(...opts.map(([id, title, sub, addr]) => {
      const input = h('input', { type: 'radio', name: 'reach', value: id, checked: id === current, disabled: id === 'lan' && !addr });
      input.addEventListener('change', () => { current = id; draw(); });
      return h('label', { class: `k-card radio-card${id === current ? ' is-selected' : ''}` }, input, h('b', { text: title }), h('span', { text: sub }),
        addr ? h('code', { text: addr }) : id === 'lan' ? h('span', { text: 'not detected' }) : null);
    }));
    custom.parentElement && (custom.parentElement.hidden = current !== 'net');
  }
  const customField = field('Address', custom, 'Players\' game clients connect to this address. Studio checks it looks like an IP or host name.');
  draw();
  customField.hidden = current !== 'net';
  cards.addEventListener('change', () => { customField.hidden = current !== 'net'; });
  const save = btn('Save realm', { variant: 'gold', ic: 'check', onclick: async () => {
    const addr = current === 'net' ? custom.value.trim() : opts.find((o) => o[0] === current)[3];
    if (!addr) { toast('Type the address players should connect to.', 'err'); return; }
    const res = await act(api('realm', { name: name.value.trim(), address: addr }));
    if (res) setRealmChip({ name: name.value.trim() });
  } });
  root.replaceChildren(h('div', { class: 'grid-2' },
    panel('Realm', 'globe', field('Realm name', name, 'Shown in every player\'s realm list.'), h('h2', {}, 'Who can connect'), cards, customField, h('div', { class: 'actions' }, save)),
    panel('Good to know', 'info', h('div', { class: 'list' },
      h('div', { class: 'li' }, h('div', {}, h('div', { text: 'Login port' }), h('div', { class: 'meta', text: 'Forward this on your router for internet play.' })), h('code', { text: '3724' })),
      h('div', { class: 'li' }, h('div', {}, h('div', { text: 'World port' }), h('div', { class: 'meta', text: 'Forward this too.' })), h('code', { text: String(r.port || 8085) })),
      h('div', { class: 'li' }, h('div', {}, h('div', { text: 'Database port' }), h('div', { class: 'meta', text: 'Never forward this one.' })), h('code', { text: '3310' }))),
      h('p', { class: 'fine' }, 'Step by step: ', h('a', { href: '../guide.html#friends', target: '_blank', rel: 'noopener' }, 'Letting friends in'), '.'))));
}

// ── Logs ──────────────────────────────────────────────────────────────────────────────────
let logSource = 'studio';
async function logs(root) {
  const pre = h('pre', { class: 'log', tabindex: '0' });
  const sel = h('select', { class: 'k-field', style: 'width:auto', 'aria-label': 'Which log' });
  const auto = h('input', { type: 'checkbox', class: 'k-check', checked: true, 'aria-label': 'Follow new lines' });
  async function load() {
    const d = await api(`logs?source=${encodeURIComponent(logSource)}&lines=400`);
    sel.replaceChildren(...d.sources.map((s) => h('option', { value: s.id, selected: s.id === d.source }, s.label)));
    const atBottom = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 30;
    pre.replaceChildren(...(d.lines.length ? d.lines : ['(empty)']).map((l) => h('span', { class: /error|fail|crash/i.test(l) ? 'err' : /warn/i.test(l) ? 'warn' : null }, l + '\n')));
    if (atBottom || !pre.dataset.loaded) pre.scrollTop = pre.scrollHeight;
    pre.dataset.loaded = '1';
  }
  sel.addEventListener('change', () => { logSource = sel.value; delete pre.dataset.loaded; load(); });
  root.replaceChildren(panelWith('Logs', 'log', h('div', { class: 'actions' }, sel, h('label', { class: 'inline fine' }, auto, 'Follow'), btn('Refresh', { sm: true, ic: 'refresh', onclick: load })), pre,
    h('p', { class: 'fine', text: 'Asking for help? Copy the lines around the error into the Open Vanilla Discord\'s #bug-reports.' })));
  await load();
  timer = setInterval(() => { if (auto.checked) load().catch(() => {}); }, 4000);
}

// ── History ───────────────────────────────────────────────────────────────────────────────
async function history(root) {
  const d = await api('changes');
  const rows = d.changes.map((c) => h('tr', {},
    h('td', { class: 'muted', title: new Date(c.ts * 1000).toLocaleString(), text: `${when(c.ts)}` }),
    h('td', { 'data-label': 'Who', text: c.user }),
    h('td', { text: c.summary }),
    h('td', {}, c.undone_by ? h('span', { class: 'tag undone', text: 'Undone' }) : c.live ? h('span', { class: 'tag live', text: 'Live' }) : h('span', { class: 'tag restart', text: 'Needs restart' })),
    h('td', { style: 'text-align:right' }, c.undoable ? btn('Undo', { sm: true, ic: 'undo', onclick: async () => {
      if (await confirmBox('Undo this change?', c.summary, 'Undo')) { if (await act(api(`changes/${c.id}/undo`, {}))) route(); }
    } }) : null)));
  root.replaceChildren(panel('History', 'history',
    h('p', { class: 'fine', text: 'Every change made in Studio, newest first. Undo reverses one change and is itself listed here.' }),
    rows.length ? h('div', { class: 'tbl-wrap' }, h('table', { class: 'tbl cards' }, h('thead', {}, h('tr', {}, ['When', 'Who', 'What', 'Status', ''].map((x) => h('th', { text: x })))), h('tbody', {}, rows)))
      : h('div', { class: 'empty', text: 'Nothing changed yet.' })));
}

boot();
