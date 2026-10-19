--[[
    Auras.lua  (Essentials)
    Time left on your target's buffs and debuffs. The 1.12 client tells addons nothing about
    other units' aura durations, so the clock starts when we see an aura go on:
        * the combat log: "Defias Thug is afflicted by Polymorph." / "Ann gains Renew." /
          "Polymorph fades from Defias Thug."
        * or the aura appearing in your target's list while you watch
    and counts down from AuraData.lua. Auras that were already up when you targeted the unit
    (and that the log did not show) get no number rather than a wrong one.
    Numbers show on the stock target frame's aura buttons and on the UI Repack's target frame.

    Lua 5.0 rules (1.12.1 client): no '#', no '%', handlers read this/event/arg1.
]]--

local E = Essentials
local W = WenillaCore
local UI = W.UI

E.auraStart = {}          -- unit name -> { [aura name] = GetTime() when it went on }
local seen = {}           -- unit name -> { [aura name] = true } as of the last look
local names = { debuff = {}, buff = {} }   -- target's aura names by index (from the tooltip)

local function pattern(global, fallback)
    local fmt = getglobal(global) or fallback
    local p = string.gsub(fmt, "([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    p = string.gsub(p, "%%s", "(.+)")
    p = string.gsub(p, "%%d", "(%%d+)")
    return "^" .. p .. "$"
end
local AFFLICTED = pattern("AURAADDEDOTHERHARMFUL", "%s is afflicted by %s.")
local GAINS = pattern("AURAADDEDOTHERHELPFUL", "%s gains %s.")
local FADES = pattern("AURAREMOVEDOTHER", "%s fades from %s.")

function E.AuraDuration(name) return name and E.AURA_DURATIONS and E.AURA_DURATIONS[name] end

local function started(unit, aura, t)
    if not (unit and aura and E.AuraDuration(aura)) then return end
    aura = string.gsub(aura, " %(%d+%)$", "")
    E.auraStart[unit] = E.auraStart[unit] or {}
    E.auraStart[unit][aura] = t or GetTime()
end
local function ended(unit, aura)
    if E.auraStart[unit] then E.auraStart[unit][aura] = nil end
end

-- Seconds left on a unit's aura, or nil when we do not know.
function E.AuraRemaining(unit, aura)
    local d = E.AuraDuration(aura)
    local t = E.auraStart[unit] and E.auraStart[unit][aura]
    if not (d and t) then return nil end
    local rem = t + d - GetTime()
    if rem <= 0 then return nil end
    return rem
end

-- -- Reading the target's auras ----------------------------------------------------------------

local function scanNames()
    names = { debuff = {}, buff = {} }
    if not UnitExists("target") then return end
    local tip = E.ScanTip()
    for i = 1, 16 do
        if not UnitDebuff("target", i) then break end
        tip:SetOwner(WorldFrame, "ANCHOR_NONE")
        tip:SetUnitDebuff("target", i)
        names.debuff[i] = E.TipLine(1)
    end
    for i = 1, 16 do
        if not UnitBuff("target", i) then break end
        tip:SetOwner(WorldFrame, "ANCHOR_NONE")
        tip:SetUnitBuff("target", i)
        names.buff[i] = E.TipLine(1)
    end
end

-- watching: an aura that appears while you look at the target starts now; one that is gone ends
local function refreshTarget(watching)
    scanNames()
    local unit = UnitName("target")
    if not unit then return end
    local now = {}
    for _, list in pairs(names) do
        for _, n in pairs(list) do now[n] = true end
    end
    local before = seen[unit]
    if watching and before then
        for n in pairs(now) do
            if not before[n] and not E.AuraRemaining(unit, n) then started(unit, n) end
        end
    end
    for n in pairs(before or {}) do
        if not now[n] then ended(unit, n) end
    end
    seen[unit] = now
end

-- -- Showing the numbers -----------------------------------------------------------------------

local function label(button)
    if button.essAura then return button.essAura end
    local over = CreateFrame("Frame", nil, button)
    over:SetAllPoints(button)
    over:SetFrameLevel(button:GetFrameLevel() + 2)
    local t = over:CreateFontString(nil, "OVERLAY")
    local w = button:GetWidth()
    if not w or w < 10 then w = 20 end
    t:SetFont(UI.FONT, math.max(8, math.floor(w * 0.5)), "OUTLINE")
    t:SetPoint("CENTER", button, "BOTTOM", 0, 1)
    t:SetShadowOffset(1, -1)
    t:SetShadowColor(0, 0, 0, 1)
    button.essAura = t
    return t
end

local function setLabel(button, kind, index, unitName, on)
    if not button then return end
    local text = ""
    local rem
    if on and button:IsVisible() then
        rem = E.AuraRemaining(unitName, names[kind][index])
        if rem then text = E.FormatCooldown(rem) end
    end
    if text == "" and not button.essAura then return end
    local t = label(button)
    t:SetText(text)
    if rem then
        if W.Palette and W.Palette.Urgency then t:SetTextColor(W.Palette.Urgency(rem)) else t:SetTextColor(1, 1, 1) end
    end
end

local function update()
    local on = E.On("auraTimers") and UnitExists("target")
    local unitName = UnitName("target")
    for i = 1, 16 do setLabel(getglobal("TargetFrameDebuff" .. i), "debuff", i, unitName, on) end
    for i = 1, 5 do setLabel(getglobal("TargetFrameBuff" .. i), "buff", i, unitName, on) end
    -- the UI Repack's target frame
    local f = CPElvTarget
    if f and f.auras then
        for _, a in ipairs(f.auras) do
            if a.auraUnit == "target" then setLabel(a, a.auraKind, a.auraIndex, unitName, on)
            else setLabel(a, "debuff", 0, unitName, false) end
        end
    end
end
E.UpdateAuraTimers = update

-- -- Events ------------------------------------------------------------------------------------

local ev = CreateFrame("Frame", "EssentialsAuras")
for _, e in ipairs({ "PLAYER_TARGET_CHANGED", "UNIT_AURA", "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE",
    "CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE", "CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_DAMAGE",
    "CHAT_MSG_SPELL_PERIODIC_PARTY_DAMAGE", "CHAT_MSG_SPELL_PERIODIC_CREATURE_BUFFS",
    "CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_BUFFS", "CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS",
    "CHAT_MSG_SPELL_PERIODIC_PARTY_BUFFS", "CHAT_MSG_SPELL_AURA_GONE_OTHER", "CHAT_MSG_SPELL_AURA_GONE_PARTY" }) do
    ev:RegisterEvent(e)
end
ev:SetScript("OnEvent", function()
    if not E.On("auraTimers") then return end
    if event == "PLAYER_TARGET_CHANGED" then
        refreshTarget(false)
    elseif event == "UNIT_AURA" then
        if arg1 == "target" then refreshTarget(true) end
    else
        local msg = arg1 or ""
        local _, _, unit, aura = string.find(msg, AFFLICTED)
        if not unit then _, _, unit, aura = string.find(msg, GAINS) end
        if unit then
            started(unit, (string.gsub(aura, " %(%d+%)$", "")))
            return
        end
        local _, _, gone, from = string.find(msg, FADES)
        if gone then ended(from, gone) end
    end
    update()
end)

local acc = 0
ev:SetScript("OnUpdate", function()
    acc = acc + arg1
    if acc < 0.2 then return end
    acc = 0
    update()
end)

E.OnRefresh(function(active)
    if active and E.On("auraTimers") then
        ev:Show()
        if UnitExists("target") then refreshTarget(false) end
    else
        ev:Hide()
    end
    update()
end)
