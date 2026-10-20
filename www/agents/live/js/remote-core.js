// Copied from Vanilla Agents (app/web/js/remote-core.js) by scripts/export_browser_access.py. Change it there, not here.
// V-054 browser access: the sealing and the session rules of remote.html, without any page code (node can run it in tests).
// Same steps as vanilla_agents/remote/seal.py:
//   shared = X25519(device private, PC public); key[dir] = HKDF-SHA256(shared, salt = pair id, info = "va-remote v1 <dir> <device public b64url>")
//   frame  = b64url(iv 12 || AES-256-GCM(key, iv, JSON, aad = pair + "|" + device id))
const te = new TextEncoder(), td = new TextDecoder();
const subtle = globalThis.crypto.subtle;

export const b64e = (u8) => { let s = ''; for (const b of u8) s += String.fromCharCode(b); return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''); };
export const b64d = (s) => { const t = atob(String(s).replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((String(s).length + 3) % 4)); return Uint8Array.from(t, (c) => c.charCodeAt(0)); };
const cat = (...parts) => { const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let i = 0; for (const p of parts) { out.set(p, i); i += p.length; } return out; };

// a new device: the private key never leaves this browser (not extractable); the public one is sent when pairing
export async function newDevice() {
  const kp = await subtle.generateKey({ name: 'X25519' }, false, ['deriveBits']);
  const pub = new Uint8Array(await subtle.exportKey('raw', kp.publicKey));
  return { priv: kp.privateKey, pub, id: await deviceId(pub) };
}

export async function deviceId(pub) {
  return b64e(new Uint8Array(await subtle.digest('SHA-256', pub))).slice(0, 16);
}

export async function proof(secret, pub, pair) {
  const k = await subtle.importKey('raw', secret, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return b64e(new Uint8Array(await subtle.sign('HMAC', k, cat(pub, te.encode(pair)))));
}

export async function keys(priv, pcPub, pair, devPub) {
  const their = await subtle.importKey('raw', pcPub, { name: 'X25519' }, false, []);
  const shared = await subtle.deriveBits({ name: 'X25519', public: their }, priv, 256);
  const base = await subtle.importKey('raw', shared, 'HKDF', false, ['deriveKey']);
  const one = (dir) => subtle.deriveKey({ name: 'HKDF', hash: 'SHA-256', salt: te.encode(pair), info: te.encode('va-remote v1 ' + dir + ' ' + b64e(devPub)) },
    base, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
  return { d2p: await one('d2p'), p2d: await one('p2d') };
}

export async function seal(key, obj, pair, dev) {
  const iv = globalThis.crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await subtle.encrypt({ name: 'AES-GCM', iv, additionalData: te.encode(pair + '|' + dev) }, key, te.encode(JSON.stringify(obj))));
  return b64e(cat(iv, ct));
}

export async function unseal(key, data, pair, dev) {
  const raw = b64d(data);
  if (raw.length < 28) throw new Error('frame too short');
  const pt = await subtle.decrypt({ name: 'AES-GCM', iv: raw.slice(0, 12), additionalData: te.encode(pair + '|' + dev) }, key, raw.slice(12));
  const o = JSON.parse(td.decode(pt));
  if (!o || typeof o !== 'object' || Array.isArray(o)) throw new Error('not an object');
  return o;
}

export const randomId = (n = 12) => b64e(globalThis.crypto.getRandomValues(new Uint8Array(n)));

// One connection to the relay for one paired PC.
//   link = { relay, pair, pcPub (Uint8Array), dev: {priv, pub, id} }
//   on = { status(text, online), paired({scope, name} | null), welcome({scope, name}), state(snapshot) }
// .pair(secret, name) once; .req(method, path, body) -> Promise<{status, body}>
export function connect(link, on, WS = globalThis.WebSocket) {
  let ws = null, k = null, sid = null, ch = null, n = 0, nIn = 0, rid = 0, closed = false, wait = 1000, timer = null;
  const pending = new Map();
  let pairWaiter = null, outq = Promise.resolve();
  const ready = (async () => { k = await keys(link.dev.priv, link.pcPub, link.pair, link.dev.pub); })();

  function send(obj) { if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj)); }
  // outgoing frames leave one at a time, numbered in the order they leave (the PC drops any n that does not grow)
  function sealed(make) {
    outq = outq.then(async () => { const obj = make(); if (obj) send({ t: 'msg', data: await seal(k.d2p, obj, link.pair, link.dev.id) }); }).catch(() => {});
    return outq;
  }

  function hello() {
    sid = randomId(); ch = null; n = 0; nIn = 0;
    return sealed(() => ({ k: 'hello', sid }));
  }

  async function onMessage(ev) {
    let m; try { m = JSON.parse(ev.data); } catch (e) { return; }
    if (m.t === 'pc') {
      on.status(m.online ? 'pc_online' : 'pc_offline', m.online);
      if (m.online && !pairWaiter) await hello();
      return;
    }
    if (m.t === 'error') { on.status('relay_error', false, m.error); return; }
    if (m.t !== 'msg') return;
    let o; try { o = await unseal(k.p2d, m.data, link.pair, link.dev.id); } catch (e) { return; }      // not for us, or changed on the way
    if (o.k === 'paired' || o.k === 'refused') {
      if (pairWaiter) { const w = pairWaiter; pairWaiter = null; w(o.k === 'paired' ? { scope: o.scope, name: o.name } : null); }
      return;
    }
    if (o.sid !== sid || typeof o.n !== 'number' || o.n <= nIn) return;      // an older session's frame, or a replay
    nIn = o.n;
    if (o.k === 'welcome') {
      ch = o.ch;
      sealed(() => ({ k: 'sub', ch, n: ++n }));
      on.welcome({ scope: o.scope, name: o.name });
    } else if (o.k === 'res') {
      const p = pending.get(o.id);
      if (p) { pending.delete(o.id); p({ status: o.status, body: o.body }); }
    } else if (o.k === 'state') on.state(o.state);
  }

  function open() {
    if (closed) return;
    on.status('connecting', false);
    ws = new WS(link.relay);
    ws.onopen = () => { wait = 1000; send({ t: 'dev', pair: link.pair, dev: link.dev.id }); };
    ws.onmessage = (ev) => { ready.then(() => onMessage(ev)); };
    ws.onclose = () => {
      ch = null;
      for (const p of pending.values()) p({ status: 0, body: { error: 'offline' } });
      pending.clear();
      if (closed) return;
      on.status('reconnecting', false);
      timer = setTimeout(open, wait);
      wait = Math.min(60000, wait * 2);
    };
  }

  return {
    start() { ready.then(open); },
    stop() { closed = true; clearTimeout(timer); if (ws) ws.close(); },
    async pair(secret, name) {
      await ready;
      const done = new Promise((res) => { pairWaiter = res; setTimeout(() => { if (pairWaiter === res) { pairWaiter = null; res(undefined); } }, 15000); });
      const go = async () => send({ t: 'pair', pub: b64e(link.dev.pub), proof: await proof(secret, link.dev.pub, link.pair), data: await seal(k.d2p, { name }, link.pair, link.dev.id) });
      if (ws && ws.readyState === 1) await go(); else { const iv = setInterval(async () => { if (ws && ws.readyState === 1) { clearInterval(iv); await go(); } }, 100); setTimeout(() => clearInterval(iv), 15000); }
      const r = await done;
      if (r) await hello();
      return r;
    },
    async req(method, path, body) {
      if (!ch) return { status: 0, body: { error: 'not connected' } };
      rid += 1;
      const id = rid;
      const p = new Promise((res) => { pending.set(id, res); setTimeout(() => { if (pending.delete(id)) res({ status: 0, body: { error: 'no answer' } }); }, 20000); });
      sealed(() => (ch ? { k: 'req', ch, n: ++n, id, method, path, body: body || null } : null));
      return p;
    },
  };
}
