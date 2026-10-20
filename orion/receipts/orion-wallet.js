// orion-wallet.js  (Open Vanilla / Orion Network)
// Browser/Node wallet for Proof-of-Uptime receipts. Uses WebCrypto Ed25519 only.
// The signed bytes match orion_receipts.py: canonical JSON, sorted keys, no spaces.
//
//   const w = await OrionWallet.load(store)      // store: {get(k), set(k,v)} e.g. IndexedDB wrapper
//   w.pub                                        // wallet public key (base64url)
//   await w.signReceipt({type:'relay', host, realm, window, bytes}, myCert)  -> receipt for the host
//   w.addReceipt(r) / w.pending(realm) / w.forget(hashes)                    -> host side
//   POST /api/orion/redeem {cert: w.cert(realm), receipts: w.pending(realm)}

const WINDOW = 300;
const subtle = globalThis.crypto.subtle;

const b64 = (u8) => {
  let s = '';
  for (const c of new Uint8Array(u8)) s += String.fromCharCode(c);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};
const unb64 = (s) => {
  const t = atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4));
  return Uint8Array.from(t, (c) => c.charCodeAt(0));
};

// Canonical JSON identical to Python json.dumps(sort_keys=True, separators=(',',':'), ensure_ascii=False)
export function canon(v) {
  if (v === null || typeof v !== 'object') return JSON.stringify(v);
  if (Array.isArray(v)) return '[' + v.map(canon).join(',') + ']';
  return '{' + Object.keys(v).sort().map((k) => JSON.stringify(k) + ':' + canon(v[k])).join(',') + '}';
}
const bytes = (o) => new TextEncoder().encode(canon(o));

export const windowOf = (t) => Math.floor(t) - (Math.floor(t) % WINDOW);

export async function receiptHash(r) {
  const b = r.body;
  const key = { type: b.type, host: b.host, peer: b.peer, realm: b.realm, window: b.window };
  const h = new Uint8Array(await subtle.digest('SHA-256', bytes(key)));
  return [...h].map((x) => x.toString(16).padStart(2, '0')).join('');
}

export async function verify(pub, body, sig) {
  try {
    const k = await subtle.importKey('raw', unb64(pub), { name: 'Ed25519' }, false, ['verify']);
    return await subtle.verify({ name: 'Ed25519' }, k, unb64(sig), bytes(body));
  } catch (e) {
    return false;
  }
}

export class OrionWallet {
  static async load(store) {
    const w = new OrionWallet();
    w.store = store;
    let d = await store.get('orion-wallet');
    if (!d) {
      const kp = await subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify']);
      d = {
        v: 1,
        jwk: await subtle.exportKey('jwk', kp.privateKey),
        pub: b64(await subtle.exportKey('raw', kp.publicKey)),
        certs: {},
        receipts: [],
      };
      await store.set('orion-wallet', d);
    }
    w.d = d;
    w.pub = d.pub;
    w.key = await subtle.importKey('jwk', d.jwk, { name: 'Ed25519' }, false, ['sign']);
    return w;
  }

  save() { return this.store.set('orion-wallet', this.d); }
  cert(realm) { return this.d.certs[realm] || null; }
  setCert(realm, cert) { this.d.certs[realm] = cert; return this.save(); }

  async sign(body) {
    return b64(await subtle.sign({ name: 'Ed25519' }, this.key, bytes(body)));
  }

  // Peer side: sign a receipt for a host that relayed traffic or seeded chunks for us.
  async signReceipt({ type, host, realm, window, bytes: n }, myCert) {
    const nonce = b64(globalThis.crypto.getRandomValues(new Uint8Array(8)));
    const body = { v: 1, type, host, peer: this.pub, realm, window: windowOf(window), bytes: Math.floor(n), nonce };
    return { body, sig: await this.sign(body), cert: myCert };
  }

  // Host side: keep receipts addressed to us (checked before storing).
  async addReceipt(r) {
    if (!r || !r.body || r.body.host !== this.pub) return false;
    if (!(await verify(r.body.peer, r.body, r.sig))) return false;
    this.d.receipts.push(r);
    await this.save();
    return true;
  }

  pending(realm) { return this.d.receipts.filter((r) => !realm || r.body.realm === realm); }

  async forget(hashes) {
    const hs = new Set(hashes);
    const keep = [];
    for (const r of this.d.receipts) if (!hs.has(await receiptHash(r))) keep.push(r);
    this.d.receipts = keep;
    await this.save();
  }
}

// Byte meter: count what we received from each host per 5-minute window, then sign on rollover.
export class UptimeMeter {
  constructor(wallet, realm, cert, deliver) {
    Object.assign(this, { wallet, realm, cert, deliver, cur: new Map() });
  }
  add(host, type, n, now = Date.now() / 1000) {
    const k = host + '|' + type + '|' + windowOf(now);
    this.cur.set(k, (this.cur.get(k) || 0) + n);
  }
  async flush(now = Date.now() / 1000) {
    const open = windowOf(now);
    for (const [k, n] of [...this.cur]) {
      const [host, type, win] = k.split('|');
      if (+win >= open) continue;
      this.cur.delete(k);
      const r = await this.wallet.signReceipt({ type, host, realm: this.realm, window: +win, bytes: n }, this.cert);
      await this.deliver(host, r);   // sent back to the host over the same relay/seed channel
    }
  }
}
