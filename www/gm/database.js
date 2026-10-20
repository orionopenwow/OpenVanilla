// database.js: the "Loot" tab. An AtlasLoot-style browser over the server's own database.
// Search items, item sets, creatures, objects, spells or quests (the server's .lookup commands),
// or browse ready-made collections (tier sets, legendaries, mounts, bags, consumables). Results
// come back as cards: click an item to put it in your bags (or your target player's), click a set
// to get the whole set, spawn creatures/objects, learn or cast spells, add quests.
// Item quality colours come from the game client's own item cache when it has seen the item.

const KINDS = [
  { id: 'item', label: 'Items', lookup: '.lookup item', placeholder: 'e.g. thunderfury, runecloth, potion' },
  { id: 'itemset', label: 'Item sets', lookup: '.lookup itemset', placeholder: 'e.g. might, netherwind, valor' },
  { id: 'creature', label: 'NPCs', lookup: '.lookup creature', placeholder: 'e.g. hogger, ragnaros, innkeeper' },
  { id: 'object', label: 'Objects', lookup: '.lookup object', placeholder: 'e.g. mailbox, chair, bonfire' },
  { id: 'spell', label: 'Spells', lookup: '.lookup spell', placeholder: 'e.g. frostbolt, mount, blessing' },
  { id: 'quest', label: 'Quests', lookup: '.lookup quest', placeholder: 'e.g. onyxia, the defias' },
  { id: 'faction', label: 'Factions', lookup: '.lookup faction', placeholder: 'e.g. stormwind, argent' },
];

const CLASS_SETS = (tier, names) => names.map(([cls, set]) => ({ label: `${cls}: ${set}`, kind: 'itemset', q: set, tier }));
const COLLECTIONS = [
  { name: 'Tier 0 · Dungeon sets', items: CLASS_SETS('T0', [['Warrior', 'Battlegear of Valor'], ['Mage', "Magister's Regalia"], ['Priest', 'Vestments of the Devout'], ['Rogue', 'Shadowcraft Armor'], ['Druid', 'Wildheart Raiment'], ['Hunter', 'Beaststalker Armor'], ['Warlock', 'Dreadmist Raiment'], ['Paladin', 'Lightforge Armor'], ['Shaman', 'The Elements']]) },
  { name: 'Tier 1 · Molten Core', items: CLASS_SETS('T1', [['Warrior', 'Battlegear of Might'], ['Mage', 'Arcanist Regalia'], ['Priest', 'Vestments of Prophecy'], ['Rogue', 'Nightslayer Armor'], ['Druid', 'Cenarion Raiment'], ['Hunter', 'Giantstalker Armor'], ['Warlock', 'Felheart Raiment'], ['Paladin', 'Lawbringer Armor'], ['Shaman', 'The Earthfury']]) },
  { name: 'Tier 2 · Blackwing Lair', items: CLASS_SETS('T2', [['Warrior', 'Battlegear of Wrath'], ['Mage', 'Netherwind Regalia'], ['Priest', 'Vestments of Transcendence'], ['Rogue', 'Bloodfang Armor'], ['Druid', 'Stormrage Raiment'], ['Hunter', 'Dragonstalker Armor'], ['Warlock', 'Nemesis Raiment'], ['Paladin', 'Judgement Armor'], ['Shaman', 'The Ten Storms']]) },
  { name: 'Tier 3 · Naxxramas', items: CLASS_SETS('T3', [['Warrior', "Dreadnaught's Battlegear"], ['Mage', 'Frostfire Regalia'], ['Priest', 'Vestments of Faith'], ['Rogue', 'Bonescythe Armor'], ['Druid', 'Dreamwalker Raiment'], ['Hunter', 'Cryptstalker Armor'], ['Warlock', 'Plagueheart Raiment'], ['Paladin', 'Redemption Armor'], ['Shaman', 'The Earthshatterer']]) },
  { name: 'Legendaries & famous weapons', items: ['Thunderfury', 'Sulfuras', 'Atiesh', 'Corrupted Ashbringer', 'Ashkandi', "Quel'Serrar", 'Benediction', "Rhok'delar", "Lok'delar", 'Nightfall', 'Hand of Ragnaros', 'Ironfoe', "Gressil", 'Kingsfall', 'Bonereaver'].map((q) => ({ label: q, kind: 'item', q })) },
  { name: 'Mounts', items: ['Reins of the', 'Horn of the', 'Whistle of the', 'Mechanostrider', 'Bridle', "Deathcharger's Reins", 'Swift Razzashi Raptor', 'Swift Zulian Tiger', 'Black Qiraji Resonating Crystal'].map((q) => ({ label: q, kind: 'item', q })) },
  { name: 'Bags', items: ['Onyxia Hide Backpack', 'Core Felcloth Bag', 'Mooncloth Bag', 'Runecloth Bag', "Traveler's Backpack", 'Bottomless Bag', 'Quiver', 'Ammo Pouch', 'Soul Pouch'].map((q) => ({ label: q, kind: 'item', q })) },
  { name: 'Consumables', items: ['Flask of', 'Elixir of the Mongoose', 'Elixir of Giants', 'Major Healing Potion', 'Major Mana Potion', 'Greater Fire Protection Potion', 'Free Action Potion', 'Limited Invulnerability Potion', 'Heavy Runecloth Bandage', 'Juju'].map((q) => ({ label: q, kind: 'item', q })) },
  { name: 'Fun & cosmetic', items: ['Tabard', 'Noggenfogger', 'Orb of Deception', 'Gnomish Mind Control Cap', 'Fireworks', 'Pet carrier', 'Mini Diablo', 'Panda Collar', 'Zergling Leash'].map((q) => ({ label: q, kind: 'item', q })) },
];

const QUALITY = ['#9d9d9d', '#ffffff', '#1eff00', '#0070dd', '#a335ee', '#ff8000', '#e6cc80'];
const QUALITY_NAME = ['Poor', 'Common', 'Uncommon', 'Rare', 'Epic', 'Legendary', 'Artifact'];

const CSS = `
#gmp .loot{display:flex;flex:1;min-height:0}
#gmp .lcol{width:220px;border-right:1px solid #2c2923;overflow:auto;padding:8px}
#gmp .lcol h5{margin:8px 2px 4px;font:bold 12px var(--wow);color:var(--gold);cursor:pointer;display:flex;justify-content:space-between}
#gmp .lcol h5:first-child{margin-top:0}
#gmp .lcol .ent{padding:4px 8px;font:12.5px system-ui;color:#ddd;cursor:pointer;border-radius:3px}
#gmp .lcol .ent:hover{background:rgba(255,209,0,.09);color:#fff}
#gmp .lcol .ent.on{background:rgba(255,209,0,.18);color:var(--gold)}
#gmp .lmain{flex:1;display:flex;flex-direction:column;min-width:0}
#gmp .lkinds{display:flex;gap:4px;padding:8px 10px 0;flex-wrap:wrap}
#gmp .lkinds button{padding:4px 10px;font-size:12px}
#gmp .lkinds button.on{border-color:#ffe08a;color:#fff;background:linear-gradient(180deg,#c22f22,#7a140c 50%,#4e0905)}
#gmp .lbar{display:flex;gap:8px;align-items:center;padding:8px 10px;border-bottom:1px solid #2c2923;flex-wrap:wrap}
#gmp .lbar input[data-ref=lq]{flex:1;min-width:180px}
#gmp .lbar input[data-ref=qty]{width:58px;text-align:center}
#gmp .lstatus{padding:5px 12px;font:12px system-ui;color:var(--dim);min-height:24px}
#gmp .lres{flex:1;overflow:auto;padding:4px 10px 10px;display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:6px;align-content:start}
#gmp .lcard{display:flex;align-items:center;gap:9px;padding:6px 8px;border:1px solid #3a362e;border-radius:4px;background:rgba(0,0,0,.45);cursor:pointer;min-width:0}
#gmp .lcard:hover{border-color:#c9a24a;background:rgba(255,209,0,.06)}
#gmp .lcard .slot{width:34px;height:34px;flex:none;border:1px solid #555046;border-radius:4px;background:radial-gradient(circle at 40% 35%,#3a352c,#0c0b09);
  display:flex;align-items:center;justify-content:center;font-size:16px;box-shadow:inset 0 0 6px #000}
#gmp .lcard .txt{flex:1;min-width:0}
#gmp .lcard .nm{font:bold 13px Arial,Helvetica,sans-serif;text-shadow:1px 1px 0 #000;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
#gmp .lcard .sub{font:11px system-ui;color:var(--dim);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
#gmp .lcard .acts{display:flex;gap:4px;flex:none}
#gmp .lcard .acts button{padding:3px 8px;font-size:11px}
#gmp .lcard.got{animation:gmpgot .7s}
@keyframes gmpgot{from{box-shadow:0 0 0 2px #7dff6b,0 0 14px #7dff6b}}
`;

const ICON = { item: '🗡', itemset: '🛡', creature: '👹', object: '📦', spell: '✨', quest: '❗', faction: '⚑' };

export default function (gm) {
  gm.css(CSS);
  const { esc, wenilla, store } = gm;
  let kind = store.get('lootKind', 'item');
  let results = [];
  let status = 'Search, or pick a collection on the left.';
  let activeEntry = null;
  let pane = null;
  let collecting = null;
  const openGroups = store.get('lootOpen', { 0: true });

  /** One reply line of a .lookup: "<id> - |cff..|H<type>:<id>..|h[<name>]|h|r <extra>". */
  function parseLine(raw) {
    const m = raw.match(/^\s*(\d+)\s*-\s*(.*)$/s);
    if (!m) return null;
    const rest = m[2];
    const color = (rest.match(/\|c[0-9a-f]{2}([0-9a-f]{6})/i) || [])[1];
    const name = (rest.match(/\[([^\]]+)\]/) || [])[1] || rest.replace(/\|c[0-9a-f]{8}|\|r|\|H[^|]*\|h|\|h/gi, '').trim();
    const extra = rest.replace(/.*\|h\|r/s, '').replace(/\|c[0-9a-f]{8}|\|r/gi, '').trim();
    return { id: Number(m[1]), name, color, extra: extra && extra !== name ? extra : '' };
  }

  function search(q, k = kind, entry = null) {
    q = String(q || '').trim();
    if (!q) return;
    kind = k;
    store.set('lootKind', kind);
    activeEntry = entry;
    results = [];
    status = `Searching ${KINDS.find((x) => x.id === kind).label.toLowerCase()} for “${q}”…`;
    if (collecting) {
      clearTimeout(collecting.timer);
      collecting.stop();
      collecting = null;
    }
    const c = { kind, q, timer: null, stop: null, last: performance.now() };
    const finish = () => {
      c.stop?.();
      if (collecting === c) collecting = null;
      status = results.length ? `${results.length} result${results.length === 1 ? '' : 's'} for “${q}”` : `Nothing found for “${q}”.`;
      if (results.length >= 50) status += ' (the server shows 50 at most: be more specific)';
      paint();
      if (kind === 'item') enrichItems();
    };
    c.stop = gm.capture((text) => {
      if (collecting !== c) return false;
      const r = parseLine(text);
      if (r) {
        results.push(r);
        clearTimeout(c.timer);
        c.timer = setTimeout(finish, 700);
        paintSoon();
        return true;
      }
      if (/not found|no \w+ found|nothing found/i.test(text)) {
        clearTimeout(c.timer);
        c.timer = setTimeout(finish, 150);
        return true;
      }
      return false;
    });
    c.timer = setTimeout(finish, 4000);
    collecting = c;
    if (pane) {
      const inp = pane.querySelector('[data-ref="lq"]');
      if (inp && document.activeElement !== inp) inp.value = q;
    }
    paint();
    gm.send(`${KINDS.find((x) => x.id === kind).lookup} ${q}`);
  }

  // Quality, level and type from the client's item cache (only for items it has seen).
  async function enrichItems() {
    const ids = results.filter((r) => r.q === undefined).map((r) => r.id).slice(0, 60);
    if (!ids.length) return;
    const lua = `local out = {}
for _, id in ipairs({${ids.join(',')}}) do
  local ok, n, l, q, ml, t, st, sc, el = pcall(GetItemInfo, id)
  if ok and n then table.insert(out, id .. "|" .. (q or 1) .. "|" .. (ml or 0) .. "|" .. (st or "") .. "|" .. (sc or 1) .. "|" .. (el or ""))
  else table.insert(out, id .. "|-1") end
end
return table.concat(out, ";")`;
    try {
      const [s] = await wenilla.lua(lua, 5000);
      for (const part of String(s || '').split(';')) {
        const [id, q, ml, st, sc, el] = part.split('|');
        const r = results.find((x) => x.id === Number(id));
        if (!r || q === '-1' || q === undefined) continue;
        r.q = Number(q);
        r.minLevel = Number(ml) || 0;
        r.sub = st;
        r.stack = Number(sc) || 1;
        r.slot = (el || '').replace(/^INVTYPE_/, '').toLowerCase().replace(/_/g, ' ');
      }
      paint();
    } catch {
      /* no VM yet: plain cards are fine */
    }
  }

  let soon = 0;
  function paintSoon() {
    if (soon) return;
    soon = requestAnimationFrame(() => {
      soon = 0;
      paint();
    });
  }

  function actionsFor(r) {
    switch (kind) {
      case 'item':
        return `<button data-a="give" title="Put in your bags (or your target player's)">Get</button>${r.stack > 1 ? `<button class="stone" data-a="stack" title="A full stack (${r.stack})">×${r.stack}</button>` : ''}`;
      case 'itemset':
        return `<button data-a="set" title="Every piece of the set">Get set</button>`;
      case 'creature':
        return `<button data-a="spawn" title="Place it where you stand (saved)">Spawn</button><button class="stone" data-a="goto" title="Teleport to it">Go</button>`;
      case 'object':
        return `<button data-a="spawn" title="Place it where you stand (saved)">Spawn</button><button class="stone" data-a="goto" title="Teleport to it">Go</button>`;
      case 'spell':
        return `<button data-a="learn" title="Learn it (target or you)">Learn</button><button class="stone" data-a="cast" title="Cast it on your target">Cast</button><button class="stone" data-a="aura" title="Apply it as an aura">Aura</button>`;
      case 'quest':
        return `<button data-a="qadd" title="Add to the quest log (target or you)">Add</button><button class="stone" data-a="qdone" title="Complete its objectives">Complete</button>`;
      case 'faction':
        return `<button data-a="exalted" title="Exalted with this faction (target or you)">Exalted</button>`;
    }
    return '';
  }

  function card(r, i) {
    const color = r.q !== undefined && r.q >= 0 ? QUALITY[r.q] : r.color && r.color.toLowerCase() !== 'ffffff' ? '#' + r.color : kind === 'itemset' ? '#a335ee' : '#ffffff';
    const sub =
      kind === 'item'
        ? [r.q !== undefined ? QUALITY_NAME[r.q] : null, r.slot, r.sub, r.minLevel ? `level ${r.minLevel}` : null].filter(Boolean).join(' · ') || `Item ${r.id}`
        : `${KINDS.find((x) => x.id === kind).label.replace(/s$/, '')} ${r.id}${r.extra ? ' · ' + r.extra : ''}`;
    return `<div class="lcard" data-i="${i}" title="${esc(r.name)} (#${r.id})">
      <div class="slot" style="border-color:${color}55">${ICON[kind]}</div>
      <div class="txt"><div class="nm" style="color:${color}">${esc(r.name)}</div><div class="sub">${esc(sub)}</div></div>
      <div class="acts">${actionsFor(r)}</div></div>`;
  }

  function paint() {
    if (!pane) return;
    pane.querySelector('[data-ref="lstatus"]').textContent = status;
    pane.querySelector('[data-ref="lres"]').innerHTML = results.map(card).join('');
    for (const b of pane.querySelectorAll('[data-kind]')) b.classList.toggle('on', b.dataset.kind === kind);
    const k = KINDS.find((x) => x.id === kind);
    const q = pane.querySelector('[data-ref="lq"]');
    q.placeholder = `Search ${k.label.toLowerCase()}…  ${k.placeholder}`;
    pane.querySelector('[data-ref="qtywrap"]').style.display = kind === 'item' ? '' : 'none';
    for (const e of pane.querySelectorAll('.ent')) e.classList.toggle('on', e.dataset.e === activeEntry);
  }

  function renderShell(p) {
    pane = p;
    p.style.padding = '0';
    p.innerHTML = `<div class="loot">
      <div class="lcol">${COLLECTIONS.map(
        (c, ci) => `<h5 data-grp="${ci}">${esc(c.name)}<span>${openGroups[ci] ? '▾' : '▸'}</span></h5>${
          openGroups[ci] ? c.items.map((it, ii) => `<div class="ent" data-e="${ci}:${ii}">${esc(it.label)}</div>`).join('') : ''
        }`,
      ).join('')}</div>
      <div class="lmain">
        <div class="lkinds">${KINDS.map((k) => `<button data-kind="${k.id}">${k.label}</button>`).join('')}</div>
        <div class="lbar"><input data-ref="lq" spellcheck="false" autocomplete="off">
          <button class="primary" data-act="lsearch">Search</button>
          <span data-ref="qtywrap">Amount <input data-ref="qty" type="number" min="1" value="${store.get('lootQty', 1)}"></span>
          <span class="hint" data-ref="who"></span></div>
        <div class="lstatus" data-ref="lstatus"></div>
        <div class="lres" data-ref="lres"></div>
      </div></div>`;
    paint();
    paintWho();
  }

  function paintWho() {
    const w = pane?.querySelector('[data-ref="who"]');
    if (!w) return;
    const t = gm.target();
    w.textContent = t?.isPlayer ? `→ goes to ${t.name}` : '→ goes to you';
  }

  function act(a, r, el) {
    const qty = Math.max(1, Math.round(Number(pane.querySelector('[data-ref="qty"]').value) || 1));
    const cmds = {
      give: `.additem ${r.id} ${qty}`,
      stack: `.additem ${r.id} ${r.stack}`,
      set: `.additemset ${r.id}`,
      spawn: kind === 'creature' ? `.npc add ${r.id}` : `.gobject add ${r.id}`,
      goto: kind === 'creature' ? `.go creature id ${r.id}` : `.go object id ${r.id}`,
      learn: `.learn ${r.id}`,
      cast: `.cast ${r.id}`,
      aura: `.aura ${r.id}`,
      qadd: `.quest add ${r.id}`,
      qdone: `.quest complete ${r.id}`,
      exalted: `.modify rep ${r.id} exalted`,
    };
    if (!cmds[a]) return;
    gm.send(cmds[a]);
    el.classList.remove('got');
    void el.offsetWidth;
    el.classList.add('got');
  }

  /** Open the GM panel on the Loot tab with a search kind selected (used by the Armory's top tabs). */
  gm.openLoot = (k) => {
    if (KINDS.some((x) => x.id === k)) {
      kind = k;
      store.set('lootKind', kind);
      results = [];
      status = 'Type a name and press Search.';
      activeEntry = null;
    }
    gm.open();
    gm.selectTab('loot');
    if (pane) {
      paint();
      pane.querySelector('[data-ref="lq"]')?.focus();
    }
  };

  const PRIMARY = { item: 'give', itemset: 'set', creature: 'spawn', object: 'spawn', spell: 'learn', quest: 'qadd', faction: 'exalted' };

  gm.addTab(
    'loot',
    'Loot',
    (p) => {
      if (pane === p) return paint(), paintWho();
      renderShell(p);
      p.addEventListener('click', (e) => {
        const grp = e.target.closest('[data-grp]');
        if (grp) {
          openGroups[grp.dataset.grp] = !openGroups[grp.dataset.grp];
          store.set('lootOpen', openGroups);
          const q = pane.querySelector('[data-ref="lq"]').value;
          renderShell(p);
          pane.querySelector('[data-ref="lq"]').value = q;
          return;
        }
        const ent = e.target.closest('[data-e]');
        if (ent) {
          const [ci, ii] = ent.dataset.e.split(':').map(Number);
          const it = COLLECTIONS[ci].items[ii];
          return search(it.q, it.kind, ent.dataset.e);
        }
        const kb = e.target.closest('[data-kind]');
        if (kb) {
          kind = kb.dataset.kind;
          store.set('lootKind', kind);
          results = [];
          status = 'Type a name and press Search.';
          activeEntry = null;
          paint();
          pane.querySelector('[data-ref="lq"]').focus();
          return;
        }
        if (e.target.closest('[data-act="lsearch"]')) return search(pane.querySelector('[data-ref="lq"]').value);
        const c = e.target.closest('.lcard');
        if (!c) return;
        const r = results[Number(c.dataset.i)];
        const b = e.target.closest('[data-a]');
        act(b ? b.dataset.a : PRIMARY[kind], r, c);
      });
      p.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && e.target.dataset.ref === 'lq') search(e.target.value);
      });
      p.addEventListener('change', (e) => {
        if (e.target.dataset.ref === 'qty') store.set('lootQty', Number(e.target.value) || 1);
      });
    },
    { first: true },
  );

  let last = 0;
  wenilla.on('frame', () => {
    const now = performance.now();
    if (now - last < 500 || !gm.isOpen() || gm.currentTab() !== 'loot') return;
    last = now;
    paintWho();
  });
}
