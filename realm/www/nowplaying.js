// ow/nowplaying.js — "Share what I'm listening to" for the web client. Off by default.
//
// What reaches the game: Persona.SetListening("Title - Artist") (Persona/Persona.lua), called through
// wenilla.lua() whenever the value changes and again after each world entry. Persona shares it with
// other players over its channel like the other profile fields (title and artist only, 80
// characters); they see "Listening: …" in your tooltip and on your profile.
//
// Where the value comes from — honestly: a web page cannot see what other apps on the computer are
// playing (there is no browser API for the system's media session), so on the web there are three
// sources, all explicit:
//   1. Spotify, if the player links it: the page signs in to Spotify with PKCE (no secret; scope
//      user-read-currently-playing only) in a popup, keeps the token in this browser's localStorage,
//      and asks GET https://api.spotify.com/v1/me/player/currently-playing every 15 s while the tab
//      is visible. Needs the realm operator's Spotify app: /ow/nowplaying.json
//      {"spotify_client_id": "…"} with redirect URI https://<realm>/ow/nowplaying-callback.html.
//      A Spotify app in development mode only works for the (up to 25) accounts its owner added in
//      the Spotify dashboard; everyone else needs Spotify to grant the app extended quota.
//   2. Typed by hand: the menu's "♫ Listening…" button asks for "Title - Artist".
//   3. Another page or extension on this origin: window.owNowPlaying.set({title, artist}), a
//      postMessage {type: 'openvanilla:nowplaying', title, artist} from a same-origin frame, or the
//      localStorage key 'ow:np' ({title, artist, at}) written by another tab.
// The desktop launcher's Windows media-session reader does NOT reach a browser tab (that would
// need a local web server the page talks to, which browsers increasingly block); on desktop the
// launcher feeds the desktop client instead (launcher/nowplaying.py).
//
// Never load-bearing: every failure leaves the game as it was.

const KEY_ON = 'ow:np:share';      // '1' when sharing is on
const KEY_NOW = 'ow:np';           // {title, artist, link?, at}
const KEY_SP = 'ow:np:spotify';    // {access, refresh, expires, client}
const MAX = 80;
const POLL_MS = 15000;
const STALE_MS = 30 * 60 * 1000;   // a hand-typed or companion value is dropped after 30 min

const BASE = new URL('./', import.meta.url).href;
const ls = {
  get(k) { try { return localStorage.getItem(k); } catch { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch { /* storage off */ } },
  del(k) { try { localStorage.removeItem(k); } catch { /* storage off */ } },
  json(k) { try { return JSON.parse(localStorage.getItem(k) || 'null'); } catch { return null; } },
};

/** "Title - Artist", cleaned for the 1.12 client (no control characters or pipes), max 80. */
export function format(title, artist) {
  const clean = (s) => String(s || '').replace(/[\u0000-\u001f\u007f|]/g, ' ').replace(/\s+/g, ' ').trim();
  const t = clean(title), a = clean(artist);
  let s = t && a ? `${t} - ${a}` : (t || a);
  if (s.length > MAX) s = s.slice(0, MAX - 3).trimEnd() + '...';
  return s;
}

/** A Lua string literal for any text (wenilla.lua runs Lua 5.0/5.1 source). */
export function luaString(s) {
  return '"' + String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n').replace(/\r/g, '\\r') + '"';
}

let wenilla = null;
let pushed = null;                 // last text handed to Persona (null = never)
let current = '';                  // what we want Persona to show
let pollTimer = null;

export function enabled() { return ls.get(KEY_ON) === '1'; }

function push(force) {
  const text = enabled() ? current : '';
  if (!wenilla || typeof wenilla.lua !== 'function') return;
  if (!force && text === pushed) return;
  const chunk = `if Persona and Persona.SetListening then Persona.SetListening(${luaString(text)}) return 1 end return 0`;
  Promise.resolve(wenilla.lua(chunk, 3000)).then((r) => {
    if (String(r) === '1' || r === 1) pushed = text;     // Persona not loaded yet: try again later
  }).catch(() => {});
}

function setNow(title, artist, link, from) {
  const text = format(title, artist);
  if (from !== 'storage') ls.set(KEY_NOW, JSON.stringify({ title: String(title || ''), artist: String(artist || ''), link: link || '', at: Date.now(), from }));
  if (text !== current) { current = text; push(false); updateButton(); }
}

function fromStorage() {
  const v = ls.json(KEY_NOW);
  if (v && Date.now() - (v.at || 0) < STALE_MS) setNow(v.title, v.artist, v.link, 'storage');
  else if (current) { current = ''; push(false); updateButton(); }
}

// -- Spotify (PKCE) ------------------------------------------------------------------------------

async function config() {
  try {
    const r = await fetch(BASE + 'nowplaying.json', { cache: 'no-cache' });
    return r.ok ? await r.json() : {};
  } catch { return {}; }
}

function b64url(bytes) {
  return btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export async function pkce() {
  const verifier = b64url(crypto.getRandomValues(new Uint8Array(48)));
  const challenge = b64url(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier)));
  return { verifier, challenge };
}

async function spotifyToken(body) {
  const r = await fetch('https://accounts.spotify.com/api/token', {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(body),
  });
  if (!r.ok) throw new Error('Spotify sign-in failed (' + r.status + ')');
  return r.json();
}

function saveSpotify(client, t, old) {
  ls.set(KEY_SP, JSON.stringify({
    client, access: t.access_token, refresh: t.refresh_token || (old && old.refresh) || '',
    expires: Date.now() + (Number(t.expires_in) || 3600) * 1000 - 60000,
  }));
}

export async function linkSpotify() {
  const cfg = await config();
  const client = String(cfg.spotify_client_id || '').trim();
  if (!client) throw new Error('This realm has no Spotify app set up (ow/nowplaying.json).');
  const redirect = BASE + 'nowplaying-callback.html';
  const { verifier, challenge } = await pkce();
  const st = b64url(crypto.getRandomValues(new Uint8Array(16)));
  const url = 'https://accounts.spotify.com/authorize?' + new URLSearchParams({
    client_id: client, response_type: 'code', redirect_uri: redirect, scope: 'user-read-currently-playing',
    code_challenge_method: 'S256', code_challenge: challenge, state: st,
  });
  const win = window.open(url, 'ow-spotify', 'width=480,height=720');
  if (!win) throw new Error('Allow the pop-up to link Spotify.');
  const code = await new Promise((resolve, reject) => {
    const done = (e) => {
      if (e.origin !== location.origin || !e.data || e.data.type !== 'openvanilla:spotify') return;
      window.removeEventListener('message', done);
      if (e.data.state !== st || !e.data.code) reject(new Error(e.data.error || 'Spotify sign-in was cancelled.'));
      else resolve(e.data.code);
    };
    window.addEventListener('message', done);
    setTimeout(() => { window.removeEventListener('message', done); reject(new Error('Spotify sign-in timed out.')); }, 5 * 60 * 1000);
  });
  const t = await spotifyToken({ client_id: client, grant_type: 'authorization_code', code, redirect_uri: redirect, code_verifier: verifier });
  saveSpotify(client, t, null);
  return true;
}

export function unlinkSpotify() { ls.del(KEY_SP); }

async function spotifyNow() {
  let sp = ls.json(KEY_SP);
  if (!sp || !sp.access) return null;
  if (Date.now() > (sp.expires || 0)) {
    if (!sp.refresh) { ls.del(KEY_SP); return null; }
    try { saveSpotify(sp.client, await spotifyToken({ client_id: sp.client, grant_type: 'refresh_token', refresh_token: sp.refresh }), sp); }
    catch { ls.del(KEY_SP); return null; }
    sp = ls.json(KEY_SP);
  }
  const r = await fetch('https://api.spotify.com/v1/me/player/currently-playing', { headers: { Authorization: 'Bearer ' + sp.access } });
  if (r.status === 204) return { title: '', artist: '' };          // nothing playing
  if (r.status === 401) { sp.expires = 0; ls.set(KEY_SP, JSON.stringify(sp)); return null; }
  if (!r.ok) return null;
  const j = await r.json();
  const it = j && j.item;
  if (!j || !j.is_playing || !it) return { title: '', artist: '' };
  const artist = (it.artists || []).map((a) => a.name).join(', ') || (it.show && it.show.name) || '';
  return { title: it.name || '', artist, link: (it.external_urls && it.external_urls.spotify) || '' };
}

async function poll() {
  if (!enabled() || document.hidden) return;
  try {
    const np = await spotifyNow();
    if (np) setNow(np.title, np.artist, np.link, 'spotify');
    else fromStorage();
  } catch { /* offline: keep the last value */ }
}

// -- The menu button (in ow/openvanilla.js's dock panel) ------------------------------------------------

let button = null;
function updateButton() {
  if (!button) return;
  button.textContent = enabled() ? (current ? '♫ Sharing: ' + (current.length > 24 ? current.slice(0, 23) + '…' : current) : '♫ Sharing (nothing playing)') : '♫ Listening: off';
}

function menu() {
  const panel = document.getElementById('ow-dock-panel');
  if (!panel || document.getElementById('ow-np')) return;
  button = document.createElement('button');
  button.type = 'button';
  button.id = 'ow-np';
  button.title = 'Share what you are listening to (title and artist) on your Persona profile. Off by default.';
  button.addEventListener('click', async () => {
    if (enabled()) {
      const v = prompt('Sharing what you listen to.\n\nType "Title - Artist" to set it by hand, "spotify" to link Spotify, or leave empty to stop sharing.', current);
      if (v === null) return;
      if (!v.trim()) { disable(); return; }
      if (v.trim().toLowerCase() === 'spotify') { try { await linkSpotify(); poll(); } catch (e) { alert(e.message); } return; }
      const i = v.lastIndexOf(' - ');
      if (i > 0) setNow(v.slice(0, i), v.slice(i + 3), '', 'typed'); else setNow(v, '', '', 'typed');
    } else {
      const v = prompt('Share what you are listening to with other players (title and artist only, on your Persona profile)?\n\nType "Title - Artist", or "spotify" to link your Spotify account.', '');
      if (v === null || !v.trim()) return;
      enable();
      if (v.trim().toLowerCase() === 'spotify') { try { await linkSpotify(); poll(); } catch (e) { alert(e.message); } return; }
      const i = v.lastIndexOf(' - ');
      if (i > 0) setNow(v.slice(0, i), v.slice(i + 3), '', 'typed'); else setNow(v, '', '', 'typed');
    }
  });
  panel.append(button);
  updateButton();
}

export function enable() { ls.set(KEY_ON, '1'); push(true); updateButton(); }
export function disable() { ls.del(KEY_ON); ls.del(KEY_NOW); current = ''; push(true); updateButton(); }

export function installNowPlaying(w) {
  wenilla = w || null;
  window.owNowPlaying = {
    enable, disable, enabled, linkSpotify, unlinkSpotify,
    set: (o) => { if (enabled() && o) setNow(o.title, o.artist, o.link, 'api'); },
    get: () => current,
  };
  window.addEventListener('message', (e) => {
    if (e.origin === location.origin && e.data && e.data.type === 'openvanilla:nowplaying' && enabled()) setNow(e.data.title, e.data.artist, e.data.link, 'api');
  });
  window.addEventListener('storage', (e) => { if (e.key === KEY_NOW || e.key === KEY_ON) fromStorage(); });
  if (w && typeof w.on === 'function') w.on('PLAYER_ENTERING_WORLD', () => setTimeout(() => push(true), 1500));
  try { menu(); } catch { /* no dock on this page */ }
  setTimeout(menu, 2000);
  if (enabled()) fromStorage();
  clearInterval(pollTimer);
  pollTimer = setInterval(() => { poll(); if (pushed !== (enabled() ? current : '')) push(false); }, POLL_MS);
  push(false);
  poll();
}
