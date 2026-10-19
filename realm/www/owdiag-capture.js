// ow/owdiag-capture.js — Herald's data routines: read the game state into compact JSON.
//
//   await owdiag.capture()                     every routine
//   await owdiag.capture(['self', 'skills'])   just these
//
// No screenshots, no model calls: each routine is one Lua round trip (or a JS read) that returns
// short strings, parsed here into small objects. The whole capture is a few KB, so a person, a
// script or an agent can read a full game snapshot for the price of a log line.
//
// Each routine: { id, when?: [screens], run(ctx) -> object }. ctx is owdiag's
// { wenilla, lua(chunk) -> [values], sleep(ms), screen() }. Lua chunks follow the 1.12 rules
// (Lua 5.0: no '#', no '%', no select()). Routines need the world: the character screens in this
// client are native, with no Lua VM.

import { ROUTINE as LOAD } from './owdiag-load.js';

const split = (s, sep = '|') => (s ? String(s).split(sep).filter(Boolean) : []);

export const ROUTINES = [
  {
    id: 'self',
    when: ['inworld'],
    async run({ lua, wenilla }) {
      const [name, race, cls, level, xp, xpMax, money, zone, sub, x, y, hp, hpMax, mp, mpMax, guild, rested] = await lua(`
        local x, y = GetPlayerMapPosition("player")
        local _, race = UnitRace("player")
        local _, cls = UnitClass("player")
        return UnitName("player"), race, cls, UnitLevel("player"), UnitXP("player"), UnitXPMax("player"),
          GetMoney(), GetZoneText(), GetSubZoneText(), math.floor((x or 0) * 1000) / 10, math.floor((y or 0) * 1000) / 10,
          UnitHealth("player"), UnitHealthMax("player"), UnitMana("player"), UnitManaMax("player"),
          (GetGuildInfo("player")) or "", GetXPExhaustion() or 0`);
      const pos = wenilla.state?.self?.pos;
      return {
        name, race, class: cls, level, xp: `${xp}/${xpMax}`, rested, copper: money, zone, sub,
        map: [x, y], world: pos ? pos.map((v) => Math.round(v * 10) / 10) : null,
        hp: `${hp}/${hpMax}`, power: `${mp}/${mpMax}`, guild: guild || null,
      };
    },
  },
  {
    id: 'skills',
    when: ['inworld'],
    async run({ lua }) {
      const [list] = await lua(`
        if ExpandSkillHeader then ExpandSkillHeader(0) end
        local out, head = {}, ""
        for i = 1, GetNumSkillLines() do
          local name, header, _, rank, _, _, max = GetSkillLineInfo(i)
          if header then head = name
          elseif name then table.insert(out, head .. ">" .. name .. "=" .. (rank or 0) .. "/" .. (max or 0)) end
        end
        return table.concat(out, "|")`);
      const by = {};
      for (const row of split(list)) {
        const [head, rest] = row.split('>');
        const [skill, val] = rest.split('=');
        (by[head] ||= {})[skill] = val;
      }
      return by;
    },
  },
  {
    id: 'gear',
    when: ['inworld'],
    async run({ lua }) {
      const [list] = await lua(`
        local out = {}
        for slot = 1, 19 do
          local link = GetInventoryItemLink("player", slot)
          if link then
            local _, _, id = string.find(link, "item:(%d+)")
            local _, _, name = string.find(link, "%[(.-)%]")
            table.insert(out, slot .. "=" .. (id or "?") .. ":" .. (name or "?"))
          end
        end
        return table.concat(out, "|")`);
      const slots = {};
      for (const row of split(list)) {
        const [slot, rest] = row.split('=');
        const i = rest.indexOf(':');
        slots[slot] = { id: Number(rest.slice(0, i)), name: rest.slice(i + 1) };
      }
      return slots;
    },
  },
  {
    id: 'bags',
    when: ['inworld'],
    async run({ lua }) {
      const [list, free] = await lua(`
        local out, counts, names, free = {}, {}, {}, 0
        for bag = 0, 4 do
          for slot = 1, GetContainerNumSlots(bag) do
            local link = GetContainerItemLink(bag, slot)
            if link then
              local _, n = GetContainerItemInfo(bag, slot)
              local _, _, id = string.find(link, "item:(%d+)")
              local _, _, name = string.find(link, "%[(.-)%]")
              if id then counts[id] = (counts[id] or 0) + (n or 1); names[id] = name end
            else free = free + 1 end
          end
        end
        for id, n in pairs(counts) do table.insert(out, id .. "x" .. n .. ":" .. (names[id] or "?")) end
        return table.concat(out, "|"), free`);
      return {
        free,
        items: split(list).map((r) => {
          const [idn, name] = [r.slice(0, r.indexOf(':')), r.slice(r.indexOf(':') + 1)];
          const [id, n] = idn.split('x');
          return { id: Number(id), n: Number(n), name };
        }),
      };
    },
  },
  {
    id: 'spells',
    when: ['inworld'],
    async run({ lua }) {
      const [tabs] = await lua(`
        local out = {}
        for t = 1, GetNumSpellTabs() do
          local name, _, offset, n = GetSpellTabInfo(t)
          local spells = {}
          for i = offset + 1, offset + n do
            local s, r = GetSpellName(i, BOOKTYPE_SPELL)
            if s then table.insert(spells, s .. ((r and r ~= "") and (" (" .. r .. ")") or "")) end
          end
          table.insert(out, name .. ">" .. table.concat(spells, ";"))
        end
        return table.concat(out, "|")`);
      const by = {};
      for (const row of split(tabs)) {
        const [tab, list] = row.split('>');
        by[tab] = split(list, ';');
      }
      return by;
    },
  },
  {
    id: 'quests',
    when: ['inworld'],
    async run({ lua }) {
      const [list] = await lua(`
        local out = {}
        for i = 1, GetNumQuestLogEntries() do
          local title, level, tag, header, _, complete = GetQuestLogTitle(i)
          if title and not header then
            table.insert(out, level .. ":" .. title .. ((complete == 1) and ":done" or ((complete == -1) and ":failed" or "")))
          end
        end
        return table.concat(out, "|")`);
      return split(list);
    },
  },
  {
    id: 'suite',
    when: ['inworld'],
    async run({ lua }) {
      const [states, connected, persona, defaults, mem] = await lua(`
        local W = WenillaCore
        local out = {}
        if W and W.ADDONS then
          for _, id in ipairs(W.ADDONS) do table.insert(out, id .. "=" .. (W:IsActive(id) and "on" or "off")) end
        end
        return table.concat(out, "|"), (W and W.connected) and 1 or 0, Persona and Persona.version or "",
          ClassicPlus_Defaults and 1 or 0, gcinfo and gcinfo() or 0`);
      const addons = {};
      for (const r of split(states)) { const [k, v] = r.split('='); addons[k] = v; }
      return { addons, serverHook: connected === 1, persona: persona || null, defaults: defaults === 1, luaKB: mem };
    },
  },
  {
    // Herald keeps its own Persona and reports what the realm's profiles look like.
    id: 'persona',
    when: ['inworld'],
    async run({ lua }) {
      const [ver, mine, status, cached, lfrp] = await lua(`
        if not Persona then return "" end
        local p = Persona.Mine()
        if (p.name or "") == "" and (p.title or "") == "" then
          p.name = "Herald"
          p.title = "Chronicler of Open Vanilla"
          p.currently = "Walking the realm and writing down what works."
          p.bio = "Herald is Open Vanilla's test character. It signs in on its own, checks that the world, the addons and the shops behave, and reports back."
          p.status = "ooc"
          p.rev = (p.rev or 0) + 1
        end
        local n, l = 0, 0
        for _, q in pairs(Persona_DB.cache[GetRealmName()] or {}) do
          n = n + 1
          if q.status == "lfrp" or q.status == "st" then l = l + 1 end
        end
        return Persona.version, (p.name or "") .. " <" .. (p.title or "") .. ">", p.status or "", n, l`);
      return ver ? { version: ver, mine, status, profilesSeen: cached, lookingForRP: lfrp } : { note: 'Persona not loaded' };
    },
  },
  {
    // Who is around: tab-target up to six enemies, then the player list from /who isn't used
    // (it would spam the chat); the world snapshot's own unit count when the bridge has one.
    id: 'nearby',
    when: ['inworld'],
    async run({ lua, wenilla }) {
      const [list] = await lua(`
        local out, seen = {}, {}
        for i = 1, 6 do
          TargetNearestEnemy()
          local n = UnitName("target")
          if not n or seen[n] then break end
          seen[n] = 1
          table.insert(out, n .. ":" .. (UnitLevel("target") or 0) .. ":" .. (UnitClassification("target") or "") .. ":"
            .. math.floor(100 * (UnitHealth("target") or 0) / math.max(1, UnitHealthMax("target") or 1)))
        end
        ClearTarget()
        return table.concat(out, "|")`);
      const st = wenilla.state || {};
      const units = Array.isArray(st.units) ? st.units.length : (st.units && typeof st.units === 'object' ? Object.keys(st.units).length : null);
      return { enemies: split(list), units };
    },
  },
  {
    id: 'settings',
    when: ['inworld'],
    async run({ lua }) {
      const [cvars] = await lua(`
        local out = {}
        for _, k in ipairs({ "autoLootDefault", "cameraDistanceMaxFactor", "autoSelfCast", "showLootSpam", "farclip", "gxResolution",
          "UnitNameNPC", "UnitNamePlayer", "UnitNameOwn", "UnitNamePlayerGuild", "UnitNamePlayerPVPTitle" }) do
          local ok, v = pcall(GetCVar, k)
          table.insert(out, k .. "=" .. (ok and tostring(v) or "?"))
        end
        return table.concat(out, "|")`);
      const o = {};
      for (const r of split(cvars)) { const [k, v] = r.split('='); o[k] = v; }
      return o;
    },
  },
];

ROUTINES.push(LOAD);   // load times and bytes (owdiag-load.js)
