/* Vanilla Forge Lite: a small browser editor that writes a real Vanilla Forge project folder.
 *
 * The top half is pure helpers (TOML writer and reader, ID ranges, project builder, zip writer and reader,
 * CRC-32, validation). They run in the page and under node (module.exports at the bottom), so the tests
 * can build a project without a browser. The bottom half is the page UI, which only runs when there is a
 * document. No inline scripts or style attributes: the page's CSP forbids them.
 */
(function (root) {
  'use strict';

  /* ------------------------------------------------------------------ constants */

  var REALMS = [['classicplus', 'Classic+'], ['warfront', 'Warfront'], ['community', 'Community']];
  var LICENSES = [
    ['MIT', 'MIT'], ['CC-BY-4.0', 'CC BY 4.0'], ['CC-BY-SA-4.0', 'CC BY-SA 4.0'],
    ['CC0-1.0', 'CC0 1.0 (public domain)'], ['GPL-3.0-only', 'GPL 3.0 only']
  ];
  // The community ID area for each table, as [start, end). Blocks of BLOCK IDs inside it.
  var AREAS = {
    creature_template: [1100000, 2100000],
    item_template: [1100000, 2100000],
    quest_template: [110000, 210000]
  };
  var RESERVED = {
    creature_template: [[990000, 1000000]],
    item_template: [[990000, 1000000]],
    quest_template: []
  };
  var BLOCK = 1000;
  var ROW_TABLES = ['item_template', 'creature_template', 'quest_template'];
  var KEY_COL = { item_template: 'entry', creature_template: 'Entry', quest_template: 'entry' };
  var NAME_COL = { item_template: 'name', creature_template: 'Name', quest_template: 'Title' };
  var NOUN = { item_template: 'item', creature_template: 'creature', quest_template: 'quest' };
  var NPC_QUESTGIVER = 2;
  var CREDITS = '# Every file in this pack that you did not make yourself, with where it came from and its licence.\n' +
    '# The Workshop review checks this. Your own work needs no entry.\n';
  var DATA_HEADER = function (t) {
    return '# ' + t + ": rows this pack adds or (override = true) changes. Edited by Forge's Data screen.\n";
  };
  var ID_RE = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
  var SEMVER_RE = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/;
  var ADDON_RE = /^[A-Za-z][A-Za-z0-9_]{0,47}$/;

  /* ------------------------------------------------------------------ small helpers */

  function has(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }

  function slugify(s) {
    s = String(s || '').toLowerCase();
    if (s.normalize) s = s.normalize('NFKD').replace(/[̀-ͯ]/g, '');
    s = s.replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
    if (s.length > 48) s = s.slice(0, 48).replace(/-+$/, '');
    return s;
  }

  function camelCase(id) {
    var out = String(id || '').split(/[^A-Za-z0-9]+/).filter(Boolean).map(function (p) {
      return p.charAt(0).toUpperCase() + p.slice(1);
    }).join('');
    if (!out) out = 'MyPack';
    if (/^[0-9]/.test(out)) out = 'Pack' + out;
    return out.slice(0, 48);
  }

  function utf8(s) {
    if (typeof TextEncoder !== 'undefined') return new TextEncoder().encode(s);
    return new Uint8Array(Buffer.from(s, 'utf8')); // eslint-disable-line no-undef
  }

  function fromUtf8(b) {
    if (typeof TextDecoder !== 'undefined') return new TextDecoder('utf-8').decode(b);
    return Buffer.from(b).toString('utf8'); // eslint-disable-line no-undef
  }

  /* ------------------------------------------------------------------ schema */

  function tableDef(schema, table) {
    var t = schema && schema[table];
    if (!t) throw new Error('Unknown table ' + table);
    return t;
  }

  function colDef(schema, table, name) {
    var cols = tableDef(schema, table).columns;
    for (var i = 0; i < cols.length; i++) if (cols[i].name === name) return cols[i];
    return null;
  }

  function colDefault(c) {
    if (c.default === null || c.default === undefined) {
      if (c.null) return null;
      return c.type === 'string' ? '' : 0;
    }
    if (c.type === 'int') { var i = parseInt(c.default, 10); return isNaN(i) ? 0 : i; }
    if (c.type === 'float') { var f = parseFloat(c.default); return isNaN(f) ? 0 : f; }
    return String(c.default);
  }

  function rowVal(schema, table, row, name) {
    if (has(row, name) && row[name] !== undefined) return row[name];
    var c = colDef(schema, table, name);
    return c ? colDefault(c) : undefined;
  }

  function coerce(v, type) {
    if (type === 'int') {
      if (v === null || v === undefined || v === '') return 0;
      var n = typeof v === 'number' ? v : Number(String(v).trim());
      return isFinite(n) ? Math.trunc(n) : 0;
    }
    if (type === 'float') {
      if (v === null || v === undefined || v === '') return 0;
      var f = typeof v === 'number' ? v : Number(String(v).trim());
      return isFinite(f) ? f : 0;
    }
    return v === null || v === undefined ? '' : String(v);
  }

  /* ------------------------------------------------------------------ TOML writer */

  function tomlString(s) {
    s = String(s);
    var out = '"';
    for (var i = 0; i < s.length; i++) {
      var ch = s.charAt(i), code = s.charCodeAt(i);
      if (ch === '\\') out += '\\\\';
      else if (ch === '"') out += '\\"';
      else if (ch === '\n') out += '\\n';
      else if (ch === '\t') out += '\\t';
      else if (code < 0x20 || code === 0x7f) out += '\\u' + ('000' + code.toString(16).toUpperCase()).slice(-4);
      else out += ch;
    }
    return out + '"';
  }

  function tomlFloat(v) {
    v = Number(v);
    if (!isFinite(v)) return '0.0';
    var s = String(v);
    return /[.eE]/.test(s) ? s : s + '.0';
  }

  function tomlValue(v, type) {
    if (type === 'int') return String(coerce(v, 'int'));
    if (type === 'float') return tomlFloat(coerce(v, 'float'));
    if (type === 'bool') return v ? 'true' : 'false';
    if (Array.isArray(v)) return '[' + v.map(function (x) { return tomlString(x); }).join(', ') + ']';
    return tomlString(v === null || v === undefined ? '' : v);
  }

  function tomlKey(k) { return /^[A-Za-z0-9_-]+$/.test(k) ? k : tomlString(k); }

  function sameValue(a, b, type) {
    if (type === 'string') return (a === null ? null : String(a)) === (b === null ? null : String(b));
    return Number(a) === Number(b);
  }

  // One data/world/<table>.toml. Only columns that differ from the schema default are written, plus the
  // key column(s) and the row's display name column, always.
  function writeTableToml(schema, table, rows) {
    var def = tableDef(schema, table), keys = def.key || [];
    var out = DATA_HEADER(table);
    rows.forEach(function (row) {
      out += '\n[[row]]\n';
      if (row._override) out += 'override = true\n';
      def.columns.forEach(function (c) {
        var always = keys.indexOf(c.name) >= 0 || c.name === 'Name' || c.name === 'name' || c.name === 'Title';
        var dflt = colDefault(c);
        var v = has(row, c.name) && row[c.name] !== undefined ? row[c.name] : dflt;
        if (v === null) {
          if (!always) return;
          v = c.type === 'string' ? '' : 0;
        }
        if (!always) {
          if (c.type === 'string' && v === '' && (dflt === null || dflt === '')) return;
          if (sameValue(v, dflt, c.type)) return;
        }
        out += c.name + ' = ' + tomlValue(v, c.type) + '\n';
      });
    });
    return out;
  }

  /* ------------------------------------------------------------------ TOML reader (the subset Forge writes) */

  function parseToml(text) {
    var rootObj = {}, cur = rootObj;
    var lines = String(text).replace(/^﻿/, '').split(/\r?\n/);
    for (var ln = 0; ln < lines.length; ln++) {
      var line = lines[ln], p = { s: line, i: 0, ln: ln + 1 };
      skipWs(p);
      if (p.i >= line.length || line.charAt(p.i) === '#') continue;
      if (line.charAt(p.i) === '[') {
        var arr = line.charAt(p.i + 1) === '[';
        p.i += arr ? 2 : 1;
        var path = parseKeyPath(p);
        skipWs(p);
        var close = arr ? ']]' : ']';
        if (line.substr(p.i, close.length) !== close) throw tomlErr(p, 'expected ' + close);
        p.i += close.length;
        expectEnd(p);
        if (arr) {
          var parent = walk(rootObj, path.slice(0, -1), p), last = path[path.length - 1];
          if (!has(parent, last)) parent[last] = [];
          if (!Array.isArray(parent[last])) throw tomlErr(p, last + ' is not an array of tables');
          cur = {};
          parent[last].push(cur);
        } else {
          cur = walk(rootObj, path, p);
        }
        continue;
      }
      var kp = parseKeyPath(p);
      skipWs(p);
      if (line.charAt(p.i) !== '=') throw tomlErr(p, 'expected =');
      p.i++;
      skipWs(p);
      var val = parseValue(p);
      expectEnd(p);
      var tgt = walk(cur, kp.slice(0, -1), p);
      tgt[kp[kp.length - 1]] = val;
    }
    return rootObj;
  }

  function tomlErr(p, msg) { return new Error('TOML line ' + p.ln + ': ' + msg); }
  function skipWs(p) { while (p.i < p.s.length && (p.s.charAt(p.i) === ' ' || p.s.charAt(p.i) === '\t')) p.i++; }
  function expectEnd(p) {
    skipWs(p);
    if (p.i < p.s.length && p.s.charAt(p.i) !== '#') throw tomlErr(p, 'unexpected text');
  }

  function walk(obj, path, p) {
    for (var i = 0; i < path.length; i++) {
      var k = path[i];
      if (!has(obj, k)) obj[k] = {};
      obj = obj[k];
      if (Array.isArray(obj)) obj = obj[obj.length - 1];
      if (typeof obj !== 'object' || obj === null) throw tomlErr(p, k + ' is not a table');
    }
    return obj;
  }

  function parseKeyPath(p) {
    var parts = [];
    for (;;) {
      skipWs(p);
      var ch = p.s.charAt(p.i);
      if (ch === '"') parts.push(parseBasicString(p));
      else if (ch === "'") parts.push(parseLiteralString(p));
      else {
        var m = /^[A-Za-z0-9_-]+/.exec(p.s.slice(p.i));
        if (!m) throw tomlErr(p, 'bad key');
        parts.push(m[0]);
        p.i += m[0].length;
      }
      skipWs(p);
      if (p.s.charAt(p.i) === '.') { p.i++; continue; }
      return parts;
    }
  }

  function parseBasicString(p) {
    p.i++;
    var out = '';
    while (p.i < p.s.length) {
      var ch = p.s.charAt(p.i++);
      if (ch === '"') return out;
      if (ch !== '\\') { out += ch; continue; }
      var e = p.s.charAt(p.i++);
      if (e === 'n') out += '\n';
      else if (e === 't') out += '\t';
      else if (e === 'r') out += '\r';
      else if (e === 'b') out += '\b';
      else if (e === 'f') out += '\f';
      else if (e === '"' || e === '\\') out += e;
      else if (e === 'u' || e === 'U') {
        var len = e === 'u' ? 4 : 8, hex = p.s.substr(p.i, len);
        if (!/^[0-9A-Fa-f]+$/.test(hex) || hex.length !== len) throw tomlErr(p, 'bad unicode escape');
        out += String.fromCodePoint(parseInt(hex, 16));
        p.i += len;
      } else throw tomlErr(p, 'bad escape');
    }
    throw tomlErr(p, 'unterminated string');
  }

  function parseLiteralString(p) {
    var end = p.s.indexOf("'", p.i + 1);
    if (end < 0) throw tomlErr(p, 'unterminated string');
    var out = p.s.slice(p.i + 1, end);
    p.i = end + 1;
    return out;
  }

  function parseValue(p) {
    var ch = p.s.charAt(p.i);
    if (ch === '"') return parseBasicString(p);
    if (ch === "'") return parseLiteralString(p);
    if (ch === '[') {
      p.i++;
      var arr = [];
      for (;;) {
        skipWs(p);
        if (p.s.charAt(p.i) === ']') { p.i++; return arr; }
        arr.push(parseValue(p));
        skipWs(p);
        if (p.s.charAt(p.i) === ',') { p.i++; continue; }
        skipWs(p);
        if (p.s.charAt(p.i) === ']') { p.i++; return arr; }
        throw tomlErr(p, 'bad array');
      }
    }
    var rest = p.s.slice(p.i);
    var m = /^(true|false)\b/.exec(rest);
    if (m) { p.i += m[0].length; return m[0] === 'true'; }
    m = /^[+-]?(?:inf|nan|[0-9_]+(?:\.[0-9_]+)?(?:[eE][+-]?[0-9_]+)?)/.exec(rest);
    if (m && m[0]) {
      p.i += m[0].length;
      var t = m[0].replace(/_/g, '');
      if (/inf$/.test(t)) return t.charAt(0) === '-' ? -Infinity : Infinity;
      if (/nan$/.test(t)) return NaN;
      return Number(t);
    }
    throw tomlErr(p, 'bad value');
  }

  /* ------------------------------------------------------------------ ID ranges */

  function overlapsReserved(table, s, e) {
    return (RESERVED[table] || []).some(function (r) { return s < r[1] && r[0] < e; });
  }

  // Deterministic block for a pack and table: block = first 4 digest bytes (big-endian) % blocks,
  // stepping to the next block (with wrap) while it overlaps a reserved range.
  function rangeFromDigest(digest, table) {
    var area = AREAS[table];
    if (!area) throw new Error('No ID area for ' + table);
    var b = new Uint8Array(digest);
    var u = ((b[0] << 24) >>> 0) + (b[1] << 16) + (b[2] << 8) + b[3];
    var n = Math.floor((area[1] - area[0]) / BLOCK);
    var idx = u % n;
    for (var i = 0; i < n; i++) {
      var s = area[0] + ((idx + i) % n) * BLOCK, e = s + BLOCK;
      if (!overlapsReserved(table, s, e)) return { start: s, end: e, next: s };
    }
    throw new Error('No free ID block for ' + table);
  }

  function subtle() {
    var c = (typeof crypto !== 'undefined' && crypto) || (root && root.crypto);
    if (!c || !c.subtle) throw new Error('This browser has no Web Crypto (crypto.subtle). Use a current browser over https.');
    return c.subtle;
  }

  function pickRange(packId, table) {
    return subtle().digest('SHA-256', utf8(packId + ':' + table)).then(function (d) {
      return rangeFromDigest(d, table);
    });
  }

  function maxId(state, table) {
    var k = KEY_COL[table], m = -1;
    (state.tables[table] || []).forEach(function (r) { if (typeof r[k] === 'number' && r[k] > m) m = r[k]; });
    return m;
  }

  // Ensure the table has a range (locked once the first row exists) and hand out the next ID.
  function allocId(state, table) {
    var rangeP = state.ids[table] ? Promise.resolve(state.ids[table]) : pickRange(state.pack.id || 'my-pack', table);
    return rangeP.then(function (r) {
      state.ids[table] = r;
      var next = Math.max(r.next, maxId(state, table) + 1, r.start);
      if (next >= r.end) throw new Error('The ' + NOUN[table] + ' ID range ' + r.start + '-' + (r.end - 1) + ' is used up. Move rows to a second pack, or ask for a bigger range in Vanilla Forge.');
      r.next = next + 1;
      return next;
    });
  }

  function addRow(state, table, values) {
    return allocId(state, table).then(function (id) {
      var row = {};
      Object.keys(values || {}).forEach(function (k) { row[k] = values[k]; });
      row[KEY_COL[table]] = id;
      (state.tables[table] = state.tables[table] || []).push(row);
      return row;
    });
  }

  /* ------------------------------------------------------------------ state */

  function newState() {
    return {
      v: 1,
      pack: {
        name: 'My first pack', id: 'my-first-pack', idEdited: false, version: '0.1.0', author: '',
        license: 'MIT', description: '', realms: ['classicplus']
      },
      tables: { item_template: [], creature_template: [], quest_template: [] },
      ids: {},
      addon: { enabled: false, name: '', nameEdited: false, code: '' }
    };
  }

  function addonName(state) {
    return state.addon.nameEdited && state.addon.name ? state.addon.name : camelCase(state.pack.id);
  }

  function defaultAddonCode(name) {
    var lower = name.toLowerCase(), upper = name.toUpperCase(), db = name + 'DB';
    return [
      '-- ' + name + ': made with Vanilla Forge Lite.',
      '-- The game runs Lua 5.0: there is no # operator (use table.getn) and no string.gmatch (use string.gfind).',
      '',
      'local function Say(text)',
      '  DEFAULT_CHAT_FRAME:AddMessage("|cfff0c058' + name + ':|r " .. text)',
      'end',
      '',
      'SLASH_' + upper + '1 = "/' + lower + '"',
      'SlashCmdList["' + upper + '"] = function(msg)',
      '  if not ' + db + ' then ' + db + ' = {} end',
      '  ' + db + '.count = (' + db + '.count or 0) + 1',
      '  local words = {}',
      '  for w in string.gfind(msg or "", "%S+") do table.insert(words, w) end',
      '  Say("hello from your realm! You have said hello " .. ' + db + '.count .. " times. (" .. table.getn(words) .. " words)")',
      'end',
      ''
    ].join('\n');
  }

  function addonCode(state) {
    return state.addon.code ? state.addon.code : defaultAddonCode(addonName(state));
  }

  /* ------------------------------------------------------------------ project builder */

  function cloneRows(rows) { return (rows || []).map(function (r) { var o = {}; for (var k in r) if (has(r, k)) o[k] = r[k]; return o; }); }

  // Rows per table as they are written, with the quest giver/ender relations derived and the
  // quest-giver NPC flag set on those creatures.
  function resolvedTables(state, schema) {
    var t = {
      item_template: cloneRows(state.tables.item_template),
      creature_template: cloneRows(state.tables.creature_template),
      quest_template: cloneRows(state.tables.quest_template),
      creature_questrelation: [],
      creature_involvedrelation: []
    };
    var byId = {};
    t.creature_template.forEach(function (c) { byId[c.Entry] = c; });
    t.quest_template.forEach(function (q) {
      [['_giver', 'creature_questrelation'], ['_ender', 'creature_involvedrelation']].forEach(function (pair) {
        var cid = Number(q[pair[0]] || 0);
        if (!cid) return;
        t[pair[1]].push({ id: cid, quest: q.entry });
        var c = byId[cid];
        if (c) c.NpcFlags = (Number(rowVal(schema, 'creature_template', c, 'NpcFlags')) | NPC_QUESTGIVER) >>> 0;
      });
    });
    return t;
  }

  function writeForgeToml(pack) {
    var realms = REALMS.map(function (r) { return r[0]; }).filter(function (r) { return pack.realms.indexOf(r) >= 0; });
    return 'depends = []\n\n[pack]\n' +
      'id = ' + tomlString(pack.id) + '\n' +
      'name = ' + tomlString(pack.name) + '\n' +
      'version = ' + tomlString(pack.version) + '\n' +
      'authors = ' + tomlValue(pack.author ? [pack.author] : []) + '\n' +
      'license = ' + tomlString(pack.license) + '\n' +
      'description = ' + tomlString(pack.description) + '\n' +
      '\n[targets]\nrealms = ' + tomlValue(realms) + '\n';
  }

  function writeIdsLock(state) {
    var out = '', names = '';
    ROW_TABLES.slice().sort().forEach(function (t) {
      var rows = state.tables[t] || [];
      if (!rows.length) return;
      var r = state.ids[t] || { start: 0, end: 0, next: 0 };
      var next = Math.max(r.next, maxId(state, t) + 1);
      out += (out ? '\n' : '') + '[tables.' + t + ']\nstart = ' + r.start + '\nend = ' + r.end + '\nnext = ' + next + '\nsource = "local"\n';
      rows.slice().sort(function (a, b) { return a[KEY_COL[t]] - b[KEY_COL[t]]; }).forEach(function (row) {
        names += tomlString(t + ':' + row[KEY_COL[t]]) + ' = ' + tomlString(row[NAME_COL[t]] || '') + '\n';
      });
    });
    if (!out) return null;
    return out + '\n[names]\n' + names;
  }

  // The project as [{path, text}] in a fixed order (sorted by path).
  function buildProject(state, schema) {
    var p = state.pack, files = [];
    files.push({ path: 'forge.toml', text: writeForgeToml(p) });
    files.push({ path: 'credits.toml', text: CREDITS });
    files.push({ path: 'README.md', text: '# ' + p.name + '\n\n' + p.description + '\n\nMade with Vanilla Forge Lite.\n' });
    files.push({ path: '.gitignore', text: 'build/\n.forge/undo/\n' });
    var lock = writeIdsLock(state);
    if (lock) files.push({ path: '.forge/ids.lock', text: lock });
    var t = resolvedTables(state, schema);
    Object.keys(t).forEach(function (name) {
      if (t[name].length) files.push({ path: 'data/world/' + name + '.toml', text: writeTableToml(schema, name, t[name]) });
    });
    if (state.addon.enabled) {
      var an = addonName(state);
      files.push({
        path: 'addons/' + an + '/' + an + '.toc',
        text: '## Interface: 11200\n## Title: ' + oneLine(p.name) + '\n## Notes: Made with Vanilla Forge Lite.\n## Author: ' +
          oneLine(p.author) + '\n## Version: ' + oneLine(p.version) + '\n## SavedVariables: ' + an + 'DB\n\nCore.lua\n'
      });
      var code = addonCode(state);
      files.push({ path: 'addons/' + an + '/Core.lua', text: /\n$/.test(code) ? code : code + '\n' });
    }
    files.sort(function (a, b) { return a.path < b.path ? -1 : a.path > b.path ? 1 : 0; });
    return files;
  }

  function oneLine(s) { return String(s || '').replace(/[\r\n]+/g, ' '); }

  /* ------------------------------------------------------------------ zip (stored) */

  var CRC_TABLE = (function () {
    var t = new Uint32Array(256);
    for (var n = 0; n < 256; n++) {
      var c = n;
      for (var k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
      t[n] = c >>> 0;
    }
    return t;
  })();

  function crc32(bytes) {
    var c = 0xFFFFFFFF;
    for (var i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]) & 0xFF] ^ (c >>> 8);
    return (c ^ 0xFFFFFFFF) >>> 0;
  }

  function dosDateTime(d) {
    var y = Math.max(1980, Math.min(2107, d.getFullYear()));
    return {
      time: (d.getHours() << 11) | (d.getMinutes() << 5) | Math.floor(d.getSeconds() / 2),
      date: ((y - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate()
    };
  }

  // entries: [{name, data: Uint8Array | string}] written in the given order, stored (method 0).
  function makeZip(entries, when) {
    var dt = dosDateTime(when || new Date());
    var parts = [], central = [], offset = 0;
    entries.forEach(function (e) {
      var name = utf8(e.name), data = typeof e.data === 'string' ? utf8(e.data) : e.data;
      var crc = crc32(data);
      var lh = new Uint8Array(30 + name.length), lv = new DataView(lh.buffer);
      lv.setUint32(0, 0x04034b50, true);
      lv.setUint16(4, 10, true);
      lv.setUint16(6, 0x0800, true);
      lv.setUint16(8, 0, true);
      lv.setUint16(10, dt.time, true);
      lv.setUint16(12, dt.date, true);
      lv.setUint32(14, crc, true);
      lv.setUint32(18, data.length, true);
      lv.setUint32(22, data.length, true);
      lv.setUint16(26, name.length, true);
      lv.setUint16(28, 0, true);
      lh.set(name, 30);
      var ch = new Uint8Array(46 + name.length), cv = new DataView(ch.buffer);
      cv.setUint32(0, 0x02014b50, true);
      cv.setUint16(4, 0x031E, true); // made by: Unix, spec 3.0
      cv.setUint16(6, 10, true);
      cv.setUint16(8, 0x0800, true);
      cv.setUint16(10, 0, true);
      cv.setUint16(12, dt.time, true);
      cv.setUint16(14, dt.date, true);
      cv.setUint32(16, crc, true);
      cv.setUint32(20, data.length, true);
      cv.setUint32(24, data.length, true);
      cv.setUint16(28, name.length, true);
      cv.setUint16(30, 0, true);
      cv.setUint16(32, 0, true);
      cv.setUint16(34, 0, true);
      cv.setUint16(36, 0, true);
      cv.setUint32(38, (0x81A4 << 16) >>> 0, true); // -rw-r--r--
      cv.setUint32(42, offset, true);
      ch.set(name, 46);
      parts.push(lh, data);
      central.push(ch);
      offset += lh.length + data.length;
    });
    var cdSize = central.reduce(function (n, c) { return n + c.length; }, 0);
    var end = new Uint8Array(22), ev = new DataView(end.buffer);
    ev.setUint32(0, 0x06054b50, true);
    ev.setUint16(8, entries.length, true);
    ev.setUint16(10, entries.length, true);
    ev.setUint32(12, cdSize, true);
    ev.setUint32(16, offset, true);
    var all = parts.concat(central, [end]);
    var total = all.reduce(function (n, c) { return n + c.length; }, 0);
    var out = new Uint8Array(total), pos = 0;
    all.forEach(function (c) { out.set(c, pos); pos += c.length; });
    return out;
  }

  function projectZip(state, schema, when) {
    var prefix = state.pack.id + '/';
    return makeZip(buildProject(state, schema).map(function (f) { return { name: prefix + f.path, data: f.text }; }), when);
  }

  // Reads stored entries, and deflated ones where the browser has DecompressionStream.
  function readZip(bytes) {
    bytes = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
    var dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength), eocd = -1;
    for (var i = bytes.length - 22; i >= Math.max(0, bytes.length - 65557); i--) {
      if (dv.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
    }
    if (eocd < 0) return Promise.reject(new Error('That file is not a zip.'));
    var count = dv.getUint16(eocd + 10, true), p = dv.getUint32(eocd + 16, true), jobs = [];
    for (var n = 0; n < count; n++) {
      if (p + 46 > bytes.length || dv.getUint32(p, true) !== 0x02014b50) return Promise.reject(new Error('The zip is damaged.'));
      var method = dv.getUint16(p + 10, true), csize = dv.getUint32(p + 20, true);
      var nlen = dv.getUint16(p + 28, true), xlen = dv.getUint16(p + 30, true), clen = dv.getUint16(p + 32, true);
      var loff = dv.getUint32(p + 42, true);
      var name = fromUtf8(bytes.subarray(p + 46, p + 46 + nlen)).replace(/\\/g, '/');
      p += 46 + nlen + xlen + clen;
      if (/\/$/.test(name)) continue;
      var start = loff + 30 + dv.getUint16(loff + 26, true) + dv.getUint16(loff + 28, true);
      var raw = bytes.subarray(start, start + csize);
      jobs.push(inflateEntry(name, method, raw));
    }
    return Promise.all(jobs).then(function (list) { return list.filter(Boolean); });
  }

  function inflateEntry(name, method, raw) {
    if (method === 0) return Promise.resolve({ name: name, data: raw });
    if (method === 8 && typeof DecompressionStream !== 'undefined' && typeof Response !== 'undefined') {
      var stream = new Blob([raw]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
      return new Response(stream).arrayBuffer().then(function (b) { return { name: name, data: new Uint8Array(b) }; });
    }
    return Promise.resolve(null);
  }

  /* ------------------------------------------------------------------ import */

  // files: [{name, data}] from readZip. Returns {state, skipped: [paths]}.
  function importProject(files, schema) {
    var forge = null;
    files.forEach(function (f) {
      if (/(^|\/)forge\.toml$/.test(f.name) && (!forge || f.name.length < forge.name.length)) forge = f;
    });
    if (!forge) throw new Error('No forge.toml in that zip, so it is not a Forge project.');
    var prefix = forge.name.slice(0, forge.name.length - 'forge.toml'.length);
    var st = newState(), skipped = [], text = {};
    files.forEach(function (f) {
      if (f.name.indexOf(prefix) !== 0) { skipped.push(f.name); return; }
      text[f.name.slice(prefix.length)] = f.data;
    });
    var ft = parseToml(fromUtf8(text['forge.toml']));
    var pk = ft.pack || {};
    st.pack.id = String(pk.id || '');
    st.pack.name = String(pk.name || pk.id || '');
    st.pack.idEdited = slugify(st.pack.name) !== st.pack.id;
    st.pack.version = String(pk.version || '0.1.0');
    st.pack.author = Array.isArray(pk.authors) ? pk.authors.join(', ') : String(pk.authors || '');
    st.pack.license = String(pk.license || 'MIT');
    st.pack.description = String(pk.description || '');
    st.pack.realms = (ft.targets && Array.isArray(ft.targets.realms)) ? ft.targets.realms.map(String) : [];
    var handled = { 'forge.toml': 1, 'credits.toml': 1, 'README.md': 1, '.gitignore': 1, '.forge/ids.lock': 1 };
    if (text['.forge/ids.lock']) {
      var lock = parseToml(fromUtf8(text['.forge/ids.lock']));
      var tabs = lock.tables || {};
      ROW_TABLES.forEach(function (t) {
        var r = tabs[t];
        if (r && isFinite(r.start) && isFinite(r.end)) st.ids[t] = { start: Number(r.start), end: Number(r.end), next: Number(r.next || r.start) };
      });
    }
    var rel = { creature_questrelation: '_giver', creature_involvedrelation: '_ender' }, relRows = {};
    Object.keys(text).forEach(function (path) {
      var m = /^data\/world\/([a-z_]+)\.toml$/.exec(path);
      if (!m) return;
      var table = m[1];
      if (ROW_TABLES.indexOf(table) < 0 && !rel[table]) return;
      var doc = parseToml(fromUtf8(text[path]));
      var rows = Array.isArray(doc.row) ? doc.row : [];
      handled[path] = 1;
      if (rel[table]) { relRows[table] = rows; return; }
      st.tables[table] = rows.map(function (r) {
        var row = {};
        Object.keys(r).forEach(function (k) {
          if (k === 'override') { if (r[k]) row._override = true; return; }
          var c = colDef(schema, table, k);
          if (c) row[k] = coerce(r[k], c.type);
        });
        return row;
      });
    });
    Object.keys(relRows).forEach(function (table) {
      relRows[table].forEach(function (r) {
        var q = st.tables.quest_template.filter(function (x) { return x.entry === Number(r.quest); })[0];
        if (q && !q[rel[table]]) q[rel[table]] = Number(r.id);
      });
    });
    Object.keys(text).forEach(function (path) {
      var m = /^addons\/([^/]+)\/Core\.lua$/.exec(path);
      if (m && !st.addon.enabled) {
        st.addon.enabled = true;
        st.addon.name = m[1];
        st.addon.nameEdited = m[1] !== camelCase(st.pack.id);
        var code = fromUtf8(text[path]);
        st.addon.code = code === defaultAddonCode(m[1]) ? '' : code;
        handled[path] = 1;
        handled['addons/' + m[1] + '/' + m[1] + '.toc'] = 1;
      }
    });
    Object.keys(text).forEach(function (path) { if (!handled[path]) skipped.push(prefix + path); });
    ROW_TABLES.forEach(function (t) {
      if (st.tables[t].length && !st.ids[t]) {
        var lo = Infinity, hi = -1;
        st.tables[t].forEach(function (r) { lo = Math.min(lo, r[KEY_COL[t]]); hi = Math.max(hi, r[KEY_COL[t]]); });
        var s = Math.floor(lo / BLOCK) * BLOCK;
        st.ids[t] = { start: s, end: s + BLOCK, next: hi + 1 };
      }
    });
    return { state: st, skipped: skipped };
  }

  /* ------------------------------------------------------------------ validation */

  function validate(state, schema) {
    var out = [];
    function add(level, table, index, msg) { out.push({ level: level, table: table, index: index, msg: msg }); }
    var p = state.pack;
    if (!String(p.name).trim()) add('error', 'pack', -1, 'Give your pack a name.');
    if (!ID_RE.test(p.id)) add('error', 'pack', -1, 'The pack ID may only use lowercase letters, digits and single dashes (like my-pack).');
    if (!SEMVER_RE.test(p.version)) add('error', 'pack', -1, 'The version should look like 0.1.0.');
    if (!p.realms.length) add('error', 'pack', -1, 'Choose at least one realm the pack is for.');
    if (!String(p.author).trim()) add('warn', 'pack', -1, 'Add an author name so players know who made this.');
    var rowsTotal = ROW_TABLES.reduce(function (n, t) { return n + (state.tables[t] || []).length; }, 0);
    if (!rowsTotal && !state.addon.enabled) add('warn', 'pack', -1, 'The pack is empty. Add an item, a creature, a quest or an addon.');
    if (state.addon.enabled) {
      if (!ADDON_RE.test(addonName(state))) add('error', 'addon', -1, 'The addon name must start with a letter and use only letters, digits and _.');
      if (!String(addonCode(state)).trim()) add('warn', 'addon', -1, 'The addon has no code yet.');
    }
    ROW_TABLES.forEach(function (t) {
      var r = state.ids[t], rows = state.tables[t] || [], key = KEY_COL[t];
      if (r && rows.length) {
        var used = Math.max(r.next, maxId(state, t) + 1) - r.start;
        if (used >= BLOCK) add('error', t, -1, 'All ' + BLOCK + ' ' + NOUN[t] + ' IDs of this pack are used. Split the pack in Vanilla Forge.');
        else if (used >= BLOCK * 0.9) add('warn', t, -1, 'Only ' + (BLOCK - used) + ' ' + NOUN[t] + ' IDs are left in this pack\'s range.');
      }
      var seen = {};
      rows.forEach(function (row, i) {
        var id = row[key];
        if (seen[id]) add('error', t, i, 'Two rows share ID ' + id + '.');
        seen[id] = 1;
        if (r && (id < r.start || id >= r.end)) add('warn', t, i, 'ID ' + id + ' is outside this pack\'s range ' + r.start + '-' + (r.end - 1) + '.');
        var v = function (c) { return rowVal(schema, t, row, c); };
        if (!String(v(NAME_COL[t]) || '').trim()) add('error', t, i, 'This ' + NOUN[t] + ' needs a ' + (t === 'quest_template' ? 'title' : 'name') + '.');
        if (t === 'item_template') {
          if (v('RequiredLevel') < 0 || v('RequiredLevel') > 60) add('warn', t, i, 'Required level is usually between 0 and 60.');
          if (v('ItemLevel') < 0 || v('ItemLevel') > 100) add('warn', t, i, 'Item level is usually between 0 and 100.');
          if (v('Quality') < 0 || v('Quality') > 6) add('error', t, i, 'Quality must be 0 to 6.');
          if (v('dmg_max1') < v('dmg_min1')) add('error', t, i, 'Maximum damage is lower than minimum damage.');
          if (v('class') === 2 && v('dmg_max1') <= 0) add('warn', t, i, 'This weapon does no damage yet.');
          if (v('stackable') < 1) add('warn', t, i, 'Stack size should be at least 1.');
          if (v('SellPrice') > v('BuyPrice') && v('BuyPrice') > 0) add('warn', t, i, 'It sells to vendors for more than it costs.');
        } else if (t === 'creature_template') {
          if (v('MinLevel') < 1 || v('MinLevel') > 63) add('error', t, i, 'Minimum level must be between 1 and 63.');
          if (v('MaxLevel') < v('MinLevel') || v('MaxLevel') > 63) add('error', t, i, 'Maximum level must be at least the minimum level and at most 63.');
          if (!v('Faction')) add('warn', t, i, 'Faction 0 is unusual. 35 is friendly to everyone, 14 is hostile.');
          if (v('HealthMultiplier') <= 0) add('error', t, i, 'Health multiplier must be above 0.');
          if (v('Scale') < 0) add('error', t, i, 'Scale cannot be negative.');
          if (!v('DisplayId1')) add('warn', t, i, 'No model yet (display ID 0). Pick one in Vanilla Forge on your computer.');
        } else if (t === 'quest_template') {
          var ql = v('QuestLevel'), ml = v('MinLevel');
          if (ql < -1 || ql > 60) add('error', t, i, 'Quest level must be between 1 and 60 (or -1 to follow the player).');
          if (ml < 0 || ml > 60) add('error', t, i, 'Minimum level must be between 0 and 60.');
          if (ql > 0 && ml > ql) add('warn', t, i, 'The minimum level is above the quest level.');
          var creatures = {};
          (state.tables.creature_template || []).forEach(function (c) { creatures[c.Entry] = c; });
          if (!row._giver) add('warn', t, i, 'Nobody gives this quest yet. Pick a quest giver.');
          else if (!creatures[row._giver]) add('error', t, i, 'The quest giver is not a creature in this pack.');
          if (row._ender && !creatures[row._ender]) add('error', t, i, 'The quest ender is not a creature in this pack.');
          if (!row._ender && row._giver) add('warn', t, i, 'Nobody takes this quest back yet. Pick who completes it.');
          [['ReqCreatureOrGOId1', 'ReqCreatureOrGOCount1', 'kills'], ['ReqItemId1', 'ReqItemCount1', 'items'], ['RewItemId1', 'RewItemCount1', 'reward items']].forEach(function (pr) {
            if (v(pr[0]) && v(pr[1]) <= 0) add('warn', t, i, 'Set how many ' + pr[2] + ' (the count is 0).');
          });
        }
      });
    });
    return out;
  }

  /* ------------------------------------------------------------------ exports */

  var api = {
    REALMS: REALMS, LICENSES: LICENSES, AREAS: AREAS, RESERVED: RESERVED, BLOCK: BLOCK, KEY_COL: KEY_COL, NAME_COL: NAME_COL,
    slugify: slugify, camelCase: camelCase, colDefault: colDefault, rowVal: rowVal, coerce: coerce,
    tomlString: tomlString, tomlFloat: tomlFloat, writeTableToml: writeTableToml, parseToml: parseToml,
    rangeFromDigest: rangeFromDigest, pickRange: pickRange, allocId: allocId, addRow: addRow,
    newState: newState, addonName: addonName, defaultAddonCode: defaultAddonCode,
    buildProject: buildProject, writeForgeToml: writeForgeToml, writeIdsLock: writeIdsLock,
    crc32: crc32, makeZip: makeZip, projectZip: projectZip, readZip: readZip, importProject: importProject,
    validate: validate, utf8: utf8, fromUtf8: fromUtf8
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  root.ForgeLite = api;
  if (typeof document !== 'undefined') startUi(api);

  /* ================================================================== page UI */

  function startUi(L) {
    var STORE = 'forge-lite:v1';
    var schema = null, state = null;
    var ui = { tab: 'item_template', sel: { item_template: 0, creature_template: 0, quest_template: 0 } };
    var $ = function (id) { return document.getElementById(id); };

    var QUALITY = [[0, 'Poor'], [1, 'Common'], [2, 'Uncommon'], [3, 'Rare'], [4, 'Epic'], [5, 'Legendary']];
    var ITEM_CLASS = [[0, 'Consumable'], [2, 'Weapon'], [4, 'Armor'], [7, 'Trade goods'], [12, 'Quest'], [15, 'Junk']];
    var SLOTS = [[0, 'Not equipped'], [1, 'Head'], [2, 'Neck'], [3, 'Shoulder'], [4, 'Shirt'], [5, 'Chest'], [20, 'Chest (robe)'],
      [6, 'Waist'], [7, 'Legs'], [8, 'Feet'], [9, 'Wrist'], [10, 'Hands'], [11, 'Finger'], [12, 'Trinket'], [16, 'Back'],
      [13, 'One-hand'], [21, 'Main hand'], [22, 'Off hand'], [17, 'Two-hand'], [14, 'Shield'], [23, 'Held in off hand'],
      [15, 'Ranged (bow)'], [26, 'Ranged (gun, crossbow, wand)'], [25, 'Thrown'], [18, 'Bag'], [19, 'Tabard']];
    var STATS = [[0, 'None'], [3, 'Agility'], [4, 'Strength'], [5, 'Intellect'], [6, 'Spirit'], [7, 'Stamina']];
    var RANKS = [[0, 'Normal'], [1, 'Elite'], [2, 'Rare elite'], [3, 'Boss'], [4, 'Rare']];
    var NPC_FLAGS = [[1, 'Talks (gossip)'], [2, 'Quest giver'], [4, 'Vendor'], [16, 'Trainer']];

    var FORMS = {
      item_template: [
        { col: 'name', label: 'Name', kind: 'text', req: true },
        { col: 'Quality', label: 'Quality', kind: 'select', opts: QUALITY },
        { col: 'class', label: 'Kind', kind: 'select', opts: ITEM_CLASS },
        { col: 'subclass', label: 'Subclass', kind: 'int', hint: 'A number inside the kind, e.g. weapons: 0 one-hand axe, 7 one-hand sword, 10 staff; armor: 1 cloth, 2 leather, 3 mail, 4 plate.' },
        { col: 'InventoryType', label: 'Slot', kind: 'select', opts: SLOTS },
        { col: 'ItemLevel', label: 'Item level', kind: 'int', min: 0 },
        { col: 'RequiredLevel', label: 'Required level', kind: 'int', min: 0, max: 60 },
        { col: 'BuyPrice', label: 'Buy price', kind: 'money' },
        { col: 'SellPrice', label: 'Sell price', kind: 'money' },
        { col: 'stackable', label: 'Stack size', kind: 'int', min: 1 },
        { kind: 'stat', n: 1 }, { kind: 'stat', n: 2 }, { kind: 'stat', n: 3 },
        { col: 'armor', label: 'Armor', kind: 'int', min: 0 },
        { col: 'dmg_min1', label: 'Weapon damage, min', kind: 'float', min: 0 },
        { col: 'dmg_max1', label: 'Weapon damage, max', kind: 'float', min: 0 },
        { col: 'delay', label: 'Weapon speed (ms)', kind: 'int', min: 0, hint: '2000 is a 2.0 second swing.' },
        { col: 'displayid', label: 'Display ID', kind: 'int', min: 0, hint: 'The look of the item. Vanilla Forge on your computer picks models for you.' },
        { col: 'description', label: 'Flavour text', kind: 'textarea', wide: true }
      ],
      creature_template: [
        { col: 'Name', label: 'Name', kind: 'text', req: true },
        { col: 'SubName', label: 'Title under the name', kind: 'text', hint: 'For example <Blacksmith>. Leave empty for none.' },
        { col: 'MinLevel', label: 'Minimum level', kind: 'int', min: 1, max: 63 },
        { col: 'MaxLevel', label: 'Maximum level', kind: 'int', min: 1, max: 63 },
        { col: 'Faction', label: 'Faction', kind: 'int', min: 0, hint: '35 is friendly to everyone, 14 is hostile, 7 is neutral (fights back).' },
        { col: 'Rank', label: 'Rank', kind: 'select', opts: RANKS },
        { col: 'NpcFlags', label: 'Does', kind: 'flags', opts: NPC_FLAGS, wide: true },
        { col: 'HealthMultiplier', label: 'Health multiplier', kind: 'float', min: 0 },
        { col: 'DamageMultiplier', label: 'Damage multiplier', kind: 'float', min: 0 },
        { col: 'DisplayId1', label: 'Display ID', kind: 'int', min: 0, hint: 'The model. Vanilla Forge on your computer picks models for you.' },
        { col: 'Scale', label: 'Scale', kind: 'float', min: 0, hint: '1 is normal size.' }
      ],
      quest_template: [
        { col: 'Title', label: 'Title', kind: 'text', req: true, wide: true },
        { col: '_giver', label: 'Given by', kind: 'npc', hint: 'Becomes a quest giver automatically.' },
        { col: '_ender', label: 'Completed at', kind: 'npc' },
        { col: 'MinLevel', label: 'Minimum level', kind: 'int', min: 0, max: 60 },
        { col: 'QuestLevel', label: 'Quest level', kind: 'int', min: -1, max: 60, hint: 'Experience comes from the quest level.' },
        { col: 'Details', label: 'Story (what the giver says)', kind: 'textarea', wide: true },
        { col: 'Objectives', label: 'Objectives', kind: 'textarea', wide: true },
        { col: 'RequestItemsText', label: 'While in progress', kind: 'textarea', wide: true },
        { col: 'OfferRewardText', label: 'On completion', kind: 'textarea', wide: true },
        { col: 'ReqCreatureOrGOId1', label: 'Kill', kind: 'ref', ref: 'creature_template', count: 'ReqCreatureOrGOCount1' },
        { col: 'ReqItemId1', label: 'Bring item', kind: 'ref', ref: 'item_template', count: 'ReqItemCount1' },
        { col: 'RewItemId1', label: 'Reward item', kind: 'ref', ref: 'item_template', count: 'RewItemCount1' },
        { col: 'RewOrReqMoney', label: 'Reward money', kind: 'money' },
        { col: 'RewMoneyMaxLevel', label: 'Money at max level (copper)', kind: 'int', min: 0, hint: 'Paid instead of experience to players at the level cap.' }
      ]
    };
    var NEW_ROW = {
      item_template: { name: 'New item', Quality: 1, ItemLevel: 1 },
      creature_template: { Name: 'New creature', Faction: 35, MinLevel: 1, MaxLevel: 1 },
      quest_template: { Title: 'New quest', MinLevel: 1, QuestLevel: 1, Method: 2 }
    };

    /* ---- element helper (no style attributes ever) */
    function h(tag, attrs, kids) {
      var el = document.createElement(tag);
      Object.keys(attrs || {}).forEach(function (k) {
        var v = attrs[k];
        if (v === null || v === undefined || v === false) return;
        if (k === 'text') el.textContent = v;
        else if (k === 'cls') el.className = v;
        else if (k.slice(0, 2) === 'on') el.addEventListener(k.slice(2), v);
        else if (k === 'value' || k === 'checked' || k === 'disabled' || k === 'readOnly') el[k] = v;
        else el.setAttribute(k, v === true ? '' : v);
      });
      (kids || []).forEach(function (c) { if (c) el.appendChild(typeof c === 'string' ? document.createTextNode(c) : c); });
      return el;
    }
    var uid = 0;
    function nid(base) { uid += 1; return 'f-' + base + '-' + uid; }

    /* ---- storage */
    function save() {
      try { localStorage.setItem(STORE, JSON.stringify(state)); } catch (e) { /* private mode etc. */ }
    }
    function load() {
      try {
        var raw = localStorage.getItem(STORE);
        if (!raw) return null;
        var s = JSON.parse(raw), d = L.newState();
        if (!s || s.v !== 1 || !s.pack || !s.tables) return null;
        Object.keys(d.pack).forEach(function (k) { if (s.pack[k] === undefined) s.pack[k] = d.pack[k]; });
        ['item_template', 'creature_template', 'quest_template'].forEach(function (t) { if (!Array.isArray(s.tables[t])) s.tables[t] = []; });
        s.ids = s.ids || {};
        s.addon = s.addon || d.addon;
        return s;
      } catch (e) { return null; }
    }

    function status(msg, bad) {
      var el = $('status');
      el.textContent = msg;
      el.className = 'status' + (bad ? ' bad' : '');
    }

    /* ---- pack panel */
    function bindPack() {
      var p = function () { return state.pack; };
      $('pack-name').addEventListener('input', function () {
        p().name = this.value;
        if (!p().idEdited) { p().id = L.slugify(this.value) || 'my-pack'; $('pack-id').value = p().id; packIdChanged(); }
        changed();
      });
      $('pack-id').addEventListener('input', function () {
        p().id = this.value.trim();
        p().idEdited = p().id !== L.slugify(p().name);
        packIdChanged();
        changed();
      });
      ['version', 'author', 'license', 'description'].forEach(function (k) {
        $('pack-' + k).addEventListener('input', function () { p()[k] = this.value; changed(); });
      });
      $('pack-license').addEventListener('change', function () { p().license = this.value; changed(); });
      Array.prototype.forEach.call(document.querySelectorAll('input[name="realm"]'), function (cb) {
        cb.addEventListener('change', function () {
          var on = Array.prototype.filter.call(document.querySelectorAll('input[name="realm"]'), function (x) { return x.checked; });
          p().realms = on.map(function (x) { return x.value; });
          changed();
        });
      });
    }
    function packIdChanged() {
      // Ranges lock once a table has rows; empty tables follow the (new) pack ID.
      ['item_template', 'creature_template', 'quest_template'].forEach(function (t) {
        if (!state.tables[t].length) delete state.ids[t];
      });
      if (ui.tab === 'addon') renderPanel();
    }
    function fillPack() {
      var p = state.pack;
      $('pack-name').value = p.name;
      $('pack-id').value = p.id;
      $('pack-version').value = p.version;
      $('pack-author').value = p.author;
      $('pack-description').value = p.description;
      var lic = $('pack-license');
      if (!Array.prototype.some.call(lic.options, function (o) { return o.value === p.license; })) lic.appendChild(h('option', { value: p.license, text: p.license }));
      lic.value = p.license;
      Array.prototype.forEach.call(document.querySelectorAll('input[name="realm"]'), function (cb) { cb.checked = p.realms.indexOf(cb.value) >= 0; });
    }

    /* ---- tabs */
    function bindTabs() {
      var tabs = Array.prototype.slice.call(document.querySelectorAll('[role="tab"]'));
      tabs.forEach(function (tb, i) {
        tb.addEventListener('click', function () { selectTab(tb.getAttribute('data-tab')); });
        tb.addEventListener('keydown', function (e) {
          var j = e.key === 'ArrowRight' ? i + 1 : e.key === 'ArrowLeft' ? i - 1 : e.key === 'Home' ? 0 : e.key === 'End' ? tabs.length - 1 : null;
          if (j === null) return;
          e.preventDefault();
          j = (j + tabs.length) % tabs.length;
          tabs[j].focus();
          selectTab(tabs[j].getAttribute('data-tab'));
        });
      });
    }
    function selectTab(t) {
      ui.tab = t;
      Array.prototype.forEach.call(document.querySelectorAll('[role="tab"]'), function (tb) {
        var on = tb.getAttribute('data-tab') === t;
        tb.setAttribute('aria-selected', on ? 'true' : 'false');
        tb.tabIndex = on ? 0 : -1;
        if (on) $('panel').setAttribute('aria-labelledby', tb.id);
      });
      renderPanel();
    }
    function updateCounts() {
      Array.prototype.forEach.call(document.querySelectorAll('[role="tab"]'), function (tb) {
        var t = tb.getAttribute('data-tab'), c = tb.querySelector('.count');
        if (!c) return;
        c.textContent = t === 'addon' ? (state.addon.enabled ? 'on' : '') : String(state.tables[t].length || '');
      });
    }

    /* ---- the row editor */
    var controls = [];

    function curRows() { return state.tables[ui.tab]; }
    function curRow() { var r = curRows(); return r[Math.min(ui.sel[ui.tab], r.length - 1)] || null; }
    function rowLabel(t, row) {
      var n = String(L.rowVal(schema, t, row, L.NAME_COL[t]) || '').trim();
      return (n || '(no name)');
    }

    function renderPanel() {
      var panel = $('panel');
      panel.textContent = '';
      controls = [];
      if (!schema) { panel.appendChild(h('p', { cls: 'muted', text: 'Loading the table list…' })); return; }
      if (ui.tab === 'addon') { renderAddon(panel); return; }
      var t = ui.tab, rows = curRows(), noun = { item_template: 'item', creature_template: 'creature', quest_template: 'quest' }[t];
      if (ui.sel[t] >= rows.length) ui.sel[t] = Math.max(0, rows.length - 1);
      var list = h('ul', { cls: 'row-list', 'aria-label': 'Your ' + noun + 's' });
      rows.forEach(function (row, i) {
        list.appendChild(h('li', {}, [h('button', {
          type: 'button', cls: 'row-btn' + (i === ui.sel[t] ? ' on' : ''), 'aria-current': i === ui.sel[t] ? 'true' : null,
          'data-index': String(i), onclick: function () { ui.sel[t] = i; renderPanel(); }
        }, [h('span', { cls: 'rname', text: rowLabel(t, row) }), h('span', { cls: 'rid', text: '#' + row[L.KEY_COL[t]] })])]));
      });
      if (!rows.length) list.appendChild(h('li', { cls: 'muted empty', text: 'No ' + noun + 's yet.' }));
      var side = h('div', { cls: 'rows' }, [
        h('div', { cls: 'row-actions' }, [
          h('button', { type: 'button', cls: 'btn btn-gold', id: 'add-row', text: 'Add ' + noun, onclick: function () { addNew(t, null); } }),
          h('button', { type: 'button', cls: 'btn', text: 'Duplicate', disabled: !rows.length, onclick: function () { addNew(t, curRow()); } }),
          h('button', { type: 'button', cls: 'btn btn-danger', text: 'Delete', disabled: !rows.length, onclick: function () { delRow(t); } })
        ]),
        list
      ]);
      var main = h('div', { cls: 'form-area' });
      var row = curRow();
      if (!row) {
        main.appendChild(h('p', { cls: 'muted', text: emptyText(t) }));
      } else {
        main.appendChild(h('div', { cls: 'form-head' }, [
          h('h3', { text: noun.charAt(0).toUpperCase() + noun.slice(1) + ' #' + row[L.KEY_COL[t]] }),
          h('ul', { cls: 'issues', id: 'row-issues', 'aria-live': 'polite' })
        ]));
        var grid = h('div', { cls: 'grid' });
        FORMS[t].forEach(function (f) { grid.appendChild(control(t, row, f)); });
        main.appendChild(grid);
        var det = h('details', { cls: 'allcols' }, [h('summary', { text: 'All columns (' + schema[t].columns.length + ')' })]);
        var filled = false;
        det.addEventListener('toggle', function () {
          if (!det.open || filled) return;
          filled = true;
          var g = h('div', { cls: 'grid grid-all' });
          g.appendChild(h('p', { cls: 'muted wide', text: 'Every column of ' + t + '. Values equal to the default are left out of the file.' }));
          schema[t].columns.forEach(function (c) { g.appendChild(rawControl(t, row, c)); });
          det.appendChild(g);
        });
        main.appendChild(det);
      }
      panel.appendChild(h('div', { cls: 'split' }, [side, main]));
      showIssues();
    }

    function emptyText(t) {
      if (t === 'item_template') return 'Add an item: a sword, a potion, a quest trophy. Pick its look later in Vanilla Forge.';
      if (t === 'creature_template') return 'Add a creature: a quest giver, a vendor, or something to fight.';
      return 'Add a quest. Make a creature first so someone can hand it out.';
    }

    function addNew(t, from) {
      var vals = {};
      var src = from || NEW_ROW[t];
      Object.keys(src).forEach(function (k) { if (k !== L.KEY_COL[t]) vals[k] = src[k]; });
      if (from) vals[L.NAME_COL[t]] = String(L.rowVal(schema, t, from, L.NAME_COL[t]) || '') + ' (copy)';
      L.addRow(state, t, vals).then(function () {
        ui.sel[t] = state.tables[t].length - 1;
        changed();
        renderPanel();
        var first = document.querySelector('#panel .grid input, #panel .grid textarea');
        if (first) { first.focus(); if (first.select) first.select(); }
        status('Added ' + rowLabel(t, curRow()) + '.');
      }).catch(function (e) { status(e.message, true); });
    }

    function delRow(t) {
      var rows = state.tables[t], i = ui.sel[t], row = rows[i];
      if (!row) return;
      rows.splice(i, 1);
      if (t === 'creature_template') {
        state.tables.quest_template.forEach(function (q) {
          if (q._giver === row.Entry) delete q._giver;
          if (q._ender === row.Entry) delete q._ender;
        });
      }
      ui.sel[t] = Math.max(0, i - 1);
      status('Deleted ' + rowLabel(t, row) + '.');
      changed();
      renderPanel();
    }

    function setVal(t, row, col, v) {
      if (col.charAt(0) === '_') { if (v) row[col] = v; else delete row[col]; }
      else row[col] = v;
      if (col === '_giver' || col === '_ender') {
        var c = state.tables.creature_template.filter(function (x) { return x.Entry === v; })[0];
        if (c) c.NpcFlags = (Number(L.rowVal(schema, 'creature_template', c, 'NpcFlags')) | 2) >>> 0;
      }
    }

    function edited(t, row, col, src) {
      controls.forEach(function (c) { if (c !== src && c.cols.indexOf(col) >= 0) c.refresh(); });
      if (col === L.NAME_COL[t]) {
        var b = document.querySelector('#panel .row-btn.on .rname');
        if (b) b.textContent = rowLabel(t, row);
      }
      changed();
    }

    function wrapField(f, id, input, extra) {
      var kids = [h('label', { 'for': id, text: f.label + (f.req ? ' *' : '') }), input];
      if (f.hint) {
        input.setAttribute('aria-describedby', id + '-hint');
        kids.push(h('small', { id: id + '-hint', cls: 'hint', text: f.hint }));
      }
      return h('div', { cls: 'field' + (f.wide ? ' wide' : '') + (extra ? ' ' + extra : '') }, kids);
    }

    function numInput(id, type, f) {
      return h('input', {
        id: id, type: 'number', inputmode: type === 'int' ? 'numeric' : 'decimal', step: type === 'int' ? '1' : 'any',
        min: f && f.min !== undefined ? String(f.min) : null, max: f && f.max !== undefined ? String(f.max) : null
      });
    }

    function control(t, row, f) {
      var get = function (c) { return c.charAt(0) === '_' ? (row[c] || 0) : L.rowVal(schema, t, row, c); };
      var reg = function (cols, refresh, el) { var c = { cols: cols, refresh: refresh }; controls.push(c); refresh(); return { c: c, el: el }; };
      var id = nid(f.col || 'stat' + f.n), r;
      if (f.kind === 'text' || f.kind === 'textarea') {
        var inp = f.kind === 'text' ? h('input', { id: id, type: 'text', autocomplete: 'off', required: f.req || null }) : h('textarea', { id: id, rows: '3' });
        r = reg([f.col], function () { var v = get(f.col); inp.value = v === null ? '' : v; }, wrapField(f, id, inp));
        inp.addEventListener('input', function () { setVal(t, row, f.col, inp.value); edited(t, row, f.col, r.c); });
        return r.el;
      }
      if (f.kind === 'int' || f.kind === 'float') {
        var ni = numInput(id, f.kind, f);
        r = reg([f.col], function () { ni.value = String(get(f.col)); }, wrapField(f, id, ni));
        ni.addEventListener('input', function () {
          if (ni.value === '' || isNaN(Number(ni.value))) return;
          setVal(t, row, f.col, L.coerce(ni.value, f.kind)); edited(t, row, f.col, r.c);
        });
        return r.el;
      }
      if (f.kind === 'select') {
        var sel = h('select', { id: id });
        f.opts.forEach(function (o) { sel.appendChild(h('option', { value: String(o[0]), text: o[1] })); });
        r = reg([f.col], function () {
          var v = String(get(f.col));
          if (!sel.querySelector('option[value="' + v + '"]')) sel.appendChild(h('option', { value: v, text: 'Other (' + v + ')' }));
          sel.value = v;
        }, wrapField(f, id, sel));
        sel.addEventListener('change', function () { setVal(t, row, f.col, Number(sel.value)); edited(t, row, f.col, r.c); });
        return r.el;
      }
      if (f.kind === 'money') {
        var g = numInput(id + '-g', 'int', { min: 0 }), s = numInput(id + '-s', 'int', { min: 0, max: 99 }), cc = numInput(id + '-c', 'int', { min: 0, max: 99 });
        var box = h('fieldset', { cls: 'field money' + (f.wide ? ' wide' : '') }, [
          h('legend', { text: f.label }),
          h('div', { cls: 'coins' }, [
            h('label', { cls: 'coin', 'for': id + '-g' }, [g, h('span', { cls: 'cg', text: 'g' }), h('span', { cls: 'sr', text: ' gold' })]),
            h('label', { cls: 'coin', 'for': id + '-s' }, [s, h('span', { cls: 'cs', text: 's' }), h('span', { cls: 'sr', text: ' silver' })]),
            h('label', { cls: 'coin', 'for': id + '-c' }, [cc, h('span', { cls: 'cc', text: 'c' }), h('span', { cls: 'sr', text: ' copper' })])
          ])
        ]);
        g.setAttribute('aria-label', f.label + ', gold');
        s.setAttribute('aria-label', f.label + ', silver');
        cc.setAttribute('aria-label', f.label + ', copper');
        r = reg([f.col], function () {
          var v = Math.max(0, Number(get(f.col)) || 0);
          g.value = String(Math.floor(v / 10000)); s.value = String(Math.floor(v / 100) % 100); cc.value = String(v % 100);
        }, box);
        var onm = function () {
          var v = (parseInt(g.value, 10) || 0) * 10000 + (parseInt(s.value, 10) || 0) * 100 + (parseInt(cc.value, 10) || 0);
          setVal(t, row, f.col, Math.max(0, v)); edited(t, row, f.col, r.c);
        };
        [g, s, cc].forEach(function (x) { x.addEventListener('input', onm); });
        return r.el;
      }
      if (f.kind === 'flags') {
        var cbs = [];
        var fs = h('fieldset', { cls: 'field flags wide' }, [h('legend', { text: f.label })].concat(f.opts.map(function (o) {
          var cid = nid('flag' + o[0]), cb = h('input', { type: 'checkbox', id: cid, value: String(o[0]) });
          cbs.push(cb);
          return h('label', { cls: 'check', 'for': cid }, [cb, ' ' + o[1]]);
        })));
        r = reg([f.col], function () { var v = Number(get(f.col)) >>> 0; cbs.forEach(function (cb) { cb.checked = (v & Number(cb.value)) !== 0; }); }, fs);
        cbs.forEach(function (cb) {
          cb.addEventListener('change', function () {
            var v = Number(get(f.col)) >>> 0, bit = Number(cb.value);
            v = cb.checked ? (v | bit) : (v & ~bit);
            setVal(t, row, f.col, v >>> 0); edited(t, row, f.col, r.c);
          });
        });
        return r.el;
      }
      if (f.kind === 'stat') {
        var tc = 'stat_type' + f.n, vc = 'stat_value' + f.n;
        var st = h('select', { id: id + '-t', 'aria-label': 'Stat ' + f.n + ' type' });
        STATS.forEach(function (o) { st.appendChild(h('option', { value: String(o[0]), text: o[1] })); });
        var sv = numInput(id + '-v', 'int', {});
        sv.setAttribute('aria-label', 'Stat ' + f.n + ' amount');
        var w = h('div', { cls: 'field' }, [h('label', { 'for': id + '-t', text: 'Stat ' + f.n }), h('div', { cls: 'pair' }, [st, sv])]);
        r = reg([tc, vc], function () {
          var tv = String(get(tc));
          if (!st.querySelector('option[value="' + tv + '"]')) st.appendChild(h('option', { value: tv, text: 'Other (' + tv + ')' }));
          st.value = tv; sv.value = String(get(vc));
        }, w);
        st.addEventListener('change', function () { setVal(t, row, tc, Number(st.value)); edited(t, row, tc, r.c); });
        sv.addEventListener('input', function () { if (sv.value === '') return; setVal(t, row, vc, L.coerce(sv.value, 'int')); edited(t, row, vc, r.c); });
        return r.el;
      }
      if (f.kind === 'npc') {
        var ns = h('select', { id: id });
        var fillN = function () {
          ns.textContent = '';
          ns.appendChild(h('option', { value: '0', text: '(nobody)' }));
          state.tables.creature_template.forEach(function (c) {
            ns.appendChild(h('option', { value: String(c.Entry), text: rowLabel('creature_template', c) + ' #' + c.Entry }));
          });
          var v = String(get(f.col));
          if (!ns.querySelector('option[value="' + v + '"]')) ns.appendChild(h('option', { value: v, text: 'Missing creature #' + v }));
          ns.value = v;
        };
        r = reg([f.col], fillN, wrapField(f, id, ns));
        ns.addEventListener('change', function () { setVal(t, row, f.col, Number(ns.value)); edited(t, row, f.col, r.c); });
        return r.el;
      }
      if (f.kind === 'ref') {
        var rid = numInput(id, 'int', { min: 0 }), rc = numInput(id + '-n', 'int', { min: 0 });
        var pick = h('select', { id: id + '-p', 'aria-label': f.label + ': pick from this pack' });
        var cntLabel = f.ref === 'creature_template' ? 'How many' : 'Count';
        var w2 = h('div', { cls: 'field wide ref' }, [
          h('span', { cls: 'lbl', text: f.label }),
          h('div', { cls: 'ref-row' }, [
            h('div', { cls: 'sub' }, [h('label', { 'for': id + '-p', cls: 'small', text: 'From this pack' }), pick]),
            h('div', { cls: 'sub' }, [h('label', { 'for': id, cls: 'small', text: 'or any ID' }), rid]),
            h('div', { cls: 'sub' }, [h('label', { 'for': id + '-n', cls: 'small', text: cntLabel }), rc])
          ])
        ]);
        r = reg([f.col, f.count], function () {
          var v = Number(get(f.col));
          pick.textContent = '';
          pick.appendChild(h('option', { value: '0', text: '(none)' }));
          state.tables[f.ref].forEach(function (x) {
            var k = x[L.KEY_COL[f.ref]];
            pick.appendChild(h('option', { value: String(k), text: rowLabel(f.ref, x) + ' #' + k }));
          });
          if (!pick.querySelector('option[value="' + v + '"]')) pick.appendChild(h('option', { value: String(v), text: 'Other' }));
          pick.value = String(v);
          rid.value = String(v);
          rc.value = String(get(f.count));
        }, w2);
        pick.addEventListener('change', function () {
          var v = Number(pick.value);
          setVal(t, row, f.col, v);
          if (v && !Number(get(f.count))) setVal(t, row, f.count, 1);
          if (!v) setVal(t, row, f.count, 0);
          r.c.refresh(); edited(t, row, f.col, r.c); edited(t, row, f.count, r.c);
        });
        rid.addEventListener('input', function () {
          if (rid.value === '') return;
          setVal(t, row, f.col, L.coerce(rid.value, 'int'));
          if (!rid.matches(':focus')) r.c.refresh();
          edited(t, row, f.col, r.c);
          var v = String(get(f.col));
          if (!pick.querySelector('option[value="' + v + '"]')) pick.appendChild(h('option', { value: v, text: 'Other' }));
          pick.value = v;
        });
        rc.addEventListener('input', function () { if (rc.value === '') return; setVal(t, row, f.count, L.coerce(rc.value, 'int')); edited(t, row, f.count, r.c); });
        return r.el;
      }
      throw new Error('unknown field kind ' + f.kind);
    }

    function rawControl(t, row, c) {
      var id = nid('raw-' + c.name), isKey = schema[t].key.indexOf(c.name) >= 0;
      var dflt = L.colDefault(c);
      var inp = c.type === 'string' ? h('input', { id: id, type: 'text', autocomplete: 'off' }) : numInput(id, c.type, null);
      if (isKey) inp.readOnly = true;
      var hint = (c.comment ? c.comment + '. ' : '') + c.type + ', default ' + (dflt === null ? 'empty' : JSON.stringify(dflt)) + (isKey ? '. Assigned by Forge.' : '');
      var el = wrapField({ label: c.name, hint: hint }, id, inp, 'raw');
      var cc = { cols: [c.name], refresh: function () { var v = L.rowVal(schema, t, row, c.name); inp.value = v === null ? '' : String(v); } };
      controls.push(cc);
      cc.refresh();
      inp.addEventListener('input', function () {
        if (isKey) return;
        if (c.type !== 'string' && (inp.value === '' || isNaN(Number(inp.value)))) return;
        var v = c.type === 'string' ? (inp.value === '' && c.null ? null : inp.value) : L.coerce(inp.value, c.type);
        setVal(t, row, c.name, v);
        edited(t, row, c.name, cc);
      });
      return el;
    }

    /* ---- addon tab */
    function renderAddon(panel) {
      var a = state.addon, name = L.addonName(state);
      var en = h('input', { type: 'checkbox', id: 'addon-on', checked: a.enabled });
      var ni = h('input', { type: 'text', id: 'addon-name', value: name, autocomplete: 'off', spellcheck: 'false', 'aria-describedby': 'addon-name-hint' });
      var code = h('textarea', { id: 'addon-code', rows: '16', spellcheck: 'false', cls: 'code', value: L.defaultAddonCode(name) });
      code.value = a.code || L.defaultAddonCode(name);
      var reset = h('button', { type: 'button', cls: 'btn', text: 'Reset to the example' });
      var body = h('div', { cls: 'addon-body' }, [
        h('div', { cls: 'grid' }, [
          h('div', { cls: 'field' }, [h('label', { 'for': 'addon-name', text: 'Addon name' }), ni,
            h('small', { id: 'addon-name-hint', cls: 'hint', text: 'Letters, digits and _. It saves its settings in ' + name + 'DB.' })]),
          h('div', { cls: 'field wide' }, [h('label', { 'for': 'addon-code', text: 'Core.lua' }), code,
            h('small', { cls: 'hint', text: 'The game runs Lua 5.0: no # operator (use table.getn), no string.gmatch (use string.gfind). Type /' + name.toLowerCase() + ' in game to try the example.' })])
        ]),
        h('div', { cls: 'row-actions' }, [reset]),
        h('ul', { cls: 'issues', id: 'row-issues', 'aria-live': 'polite' })
      ]);
      body.hidden = !a.enabled;
      en.addEventListener('change', function () { a.enabled = en.checked; body.hidden = !a.enabled; changed(); });
      ni.addEventListener('input', function () {
        var wasDefault = !a.code;
        a.name = ni.value.trim();
        a.nameEdited = a.name !== L.camelCase(state.pack.id);
        if (wasDefault) code.value = L.defaultAddonCode(L.addonName(state));
        changed();
      });
      code.addEventListener('input', function () { a.code = code.value === L.defaultAddonCode(L.addonName(state)) ? '' : code.value; changed(); });
      reset.addEventListener('click', function () { a.code = ''; code.value = L.defaultAddonCode(L.addonName(state)); changed(); });
      panel.appendChild(h('p', { cls: 'muted', text: 'An addon is a small Lua script that runs in the game\'s interface for everyone who installs your pack. Optional.' }));
      panel.appendChild(h('label', { cls: 'check big', 'for': 'addon-on' }, [en, ' Include an addon in this pack']));
      panel.appendChild(body);
      showIssues();
    }

    /* ---- validation display */
    function showIssues() {
      var issues = L.validate(state, schema);
      var packList = $('pack-issues');
      packList.textContent = '';
      var t = ui.tab, sel = ui.sel[t];
      var rowList = $('row-issues');
      if (rowList) rowList.textContent = '';
      issues.forEach(function (it) {
        var li = h('li', { cls: it.level, text: (it.level === 'error' ? 'Fix: ' : 'Note: ') + it.msg });
        if (it.table === 'pack') packList.appendChild(li);
        else if (rowList && it.table === t && (it.index === sel || it.index === -1)) rowList.appendChild(li);
        else if (rowList && t === 'addon' && it.table === 'addon') rowList.appendChild(li);
      });
      var errs = issues.filter(function (i) { return i.level === 'error'; }).length;
      var warns = issues.length - errs;
      $('summary').textContent = errs || warns
        ? (errs ? errs + ' to fix' : '') + (errs && warns ? ', ' : '') + (warns ? warns + ' note' + (warns === 1 ? '' : 's') : '')
        : 'Looks good.';
      $('summary').className = 'summary' + (errs ? ' bad' : warns ? ' warn' : '');
      return issues;
    }

    function changed() {
      save();
      updateCounts();
      showIssues();
    }

    /* ---- toolbar */
    function download() {
      if (!schema) return;
      var issues = L.validate(state, schema), errs = issues.filter(function (i) { return i.level === 'error'; });
      if (!L.slugify(state.pack.id) || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(state.pack.id)) { status('Fix the pack ID first.', true); return; }
      var bytes = L.projectZip(state, schema, new Date());
      var blob = new Blob([bytes], { type: 'application/zip' });
      var url = URL.createObjectURL(blob);
      var a = h('a', { href: url, download: state.pack.id + '.zip', cls: 'hidden-link' });
      document.body.appendChild(a);
      a.click();
      setTimeout(function () { URL.revokeObjectURL(url); a.remove(); }, 4000);
      status('Downloaded ' + state.pack.id + '.zip' + (errs.length ? '. Vanilla Forge\'s Check will ask you to fix ' + errs.length + ' thing' + (errs.length === 1 ? '' : 's') + '.' : '.'), errs.length > 0);
    }

    function openZip(file) {
      file.arrayBuffer().then(function (buf) { return L.readZip(new Uint8Array(buf)); }).then(function (files) {
        var res = L.importProject(files, schema);
        state = res.state;
        ui.sel = { item_template: 0, creature_template: 0, quest_template: 0 };
        fillPack();
        changed();
        renderPanel();
        status('Opened ' + state.pack.name + '.' + (res.skipped.length ? ' ' + res.skipped.length + ' other file(s) were left out: art, maps and other tables open in Vanilla Forge on your computer.' : ''));
      }).catch(function (e) { status('Could not open that zip: ' + e.message, true); });
    }

    function newPack() {
      var any = ['item_template', 'creature_template', 'quest_template'].some(function (t) { return state.tables[t].length; }) || state.addon.enabled;
      if (any && !window.confirm('Start a new pack? This clears the current one from this browser. Download it first if you want to keep it.')) return;
      state = L.newState();
      ui.sel = { item_template: 0, creature_template: 0, quest_template: 0 };
      fillPack();
      changed();
      renderPanel();
      status('New pack started.');
    }

    /* ---- boot */
    state = load() || L.newState();
    fillPack();
    bindPack();
    bindTabs();
    $('btn-new').addEventListener('click', newPack);
    $('btn-open').addEventListener('click', function () { $('file-open').click(); });
    $('file-open').addEventListener('change', function () { if (this.files && this.files[0]) openZip(this.files[0]); this.value = ''; });
    $('btn-download').addEventListener('click', download);
    $('btn-download').disabled = true;
    updateCounts();
    renderPanel();
    fetch('world.json').then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.json();
    }).then(function (s) {
      schema = s;
      $('btn-download').disabled = false;
      renderPanel();
      showIssues();
    }).catch(function (e) {
      status('Could not load the table list (' + e.message + '). Reload the page to try again.', true);
    });
  }
})(typeof globalThis !== 'undefined' ? globalThis : this);
