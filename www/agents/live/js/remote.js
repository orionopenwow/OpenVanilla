// Copied from Vanilla Agents (app/web/js/remote.js) by scripts/export_browser_access.py. Change it there, not here.
// V-054 Browser access page (remote.html): pair once from the link the PC shows, then watch the inn live through the relay.
// The pairing link carries, in its address fragment only (never sent to any server): r = relay, p = pair id, k = the PC's public key,
// s = a one-time invite secret. This browser makes its own key (the private half cannot be exported) and keeps it in IndexedDB.
import { connect, newDevice, b64d } from './remote-core.js';

const $ = (id) => document.getElementById(id);
let S = {
  remote_title: 'Vanilla Agents', remote_pair_head: 'Pair this browser with your PC', remote_pair_text: 'This link came from Options > Browser access on your PC. Give this browser a name you will recognise in the list there, then press Pair.',
  remote_name: 'Name of this browser', remote_pair: 'Pair', remote_pairing: 'Pairing...', remote_refused: 'That pairing link has expired or was already used. Make a new one on your PC (Options > Browser access).',
  remote_no_link: 'Not paired yet. On your PC open Vanilla Agents, Options > Browser access, and scan or open the pairing link there.',
  remote_old_browser: 'This browser cannot do the sealing Vanilla Agents needs (X25519). Use a current Chrome, Edge, Firefox or Safari.',
  remote_connecting: 'Connecting to the relay...', remote_reconnecting: 'Connection lost. Trying again...', remote_pc_online: 'Connected to {name}.',
  remote_pc_offline: 'Your PC is offline: Vanilla Agents is closed or Browser access is off.', remote_relay_error: 'The relay said: {error}',
  remote_watch: 'Watching only', remote_respond: 'Watching, and you can approve, pause and verify', remote_forget: 'Forget this PC',
  remote_forget_ask: 'Forget this PC in this browser? You will need a new pairing link to come back.', remote_sealed: 'End-to-end sealed: the relay passes messages on but cannot read them.',
  done_of: '{done} of {total} quests done', paused: 'paused', no_helpers: 'No helpers yet.', no_quests: 'No quests yet.', quiet: 'Quiet.', away: 'away', waiting: 'waiting for you',
  pause: 'Pause', resume: 'Resume', verify: 'Verify', approve: 'Approve', approved: 'approved', approve_ask: 'Approve "{title}"?', sent: 'Done.', error: 'That did not work: {error}',
  helpers: 'Helpers', quests: 'Quests', chat: 'Chat', memory: 'memory left',
};
const t = (k, v) => String(S[k] || k).replace(/\{(\w+)\}/g, (m, n) => (v && v[n] !== undefined ? v[n] : m));
const words = () => document.querySelectorAll('[data-s]').forEach((n) => { n.textContent = t(n.dataset.s); });
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text !== undefined) e.textContent = text; return e; };
function say(text, bad) { const m = $('msg'); m.textContent = text || ''; m.className = 'msg ' + (bad ? 'bad' : 'ok'); }

// ---- the saved pairing (IndexedDB; a CryptoKey is stored as itself, still not extractable) ----
const DB = 'va-remote', STORE = 'pcs';
function db() {
  return new Promise((res, rej) => {
    const r = indexedDB.open(DB, 1);
    r.onupgradeneeded = () => r.result.createObjectStore(STORE, { keyPath: 'pair' });
    r.onsuccess = () => res(r.result);
    r.onerror = () => rej(r.error);
  });
}
async function tx(mode, fn) {
  const d = await db();
  return new Promise((res, rej) => { const s = d.transaction(STORE, mode).objectStore(STORE); const r = fn(s); r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); });
}
const loadAll = () => tx('readonly', (s) => s.getAll()).catch(() => []);
const save = (rec) => tx('readwrite', (s) => s.put(rec));
const forget = (pair) => tx('readwrite', (s) => s.delete(pair));

// ---- drawing the inn (same as the phone page, built with DOM nodes only) ----
let last = null, scope = 'watch', conn = null, pcName = '', busy = false;

function draw(s) {
  last = s;
  $('inn').hidden = false;
  const c = s.counts || { done: 0, total: 0 };
  const paused = !!(s.verify && s.verify.paused);
  $('head').textContent = (s.project ? s.project.name + ' - ' : '') + t('done_of', c) + (paused ? ' - ' + t('paused') : '') + ' - ' + new Date().toLocaleTimeString();
  $('owner').hidden = scope !== 'respond';
  $('pause').textContent = t(paused ? 'resume' : 'pause');
  $('pause').className = 'btn ' + (paused ? 'b-green' : 'b-orange');
  $('verify').disabled = !!(s.verify && s.verify.running);
  const agents = $('agents');
  agents.replaceChildren();
  for (const a of s.agents || []) {
    const ghost = a.state !== 'working' && a.seen && Date.now() - (typeof a.seen === 'number' ? a.seen * 1000 : Date.parse(a.seen)) > 15 * 60000;
    const card = el('div', 'card'), row = el('div', 'row');
    row.append(el('span', 'name ' + (ghost ? 'ghost' : a.state === 'working' ? 'working' : 'idle'), a.id + (a.role ? ' (' + a.role + ')' : '')),
      el('span', 'sub', ghost ? t('away') : a.waiting ? t('waiting') : a.state));
    card.append(row);
    if (a.activity) card.append(el('div', 'act', a.activity));
    if (typeof a.mana === 'number') { const bar = el('div', 'bar'), i = el('i'); i.style.width = Math.max(0, Math.min(100, a.mana)) + '%'; bar.title = t('memory'); bar.append(i); card.append(bar); }
    agents.append(card);
  }
  if (!agents.children.length) agents.append(el('div', 'sub', t('no_helpers')));
  const tasks = $('tasks');
  tasks.replaceChildren();
  for (const q of (s.tasks || []).slice().reverse().slice(0, 30)) {
    const row = el('div', 'card row'), name = el('span', '', q.title);
    if (q.approved) name.append(' ', el('span', 'tag', '(' + t('approved') + ')'));
    row.append(name);
    if (scope === 'respond' && !q.approved && !['complete', 'failed'].includes(q.status)) {
      const b = el('button', 'btn b-green qbtn', t('approve'));
      b.type = 'button';
      b.addEventListener('click', () => { if (confirm(t('approve_ask', { title: q.title }))) act('/api/approve', { task: q.id }); });
      row.append(b);
    } else row.append(el('span', q.status, q.status));
    tasks.append(row);
  }
  if (!tasks.children.length) tasks.append(el('div', 'sub', t('no_quests')));
  const chat = $('chat');
  chat.replaceChildren();
  for (const l of (s.chat || []).slice(-25).reverse()) chat.append(el('div', l.channel === 'whisper' ? 'whisper' : '', l.text || String(l)));
  if (!chat.children.length) chat.append(el('div', 'sub', t('quiet')));
}

async function act(path, body) {
  if (busy || !conn) return;
  busy = true;
  const r = await conn.req('POST', path, body);
  if (r.status === 200) { say(t('sent')); if (r.body && r.body.agents) draw(r.body); } else say(t('error', { error: (r.body && r.body.error) || r.status }), true);
  busy = false;
}
$('pause').addEventListener('click', () => act('/api/pause', { paused: !(last && last.verify && last.verify.paused) }));
$('verify').addEventListener('click', () => act('/api/verify', {}));

// ---- connecting ----
function link(rec) { return { relay: rec.relay, pair: rec.pair, pcPub: rec.pcPub, dev: { priv: rec.priv, pub: rec.pub, id: rec.id } }; }

function run(rec) {
  $('forget').hidden = false;
  conn = connect(link(rec), {
    status: (k, online, error) => { if (k === 'pc_online') return; $('head').textContent = t('remote_' + k, { error, name: pcName }); if (!online) $('owner').hidden = true; },
    welcome: async (w) => {
      scope = w.scope; pcName = w.name;
      $('scope').textContent = t(scope === 'respond' ? 'remote_respond' : 'remote_watch');
      const strings = await conn.req('GET', '/api/phone/strings');
      if (strings.status === 200) { S = { ...S, ...strings.body }; words(); $('scope').textContent = t(scope === 'respond' ? 'remote_respond' : 'remote_watch'); }
      const st = await conn.req('GET', '/api/state');
      if (st.status === 200) draw(st.body);
    },
    state: (s) => draw(s),
    paired: () => {},
  });
  conn.start();
  return conn;
}

$('forget').addEventListener('click', async () => {
  if (!confirm(t('remote_forget_ask'))) return;
  const all = await loadAll();
  for (const r of all) await forget(r.pair);
  if (conn) conn.stop();
  location.replace(location.pathname);
});

async function main() {
  words();
  if (!globalThis.crypto || !crypto.subtle) { say(t('remote_old_browser'), true); return; }
  const frag = new URLSearchParams(location.hash.slice(1));
  if (location.hash) history.replaceState(null, '', location.pathname + location.search);       // the secret leaves the address bar at once
  if (frag.get('r') && frag.get('p') && frag.get('k') && frag.get('s')) {
    let dev;
    try { dev = await newDevice(); } catch (e) { say(t('remote_old_browser'), true); return; }
    const rec = { relay: frag.get('r'), pair: frag.get('p'), pcPub: b64d(frag.get('k')), priv: dev.priv, pub: dev.pub, id: dev.id };
    $('pairbox').hidden = false;
    $('devname').value = /Mobi|Android|iPhone/.test(navigator.userAgent) ? 'Phone' : 'Browser';
    $('pairbtn').addEventListener('click', async () => {
      $('pairbtn').disabled = true;
      say(t('remote_pairing'));
      const c = run(rec);
      const ok = await c.pair(b64d(frag.get('s')), $('devname').value.trim().slice(0, 40) || 'Browser');
      if (!ok) { c.stop(); $('pairbtn').disabled = false; say(t('remote_refused'), true); return; }
      rec.scope = ok.scope; rec.name = ok.name;
      await save(rec);
      $('pairbox').hidden = true;
      say('');
    }, { once: false });
    return;
  }
  const saved = await loadAll();
  if (!saved.length) { $('head').textContent = t('remote_no_link'); return; }
  run(saved[saved.length - 1]);
}
main();
