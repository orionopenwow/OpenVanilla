// addons-loader.js — loads the Classic+ native addon suite into the web client for every player.
//
// Why: the web build's addon registry does not discover loose folders in Data/Interface/AddOns
// (docs/ADDON_COMPAT_REPORT.md, gap G1), so the suite is streamed into the live UI VM through the
// page bridge (window.wenilla.lua). This file does what the engine's AddOn pass would:
//   * discovers suite folders from /data/__addons (any folder whose .toc has "## X-ClassicPlus")
//   * reads each .toc and runs its files in order, dependencies first, as chunks named
//     "@Interface\AddOns\<Name>\<file>" so errors point at the real file
//   * honours the AddOn list: a suite addon unticked there (its bundled row) is skipped
//   * restores ## SavedVariables from localStorage before ADDON_LOADED, saves them every 30 s
//     and when the tab is hidden
//   * replays ADDON_LOADED, VARIABLES_LOADED, PLAYER_LOGIN and PLAYER_ENTERING_WORLD to the
//     frames the suite created (the real ones fired before the suite existed)
//   * loads again after /reload (a reload creates a fresh Lua VM)
// It also forwards engine state the 1.12 API cannot see — enemy cast bars — to Castline.

const MARK = 'X-ClassicPlus';
const SV_KEY = 'classicplus:SV:';
const LOG = (...a) => console.log('[Classic+]', ...a);

let wenilla = null;
let loading = null;       // in-flight load promise (single flight)
let suite = [];           // [{ name, toc }] in load order
let savedVars = [];       // SavedVariables names across the suite

const enc = (p) => '/data/' + p.split('/').map(encodeURIComponent).join('/');
const luaStr = (s) => '"' + String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\r/g, '\\r').replace(/\n/g, '\\n') + '"';
function luaLong(s) {
  let n = 0;
  while (s.includes(']' + '='.repeat(n) + ']')) n++;
  const eq = '='.repeat(n);
  return '[' + eq + '[\n' + s + ']' + eq + ']';
}
const lua = (chunk, ms = 20000) => wenilla.lua(chunk, ms);

async function text(path) {
  const r = await fetch(enc(path), { cache: 'no-cache' });
  return r.ok ? r.text() : null;
}

function parseToc(t) {
  const meta = {}, files = [];
  for (let line of t.replace(/^﻿/, '').split(/\r?\n/)) {
    line = line.trim();
    if (line.startsWith('##')) {
      const i = line.indexOf(':');
      if (i > 0) meta[line.slice(2, i).trim()] = line.slice(i + 1).trim();
    } else if (line && !line.startsWith('#')) files.push(line.replace(/\\/g, '/'));
  }
  const list = (k) => (meta[k] || '').split(',').map((s) => s.trim()).filter(Boolean);
  return { meta, files, deps: [...list('Dependencies'), ...list('RequiredDeps')], sv: [...list('SavedVariables'), ...list('SavedVariablesPerCharacter')] };
}

async function discover() {
  let names = [];
  try {
    const r = await fetch('/data/__addons', { cache: 'no-store' });
    if (r.ok) names = (await r.json()).addons.map((a) => a.name);
  } catch (e) { /* older asset server: fall back to the known suite */ }
  if (!names.length) names = ['WenillaCore', 'Meters', 'Quests', 'Threat', 'Casting', 'Guilds', 'Bags', 'Prices', 'Vendor', 'Plates', 'Raid'];
  const tocs = {};
  await Promise.all(names.map(async (n) => {
    const t = await text(`Interface/AddOns/${n}/${n}.toc`);
    if (t) {
      const toc = parseToc(t);
      if (toc.meta[MARK] && toc.meta.Interface === '11200') tocs[n] = toc;
    }
  }));
  // dependencies first, then alphabetical (the client's directory order)
  const order = [], seen = new Set();
  const visit = (n, stack = []) => {
    if (seen.has(n) || !tocs[n] || stack.includes(n)) return;
    for (const d of tocs[n].deps) visit(d, [...stack, n]);
    seen.add(n);
    order.push({ name: n, toc: tocs[n] });
  };
  Object.keys(tocs).sort((a, b) => a.toUpperCase() < b.toUpperCase() ? -1 : 1).forEach((n) => visit(n));
  return order;
}

// Lua-side helpers: remember which frames the suite creates and the events they register,
// so the login events can be replayed to them (and only them).
const PRELUDE = `
if not __CPLOAD then
  __CPLOAD = { frames = {}, events = {} }
  local D = __CPLOAD
  local origCreateFrame = CreateFrame
  CreateFrame = function(a, b, c, d)
    local f = origCreateFrame(a, b, c, d)
    if D.capturing and f then
      table.insert(D.frames, f)
      local reg = f.RegisterEvent
      f.RegisterEvent = function(self, e)
        D.events[self] = D.events[self] or {}
        D.events[self][e] = true
        return reg(self, e)
      end
    end
    return f
  end
  function D.dispatch(e, a1)
    local errs = {}
    for _, f in ipairs(D.frames) do
      local ev = D.events[f]
      if ev and ev[e] then
        local s = f:GetScript("OnEvent")
        if s then
          local othis, oevent, oarg1 = this, event, arg1
          this, event, arg1 = f, e, a1
          local ok, err = pcall(s)
          this, event, arg1 = othis, oevent, oarg1
          if not ok then table.insert(errs, e .. ": " .. tostring(err)) end
        end
      end
    end
    return table.concat(errs, "\\n")
  end
  function D.ser(v, ind)
    ind = ind or ""
    local t = type(v)
    -- %q leaves a newline as backslash + a real line break (and \r raw): written as \n / \r
    -- instead, so a stored string can never start a line of its own when the save is split
    if t == "string" then return (string.gsub(string.gsub(string.format("%q", v), "\n", "n"), "\r", "\\r"))
    elseif t == "number" or t == "boolean" then return tostring(v)
    elseif t == "table" then
      local out = { "{" }
      for k, x in pairs(v) do
        local kt, xt = type(k), type(x)
        if (kt == "string" or kt == "number") and xt ~= "function" and xt ~= "userdata" then
          table.insert(out, ind .. "  [" .. D.ser(k) .. "] = " .. D.ser(x, ind .. "  ") .. ",")
        end
      end
      table.insert(out, ind .. "}")
      return table.concat(out, "\\n")
    end
    return "nil"
  end
end
return "ok"`;

async function enabledInAddonList(name) {
  // The bundled rows (patch_wasm.py) carry the suite's names; respect the player's choice.
  const r = await lua(`local n = ${luaStr(name)}
if not GetAddOnInfo then return "yes" end
local _, title, _, enabled = GetAddOnInfo(n)
if not title then return "yes" end
return enabled and "yes" or "no"`).catch(() => ['yes']);
  return r[0] !== 'no';
}

async function loadSuite() {
  const t0 = performance.now();
  suite = suite.length ? suite : await discover();
  if (!suite.length) { LOG('no suite addons found under Data/Interface/AddOns'); return; }
  await lua(PRELUDE);
  const report = [];
  savedVars = [];
  for (const { name, toc } of suite) {
    if (name !== 'WenillaCore' && !(await enabledInAddonList(name))) { report.push(`${name}: off in AddOn list`); continue; }
    let errors = 0;
    for (const file of toc.files) {
      const path = `Interface/AddOns/${name}/${file}`;
      const code = await text(path);
      if (code == null) { report.push(`${path}: missing`); errors++; continue; }
      const chunkName = '@' + path.replace(/\//g, '\\');
      const r = await lua(`__CPLOAD.capturing = true
local f, e = loadstring(${luaLong(code)}, ${luaStr(chunkName)})
if not f then __CPLOAD.capturing = false return "compile: " .. tostring(e) end
local ok, err = pcall(f)
__CPLOAD.capturing = false
if not ok then return "runtime: " .. tostring(err) end
return "ok"`).catch((e) => [String(e)]);
      if (r[0] !== 'ok') { report.push(`${path}: ${r[0]}`); errors++; }
    }
    for (const v of toc.sv) {
      savedVars.push(v);
      let saved = localStorage.getItem(SV_KEY + v);
      // one variable per entry: anything that sets another name on a line of its own is not a save
      // this loader wrote (strings are written with \n escapes), so it is dropped, not run
      if (saved && saved.split('\n').slice(1).some((l) => /^[A-Za-z_][A-Za-z0-9_]*\s*=/.test(l))) {
        report.push(`${v}: saved data looked tampered with and was reset`);
        localStorage.removeItem(SV_KEY + v);
        saved = null;
      }
      if (saved) {
        // data, not code: the saved text runs with no globals (a call to any function fails) and
        // may only set its own variable
        const r = await lua(`local f, e = loadstring(${luaLong(saved)}, "=SavedVariables") if not f then return e end if setfenv and setmetatable then setfenv(f, setmetatable({}, { __newindex = function(_, k, x) if k == ${luaStr(v)} then setglobal(k, x) end end })) end local ok, err = pcall(f) return ok and "ok" or tostring(err)`);
        if (r[0] !== 'ok') report.push(`${v}: ${r[0]}`);
      }
    }
    const ev = await lua(`return __CPLOAD.dispatch("ADDON_LOADED", ${luaStr(name)})`);
    if (ev[0]) report.push(ev[0]);
    report.push(`${name}: ${errors ? 'loaded with errors' : 'loaded'}`);
  }
  for (const e of ['VARIABLES_LOADED', 'PLAYER_LOGIN', 'PLAYER_ENTERING_WORLD']) {
    const r = await lua(`return __CPLOAD.dispatch(${luaStr(e)})`);
    if (r[0]) report.push(r[0]);
  }
  await lua(`WenillaCore = WenillaCore or {} WenillaCore.__suite = true return "ok"`);
  LOG(`suite loaded in ${Math.round(performance.now() - t0)} ms\n  ` + report.join('\n  '));
}

async function saveVars() {
  if (!wenilla || !savedVars.length) return;
  try {
    const parts = savedVars.map((v) => `"${v} = " .. __CPLOAD.ser(${v})`).join(' .. "\\n" .. ');
    const r = await lua(`if not __CPLOAD or not WenillaCore or not WenillaCore.__suite then return "" end return ${parts}`, 5000);
    if (r[0]) {
      const lines = r[0].split('\n');
      // one key per variable so a corrupt entry cannot take the others with it
      let cur = null, buf = [];
      const flush = () => { if (cur) localStorage.setItem(SV_KEY + cur, buf.join('\n')); };
      for (const line of lines) {
        const m = /^([A-Za-z_][A-Za-z0-9_]*) = /.exec(line);
        if (m && savedVars.includes(m[1])) { flush(); cur = m[1]; buf = [line]; } else buf.push(line);
      }
      flush();
    }
  } catch (e) { /* VM busy or gone; the next save catches up */ }
}

// Load when in world and the suite is not in this VM (first entry, or after /reload).
async function ensure() {
  if (loading || !wenilla.state || !wenilla.state.self) return;
  loading = (async () => {
    try {
      const r = await lua('return WenillaCore and WenillaCore.__suite and "yes" or "no"', 8000);
      if (r[0] !== 'yes') await loadSuite();
    } catch (e) {
      console.warn('[Classic+] load failed:', e);
    }
  })();
  await loading;
  loading = null;
}

// ── Engine feed: enemy casts for Castline ─────────────────────────────────────
// The engine knows every nearby unit's cast but reports only its spell id. Name, cast time,
// icon, interruptibility and channelling come from the client's own DBC files, which the
// game has already downloaded (so this is a cache hit), parsed once on the first cast.
const casts = new Map();   // guid -> signature of the cast we last reported
let spells = null, spellsLoading = null;

async function dbc(name) {
  const r = await fetch(`/data/dbfilesclient/${name}.dbc`);
  const buf = await r.arrayBuffer();
  const v = new DataView(buf), u8 = new Uint8Array(buf);
  const recs = v.getUint32(4, true), rs = v.getUint32(12, true), sb = 20 + recs * rs;
  const dec = new TextDecoder();
  return {
    recs,
    u32: (i, k) => v.getUint32(20 + i * rs + k * 4, true),
    i32: (i, k) => v.getInt32(20 + i * rs + k * 4, true),
    str: (o) => { let e = sb + o; while (u8[e]) e++; return dec.decode(u8.subarray(sb + o, e)); },
  };
}

// Spell.dbc 1.12.1 (173 fields): 7 AttributesEx, 18 CastingTimeIndex, 21 InterruptFlags,
// 30 DurationIndex, 117 SpellIconID, 120 SpellName[enUS].
async function loadSpells() {
  const [sp, ct, du, ic] = await Promise.all(['spell', 'spellcasttimes', 'spellduration', 'spellicon'].map(dbc));
  const cast = {}, dur = {}, icon = {};
  for (let i = 0; i < ct.recs; i++) cast[ct.u32(i, 0)] = ct.i32(i, 1);
  for (let i = 0; i < du.recs; i++) dur[du.u32(i, 0)] = du.i32(i, 1);
  for (let i = 0; i < ic.recs; i++) icon[ic.u32(i, 0)] = ic.str(ic.u32(i, 1)).split('\\').pop();
  const t = new Map();
  for (let i = 0; i < sp.recs; i++) {
    const channel = (sp.u32(i, 7) & 0x44) !== 0;
    let ms = cast[sp.u32(i, 18)] || 0;
    if (channel) ms = dur[sp.u32(i, 30)] || ms;
    if (ms <= 0) continue;
    t.set(sp.u32(i, 0), { spell: sp.str(sp.u32(i, 120)).replace(/[,;]/g, ' '), dur: ms,
      icon: icon[sp.u32(i, 117)] || '', interruptible: (sp.u32(i, 21) & 8) ? 1 : 0, channel });
  }
  return t;
}

function castInfo(c) {
  if (!c) return null;
  const id = c.spellId ?? c.id;
  if (id != null && spells) return spells.get(id) || null;
  if (id != null && !spellsLoading) spellsLoading = loadSpells().then((t) => { spells = t; }).catch(() => { spells = new Map(); });
  return null;   // reported on the next frame once the table is ready
}
function feedCasts(state) {
  if (!state || !state.units) return;
  const targetGuid = state.target && state.target.guid;
  const selfGuid = state.self && state.self.guid;
  const seen = new Set();
  const now = performance.now();
  for (const u of [state.target, ...state.units]) {
    if (!u || !u.guid || u.guid === selfGuid || seen.has(u.guid) || (u.isPlayer && u.friendly)) continue;
    seen.add(u.guid);
    const c = castInfo(u.casting) || castInfo(u.channeling);
    const role = u.guid === targetGuid ? 'target' : 'plate';
    const name = (u.name || '').replace(/[,;]/g, ' ');
    const sig = c ? `${role}|${c.spell}|${c.dur}` : null;
    const prev = casts.get(u.guid);
    if (sig && (!prev || prev.sig !== sig)) {
      casts.set(u.guid, { sig, role, name, start: now, dur: c.dur });
      if (name) dispatch('CL', `${role},${name},${c.spell},${c.dur},${c.interruptible},${c.icon},${c.channel ? 1 : 0}`);
    } else if (!sig && prev) {
      casts.delete(u.guid);
      // ended well before its cast time: interrupted (or the caster moved / died)
      const cut = now - prev.start < prev.dur - 250 ? 1 : 0;
      if (prev.name) dispatch('CL', `stop,${prev.role},${prev.name},${cut}`);
    }
  }
  // units that left range mid-cast
  for (const [guid, prev] of casts) {
    if (!seen.has(guid)) {
      casts.delete(guid);
      if (prev.name) dispatch('CL', `stop,${prev.role},${prev.name},0`);
    }
  }
}
function dispatch(tag, body) {
  wenilla.lua(`if WenillaCore and WenillaCore.Dispatch then WenillaCore:Dispatch(${luaStr(tag)}, ${luaStr(body)}) end`, 3000).catch(() => {});
}

let started = false;
export async function initNativeAddons(w) {
  wenilla = w;
  if (started) return ensure();
  started = true;
  w.on('PLAYER_ENTERING_WORLD', () => setTimeout(ensure, 250));
  setInterval(ensure, 3000);              // catches /reload and late world entry
  setInterval(saveVars, 30000);
  document.addEventListener('visibilitychange', () => { if (document.hidden) saveVars(); });
  window.addEventListener('pagehide', saveVars);
  let lastFeed = 0;
  w.on('frame', (s) => {
    const now = performance.now();
    if (now - lastFeed > 150 && s && s.self) { lastFeed = now; feedCasts(s); }
  });
  window.classicPlus = {
    reload: () => { suite = []; return lua('WenillaCore.__suite = nil return 1').then(ensure); },
    save: saveVars,
    feedCasts,                       // exposed for diagnostics: feed a hand-made state
    spells: () => spells,
  };
  return ensure();
}
