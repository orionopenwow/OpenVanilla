// ow/owdiag.js — Open Vanilla self-test kit. One call, one compact JSON report.
//
//   await owdiag.run()            quick checks for the current screen (login, character, world)
//   await owdiag.run('full')      + scenario checks that move the character and open UI panels
//   await owdiag.diff()           what changed since the previous run (newly failing / fixed)
//   await owdiag.bot(10)          patrol for N minutes: small moves, panel opens, checks every 30 s
//   await owdiag.log()            the captured page errors and failed requests, deduplicated
//   ?diag=1 on the page URL       runs once when the screen settles and logs the report
//
// The report is small on purpose (an agent or a person can read it in one glance): passing
// checks are only counted, failures and warnings carry a one-line reason. Screenshots are never
// taken here; take one only when a failure needs eyes.
//
// Checks live in owdiag-checks.js, a plain list. When a bug is fixed, add a check that would
// have caught it: the suite grows with the game.

import { CHECKS } from './owdiag-checks.js';

const HISTORY_KEY = 'owdiag:history';
const MAX_HISTORY = 30;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export function createDiag(wenilla) {
  const errors = new Map();   // message -> count
  const failed = new Map();   // url -> status
  let capturing = false;

  const note = (map, key, val = 1) => map.set(key, (map.get(key) || 0) + val);

  function capture() {
    if (capturing) return;
    capturing = true;
    const origError = console.error.bind(console);
    console.error = (...a) => {
      note(errors, a.map((x) => (x instanceof Error ? x.message : String(x))).join(' ').slice(0, 200));
      origError(...a);
    };
    window.addEventListener('error', (e) => note(errors, `${e.message} @${(e.filename || '').split('/').pop()}:${e.lineno}`.slice(0, 200)));
    window.addEventListener('unhandledrejection', (e) => note(errors, `unhandled: ${e.reason?.message || e.reason}`.slice(0, 200)));
    try {
      new PerformanceObserver((list) => {
        for (const r of list.getEntries()) {
          if (r.responseStatus >= 400) failed.set(r.name.replace(location.origin, ''), r.responseStatus);
        }
      }).observe({ type: 'resource', buffered: true });
    } catch { /* older browsers: no resource status */ }
  }

  // Lua through the bridge, always resolving to an array of values (or throwing with the error).
  async function lua(chunk, timeout = 8000) {
    const v = await wenilla.lua(chunk, timeout);
    return Array.isArray(v) ? v : [v];
  }

  const screen = () => wenilla.state?.session?.state || (wenilla.ready ? 'unknown' : 'booting');

  const ctx = { wenilla, lua, sleep, screen, errors, failed, capture };

  async function run(level = 'quick', only = null) {
    capture();
    const t0 = performance.now();
    const state = screen();
    const out = { v: 1, at: new Date().toISOString(), state, level, pass: 0, warn: [], fail: [], skip: 0 };
    for (const c of CHECKS) {
      if (only && !only.includes(c.id)) continue;
      if (c.level === 'full' && level !== 'full') { out.skip++; continue; }
      if (c.when && !c.when.includes(state)) { out.skip++; continue; }
      let r;
      try {
        r = await Promise.race([c.run(ctx), sleep(c.timeout || 10000).then(() => 'timed out')]);
      } catch (e) {
        r = `threw: ${e?.message || e}`;
      }
      if (r === true || r === undefined || r === null) out.pass++;
      else if (typeof r === 'object' && r.warn) out.warn.push(`${c.id}: ${r.warn}`);
      else out.fail.push(`${c.id}: ${typeof r === 'string' ? r : JSON.stringify(r)}`);
    }
    out.ok = out.fail.length === 0;
    out.ms = Math.round(performance.now() - t0);
    save(out);
    window.__owdiag_last = out;
    return out;
  }

  function history() {
    try { return JSON.parse(localStorage.getItem(HISTORY_KEY) || '[]'); } catch { return []; }
  }
  function save(r) {
    try {
      const h = history();
      h.push(r);
      localStorage.setItem(HISTORY_KEY, JSON.stringify(h.slice(-MAX_HISTORY)));
    } catch { /* storage off: fine */ }
  }

  function diff() {
    const h = history();
    if (h.length < 2) return { note: 'need two runs' };
    const [a, b] = h.slice(-2);
    const ids = (r) => new Set(r.fail.map((f) => f.split(':')[0]));
    const was = ids(a), now = ids(b);
    return {
      newlyFailing: b.fail.filter((f) => !was.has(f.split(':')[0])),
      fixed: [...was].filter((id) => !now.has(id)),
      stillFailing: [...now].filter((id) => was.has(id)),
    };
  }

  function log() {
    const top = (m, n) => [...m.entries()].sort((x, y) => y[1] - x[1]).slice(0, n).map(([k, v]) => `${v}x ${k}`);
    return { errors: top(errors, 12), failedRequests: [...failed.entries()].slice(0, 12).map(([u, s]) => `${s} ${u}`) };
  }

  // Wait for a settled screen, then run once and print the report.
  async function autorun() {
    capture();
    for (let i = 0; i < 120; i++) {
      const s = screen();
      if (s === 'inworld' && wenilla.state?.self) { await sleep(8000); break; }   // let addons load
      if (s === 'login' || s === 'charselect') { await sleep(3000); if (screen() === s) break; }
      await sleep(1000);
    }
    const r = await run(new URLSearchParams(location.search).get('diag') === 'full' ? 'full' : 'quick');
    console.log('[owdiag]', JSON.stringify(r));
    return r;
  }

  // A light patrol bot: keeps the session alive and busy, and samples the checks as it goes.
  async function bot(minutes = 5) {
    capture();
    if (screen() !== 'inworld') return { error: `bot needs the world; screen is ${screen()}` };
    const end = Date.now() + minutes * 60000;
    const runs = [];
    const moves = ['MOVEFORWARD', 'STRAFELEFT', 'MOVEBACKWARD', 'STRAFERIGHT'];
    let step = 0;
    while (Date.now() < end) {
      const cmd = moves[step++ % moves.length];
      wenilla.hold(cmd);
      await sleep(900);
      wenilla.release(cmd);
      if (step % 3 === 0) wenilla.fire('JUMP');
      wenilla.look((Math.random() - 0.5) * 1.2);
      if (step % 30 === 0) {
        const r = await run(step % 60 === 0 ? 'full' : 'quick');
        runs.push({ at: r.at, ok: r.ok, fail: r.fail, warn: r.warn.length });
      }
      await sleep(1000);
    }
    wenilla.releaseAll();
    const last = await run('full');
    return { minutes, samples: runs.length, everFailed: [...new Set(runs.flatMap((r) => r.fail))], last, log: log() };
  }

  return { capture, run, diff, log, autorun, bot, history, lua, checks: () => CHECKS.map((c) => c.id) };
}
