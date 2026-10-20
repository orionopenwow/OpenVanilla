// ow/owdiag-checks.js — the Open Vanilla self-test list (run by owdiag.js).
//
// Each check: { id, when?: [screens], level?: 'full', timeout?, run(ctx) }.
//   run returns true (pass), a string (fail: one short reason) or { warn: 'reason' }.
//   ctx: { wenilla, lua(chunk) -> [values], sleep(ms), screen(), errors, failed }
// Screens: 'login' | 'charselect' | 'charcreate' | 'inworld'.
//
// Rule of thumb: every bug that gets fixed adds a check here that would have caught it.

// Weapon skills each class should have from level 1 on every race (classicplus_weapons.sql).
const WEAPONS = {
  WARRIOR: ['Swords', 'Axes', 'Bows', 'Guns', 'Maces', 'Two-Handed Swords', 'Staves', 'Two-Handed Maces', 'Two-Handed Axes', 'Daggers', 'Thrown', 'Crossbows', 'Polearms', 'Fist Weapons'],
  PALADIN: ['Swords', 'Axes', 'Maces', 'Two-Handed Swords', 'Two-Handed Maces', 'Two-Handed Axes', 'Polearms'],
  HUNTER: ['Swords', 'Axes', 'Bows', 'Guns', 'Two-Handed Swords', 'Staves', 'Two-Handed Axes', 'Daggers', 'Thrown', 'Crossbows', 'Polearms', 'Fist Weapons'],
  ROGUE: ['Swords', 'Bows', 'Guns', 'Maces', 'Daggers', 'Thrown', 'Crossbows', 'Fist Weapons'],
  PRIEST: ['Maces', 'Staves', 'Daggers', 'Wands'],
  SHAMAN: ['Axes', 'Maces', 'Staves', 'Two-Handed Maces', 'Two-Handed Axes', 'Daggers', 'Fist Weapons'],
  MAGE: ['Swords', 'Staves', 'Daggers', 'Wands'],
  WARLOCK: ['Swords', 'Staves', 'Daggers', 'Wands'],
  DRUID: ['Maces', 'Staves', 'Two-Handed Maces', 'Daggers', 'Fist Weapons'],
};

// Lua error capture, installed once per UI VM (a /reload makes a new one).
const LUA_ERRORS = `
  if not OWDIAG then
    OWDIAG = { n = 0, list = {} }
    local prev = geterrorhandler and geterrorhandler()
    if seterrorhandler then
      seterrorhandler(function(msg)
        OWDIAG.n = OWDIAG.n + 1
        if table.getn(OWDIAG.list) < 5 then table.insert(OWDIAG.list, tostring(msg)) end
        if prev then return prev(msg) end
      end)
    end
  end
  return OWDIAG.n, table.concat(OWDIAG.list, " || ")`;

export const CHECKS = [
  // -- Page --------------------------------------------------------------------------------
  {
    id: 'page.webgpu',
    async run() {
      if (!navigator.gpu) return 'no navigator.gpu';
      const a = await navigator.gpu.requestAdapter();
      return a ? true : 'no WebGPU adapter';
    },
  },
  { id: 'page.bridge', run: ({ wenilla }) => (wenilla.ready ? true : 'bridge never said ready') },
  {
    id: 'page.errors',
    run: ({ errors }) => {
      const n = [...errors.values()].reduce((a, b) => a + b, 0);
      return n === 0 ? true : `${n} page error(s), first: ${[...errors.keys()][0]}`;
    },
  },
  {
    id: 'page.requests',
    run: ({ failed }) => (failed.size === 0 ? true : `${failed.size} failed: ${[...failed].slice(0, 3).map(([u, s]) => `${s} ${u}`).join(', ')}`),
  },
  {
    // Nothing of the page may sit over the minimap (top-right) — the old account bar did.
    id: 'page.minimap-clear',
    run() {
      const w = innerWidth;
      for (const [x, y] of [[w - 12, 6], [w - 80, 10], [w - 140, 40], [w - 60, 90]]) {
        const top = document.elementFromPoint(x, y);
        if (top && top.id !== 'benilla' && !top.closest('#ow-login-backdrop')) return `#${top.id || top.tagName} covers the minimap at ${x},${y}`;
      }
      return true;
    },
  },
  { id: 'page.dock', run: () => (document.getElementById('ow-dock') ? true : { warn: 'account dock missing (openvanilla.js not loaded?)' }) },
  {
    id: 'page.fps',
    timeout: 5000,
    async run({ sleep }) {
      let n = 0, on = true;
      const tick = () => { n++; if (on) requestAnimationFrame(tick); };
      requestAnimationFrame(tick);
      await sleep(2000);
      on = false;
      const fps = n / 2;
      if (document.hidden) return { warn: 'tab hidden, fps not measured' };
      if (fps < 10) return `fps ${fps}`;
      return fps < 30 ? { warn: `fps ${fps}` } : true;
    },
  },

  // -- Login -------------------------------------------------------------------------------
  {
    id: 'login.backdrop',
    when: ['login'],
    run() {
      const b = document.getElementById('ow-login-backdrop');
      if (!b) return 'no #ow-login-backdrop';
      if (b.classList.contains('is-hidden')) return 'backdrop hidden on the login screen';
      const v = b.querySelector('video');
      if (v && v.paused && !matchMedia('(prefers-reduced-motion: reduce)').matches) return { warn: 'video paused (autoplay blocked?)' };
      return true;
    },
  },

  // -- World -------------------------------------------------------------------------------
  {
    id: 'world.self',
    when: ['inworld'],
    run: ({ wenilla }) => (wenilla.state?.self ? (wenilla.state.zone ? true : { warn: 'no zone yet' }) : 'no player in the snapshot'),
  },
  {
    id: 'lua.errors',
    when: ['inworld', 'charselect'],
    async run({ lua }) {
      const [n, first] = await lua(LUA_ERRORS);
      return n > 0 ? `${n} Lua error(s): ${String(first).slice(0, 160)}` : true;
    },
  },
  {
    id: 'lua.suite',
    when: ['inworld'],
    async run({ lua }) {
      const [core, persona, defs] = await lua('return WenillaCore ~= nil, Persona ~= nil, ClassicPlus_Defaults ~= nil');
      const missing = [!core && 'WenillaCore', !persona && 'Persona', !defs && 'Defaults'].filter(Boolean);
      return missing.length ? `not loaded: ${missing.join(', ')}` : true;
    },
  },
  {
    id: 'lua.defaults',
    when: ['inworld'],
    async run({ lua }) {
      const [text, loot, cam, accept] = await lua(
        'return QUEST_FADING_DISABLE, GetCVar("autoLootDefault"), GetCVar("cameraDistanceMaxFactor"), ClassicPlus_Defaults and ClassicPlus_Defaults.autoAccept ~= false');
      const off = [text !== '1' && 'instant quest text', loot !== '1' && 'auto loot', !(Number(cam) >= 2) && 'camera zoom', !accept && 'auto-accept'].filter(Boolean);
      // A player may turn these off on purpose, so only a warning.
      return off.length ? { warn: `off: ${off.join(', ')}` } : true;
    },
  },
  {
    id: 'skills.weapons',
    when: ['inworld'],
    async run({ lua }) {
      const [cls, list] = await lua(`
        local _, cls = UnitClass("player")
        if ExpandSkillHeader then ExpandSkillHeader(0) end
        local names = {}
        for i = 1, GetNumSkillLines() do
          local name, header = GetSkillLineInfo(i)
          if name and not header then table.insert(names, name) end
        end
        return cls, table.concat(names, "|")`);
      const want = WEAPONS[cls];
      if (!want) return { warn: `unknown class ${cls}` };
      const have = new Set(String(list).split('|'));
      const missing = want.filter((w) => !have.has(w));
      return missing.length ? `${cls} missing ${missing.join(', ')}` : true;
    },
  },

  // -- Scenarios (level 'full'): they move the character and open panels --------------------
  {
    id: 'scenario.move',
    when: ['inworld'],
    level: 'full',
    async run({ wenilla, sleep }) {
      const a = wenilla.state?.self?.pos;
      if (!a) return 'no position';
      wenilla.hold('MOVEFORWARD');
      await sleep(1500);
      wenilla.release('MOVEFORWARD');
      await sleep(300);
      const b = wenilla.state?.self?.pos;
      const d = Math.hypot(b[0] - a[0], b[1] - a[1]);
      wenilla.hold('MOVEBACKWARD');
      await sleep(1500);
      wenilla.release('MOVEBACKWARD');
      return d > 2 ? true : `moved only ${d.toFixed(1)} yd in 1.5 s`;
    },
  },
  {
    id: 'scenario.panels',
    when: ['inworld'],
    level: 'full',
    async run({ lua, sleep }) {
      const panels = [
        ['ToggleCharacter("PaperDollFrame")', 'PaperDollFrame'],
        ['ToggleQuestLog()', 'QuestLogFrame'],
        ['ToggleSpellBook(BOOKTYPE_SPELL)', 'SpellBookFrame'],
        ['ToggleFriendsFrame()', 'FriendsFrame'],
        ['if SlashCmdList.PERSONA then SlashCmdList.PERSONA("edit") end', 'PersonaFrame'],
      ];
      const bad = [];
      const [before] = await lua(LUA_ERRORS);
      for (const [open, frame] of panels) {
        const [shown] = await lua(`pcall(function() ${open} end) local f = getglobal("${frame}") return f and f:IsVisible() and 1 or 0`);
        await sleep(150);
        await lua(`local f = getglobal("${frame}") if f and f:IsVisible() then HideUIPanel(f) f:Hide() end`);
        if (!shown) bad.push(frame);
      }
      const [after, msg] = await lua(LUA_ERRORS);
      if (after > before) bad.push(`${after - before} Lua error(s): ${String(msg).slice(0, 120)}`);
      return bad.length ? `did not open: ${bad.join(', ')}` : true;
    },
  },
];
