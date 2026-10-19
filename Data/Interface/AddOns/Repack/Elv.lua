--[[
    Elv.lua  (Classic+ Themes)
    The ElvUI-style theme: flat dark panels with 1-px borders, class-coloured unit frames either side
    of the screen centre, three 12-button action rows in one block, a square minimap with an info
    bar, and chat and Chronicle docked in panels along the bottom. Our own code and art, laid out
    the way ElvUI players know; nothing of ElvUI itself.

    Part of the UI Repack, a Workshop item: it runs only once a player adds the Repack
    (Classic+ menu > Workshop, or /workshop). The default is the stock UI.
    Every frame here registers with Move Anything, so all of it can be dragged and scaled.
]]--

local T = ClassicPlusUI
local W = WenillaCore

local BAR = "Interface\\TargetingFrame\\UI-StatusBar"
local FLAT = "Interface\\Buttons\\WHITE8X8"
local hidden = CreateFrame("Frame", "CPElvHidden")
hidden:Hide()

local E = {}
T.Elv = E

-- -- Look ---------------------------------------------------------------------------------------

local function skin(f, alpha)
    f:SetBackdrop({ bgFile = FLAT, edgeFile = FLAT, edgeSize = 1, insets = { left = 0, right = 0, top = 0, bottom = 0 } })
    f:SetBackdropColor(0.06, 0.06, 0.07, alpha or 0.88)
    f:SetBackdropBorderColor(0, 0, 0, 1)
end

local function panel(name, w, h)
    local f = CreateFrame("Frame", name, UIParent)
    f:SetWidth(w)
    f:SetHeight(h)
    f:SetFrameStrata("BACKGROUND")
    skin(f)
    return f
end

local function text(parent, size, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont("Fonts\\FRIZQT__.TTF", size or 11, "OUTLINE")
    fs:SetJustifyH(justify or "LEFT")
    return fs
end

local function stash(f)
    if not f then return end
    f:SetParent(hidden)
    if f.UnregisterAllEvents then f:UnregisterAllEvents() end
end

local function hideTex(name)
    local t = getglobal(name)
    if t then
        if t.SetTexture then t:SetTexture(nil) end
        t:Hide()
    end
end

local function short(n)
    if n >= 1000000 then return string.format("%.1fm", n / 1000000) end
    if n >= 10000 then return string.format("%.1fk", n / 1000) end
    return tostring(n)
end

local function classColor(unit)
    if W.Palette and W.Palette.Unit then
        local r, g, b = W.Palette.Unit(unit)
        if r then return r, g, b end
    end
    if UnitIsPlayer(unit) then
        local _, cls = UnitClass(unit)
        local c = cls and RAID_CLASS_COLORS and RAID_CLASS_COLORS[cls]
        if c then return c.r, c.g, c.b end
    end
    if UnitIsTapped and UnitIsTapped(unit) and not UnitIsTappedByPlayer(unit) then return 0.5, 0.5, 0.5 end
    local r = UnitReaction(unit, "player")
    if r and r <= 3 then return 0.78, 0.2, 0.2 end
    if r and r == 4 then return 0.85, 0.75, 0.25 end
    return 0.3, 0.75, 0.3
end

local POWER = { [0] = { 0.2, 0.42, 1 }, [1] = { 0.85, 0.2, 0.2 }, [2] = { 0.9, 0.55, 0.15 }, [3] = { 0.95, 0.85, 0.25 } }

-- -- Unit frames --------------------------------------------------------------------------------

local frames = {}

local function updateUnit(f)
    local u = f.unit
    if not UnitExists(u) then f:SetAlpha(f.always and 1 or 0); f:EnableMouse(false); if not f.always then return end end
    f:SetAlpha(1)
    f:EnableMouse(true)
    local hp, max = UnitHealth(u) or 0, UnitHealthMax(u) or 1
    if max == 0 then max = 1 end
    f.hp:SetMinMaxValues(0, max)
    f.hp:SetValue(hp)
    f.hp:SetStatusBarColor(classColor(u))
    local name = UnitName(u) or ""
    if f.showLevel then
        local lvl = UnitLevel(u)
        local cl = UnitClassification and UnitClassification(u)
        local tag = (lvl and lvl > 0) and tostring(lvl) or "??"
        if cl == "elite" or cl == "worldboss" or cl == "rareelite" then tag = tag .. "+" end
        name = tag .. " " .. name
    end
    f.name:SetText(name)
    if UnitIsDead(u) or UnitIsGhost(u) then
        f.hpText:SetText("Dead")
    elseif f.compact then
        f.hpText:SetText(math.floor(hp / max * 100 + .5) .. "%")
    else
        f.hpText:SetText(short(hp) .. " | " .. math.floor(hp / max * 100 + .5) .. "%")
    end
    if f.pp then
        local pmax = UnitManaMax(u) or 0
        if pmax > 0 then
            f.pp:Show()
            f.pp:SetMinMaxValues(0, pmax)
            f.pp:SetValue(UnitMana(u) or 0)
            local c = POWER[UnitPowerType(u) or 0] or POWER[0]
            f.pp:SetStatusBarColor(c[1], c[2], c[3])
        else
            f.pp:Hide()
        end
    end
    if f.auras then
        local n = 0
        for i = 1, 16 do
            local tex, count = UnitDebuff(u, i)
            if not tex then break end
            n = n + 1
            local a = f.auras[n]
            if not a then break end
            a.icon:SetTexture(tex)
            a.count:SetText((count and count > 1) and count or "")
            a.auraUnit, a.auraIndex, a.auraKind = u, i, "debuff"
            a:Show()
        end
        for i = 1, 16 do
            if n >= table.getn(f.auras) then break end
            local tex = UnitBuff(u, i)
            if not tex then break end
            n = n + 1
            local a = f.auras[n]
            a.icon:SetTexture(tex)
            a.count:SetText("")
            a.auraUnit, a.auraIndex, a.auraKind = u, i, "buff"
            a:Show()
        end
        for i = n + 1, table.getn(f.auras) do f.auras[i]:Hide() end
    end
end

local function unitFrame(name, unit, w, h, opts)
    opts = opts or {}
    local f = CreateFrame("Button", name, UIParent)
    f:SetWidth(w)
    f:SetHeight(h)
    f:SetFrameStrata("LOW")
    f.unit = unit
    f.compact = opts.compact
    f.showLevel = opts.level
    f.always = opts.always
    skin(f, 0.9)
    local ppH = opts.power and math.floor(h * 0.22) or 0
    f.hp = CreateFrame("StatusBar", nil, f)
    f.hp:SetStatusBarTexture(BAR)
    f.hp:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
    f.hp:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1 + (ppH > 0 and ppH + 1 or 0))
    if ppH > 0 then
        f.pp = CreateFrame("StatusBar", nil, f)
        f.pp:SetStatusBarTexture(BAR)
        f.pp:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 1, 1)
        f.pp:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
        f.pp:SetHeight(ppH)
    end
    f.name = text(f.hp, opts.compact and 10 or 12, "LEFT")
    f.name:SetPoint("LEFT", f.hp, "LEFT", 5, 0)
    f.hpText = text(f.hp, opts.compact and 10 or 12, "RIGHT")
    f.hpText:SetPoint("RIGHT", f.hp, "RIGHT", -5, 0)
    if opts.auras then
        f.auras = {}
        for i = 1, opts.auras do
            local a = CreateFrame("Frame", nil, f)
            a:SetWidth(22)
            a:SetHeight(22)
            a:SetPoint("TOPLEFT", f, "BOTTOMLEFT", (i - 1) * 24, -3)
            skin(a, 1)
            a.icon = a:CreateTexture(nil, "ARTWORK")
            a.icon:SetPoint("TOPLEFT", a, "TOPLEFT", 1, -1)
            a.icon:SetPoint("BOTTOMRIGHT", a, "BOTTOMRIGHT", -1, 1)
            a.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            a.count = text(a, 10, "RIGHT")
            a.count:SetPoint("BOTTOMRIGHT", a, "BOTTOMRIGHT", 0, 1)
            a:Hide()
            f.auras[i] = a
        end
    end
    f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    f:SetScript("OnClick", function()
        if arg1 == "RightButton" then
            -- our own dropdown: the stock PlayerFrameDropDown & co. are initialised only by
            -- Blizzard's frames, which this theme puts away (see WenillaCore/UnitMenu.lua)
            if UnitExists(unit) and W.UnitMenu then W.UnitMenu.Open(unit) end
        elseif SpellIsTargeting and SpellIsTargeting() then
            SpellTargetUnit(unit)
        elseif CursorHasItem and CursorHasItem() then
            DropItemOnUnit(unit)
        else
            TargetUnit(unit)
        end
    end)
    f:SetScript("OnEnter", function()
        if UnitExists(unit) and GameTooltip_SetDefaultAnchor then
            GameTooltip_SetDefaultAnchor(GameTooltip, this)
            GameTooltip:SetUnit(unit)
            GameTooltip:Show()
        end
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)
    frames[unit] = f
    T:Register(name, opts.label or name)
    return f
end

-- -- Action bars --------------------------------------------------------------------------------

local SIZE, GAP = 32, 2

local function skinButton(b)
    if not b or b.cpSkinned then return end
    local n = b:GetName()
    local icon = getglobal(n .. "Icon")
    if icon then
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        icon:ClearAllPoints()
        icon:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
        icon:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
    end
    local nt = getglobal(n .. "NormalTexture") or (b.GetNormalTexture and b:GetNormalTexture())
    if nt then nt:SetAlpha(0) end
    local bg = CreateFrame("Frame", nil, b)
    bg:SetAllPoints(b)
    bg:SetFrameLevel(math.max(0, b:GetFrameLevel() - 1))
    skin(bg, 1)
    local hk = getglobal(n .. "HotKey")
    if hk then
        hk:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
        hk:ClearAllPoints()
        hk:SetPoint("TOPRIGHT", b, "TOPRIGHT", -1, -2)
    end
    local mn = getglobal(n .. "Name")
    if mn then mn:Hide() end
    b:SetWidth(SIZE)
    b:SetHeight(SIZE)
    b.cpSkinned = true
end

local function row(holder, prefix, r)
    for i = 1, 12 do
        local b = getglobal(prefix .. i)
        if b then
            skinButton(b)
            b:SetParent(holder)
            b:ClearAllPoints()
            b:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 3 + (i - 1) * (SIZE + GAP), 3 + r * (SIZE + GAP))
            b:Show()
        end
    end
end

function E:Bars()
    local w = 12 * SIZE + 11 * GAP + 6
    local h = 3 * SIZE + 2 * GAP + 6
    local holder = panel("CPElvBars", w, h)
    holder:SetFrameStrata("LOW")
    holder:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 8)
    T:Register("CPElvBars", "Action bars")
    -- the stock bar's art goes; its buttons move into our block
    for _, t in ipairs({ "MainMenuBarTexture0", "MainMenuBarTexture1", "MainMenuBarTexture2", "MainMenuBarTexture3",
        "MainMenuBarLeftEndCap", "MainMenuBarRightEndCap", "MainMenuBarPageNumber", "MainMenuMaxLevelBar0",
        "MainMenuMaxLevelBar1", "MainMenuMaxLevelBar2", "MainMenuMaxLevelBar3", "MainMenuXPBarTexture0",
        "MainMenuXPBarTexture1", "MainMenuXPBarTexture2", "MainMenuXPBarTexture3", "BonusActionBarTexture0",
        "BonusActionBarTexture1", "ReputationWatchBarTexture0", "ReputationWatchBarTexture1",
        "ReputationWatchBarTexture2", "ReputationWatchBarTexture3", "SlidingActionBarTexture0", "SlidingActionBarTexture1",
        "ShapeshiftBarLeft", "ShapeshiftBarMiddle", "ShapeshiftBarRight" }) do hideTex(t) end
    for _, n in ipairs({ "ActionBarUpButton", "ActionBarDownButton", "MainMenuBarPerformanceBarFrame" }) do
        local f = getglobal(n)
        if f then f:Hide() end
    end
    if MainMenuBar then MainMenuBar:EnableMouse(false) end
    -- both bottom bars on (the Interface Options boxes)
    SHOW_MULTI_ACTIONBAR_1 = 1
    SHOW_MULTI_ACTIONBAR_2 = 1
    if MultiActionBar_Update then pcall(MultiActionBar_Update) end
    row(holder, "ActionButton", 0)
    row(holder, "MultiBarBottomLeftButton", 1)
    row(holder, "MultiBarBottomRightButton", 2)
    for i = 1, 12 do
        skinButton(getglobal("MultiBarRightButton" .. i))
        skinButton(getglobal("MultiBarLeftButton" .. i))
        skinButton(getglobal("BonusActionButton" .. i))
    end
    for i = 1, 10 do
        skinButton(getglobal("PetActionButton" .. i))
        skinButton(getglobal("ShapeshiftButton" .. i))
    end
    -- the experience bar: a thin line on top of the block
    if MainMenuExpBar then
        MainMenuExpBar:SetParent(holder)
        MainMenuExpBar:ClearAllPoints()
        MainMenuExpBar:SetPoint("BOTTOMLEFT", holder, "TOPLEFT", 0, 3)
        MainMenuExpBar:SetPoint("BOTTOMRIGHT", holder, "TOPRIGHT", 0, 3)
        MainMenuExpBar:SetHeight(5)
        MainMenuExpBar:SetStatusBarTexture(BAR)
        local xbg = CreateFrame("Frame", nil, MainMenuExpBar)
        xbg:SetPoint("TOPLEFT", MainMenuExpBar, "TOPLEFT", -1, 1)
        xbg:SetPoint("BOTTOMRIGHT", MainMenuExpBar, "BOTTOMRIGHT", 1, -1)
        xbg:SetFrameLevel(math.max(0, MainMenuExpBar:GetFrameLevel() - 1))
        skin(xbg, 1)
        hideTex("ExhaustionLevelFillBar")
    end
    if PetActionBarFrame then
        PetActionBarFrame:ClearAllPoints()
        PetActionBarFrame:SetPoint("BOTTOM", holder, "TOP", 0, 14)
    end
    if ShapeshiftBarFrame then
        ShapeshiftBarFrame:ClearAllPoints()
        ShapeshiftBarFrame:SetPoint("BOTTOMLEFT", holder, "TOPLEFT", 0, 14)
    end
    self.bars = holder
end

-- -- Minimap and the info bar ----------------------------------------------------------------------

function E:Minimap()
    if not Minimap then return end
    local holder = panel("CPElvMinimap", 172, 172)
    holder:SetFrameStrata("LOW")
    holder:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -8, -30)
    T:Register("CPElvMinimap", "Minimap")
    if MinimapCluster then MinimapCluster:EnableMouse(false) end
    Minimap:SetParent(holder)
    Minimap:ClearAllPoints()
    Minimap:SetPoint("TOPLEFT", holder, "TOPLEFT", 1, -1)
    Minimap:SetWidth(170)
    Minimap:SetHeight(170)
    if Minimap.SetMaskTexture then Minimap:SetMaskTexture(FLAT) end
    for _, n in ipairs({ "MinimapBorder", "MinimapBorderTop", "MinimapZoomIn", "MinimapZoomOut", "MinimapToggleButton",
        "MiniMapWorldMapButton", "MinimapZoneTextButton", "MinimapNorthTag", "GameTimeFrame" }) do
        local f = getglobal(n)
        if f then f:Hide() end
    end
    -- the Compass ring is round; on a square map only its pins stay useful, so the ring goes
    if Compass_RingFrame then Compass_RingFrame:SetParent(hidden) end
    Minimap:EnableMouseWheel(true)
    Minimap:SetScript("OnMouseWheel", function()
        if arg1 > 0 then Minimap_ZoomIn() else Minimap_ZoomOut() end
    end)
    for _, n in ipairs({ "MiniMapMailFrame", "MiniMapTracking", "MiniMapBattlefieldFrame", "MiniMapMeetingStoneFrame" }) do
        local f = getglobal(n)
        if f then f:SetParent(Minimap) end
    end
end

function E:InfoBar()
    local bar = CreateFrame("Frame", "CPElvInfoBar", UIParent)
    bar:SetHeight(20)
    bar:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
    bar:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", 0, 0)
    bar:SetFrameStrata("BACKGROUND")
    skin(bar, 0.85)
    local zone = text(bar, 11, "LEFT")
    zone:SetPoint("LEFT", bar, "LEFT", 10, 0)
    local stats = text(bar, 11, "RIGHT")
    stats:SetPoint("RIGHT", bar, "RIGHT", -10, 0)
    local t = 1
    bar:SetScript("OnUpdate", function()
        t = t + arg1
        if t < 1 then return end
        t = 0
        local sub = GetSubZoneText and GetSubZoneText() or ""
        local z = GetZoneText and GetZoneText() or ""
        zone:SetText("|cffffffff" .. z .. "|r" .. ((sub ~= "" and sub ~= z) and ("  |cffaab3bf" .. sub .. "|r") or ""))
        local fps = GetFramerate and math.floor(GetFramerate() + .5) or 0
        local _, _, lat = GetNetStats()
        local m = GetMoney and GetMoney() or 0
        local g = math.floor(m / 10000)
        local s = math.floor((m - g * 10000) / 100)
        local h, mi = GetGameTime()
        stats:SetText(string.format("FPS |cff6fe36a%d|r   MS |cff6fe36a%d|r   |cfff5d36b%dg %ds|r   %02d:%02d", fps, lat or 0, g, s, h or 0, mi or 0))
    end)
end

-- -- Chat, Chronicle, menu and bags -------------------------------------------------------------------

function E:Panels()
    local left = panel("CPElvChatPanel", 410, 196)
    left:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 8, 8)
    T:Register("CPElvChatPanel", "Chat panel")
    if ChatFrame1 then
        ChatFrame1:ClearAllPoints()
        ChatFrame1:SetPoint("TOPLEFT", left, "TOPLEFT", 6, -26)
        ChatFrame1:SetPoint("BOTTOMRIGHT", left, "BOTTOMRIGHT", -6, 6)
        if ChatFrame1.SetUserPlaced then pcall(ChatFrame1.SetUserPlaced, ChatFrame1, true) end
    end
    local right = panel("CPElvRightPanel", 310, 196)
    right:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -8, 8)
    T:Register("CPElvRightPanel", "Right panel")
    -- Chronicle docks into the right panel
    if Chronicle_Frame then
        Chronicle_Frame:ClearAllPoints()
        Chronicle_Frame:SetPoint("TOPLEFT", right, "TOPLEFT", 3, -3)
        Chronicle_Frame:SetPoint("TOPRIGHT", right, "TOPRIGHT", -3, -3)
    end
    -- the menu buttons and bags: a strip along the right panel's bottom
    local strip = CreateFrame("Frame", "CPElvMenuStrip", right)
    strip:SetHeight(26)
    strip:SetPoint("BOTTOMLEFT", right, "BOTTOMLEFT", 2, 2)
    strip:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", -2, 2)
    -- the menu bar's buttons as Open Vanilla's menu shows them (WenillaCore MicroMenu.lua)
    local function place(list)
        local x = 2
        for _, b in ipairs(list) do
            b:SetParent(strip)
            b:ClearAllPoints()
            b:SetScale(0.56)               -- 15.7 px wide on an 18 px step: a clear gap between buttons
            b:SetPoint("BOTTOMLEFT", strip, "BOTTOMLEFT", x / 0.56, -1 / 0.56)
            x = x + 18
        end
    end
    if W.MicroMenu and W.MicroMenu.SetPlacer then
        W.MicroMenu:SetPlacer(place)
    else
        local list = {}
        for _, n in ipairs({ "CharacterMicroButton", "SpellbookMicroButton", "TalentMicroButton", "QuestLogMicroButton",
            "SocialsMicroButton", "WorldMapMicroButton", "MainMenuMicroButton", "HelpMicroButton" }) do
            if getglobal(n) then table.insert(list, getglobal(n)) end
        end
        place(list)
    end
    local bags = { "MainMenuBarBackpackButton", "CharacterBag0Slot", "CharacterBag1Slot", "CharacterBag2Slot", "CharacterBag3Slot" }
    local bx = -2
    for _, n in ipairs(bags) do
        local b = getglobal(n)
        if b then
            b:SetParent(strip)
            b:ClearAllPoints()
            b:SetScale(0.6)
            b:SetPoint("BOTTOMRIGHT", strip, "BOTTOMRIGHT", bx / 0.6, 0)
            skinButton(b)
            bx = bx - 24
        end
    end
end

-- -- Buffs and the cast bar ---------------------------------------------------------------------------

function E:Buffs()
    if BuffFrame then
        BuffFrame:ClearAllPoints()
        BuffFrame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -190, -32)
    end
    if TemporaryEnchantFrame then
        TemporaryEnchantFrame:ClearAllPoints()
        TemporaryEnchantFrame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -190, -80)
    end
    for i = 0, 23 do
        local b = getglobal("BuffButton" .. i)
        if b and not b.cpSkinned then
            local icon = getglobal("BuffButton" .. i .. "Icon")
            if icon then icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
            local bg = CreateFrame("Frame", nil, b)
            bg:SetPoint("TOPLEFT", b, "TOPLEFT", -1, 1)
            bg:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 1, -1)
            bg:SetFrameLevel(math.max(0, b:GetFrameLevel() - 1))
            skin(bg, 1)
            b.cpSkinned = true
        end
    end
end

function E:CastBar()
    local c = CastingBarFrame
    if not c then return end
    hideTex("CastingBarBorder")
    hideTex("CastingBarFlash")
    hideTex("CastingBarSpark")
    c:SetStatusBarTexture(BAR)
    c:SetWidth(240)
    c:SetHeight(18)
    c:ClearAllPoints()
    c:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 200)
    local bg = CreateFrame("Frame", nil, c)
    bg:SetPoint("TOPLEFT", c, "TOPLEFT", -1, 1)
    bg:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 1, -1)
    bg:SetFrameLevel(math.max(0, c:GetFrameLevel() - 1))
    skin(bg, 1)
    if CastingBarText then
        CastingBarText:ClearAllPoints()
        CastingBarText:SetPoint("CENTER", c, "CENTER", 0, 0)
        CastingBarText:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    end
end

-- -- Putting it together ----------------------------------------------------------------------------

function E:UnitFrames()
    stash(PlayerFrame)
    stash(TargetFrame)
    stash(ComboFrame)
    for i = 1, 4 do stash(getglobal("PartyMemberFrame" .. i)) end
    local p = unitFrame("CPElvPlayer", "player", 230, 40, { power = true, label = "Player", always = true })
    p:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOM", -160, 150)
    local t = unitFrame("CPElvTarget", "target", 230, 40, { power = true, level = true, auras = 8, label = "Target" })
    t:SetPoint("BOTTOMLEFT", UIParent, "BOTTOM", 160, 150)
    local tt = unitFrame("CPElvToT", "targettarget", 110, 20, { compact = true, label = "Target of target" })
    tt:SetPoint("TOPLEFT", t, "TOPRIGHT", 6, 0)
    for i = 1, 4 do
        local pf = unitFrame("CPElvParty" .. i, "party" .. i, 160, 30, { compact = true, power = true, label = "Party " .. i })
        pf:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 12, -220 - (i - 1) * 36)
    end
    local ev = CreateFrame("Frame")
    for _, e in ipairs({ "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_MANA", "UNIT_MAXMANA", "UNIT_RAGE", "UNIT_MAXRAGE",
        "UNIT_ENERGY", "UNIT_MAXENERGY", "UNIT_FOCUS", "UNIT_DISPLAYPOWER", "UNIT_AURA", "UNIT_LEVEL", "UNIT_NAME_UPDATE",
        "PLAYER_TARGET_CHANGED", "PARTY_MEMBERS_CHANGED", "PLAYER_ENTERING_WORLD" }) do ev:RegisterEvent(e) end
    ev:SetScript("OnEvent", function()
        if arg1 and frames[arg1] then
            updateUnit(frames[arg1])
        else
            for _, f in pairs(frames) do updateUnit(f) end
        end
    end)
    -- target of target has no event in 1.12: a light poll
    local acc = 0
    ev:SetScript("OnUpdate", function()
        acc = acc + arg1
        if acc < 0.25 then return end
        acc = 0
        updateUnit(frames.targettarget)
        if UnitExists("target") then updateUnit(frames.target) end
    end)
    for _, f in pairs(frames) do updateUnit(f) end
end

function E:Apply()
    if self.applied then return end
    self.applied = true
    local steps = { "InfoBar", "Minimap", "Bars", "Panels", "Buffs", "CastBar", "UnitFrames" }
    for _, s in ipairs(steps) do
        local ok, err = pcall(self[s], self)
        if not ok then W.Print("Theme step " .. s .. " failed: " .. tostring(err)) end
    end
    if T.ApplyAll then T:ApplyAll() end
end
