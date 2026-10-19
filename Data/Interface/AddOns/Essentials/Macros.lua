--[[
    Macros.lua  (Essentials)
    * /cast with conditions, as later clients have it, for 1.12 macros:
          /cast [mod:shift] Frost Nova; [target=mouseover,help] Flash Heal; Smite
      Clauses are separated by ';' and tried in order; the first whose conditions hold is cast.
      A clause may have several [ ] groups (any one may match); inside a group every
      condition must hold. Conditions:
          mod, mod:shift, mod:ctrl, mod:alt (mod:shift/ctrl = either), nomod, nomod:shift ...
          target=<unit> (or @<unit>): player, target, mouseover, focus-free tokens like party1, pet
          help, harm, exists, noexists, dead, nodead, combat, nocombat
      A plain /cast (no brackets, no ';') goes straight to the stock /cast.
      Casting on another unit uses the 1.12 way: target it, cast, and target your old target again.
    * Auto dismount / stand: when a cast or attack fails with "You are mounted" or "You must be
      standing", get off the mount (cancel the mount buff) or stand up, then retry what you did.

    Lua 5.0 rules (1.12.1 client): no '#', no '%', handlers read this/event/arg1.
]]--

local E = Essentials
local W = WenillaCore

local function trim(s) return W.Trim(s) end

-- -- Conditions ------------------------------------------------------------------------------

local MODS = {
    shift = function() return IsShiftKeyDown() end,
    ctrl = function() return IsControlKeyDown() end,
    alt = function() return IsAltKeyDown() end,
}
local function anyMod() return IsShiftKeyDown() or IsControlKeyDown() or IsAltKeyDown() end

-- "shift/ctrl" -> true when any of them is held
local function modsHeld(list)
    for m in string.gfind(list, "[^/]+") do
        local f = MODS[m]
        if f and f() then return true end
    end
    return false
end

local function checkOne(cond, unit)
    local _, _, key, value = string.find(cond, "^(%a+):(.+)$")
    key = key or cond
    if key == "mod" or key == "modifier" then
        if value then return modsHeld(value) end
        return anyMod() and true or false
    elseif key == "nomod" or key == "nomodifier" then
        if value then return not modsHeld(value) end
        return not anyMod()
    elseif key == "help" then
        return UnitExists(unit) and UnitCanAssist("player", unit) and true or false
    elseif key == "harm" then
        return UnitExists(unit) and UnitCanAttack("player", unit) and true or false
    elseif key == "exists" then
        return UnitExists(unit) and true or false
    elseif key == "noexists" then
        return not UnitExists(unit)
    elseif key == "dead" then
        return UnitExists(unit) and UnitIsDeadOrGhost(unit) and true or false
    elseif key == "nodead" then
        return UnitExists(unit) and not UnitIsDeadOrGhost(unit)
    elseif key == "combat" then
        return UnitAffectingCombat("player") and true or false
    elseif key == "nocombat" then
        return not UnitAffectingCombat("player")
    end
    return false                  -- a condition we do not know never matches
end

-- One [ ] group: returns ok, unit
function E.CheckGroup(group)
    local unit
    local conds = {}
    for raw in string.gfind(group, "[^,]+") do
        local c = string.lower(trim(raw))
        local _, _, u = string.find(c, "^target%s*=%s*(.+)$")
        if not u then _, _, u = string.find(c, "^@(.+)$") end
        if u then unit = trim(u) elseif c ~= "" then table.insert(conds, c) end
    end
    for _, c in ipairs(conds) do
        if not checkOne(c, unit or "target") then return false end
    end
    return true, unit
end

-- "[mod:shift] A; [help] B; C" -> spell, unit (or nil when no clause matches)
function E.ParseCast(msg)
    for clause in string.gfind((msg or "") .. ";", "([^;]*);") do
        local rest = clause
        local groups = {}
        while true do
            local _, e, inner = string.find(rest, "^%s*%[([^%]]*)%]")
            if not inner then break end
            table.insert(groups, inner)
            rest = string.sub(rest, e + 1)
        end
        local spell = trim(rest)
        if not groups[1] then
            if spell ~= "" then return spell, nil end
        else
            for _, g in ipairs(groups) do
                local ok, unit = E.CheckGroup(g)
                if ok then
                    if spell == "" then return nil end
                    return spell, unit
                end
            end
        end
    end
    return nil
end

-- -- Casting ------------------------------------------------------------------------------------

E.last = nil       -- { t = GetTime(), run = function() ... end, retried = bool }

local function remember(run) E.last = { t = GetTime(), run = run } end

function E.CastOn(spell, unit)
    local function go()
        if not unit or unit == "target" or not UnitExists(unit) then
            CastSpellByName(spell)
        elseif unit == "player" then
            CastSpellByName(spell, 1)
        elseif UnitIsUnit("target", unit) then
            CastSpellByName(spell)
        else
            local had = UnitExists("target")
            TargetUnit(unit)
            CastSpellByName(spell)
            if SpellIsTargeting() then SpellTargetUnit(unit) end
            if had then TargetLastTarget() else ClearTarget() end
        end
    end
    go()
    remember(go)
end

-- Remember the last cast or button press so a dismount can retry it.
if UseAction then
    local stock = UseAction
    UseAction = function(slot, cursor, onSelf)
        local r = stock(slot, cursor, onSelf)
        if not E.retrying then remember(function() stock(slot, cursor, onSelf) end) end
        return r
    end
end
if CastSpellByName then
    local stock = CastSpellByName
    CastSpellByName = function(spell, onSelf)
        local r = stock(spell, onSelf)
        if not E.retrying then remember(function() stock(spell, onSelf) end) end
        return r
    end
end

-- /cast: our conditions first, the stock command for everything else.
do
    local stock = SlashCmdList["CAST"]
    if not SLASH_CAST1 then SLASH_CAST1 = "/cast" end
    SlashCmdList["CAST"] = function(msg)
        msg = msg or ""
        if E.On("macroConditions") and (string.find(msg, "[", 1, true) or string.find(msg, ";", 1, true)) then
            local spell, unit = E.ParseCast(msg)
            if spell then E.CastOn(spell, unit) end
            return
        end
        if stock then return stock(msg) end
        if msg ~= "" then CastSpellByName(msg) end
    end
end

-- -- Auto dismount / stand ----------------------------------------------------------------------

local MOUNT_ICONS = { "ability_mount_", "inv_misc_foot_kodo", "spell_nature_swiftness", "inv_misc_qirajicrystal" }

local function isMount(idx)
    local tex = string.lower(GetPlayerBuffTexture(idx) or "")
    local tip = E.ScanTip()
    if tip.SetPlayerBuff then tip:SetPlayerBuff(idx) end
    local name, desc = E.TipLine(1) or "", E.TipLine(2) or ""
    if string.find(name, "^Aspect of") then return false end         -- hunters' aspects share mount icons
    for _, p in ipairs(MOUNT_ICONS) do
        if string.find(tex, p, 1, true) then return true end
    end
    local _, _, pct = string.find(desc, "[Ii]ncreases speed by (%d+)")
    return pct and tonumber(pct) >= 60 or false
end

function E.Dismount()
    for i = 0, 31 do
        local idx = GetPlayerBuff(i, "HELPFUL")
        if not idx or idx < 0 then break end
        if isMount(idx) then
            CancelPlayerBuff(idx)
            return true
        end
    end
    return false
end

function E.Stand()
    if DoEmote then DoEmote("STAND") elseif SitOrStand then SitOrStand() end
    return true
end

local function errorKind(msg)
    if not msg then return nil end
    for _, g in ipairs({ "SPELL_FAILED_NOT_MOUNTED", "ERR_ATTACK_MOUNTED", "ERR_NOT_WHILE_MOUNTED",
        "ERR_TAXIPLAYERALREADYMOUNTED", "ERR_MOUNT_ALREADYMOUNTED" }) do
        local s = getglobal(g)
        if s and string.find(msg, s, 1, true) then return "mount" end
    end
    for _, g in ipairs({ "SPELL_FAILED_NOT_STANDING", "ERR_CANTATTACK_NOTSTANDING", "ERR_LOOT_NOTSTANDING" }) do
        local s = getglobal(g)
        if s and string.find(msg, s, 1, true) then return "stand" end
    end
    local low = string.lower(msg)
    if string.find(low, "mounted", 1, true) then return "mount" end
    if string.find(low, "standing", 1, true) then return "stand" end
    return nil
end

local RETRY_AFTER = 0.3
local retry = CreateFrame("Frame", "EssentialsRetry")
retry:Hide()
retry:SetScript("OnUpdate", function()
    this.wait = (this.wait or 0) - arg1
    if this.wait > 0 then return end
    this:Hide()
    local l = E.last
    if l and l.run and not l.retried then
        l.retried = true
        E.retrying = true
        pcall(l.run)
        E.retrying = nil
    end
end)

local ev = CreateFrame("Frame", "EssentialsDismount")
ev:RegisterEvent("UI_ERROR_MESSAGE")
ev:SetScript("OnEvent", function()
    if not E.On("autoDismount") then return end
    local kind = errorKind(arg1)
    if not kind then return end
    local done
    if kind == "mount" then done = E.Dismount() else done = E.Stand() end
    local l = E.last
    if done and l and not l.retried and GetTime() - l.t < 1.5 then
        retry.wait = RETRY_AFTER
        retry:Show()
    end
end)
