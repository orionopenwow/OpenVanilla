// armory.js: "Ultimate GM Suite", an AtlasLoot-style item browser in its own game-style window.
// Every item in the server's database (gm/data/items.json, made by gen_items.py) as a bag-style
// icon grid with the game's own icons (BLP decoded in the browser), quality borders, full tooltips,
// slot/class/armor/quality filters, infinite scroll, and one-click giving:
//   Left-click  give the item (Amount)            Right-click  give its whole set
//   Shift-click try it on in the game's Dressing Room   Ctrl-click   link it in chat
const { iconNames, iconUrl, itemSets, spellText } = await import('./wowdata.js' + new URL(import.meta.url).search);

const QUALITY = ['#9d9d9d', '#ffffff', '#1eff00', '#0070dd', '#a335ee', '#ff8000', '#e6cc80'];
const QUALITY_NAME = ['Poor', 'Common', 'Uncommon', 'Rare', 'Epic', 'Legendary', 'Artifact'];
const CLASSES = [['all', 'All'], [1, 'Warrior'], [2, 'Paladin'], [4, 'Hunter'], [8, 'Rogue'], [16, 'Priest'], [64, 'Shaman'], [128, 'Mage'], [256, 'Warlock'], [1024, 'Druid']];
const CLASS_ARMOR = { 1: [1, 2, 3, 4, 6], 2: [1, 2, 3, 4, 6], 4: [1, 2, 3], 64: [1, 2, 3, 6], 8: [1, 2], 1024: [1, 2], 16: [1], 128: [1], 256: [1] };
const ARMOR = [['all', 'All'], [1, 'Cloth'], [2, 'Leather'], [3, 'Mail'], [4, 'Plate']];
const INV_NAME = { 1: 'Head', 2: 'Neck', 3: 'Shoulder', 4: 'Shirt', 5: 'Chest', 6: 'Waist', 7: 'Legs', 8: 'Feet', 9: 'Wrist', 10: 'Hands', 11: 'Finger', 12: 'Trinket', 13: 'One-Hand', 14: 'Off Hand', 15: 'Ranged', 16: 'Back', 17: 'Two-Hand', 18: 'Bag', 19: 'Tabard', 20: 'Chest', 21: 'Main Hand', 22: 'Off Hand', 23: 'Held In Off-hand', 24: 'Projectile', 25: 'Thrown', 26: 'Ranged', 27: 'Quiver', 28: 'Relic' };
const ARMOR_SUB = { 1: 'Cloth', 2: 'Leather', 3: 'Mail', 4: 'Plate', 6: 'Shield', 7: 'Libram', 8: 'Idol', 9: 'Totem' };
const WEAPON_SUB = { 0: 'Axe', 1: 'Axe', 2: 'Bow', 3: 'Gun', 4: 'Mace', 5: 'Mace', 6: 'Polearm', 7: 'Sword', 8: 'Sword', 10: 'Staff', 13: 'Fist Weapon', 14: 'Miscellaneous', 15: 'Dagger', 16: 'Thrown', 17: 'Spear', 18: 'Crossbow', 19: 'Wand', 20: 'Fishing Pole' };
const STAT = { 1: 'Health', 2: 'Mana', 3: 'Agility', 4: 'Strength', 5: 'Intellect', 6: 'Spirit', 7: 'Stamina' };
const RES = ['Holy', 'Fire', 'Nature', 'Frost', 'Shadow', 'Arcane'];
const BOND = { 1: 'Binds when picked up', 2: 'Binds when equipped', 3: 'Binds when used', 4: 'Quest Item' };
const TRIGGER = { 0: 'Use', 1: 'Equip', 2: 'Chance on hit' };
const DMG_SCHOOL = ['', 'Holy ', 'Fire ', 'Nature ', 'Frost ', 'Shadow ', 'Arcane '];

// Left-hand categories: label -> test(item)
const CATS = [
  ['Helmets', (i) => i.inv === 1], ['Shoulders', (i) => i.inv === 3], ['Chest', (i) => i.inv === 5 || i.inv === 20],
  ['Hands', (i) => i.inv === 10], ['Legs', (i) => i.inv === 7], ['Feet', (i) => i.inv === 8],
  ['Weapons', (i) => [13, 17, 21, 15, 25, 26].includes(i.inv)], ['Shields', (i) => i.inv === 14], ['Off-hand', (i) => i.inv === 22 || i.inv === 23],
  ['Neck', (i) => i.inv === 2], ['Back', (i) => i.inv === 16], ['Wrist', (i) => i.inv === 9], ['Waist', (i) => i.inv === 6],
  ['Rings', (i) => i.inv === 11], ['Trinkets', (i) => i.inv === 12], ['Relics', (i) => i.inv === 28],
  ['Bags', (i) => i.inv === 18 || i.inv === 27], ['Shirts & Tabards', (i) => i.inv === 4 || i.inv === 19], ['Ammo', (i) => i.inv === 24],
  ['Consumables', (i) => i.cls === 0], ['Trade Goods', (i) => i.cls === 7], ['Recipes', (i) => i.cls === 9], ['Quest Items', (i) => i.cls === 12],
  ['Everything', () => true], ['Sets', null],
];
const SLOTS = [['all', 'All'], ...CATS.filter(([n, t]) => t && n !== 'Everything').map(([n]) => [n, n])];
const JUNK = /^(Monster - |Test |TEST|Deprecated|\[PH\]|OLD|Unused|NPC Equip|QAEnchant|zz|Dev )|\(old\)|\(test\)|Deprecated/i;

const CSS = `
#gmar-btn{position:fixed;top:0;left:10.3rem;z-index:11;padding:.3rem .8rem;color:#ffd100;background:linear-gradient(180deg,#8f1a10,#4a0804);
  border:1px solid #c9a24a;border-top:0;border-radius:0 0 6px 6px;cursor:pointer;font:bold 12px "Friz Quadrata TT",Morpheus,Georgia,serif;text-shadow:1px 1px 0 #000}
#gmar-btn:hover,#gmar-btn.on{color:#fff6c2;background:linear-gradient(180deg,#b0261a,#5c0a05)}
#gmar{--gold:#ffd100;--wow:"Friz Quadrata TT",Morpheus,Georgia,serif;position:fixed;z-index:21;left:120px;top:70px;width:960px;height:620px;min-width:760px;min-height:480px;
  display:none;flex-direction:column;color:#fff;font:13px var(--wow);resize:both;overflow:hidden;
  background:linear-gradient(180deg,#2b2a28,#141312);border:4px solid #7d776b;border-radius:10px;
  box-shadow:0 0 0 1px #000,inset 0 0 0 1px #000,inset 0 0 0 3px #b9ae90,inset 0 0 0 4px #000,0 22px 60px rgba(0,0,0,.85)}
#gmar.open{display:flex}
#gmar *{box-sizing:border-box}
#gmar .ttl{position:relative;height:30px;display:flex;align-items:center;justify-content:center;cursor:move;user-select:none;
  background:linear-gradient(180deg,#3a3833,#1b1a18);border-bottom:2px solid #6e675b}
#gmar .ttl b{font:bold 15px var(--wow);color:var(--gold);text-shadow:1px 1px 0 #000;letter-spacing:.5px}
#gmar .portrait{position:absolute;left:-2px;top:-2px;width:58px;height:58px;border-radius:50%;border:3px solid #9a917c;background:#000 center/cover no-repeat;
  box-shadow:0 0 0 2px #000,0 3px 8px rgba(0,0,0,.8);z-index:2}
#gmar .x{position:absolute;right:6px;top:4px;width:22px;height:22px;border-radius:4px;border:1px solid #c9a24a;color:#ffd100;font:bold 13px system-ui;cursor:pointer;
  background:linear-gradient(180deg,#a3241a,#4e0905);line-height:1;padding:0}
#gmar .tabs{display:flex;gap:4px;padding:6px 10px 0 66px}
#gmar .tabs button{flex:1;font:bold 13px var(--wow);color:#e8d9a8;text-shadow:1px 1px 0 #000;padding:6px 8px;cursor:pointer;border:1px solid #7d776b;border-bottom:0;
  border-radius:7px 7px 0 0;background:linear-gradient(180deg,#3b3934,#1a1917)}
#gmar .tabs button.on{color:#fff;background:linear-gradient(180deg,#5c5547,#2b2924);border-color:#c9a24a;box-shadow:inset 0 2px 0 rgba(255,220,150,.15)}
#gmar .bar{display:flex;align-items:center;gap:8px;padding:7px 10px;border-top:1px solid #6e675b;border-bottom:1px solid #000;background:linear-gradient(180deg,#24221f,#191816);flex-wrap:wrap}
#gmar .bar label{font:bold 12px var(--wow);color:var(--gold);text-shadow:1px 1px 0 #000}
#gmar select,#gmar input[type=text]{font:12px system-ui,sans-serif;color:#fff;background:#0b0a09;border:1px solid #6e675b;border-radius:3px;padding:3px 6px;
  box-shadow:inset 0 1px 3px #000;outline:none}
#gmar select{min-width:120px}
#gmar .srch{flex:1;min-width:150px;position:relative}
#gmar .srch input{width:100%;padding-left:24px}
#gmar .srch:before{content:"⌕";position:absolute;left:7px;top:2px;color:#aaa;font-size:14px}
#gmar .chk{font:11px system-ui;color:#bbb;display:flex;align-items:center;gap:3px}
#gmar .body{flex:1;display:flex;min-height:0;padding:8px 10px 0;gap:8px}
#gmar .cats{width:150px;overflow:auto;display:flex;flex-direction:column;gap:4px;padding-right:4px}
#gmar .cats button{font:bold 13px var(--wow);color:#f1e6c8;text-shadow:1px 1px 0 #000;text-align:left;padding:6px 10px;cursor:pointer;border-radius:3px;
  border:1px solid #5d574b;background:linear-gradient(180deg,#3a2e1c,#1c160d)}
#gmar .cats button:hover{border-color:#c9a24a}
#gmar .cats button.on{color:#fff;border-color:#ffd100;background:linear-gradient(180deg,#6a5121,#33260d);box-shadow:inset 0 0 6px rgba(255,209,0,.3)}
#gmar .grid{flex:1;overflow:auto;border:3px solid #5d4a2a;border-radius:4px;padding:10px;
  background:radial-gradient(ellipse at 30% 20%,rgba(255,255,255,.18),transparent 60%),repeating-linear-gradient(17deg,rgba(120,85,40,.05) 0 3px,transparent 3px 7px),linear-gradient(180deg,#e2cfa4,#c7ab78 60%,#b89663);
  box-shadow:inset 0 0 18px rgba(80,50,15,.6);display:grid;grid-template-columns:repeat(auto-fill,46px);gap:8px;align-content:start}
#gmar .slot{width:46px;height:46px;border-radius:5px;position:relative;cursor:pointer;background:#000 center/40px no-repeat;
  border:2px solid var(--qc,#555);box-shadow:0 0 0 1px #000,0 0 7px var(--qg,transparent),inset 0 0 4px rgba(0,0,0,.9)}
#gmar .slot:hover{filter:brightness(1.25);box-shadow:0 0 0 1px #000,0 0 12px var(--qc),inset 0 0 4px rgba(0,0,0,.9)}
#gmar .slot.sel{outline:2px solid #fff;outline-offset:1px}
#gmar .slot.got{animation:gmargot .6s}
@keyframes gmargot{from{box-shadow:0 0 0 2px #7dff6b,0 0 18px #7dff6b}}
#gmar .grid .more{grid-column:1/-1;height:1px}
#gmar .grid .note{grid-column:1/-1;color:#3a2a10;font:13px var(--wow);padding:20px;text-align:center}
#gmar .setcard{grid-column:span 6;display:flex;flex-direction:column;gap:5px;padding:7px 9px;border:1px solid #6b5228;border-radius:4px;background:rgba(40,25,8,.18);cursor:pointer}
#gmar .setcard:hover{background:rgba(255,230,160,.25);border-color:#3a2a10}
#gmar .setcard b{font:bold 13px var(--wow);color:#3a1d6b;text-shadow:0 1px 0 rgba(255,255,255,.4)}
#gmar .setcard .pcs{display:flex;gap:4px;flex-wrap:wrap}
#gmar .setcard .pcs i{width:28px;height:28px;border-radius:3px;border:1px solid var(--qc,#555);background:#000 center/26px no-repeat;display:block}
#gmar .setcard small{font:11px system-ui;color:#4b3a1c}
#gmar .foot{display:flex;align-items:center;gap:10px;padding:8px 10px 10px}
#gmar .amt{display:flex;align-items:center;gap:6px;font:bold 12px var(--wow);color:var(--gold);text-shadow:1px 1px 0 #000}
#gmar .amt input[type=range]{width:110px;accent-color:#c9a24a}
#gmar .amt button,#gmar .pm{width:24px;height:24px;padding:0;border-radius:50%;font:bold 14px system-ui;color:#ffd100;cursor:pointer;border:1px solid #c9a24a;
  background:linear-gradient(180deg,#a3241a,#4e0905)}
#gmar .bigbtn{font:bold 13px var(--wow);color:#ffd100;text-shadow:1px 1px 0 #000;padding:7px 18px;cursor:pointer;border-radius:4px;border:1px solid #c9a24a;
  background:linear-gradient(180deg,#a3241a 0%,#7a140c 45%,#4e0905 100%);box-shadow:inset 0 1px 0 rgba(255,200,150,.35),0 1px 2px #000;white-space:nowrap}
#gmar .bigbtn:hover{color:#fff;background:linear-gradient(180deg,#c22f22,#931a10 45%,#5e0b06)}
#gmar .bigbtn:disabled{opacity:.45;cursor:default}
#gmar .dress{width:190px;align-self:stretch;display:flex;flex-direction:column;border:2px solid #7d776b;border-radius:5px;background:#0b0b0b;margin-top:-56px}
#gmar .dress .dh{font:bold 12px var(--wow);color:#fff;text-align:center;padding:3px;border-bottom:1px solid #444;background:linear-gradient(180deg,#3a3833,#1b1a18)}
#gmar .dress .stage{flex:1;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:6px;padding:8px;
  background:radial-gradient(ellipse at 50% 70%,#3a3a44,#0b0b0e 70%)}
#gmar .dress .big{width:64px;height:64px;border-radius:6px;border:2px solid var(--qc,#555);background:#000 center/60px no-repeat;box-shadow:0 0 12px var(--qg,transparent)}
#gmar .dress .nm{font:bold 12px Arial,sans-serif;text-align:center;text-shadow:1px 1px 0 #000}
#gmar .dress .hint{font:10.5px system-ui;color:#999;text-align:center}
#gmar .dress .bigbtn{margin:6px;padding:5px 8px;font-size:12px}
#gmar-tip{position:fixed;z-index:40;max-width:300px;pointer-events:none;display:none;padding:8px 10px;border-radius:5px;font:12.5px/1.35 Arial,Helvetica,sans-serif;color:#fff;
  background:rgba(4,8,22,.94);border:2px solid #9b9b9b;box-shadow:0 0 0 1px #000,0 6px 20px rgba(0,0,0,.7);text-shadow:1px 1px 0 #000}
#gmar-tip .n{font-size:14px;font-weight:bold;margin-bottom:2px}
#gmar-tip .row{display:flex;justify-content:space-between;gap:16px}
#gmar-tip .g{color:#1eff00}#gmar-tip .y{color:#ffd100}#gmar-tip .d{color:#9d9d9d}#gmar-tip .r{color:#ff2020}
#gmar-tip .h{color:#1eff00;margin-top:5px;font-size:11.5px}
`;

export default async function (gm) {
  gm.css(CSS);
  const { wenilla, esc, store } = gm;

  // ── data ────────────────────────────────────────────────────────────────────────────────────
  let items = null;
  let byId = new Map();
  let sets = [];
  let icons = new Map();
  let loadError = null;
  const ready = (async () => {
    try {
      const j = await (await fetch('gm/data/items.json')).json();
      const F = j.fields;
      items = j.rows.map((r) => Object.fromEntries(F.map((k, i) => [k, r[i]])));
      byId = new Map(items.map((i) => [i.id, i]));
      [icons, sets] = await Promise.all([iconNames(), itemSets()]);
    } catch (e) {
      loadError = e;
      console.warn('armory:', e);
    }
  })();

  // ── window ──────────────────────────────────────────────────────────────────────────────────
  const btn = document.createElement('button');
  btn.id = 'gmar-btn';
  btn.type = 'button';
  btn.textContent = '🛡 Armory';
  btn.title = 'Ultimate GM Suite: Armory & Gear (Ctrl+Shift+A)';
  document.body.appendChild(btn);

  const tip = document.createElement('div');
  tip.id = 'gmar-tip';
  document.body.appendChild(tip);

  const st = {
    cls: store.get('ar.cls', 'all'), slot: 'all', armor: 'all', q: store.get('ar.q', 'all'),
    cat: store.get('ar.cat', 'Helmets'), search: '', hideJunk: store.get('ar.junk', true),
    amt: 1, setAmt: 1, sel: null, list: [], shown: 0,
  };

  const w = document.createElement('div');
  w.id = 'gmar';
  w.innerHTML = `
    <div class="portrait" data-ref="portrait"></div>
    <div class="ttl"><b>Ultimate GM Suite</b><button class="x" data-act="close" title="Close">✕</button></div>
    <div class="tabs">
      <button data-go="creature">NPC Spawner</button>
      <button class="on">ARMORY &amp; GEAR</button>
      <button data-go="object">World Decorator</button>
      <button data-go="locations">Waypoint</button>
    </div>
    <div class="bar">
      <label>CLASS:</label><select data-f="cls">${CLASSES.map(([v, l]) => `<option value="${v}">${l}</option>`).join('')}</select>
      <label>SLOT:</label><select data-f="slot">${SLOTS.map(([v, l]) => `<option value="${esc(v)}">${esc(l)}</option>`).join('')}</select>
      <label>ARMOR:</label><select data-f="armor">${ARMOR.map(([v, l]) => `<option value="${v}">${l}</option>`).join('')}</select>
      <label>QUALITY:</label><select data-f="q"><option value="all">All</option>${QUALITY_NAME.map((n, i) => `<option value="${i}">${n}</option>`).join('')}</select>
      <div class="srch"><input type="text" data-f="search" placeholder="Search name or item ID…" spellcheck="false" autocomplete="off"></div>
      <span class="chk"><input type="checkbox" data-f="hideJunk" ${st.hideJunk ? 'checked' : ''}>hide test items</span>
    </div>
    <div class="body">
      <div class="cats">${CATS.map(([n]) => `<button data-cat="${esc(n)}">${esc(n)}</button>`).join('')}</div>
      <div class="grid" data-ref="grid"></div>
    </div>
    <div class="foot">
      <div class="amt">Amount: [ <span data-ref="amtv">1</span> ]
        <button data-act="amt-">−</button><input type="range" min="1" max="200" value="1" data-ref="amt"><button data-act="amt+">+</button></div>
      <button class="bigbtn" data-act="add">ADD TO INVENTORY</button>
      <span style="flex:1"></span>
      <div class="amt">Amount: [ <span data-ref="setv">1</span> ]
        <button data-act="set-">−</button><input type="range" min="1" max="10" value="1" data-ref="setamt"><button data-act="set+">+</button></div>
      <button class="bigbtn" data-act="addset">ADD COMPLETE SET</button>
      <div class="dress">
        <div class="dh">3D Dressing Room</div>
        <div class="stage" data-ref="stage"><div class="hint">Shift-click an item to try it on your character</div></div>
        <button class="bigbtn" data-act="tryon">3D Dressing Room</button>
      </div>
    </div>`;
  document.body.appendChild(w);
  const $ = (r) => w.querySelector(`[data-ref="${r}"]`);
  for (const ev of ['keydown', 'keyup', 'keypress']) w.addEventListener(ev, (e) => e.stopPropagation());
  w.querySelector('[data-f="cls"]').value = String(st.cls);
  w.querySelector('[data-f="q"]').value = String(st.q);
  iconUrl('INV_Misc_Book_09').then((u) => ($('portrait').style.backgroundImage = `url(${u})`));

  const rect = store.get('ar.rect', null);
  if (rect) Object.assign(w.style, { left: rect.left + 'px', top: rect.top + 'px', width: rect.width + 'px', height: rect.height + 'px' });
  const saveRect = () => {
    const b = w.getBoundingClientRect();
    store.set('ar.rect', { left: b.left, top: b.top, width: b.width, height: b.height });
  };
  w.querySelector('.ttl').addEventListener('pointerdown', (e) => {
    if (e.target.closest('button')) return;
    const b = w.getBoundingClientRect();
    const dx = e.clientX - b.left;
    const dy = e.clientY - b.top;
    const move = (ev) => {
      w.style.left = Math.max(0, Math.min(innerWidth - 120, ev.clientX - dx)) + 'px';
      w.style.top = Math.max(0, Math.min(innerHeight - 40, ev.clientY - dy)) + 'px';
    };
    const up = () => {
      removeEventListener('pointermove', move);
      removeEventListener('pointerup', up);
      saveRect();
    };
    addEventListener('pointermove', move);
    addEventListener('pointerup', up);
  });
  new ResizeObserver(() => w.classList.contains('open') && saveRect()).observe(w);

  function setOpen(open) {
    w.classList.toggle('open', open);
    btn.classList.toggle('on', open);
    if (open) refresh();
    else tip.style.display = 'none';
  }
  btn.onclick = () => setOpen(!w.classList.contains('open'));
  addEventListener('keydown', (e) => {
    if (e.ctrlKey && e.shiftKey && (e.key === 'A' || e.key === 'a')) {
      e.preventDefault();
      e.stopPropagation();
      setOpen(!w.classList.contains('open'));
    }
  }, true);

  // ── filtering ───────────────────────────────────────────────────────────────────────────────
  function passes(i) {
    if (st.hideJunk && JUNK.test(i.name)) return false;
    if (st.q !== 'all' && i.q !== Number(st.q)) return false;
    if (st.cls !== 'all') {
      const bit = Number(st.cls);
      if (i.allow > 0 && i.allow !== 32767 && i.allow !== 262143 && !(i.allow & bit)) return false;
      if (i.cls === 4 && [1, 2, 3, 4, 6].includes(i.sub) && !CLASS_ARMOR[bit].includes(i.sub)) return false;
    }
    if (st.armor !== 'all' && !(i.cls === 4 && i.sub === Number(st.armor))) return false;
    if (st.slot !== 'all') {
      const c = CATS.find(([n]) => n === st.slot);
      if (c && !c[1](i)) return false;
    }
    return true;
  }
  function filtered() {
    const q = st.search.trim().toLowerCase();
    const cat = CATS.find(([n]) => n === st.cat);
    const test = q ? null : cat?.[1];
    const out = items.filter((i) => {
      if (q) {
        if (!(String(i.id) === q || i.name.toLowerCase().includes(q))) return false;
      } else if (test && !test(i)) return false;
      return passes(i);
    });
    out.sort((a, b) => b.ilvl - a.ilvl || b.q - a.q || a.name.localeCompare(b.name));
    return out;
  }

  // ── grid with infinite scroll ───────────────────────────────────────────────────────────────
  const grid = () => $('grid');
  // Icons load per chunk (decoded once, then cached); more items load as you scroll near the end.
  const loadIcons = (root) =>
    root.querySelectorAll('[data-icon]:not([data-seen])').forEach((el) => {
      el.dataset.seen = 1;
      if (el.dataset.icon) iconUrl(el.dataset.icon).then((u) => u && (el.style.backgroundImage = `url(${u})`));
    });

  function slotHtml(i) {
    const c = QUALITY[i.q] || '#555';
    return `<div class="slot${st.sel === i ? ' sel' : ''}" data-id="${i.id}" data-icon="${esc(icons.get(i.disp) || '')}"
      style="--qc:${i.q >= 2 ? c : '#3b3b3b'};--qg:${i.q >= 2 ? c + '88' : 'transparent'}"></div>`;
  }
  function appendChunk() {
    const g = grid();
    g.querySelector('.more')?.remove();
    const next = st.list.slice(st.shown, st.shown + 160);
    st.shown += next.length;
    g.insertAdjacentHTML('beforeend', next.map(slotHtml).join('') + (st.shown < st.list.length ? '<div class="more"></div>' : ''));
    loadIcons(g);
  }

  async function refresh() {
    for (const b of w.querySelectorAll('.cats button')) b.classList.toggle('on', b.dataset.cat === st.cat && !st.search);
    const g = grid();
    if (!items) {
      g.innerHTML = `<div class="note">${loadError ? 'Could not load the item list. Run <b>export_items_for_gm_panel.bat</b> in the Open Vanilla folder, then reopen.' : 'Loading every item in the database…'}</div>`;
      await ready;
      if (!items) return refresh();
    }
    g.scrollTop = 0;
    if (st.cat === 'Sets' && !st.search) return renderSets();
    st.list = filtered();
    st.shown = 0;
    g.innerHTML = st.list.length ? '' : '<div class="note">No items match these filters.</div>';
    appendChunk();
  }

  function renderSets() {
    const q = st.search.trim().toLowerCase();
    const list = sets
      .filter((s) => s.items.length && (!q || s.name.toLowerCase().includes(q)))
      .filter((s) => st.cls === 'all' || s.items.some((id) => byId.get(id) && passes(byId.get(id))))
      .map((s) => ({ ...s, q: Math.max(0, ...s.items.map((id) => byId.get(id)?.q ?? 0)), lvl: Math.max(0, ...s.items.map((id) => byId.get(id)?.ilvl ?? 0)) }))
      .sort((a, b) => b.lvl - a.lvl);
    const g = grid();
    g.innerHTML = list.length
      ? list.map((s) => `<div class="setcard" data-set="${s.id}" title="Click: add the complete set">
          <b style="color:${s.q >= 4 ? '#5a1f9a' : s.q === 3 ? '#0a4f9a' : '#2b5a10'}">${esc(s.name)}</b>
          <div class="pcs">${s.items.map((id) => `<i data-id="${id}" data-icon="${esc(icons.get(byId.get(id)?.disp) || '')}" style="--qc:${QUALITY[byId.get(id)?.q ?? 1]}"></i>`).join('')}</div>
          <small>${s.items.length} pieces · item level ${s.lvl}</small></div>`).join('')
      : '<div class="note">No sets match.</div>';
    loadIcons(g);
  }

  // ── tooltip ─────────────────────────────────────────────────────────────────────────────────
  let tipFor = 0;
  async function showTip(i, x, y) {
    tipFor = i.id;
    const c = QUALITY[i.q] || '#fff';
    tip.style.borderColor = i.q >= 3 ? c : '#9b9b9b';
    const lines = [`<div class="n" style="color:${c}">${esc(i.name)}</div>`];
    if (BOND[i.bond]) lines.push(`<div>${BOND[i.bond]}</div>`);
    const type = i.cls === 4 ? ARMOR_SUB[i.sub] || '' : i.cls === 2 ? WEAPON_SUB[i.sub] || '' : '';
    if (INV_NAME[i.inv]) lines.push(`<div class="row"><span>${INV_NAME[i.inv]}</span><span>${type}</span></div>`);
    if (i.slots) lines.push(`<div>${i.slots} Slot ${i.inv === 27 ? 'Quiver' : 'Bag'}</div>`);
    if (i.cls === 2 && i.dmax) {
      const spd = i.delay / 1000;
      lines.push(`<div class="row"><span>${i.dmin} - ${i.dmax} ${DMG_SCHOOL[i.dtype] || ''}Damage</span><span>Speed ${spd.toFixed(2)}</span></div>`);
      lines.push(`<div>(${(((i.dmin + i.dmax) / 2) / spd).toFixed(1)} damage per second)</div>`);
    }
    if (i.armor) lines.push(`<div>${i.armor} Armor</div>`);
    if (i.block) lines.push(`<div>${i.block} Block</div>`);
    for (const [t, v] of i.stats || []) if (STAT[t]) lines.push(`<div>${v > 0 ? '+' : ''}${v} ${STAT[t]}</div>`);
    (i.res || []).forEach((v, k) => v && lines.push(`<div>+${v} ${RES[k]} Resistance</div>`));
    if (i.dur) lines.push(`<div>Durability ${i.dur} / ${i.dur}</div>`);
    if (i.req > 1) lines.push(`<div>Requires Level ${i.req}</div>`);
    lines.push('<div data-ref="spells"></div>');
    const set = i.set && sets.find((s) => s.id === i.set);
    if (set) {
      lines.push(`<div class="y" style="margin-top:6px">${esc(set.name)} (0/${set.items.length})</div>`);
      for (const id of set.items) lines.push(`<div class="d">&nbsp; ${esc(byId.get(id)?.name || '#' + id)}</div>`);
      lines.push('<div data-ref="bonus"></div>');
    }
    if (i.desc) lines.push(`<div class="y">"${esc(i.desc)}"</div>`);
    lines.push(`<div class="d" style="margin-top:4px">Item ID: ${i.id}${i.ilvl ? ` · Item Level ${i.ilvl}` : ''}</div>`);
    lines.push(`<div class="h">&lt;Left-Click to Add to Bags (${st.amt})&gt;</div>`);
    if (set) lines.push(`<div class="h" style="margin-top:0">&lt;Right-Click to Add Set&gt;</div>`);
    lines.push(`<div class="h" style="margin-top:0;color:#9bd">&lt;Shift-Click: Dressing Room · Ctrl-Click: Link in chat&gt;</div>`);
    tip.innerHTML = lines.join('');
    tip.style.display = 'block';
    placeTip(x, y);
    // spell lines (Equip: / Use: / Chance on hit:) and set bonuses come from Spell.dbc
    const sp = await Promise.all((i.spells || []).map(async ([id, trig]) => [TRIGGER[trig] || 'Use', await spellText(id).catch(() => '')]));
    if (tipFor !== i.id) return;
    const spEl = tip.querySelector('[data-ref="spells"]');
    if (spEl) spEl.innerHTML = sp.filter(([, t]) => t).map(([k, t]) => `<div class="g">${k}: ${esc(t)}</div>`).join('');
    if (set) {
      const bon = await Promise.all(set.bonuses.map(async (b) => `(${b.pieces}) Set: ${await spellText(b.spell).catch(() => '')}`));
      if (tipFor !== i.id) return;
      const bEl = tip.querySelector('[data-ref="bonus"]');
      if (bEl) bEl.innerHTML = bon.map((t) => `<div class="d">${esc(t)}</div>`).join('');
    }
    placeTip(x, y);
  }
  function placeTip(x, y) {
    const r = tip.getBoundingClientRect();
    let left = x + 18;
    let top = y + 12;
    if (left + r.width > innerWidth - 8) left = x - r.width - 18;
    if (top + r.height > innerHeight - 8) top = innerHeight - r.height - 8;
    tip.style.left = Math.max(8, left) + 'px';
    tip.style.top = Math.max(8, top) + 'px';
  }

  // ── actions ─────────────────────────────────────────────────────────────────────────────────
  const giveItem = (i, n = st.amt) => gm.send(`.additem ${i.id} ${n}`);
  const giveSet = (setId, n = st.setAmt) => {
    for (let k = 0; k < n; k++) setTimeout(() => gm.send(`.additemset ${setId}`), k * 400);
  };
  const luaStr = (s) => '"' + String(s).replace(/[^\x20-\x7e]/g, '').replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
  function tryOn(i) {
    wenilla.lua(`DressUpItemLink(${luaStr(`item:${i.id}:0:0:0`)}) return 1`).then(
      () => gm.log(`Trying on ${i.name} in the Dressing Room.`, 'res'),
      (e) => gm.log('Dressing Room: ' + e.message, 'err'),
    );
  }
  function linkInChat(i) {
    const hex = (QUALITY[i.q] || '#ffffff').slice(1);
    const link = `|cff${hex}|Hitem:${i.id}:0:0:0|h[${i.name}]|h|r`;
    wenilla.lua(`if not ChatFrameEditBox:IsVisible() then ChatFrame_OpenChat("") end ChatFrameEditBox:Insert(${luaStr(link)}) return 1`).then(
      () => gm.log(`Linked ${i.name} in your chat box.`, 'res'),
      (e) => gm.log('Chat link: ' + e.message, 'err'),
    );
  }
  function select(i, el) {
    st.sel = i;
    w.querySelectorAll('.slot.sel').forEach((s) => s.classList.remove('sel'));
    el?.classList.add('sel');
    const c = QUALITY[i.q] || '#fff';
    iconUrl(icons.get(i.disp)).then((u) => {
      $('stage').innerHTML = `<div class="big" style="--qc:${c};--qg:${c}88;background-image:url(${u})"></div>
        <div class="nm" style="color:${c}">${esc(i.name)}</div><div class="hint">Press the button below to see it on your character</div>`;
    });
    w.querySelector('[data-act="addset"]').disabled = !i.set;
  }
  function flash(el) {
    el.classList.remove('got');
    void el.offsetWidth;
    el.classList.add('got');
  }

  w.addEventListener('click', (e) => {
    const go = e.target.closest('[data-go]')?.dataset.go;
    if (go) {
      gm.open();
      if (go === 'locations') gm.selectTab('locations');
      else gm.openLoot?.(go);
      return;
    }
    const act = e.target.closest('[data-act]')?.dataset.act;
    if (act) {
      const amt = $('amt');
      const sa = $('setamt');
      if (act === 'close') setOpen(false);
      if (act === 'amt-' || act === 'amt+') amt.value = Number(amt.value) + (act === 'amt+' ? 1 : -1);
      if (act === 'set-' || act === 'set+') sa.value = Number(sa.value) + (act === 'set+' ? 1 : -1);
      st.amt = Number(amt.value);
      st.setAmt = Number(sa.value);
      $('amtv').textContent = st.amt;
      $('setv').textContent = st.setAmt;
      if (act === 'add') st.sel ? giveItem(st.sel) : gm.log('Pick an item first.');
      if (act === 'addset') st.sel?.set ? giveSet(st.sel.set) : gm.log('That item is not part of a set.');
      if (act === 'tryon') st.sel ? tryOn(st.sel) : gm.log('Pick an item first.');
      return;
    }
    const cat = e.target.closest('[data-cat]')?.dataset.cat;
    if (cat) {
      st.cat = cat;
      store.set('ar.cat', cat);
      st.search = '';
      w.querySelector('[data-f="search"]').value = '';
      return refresh();
    }
    const card = e.target.closest('[data-set]');
    if (card && !e.target.closest('[data-id]')) return giveSet(Number(card.dataset.set)), flash(card);
    const el = e.target.closest('[data-id]');
    if (!el) return;
    const i = byId.get(Number(el.dataset.id));
    if (!i) return;
    if (e.ctrlKey || e.metaKey) return linkInChat(i);
    if (e.shiftKey) return select(i, el), tryOn(i);
    select(i, el);
    giveItem(i);
    flash(el);
  });
  $('grid').addEventListener('scroll', (e) => {
    const g = e.currentTarget;
    if (st.shown < st.list.length && g.scrollTop + g.clientHeight > g.scrollHeight - 400) appendChunk();
  });
  w.addEventListener('contextmenu', (e) => {
    const el = e.target.closest('[data-id]');
    if (!el) return;
    e.preventDefault();
    const i = byId.get(Number(el.dataset.id));
    if (i?.set) {
      select(i, el);
      giveSet(i.set);
      flash(el);
    } else gm.log(`${i?.name || 'That item'} is not part of a set.`);
  });
  w.addEventListener('mouseover', (e) => {
    const el = e.target.closest('[data-id]');
    if (!el) return;
    const i = byId.get(Number(el.dataset.id));
    if (i) showTip(i, e.clientX, e.clientY);
  });
  w.addEventListener('mousemove', (e) => tip.style.display === 'block' && e.target.closest('[data-id]') && placeTip(e.clientX, e.clientY));
  w.addEventListener('mouseout', (e) => {
    if (e.target.closest('[data-id]') && !e.relatedTarget?.closest?.('[data-id]')) tip.style.display = 'none';
  });
  w.addEventListener('input', (e) => {
    const f = e.target.dataset.f;
    if (e.target.dataset.ref === 'amt' || e.target.dataset.ref === 'setamt') {
      st.amt = Number($('amt').value);
      st.setAmt = Number($('setamt').value);
      $('amtv').textContent = st.amt;
      $('setv').textContent = st.setAmt;
      return;
    }
    if (!f) return;
    st[f] = e.target.type === 'checkbox' ? e.target.checked : e.target.value;
    if (f === 'cls') store.set('ar.cls', st.cls);
    if (f === 'q') store.set('ar.q', st.q);
    if (f === 'hideJunk') store.set('ar.junk', st.hideJunk);
    if (f === 'slot' && st.slot !== 'all') {
      st.cat = st.slot;
      st.slot = 'all';
      e.target.value = 'all';
    }
    clearTimeout(st.t);
    st.t = setTimeout(refresh, f === 'search' ? 180 : 0);
  });

  gm.armory = { open: () => setOpen(true), close: () => setOpen(false) };
  gm.addTab('armory', 'Armory', (pane) => {
    pane.innerHTML = `<div class="card"><h4>Ultimate GM Suite · Armory &amp; Gear</h4>
      <div class="hint">Every item in your database as an icon grid, with filters, tooltips, sets, try-on and chat links. It opens in its own window (also the 🛡 Armory button at the top, or Ctrl+Shift+A).</div>
      <div class="btns" style="margin-top:8px"><button class="primary" data-open>Open the Armory</button></div></div>`;
    pane.querySelector('[data-open]').onclick = () => setOpen(true);
    setOpen(true);
  }, { first: true });
}
