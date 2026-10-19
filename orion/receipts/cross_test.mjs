// Cross-check helper. Wallets persist in a JSON file so Python can certify them between steps.
//   node cross_test.mjs keys  <dir>                 -> writes <dir>/pubs.json
//   node cross_test.mjs sign  <dir> <now>           -> peers meter traffic, sign, host stores; writes <dir>/host_receipts.json
import { OrionWallet, UptimeMeter, receiptHash } from './orion-wallet.js';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';

const [, , cmd, dir, nowArg] = process.argv;
const fileStore = (name) => {
  const p = `${dir}/${name}.json`;
  return {
    get: async () => (existsSync(p) ? JSON.parse(readFileSync(p, 'utf8')) : undefined),
    set: async (_k, v) => writeFileSync(p, JSON.stringify(v)),
  };
};
const host = await OrionWallet.load(fileStore('host'));
const peers = [];
for (let i = 0; i < 5; i++) peers.push(await OrionWallet.load(fileStore('peer' + i)));

if (cmd === 'keys') {
  writeFileSync(`${dir}/pubs.json`, JSON.stringify({ host: host.pub, peers: peers.map((p) => p.pub) }));
} else if (cmd === 'sign') {
  const certs = JSON.parse(readFileSync(`${dir}/certs.json`, 'utf8'));
  const now = Number(nowArg);
  let stored = 0;
  for (let i = 0; i < peers.length; i++) {
    const m = new UptimeMeter(peers[i], 'classicplus', certs.peers[i], async (h, r) => {
      if (h === host.pub && (await host.addReceipt(r))) stored++;
    });
    // 24 windows (2 hours) of relayed traffic from this host, 100 KB each
    for (let w = 0; w < 24; w++) m.add(host.pub, 'relay', 100 * 1024, now - 3 * 3600 + w * 300 + 7);
    await m.flush(now);
  }
  // a forged receipt the host must refuse
  const bad = await peers[0].signReceipt({ type: 'relay', host: host.pub, realm: 'classicplus', window: now - 600, bytes: 1e6 }, certs.peers[0]);
  bad.body.bytes = 9e9;
  const refused = !(await host.addReceipt(bad));
  writeFileSync(`${dir}/host_receipts.json`, JSON.stringify({
    receipts: host.pending('classicplus'),
    hashes: await Promise.all(host.pending('classicplus').map(receiptHash)),
    stored, refused,
  }));
}
