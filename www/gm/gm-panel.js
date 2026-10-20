// Open Vanilla GM panel: a Game Master window over the wenilla (browser benilla) canvas.
//
// It talks to the game only through the page's JavaScript bridge (../bridge.js, `window.wenilla`):
//   wenilla.chat('.gm on')  -> sends a dot command exactly as if typed in chat
//   wenilla.lua(chunk)      -> runs Lua in the game's UI VM and resolves to the return values
//   wenilla.on(...)         -> system messages (server replies), chat, live position/target
// So it needs no change to the game build or the server: these are static files the web backend
// already serves. Toggle with the "GM" button (top left) or Ctrl+Shift+G.
//
// Room to build: put your own tabs, quick buttons and commands in ./custom.js (examples there).

import { wenilla } from '../bridge.js';
import { CATALOG, CATALOG_SOURCE } from './catalog.js';

const VERSION = '1.0';

// ── data ──────────────────────────────────────────────────────────────────────────────────────
const LEVELS = ['Player', 'Moderator', 'Game Master', 'Administrator', 'Console'];
const LEVEL_COLORS = ['#d9d9d9', '#9fdf9f', '#ffd166', '#ff8a5c', '#8a8a8a'];

const CATEGORIES = [
  ['fav', 'Favorites'], ['all', 'All commands'], ['char', 'Character'], ['gm', 'GM mode'],
  ['travel', 'Teleport'], ['npc', 'NPCs'], ['obj', 'Objects'], ['item', 'Items & mail'],
  ['lookup', 'Lookup & info'], ['players', 'Players & bans'], ['social', 'Tickets & guilds'],
  ['server', 'Server & events'], ['reload', 'Reload tables'], ['dev', 'Debug & dev'],
  ['bots', 'Playerbots'], ['other', 'Other'],
];
const CAT_OF = {};
const cats = (key, words) => words.split(/\s+/).forEach((w) => (CAT_OF[w] = key));
cats('char', 'modify character levelup reset learn unlearn cast aura unaura cooldown maxskill setskill honor quest revive die demorph dismount explorecheat taxicheat repairitems damage combat save start waterwalk pet');
cats('gm', 'gm');
cats('travel', 'go tele goname appear namego summon groupgo recall neargrave linkgrave gps');
cats('npc', 'npc movement wp');
cats('obj', 'gobject trigger pool');
cats('item', 'additem additemset itemmove bank send stable auction');
cats('lookup', 'lookup list guid distance los showarea hidearea pinfo');
cats('players', 'kick ban unban baninfo banlist mute unmute account whispers wr');
cats('social', 'ticket tickets guild channel');
cats('server', 'server announce notify saveall respawn event wchange instance bg commands help quit loadscripts worldstate');
cats('reload', 'reload');
cats('dev', 'debug mmap pdump link testing loot');
cats('bots', 'bot rndbot ahbot');

const DEFAULT_QUICK = []; // the Dashboard has the everyday switches; custom.js can add buttons here

const DEFAULT_MACROS = [
  { name: 'GM setup', lines: '.gm on\n.gm visible off\n.gm fly on\n.modify aspeed 3', pinned: true },
  { name: 'Normal play', lines: '.gm fly off\n.modify aspeed 1\n.gm visible on\n.gm off', pinned: true },
  { name: 'Max my character', lines: '.levelup 59\n.learn all_myclass\n.maxskill\n.modify money 10000000', pinned: false },
];

const DEFAULT_SNIPPETS = [
  { name: 'Who am I', code: 'return UnitName("player"), UnitLevel("player"), GetRealZoneText()' },
  { name: 'Target info', code: 'if not UnitExists("target") then return "no target" end\nreturn UnitName("target"), UnitLevel("target"), UnitHealth("target") .. "/" .. UnitHealthMax("target")' },
  { name: 'Bag items', code: 'local out = {}\nfor bag = 0, 4 do\n  for slot = 1, GetContainerNumSlots(bag) do\n    local link = GetContainerItemLink(bag, slot)\n    if link then table.insert(out, link) end\n  end\nend\nreturn table.getn(out) .. " items", table.concat(out, ", ")' },
];

// ── storage (per browser; never required) ─────────────────────────────────────────────────────
const store = {
  get(key, fallback) {
    try {
      const v = localStorage.getItem('openvanilla.gm.' + key);
      return v == null ? fallback : JSON.parse(v);
    } catch {
      return fallback;
    }
  },
  set(key, value) {
    try {
      localStorage.setItem('openvanilla.gm.' + key, JSON.stringify(value));
    } catch {}
  },
};
const db = {
  favs: store.get('favs', {}),
  locs: store.get('locs', {}),
  history: store.get('history', []),
  macros: store.get('macros', DEFAULT_MACROS),
  snippets: store.get('snippets', DEFAULT_SNIPPETS),
  maxLevel: store.get('maxLevel', 3),
  cat: store.get('cat', 'all'),
  tab: store.get('tab2', 'home'),
  rect: store.get('rect', null),
  luaDraft: store.get('luaDraft', DEFAULT_SNIPPETS[0].code),
};
const save = (k) => store.set(k, db[k]);

// ── commands ──────────────────────────────────────────────────────────────────────────────────
const commands = [];
const byName = new Map();

/** Split a help-table syntax line into argument boxes: `.npc add #creatureid` -> [creatureid]. */
function parseArgs(name, syntax) {
  if (!syntax) return null;
  let s = syntax.trim().replace(/^\./, '');
  if (s.toLowerCase().startsWith(name.toLowerCase())) s = s.slice(name.length);
  const toks = [];
  let cur = '';
  let depth = 0;
  let quoted = false;
  for (const ch of s) {
    if (ch === '"') quoted = !quoted;
    if (!quoted && '[(<'.includes(ch)) depth++;
    if (!quoted && '])>'.includes(ch)) depth = Math.max(0, depth - 1);
    if (!quoted && depth === 0 && /\s/.test(ch)) {
      if (cur) toks.push(cur);
      cur = '';
      continue;
    }
    cur += ch;
  }
  if (cur) toks.push(cur);
  if (!toks.length) return [];
  let list = toks;
  if (list.length > 5) list = [...list.slice(0, 4), list.slice(4).join(' ')];
  return list.map((raw) => {
    const optional = /^[[<]/.test(raw);
    const label = raw.replace(/^[[(<]+/, '').replace(/[\])>]+$/, '').replace(/[#$"]/g, '').trim() || raw;
    return { label, optional, quoted: raw.includes('"') };
  });
}

function addCommand({ name, level = 0, syntax = '', desc = '', cat, args }) {
  name = String(name).trim().toLowerCase().replace(/^\./, '');
  if (!name) return null;
  let c = byName.get(name);
  if (!c) {
    c = { name, level, syntax: '', desc: '' };
    byName.set(name, c);
    commands.push(c);
  }
  c.level = level ?? c.level;
  if (syntax) c.syntax = syntax;
  if (desc) c.desc = desc;
  c.cat = cat || c.cat || CAT_OF[name.split(' ')[0]] || 'other';
  c.args = args ? args.map((a) => (typeof a === 'string' ? { label: a, optional: false } : a)) : parseArgs(name, c.syntax);
  return c;
}

for (const line of CATALOG.split('\n')) {
  if (!line.trim()) continue;
  const [name, lvl, syntax = '', desc = ''] = line.split('\t');
  addCommand({ name, level: Number(lvl) || 0, syntax, desc });
}

// ── helpers ───────────────────────────────────────────────────────────────────────────────────
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

/** WoW chat markup (|cAARRGGBB … |r colours, |H…|h[name]|h links, || escapes) to safe HTML. */
function wowToHtml(text) {
  let s = esc(text).replace(/\|\|/g, '\u0001');
  s = s.replace(/\|H[^|]*\|h(.*?)\|h/g, '<b>$1</b>');
  let open = 0;
  s = s.replace(/\|c([0-9a-fA-F]{2})([0-9a-fA-F]{6})/g, (_, _a, rgb) => {
    open++;
    return `<span style="color:#${rgb}">`;
  });
  s = s.replace(/\|r/g, () => (open > 0 ? (open--, '</span>') : ''));
  return (s + '</span>'.repeat(open)).replace(/\u0001/g, '|');
}

const fmt = (n, d = 2) => (typeof n === 'number' && isFinite(n) ? n.toFixed(d) : '?');

// ── styles ────────────────────────────────────────────────────────────────────────────────────
const CSS = `
#gmp-toggle{position:fixed;top:0;left:5.9rem;z-index:11;padding:.3rem .8rem;color:#ffd100;background:linear-gradient(180deg,#8f1a10,#4a0804);
  border:1px solid #c9a24a;border-top:0;border-radius:0 0 6px 6px;cursor:pointer;font:bold 12px "Friz Quadrata TT",Morpheus,Georgia,serif;
  text-shadow:1px 1px 0 #000;box-shadow:0 2px 6px rgba(0,0,0,.6)}
#gmp-toggle:hover,#gmp-toggle.on{color:#fff6c2;background:linear-gradient(180deg,#b0261a,#5c0a05)}
#gmp{--gold:#ffd100;--gold2:#fff1a8;--line:#3b362d;--ink:#ffffff;--dim:#a99f86;--wow:"Friz Quadrata TT",Morpheus,Georgia,"Times New Roman",serif;
  position:fixed;z-index:20;left:60px;top:48px;width:980px;height:640px;min-width:760px;min-height:460px;max-width:98vw;max-height:94vh;
  display:none;flex-direction:column;color:var(--ink);font:13px/1.35 var(--wow);
  background:
    radial-gradient(ellipse at 50% 0%,rgba(90,80,60,.18),transparent 60%),
    repeating-linear-gradient(45deg,rgba(255,255,255,.012) 0 2px,transparent 2px 5px),
    linear-gradient(180deg,#141210,#080706);
  border:3px solid #6e675b;border-radius:6px;
  box-shadow:0 0 0 1px #000,inset 0 0 0 1px #000,inset 0 0 0 2px #a59a7c,0 20px 60px rgba(0,0,0,.8);resize:both;overflow:visible}
#gmp.open{display:flex}
#gmp *{box-sizing:border-box}
#gmp .sp{flex:1}
/* WoW panel buttons: red lacquer with a gold rim */
#gmp button{font:bold 12px var(--wow);color:var(--gold);text-shadow:1px 1px 0 #000;letter-spacing:.2px;cursor:pointer;white-space:nowrap;
  padding:5px 12px;border-radius:4px;border:1px solid #c9a24a;
  background:linear-gradient(180deg,#a3241a 0%,#7a140c 45%,#4e0905 100%);
  box-shadow:inset 0 1px 0 rgba(255,200,150,.35),inset 0 -2px 3px rgba(0,0,0,.5),0 1px 2px rgba(0,0,0,.7)}
#gmp button:hover{color:#fff;background:linear-gradient(180deg,#c22f22 0%,#931a10 45%,#5e0b06 100%);box-shadow:inset 0 1px 0 rgba(255,220,170,.5),0 0 6px rgba(255,190,60,.35)}
#gmp button:active{transform:translateY(1px);background:linear-gradient(180deg,#5e0b06,#7a140c)}
#gmp button:disabled{opacity:.4;cursor:default;filter:grayscale(.6)}
#gmp button.primary{border-color:#ffe08a;box-shadow:inset 0 1px 0 rgba(255,220,170,.5),0 0 0 1px #000,0 0 8px rgba(255,200,60,.25)}
#gmp button.ghost{background:transparent;border-color:transparent;box-shadow:none;color:var(--dim);font-weight:normal}
#gmp button.ghost:hover{color:var(--gold)}
#gmp button.stone{background:linear-gradient(180deg,#3d3a35,#22201c 55%,#151412);border-color:#6e675b;color:var(--gold)}
#gmp button.stone:hover{border-color:#c9a24a;color:#fff}
#gmp input,#gmp textarea,#gmp select{font:13px system-ui,Segoe UI,sans-serif;color:#fff;background:rgba(0,0,0,.75);border:1px solid #555046;border-radius:3px;padding:5px 7px;outline:none;
  box-shadow:inset 0 1px 3px rgba(0,0,0,.9)}
#gmp input:focus,#gmp textarea:focus,#gmp select:focus{border-color:#c9a24a}
/* title plate */
#gmp .hdr{position:relative;display:flex;align-items:center;gap:10px;padding:10px 12px 8px;cursor:move;user-select:none;min-height:44px}
#gmp .plate{position:absolute;left:50%;top:-14px;transform:translateX(-50%);padding:6px 34px 7px;border:2px solid #c9a24a;border-radius:6px;
  background:linear-gradient(180deg,#2a2112,#120d06);box-shadow:0 0 0 1px #000,0 3px 8px rgba(0,0,0,.7),inset 0 1px 0 rgba(255,220,150,.25);white-space:nowrap}
#gmp .plate:before,#gmp .plate:after{content:"◆";position:absolute;top:50%;transform:translateY(-50%);color:#c9a24a;font-size:10px}
#gmp .plate:before{left:12px}#gmp .plate:after{right:12px}
#gmp .title{font:bold 16px var(--wow);color:var(--gold);letter-spacing:1px;text-shadow:1px 1px 0 #000,0 0 6px rgba(255,180,0,.25)}
#gmp .pill{font:11px system-ui,sans-serif;padding:2px 8px;border-radius:9px;border:1px solid #3d382f;color:var(--dim);background:rgba(0,0,0,.5)}
#gmp .pill.ok{color:#7dff6b;border-color:#2f5a2f}
#gmp .hdr .x{width:26px;height:26px;padding:0;border-radius:50%;font:bold 13px system-ui;line-height:1}
#gmp .quick{display:flex;flex-wrap:wrap;gap:6px;padding:0 12px 8px}
#gmp .quick:empty{display:none}
#gmp .main{flex:1;display:flex;min-height:0;margin:0 10px;border:1px solid #2c2923;border-radius:4px;background:rgba(0,0,0,.35);
  box-shadow:inset 0 0 12px rgba(0,0,0,.9)}
#gmp .view{flex:1;display:none;min-height:0;min-width:0}
#gmp .view.on{display:flex}
/* bottom tabs, like the character frame */
#gmp .tabs{display:flex;gap:3px;padding:0 14px;margin-top:-1px;position:relative;top:3px;flex-wrap:wrap}
#gmp .tabs button{border-radius:0 0 7px 7px;border-top:0;padding:6px 14px 7px;font-size:12px;color:#c9b078;
  background:linear-gradient(180deg,#151412,#2a2721 70%,#3a352c);border-color:#6e675b;box-shadow:0 3px 5px rgba(0,0,0,.7)}
#gmp .tabs button:hover{color:var(--gold)}
#gmp .tabs button.on{color:var(--gold);padding-bottom:10px;background:linear-gradient(180deg,#0d0c0a,#25221c 60%,#4a4335);border-color:#c9a24a}
/* sections ("insets") */
#gmp .pane{flex:1;overflow:auto;padding:12px 14px;display:flex;flex-direction:column;gap:10px;min-width:0}
#gmp .card,#gmp .dsec{border:1px solid #3a362e;border-radius:5px;padding:10px 12px;background:linear-gradient(180deg,rgba(255,255,255,.035),rgba(0,0,0,.35));
  box-shadow:inset 0 0 0 1px rgba(0,0,0,.6)}
#gmp .card h4,#gmp .dsec>h4{margin:0 0 8px;font:bold 14px var(--wow);color:var(--gold);text-shadow:1px 1px 0 #000;display:flex;align-items:center;gap:8px}
#gmp .card h4 small,#gmp .dsec>h4 small{font:11px system-ui,sans-serif;color:var(--dim);font-weight:normal;text-shadow:none}
#gmp .hint{font:12px system-ui,sans-serif;color:var(--dim)}
#gmp .empty{color:var(--dim);padding:24px;text-align:center}
#gmp .btns{display:flex;gap:6px;flex-wrap:wrap;align-items:center}
#gmp .kv{display:grid;grid-template-columns:90px 1fr;gap:3px 10px;font:12.5px system-ui,sans-serif}
#gmp .kv b{color:var(--gold);font-weight:normal}
#gmp table{width:100%;border-collapse:collapse;font:12.5px system-ui,sans-serif}
#gmp td,#gmp th{padding:5px 6px;border-bottom:1px solid rgba(255,255,255,.05);text-align:left}
#gmp th{color:var(--gold);font-weight:normal;font-size:11px}
#gmp td .btns{justify-content:flex-end}
#gmp td button{padding:3px 9px;font-size:11px}
/* Advanced (raw command browser) */
#gmp .cats{width:180px;border-right:1px solid #2c2923;overflow:auto;padding:6px 0}
#gmp .cats div{padding:5px 14px;cursor:pointer;color:#fff;display:flex;justify-content:space-between;font-size:13px}
#gmp .cats div span{color:var(--dim);font:11px system-ui}
#gmp .cats div:hover{background:rgba(255,209,0,.08)}
#gmp .cats div.on{background:linear-gradient(90deg,rgba(255,209,0,.22),transparent);color:var(--gold);box-shadow:inset 3px 0 0 var(--gold)}
#gmp .lvl{margin:10px 12px 4px;font-size:11px;color:var(--dim)}
#gmp .lvl select{width:100%;margin-top:3px}
#gmp .list{flex:1;display:flex;flex-direction:column;min-width:0;border-right:1px solid #2c2923}
#gmp .search{padding:8px;border-bottom:1px solid #2c2923;display:flex;gap:6px}
#gmp .search input{flex:1}
#gmp .rows{flex:1;overflow:auto}
#gmp .row{display:flex;gap:8px;align-items:baseline;padding:5px 10px;border-bottom:1px solid rgba(255,255,255,.03);cursor:pointer}
#gmp .row:hover{background:rgba(255,209,0,.07)}
#gmp .row.on{background:rgba(255,209,0,.16)}
#gmp .row .n{font:12.5px ui-monospace,Consolas,monospace;color:#fff;white-space:nowrap}
#gmp .row .d{color:var(--dim);font:12px system-ui;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1}
#gmp .row .l{font:11px system-ui;white-space:nowrap}
#gmp .star{color:var(--gold)}
#gmp .detail{width:350px;overflow:auto;padding:12px 14px;display:flex;flex-direction:column;gap:9px}
#gmp .detail h3{margin:0;font:bold 15px ui-monospace,Consolas,monospace;color:var(--gold)}
#gmp .syntax{font:12px ui-monospace,Consolas,monospace;color:#e8dcb5;background:rgba(0,0,0,.6);border:1px solid #2c2923;border-radius:3px;padding:6px 8px;word-break:break-word}
#gmp .desc{color:var(--dim);font:12.5px system-ui}
#gmp .field label{display:block;font-size:12px;color:var(--gold);margin-bottom:3px}
#gmp .field label i{color:var(--dim);font:italic 11px system-ui}
#gmp .field input,#gmp .field select{width:100%}
#gmp .preview{font:12px ui-monospace,Consolas,monospace;color:#7dff6b;word-break:break-word}
#gmp .split{display:flex;gap:10px;flex:1;min-height:0}
#gmp .side{width:230px;display:flex;flex-direction:column;gap:6px;overflow:auto}
#gmp .side .item{padding:6px 9px;border:1px solid #3a362e;border-radius:4px;cursor:pointer;display:flex;justify-content:space-between;gap:6px;background:rgba(0,0,0,.3)}
#gmp .side .item:hover{border-color:#6e675b}
#gmp .side .item.on{border-color:#c9a24a;background:rgba(255,209,0,.1);color:var(--gold)}
#gmp .editor{flex:1;display:flex;flex-direction:column;gap:6px;min-width:0}
#gmp .editor textarea{flex:1;min-height:140px;resize:none;font:12.5px/1.45 ui-monospace,Consolas,monospace;tab-size:2;white-space:pre}
/* message log (chat-frame look) */
#gmp .out{display:flex;flex-direction:column;margin:8px 10px 0;border:1px solid #2c2923;border-radius:4px;background:rgba(0,0,0,.55)}
#gmp .outhdr{display:flex;align-items:center;gap:8px;padding:2px 8px;font:11px var(--wow);color:var(--gold);border-bottom:1px solid #1d1b17}
#gmp .outhdr button{padding:1px 8px;font-size:11px}
#gmp .log{height:92px;overflow:auto;padding:4px 10px;font:12.5px/1.4 Arial,Helvetica,sans-serif;white-space:pre-wrap;word-break:break-word;text-shadow:1px 1px 0 #000}
#gmp .out.min .log{display:none}
#gmp .log .sys{color:#ffff00}
#gmp .log .sent{color:#8a8578}
#gmp .log .lua{color:#7fd4ff}
#gmp .log .res{color:#7dff6b}
#gmp .log .err{color:#ff4b3b}
#gmp .log .info{color:#ffd100}
#gmp .console{display:none;gap:6px;padding:6px 8px;border-top:1px solid #1d1b17}
#gmp .out.con .console{display:flex}
#gmp .console input{flex:1;font-family:ui-monospace,Consolas,monospace}
#gmp .console select{width:auto}
/* game-style popup (StaticPopup) */
#gmp .modal{position:absolute;inset:0;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center;z-index:5;border-radius:6px}
#gmp .popup{width:380px;max-width:92%;padding:16px 18px 14px;border:3px solid #6e675b;border-radius:6px;background:linear-gradient(180deg,#1a1814,#0a0908);
  box-shadow:0 0 0 1px #000,inset 0 0 0 1px #a59a7c,0 12px 40px rgba(0,0,0,.9);display:flex;flex-direction:column;gap:10px}
#gmp .popup h3{margin:0;text-align:center;font:bold 15px var(--wow);color:var(--gold);text-shadow:1px 1px 0 #000}
#gmp .popup p{margin:0;text-align:center;font:12.5px system-ui;color:#e6e0d0}
#gmp .popup .btns{justify-content:center;margin-top:4px}
#gmp .popup .btns button{min-width:100px}
#gmp ::-webkit-scrollbar{width:10px;height:10px}
#gmp ::-webkit-scrollbar-thumb{background:linear-gradient(90deg,#4a453b,#2c2923);border:1px solid #000;border-radius:5px}
#gmp ::-webkit-scrollbar-track{background:rgba(0,0,0,.4)}
`;

// ── DOM ───────────────────────────────────────────────────────────────────────────────────────
const style = document.createElement('style');
style.textContent = CSS;
document.head.appendChild(style);

const toggle = document.createElement('button');
toggle.id = 'gmp-toggle';
toggle.type = 'button';
toggle.textContent = '⚔ GM';
toggle.title = 'Game Master panel (Ctrl+Shift+G)';
document.body.appendChild(toggle);

const root = document.createElement('div');
root.id = 'gmp';
root.innerHTML = `
  <div class="hdr">
    <div class="plate"><span class="title">Game Master</span></div>
    <span class="pill" data-ref="status">offline</span>
    <span class="sp"></span>
    <button class="x" data-act="close" title="Close (Ctrl+Shift+G)">✕</button>
  </div>
  <div class="quick" data-ref="quick"></div>
  <div class="main">
    <div class="view" data-view="commands">
      <div class="cats" data-ref="cats"></div>
      <div class="list">
        <div class="search"><input data-ref="search" placeholder="Search ${commands.length} commands…  (name or description)"></div>
        <div class="rows" data-ref="rows"></div>
      </div>
      <div class="detail" data-ref="detail"></div>
    </div>
    <div class="view" data-view="locations"><div class="pane" data-ref="locations"></div></div>
    <div class="view" data-view="nearby"><div class="pane" data-ref="nearby"></div></div>
    <div class="view" data-view="macros"><div class="pane" data-ref="macros"></div></div>
    <div class="view" data-view="lua"><div class="pane" data-ref="lua"></div></div>
  </div>
  <div class="out" data-ref="out">
    <div class="outhdr">Messages <span class="sp"></span>
      <button class="ghost" data-act="console" title="Type commands or Lua directly">⌨ console</button>
      <button class="ghost" data-act="clear">clear</button>
      <button class="ghost" data-act="min" title="Hide / show messages">▾</button></div>
    <div class="log" data-ref="log"></div>
    <div class="console">
      <select data-ref="mode" title="GM: sends dot commands. Lua: runs in the game's Lua VM."><option value="gm">GM</option><option value="lua">Lua</option></select>
      <input data-ref="console" placeholder=".command   (↑/↓ history)" spellcheck="false" autocomplete="off">
      <button class="primary" data-act="send">Send</button>
    </div>
  </div>
  <div class="tabs" data-ref="tabs">
    <button data-tab="locations">Locations</button>
    <button data-tab="nearby">Nearby</button>
    <button data-tab="macros">Macros</button>
    <button data-tab="lua">Lua</button>
    <button data-tab="commands">Advanced</button>
  </div>
  </div>`;
document.body.appendChild(root);

const $ = (ref) => root.querySelector(`[data-ref="${ref}"]`);
const ui = Object.fromEntries(
  ['status', 'tabs', 'quick', 'cats', 'search', 'rows', 'detail', 'locations', 'nearby', 'macros', 'lua', 'log', 'mode', 'console', 'out'].map((r) => [r, $(r)]),
);

// Keys typed into the panel must not reach the game (movement keys, Enter opening chat…).
for (const ev of ['keydown', 'keyup', 'keypress']) root.addEventListener(ev, (e) => e.stopPropagation());

// ── log ───────────────────────────────────────────────────────────────────────────────────────
let lastSys = { text: '', t: 0 };
function log(text, cls = 'sys', html = false) {
  const atBottom = ui.log.scrollTop + ui.log.clientHeight >= ui.log.scrollHeight - 4;
  const div = document.createElement('div');
  div.className = cls;
  if (html) div.innerHTML = text;
  else div.textContent = text;
  ui.log.appendChild(div);
  while (ui.log.childElementCount > 800) ui.log.firstElementChild.remove();
  if (atBottom) ui.log.scrollTop = ui.log.scrollHeight;
}
function systemMessage(text) {
  if (!text) return;
  const now = performance.now();
  if (text === lastSys.text && now - lastSys.t < 250) return; // same line via two routes
  lastSys = { text, t: now };
  let swallowed = false;
  for (const cap of captures) {
    try {
      if (cap(text)) swallowed = true;
    } catch (e) {
      console.error(e);
    }
  }
  if (!swallowed) log(wowToHtml(text), 'sys', true);
  for (const cb of systemListeners) {
    try {
      cb(text);
    } catch (e) {
      console.error(e);
    }
  }
}
const systemListeners = new Set();
const captures = new Set(); // handlers that may claim a system line (return true) so it skips Messages
wenilla.on('CHAT_MSG_SYSTEM', (args) => systemMessage(Array.isArray(args) ? args[0] : args));
wenilla.on('chat', (c) => {
  if (c && /SYSTEM/i.test(String(c.kind))) systemMessage(c.text);
});
wenilla.on('error', (e) => log('bridge: ' + JSON.stringify(e), 'err'));

// ── sending ───────────────────────────────────────────────────────────────────────────────────
function send(cmd) {
  cmd = String(cmd ?? '').trim();
  if (!cmd) return;
  if (!cmd.startsWith('.') && !cmd.startsWith('/')) cmd = '.' + cmd;
  // The command text only shows when you're working with commands (console open or Advanced tab).
  if (ui.out.classList.contains('con') || db.tab === 'commands') log('> ' + cmd, 'sent');
  if (!wenilla.state?.self) log('(not in the world yet: the command is queued for when you are)', 'info');
  wenilla.chat(cmd);
  if (db.history[db.history.length - 1] !== cmd) db.history.push(cmd);
  if (db.history.length > 100) db.history.splice(0, db.history.length - 100);
  save('history');
  histPos = null;
}

async function runLua(code, { expression = false } = {}) {
  code = String(code ?? '').trim();
  if (!code) return;
  log('lua> ' + code.replace(/\n/g, '\n     '), 'lua');
  try {
    let values;
    if (expression && !/^\s*(local|for|while|if|return|function|repeat)\b/.test(code) && !code.includes('\n')) {
      try {
        values = await wenilla.lua('return ' + code);
      } catch (e) {
        if (!/expected|unexpected|syntax|near/i.test(e.message)) throw e;
        values = await wenilla.lua(code);
      }
    } else {
      values = await wenilla.lua(code);
    }
    const shown = (values ?? []).map((v) => (typeof v === 'string' ? v : JSON.stringify(v)));
    log(shown.length ? shown.join(', ') : '(ok, no values)', 'res');
    return values;
  } catch (e) {
    log(String(e.message || e), 'err');
  }
}

function runMacro(m) {
  const lines = m.lines.split('\n').map((l) => l.trim()).filter((l) => l && !l.startsWith('#') && !l.startsWith('--'));
  lines.forEach((line, i) => setTimeout(() => send(line), i * 350));
}

// ── quick bar ─────────────────────────────────────────────────────────────────────────────────
const quick = [...DEFAULT_QUICK];
function renderQuick() {
  ui.quick.innerHTML = '';
  for (const [label, cmd] of quick) {
    const b = document.createElement('button');
    b.textContent = label;
    b.onclick = () => send(cmd);
    ui.quick.appendChild(b);
  }
  for (const m of db.macros.filter((x) => x.pinned)) {
    const b = document.createElement('button');
    b.className = 'macro';
    b.textContent = '▶ ' + m.name;
    b.title = 'Run macro: ' + m.name;
    b.onclick = () => runMacro(m);
    ui.quick.appendChild(b);
  }
}

// ── tabs ──────────────────────────────────────────────────────────────────────────────────────
const tabRenderers = {};
function selectTab(tab) {
  if (!root.querySelector(`[data-view="${tab}"]`)) tab = root.querySelector('.view')?.dataset.view || 'commands';
  db.tab = tab;
  store.set('tab2', tab);
  for (const b of ui.tabs.querySelectorAll('button')) b.classList.toggle('on', b.dataset.tab === tab);
  for (const v of root.querySelectorAll('.view')) v.classList.toggle('on', v.dataset.view === tab);
  tabRenderers[tab]?.();
}
ui.tabs.addEventListener('click', (e) => {
  const t = e.target.closest('button')?.dataset.tab;
  if (t) selectTab(t);
});

// ── commands tab ──────────────────────────────────────────────────────────────────────────────
let selected = null;
function visibleCommands() {
  const q = ui.search.value.trim().toLowerCase();
  return commands
    .filter((c) => c.level <= db.maxLevel)
    .filter((c) => {
      if (q) return c.name.includes(q) || c.desc.toLowerCase().includes(q);
      if (db.cat === 'fav') return db.favs[c.name];
      if (db.cat === 'all') return true;
      return c.cat === db.cat;
    })
    .sort((a, b) => a.name.localeCompare(b.name));
}
function renderCats() {
  const counts = {};
  for (const c of commands) if (c.level <= db.maxLevel) counts[c.cat] = (counts[c.cat] || 0) + 1;
  counts.all = commands.filter((c) => c.level <= db.maxLevel).length;
  counts.fav = Object.keys(db.favs).length;
  ui.cats.innerHTML =
    CATEGORIES.filter(([k]) => k === 'fav' || k === 'all' || counts[k])
      .map(([k, label]) => `<div data-cat="${k}" class="${db.cat === k ? 'on' : ''}">${esc(label)}<span>${counts[k] || 0}</span></div>`)
      .join('') +
    `<div class="lvl" style="cursor:default">Show commands up to<select data-ref="lvlsel">${LEVELS.map(
      (l, i) => `<option value="${i}" ${i === db.maxLevel ? 'selected' : ''}>${i} · ${l}</option>`,
    ).join('')}</select></div>`;
  ui.cats.querySelector('select').onchange = (e) => {
    db.maxLevel = Number(e.target.value);
    save('maxLevel');
    renderCats();
    renderRows();
  };
}
ui.cats.addEventListener('click', (e) => {
  const k = e.target.closest('[data-cat]')?.dataset.cat;
  if (!k) return;
  db.cat = k;
  save('cat');
  ui.search.value = '';
  renderCats();
  renderRows();
});
function renderRows() {
  const list = visibleCommands();
  if (!list.length) {
    ui.rows.innerHTML = `<div class="empty">${db.cat === 'fav' && !ui.search.value ? 'No favorites yet: pick a command and press ☆ Favorite.' : 'No commands match.'}</div>`;
    return;
  }
  ui.rows.innerHTML = list
    .map(
      (c) => `<div class="row ${selected === c ? 'on' : ''}" data-cmd="${esc(c.name)}">
        <span class="n">${db.favs[c.name] ? '<span class="star">★</span> ' : ''}.${esc(c.name)}</span>
        <span class="d">${esc(c.desc)}</span>
        <span class="l" style="color:${LEVEL_COLORS[c.level]}">${LEVELS[c.level]}</span></div>`,
    )
    .join('');
}
ui.rows.addEventListener('click', (e) => {
  const n = e.target.closest('[data-cmd]')?.dataset.cmd;
  if (n) selectCommand(byName.get(n));
});
ui.rows.addEventListener('dblclick', (e) => {
  const n = e.target.closest('[data-cmd]')?.dataset.cmd;
  if (n) {
    selectCommand(byName.get(n));
    runSelected();
  }
});
ui.search.addEventListener('input', renderRows);

function buildCommand() {
  if (!selected) return '';
  const parts = ['.' + selected.name];
  ui.detail.querySelectorAll('input[data-arg]').forEach((inp, i) => {
    let v = inp.value.trim();
    if (!v) return;
    const a = selected.args?.[i];
    if (a?.quoted && /\s/.test(v) && !v.startsWith('"')) v = `"${v}"`;
    parts.push(v);
  });
  return parts.join(' ');
}
function updatePreview() {
  const p = ui.detail.querySelector('.preview');
  if (p) p.textContent = buildCommand();
}
function runSelected() {
  const cmd = buildCommand();
  if (cmd) send(cmd);
}
function selectCommand(c) {
  selected = c;
  if (!c) {
    ui.detail.innerHTML = `<div class="empty">Pick a command on the left.<br><br>Fill in the boxes and press <b>Run</b>, or double-click a command to run it as is.</div>`;
    return;
  }
  const args = c.args && c.args.length ? c.args : c.syntax ? [] : [{ label: 'arguments', optional: true }];
  ui.detail.innerHTML = `
    <h3>.${esc(c.name)}</h3>
    <div style="font-size:11px;color:${LEVEL_COLORS[c.level]}">${LEVELS[c.level]} (level ${c.level})${c.level === 4 ? ' · server console only' : ''}</div>
    ${c.syntax ? `<div class="syntax">${esc(c.syntax)}</div>` : ''}
    ${c.desc ? `<div class="desc">${esc(c.desc)}</div>` : '<div class="desc">No help text in the database: press <b>Server help</b>.</div>'}
    ${args
      .map(
        (a, i) => `<div class="field"><label>${esc(a.label)} ${a.optional ? '<i>(optional)</i>' : ''}</label>
          <input data-arg="${i}" spellcheck="false" autocomplete="off"></div>`,
      )
      .join('')}
    <div class="preview"></div>
    <div class="btns">
      <button class="primary" data-act="run">Run</button>
      <button data-act="target" title="Put your target's name in the first box">Target ⇢</button>
      <button data-act="help" title="Ask your server for this command's help (.help)">Server help</button>
      <button data-act="fav">${db.favs[c.name] ? '★ Unfavorite' : '☆ Favorite'}</button>
    </div>`;
  ui.detail.querySelectorAll('input[data-arg]').forEach((inp) => {
    inp.addEventListener('input', updatePreview);
    inp.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') runSelected();
    });
  });
  updatePreview();
  renderRows();
}
ui.detail.addEventListener('click', (e) => {
  const act = e.target.closest('[data-act]')?.dataset.act;
  if (!act || !selected) return;
  if (act === 'run') runSelected();
  if (act === 'help') send('.help ' + selected.name);
  if (act === 'target') {
    const name = wenilla.state?.target?.name;
    const first = ui.detail.querySelector('input[data-arg]');
    if (name && first) {
      first.value = name;
      updatePreview();
    } else log('No target selected.', 'info');
  }
  if (act === 'fav') {
    if (db.favs[selected.name]) delete db.favs[selected.name];
    else db.favs[selected.name] = true;
    save('favs');
    renderCats();
    selectCommand(selected);
  }
});
tabRenderers.commands = () => {
  renderCats();
  renderRows();
  if (!selected) selectCommand(null);
};

// ── locations tab ─────────────────────────────────────────────────────────────────────────────
function here() {
  const s = wenilla.state;
  if (!s?.self?.pos) return null;
  const [x, y, z] = s.self.pos;
  return { map: s.map?.id ?? 0, x, y, z, o: s.self.facing ?? 0, zone: s.zone?.name || '', subzone: s.zone?.subzone || '' };
}
function goCommand(l) {
  return `.go xyz ${fmt(l.x, 3)} ${fmt(l.y, 3)} ${fmt(l.z, 3)} ${l.map}`;
}
function renderLocations() {
  const h = here();
  const names = Object.keys(db.locs).sort((a, b) => a.localeCompare(b));
  ui.locations.innerHTML = `
    <div class="card"><h4>You are here</h4>${
      h
        ? `<div class="kv"><b>Zone</b><span>${esc(h.zone || '?')}${h.subzone ? ' · ' + esc(h.subzone) : ''}</span>
           <b>Map</b><span>${h.map}</span><b>Position</b><span>${fmt(h.x)}, ${fmt(h.y)}, ${fmt(h.z)}</span>
           <b>Facing</b><span>${fmt(h.o)}</span></div>`
        : '<div class="hint">Not in the world yet.</div>'
    }
      <div class="btns" style="margin-top:8px">
        <input data-ref="locname" placeholder="Name this spot" style="flex:1">
        <button class="primary" data-act="saveloc">Save location</button>
        <button class="stone" data-act="copygo" title="Copy this spot's coordinates">Copy coords</button>
      </div></div>
    <div class="card"><h4>Famous places <small>the server's teleport list</small></h4>
      <div class="btns"><input data-ref="teleq" placeholder="e.g. stormwind, ironforge, gmisland" style="flex:1">
        <button class="stone" data-act="telelookup">Search</button><button class="primary" data-act="tele">Teleport</button></div>
      <div class="hint" style="margin-top:6px">Search lists matching places in Messages below; type the exact name and press Teleport.</div></div>
    <div class="card"><h4>Saved locations (${names.length})</h4>${
      names.length
        ? `<table><tr><th>Name</th><th>Zone</th><th>Map</th><th>Position</th><th></th></tr>${names
            .map((n) => {
              const l = db.locs[n];
              return `<tr><td>${esc(n)}</td><td>${esc(l.zone || '')}</td><td>${l.map}</td><td>${fmt(l.x, 1)}, ${fmt(l.y, 1)}, ${fmt(l.z, 1)}</td>
                <td><div class="btns"><button class="primary" data-go="${esc(n)}">Go</button><button data-del="${esc(n)}">Delete</button></div></td></tr>`;
            })
            .join('')}</table>`
        : '<div class="hint">Nothing saved yet. Stand somewhere, name it, press Save location.</div>'
    }</div>`;
}
ui.locations.addEventListener('click', (e) => {
  const t = e.target.closest('button');
  if (!t) return;
  const val = (ref) => ui.locations.querySelector(`[data-ref="${ref}"]`)?.value.trim() || '';
  if (t.dataset.act === 'saveloc') {
    const h = here();
    const name = val('locname');
    if (!h) return log('Not in the world yet.', 'info');
    if (!name) return log('Type a name for the location first.', 'info');
    db.locs[name] = h;
    save('locs');
    log(`Saved location "${name}".`, 'res');
    renderLocations();
  }
  if (t.dataset.act === 'copygo') {
    const h = here();
    if (h) navigator.clipboard?.writeText(goCommand(h)).then(() => log('Copied: ' + goCommand(h), 'res'), () => log(goCommand(h), 'res'));
  }
  if (t.dataset.act === 'telelookup') send('.lookup tele ' + val('teleq'));
  if (t.dataset.act === 'tele' && val('teleq')) send('.tele ' + val('teleq'));
  if (t.dataset.go) send(goCommand(db.locs[t.dataset.go]));
  if (t.dataset.del) {
    delete db.locs[t.dataset.del];
    save('locs');
    renderLocations();
  }
});
tabRenderers.locations = renderLocations;

// ── nearby tab ────────────────────────────────────────────────────────────────────────────────
function renderNearby() {
  const s = wenilla.state;
  const units = s?.units || [];
  const t = s?.target;
  ui.nearby.innerHTML = `
    <div class="card"><h4>Target</h4>${
      t
        ? `<div class="kv"><b>Name</b><span>${esc(t.name ?? t.guid)}</span><b>Level</b><span>${t.level ?? '?'}</span>
           <b>Health</b><span>${t.health ?? '?'} / ${t.maxHealth ?? '?'}</span><b>Distance</b><span>${fmt(t.dist, 1)} yd</span>
           <b>Stance</b><span>${t.hostile ? 'hostile' : t.friendly ? 'friendly' : 'neutral'}</span><b>GUID</b><span>${esc(t.guid ?? '')}</span></div>
           <div class="btns" style="margin-top:8px">
             <button data-cmd=".npc info">NPC info</button><button data-cmd=".gps">Position</button><button data-cmd=".revive">Revive</button>
             <button data-cmd=".die">Kill</button><button data-cmd=".npc follow">Follow me</button><button data-cmd=".npc unfollow">Stop following</button>
             <button data-cmd=".npc delete">Delete spawn</button></div>`
        : '<div class="hint">No target. Click a unit in the game, or use Target below.</div>'
    }</div>
    <div class="card"><h4>Nearby (${units.length})</h4>${
      units.length
        ? `<table><tr><th></th><th>Name</th><th>Lvl</th><th>Dist</th><th>HP</th><th></th></tr>${units
            .slice(0, 40)
            .map(
              (u) => `<tr><td>${u.isPlayer ? '👤' : u.hostile ? '⚔' : '·'}</td><td>${esc(u.name ?? u.kind ?? u.guid)}</td><td>${u.level ?? ''}</td>
                <td>${fmt(u.dist, 0)}yd</td><td>${u.dead ? '☠' : `${u.health ?? '?'}/${u.maxHealth ?? '?'}`}</td>
                <td><div class="btns">${u.name ? `<button data-target="${esc(u.name)}">Target</button>` : ''}${
                  u.isPlayer && u.name
                    ? `<button data-cmd=".goname ${esc(u.name)}">Go to</button><button data-cmd=".namego ${esc(u.name)}">Summon</button>`
                    : ''
                }</div></td></tr>`,
            )
            .join('')}</table>`
        : '<div class="hint">Nobody in range (or not in the world yet).</div>'
    }</div>`;
}
ui.nearby.addEventListener('click', (e) => {
  const b = e.target.closest('button');
  if (!b) return;
  if (b.dataset.cmd) send(b.dataset.cmd);
  if (b.dataset.target) {
    wenilla.chat('/target ' + b.dataset.target);
    log('> /target ' + b.dataset.target, 'sent');
  }
});
tabRenderers.nearby = renderNearby;

// ── macros tab ────────────────────────────────────────────────────────────────────────────────
let macroSel = 0;
function renderMacros() {
  const m = db.macros[macroSel];
  ui.macros.innerHTML = `
    <div class="split">
      <div class="side">
        ${db.macros.map((x, i) => `<div class="item ${i === macroSel ? 'on' : ''}" data-i="${i}"><span>${esc(x.name)}</span>${x.pinned ? '<span class="star">📌</span>' : ''}</div>`).join('')}
        <button data-act="new">+ New macro</button>
      </div>
      <div class="editor">${
        m
          ? `<input data-ref="mname" value="${esc(m.name)}">
             <textarea data-ref="mlines" spellcheck="false">${esc(m.lines)}</textarea>
             <div class="hint">One command per line: dot commands (.gm on) or slash commands (/say hi). Lines starting with # are skipped. Runs top to bottom, 0.35 s apart.</div>
             <div class="btns"><button class="primary" data-act="run">▶ Run</button><button data-act="save">Save</button>
               <button data-act="pin">${m.pinned ? 'Unpin from' : 'Pin to'} quick bar</button><span class="sp"></span><button data-act="del">Delete</button></div>`
          : '<div class="empty">No macros.</div>'
      }</div>
    </div>`;
}
function readMacro() {
  const m = db.macros[macroSel];
  if (!m) return null;
  m.name = ui.macros.querySelector('[data-ref="mname"]').value.trim() || 'Macro';
  m.lines = ui.macros.querySelector('[data-ref="mlines"]').value;
  return m;
}
ui.macros.addEventListener('click', (e) => {
  const item = e.target.closest('[data-i]');
  if (item) {
    readMacro();
    macroSel = Number(item.dataset.i);
    return renderMacros();
  }
  const act = e.target.closest('[data-act]')?.dataset.act;
  if (!act) return;
  if (act === 'new') {
    readMacro();
    db.macros.push({ name: 'New macro', lines: '.gm on\n', pinned: false });
    macroSel = db.macros.length - 1;
  }
  const m = act === 'new' ? null : readMacro();
  if (act === 'run' && m) runMacro(m);
  if (act === 'pin' && m) m.pinned = !m.pinned;
  if (act === 'del' && m) {
    db.macros.splice(macroSel, 1);
    macroSel = Math.max(0, macroSel - 1);
  }
  save('macros');
  renderQuick();
  renderMacros();
});
tabRenderers.macros = renderMacros;

// ── Lua IDE tab ───────────────────────────────────────────────────────────────────────────────
let snipSel = -1;
function renderLua() {
  ui.lua.innerHTML = `
    <div class="split">
      <div class="side">
        <div class="hint">Snippets</div>
        ${db.snippets.map((x, i) => `<div class="item ${i === snipSel ? 'on' : ''}" data-i="${i}"><span>${esc(x.name)}</span></div>`).join('')}
      </div>
      <div class="editor">
        <textarea data-ref="code" spellcheck="false" placeholder="-- Lua 5.0 with the 1.12 UI API. return values are printed below.">${esc(db.luaDraft)}</textarea>
        <div class="hint">Runs inside the game client's Lua VM (the same API addons use: UnitName, GetContainerItemLink, CastSpellByName, SendChatMessage, CreateFrame…). <b>Ctrl+Enter</b> runs. Use <b>return</b> to print values.</div>
        <div class="btns"><button class="primary" data-act="run">▶ Run (Ctrl+Enter)</button>
          <input data-ref="sname" placeholder="snippet name" style="width:160px"><button data-act="save">Save snippet</button>
          <span class="sp"></span><button data-act="del" ${snipSel < 0 ? 'disabled' : ''}>Delete snippet</button></div>
      </div>
    </div>`;
  const ta = ui.lua.querySelector('[data-ref="code"]');
  ta.addEventListener('input', () => {
    db.luaDraft = ta.value;
    save('luaDraft');
  });
  ta.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      runLua(ta.value);
    } else if (e.key === 'Tab') {
      e.preventDefault();
      const { selectionStart: a, selectionEnd: b } = ta;
      ta.value = ta.value.slice(0, a) + '  ' + ta.value.slice(b);
      ta.selectionStart = ta.selectionEnd = a + 2;
    }
  });
}
ui.lua.addEventListener('click', (e) => {
  const item = e.target.closest('[data-i]');
  if (item) {
    snipSel = Number(item.dataset.i);
    db.luaDraft = db.snippets[snipSel].code;
    save('luaDraft');
    renderLua();
    ui.lua.querySelector('[data-ref="sname"]').value = db.snippets[snipSel].name;
    return;
  }
  const act = e.target.closest('[data-act]')?.dataset.act;
  const code = ui.lua.querySelector('[data-ref="code"]')?.value ?? '';
  if (act === 'run') runLua(code);
  if (act === 'save') {
    const name = ui.lua.querySelector('[data-ref="sname"]').value.trim() || 'Snippet ' + (db.snippets.length + 1);
    const i = db.snippets.findIndex((s) => s.name === name);
    if (i >= 0) db.snippets[i].code = code;
    else db.snippets.push({ name, code });
    snipSel = i >= 0 ? i : db.snippets.length - 1;
    save('snippets');
    renderLua();
    ui.lua.querySelector('[data-ref="sname"]').value = name;
  }
  if (act === 'del' && snipSel >= 0) {
    db.snippets.splice(snipSel, 1);
    snipSel = -1;
    save('snippets');
    renderLua();
  }
});
tabRenderers.lua = renderLua;

// ── console ───────────────────────────────────────────────────────────────────────────────────
let histPos = null;
function submitConsole() {
  const v = ui.console.value;
  ui.console.value = '';
  if (ui.mode.value === 'lua') runLua(v, { expression: true });
  else send(v);
}
ui.console.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') submitConsole();
  else if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
    const h = db.history;
    if (!h.length) return;
    e.preventDefault();
    histPos = histPos == null ? h.length : histPos;
    histPos = Math.max(0, Math.min(h.length, histPos + (e.key === 'ArrowUp' ? -1 : 1)));
    ui.console.value = h[histPos] ?? '';
  }
});
ui.mode.addEventListener('change', () => {
  ui.console.placeholder = ui.mode.value === 'lua' ? 'Lua expression or statement, e.g. GetRealZoneText()' : '.command   (↑/↓ history)';
});

root.addEventListener('click', (e) => {
  const act = e.target.closest('[data-act]')?.dataset.act;
  if (act === 'close') setOpen(false);
  if (act === 'clear') ui.log.innerHTML = '';
  if (act === 'send') submitConsole();
  if (act === 'console') {
    ui.out.classList.toggle('con');
    ui.out.classList.remove('min');
    if (ui.out.classList.contains('con')) ui.console.focus();
  }
  if (act === 'min') ui.out.classList.toggle('min');
});

// ── window: open/close, drag, size ────────────────────────────────────────────────────────────
function setOpen(open) {
  root.classList.toggle('open', open);
  toggle.classList.toggle('on', open);
  if (open) selectTab(db.tab);
}
toggle.addEventListener('click', () => setOpen(!root.classList.contains('open')));
window.addEventListener(
  'keydown',
  (e) => {
    if (e.ctrlKey && e.shiftKey && (e.key === 'G' || e.key === 'g')) {
      e.preventDefault();
      e.stopPropagation();
      setOpen(!root.classList.contains('open'));
    }
  },
  true,
);
function applyRect() {
  const r = db.rect;
  if (!r) return;
  root.style.left = Math.max(0, Math.min(window.innerWidth - 120, r.left)) + 'px';
  root.style.top = Math.max(0, Math.min(window.innerHeight - 60, r.top)) + 'px';
  if (r.width) root.style.width = r.width + 'px';
  if (r.height) root.style.height = r.height + 'px';
}
function saveRect() {
  const b = root.getBoundingClientRect();
  db.rect = { left: b.left, top: b.top, width: b.width, height: b.height };
  save('rect');
}
applyRect();
root.querySelector('.hdr').addEventListener('pointerdown', (e) => {
  if (e.target.closest('button,input,select')) return;
  const b = root.getBoundingClientRect();
  const dx = e.clientX - b.left;
  const dy = e.clientY - b.top;
  const move = (ev) => {
    root.style.left = Math.max(0, Math.min(window.innerWidth - 120, ev.clientX - dx)) + 'px';
    root.style.top = Math.max(0, Math.min(window.innerHeight - 40, ev.clientY - dy)) + 'px';
  };
  const up = () => {
    window.removeEventListener('pointermove', move);
    window.removeEventListener('pointerup', up);
    saveRect();
  };
  window.addEventListener('pointermove', move);
  window.addEventListener('pointerup', up);
});
new ResizeObserver(() => root.classList.contains('open') && saveRect()).observe(root);

// ── live refresh (status pill, Locations / Nearby while visible) ──────────────────────────────
let lastRefresh = 0;
wenilla.on('frame', (s) => {
  const now = performance.now();
  if (now - lastRefresh < 500) return;
  lastRefresh = now;
  const st = s?.session;
  const inWorld = !!s?.self;
  ui.status.textContent = inWorld ? `${s.self.name ?? 'in world'} · L${s.self.level ?? '?'}` : st ? `${st.state}${st.connected ? '' : ' (offline)'}` : 'offline';
  ui.status.classList.toggle('ok', inWorld);
  if (!root.classList.contains('open')) return;
  const focused = root.contains(document.activeElement) && /INPUT|TEXTAREA|SELECT/.test(document.activeElement.tagName);
  if (db.tab === 'nearby' && !focused) renderNearby();
  if (db.tab === 'locations' && !focused) renderLocations();
});

// ── game-style popup ─────────────────────────────────────────────────────────────────────────
/**
 * prompt({title, text, fields:[{key,label,value,placeholder,type,options}], ok}) -> Promise<values|null>.
 * A StaticPopup-like dialog inside the panel; Enter accepts, Esc cancels.
 */
function prompt({ title = '', text = '', fields = [], ok = 'Accept' } = {}) {
  return new Promise((resolve) => {
    const m = document.createElement('div');
    m.className = 'modal';
    m.innerHTML = `<div class="popup"><h3>${esc(title)}</h3>${text ? `<p>${esc(text)}</p>` : ''}
      ${fields
        .map(
          (f, i) => `<div class="field"><label>${esc(f.label)}${f.optional ? ' <i>(optional)</i>' : ''}</label>${
            f.options
              ? `<select data-i="${i}">${f.options.map((o) => `<option value="${esc(o[0] ?? o)}" ${String(o[0] ?? o) === String(f.value) ? 'selected' : ''}>${esc(o[1] ?? o)}</option>`).join('')}</select>`
              : `<input data-i="${i}" type="${f.type || 'text'}" value="${esc(f.value ?? '')}" placeholder="${esc(f.placeholder ?? '')}" spellcheck="false" autocomplete="off">`
          }</div>`,
        )
        .join('')}
      <div class="btns"><button class="primary" data-ok>${esc(ok)}</button><button class="stone" data-cancel>Cancel</button></div></div>`;
    root.appendChild(m);
    const done = (v) => {
      m.remove();
      resolve(v);
    };
    const values = () => {
      const out = {};
      m.querySelectorAll('[data-i]').forEach((el) => (out[fields[Number(el.dataset.i)].key] = el.value.trim()));
      return out;
    };
    m.addEventListener('click', (e) => {
      if (e.target.closest('[data-ok]')) done(values());
      else if (e.target.closest('[data-cancel]') || e.target === m) done(null);
    });
    m.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') done(values());
      if (e.key === 'Escape') done(null);
    });
    (m.querySelector('input,select') || m.querySelector('[data-ok]')).focus();
  });
}

// ── public API + custom.js ────────────────────────────────────────────────────────────────────
const api = {
  version: VERSION,
  wenilla,
  send,
  lua: runLua,
  log: (text, cls = 'info') => log(String(text), cls),
  open: () => setOpen(true),
  close: () => setOpen(false),
  /** capture(fn): fn(text) returns true to claim a server line (it then skips Messages). Returns stop(). */
  capture(fn) {
    captures.add(fn);
    return () => captures.delete(fn);
  },
  onSystemMessage(cb) {
    systemListeners.add(cb);
    return () => systemListeners.delete(cb);
  },
  /** addQuick('Label', '.command') — a button on the quick bar. */
  addQuick(label, cmd) {
    quick.push([label, cmd]);
    renderQuick();
  },
  clearQuick() {
    quick.length = 0;
    renderQuick();
  },
  /** addCommand({name, level, syntax, desc, cat, args}) — args: ['label', …] or auto from syntax. */
  addCommand(def) {
    const c = addCommand(def);
    if (root.classList.contains('open') && db.tab === 'commands') {
      renderCats();
      renderRows();
    }
    return c;
  },
  /** addTab('id', 'Label', (el, api) => { … render into el … }) — called each time the tab opens. */
  addTab(id, label, render, { first = false, once = false } = {}) {
    const b = document.createElement('button');
    b.dataset.tab = id;
    b.textContent = label;
    const view = document.createElement('div');
    view.className = 'view';
    view.dataset.view = id;
    view.innerHTML = '<div class="pane"></div>';
    if (first) {
      ui.tabs.prepend(b);
      root.querySelector('.main').prepend(view);
    } else {
      ui.tabs.appendChild(b);
      root.querySelector('.main').appendChild(view);
    }
    let rendered = false;
    tabRenderers[id] = () => {
      if (once && rendered) return;
      rendered = true;
      render(view.firstElementChild, api);
    };
    if (root.classList.contains('open') && db.tab === id) selectTab(id);
  },
  /** The panel's per-browser storage: get(key, fallback) / set(key, value). */
  store,
  esc,
  wowToHtml,
  here,
  goCommand,
  /** Save the current position under a name (shows in Locations). */
  saveLocation(name) {
    const h = here();
    if (!h) return log('Not in the world yet.', 'info'), false;
    db.locs[name] = h;
    save('locs');
    log(`Saved location "${name}".`, 'res');
    return true;
  },
  isOpen: () => root.classList.contains('open'),
  prompt,
  /** Your current target from the bridge snapshot (with isPlayer), or null. */
  target() {
    const s = wenilla.state;
    const t = s?.target;
    if (!t) return null;
    const unit = s.units?.find((u) => u.guid === t.guid);
    return { ...t, isPlayer: !!(t.isPlayer ?? unit?.isPlayer) };
  },
  selectTab: (id) => selectTab(id),
  currentTab: () => db.tab,
  /** Add CSS (scoped under #gmp by convention). */
  css(text) {
    const st = document.createElement('style');
    st.textContent = text;
    document.head.appendChild(st);
  },
  commands,
};
window.gm = api;

renderQuick();
log(`Game Master panel ready (${CATALOG_SOURCE}). Server replies appear here.`, 'info');

// Built-in extra tabs, then the user's custom.js. Each is optional: one failing never stops the rest.
// ?v=… on this module's own URL (game.html adds it) is passed on, so a page refresh always gets
// the current version of every part instead of a stale browser-cached copy.
const V = new URL(import.meta.url).search;
for (const mod of ['./database.js', './armory.js', './tools.js', './dashboard.js']) {
  try {
    (await import(mod + V)).default?.(api);
  } catch (e) {
    console.warn('gm/' + mod.slice(2) + ':', e);
  }
}
import('./custom.js' + V)
  .then((m) => m.default?.(api))
  .catch((e) => {
    if (!/Failed to fetch|404|Cannot find|error loading/i.test(String(e))) console.warn('gm/custom.js:', e);
  });
