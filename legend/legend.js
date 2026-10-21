// Legend: signed, portable character records for Open Vanilla realms.
// Zero-dependency ES module for browsers and Node 18+ (WebCrypto Ed25519 + HKDF).
// Licence: MIT. See SPEC.md.

export const LEGEND_PREFIX = 'openvanilla-legend-v1\n';
export const HERO_PREFIX = 'openvanilla-hero-v1\n';
export const WELL_KNOWN_PATH = '/.well-known/openvanilla-legend.json';
const HERO_SALT = 'openvanilla-hero-v1';
const HERO_INFO = 'ed25519-seed';
const PKCS8_PREFIX = '302e020100300506032b657004220420';
const HOST_RE = /^(?=.{1,253}$)[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$/;
const HERO_RE = /^ovh1\.[A-Za-z0-9_-]{43}$/;

const utf8 = new TextEncoder();
const subtle = () => {
  const s = globalThis.crypto && globalThis.crypto.subtle;
  if (!s) throw new Error('WebCrypto is not available (use HTTPS or a modern browser)');
  return s;
};

// ---------------------------------------------------------------- base64url

export function b64uEncode(bytes) {
  const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let bin = '';
  for (let i = 0; i < b.length; i++) bin += String.fromCharCode(b[i]);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function b64uDecode(s, length) {
  if (typeof s !== 'string') throw new Error('base64url value must be a string');
  s = s.replace(/=+$/, '');
  if (!/^[A-Za-z0-9_-]*$/.test(s) || s.length % 4 === 1) throw new Error('bad base64url');
  const bin = atob(s.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (s.length % 4)) % 4));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  if (b64uEncode(out) !== s) throw new Error('non-canonical base64url');
  if (length !== undefined && out.length !== length) throw new Error(`expected ${length} bytes, got ${out.length}`);
  return out;
}

const hexBytes = (h) => new Uint8Array(h.match(/../g).map((x) => parseInt(x, 16)));
const concat = (...parts) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
};

// ---------------------------------------------------------------- canonical JSON

function encStr(s) {
  let out = '"';
  for (const ch of s) {
    const c = ch.codePointAt(0);
    if (ch === '"') out += '\\"';
    else if (ch === '\\') out += '\\\\';
    else if (ch === '\n') out += '\\n';
    else if (ch === '\r') out += '\\r';
    else if (ch === '\t') out += '\\t';
    else if (ch === '\b') out += '\\b';
    else if (ch === '\f') out += '\\f';
    else if (c < 0x20) out += '\\u' + c.toString(16).padStart(4, '0');
    else if (c >= 0xd800 && c <= 0xdfff) throw new Error('lone surrogate in string');
    else out += ch;
  }
  return out + '"';
}

// Sort by Unicode code point (not UTF-16 code unit).
function cmpCodePoints(a, b) {
  const ia = a[Symbol.iterator](), ib = b[Symbol.iterator]();
  for (;;) {
    const x = ia.next(), y = ib.next();
    if (x.done || y.done) return x.done === y.done ? 0 : x.done ? -1 : 1;
    const d = x.value.codePointAt(0) - y.value.codePointAt(0);
    if (d) return d;
  }
}

/** Canonical JSON text for a JSON value. Encode with UTF-8 to get the signed bytes. */
export function canonical(v) {
  if (v === null) return 'null';
  if (v === true) return 'true';
  if (v === false) return 'false';
  if (typeof v === 'number') {
    if (!Number.isSafeInteger(v)) throw new Error('only integers in ±(2^53-1) are allowed');
    return String(v === 0 ? 0 : v);
  }
  if (typeof v === 'string') return encStr(v);
  if (Array.isArray(v)) return '[' + v.map(canonical).join(',') + ']';
  if (typeof v === 'object') {
    const keys = Object.keys(v).sort(cmpCodePoints);
    return '{' + keys.map((k) => encStr(k) + ':' + canonical(v[k])).join(',') + '}';
  }
  throw new Error('unsupported type: ' + typeof v);
}

export function signingBytes(doc) {
  const body = {};
  for (const k of Object.keys(doc)) if (k !== 'sig') body[k] = doc[k];
  return utf8.encode(LEGEND_PREFIX + canonical(body));
}

/** Value for the next document's "prev". */
export async function docHash(doc) {
  return b64uEncode(new Uint8Array(await subtle().digest('SHA-256', utf8.encode(canonical(doc)))));
}

export async function kidFor(pub) {
  return b64uEncode(new Uint8Array(await subtle().digest('SHA-256', pub))).slice(0, 16);
}

// ---------------------------------------------------------------- Ed25519 via WebCrypto

async function edVerify(pub, msg, sig) {
  let key;
  try {
    key = await subtle().importKey('raw', pub, { name: 'Ed25519' }, false, ['verify']);
  } catch (e) {
    if (e && e.name === 'NotSupportedError') throw new Error('this browser does not support Ed25519');
    return false; // invalid point
  }
  try {
    return await subtle().verify({ name: 'Ed25519' }, key, sig, msg);
  } catch {
    return false;
  }
}

async function heroSeed(line) {
  if (typeof line !== 'string') throw new Error('Hero Key must be a string');
  const parts = line.trim().split('.');
  if (parts.length < 3 || parts[0] !== 'ovk1' || !parts[1]) throw new Error('not a Hero Key line (ovk1.<key_id>.<secret>)');
  const secret = b64uDecode(parts[parts.length - 1], 32);
  const ikm = await subtle().importKey('raw', secret, 'HKDF', false, ['deriveBits']);
  const bits = await subtle().deriveBits(
    { name: 'HKDF', hash: 'SHA-256', salt: utf8.encode(HERO_SALT), info: utf8.encode(HERO_INFO) }, ikm, 256);
  return new Uint8Array(bits);
}

async function privateKey(seed) {
  return subtle().importKey('pkcs8', concat(hexBytes(PKCS8_PREFIX), seed), { name: 'Ed25519' }, true, ['sign']);
}

// ---------------------------------------------------------------- Hero IDs

export async function heroFromKey(line) {
  const jwk = await subtle().exportKey('jwk', await privateKey(await heroSeed(line)));
  return 'ovh1.' + jwk.x;
}

export async function heroSign(line, message) {
  const key = await privateKey(await heroSeed(line));
  const sig = await subtle().sign({ name: 'Ed25519' }, key, utf8.encode(HERO_PREFIX + message));
  return b64uEncode(new Uint8Array(sig));
}

export async function heroVerify(hero, message, sig) {
  if (typeof hero !== 'string' || !HERO_RE.test(hero.trim())) return false;
  let pub, s;
  try {
    pub = b64uDecode(hero.trim().slice(5), 32);
    s = b64uDecode(String(sig).trim(), 64);
  } catch {
    return false;
  }
  return edVerify(pub, utf8.encode(HERO_PREFIX + message), s);
}

// ---------------------------------------------------------------- verification

export async function defaultFetchKeys(host) {
  if (!HOST_RE.test(host || '')) throw new Error('bad realm host');
  const r = await fetch('https://' + host + WELL_KNOWN_PATH, { credentials: 'omit' });
  if (!r.ok) throw new Error(`could not fetch keys from ${host} (HTTP ${r.status})`);
  return r.json();
}

/**
 * Verify a Legend document.
 * opts.fetchKeys(host) -> key file object (default: HTTPS fetch of the well-known file).
 * Resolves to { valid, reason, realm, issued, hero, kid, realmName }.
 */
export async function verifyLegend(doc, { fetchKeys = defaultFetchKeys } = {}) {
  const res = { valid: false, reason: '', realm: null, issued: null, hero: false, kid: null, realmName: null };
  const fail = (m) => { res.reason = m; return res; };
  if (typeof doc === 'string') {
    try { doc = JSON.parse(doc); } catch (e) { return fail('document is not valid JSON'); }
  }
  if (!doc || typeof doc !== 'object' || Array.isArray(doc)) return fail('document is not a JSON object');
  if (doc.legend !== 1) return fail('unsupported legend version');
  const { realm, kid, issued, sig } = doc;
  res.realm = realm; res.kid = kid;
  if (typeof realm !== 'string' || !HOST_RE.test(realm)) return fail('bad realm host');
  if (!Number.isSafeInteger(issued)) return fail('bad issued time');
  res.issued = issued;
  if (typeof kid !== 'string' || typeof sig !== 'string') return fail('missing kid or sig');
  if (typeof doc.kind !== 'string') return fail('missing kind');
  const hero = doc.hero === undefined ? null : doc.hero;
  if (hero !== null && (typeof hero !== 'string' || !HERO_RE.test(hero))) return fail('bad hero id');
  res.hero = hero !== null;
  if (doc.kind === 'character') {
    const s = doc.subject;
    if (!s || typeof s !== 'object' || typeof s.id !== 'string' || !s.id.startsWith(realm + '/'))
      return fail('subject id does not belong to this realm');
  }
  let sigBytes, msg;
  try { sigBytes = b64uDecode(sig, 64); } catch { return fail('bad signature encoding'); }
  try { msg = signingBytes(doc); } catch (e) { return fail('document is not canonical-able: ' + e.message); }

  let kf;
  try { kf = await fetchKeys(realm); } catch (e) { return fail(e.message || 'could not fetch realm keys'); }
  if (typeof kf === 'string') { try { kf = JSON.parse(kf); } catch { return fail('realm key file is not valid JSON'); } }
  if (!kf || kf.legend !== 1) return fail('bad realm key file');
  if (!kf.realm || kf.realm.host !== realm) return fail('key file is for a different realm');
  res.realmName = typeof kf.realm.name === 'string' ? kf.realm.name : null;
  if (Array.isArray(kf.revoked) && kf.revoked.includes(kid)) return fail(`key ${kid} is revoked`);
  const key = (Array.isArray(kf.keys) ? kf.keys : []).find((k) => k && k.kid === kid);
  if (!key) return fail(`key ${kid} not published by ${realm}`);
  if (key.alg !== 'Ed25519') return fail('unsupported key algorithm');
  let pub;
  try { pub = b64uDecode(key.pub, 32); } catch { return fail('bad public key'); }
  if ((await kidFor(pub)) !== kid) return fail('published kid does not match its public key');
  if (!Number.isSafeInteger(key.since) || key.since > issued) return fail('issued before the key was valid');
  if (key.until !== null && key.until !== undefined && (!Number.isSafeInteger(key.until) || issued >= key.until))
    return fail('issued after the key expired');
  try {
    if (!(await edVerify(pub, msg, sigBytes))) return fail('signature does not match');
  } catch (e) {
    return fail(e.message);
  }
  res.valid = true;
  res.reason = 'verified by ' + realm;
  return res;
}
