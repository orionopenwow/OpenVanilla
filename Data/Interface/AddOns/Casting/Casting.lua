--[[
    Casting.lua  -  Castline
    Exact enemy cast bars: one for your target and small ones under enemy nameplates.
    Nothing is guessed from animations or combat text; a cast starts when the game
    reports it and stops when it is interrupted or finished.

    Sources: the server ("CL" packets) and, in the web client, the engine itself (the page's
    bridge reads each unit's cast from the game state and forwards it in the same format).

    CL packet: "<target|plate>,<caster>,<spell>,<durationMs>,<interruptible>[,<icon>][,<channel>]"
               "stop,<target|plate>,<caster>,<1 if interrupted>"
    <icon> is a texture name under Interface\Icons (e.g. Spell_Fire_Fireball02).
]]--

local W = WenillaCore
local UI = W.UI
local ID = "Casting"

Castline = Castline or {}
local CL = Castline
CL.casts = {}   -- caster name -> cast

local COL_CAST = { 1.00, 0.70, 0.00 }
local COL_CHANNEL = { 0.32, 0.80, 0.30 }
local COL_LOCKED = { 0.60, 0.60, 0.66 }
local COL_FAIL = { 0.90, 0.14, 0.10 }

local function iconPath(name)
    if not name or name == "" then return "Interface\\Icons\\Spell_Holy_MagicalSentry" end
    if string.find(name, "\\", 1, 1) then return name end
    return "Interface\\Icons\\" .. name
end

-- -- Target bar ----------------------------------------------------------------

local bar = CreateFrame("Frame", "Castline_TargetBar", UIParent)
bar:SetWidth(240)
bar:SetHeight(24)
bar.defaultPoint = { "CENTER", UIParent, "CENTER", 0, -120 }
bar:SetPoint("CENTER", UIParent, "CENTER", 0, -120)
bar:SetBackdrop(UI.BACKDROP)
bar:SetBackdropColor(0.06, 0.06, 0.07, 0.94)
bar:SetBackdropBorderColor(0.62, 0.62, 0.66, 1)
bar:SetMovable(true)
bar:EnableMouse(true)
bar:RegisterForDrag("LeftButton")
bar:SetScript("OnDragStart", function() this:StartMoving() end)
bar:SetScript("OnDragStop", function() this:StopMovingOrSizing() W:SavePosition(this) end)
W:TrackPosition(bar)
bar:Hide()

local iconBox = UI.IconBox(bar, 28)
iconBox:SetPoint("RIGHT", bar, "LEFT", -3, 0)
local shield = iconBox:CreateTexture(nil, "OVERLAY")
shield:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
shield:SetBlendMode("ADD")
shield:SetVertexColor(0.75, 0.75, 0.85)
shield:SetPoint("CENTER", iconBox, "CENTER", 0, 0)
shield:SetWidth(52)
shield:SetHeight(52)

local sb = CreateFrame("StatusBar", nil, bar)
sb:SetPoint("TOPLEFT", bar, "TOPLEFT", 4, -4)
sb:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -4, 4)
sb:SetStatusBarTexture(UI.BAR)
sb:SetMinMaxValues(0, 1)

local spark = sb:CreateTexture(nil, "OVERLAY")
spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
spark:SetBlendMode("ADD")
spark:SetWidth(20)
spark:SetHeight(34)

local spellText = sb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
spellText:SetPoint("LEFT", sb, "LEFT", 5, 0)
local timeText = sb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
timeText:SetPoint("RIGHT", sb, "RIGHT", -5, 0)

local flash = sb:CreateTexture(nil, "OVERLAY")
flash:SetTexture(1, 1, 1, 1)
flash:SetAllPoints(sb)
flash:SetBlendMode("ADD")
flash:SetAlpha(0)

-- -- Nameplate bars ------------------------------------------------------------

local function plateBar(plate)
    if plate.castline then return plate.castline end
    local hb = plate:GetChildren()
    local f = CreateFrame("StatusBar", nil, plate)
    f:SetWidth(100)
    f:SetHeight(6)
    f:SetPoint("TOP", hb or plate, "BOTTOM", 6, -3)
    f:SetStatusBarTexture(UI.BAR)
    f:SetMinMaxValues(0, 1)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", f, "TOPLEFT", -1, 1)
    bg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 1, -1)
    bg:SetTexture(0, 0, 0, 0.85)
    local ic = f:CreateTexture(nil, "ARTWORK")
    ic:SetWidth(11)
    ic:SetHeight(11)
    ic:SetPoint("RIGHT", f, "LEFT", -2, 1)
    ic:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    f.icon = ic
    f:Hide()
    plate.castline = f
    return f
end

-- -- Cast state ----------------------------------------------------------------

function CL:Start(role, caster, spell, durSec, interruptible, icon, channel)
    local c = {
        role = role, caster = caster, spell = spell or "Casting", dur = durSec > 0 and durSec or 0.01,
        start = GetTime(), interruptible = interruptible, icon = iconPath(icon), channel = channel,
    }
    self.casts[caster] = c
    if role == "target" then self:ShowTarget(c) end
end

-- Paint the target bar for cast c (a new cast, or a remembered one when the target changes).
function CL:ShowTarget(c)
    self.target = c
    self.ending = nil
    local s = W:Settings(ID)
    local col = (not c.interruptible) and COL_LOCKED or (c.channel and COL_CHANNEL or COL_CAST)
    sb:SetStatusBarColor(col[1], col[2], col[3])
    sb:SetMinMaxValues(0, c.dur)
    spellText:SetText(c.spell)
    iconBox.icon:SetTexture(c.icon)
    if s.showIcon ~= false then iconBox:Show() else iconBox:Hide() end
    if c.interruptible then shield:Hide() else shield:Show() end
    flash:SetAlpha(0)
    bar:SetAlpha(1)
    if W:IsActive(ID) and s.showTarget ~= false then bar:Show() end
end

function CL:Stop(role, caster, interrupted)
    local c = self.casts[caster]
    self.casts[caster] = nil
    if role == "target" and self.target and (not c or self.target == c) then
        self.target = nil
        if interrupted then
            sb:SetStatusBarColor(COL_FAIL[1], COL_FAIL[2], COL_FAIL[3])
            local _, max = sb:GetMinMaxValues()
            sb:SetValue(max)
            spellText:SetText(INTERRUPTED or "Interrupted")
            timeText:SetText("")
        end
        self.ending = { t = GetTime(), flash = interrupted and 0.8 or 0.5 }
    end
end

function CL:HandlePacket(body)
    local f = W.Split(body, ",")
    if f[1] == "stop" then
        self:Stop(f[2] or "target", f[3] or "", f[4] == "1")
        return
    end
    local ms = tonumber(f[4]) or 0
    self:Start(f[1] or "target", f[2] or "", f[3], ms / 1000, f[5] ~= "0", f[6], f[7] == "1")
end

W:RegisterModule("CL", function(body) CL:HandlePacket(body) end)

-- -- Animation -----------------------------------------------------------------

local driver = CreateFrame("Frame", "Castline_Driver")
local scan = 0
driver:SetScript("OnUpdate", function()
    local now = GetTime()
    local s = W:Settings(ID)
    local c = CL.target
    if c then
        local el = now - c.start
        if el > c.dur + 0.5 then
            CL:Stop("target", c.caster, false)
        else
            if el > c.dur then el = c.dur end
            local v = c.channel and (c.dur - el) or el
            sb:SetValue(v)
            local w = sb:GetWidth()
            spark:ClearAllPoints()
            spark:SetPoint("CENTER", sb, "LEFT", w * v / c.dur, 0)
            spark:Show()
            if s.showTime ~= false then
                timeText:SetText(string.format("%.1fs / %.1fs", el, c.dur))
            else
                timeText:SetText("")
            end
        end
    elseif CL.ending then
        spark:Hide()
        local k = (now - CL.ending.t) / 0.6
        if k >= 1 then
            CL.ending = nil
            bar:Hide()
        else
            flash:SetAlpha(CL.ending.flash * (1 - k) * 0.6)
            bar:SetAlpha(1 - k * k)
        end
    end

    -- nameplate bars, matched by caster name
    if s.showNameplate ~= false and W:IsActive(ID) then
        scan = scan - arg1
        if scan <= 0 then
            scan = 0.25
            W.Plates.Scan()
        end
        for _, plate in ipairs(W.Plates.list) do
            local name = plate:IsVisible() and W.Plates.Name(plate)
            local pc = name and CL.casts[name]
            if pc and now - pc.start <= pc.dur + 0.3 then
                local pb = plateBar(plate)
                local col = (not pc.interruptible) and COL_LOCKED or (pc.channel and COL_CHANNEL or COL_CAST)
                pb:SetStatusBarColor(col[1], col[2], col[3])
                pb:SetMinMaxValues(0, pc.dur)
                local el = now - pc.start
                if el > pc.dur then el = pc.dur end
                pb:SetValue(pc.channel and (pc.dur - el) or el)
                pb.icon:SetTexture(pc.icon)
                pb:Show()
            elseif plate.castline then
                plate.castline:Hide()
            end
        end
    end
end)

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_TARGET_CHANGED")
ev:SetScript("OnEvent", function()
    -- a new target shows its own cast (if any) the next time the source reports it
    local name = UnitName("target")
    local c = name and CL.casts[name]
    if c and GetTime() - c.start < c.dur then
        CL:ShowTarget(c)
    elseif CL.target then
        CL.target = nil
        CL.ending = nil
        bar:Hide()
    end
end)

W:RegisterAddon(ID, function(active)
    if not active then
        bar:Hide()
        for _, plate in ipairs(W.Plates.list) do
            if plate.castline then plate.castline:Hide() end
        end
        driver:Hide()
    else
        driver:Show()
    end
end)

SLASH_CASTING1 = "/casting"
SLASH_CASTING2 = "/castbars"
SLASH_CASTING3 = "/castline"
SlashCmdList["CASTING"] = function()
    -- preview the bar so it can be positioned
    CL:Start("target", UnitName("target") or "Preview", "Shadow Bolt", 3, true, "Spell_Shadow_ShadowBolt", false)
    W.Print("Casting preview - drag the bar to move it.")
end
