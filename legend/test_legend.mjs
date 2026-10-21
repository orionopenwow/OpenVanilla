// Cross-checks legend.js against legend.py output. Run: node test_legend.mjs  (Node 18+)
import { readFileSync, mkdtempSync, writeFileSync, readdirSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import {
  canonical, verifyLegend, heroFromKey, heroSign, heroVerify, docHash, b64uDecode, signingBytes,
} from './legend.js';

const here = dirname(fileURLToPath(import.meta.url));
const V = JSON.parse(readFileSync(join(here, 'vectors.json'), 'utf8'));
const clone = (x) => JSON.parse(JSON.stringify(x));
let passed = 0;
const tests = [];
const test = (name, fn) => tests.push([name, fn]);
const keysFrom = (kf) => ({ fetchKeys: async () => clone(kf) });

test('canonical JSON matches Python', () => {
  for (const c of V.canonical) assert.equal(canonical(c.value), c.text);
  for (const bad of [1.5, 2 ** 53, NaN, '\ud800', () => 1]) assert.throws(() => canonical(bad));
  assert.equal(canonical(-0), '0');
  assert.equal(new TextDecoder().decode(signingBytes(V.documents.valid[0])), V.documents.signing_bytes_utf8[0]);
});

test('hero vector: Hero ID and signature', async () => {
  const h = V.hero;
  assert.equal(await heroFromKey(h.key_line), h.hero_id);
  assert.equal(await heroSign(h.key_line, h.message), h.signature); // Ed25519 is deterministic
  assert.equal(await heroVerify(h.hero_id, h.message, h.signature), true);
  assert.equal(await heroVerify(h.hero_id, h.message + 'x', h.signature), false);
  assert.equal(await heroVerify('ovh1.bad', h.message, h.signature), false);
  assert.equal(await heroVerify(h.hero_id, h.message, 'AAAA'), false);
  await assert.rejects(heroFromKey('ovk1..AAAA'));
});

test('verifies vector documents', async () => {
  for (const d of V.documents.valid) {
    const r = await verifyLegend(d, keysFrom(V.realm.keyfile));
    assert.equal(r.valid, true, r.reason);
    assert.equal(r.realm, 'duels.openvanilla.app');
    assert.equal(r.realmName, 'Duels');
    assert.equal(r.hero, true);
  }
  assert.equal(await docHash(V.documents.valid[0]), V.documents.prev_of_second);
  // accepts JSON text too, any key order
  const text = JSON.stringify(Object.fromEntries(Object.entries(V.documents.valid[0]).reverse()), null, 3);
  assert.equal((await verifyLegend(text, keysFrom(V.realm.keyfile))).valid, true);
});

test('rejects tampering, revoked and expired keys', async () => {
  for (const inv of V.documents.invalid) {
    const r = await verifyLegend(inv.doc, keysFrom(V.realm.keyfile));
    assert.equal(r.valid, false);
    assert.equal(r.reason, inv.reason);
  }
  const doc = V.documents.valid[0];
  const kid = V.realm.kid;
  const cases = [
    [(d) => { d.subject.name = 'X'; }, null, 'signature'],
    [(d) => { d.records.extra = 1; }, null, 'signature'],
    [(d) => { d.realm = 'evil.example.com'; }, null, 'subject id'],
    [null, (k) => { k.revoked = [kid]; }, 'revoked'],
    [null, (k) => { k.keys[0].until = doc.issued; }, 'expired'],
    [null, (k) => { k.keys[0].since = doc.issued + 1; }, 'before the key'],
    [null, (k) => { k.realm.host = 'other.example.org'; }, 'different realm'],
    [(d) => { d.records.f = 1.5; }, null, 'canonical'],
  ];
  for (const [fd, fk, reason] of cases) {
    const d = clone(doc), k = clone(V.realm.keyfile);
    if (fd) fd(d);
    if (fk) fk(k);
    const r = await verifyLegend(d, keysFrom(k));
    assert.equal(r.valid, false);
    assert.ok(r.reason.includes(reason), `${r.reason} should mention ${reason}`);
  }
  const r = await verifyLegend(doc, { fetchKeys: async () => { throw new Error('offline'); } });
  assert.equal(r.reason, 'offline');
});

test('verifies fresh documents from legend_issue.py (random key)', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'legend-'));
  try {
    writeFileSync(join(dir, 'rows.tsv'),
      'guid\tname\trace\tclass\tgender\tlevel\taccount\trating\tbest\twins\tlosses\n' +
      '7\tZül\'jin\t8\t3\t0\t60\t70\t1999\t2001\t50\t9\n' +
      '8\tAnduin 😀\t1\t5\t0\t42\t71\t1500\t1500\t0\t0\n');
    writeFileSync(join(dir, 'heroes.json'), JSON.stringify({ heroes: [{ account: 70, hero: V.hero.hero_id }] }));
    execFileSync('python3', [join(here, 'legend_issue.py'), '--host', 'duels.openvanilla.app', '--name', 'Duels',
      '--key', join(dir, 'duels.key'), '--rows', join(dir, 'rows.tsv'), '--heroes', join(dir, 'heroes.json'),
      '--out', join(dir, 'out'), '--wellknown', join(dir, 'wk.json')], { stdio: 'pipe' });
    const kf = JSON.parse(readFileSync(join(dir, 'wk.json'), 'utf8'));
    const files = readdirSync(join(dir, 'out')).filter((f) => /^\d+\.json$/.test(f));
    assert.equal(files.length, 2);
    for (const f of files) {
      const d = JSON.parse(readFileSync(join(dir, 'out', f), 'utf8'));
      const r = await verifyLegend(d, keysFrom(kf));
      assert.equal(r.valid, true, r.reason);
      assert.equal(r.hero, f === '7.json');
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('Python and JS derive the same Hero ID for random keys', async () => {
  for (let i = 0; i < 5; i++) {
    const secret = crypto.getRandomValues(new Uint8Array(32));
    const line = 'ovk1.K' + i + '.' + Buffer.from(secret).toString('base64url');
    const py = execFileSync('python3', [join(here, 'legend.py'), 'hero', line, '--sign', 'challenge:n' + i],
      { encoding: 'utf8' }).trim().split('\n');
    assert.equal(await heroFromKey(line), py[0]);
    assert.equal(await heroSign(line, 'challenge:n' + i), py[1]);
    assert.equal(await heroVerify(py[0], 'challenge:n' + i, py[1]), true);
    assert.equal(b64uDecode(py[0].slice(5)).length, 32);
  }
});

test('legend.html inlines the current legend.js', () => {
  const html = readFileSync(join(here, '..', 'www', 'legend.html'), 'utf8');
  const lib = readFileSync(join(here, 'legend.js'), 'utf8').trim();
  assert.ok(html.includes(lib), 'legend.html is out of date: re-run build_html.py');
});

const [major] = process.versions.node.split('.').map(Number);
assert.ok(major >= 18, 'Node 18+ required');
for (const [name, fn] of tests) {
  try {
    await fn();
    passed++;
    console.log('ok   ' + name);
  } catch (e) {
    console.log('FAIL ' + name + '\n     ' + (e && e.stack || e));
    process.exitCode = 1;
  }
}
console.log(`${passed}/${tests.length} passed (node ${process.version})`);
