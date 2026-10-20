// dashboard.js: the GM panel's home tab. Toggle switches with status lights, sliders for speed
// and size, a gold control, one-click kits and the everyday actions, plus a strip that always
// says who the next command will land on (most GM commands act on your target, else on you).

const TOGGLES = [
  { id: 'gm', label: 'GM mode', tip: 'GM tag, no aggro, GM commands everywhere', on: '.gm on', off: '.gm off',
    match: [[/gm mode is (on|off)/i, (m) => m[1]], [/gm mode (enabled|disabled)/i, (m) => m[1] === 'enabled']] },
  { id: 'invis', label: 'Invisible', tip: 'Hidden from players', on: '.gm visible off', off: '.gm visible on',
    match: [[/you are (?:now )?(invisible|visible)/i, (m) => m[1].toLowerCase() === 'invisible'], [/visibility.*\b(on|off)\b/i, (m) => m[1].toLowerCase() === 'off']] },
  { id: 'fly', label: 'Fly mode', tip: 'Fly through the air', on: '.gm fly on', off: '.gm fly off',
    match: [[/fly(?:ing)? mode.*\b(on|off|enabled|disabled)\b/i, (m) => /on|enabled/i.test(m[1])]] },
  { id: 'god', label: 'God mode', tip: 'Take no damage', on: '.gm unkillable on', off: '.gm unkillable off',
    match: [[/unkillable.*\b(on|off|enabled|disabled)\b/i, (m) => /on|enabled/i.test(m[1])]] },
  { id: 'badge', label: 'GM badge', tip: 'Blizzard GM tag on your chat lines', on: '.gm chat on', off: '.gm chat off',
    match: [[/gm chat.*\b(on|off)\b/i, (m) => m[1]]] },
  { id: 'whispers', label: 'Whispers', tip: 'Accept whispers from players', on: '.whispers on', off: '.whispers off',
    match: [[/accept\w* whispers.*\b(on|off)\b/i, (m) => m[1]]] },
  { id: 'taxi', label: 'All flights', tip: 'Every flight path unlocked (you or target)', on: '.taxicheat on', off: '.taxicheat off' },
  { id: 'water', label: 'Water walk', tip: 'Walk on water (you or target)', on: '.waterwalk on', off: '.waterwalk off' },
];

const SLIDERS = [
  { id: 'aspeed', label: 'Movement speed', cmd: '.modify aspeed', min: 1, max: 10, step: 0.5, def: 1, ticks: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], unit: '×' },
  { id: 'swim', label: 'Swim speed', cmd: '.modify swim', min: 1, max: 10, step: 0.5, def: 1, ticks: [1, 2, 4, 6, 8, 10], unit: '×' },
  { id: 'scale', label: 'Model size', cmd: '.modify scale', min: 0.5, max: 5, step: 0.1, def: 1, ticks: [0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5], unit: '×' },
];

const KITS = [
  { label: 'Hearthstone', cmd: '.additem 6948 1', tip: 'Hearth home' },
  { label: 'Runecloth Bags ×4', cmd: '.additem 14046 4', tip: '14-slot bags' },
  { label: 'Major Healing ×5', cmd: '.additem 13446 5', tip: 'Major Healing Potion' },
  { label: 'Major Mana ×5', cmd: '.additem 13444 5', tip: 'Major Mana Potion' },
  { label: 'Runecloth Bandage ×20', cmd: '.additem 14530 20', tip: 'Heavy Runecloth Bandage' },
  { label: 'Swiftness Potion ×5', cmd: '.additem 2459 5', tip: 'Run faster for a short time' },
];

const CSS = `
#gmp .dash{display:grid;grid-template-columns:1.15fr 1fr;gap:12px;align-content:start}
#gmp .dash .wide{grid-column:1/-1}
#gmp .applies{display:flex;align-items:center;gap:10px;padding:7px 12px;border:1px solid #3a362e;border-radius:5px;background:rgba(0,0,0,.45);font-size:13px}
#gmp .applies .who{font:bold 14px var(--wow);color:var(--gold)}
#gmp .applies .tag{font-size:11px;padding:1px 7px;border-radius:9px;border:1px solid #3d301a;color:var(--dim)}
#gmp .applies .tag.h{color:#ff8a6b;border-color:#6b2a1a}
#gmp .applies .tag.f{color:#9fdf9f;border-color:#2f5a2f}
#gmp .tgrid{display:grid;grid-template-columns:repeat(3,1fr);gap:8px}
#gmp .tog{display:flex;align-items:center;gap:9px;padding:9px 11px;border-radius:5px;font-size:13px;text-align:left;
  background:linear-gradient(180deg,#3d3a35,#22201c 55%,#151412)!important;border:1px solid #6e675b!important;box-shadow:inset 0 1px 0 rgba(255,255,255,.08),0 2px 4px rgba(0,0,0,.6)!important}
#gmp .tog:hover{border-color:#c9a24a!important;color:#fff}
#gmp .tog.on{border-color:#4f8a3a!important}
#gmp .tog:active{transform:translateY(1px)}
#gmp .led{width:12px;height:12px;border-radius:50%;flex:none;background:radial-gradient(circle at 35% 35%,#555,#1a1a1a);box-shadow:inset 0 0 2px #000,0 0 0 1px #000}
#gmp .tog.on .led{background:radial-gradient(circle at 35% 35%,#d9ffb0,#3fd23f 45%,#137a13);box-shadow:0 0 8px #3fd23f,0 0 0 1px #0a3a0a}
#gmp .tog.unk .led{background:radial-gradient(circle at 35% 35%,#7a6a40,#3a3020)}
#gmp .tog.busy .led{animation:gmpblink .5s infinite alternate}
@keyframes gmpblink{to{opacity:.35}}
#gmp .slider{margin:4px 0 12px}
#gmp .slider .top{display:flex;align-items:center;gap:8px;margin-bottom:2px}
#gmp .slider .top b{flex:1;font:13px var(--wow);color:var(--gold);text-align:center;text-shadow:1px 1px 0 #000}
#gmp .slider .val{min-width:44px;text-align:right;font:bold 12px ui-monospace,Consolas,monospace;color:var(--gold2)}
#gmp .slider .rs{padding:1px 7px;font-size:11px}
#gmp input[type=range].gr{-webkit-appearance:none;appearance:none;width:100%;height:22px;background:transparent;padding:0;border:0}
#gmp input[type=range].gr::-webkit-slider-runnable-track{height:8px;border-radius:5px;border:1px solid #000;
  background:linear-gradient(90deg,#c08a2c var(--p,0%),#2a2116 var(--p,0%));box-shadow:inset 0 1px 2px rgba(0,0,0,.8),0 1px 0 rgba(255,230,160,.08)}
#gmp input[type=range].gr::-webkit-slider-thumb{-webkit-appearance:none;width:18px;height:22px;margin-top:-8px;border-radius:4px;cursor:pointer;
  background:linear-gradient(180deg,#e8c37a,#8a6020);border:1px solid #2a1a05;box-shadow:0 2px 4px rgba(0,0,0,.6)}
#gmp input[type=range].gr::-moz-range-track{height:8px;border-radius:5px;background:#2a2116;border:1px solid #000}
#gmp input[type=range].gr::-moz-range-progress{height:8px;border-radius:5px;background:#c08a2c}
#gmp input[type=range].gr::-moz-range-thumb{width:16px;height:20px;border-radius:4px;background:linear-gradient(180deg,#e8c37a,#8a6020);border:1px solid #2a1a05}
#gmp .ticks{display:flex;justify-content:space-between;font-size:10.5px;color:var(--dim);padding:0 4px}
#gmp .agrid{display:grid;grid-template-columns:repeat(4,1fr);gap:8px}
#gmp .agrid button,#gmp .kgrid button{padding:8px 6px;font-size:13px}
#gmp .kgrid{display:grid;grid-template-columns:repeat(3,1fr);gap:8px}
#gmp .gold{display:flex;align-items:center;gap:6px;margin-bottom:10px;flex-wrap:wrap}
#gmp .gold input{width:110px;text-align:right}
#gmp .gold .coin{color:#ffd700;font-weight:bold}
#gmp .flash{animation:gmpflash .6s}
@keyframes gmpflash{from{box-shadow:0 0 0 2px var(--gold)}}
`;

export default function (gm) {
  gm.css(CSS);
  const { wenilla, esc, store } = gm;
  const state = store.get('toggles', {}); // id -> true/false (last known), missing = unknown
  let busy = {};

  // Server replies keep the lights honest when the server says what state it switched to.
  gm.onSystemMessage((text) => {
    const plain = text.replace(/\|c[0-9a-f]{8}|\|r/gi, '');
    for (const t of TOGGLES) {
      for (const [re, read] of t.match || []) {
        const m = plain.match(re);
        if (!m) continue;
        const v = read(m);
        state[t.id] = v === true || v === false ? v : /^(on|enabled)$/i.test(String(v));
        busy[t.id] = false;
        store.set('toggles', state);
        paintToggles();
        break;
      }
    }
  });

  let el = null;
  function target() {
    const s = wenilla.state;
    const t = s?.target;
    if (!t) return null;
    const unit = s.units?.find((u) => u.guid === t.guid);
    return { ...t, isPlayer: !!(t.isPlayer ?? unit?.isPlayer) };
  }

  function render(pane) {
    el = pane;
    const sliders = store.get('sliders', {});
    pane.innerHTML = `
      <div class="applies" data-ref="applies"></div>
      <div class="dash">
        <div class="dsec"><h4>Toggles <small>click to switch · light = last known state</small><span class="sp"></span>
          <button class="ghost" data-act="sync" title="Ask the server what is switched on right now">⟳ refresh</button></h4>
          <div class="tgrid">${TOGGLES.map((t) => `<button class="tog" data-tog="${t.id}" title="${esc(t.tip)}"><span class="led"></span>${esc(t.label)}</button>`).join('')}</div>
        </div>
        <div class="dsec"><h4>Sliders <small>applied when you let go · to target, else you</small><span class="sp"></span>
          <button class="ghost" data-act="normal" title="Speeds and size back to 1×">↺ all normal</button></h4>
          ${SLIDERS.map((sl) => {
            const v = sliders[sl.id] ?? sl.def;
            return `<div class="slider"><div class="top"><span style="width:44px"></span><b>${esc(sl.label)}</b><span class="val" data-val="${sl.id}">${v}${sl.unit}</span>
              <button class="rs" data-reset="${sl.id}" title="Back to ${sl.def}${sl.unit}">↺</button></div>
              <input type="range" class="gr" data-sl="${sl.id}" min="${sl.min}" max="${sl.max}" step="${sl.step}" value="${v}">
              <div class="ticks">${sl.ticks.map((t) => `<span>${t}${sl.unit}</span>`).join('')}</div></div>`;
          }).join('')}
        </div>
        <div class="dsec wide"><h4>Quick actions</h4>
          <div class="agrid">
            <button data-cmd=".tele gmisland" title="Teleport to GM Island">🏝 GM Island</button>
            <button data-act="savespot" title="Save where you stand (Locations tab)">📍 Save spot</button>
            <button data-act="goto" title="Teleport to your target">➜ Teleport to target</button>
            <button data-act="summon" title="Bring your target player to you">⇠ Summon target</button>
            <button data-macro="recover" title="Revive, reset cooldowns and repair gear (target or you)">✚ Revive & repair</button>
            <button data-cmd=".levelup 1" title="One level up (target or you)">⬆ Level up</button>
            <button data-cmd=".maxskill" title="Max all skills for the level (target or you)">★ Max skills</button>
            <button data-cmd=".learn all_myclass" title="Learn every spell and talent of your class">📖 All class spells</button>
          </div>
        </div>
        <div class="dsec wide"><h4>Kits & currency <small>items go to your target player, else to you</small></h4>
          <div class="gold">
            <span>Gold</span>
            <button data-gstep="-100">−100</button><button data-gstep="-10">−10</button>
            <input type="number" min="0" data-ref="gold" value="${store.get('goldAmt', 1000)}"><span class="coin">g</span>
            <button data-gstep="10">+10</button><button data-gstep="100">+100</button>
            <button class="primary" data-act="givegold">Give gold</button>
            <button data-act="takegold">Take gold</button>
          </div>
          <div class="kgrid">${KITS.map((k, i) => `<button data-kit="${i}" title="${esc(k.tip)}">${esc(k.label)}</button>`).join('')}</div>
          <div class="hint" style="margin-top:8px">Want anything else? The <b>Loot</b> tab finds any item, set, NPC or spell. Click a result to get it.</div>
        </div>
      </div>`;
    for (const r of pane.querySelectorAll('input[type=range]')) paintRange(r);
    paintToggles();
    paintApplies();
  }

  function paintRange(r) {
    const p = ((r.value - r.min) / (r.max - r.min)) * 100;
    r.style.setProperty('--p', p + '%');
  }

  function paintToggles() {
    if (!el) return;
    for (const b of el.querySelectorAll('[data-tog]')) {
      const id = b.dataset.tog;
      b.classList.toggle('on', state[id] === true);
      b.classList.toggle('unk', state[id] === undefined);
      b.classList.toggle('busy', !!busy[id]);
    }
  }

  function paintApplies() {
    const box = el?.querySelector('[data-ref="applies"]');
    if (!box) return;
    const s = wenilla.state;
    const t = target();
    if (!s?.self) {
      box.innerHTML = `<span class="who">Not in the world</span><span class="hint">Log in a character: commands are queued until you are.</span>`;
      return;
    }
    box.innerHTML = t
      ? `Applies to <span class="who">${esc(t.name ?? t.guid)}</span><span class="tag">L${t.level ?? '?'}</span>
         <span class="tag ${t.hostile ? 'h' : t.friendly ? 'f' : ''}">${t.isPlayer ? 'player' : t.hostile ? 'hostile' : t.friendly ? 'friendly' : 'neutral'}</span>
         <span class="sp"></span><span class="hint">${Math.round(t.dist ?? 0)} yd</span><button data-act="cleartarget" title="Clear target so commands apply to you">✕ clear target</button>`
      : `Applies to <span class="who">you · ${esc(s.self.name ?? '')}</span><span class="tag">L${s.self.level ?? '?'}</span><span class="sp"></span>
         <span class="hint">Select a player or NPC in the game to aim commands at them.</span>`;
  }

  function flash(b) {
    b.classList.remove('flash');
    void b.offsetWidth;
    b.classList.add('flash');
  }

  function onClick(e) {
    const b = e.target.closest('button');
    if (!b || !el?.contains(b)) return;
    flash(b);
    const d = b.dataset;
    if (d.tog) {
      const t = TOGGLES.find((x) => x.id === d.tog);
      const next = state[t.id] !== true;
      state[t.id] = next;
      busy[t.id] = !!t.match;
      store.set('toggles', state);
      gm.send(next ? t.on : t.off);
      setTimeout(() => ((busy[t.id] = false), paintToggles()), 2500);
      return paintToggles();
    }
    if (d.cmd) return gm.send(d.cmd);
    if (d.kit) return gm.send(KITS[Number(d.kit)].cmd);
    if (d.macro === 'recover') return ['.revive', '.cooldown clear', '.repairitems'].forEach((c, i) => setTimeout(() => gm.send(c), i * 300));
    if (d.reset) {
      const sl = SLIDERS.find((x) => x.id === d.reset);
      const r = el.querySelector(`[data-sl="${sl.id}"]`);
      r.value = sl.def;
      return applySlider(r);
    }
    if (d.gstep) {
      const inp = el.querySelector('[data-ref="gold"]');
      inp.value = Math.max(0, (Number(inp.value) || 0) + Number(d.gstep));
      return store.set('goldAmt', Number(inp.value));
    }
    const gold = () => Math.max(0, Math.round(Number(el.querySelector('[data-ref="gold"]').value) || 0));
    switch (d.act) {
      case 'sync':
        ['.gm', '.gm visible', '.gm chat'].forEach((c, i) => setTimeout(() => gm.send(c), i * 300));
        break;
      case 'normal':
        for (const sl of SLIDERS) {
          const r = el.querySelector(`[data-sl="${sl.id}"]`);
          r.value = sl.def;
          applySlider(r, false);
        }
        SLIDERS.forEach((sl, i) => setTimeout(() => gm.send(`${sl.cmd} ${sl.def}`), i * 300));
        break;
      case 'givegold':
        if (gold()) gm.send(`.modify money ${gold() * 10000}`);
        store.set('goldAmt', gold());
        break;
      case 'takegold':
        if (gold()) gm.send(`.modify money -${gold() * 10000}`);
        break;
      case 'savespot': {
        const h = gm.here();
        const name = `${h?.subzone || h?.zone || 'Spot'} ${new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`;
        gm.saveLocation(name);
        break;
      }
      case 'goto': {
        const t = target();
        if (!t?.name) return gm.log('Select a target first.');
        gm.send(t.isPlayer ? `.goname ${t.name}` : `.go creature ${t.name}`);
        break;
      }
      case 'summon': {
        const t = target();
        if (!t?.name || !t.isPlayer) return gm.log('Select a player to summon.');
        gm.send(`.namego ${t.name}`);
        break;
      }
      case 'cleartarget':
        wenilla.lua('ClearTarget()').catch(() => {});
        break;
    }
  }

  function applySlider(r, sendIt = true) {
    const sl = SLIDERS.find((x) => x.id === r.dataset.sl);
    const v = Number(r.value);
    el.querySelector(`[data-val="${sl.id}"]`).textContent = v + sl.unit;
    paintRange(r);
    const all = store.get('sliders', {});
    all[sl.id] = v;
    store.set('sliders', all);
    if (sendIt) gm.send(`${sl.cmd} ${v}`);
  }

  gm.addTab(
    'home',
    'Dashboard',
    (pane) => {
      if (el !== pane || !pane.firstElementChild) {
        render(pane);
        pane.addEventListener('click', onClick);
        pane.addEventListener('input', (e) => {
          const r = e.target.closest('input[type=range]');
          if (!r) return;
          const sl = SLIDERS.find((x) => x.id === r.dataset.sl);
          el.querySelector(`[data-val="${sl.id}"]`).textContent = r.value + sl.unit;
          paintRange(r);
        });
        pane.addEventListener('change', (e) => {
          const r = e.target.closest('input[type=range]');
          if (r) applySlider(r);
          if (e.target.dataset.ref === 'gold') store.set('goldAmt', Number(e.target.value) || 0);
        });
      } else {
        paintToggles();
        paintApplies();
      }
    },
    { first: true },
  );

  let last = 0;
  wenilla.on('frame', () => {
    const now = performance.now();
    if (now - last < 400 || !gm.isOpen() || gm.currentTab() !== 'home') return;
    last = now;
    paintApplies();
  });
}
