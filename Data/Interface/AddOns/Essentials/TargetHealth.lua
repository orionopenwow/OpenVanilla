--[[
    TargetHealth.lua  (Essentials)
    Your target's health as a number on the stock target frame's health bar: the percentage for a
    creature (the 1.12 server tells a client a creature's health in hundredths, so a percentage is
    all there is to say), and "current / max" for a player or pet whose real numbers the client has.
    A player asked for it on 2026-10-21 ("in Kelduron it was in percentage, here I don't see anything").

    Lua 5.0 rules (1.12.1 client): no '#', no '%', handlers read this/event/arg1.
]]--

local E = Essentials

local floor = math.floor
local text

-- The text for a unit's health: "73%" when the client only knows hundredths, else "1234 / 2000 (62%)".
function E.HealthText(cur, max)
    if not cur or not max or max <= 0 then return "" end
    local pct = floor(cur / max * 100 + 0.5)
    if cur > 0 and pct == 0 then pct = 1 end
    if max == 100 then return pct .. "%" end
    return cur .. " / " .. max .. "  (" .. pct .. "%)"
end

local function bar()
    return TargetFrameHealthBar
end

local function make()
    if text or not bar() then return text end
    local holder = CreateFrame("Frame", "Essentials_TargetHealth", bar())
    holder:SetAllPoints(bar())
    holder:SetFrameLevel((bar():GetFrameLevel() or 1) + 2)
    text = holder:CreateFontString("Essentials_TargetHealthText", "OVERLAY", "TextStatusBarText")
    if not text:GetFont() then text:SetFontObject(GameFontHighlightSmall) end
    text:SetPoint("CENTER", holder, "CENTER", 0, 0)
    return text
end

function E.UpdateTargetHealth()
    local t = make()
    if not t then return end
    if not (E.On("targetHealth") and UnitExists("target")) or UnitIsDeadOrGhost("target") then
        t:SetText("")
        t:Hide()
        return
    end
    t:SetText(E.HealthText(UnitHealth("target"), UnitHealthMax("target")))
    t:Show()
end

local ev = CreateFrame("Frame", "Essentials_TargetHealthEvents")
ev:RegisterEvent("PLAYER_TARGET_CHANGED")
ev:RegisterEvent("UNIT_HEALTH")
ev:RegisterEvent("UNIT_MAXHEALTH")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:SetScript("OnEvent", function()
    if (event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH") and arg1 ~= "target" then return end
    E.UpdateTargetHealth()
end)

table.insert(E.refreshers, function() E.UpdateTargetHealth() end)
