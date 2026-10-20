// The web client's "Share what I'm listening to" (realm/www/nowplaying.js) with a fake game, storage,
// fetch and clock. Run: node tests/nowplaying_test.mjs   (exit 0 = all good)
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
let failed = 0;
const ok = (c, m) => { if (c) console.log('ok  ', m); else { failed++; console.log('FAIL', m); } };

// ---- fakes: localStorage, window, document, fetch, the game
const store = new Map();
globalThis.localStorage = {
  getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => store.set(k, String(v)), removeItem: (k) => store.delete(k),
};
const listeners = {};
globalThis.window = globalThis;
globalThis.addEventListener = (t, f) => { (listeners[t] ||= []).push(f); };
globalThis.removeEventListener = () => {};
globalThis.document = { hidden: false, getElementById: () => null };
globalThis.location = { origin: 'https://play.test', pathname: '/' };
let spotify = null;     // what the fake Spotify API answers
const calls = [];
globalThis.fetch = async (url, init = {}) => {
  calls.push(String(url));
  if (String(url).endsWith('nowplaying.json')) return { ok: true, status: 200, json: async () => ({ spotify_client_id: 'cid' }) };
  if (String(url).includes('api.spotify.com')) {
    if (!spotify) return { ok: true, status: 204, json: async () => null };
    return { ok: true, status: 200, json: async () => spotify };
  }
  if (String(url).includes('accounts.spotify.com/api/token')) return { ok: true, status: 200, json: async () => ({ access_token: 'new', expires_in: 3600 }) };
  return { ok: false, status: 404, json: async () => ({}) };
};
const lua = [];
let personaLoaded = true;
const game = {
  lua: async (chunk) => { lua.push(chunk); return personaLoaded ? 1 : 0; },
  on: (ev, f) => { (listeners['game:' + ev] ||= []).push(f); },
};
const tick = () => new Promise((r) => setTimeout(r, 0));
const lastText = () => { const m = /SetListening\((".*")\)/.exec(lua[lua.length - 1] || ''); return m ? JSON.parse(m[1]) : null; };

const np = await import(pathToFileURL(path.join(here, '..', 'realm', 'www', 'nowplaying.js')).href);

ok(np.format('Song', 'Band') === 'Song - Band', 'format: "Title - Artist"');
ok(np.format('x'.repeat(100), 'y').length === 80 && np.format('x'.repeat(100), 'y').endsWith('...'), 'format: 80 characters at most');
ok(np.format('A|cffff0000red|r', '') === 'A cffff0000red r', 'format: no pipes (no colour codes in game)');
ok(np.luaString('say "hi"\\\n') === '"say \\"hi\\"\\\\\\n"', 'luaString escapes');

np.installNowPlaying(game);
await tick(); await tick();
ok(!np.enabled(), 'off by default');
ok(lua.length === 1 && lastText() === '', 'off: only clears (pushes "")');
ok(!calls.some((u) => u.includes('spotify')), 'off: Spotify is never asked');

window.owNowPlaying.set({ title: 'Ignored', artist: 'X' });
await tick();
ok(lastText() === '', 'off: the companion API is ignored');

np.enable();
window.owNowPlaying.set({ title: 'Tavern Song', artist: 'Unknown Bard' });
await tick();
ok(lastText() === 'Tavern Song - Unknown Bard', 'on: the value reaches Persona.SetListening');
ok(JSON.parse(store.get('ow:np')).title === 'Tavern Song', 'kept for other tabs');
const n = lua.length;
window.owNowPlaying.set({ title: 'Tavern Song', artist: 'Unknown Bard' });
await tick();
ok(lua.length === n, 'the same song again is not re-sent');

// world entry re-sends (a /reload or a new character gets it again)
for (const f of listeners['game:PLAYER_ENTERING_WORLD'] || []) f();
await new Promise((r) => setTimeout(r, 1600));
ok(lua.length === n + 1 && lastText() === 'Tavern Song - Unknown Bard', 'sent again after entering the world');

// another tab wrote a new value
store.set('ow:np', JSON.stringify({ title: 'Other Tab', artist: 'B', at: Date.now() }));
for (const f of listeners.storage) f({ key: 'ow:np' });
await tick();
ok(lastText() === 'Other Tab - B', 'another tab (storage event)');

// Spotify linked: polled, playing -> shown; nothing playing -> cleared
store.set('ow:np:spotify', JSON.stringify({ client: 'cid', access: 'tok', refresh: 'r', expires: Date.now() + 600000 }));
spotify = { is_playing: true, item: { name: 'Bloodborne', artists: [{ name: 'Ryan Amon' }], external_urls: { spotify: 'https://open.spotify.com/track/1' } } };
np.installNowPlaying(game);
await tick(); await tick(); await tick();
ok(lastText() === 'Bloodborne - Ryan Amon', 'Spotify: currently-playing reaches Persona');
spotify = null;
np.installNowPlaying(game);
await tick(); await tick(); await tick();
ok(lastText() === '', 'Spotify: nothing playing clears it');

// expired token is refreshed
store.set('ow:np:spotify', JSON.stringify({ client: 'cid', access: 'old', refresh: 'r', expires: 0 }));
spotify = { is_playing: true, item: { name: 'Again', artists: [{ name: 'Z' }] } };
np.installNowPlaying(game);
await tick(); await tick(); await tick(); await tick();
ok(calls.some((u) => u.includes('accounts.spotify.com/api/token')) && JSON.parse(store.get('ow:np:spotify')).access === 'new', 'Spotify: an expired token is refreshed');

// turning it off clears what others see
np.disable();
await tick();
ok(lastText() === '' && !store.has('ow:np'), 'off again: cleared in game and in storage');

// Persona not loaded yet: retried until it answers
lua.length = 0; personaLoaded = false; store.delete('ow:np:spotify');
np.enable(); window.owNowPlaying.set({ title: 'Late', artist: 'L' });
await tick();
personaLoaded = true;
np.installNowPlaying(game);
await tick(); await tick();
ok(lastText() === 'Late - L', 'retried once Persona is loaded');

console.log(failed ? `\n${failed} failed` : '\nall passed');
process.exit(failed ? 1 : 0);
