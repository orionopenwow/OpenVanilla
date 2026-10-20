--[[
    Move.lua  (Classic+ Themes)
    Move Anything: /move (or the Classic+ menu button) unlocks the interface. Every movable frame
    gets a green box: drag it to move, Shift + mouse wheel to scale, right-click to put it back.
    Positions and scales are saved account-wide in ClassicPlus_UI and survive /reload.

    Lua 5.0 rules (1.12.1): no '#', no '%', handlers read this/arg1.
]]--

ClassicPlusUI = ClassicPlusUI or {}
local T = ClassicPlusUI
local W = WenillaCore

T.movers = {}          -- name -> mover button
T.registry = {}        -- ordered { name, label }
local registered = {}

local function db()
    if type(ClassicPlus_UI) ~= "table" then ClassicPlus_UI = {} end
    local d = ClassicPlus_UI
    if type(d.pos) ~= "table" then d.pos = {} end
    return d
end
T.db = db

-- Stock frames everyone wants to move. Frames a theme adds register themselves the same way.
local STOCK = {
    { "PlayerFrame", "Player" }, { "TargetFrame", "Target" },
    { "PartyMemberFrame1", "Party 1" }, { "PartyMemberFrame2", "Party 2" },
    { "PartyMemberFrame3", "Party 3" }, { "PartyMemberFrame4", "Party 4" },
    { "MinimapCluster", "Minimap" }, { "BuffFrame", "Buffs" },
    { "CastingBarFrame", "Cast bar" }, { "MainMenuBar", "Action bar" },
    { "MultiBarRight", "Right bar" }, { "MultiBarLeft", "Right bar 2" },
    { "PetActionBarFrame", "Pet bar" }, { "ShapeshiftBarFrame", "Stance bar" },
    { "QuestWatchFrame", "Quest tracker" }, { "DurabilityFrame", "Durability" },
    { "Chronicle_Frame", "Chronicle" }, { "Vanguard_Frame", "Vanguard" },
    { "Rally_Frame", "Rally" }, { "Vault_Frame", "Vault" },
}

function T:Register(name, label)
    if registered[name] then return end
    registered[name] = true
    table.insert(self.registry, { name, label or name })
end
for _, e in ipairs(STOCK) do T:Register(e[1], e[2]) end

-- -- Saving and applying ------------------------------------------------------------------------

local origin = {}      -- name -> the frame's own points the first time we touched it

local function remember(f, name)
    if origin[name] then return end
    local pts = {}
    for i = 1, (f.GetNumPoints and f:GetNumPoints() or 1) do
        local p, rel, rp, x, y = f:GetPoint(i)
        if p then table.insert(pts, { p, rel, rp, x, y }) end
    end
    origin[name] = { pts = pts, scale = f:GetScale() or 1 }
end

function T:Apply(name)
    local f = getglobal(name)
    local s = db().pos[name]
    if not f or not s then return end
    remember(f, name)
    if s.scale then f:SetScale(s.scale) end
    if s.left and s.top then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", s.left, s.top)
    end
    if f.SetUserPlaced then pcall(f.SetUserPlaced, f, true) end
end

function T:ApplyAll()
    for name in pairs(db().pos) do self:Apply(name) end
end

local function save(f, name)
    local d = db().pos
    d[name] = d[name] or {}
    d[name].left = f:GetLeft()
    d[name].top = f:GetTop()
    d[name].scale = f:GetScale()
end

function T:Reset(name)
    local f = getglobal(name)
    db().pos[name] = nil
    local o = origin[name]
    if f and o then
        f:SetScale(o.scale or 1)
        f:ClearAllPoints()
        for _, p in ipairs(o.pts) do f:SetPoint(p[1], p[2], p[3], p[4], p[5]) end
    end
    if UIParent_ManageFramePositions then UIParent_ManageFramePositions() end
    self:Refresh()
end

-- -- The movers ---------------------------------------------------------------------------------

local function mover(name, label)
    local m = T.movers[name]
    if m then return m end
    m = CreateFrame("Button", nil, UIParent)
    m:SetFrameStrata("FULLSCREEN_DIALOG")
    m:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    m:SetBackdropColor(0.15, 0.75, 0.3, 0.35)
    m:SetBackdropBorderColor(0.4, 1, 0.5, 0.9)
    m:EnableMouse(true)
    m:EnableMouseWheel(true)
    m:RegisterForDrag("LeftButton")
    m:RegisterForClicks("RightButtonUp")
    local fs = m:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("CENTER", m, "CENTER", 0, 0)
    fs:SetText(label)
    m.label = fs
    m:SetScript("OnDragStart", function()
        local f = getglobal(name)
        if not f then return end
        remember(f, name)
        f:SetMovable(true)
        if f.SetClampedToScreen then f:SetClampedToScreen(true) end
        f:StartMoving()
        m.moving = f
    end)
    m:SetScript("OnDragStop", function()
        local f = m.moving
        if not f then return end
        f:StopMovingOrSizing()
        m.moving = nil
        save(f, name)
        T:Apply(name)
        T:Place(name)
    end)
    m:SetScript("OnUpdate", function()
        if m.moving then T:Place(name) end
    end)
    m:SetScript("OnMouseWheel", function()
        if not IsShiftKeyDown() then return end
        local f = getglobal(name)
        if not f then return end
        remember(f, name)
        local old = f:GetScale() or 1
        local new = old + (arg1 > 0 and 0.05 or -0.05)
        if new < 0.5 then new = 0.5 elseif new > 2 then new = 2 end
        -- keep the top-left corner where it is on screen
        local l, t = (f:GetLeft() or 0) * old, (f:GetTop() or 0) * old
        f:SetScale(new)
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l / new, t / new)
        save(f, name)
        T:Place(name)
    end)
    m:SetScript("OnClick", function()
        if arg1 == "RightButton" then T:Reset(name) end
    end)
    m:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_TOP")
        GameTooltip:SetText(label, 0.4, 1, 0.5)
        GameTooltip:AddLine("Drag to move", 1, 1, 1)
        GameTooltip:AddLine("Shift + mouse wheel to scale", 1, 1, 1)
        GameTooltip:AddLine("Right-click to put it back", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    m:SetScript("OnLeave", function() GameTooltip:Hide() end)
    T.movers[name] = m
    return m
end

-- Sit the box over its frame (the frame's own size, at least 60x20, scaled like it).
function T:Place(name)
    local m, f = self.movers[name], getglobal(name)
    if not m or not f then return end
    local sc = (f:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
    local w, h = (f:GetWidth() or 0) * sc, (f:GetHeight() or 0) * sc
    if w < 60 then w = 60 end
    if h < 20 then h = 20 end
    m:SetWidth(w)
    m:SetHeight(h)
    m:ClearAllPoints()
    local l, t = f:GetLeft(), f:GetTop()
    if l and t then
        m:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l * sc, t * sc)
    else
        m:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

function T:Refresh()
    if not self.unlocked then return end
    for _, e in ipairs(self.registry) do
        local name = e[1]
        local f = getglobal(name)
        if f and (f:IsShown() or name == "TargetFrame" or string.find(name, "^Party") or string.find(name, "^CP")) then
            mover(name, e[2])
            self:Place(name)
            self.movers[name]:Show()
        elseif self.movers[name] then
            self.movers[name]:Hide()
        end
    end
end

-- -- Lock panel and grid ------------------------------------------------------------------------

local panel = CreateFrame("Frame", "ClassicPlusMovePanel", UIParent)
panel:SetWidth(360)
panel:SetHeight(64)
panel:SetPoint("TOP", UIParent, "TOP", 0, -60)
panel:SetFrameStrata("FULLSCREEN_DIALOG")
panel:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
panel:SetBackdropColor(0.05, 0.05, 0.06, 0.92)
panel:SetBackdropBorderColor(0.4, 1, 0.5, 0.9)
panel:Hide()
local ptext = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
ptext:SetPoint("TOP", panel, "TOP", 0, -8)
ptext:SetText("|cff66ff88Move Anything|r  drag · Shift+wheel to scale · right-click resets")

local function button(text, x, onClick)
    local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    b:SetWidth(96)
    b:SetHeight(22)
    b:SetPoint("BOTTOM", panel, "BOTTOM", x, 8)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end
button("Done", -104, function() T:Lock() end)
button("Grid", 0, function() T:ToggleGrid() end)
button("Reset all", 104, function()
    for name in pairs(db().pos) do T:Reset(name) end
    W.Print("Every frame is back where it started.")
end)

local grid
function T:ToggleGrid()
    if not grid then
        grid = CreateFrame("Frame", nil, UIParent)
        grid:SetAllPoints(UIParent)
        grid:SetFrameStrata("BACKGROUND")
        local w, h = UIParent:GetWidth(), UIParent:GetHeight()
        local step = 32
        local x = 0
        while x < w do
            local t = grid:CreateTexture(nil, "BACKGROUND")
            t:SetTexture(1, 1, 1, (math.abs(x - w / 2) < 1) and 0.35 or 0.12)
            t:SetWidth(1)
            t:SetPoint("TOPLEFT", grid, "TOPLEFT", x, 0)
            t:SetPoint("BOTTOMLEFT", grid, "BOTTOMLEFT", x, 0)
            x = x + step
        end
        local y = 0
        while y < h do
            local t = grid:CreateTexture(nil, "BACKGROUND")
            t:SetTexture(1, 1, 1, 0.12)
            t:SetHeight(1)
            t:SetPoint("TOPLEFT", grid, "TOPLEFT", 0, -y)
            t:SetPoint("TOPRIGHT", grid, "TOPRIGHT", 0, -y)
            y = y + step
        end
        grid:Hide()
    end
    if grid:IsShown() then grid:Hide() else grid:Show() end
end

function T:Unlock()
    self.unlocked = true
    panel:Show()
    self:Refresh()
end

function T:Lock()
    self.unlocked = false
    panel:Hide()
    if grid then grid:Hide() end
    for _, m in pairs(self.movers) do m:Hide() end
end

function T:ToggleMove()
    if self.unlocked then self:Lock() else self:Unlock() end
end

SLASH_CPMOVE1 = "/move"
SLASH_CPMOVE2 = "/moveanything"
SLASH_CPMOVE3 = "/unlock"
SlashCmdList["CPMOVE"] = function() T:ToggleMove() end

-- The stock UI repositions some frames (bars, party, minimap) on its own; put ours back after it.
local hooked = false
local function hookManager()
    if hooked or type(UIParent_ManageFramePositions) ~= "function" then return end
    local orig = UIParent_ManageFramePositions
    UIParent_ManageFramePositions = function(a1, a2, a3)
        orig(a1, a2, a3)
        T:ApplyAll()
    end
    hooked = true
end

local ev = CreateFrame("Frame", "ClassicPlusMoveEvents")
ev:RegisterEvent("VARIABLES_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PARTY_MEMBERS_CHANGED")
ev:SetScript("OnEvent", function()
    db()
    hookManager()
    T:ApplyAll()
    T:Refresh()
end)
