--[[
    Threat.lua  -  Vanguard
    Exact threat on your target, read by the server from the creature's own threat table.
    Three bars, as on the design sheet:
        Threat       the unit holding aggro (red)
        Aggro        you, or the runner-up when you hold aggro (gold)
        Aggro Delta  how far you are below the pull point (blue; full = safe)
    The window appears only while the server is sending threat for your target.

    VG packet: "<target>;<name>,<pct>,<isTank>;...;S,<rank>,<pct>,<pullAt>"
               pct is percent of the tank's threat; pullAt is 110 (melee) or 130 (ranged).
               "-" hides the window (target lost / combat over).
]]--

local W = WenillaCore
local UI = W.UI
local ID = "Threat"

Vanguard = Vanguard or {}
local V = Vanguard
V.last = 0
V.warned = false

local WIDTH, ROW_H = 214, 18

local frame = UI.Window("Vanguard_Frame", {
    width = WIDTH, height = 96, title = "Threat",
    icon = "Interface\\Icons\\Ability_Warrior_DefensiveStance",
    point = { "TOP", UIParent, "TOP", 0, -40 },
    onClose = function() V.userClosed = true; Vanguard_Frame:Hide() end,
})
frame:Hide()

local targetText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
targetText:SetPoint("TOPLEFT", frame, "TOPLEFT", 9, -27)
targetText:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -9, -27)
targetText:SetJustifyH("LEFT")

local ICONS = {
    "Interface\\Icons\\Ability_Warrior_Sunder",
    "Interface\\Icons\\Ability_Warrior_BattleShout",
    "Interface\\Icons\\Spell_Nature_TimeStop",
}
local COLORS = { { 0.78, 0.13, 0.12 }, { 0.82, 0.66, 0.14 }, { 0.20, 0.42, 0.86 } }

local bars = {}
for i = 1, 3 do
    local b = UI.Bar(frame, { width = WIDTH - 16, height = ROW_H, icon = true })
    b:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -40 - (i - 1) * (ROW_H + 3))
    b.icon:SetTexture(ICONS[i])
    b:SetColor(COLORS[i][1], COLORS[i][2], COLORS[i][3])
    bars[i] = b
end
Vanguard_Bar1, Vanguard_Bar2, Vanguard_Bar3 = bars[1], bars[2], bars[3]

local glow = frame:CreateTexture(nil, "BACKGROUND")
glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
glow:SetBlendMode("ADD")
glow:SetVertexColor(1, 0.15, 0.05)
glow:SetPoint("TOPLEFT", frame, "TOPLEFT", -40, 40)
glow:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 40, -40)
glow:Hide()

local function layout()
    local delta = W:Setting(ID, "showDelta", true)
    if delta then bars[3]:Show() else bars[3]:Hide() end
    frame:SetHeight(delta and 108 or 87)
end

local function hide()
    frame:Hide()
    glow:Hide()
    V.warned = false
end

function V:HandlePacket(body)
    if body == "-" or body == "" then hide() return end
    local recs, n = W.Split(body, ";")
    local target = recs[1]
    local entries, rank, mine, pullAt = {}, 0, 0, 110
    for i = 2, n do
        local f = W.Split(recs[i], ",")
        if f[1] == "S" then
            rank, mine, pullAt = tonumber(f[2]) or 0, tonumber(f[3]) or 0, tonumber(f[4]) or 110
        elseif f[1] ~= "" then
            table.insert(entries, { name = f[1], pct = tonumber(f[2]) or 0, tank = f[3] == "1" })
        end
    end
    if pullAt <= 0 then pullAt = 110 end
    local top = entries[1]
    if not top then hide() return end

    local me = UnitName("player")
    local second
    if top.name == me then second = entries[2] else second = { name = me, pct = mine } end

    targetText:SetText(target)
    local scale = pullAt
    if top.pct > scale then scale = top.pct end
    bars[1].left:SetText(top.name)
    bars[1].right:SetText(string.format("%.1f%%", top.pct))
    bars[1]:SetFraction(top.pct / scale)

    if second then
        bars[2].left:SetText(second.name == me and "You" or second.name)
        bars[2].right:SetText(string.format("%.1f%%", second.pct))
        bars[2]:SetFraction(second.pct / scale)
        bars[2]:Show()
    else
        bars[2]:Hide()
    end

    local room = (top.name == me) and 0 or (pullAt - mine)
    if room < 0 then room = 0 end
    bars[3].left:SetText(top.name == me and "You have aggro" or "Until pull")
    bars[3].right:SetText(string.format("%.1f%%", room))
    bars[3]:SetFraction(room / pullAt)

    local danger = top.name ~= me and rank > 1 and mine >= pullAt * 0.9
    if danger and W:Setting(ID, "pullWarning", true) then
        glow:Show()
        if not V.warned and W:Setting(ID, "soundAlert", true) then
            PlaySoundFile("Sound\\Interface\\RaidWarning.wav")
        end
        V.warned = true
    else
        glow:Hide()
        V.warned = false
    end

    V.last = GetTime()
    if W:IsActive(ID) and not V.userClosed then
        layout()
        frame:Show()
    end
end

W:RegisterModule("VG", function(body) V:HandlePacket(body) end)

-- stale data (no update for 6 s) hides the window; the pulse runs while warning
local ticker = CreateFrame("Frame")
local t = 0
ticker:SetScript("OnUpdate", function()
    t = t + arg1
    if glow:IsShown() then glow:SetAlpha(0.45 + 0.4 * math.sin(t * 7)) end
    if frame:IsShown() and GetTime() - V.last > 6 then hide() end
end)

W:RegisterAddon(ID, function(active)
    layout()
    if not active then hide() end
end)

SLASH_THREAT1 = "/threat"
SLASH_THREAT2 = "/vanguard"
SlashCmdList["THREAT"] = function()
    V.userClosed = not V.userClosed
    if V.userClosed then hide() end
    W.Print("Threat window " .. (V.userClosed and "hidden" or "shown when the server sends threat") .. ".")
end
