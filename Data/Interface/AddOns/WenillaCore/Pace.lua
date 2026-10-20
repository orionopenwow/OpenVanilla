--[[
    Pace.lua  (WenillaCore)
    The realm's own Hearthstone cooldown and Blessing duration in tooltips and timers.

    The 1.12 client words tooltips and times cooldowns from its own Spell.dbc, which Open Vanilla
    does not ship. A realm that changes them (realm/classicplus/PACE.md) says so once the addons
    have greeted it:  PZ <hearthstone cooldown ms>,<single-target Blessing duration ms>
    Nothing here does anything until a realm sends numbers that differ from 1.12's; then:
      * Blessing tooltips say the realm's duration ("for 15 min", not "for 5 min"), and
        Essentials' timers on other players' Blessings count from it;
      * the Hearthstone's "Cooldown remaining", its cooldown spiral (bags and action bars) and
        Essentials' cooldown numbers count the realm's cooldown from the moment it started (the
        client still knows when; only the length it assumes is the 1.12 hour). The realm clears
        the cooldown on the client when it ends, so the item is usable when it says it is.
]]--

local W = WenillaCore
W.pace = W.pace or {}
local P = W.pace

local STOCK_HEARTH = 3600                 -- seconds, 1.12.1
local STOCK_BLESSING = 300
local HEARTH_ITEM = "item:6948:"
local HEARTH_ICON = "Interface\\Icons\\INV_Misc_Rune_01"
local BLESSINGS = {
    ["Blessing of Might"] = 1, ["Blessing of Wisdom"] = 1, ["Blessing of Kings"] = 1,
    ["Blessing of Salvation"] = 1, ["Blessing of Light"] = 1, ["Blessing of Sanctuary"] = 1,
}

-- The client's own way of writing a duration ("15 min", "1 hour", "30 sec").
function P.Duration(sec)
    if sec >= 3600 and sec - math.floor(sec / 3600) * 3600 == 0 then
        local h = sec / 3600
        return h .. (h == 1 and " hour" or " hours")
    end
    if sec >= 60 then return math.floor(sec / 60 + 0.5) .. " min" end
    return math.floor(sec) .. " sec"
end

local function hearthChanged() return P.hearth and P.hearth ~= STOCK_HEARTH end
local function blessingChanged() return P.blessing and P.blessing > 0 and P.blessing ~= STOCK_BLESSING end

-- ── cooldowns ──────────────────────────────────────────────────────────────────────────────

-- start/duration as the client reports them for the Hearthstone -> the realm's.
function P.FixCooldown(start, duration, enable)
    if not hearthChanged() or not start or start == 0 or not duration then return start, duration, enable end
    if duration < STOCK_HEARTH - 1 then return start, duration, enable end   -- not the client's hour (already right)
    if start + P.hearth <= GetTime() then return 0, 0, enable end
    return start, P.hearth, enable
end

local origContainerCooldown, origActionCooldown
local function isHearth(link) return link and strfind(link, HEARTH_ITEM, 1, 1) end

-- when the Hearthstone in the bags started cooling down (the client's own start time)
local function hearthStart()
    if not origContainerCooldown or not GetContainerItemLink then return nil end
    for bag = 0, 4 do
        for slot = 1, (GetContainerNumSlots and GetContainerNumSlots(bag) or 0) do
            if isHearth(GetContainerItemLink(bag, slot)) then
                local start, duration = origContainerCooldown(bag, slot)
                if start and start > 0 and duration and duration > 0 then return start end
                return nil
            end
        end
    end
    return nil
end

local function wrapCooldowns()
    if P.cooldownsWrapped then return end
    P.cooldownsWrapped = true
    origContainerCooldown = GetContainerItemCooldown
    if origContainerCooldown then
        function GetContainerItemCooldown(bag, slot)
            local s, d, e = origContainerCooldown(bag, slot)
            if isHearth(GetContainerItemLink and GetContainerItemLink(bag, slot)) then return P.FixCooldown(s, d, e) end
            return s, d, e
        end
    end
    origActionCooldown = GetActionCooldown
    if origActionCooldown then
        function GetActionCooldown(slot)
            local s, d, e = origActionCooldown(slot)
            if GetActionTexture and GetActionTexture(slot) == HEARTH_ICON then return P.FixCooldown(s, d, e) end
            return s, d, e
        end
    end
end

-- ── tooltips ───────────────────────────────────────────────────────────────────────────────

local function plain(text) return (string.gsub(text or "", "|c%x%x%x%x%x%x%x%x(.-)|r", "%1")) end

function P.FixTooltip(tip)
    local name = tip and tip.GetName and tip:GetName()
    if not name or not tip.NumLines then return end
    local first = getglobal(name .. "TextLeft1")
    local title = first and plain(first:GetText())
    if not title or title == "" then return end
    local n = tip:NumLines() or 0
    if BLESSINGS[title] and blessingChanged() then
        local was, now = P.Duration(STOCK_BLESSING), P.Duration(P.blessing)
        for i = 2, n do
            local line = getglobal(name .. "TextLeft" .. i)
            local t = line and line:GetText()
            if t then
                -- " 5 min" but never the "5 min" inside "15 min"
                local new, count = string.gsub(t, "([^%d])" .. was, "%1" .. now)
                if count > 0 then line:SetText(new) end
            end
        end
    elseif title == "Hearthstone" and hearthChanged() then
        local start = hearthStart()
        for i = 2, n do
            local line = getglobal(name .. "TextLeft" .. i)
            local t = line and line:GetText()
            if t then
                local _, _, prefix = strfind(t, "^(Cooldown remaining:%s*)")
                if prefix then
                    local left = start and (start + P.hearth - GetTime())
                    if left and left > 0 then
                        line:SetText(prefix .. (left >= 60 and (math.ceil(left / 60) .. " min") or (math.ceil(left) .. " sec")))
                    else
                        line:SetText("")
                    end
                else
                    local new = string.gsub(t, P.Duration(STOCK_HEARTH), P.Duration(P.hearth))
                    if new ~= t then line:SetText(new) end
                end
            end
        end
    end
end

local METHODS = {
    "SetBagItem", "SetInventoryItem", "SetAction", "SetSpell", "SetHyperlink", "SetPlayerBuff",
    "SetUnitBuff", "SetTrainerService", "SetLootItem", "SetMerchantItem", "SetQuestItem",
    "SetQuestLogItem", "SetCraftSpell", "SetTradePlayerItem", "SetInboxItem",
}
local function hookTooltip(tip)
    if not tip or tip.ovPaceHooked then return end
    tip.ovPaceHooked = true
    for _, m in ipairs(METHODS) do
        local orig = tip[m]
        if orig then
            tip[m] = function(self, a1, a2, a3, a4)
                local r1, r2 = orig(self, a1, a2, a3, a4)
                P.FixTooltip(self)
                return r1, r2
            end
        end
    end
end

-- ── the realm's numbers ────────────────────────────────────────────────────────────────────

function P.Apply()
    if blessingChanged() and Essentials and Essentials.AURA_DURATIONS then
        for spell in pairs(BLESSINGS) do Essentials.AURA_DURATIONS[spell] = P.blessing end
    end
    if hearthChanged() then wrapCooldowns() end
    if hearthChanged() or blessingChanged() then
        hookTooltip(GameTooltip)
        hookTooltip(ItemRefTooltip)
    end
end

W:RegisterModule("PZ", function(body)
    local _, _, hearth, blessing = strfind(body or "", "^(%d+),(%-?%d+)")
    if not hearth then return end
    P.hearth = math.floor(tonumber(hearth) / 1000 + 0.5)
    P.blessing = math.floor(tonumber(blessing) / 1000 + 0.5)
    P.Apply()
end)
