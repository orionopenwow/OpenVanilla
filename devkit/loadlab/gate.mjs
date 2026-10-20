#!/usr/bin/env node
// devkit/loadlab/gate.mjs — the load-time gate: compare a measure.mjs result with a baseline and
// fail (exit 1) when loading got slower or heavier. No AI, no network: two JSON files in, a table out.
//
//   node devkit/loadlab/gate.mjs current.json baseline.json [--slower 20] [--min-ms 750] [--bigger 10]
//
// Checked for each run in both files (cold, warm):
//   time to the login screen, the character list and the world (states.*), slower than the
//   baseline by more than --slower % (default 20) AND by more than --min-ms (default 750 ms:
//   headless runners are noisy, so a small absolute change never fails the gate);
//   the client download (wasm.mb), what loads before the login screen (data.boot.mb) and
//   everything measured (data.all.mb), bigger by more than --bigger % (default 10).
// When the run was repeated (--repeat), each stage's median is used instead of the first run.
// Prints a Markdown table (for the GitHub run summary) and a one-line verdict.

import fs from 'node:fs';

const args = process.argv.slice(2);
const opt = (name, def) => { const i = args.indexOf(name); return i >= 0 ? Number(args[i + 1]) : def; };
const files = args.filter((a, i) => !a.startsWith('--') && !(i > 0 && args[i - 1].startsWith('--')));
if (files.length < 2) { console.error('usage: gate.mjs current.json baseline.json [--slower PCT] [--min-ms MS] [--bigger PCT]'); process.exit(2); }
const SLOWER = opt('--slower', 20), MIN_MS = opt('--min-ms', 750), BIGGER = opt('--bigger', 10);

const read = (f) => JSON.parse(fs.readFileSync(f, 'utf8'));
const cur = read(files[0]), base = read(files[1]);

// A stage's time: the median over repeats when there are any, else the single run.
function stateMs(result, run, state) {
  const reps = (result.repeats || []).map((r) => r?.[run]?.states?.[state]).filter((v) => typeof v === 'number');
  if (reps.length) { const s = [...reps].sort((a, b) => a - b); return s[Math.floor(s.length / 2)]; }
  const v = result.runs?.[run]?.states?.[state];
  return typeof v === 'number' ? v : null;
}
const get = (o, path) => path.split('.').reduce((x, k) => (x == null ? x : x[k]), o);

export function evaluate(cur, base) {
  const rows = [], fails = [];
  for (const run of Object.keys(cur.runs || {})) {
    if (!base.runs?.[run]) continue;
    for (const state of ['login', 'charselect', 'inworld']) {
      const a = stateMs(base, run, state), b = stateMs(cur, run, state);
      if (a == null || b == null) continue;
      const d = b - a, pct = a ? (d / a) * 100 : 0;
      const bad = d > MIN_MS && pct > SLOWER;
      rows.push([run, `time to ${state}`, `${(a / 1000).toFixed(1)} s`, `${(b / 1000).toFixed(1)} s`, `${pct >= 0 ? '+' : ''}${pct.toFixed(0)}%`, bad ? 'FAIL' : 'ok']);
      if (bad) fails.push(`${run}: time to ${state} ${(a / 1000).toFixed(1)} s -> ${(b / 1000).toFixed(1)} s`);
    }
    for (const [path, label] of [['wasm.mb', 'client download'], ['data.boot.mb', 'before login'], ['data.all.mb', 'all measured']]) {
      const a = get(base.runs[run], path), b = get(cur.runs[run], path);
      if (typeof a !== 'number' || typeof b !== 'number') continue;
      const pct = a ? ((b - a) / a) * 100 : 0;
      // A warm run downloads almost nothing, so tiny sizes never fail the gate.
      const bad = pct > BIGGER && b - a > 0.25;
      rows.push([run, label, `${a} MB`, `${b} MB`, `${pct >= 0 ? '+' : ''}${pct.toFixed(0)}%`, bad ? 'FAIL' : 'ok']);
      if (bad) fails.push(`${run}: ${label} ${a} MB -> ${b} MB`);
    }
  }
  return { rows, fails };
}

const isMain = (() => { try { return fs.realpathSync(new URL(import.meta.url).pathname) === fs.realpathSync(process.argv[1]); } catch { return false; } })();
if (isMain) {
  const { rows, fails } = evaluate(cur, base);
  const out = ['| run | measure | baseline | now | change | |', '|---|---|---|---|---|---|', ...rows.map((r) => `| ${r.join(' | ')} |`)];
  console.log(out.join('\n'));
  if (!rows.length) { console.log('\nNothing to compare (the runs reached no common screens).'); process.exit(2); }
  if (fails.length) { console.log(`\nLOAD GATE FAILED (slower than +${SLOWER}% and ${MIN_MS} ms, or bigger than +${BIGGER}%):\n- ` + fails.join('\n- ')); process.exit(1); }
  console.log('\nLoad gate passed.');
}
