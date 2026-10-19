// openvanilla_addon_devloader.js — TEST HARNESS, not an engine feature.
//
// Why this exists: the deployed web client (wenilla_bg.wasm, built 2026-10-12) never discovers
// player addons in Data/Interface/AddOns. Its addon registry is the 12 Blizzard LoadOnDemand
// addons (probed over HTTP) plus a compiled-in "bundled" list; the loose-folder pass
// (benilla-app/src/ui_script/addons.rs `discover_folder`, std::fs::read_dir) has no
// filesystem on wasm and returns nothing. See docs/ADDON_COMPAT_REPORT.md, gap G1.
//
// Until the engine does that pass, this script lets you load an unmodified 1.12 addon folder
// into the live UI VM from the browser console, through the page's JavaScript bridge
// (`window.wenilla.lua`, www/bridge.js), to see what the engine's Lua/widget API does with it.
// It emulates only what the missing pass would do:
//   * reads <Name>.toc over /data/Interface/AddOns/<Name>/ (the same HTTP source the engine uses)
//   * honours ## Dependencies / RequiredDeps (load first, DEP_MISSING otherwise), OptionalDeps,
//     ## Interface (11200 gate), ## LoadOnDemand (skipped unless named explicitly)
//   * runs .toc files in order; .lua as chunks named "@Interface\AddOns\<Name>\<path>" (what
//     Ace2's debugstack-based path detection expects); .xml: <Script file>, inline <Script>,
//     <Include file> resolved relative to the including file, backslashes accepted
//   * gives the addon a registry row (GetAddOnInfo / GetAddOnMetadata / IsAddOnLoaded /
//     GetNumAddOns) and dispatches ADDON_LOADED(arg1=<Name>), then VARIABLES_LOADED,
//     PLAYER_LOGIN, PLAYER_ENTERING_WORLD to frames the addon created and registered
//   * restores/saves ## SavedVariables[PerCharacter] in localStorage ("openvanilla-devloader:SV:")
// What it CANNOT do: materialize XML frames/templates (<Frame>, <Button>, virtual templates…)
// — only the engine's FrameXML loader can; such elements are reported and skipped.
// A /reload recreates the Lua VM and drops everything this script loaded; run it again.
//
// Usage (browser console on game.html, in world): paste this whole file, then
//   await openvanillaDevLoad(['ShaguDPS', 'pfQuest'])          // returns a per-addon report
//   await openvanillaDevSave()                                  // write SavedVariables now

(function () {
  const ROOT = 'Interface/AddOns/';
  const SV_KEY = 'openvanilla-devloader:SV:';

  const enc = (p) => '/data/' + p.split('/').map(encodeURIComponent).join('/');
  async function fetchText(path) {
    const r = await fetch(enc(path), { cache: 'no-store' });
    if (!r.ok) return null;
    // Lua sources are bytes; latin1 keeps every byte as one UTF-16 unit for the round trip.
    const buf = new Uint8Array(await r.arrayBuffer());
    let s = '';
    for (let i = 0; i < buf.length; i += 0x8000) s += String.fromCharCode.apply(null, buf.subarray(i, i + 0x8000));
    return s;
  }
  // Re-encode the latin1 string as UTF-8 text for the bridge (the bridge carries JS strings).
  const asText = (latin1) => {
    try { return decodeURIComponent(escape(latin1)); } catch (e) { return latin1; }
  };

  function parseToc(text) {
    const t = text.replace(/^﻿|^\xEF\xBB\xBF/, '');
    const directives = {}, order = [], files = [];
    for (let line of t.split(/\r?\n/)) {
      line = line.trim();
      if (line.startsWith('##')) {
        const i = line.indexOf(':');
        if (i > 0) {
          const k = line.slice(2, i).trim(), v = line.slice(i + 1).trim();
          directives[k] = v; order.push([k, v]);
        }
      } else if (line && !line.startsWith('#')) files.push(line);
    }
    const list = (k) => (directives[k] || '').split(',').map((s) => s.trim()).filter(Boolean);
    return {
      directives, order, files,
      deps: [...list('Dependencies'), ...list('RequiredDeps'),
        ...Object.keys(directives).filter((k) => /^Dep/i.test(k) && k !== 'Dependencies').flatMap(list)],
      optdeps: list('OptionalDeps'),
      lod: directives.LoadOnDemand === '1',
      interface: parseInt(directives.Interface || '0', 10) || 0,
      sv: list('SavedVariables'),
      svpc: list('SavedVariablesPerCharacter'),
    };
  }

  // Lua long-bracket literal that cannot be closed by the payload.
  function luaLong(s) {
    let n = 0;
    while (s.includes(']' + '='.repeat(n) + ']')) n++;
    const eq = '='.repeat(n);
    return '[' + eq + '[\n' + s + ']' + eq + ']';
  }
  const luaStr = (s) => '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n') + '"';
  const lua = (chunk) => window.wenilla.lua(chunk, 120000);

  const PRELUDE = `
if not __DEVLOAD then
  __DEVLOAD = { frames = {}, events = {}, rows = {}, order = {} }
  local D = __DEVLOAD
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
  local oInfo, oNum, oLoaded, oMeta = GetAddOnInfo, GetNumAddOns, IsAddOnLoaded, GetAddOnMetadata
  local function row(k)
    if type(k) == "string" then return D.rows[string.lower(k)] end
    local n = tonumber(k)
    if n and n > oNum() then local name = D.order[n - oNum()]; return name and D.rows[string.lower(name)] end
  end
  GetNumAddOns = function() return oNum() + table.getn(D.order) end
  GetAddOnInfo = function(k)
    local r = row(k)
    if r then return r.name, r.title, r.notes, 1, 1, nil, "INSECURE" end
    return oInfo(k)
  end
  IsAddOnLoaded = function(k) local r = row(k) if r then return r.loaded and 1 or nil end return oLoaded(k) end
  GetAddOnMetadata = function(k, key) local r = row(k) if r then return r.meta[key] end return oMeta(k, key) end
  function D.dispatch(e, a1, only)
    local errs = {}
    for _, f in ipairs(D.frames) do
      local ev = D.events[f]
      if ev and ev[e] and (not only or only[f]) then
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
  function D.serialize(v, ind)
    ind = ind or ""
    local t = type(v)
    if t == "string" then return string.format("%q", v)
    elseif t == "number" or t == "boolean" or t == "nil" then return tostring(v)
    elseif t == "table" then
      local out = {"{"}
      for k, x in pairs(v) do
        local kt = type(k)
        if (kt == "string" or kt == "number") and type(x) ~= "function" and type(x) ~= "userdata" then
          table.insert(out, ind .. "  [" .. D.serialize(k) .. "] = " .. D.serialize(x, ind .. "  ") .. ",")
        end
      end
      table.insert(out, ind .. "}")
      return table.concat(out, "\\n")
    end
    return "nil"
  end
end
return "ok"`;

  const reports = {};
  const loaded = new Set();

  async function runLua(name, path, code, rep) {
    const chunkName = '@' + path.replace(/\//g, '\\');
    const t0 = performance.now();
    const r = await lua(`local D = __DEVLOAD
local f, e = loadstring(${luaLong(asText(code))}, ${luaStr(chunkName)})
if not f then return "COMPILE " .. tostring(e) end
D.capturing = true
local ok, err = pcall(f)
D.capturing = false
if not ok then return "RUNTIME " .. tostring(err) end
return "ok"`);
    const res = r && r[0];
    if (res !== 'ok') rep.errors.push(`${path}: ${res}`);
    rep.files.push(path + ' [' + Math.round(performance.now() - t0) + 'ms]' + (res === 'ok' ? '' : '  <-- ' + res));
  }

  async function runFile(name, dir, ref, rep) {
    const norm = (dir + '/' + ref.replace(/\\/g, '/')).split('/').reduce((a, p) => {
      if (p === '..') a.pop(); else if (p && p !== '.') a.push(p);
      return a;
    }, []).join('/');
    const text = await fetchText(norm);
    if (text == null) { rep.errors.push(`${norm}: Couldn't open (HTTP miss)`); rep.files.push(norm + '  <-- missing'); return; }
    if (/\.lua$/i.test(norm)) return runLua(name, norm, text, rep);
    if (/\.xml$/i.test(norm)) {
      const doc = new DOMParser().parseFromString(asText(text), 'text/xml');
      if (doc.getElementsByTagName('parsererror').length) { rep.errors.push(`${norm}: Couldn't parse XML`); return; }
      rep.files.push(norm);
      const base = norm.slice(0, norm.lastIndexOf('/'));
      for (const el of Array.from(doc.documentElement.children)) {
        const tag = el.tagName;
        if ((tag === 'Script' || tag === 'Include') && el.getAttribute('file')) {
          await runFile(name, base, el.getAttribute('file'), rep);
        } else if (tag === 'Script') {
          await runLua(name, norm + '#inline', el.textContent, rep);
        } else {
          rep.unsupported.push(`${norm}: <${tag}${el.getAttribute('name') ? ' name="' + el.getAttribute('name') + '"' : ''}> (XML frame — engine FrameXML loader needed)`);
        }
      }
      return;
    }
    rep.files.push(norm + '  (ignored: not .lua/.xml)');
  }

  async function loadOne(name, explicit, stack) {
    const key = name.toLowerCase();
    if (loaded.has(key)) return 'loaded';
    if (stack.includes(key)) return 'DEP_CYCLE';
    const tocText = await fetchText(`${ROOT}${name}/${name}.toc`);
    if (tocText == null) return 'MISSING';
    const toc = parseToc(tocText);
    const rep = reports[name] = { name, title: toc.directives.Title, status: '', files: [], errors: [], unsupported: [], events: '' };
    if (toc.interface !== 11200) { rep.status = 'INTERFACE_VERSION (' + toc.interface + ')'; return rep.status; }
    if (toc.lod && !explicit) { rep.status = 'LoadOnDemand — not loaded'; return 'LOD'; }
    for (const d of toc.deps) {
      const r = await loadOne(d, true, [...stack, key]);
      if (r !== 'loaded' && r !== 'ok') { rep.status = 'DEP_' + (r.startsWith('DEP_') ? r.slice(4) : r) + ' (' + d + ')'; return rep.status; }
    }
    for (const d of toc.optdeps) await loadOne(d, false, [...stack, key]).catch(() => {});
    loaded.add(key);
    const meta = toc.order.map(([k, v]) => `[${luaStr(k)}]=${luaStr(v)}`).join(',');
    await lua(`local D=__DEVLOAD D.rows[${luaStr(key)}]={name=${luaStr(name)},title=${toc.directives.Title ? luaStr(toc.directives.Title) : 'nil'},notes=${toc.directives.Notes ? luaStr(toc.directives.Notes) : 'nil'},loaded=true,meta={${meta}}} table.insert(D.order, ${luaStr(name)}) D.mark = table.getn(D.frames) return "ok"`);
    for (const f of toc.files) await runFile(name, ROOT + name, f, rep);
    // SavedVariables: after the files, before ADDON_LOADED (AddOn_Load order).
    const saved = localStorage.getItem(SV_KEY + name);
    if (saved) {
      const r = await lua(`local f,e=loadstring(${luaLong(saved)}, "=SavedVariables") if not f then return e end local ok,err=pcall(f) return ok and "ok" or tostring(err)`);
      if (r[0] !== 'ok') rep.errors.push('SavedVariables: ' + r[0]);
    }
    rep.sv = [...toc.sv, ...toc.svpc];
    const ev = await lua(`return __DEVLOAD.dispatch("ADDON_LOADED", ${luaStr(name)})`);
    if (ev[0]) rep.errors.push(ev[0]);
    rep.status = rep.errors.length ? 'loaded with errors' : 'loaded';
    return 'ok';
  }

  window.openvanillaDevLoad = async function (names) {
    if (!window.wenilla || !window.wenilla.lua) throw new Error('bridge.js not loaded (window.wenilla missing)');
    await lua(PRELUDE);
    for (const n of names) await loadOne(n, true, []);
    // The world is already entered: replay the login sequence for what was just loaded.
    const post = [];
    for (const e of ['VARIABLES_LOADED', 'PLAYER_LOGIN', 'PLAYER_ENTERING_WORLD']) {
      const r = await lua(`return __DEVLOAD.dispatch(${luaStr(e)})`);
      if (r[0]) post.push(r[0]);
    }
    for (const n of names) if (reports[n]) reports[n].loginEvents = post.join('\n');
    return names.map((n) => reports[n] || { name: n, status: 'MISSING' });
  };

  window.openvanillaDevSave = async function () {
    const out = {};
    for (const [name, rep] of Object.entries(reports)) {
      if (!rep.sv || !rep.sv.length) continue;
      const parts = rep.sv.map((v) => `"${v} = " .. __DEVLOAD.serialize(${v})`).join(' .. "\\n" .. ');
      const r = await lua(`return ${parts}`);
      localStorage.setItem(SV_KEY + name, r[0]);
      out[name] = r[0].length;
    }
    return out;
  };
})();
