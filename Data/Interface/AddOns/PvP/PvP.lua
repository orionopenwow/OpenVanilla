--[[
    PvP.lua  (Open Vanilla)
    The arena helpers players reach for most, as our own code (modes roadmap Phase 3, art pass 3a picks):
      Arena card     (B) your enemy's portrait, name, class and health right of the target frame
      Enemy cooldowns (A) one row under the card: what they've used and when it's back
      Big CC         (B) crowd control on a portrait, a sweep and the seconds left (theirs and yours)
      DR tracker     (A) icons under the card: the next stun / fear / ... lasts ½, ¼ or not at all
      Cast bar       (B) Castline's target bar, bigger, red when you can't interrupt it right now
    Cooldown numbers (A) are Essentials' (big and centred on every button) and stay as they are.

    1.12 gives no aura durations and no cooldowns of other players, so:
      * cooldowns start when the combat log says the enemy used the ability (PvP.COOLDOWNS);
      * crowd control is seen on UnitDebuff by its icon (PvP.CC), timed from when it appears, with
        the diminishing return applied; it ends when the icon goes.
    Diminishing returns: each category's second hit lasts half, the third a quarter, then immune,
    until 18 s pass without one.
    Lua 5.0 rules: no #, no %, this/arg1 in scripts.
]]--

local W = WenillaCore
local UI = W.UI

PvP = PvP or {}
local P = PvP
local getn, strfind, strlower = table.getn, string.find, string.lower

P.DR_RESET = 18
P.DR_FACTOR = { 1, 0.5, 0.25, 0 }

-- ability -> cooldown in seconds, by class (the ones that decide a duel)
P.COOLDOWNS = {
    ROGUE = { Vanish = 300, Blind = 300, Evasion = 300, Sprint = 300, Preparation = 600, Kick = 10, ["Kidney Shot"] = 20,
        Gouge = 10, ["Cold Blood"] = 180 },
    MAGE = { Blink = 15, Counterspell = 30, ["Ice Block"] = 300, ["Frost Nova"] = 25, ["Cold Snap"] = 600,
        ["Presence of Mind"] = 180, ["Cone of Cold"] = 10 },
    WARRIOR = { Intercept = 15, Charge = 15, Pummel = 10, ["Shield Bash"] = 12, ["Intimidating Shout"] = 180,
        ["Berserker Rage"] = 30, ["Death Wish"] = 180, Disarm = 60, Recklessness = 1800, ["Shield Wall"] = 1800 },
    PRIEST = { ["Psychic Scream"] = 30, Silence = 45, Fade = 30, ["Desperate Prayer"] = 600, ["Power Infusion"] = 180,
        ["Inner Focus"] = 180 },
    WARLOCK = { ["Death Coil"] = 120, ["Howl of Terror"] = 40, ["Spell Lock"] = 24, Shadowburn = 15 },
    HUNTER = { ["Scatter Shot"] = 30, ["Freezing Trap"] = 15, ["Feign Death"] = 30, Deterrence = 300, Intimidation = 60,
        ["Rapid Fire"] = 300 },
    PALADIN = { ["Hammer of Justice"] = 60, ["Divine Shield"] = 300, ["Blessing of Protection"] = 300,
        ["Blessing of Freedom"] = 20, ["Lay on Hands"] = 3600, Repentance = 60 },
    SHAMAN = { ["Earth Shock"] = 6, ["Grounding Totem"] = 15, ["Nature's Swiftness"] = 180, ["Elemental Mastery"] = 180,
        Stormstrike = 20 },
    DRUID = { Bash = 60, Barkskin = 60, ["Nature's Swiftness"] = 180, Innervate = 360, ["Feral Charge"] = 15, Dash = 300,
        ["Nature's Grasp"] = 60 },
}
-- every ability -> its cooldown, for a caster whose class isn't known yet
P.ANY = {}
for _, list in pairs(P.COOLDOWNS) do for name, s in pairs(list) do P.ANY[name] = s end end

-- crowd control by the icon UnitDebuff returns (the part after Interface\Icons\): name, category, seconds
P.CC = {
    Spell_Nature_Polymorph = { "Polymorph", "incap", 10 },
    Ability_Sap = { "Sap", "incap", 10 },
    Ability_Gouge = { "Gouge", "incap", 4 },
    Ability_GolemStormBolt = { "Scatter Shot", "incap", 4 },
    Spell_Frost_ChainsOfIce = { "Freezing Trap", "incap", 10 },
    Spell_Nature_Sleep = { "Hibernate", "incap", 10 },
    Ability_Rogue_KidneyShot = { "Kidney Shot", "stun", 6 },
    Ability_CheapShot = { "Cheap Shot", "stun", 4 },
    Spell_Holy_SealOfMight = { "Hammer of Justice", "stun", 6 },
    Ability_Druid_Bash = { "Bash", "stun", 4 },
    Ability_ThunderBolt = { "Concussion Blow", "stun", 5 },
    Ability_Rogue_Sprint = { "Intercept", "stun", 3 },
    Spell_Shadow_Possession = { "Fear", "fear", 10 },
    Spell_Shadow_PsychicScream = { "Psychic Scream", "fear", 8 },
    Spell_Shadow_DeathScream = { "Howl of Terror", "fear", 8 },
    Ability_GolemThunderClap = { "Intimidating Shout", "fear", 8 },
    Spell_Shadow_MindSteal = { "Blind", "fear", 10 },
    Spell_Nature_StrangleVines = { "Entangling Roots", "root", 10 },
    Spell_Frost_FrostNova = { "Frost Nova", "root", 8 },
    Spell_Shadow_DeathCoil = { "Death Coil", "horror", 3 },
    Spell_Shadow_ImpPhaseShift = { "Silence", "silence", 5 },
}
P.CC_COLOR = { incap = { 0.7, 0.55, 1 }, stun = { 1, 0.25, 0.2 }, fear = { 0.75, 0.3, 1 }, root = { 0.3, 0.8, 0.3 },
    horror = { 0.6, 0.2, 0.6 }, silence = { 0.35, 0.6, 1 } }
P.CATEGORIES = { "stun", "fear", "incap", "root", "silence", "horror" }

-- the interrupt your class has (Castline's red bar: it's on cooldown or the cast can't be kicked)
P.INTERRUPT = { ROGUE = "Kick", WARRIOR = "Pummel", MAGE = "Counterspell", SHAMAN = "Earth Shock", PRIEST = "Silence",
    WARLOCK = "Spell Lock", PALADIN = "Hammer of Justice", DRUID = "Bash", HUNTER = "Scatter Shot" }

P.cds = {}      -- caster name -> { ability -> ready at (GetTime) }
P.dr = {}       -- unit name -> { category -> { n, last } }
P.cc = {}       -- unit name -> { icon -> { name, cat, start, dur } }

local function now() return GetTime() end
local function iconKey(tex)
    if not tex then return nil end
    local _, _, k = strfind(tex, "([^\\]+)$")
    return k
end

-- -- the combat log: who used what ------------------------------------------------------------------

P.PATTERNS = {
    "^(.+) casts (.+) on .+%.$", "^(.+) casts (.+)%.$", "^(.+) gains (.+)%.$", "^(.+) performs (.+) on .+%.$",
    "^(.+) performs (.+)%.$", "^(.+) begins to cast (.+)%.$", "^(.+) begins to perform (.+)%.$",
    "^(.+)'s (.+) hits", "^(.+)'s (.+) crits", "^(.+)'s (.+) was resisted", "^(.+)'s (.+) missed",
    "^(.+)'s (.+) was dodged", "^(.+)'s (.+) was parried", "^(.+)'s (.+) fails", "^(.+)'s (.+) is absorbed",
}

-- one combat log line -> caster, ability (only abilities with a cooldown we track)
function P.Parse(text)
    if not text then return nil end
    for _, pat in ipairs(P.PATTERNS) do
        local _, _, who, what = strfind(text, pat)
        if who and what and P.ANY[what] and who ~= "You" then return who, what end
    end
    return nil
end

function P.Used(who, what, class)
    local list = class and P.COOLDOWNS[class] or nil
    local s = (list and list[what]) or P.ANY[what]
    if not s then return end
    P.cds[who] = P.cds[who] or {}
    P.cds[who][what] = now() + s
    -- Preparation and Cold Snap give their class's other cooldowns back
    if what == "Preparation" then for k in pairs(P.cds[who]) do if k ~= "Preparation" then P.cds[who][k] = nil end end end
    if what == "Cold Snap" then
        for _, k in ipairs({ "Ice Block", "Frost Nova", "Cone of Cold" }) do P.cds[who][k] = nil end
    end
    P.Paint()
end

-- caster's cooldowns, soonest ready last: { { ability, seconds left } }
function P.Cooldowns(who)
    local out = {}
    for what, ready in pairs(P.cds[who or ""] or {}) do
        local left = ready - now()
        if left > 0 then table.insert(out, { what, left }) end
    end
    table.sort(out, function(a, b) return a[2] > b[2] end)
    return out
end

-- -- crowd control and diminishing returns --------------------------------------------------------

-- the DR factor the next CC of this category will get on this unit, and how many came before
function P.DrLevel(name, cat)
    local d = P.dr[name] and P.dr[name][cat]
    if not d or now() - d.last > P.DR_RESET then return 1, 0 end
    local n = math.min(d.n + 1, 4)
    return P.DR_FACTOR[n], d.n
end

-- look at a unit's debuffs: new CC starts a timer (with DR), gone CC ends it
function P.ScanUnit(unit)
    if not UnitExists(unit) then return end
    local name = UnitName(unit)
    if not name then return end
    local seen = {}
    for i = 1, 16 do
        local tex = UnitDebuff(unit, i)
        if not tex then break end
        local key = iconKey(tex)
        local def = key and P.CC[key]
        if def then
            seen[key] = true
            P.cc[name] = P.cc[name] or {}
            if not P.cc[name][key] then
                local factor = P.DrLevel(name, def[2])
                P.dr[name] = P.dr[name] or {}
                local d = P.dr[name][def[2]]
                if not d or now() - d.last > P.DR_RESET then d = { n = 0, last = 0 } end
                d.n, d.last = math.min(d.n + 1, 3), now()
                P.dr[name][def[2]] = d
                P.cc[name][key] = { name = def[1], cat = def[2], start = now(), dur = def[3] * factor, icon = tex }
            end
        end
    end
    for key, c in pairs(P.cc[name] or {}) do
        if not seen[key] then
            P.cc[name][key] = nil
            local d = P.dr[name] and P.dr[name][c.cat]
            if d then d.last = now() end            -- the DR window runs from when the CC ends
        end
    end
end

-- the longest CC on a unit now: { name, cat, left, dur, icon }
function P.ActiveCC(name)
    local best
    for _, c in pairs(P.cc[name or ""] or {}) do
        local left = c.start + c.dur - now()
        if left > 0 and (not best or left > best.left) then
            best = { name = c.name, cat = c.cat, left = left, dur = c.dur, icon = c.icon }
        end
    end
    return best
end

-- the DR icons to show for a unit: { { cat, text } } with text ½ / ¼ / immune
function P.DrIcons(name)
    local out = {}
    for _, cat in ipairs(P.CATEGORIES) do
        local factor, n = P.DrLevel(name, cat)
        if n > 0 then
            table.insert(out, { cat, factor == 0.5 and "1/2" or (factor == 0.25 and "1/4" or "immune") })
        end
    end
    return out
end

-- -- the card ------------------------------------------------------------------------------------

local card

local function classColor(unit)
    local _, class = UnitClass(unit)
    if UI.ClassColor then return UI.ClassColor(class) end
    return 1, 1, 1
end

local function ccRing(parent, size)
    local r = CreateFrame("Frame", nil, parent)
    r:SetWidth(size); r:SetHeight(size)
    r.edge = r:CreateTexture(nil, "OVERLAY")
    r.edge:SetPoint("TOPLEFT", r, "TOPLEFT", -3, 3)
    r.edge:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", 3, -3)
    r.edge:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    r.edge:SetBlendMode("ADD")
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetAllPoints(r)
    r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    local ok, cd = pcall(CreateFrame, "Model", nil, r, "CooldownFrameTemplate")
    if ok and cd then cd:SetAllPoints(r); r.sweep = cd end
    r.time = r:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    r.time:SetPoint("CENTER", r, "CENTER", 0, 0)
    r:Hide()
    return r
end

function P.Build()
    if card then return card end
    card = CreateFrame("Frame", "PvP_ArenaCard", UIParent)
    card:SetWidth(230); card:SetHeight(64)
    if TargetFrame then card:SetPoint("TOPLEFT", TargetFrame, "TOPRIGHT", -12, -8)
    else card:SetPoint("TOP", UIParent, "TOP", 140, -30) end
    UI.Skin(card, "panel")
    card.portrait = card:CreateTexture(nil, "ARTWORK")
    card.portrait:SetWidth(46); card.portrait:SetHeight(46)
    card.portrait:SetPoint("LEFT", card, "LEFT", 8, 0)
    card.ring = ccRing(card, 46)
    card.ring:SetPoint("CENTER", card.portrait, "CENTER", 0, 0)
    card.name = UI.Label(card, 12, UI.WHITE)
    card.name:SetPoint("TOPLEFT", card.portrait, "TOPRIGHT", 8, 2)
    card.info = UI.Label(card, 10, UI.MUTED)
    card.info:SetPoint("TOPRIGHT", card, "TOPRIGHT", -8, -8)
    card.hp = CreateFrame("StatusBar", nil, card)
    card.hp:SetStatusBarTexture(UI.BAR)
    card.hp:SetStatusBarColor(0.17, 0.7, 0.3)
    card.hp:SetMinMaxValues(0, 100)
    card.hp:SetWidth(162); card.hp:SetHeight(12)
    card.hp:SetPoint("TOPLEFT", card.name, "BOTTOMLEFT", 0, -3)
    card.hpText = UI.Label(card.hp, 9, UI.WHITE)
    card.hpText:SetPoint("RIGHT", card.hp, "RIGHT", -3, 0)
    -- enemy cooldowns: one row under the card
    card.cds = {}
    for i = 1, 6 do
        local b = UI.IconBox(card, 22)
        b:SetPoint("TOPLEFT", card, "BOTTOMLEFT", (i - 1) * 25, -3)
        b.time = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.time:SetPoint("CENTER", b, "CENTER", 0, 0)
        b:Hide()
        card.cds[i] = b
    end
    -- DR: icons right of the cooldowns
    card.drs = {}
    for i = 1, 4 do
        local b = UI.IconBox(card, 22)
        b:SetPoint("TOPRIGHT", card, "BOTTOMRIGHT", -(i - 1) * 25, -3)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        b.text:SetPoint("CENTER", b, "CENTER", 0, 0)
        b:Hide()
        card.drs[i] = b
    end
    card:Hide()
    -- your own crowd control, on your portrait
    if PlayerFrame then
        P.selfRing = ccRing(PlayerFrame, 52)
        P.selfRing:SetPoint("CENTER", PlayerPortrait or PlayerFrame, "CENTER", 0, 0)
    end
    card:SetScript("OnUpdate", function()
        this.elapsed = (this.elapsed or 0) + arg1
        if this.elapsed < 0.2 then return end
        this.elapsed = 0
        P.ScanUnit("target"); P.ScanUnit("player")
        P.Paint()
    end)
    return card
end

local function paintRing(r, c)
    if not r then return end
    if not c then r:Hide() return end
    local col = P.CC_COLOR[c.cat] or UI.WHITE
    r.edge:SetVertexColor(col[1], col[2], col[3])
    r.icon:SetTexture(c.icon)
    r.time:SetText(string.format("%.1f", c.left))
    if r.sweep and CooldownFrame_SetTimer and r.dur ~= c.dur then
        CooldownFrame_SetTimer(r.sweep, GetTime() - (c.dur - c.left), c.dur, 1)
        r.dur = c.dur
    end
    r:Show()
end

local function enemyPlayer(unit)
    return UnitExists(unit) and UnitIsPlayer(unit) and UnitCanAttack("player", unit)
end

function P.Paint()
    if not card then return end
    paintRing(P.selfRing, P.ActiveCC(UnitName("player")))
    if not enemyPlayer("target") then card:Hide() return end
    local name = UnitName("target")
    local _, class = UnitClass("target")
    local r, g, b = classColor("target")
    card.name:SetText(name or "")
    card.name:SetTextColor(r, g, b)
    card.info:SetText((UnitClass("target") or "") .. " · " .. (UnitLevel("target") or "?"))
    if SetPortraitTexture then SetPortraitTexture(card.portrait, "target") end
    local hp, max = UnitHealth("target") or 0, UnitHealthMax("target") or 100
    local pct = max > 0 and math.floor(hp * 100 / max) or 0
    card.hp:SetValue(pct)
    card.hpText:SetText(pct .. "%")
    paintRing(card.ring, P.ActiveCC(name))
    local cds = P.Cooldowns(name)
    for i, bx in ipairs(card.cds) do
        local c = cds[i]
        if c then
            bx.icon:SetTexture(P.Icon(c[1]))
            bx.time:SetText(c[2] >= 60 and (math.ceil(c[2] / 60) .. "m") or math.ceil(c[2]))
            bx:Show()
        else bx:Hide() end
    end
    local drs = P.DrIcons(name)
    for i, bx in ipairs(card.drs) do
        local d = drs[i]
        if d then
            local col = P.CC_COLOR[d[1]] or UI.WHITE
            bx.edge:SetTexture(col[1], col[2], col[3], 1)
            bx.text:SetText(d[2] == "immune" and "|cffff3030X|r" or d[2])
            bx:Show()
        else bx:Hide() end
    end
    card:Show()
    P.class = class
end

-- the icon of an ability, from the spellbook when the player has it, else a question mark
function P.Icon(spell)
    local i = 1
    while true do
        local n = GetSpellName(i, BOOKTYPE_SPELL)
        if not n then break end
        if n == spell then return GetSpellTexture(i, BOOKTYPE_SPELL) end
        i = i + 1
    end
    return UI.UNKNOWN_ICON
end

-- -- Castline's bar, big and red when you can't interrupt ---------------------------------------------

function P.CanInterrupt()
    local _, class = UnitClass("player")
    local spell = P.INTERRUPT[class or ""]
    if not spell then return false end
    local i = 1
    while true do
        local n = GetSpellName(i, BOOKTYPE_SPELL)
        if not n then return false end
        if n == spell then
            local start, dur = GetSpellCooldown(i, BOOKTYPE_SPELL)
            return not (start and start > 0 and dur and dur > 1.5)
        end
        i = i + 1
    end
end

function P.HookCastline()
    if not Castline or Castline.Paint then return end
    -- only against an enemy player; any other cast keeps Castline's own look
    Castline.Paint = function(c, sb, bar)
        if not (c and sb and bar) then return end
        if not enemyPlayer("target") then bar:SetScale(1) return end
        bar:SetScale(1.35)
        if not c.interruptible or not P.CanInterrupt() then sb:SetStatusBarColor(0.9, 0.15, 0.1) end
    end
end
P.HookCastline()

-- -- events ----------------------------------------------------------------------------------------

local function second(_, b) return b end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "CHAT_MSG_SPELL_HOSTILEPLAYER_DAMAGE", "CHAT_MSG_SPELL_HOSTILEPLAYER_BUFF",
    "CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_BUFFS", "CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE", "CHAT_MSG_SPELL_SELF_DAMAGE",
    "PLAYER_TARGET_CHANGED", "UNIT_AURA", "UNIT_HEALTH", "PLAYER_ENTERING_WORLD" }) do ev:RegisterEvent(e) end
ev:SetScript("OnEvent", function()
    if event == "PLAYER_ENTERING_WORLD" then P.Build(); P.HookCastline() return end
    if strfind(event, "^CHAT_MSG") then
        local who, what = P.Parse(arg1)
        if who then
            local class = (UnitName("target") == who) and second(UnitClass("target")) or nil
            P.Used(who, what, class)
        end
        return
    end
    if event == "UNIT_AURA" then if arg1 == "target" or arg1 == "player" then P.ScanUnit(arg1) end end
    P.Paint()
end)

P.Build()
