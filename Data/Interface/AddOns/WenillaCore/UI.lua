--[[
    UI.lua
    Shared window kit for the Classic+ suite, so all ten addons share one look:
    a dark stone panel with the stock tooltip border, a charcoal title strip with an icon,
    the stock red close button, glossy stock status bars, coin read-outs and icon wells.
    Only stock 1.12 textures are required; custom art from Media/ is layered on when it loads.
]]--

local W = WenillaCore
local UI = {}
W.UI = UI

local floor = math.floor

UI.FONT = "Fonts\\FRIZQT__.TTF"
UI.BAR = "Interface\\TargetingFrame\\UI-StatusBar"
UI.WHITE = { 1, 1, 1 }
UI.GOLD = { 1, 0.82, 0 }

UI.BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}
UI.THIN = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 8, edgeSize = 8,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
}

-- Class tokens by the numeric ids the server sends, colours from the design sheet.
UI.CLASS_BY_ID = {
    [1] = "WARRIOR", [2] = "PALADIN", [3] = "HUNTER", [4] = "ROGUE", [5] = "PRIEST",
    [7] = "SHAMAN", [8] = "MAGE", [9] = "WARLOCK", [11] = "DRUID",
}
UI.CLASS_COLORS = {
    WARRIOR = { 0.70, 0.30, 0.22 }, MAGE = { 0.25, 0.58, 0.88 }, ROGUE = { 0.86, 0.76, 0.22 },
    PRIEST = { 0.78, 0.74, 0.58 }, DRUID = { 0.66, 0.34, 0.16 }, HUNTER = { 0.52, 0.72, 0.32 },
    SHAMAN = { 0.16, 0.44, 0.86 }, WARLOCK = { 0.56, 0.46, 0.78 }, PALADIN = { 0.88, 0.52, 0.66 },
}
UI.CLASS_ICONS = {
    WARRIOR = "Interface\\Icons\\Ability_Warrior_SavageBlow",
    MAGE = "Interface\\Icons\\Spell_Frost_IceStorm",
    ROGUE = "Interface\\Icons\\Ability_Rogue_Eviscerate",
    PRIEST = "Interface\\Icons\\Spell_Holy_HolyBolt",
    DRUID = "Interface\\Icons\\Ability_Druid_Rake",
    HUNTER = "Interface\\Icons\\Ability_Hunter_AimedShot",
    SHAMAN = "Interface\\Icons\\Spell_Nature_Lightning",
    WARLOCK = "Interface\\Icons\\Spell_Shadow_ShadowBolt",
    PALADIN = "Interface\\Icons\\Spell_Holy_SealOfMight",
}
UI.UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

-- "Warrior" / "WARRIOR" / 1 -> "WARRIOR"
function UI.ClassToken(c)
    if type(c) == "number" or tonumber(c) then return UI.CLASS_BY_ID[tonumber(c)] end
    if not c then return nil end
    return string.upper(c)
end

function UI.ClassColor(c)
    local t = UI.CLASS_COLORS[UI.ClassToken(c) or ""]
    if t then return t[1], t[2], t[3] end
    return 0.55, 0.55, 0.58
end

function UI.Font(fs, size, flags)
    if fs.SetFont then fs:SetFont(UI.FONT, size, flags or "") end
end

-- Header tint: sleek dark charcoal/slate title strip matching the design sheet.
function UI.Gradient(tex, tr, tg, tb, br, bg, bb)
    local mr = (tr + (br or tr)) / 2
    local mg = (tg + (bg or tg)) / 2
    local mb = (tb + (bb or tb)) / 2
    tex:SetTexture(mr, mg, mb, 0.95)
end

-- -- Close button --------------------------------------------------------------

function UI.CloseButton(parent, onClick, size)
    local ok, b = pcall(CreateFrame, "Button", nil, parent, "UIPanelCloseButton")
    if not ok or not b then
        b = CreateFrame("Button", nil, parent)
        b:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
        b:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
        b:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
    end
    size = size or 24
    b:SetWidth(size)
    b:SetHeight(size)
    b:SetScript("OnClick", onClick or function() parent:Hide() end)
    return b
end

-- -- Window --------------------------------------------------------------------
-- opts: width, height, title, icon, point = {point, relTo, relPoint, x, y},
--       close (default true), strata, titleAlign ("CENTER"|"LEFT"),
--       skin (true: the window follows the player's skin, see Skins at the end of this file)
function UI.Window(name, opts)
    local f = CreateFrame("Frame", name, UIParent)
    f:SetWidth(opts.width or 220)
    f:SetHeight(opts.height or 120)
    f.defaultPoint = opts.point or { "CENTER", UIParent, "CENTER", 0, 0 }
    local d = f.defaultPoint
    f:SetPoint(d[1], d[2] or UIParent, d[3], d[4], d[5])
    f:SetFrameStrata(opts.strata or "MEDIUM")
    f:SetBackdrop(UI.BACKDROP)
    f:SetBackdropColor(0.07, 0.07, 0.08, 0.94)
    f:SetBackdropBorderColor(0.62, 0.62, 0.66, 1)
    f:SetMovable(true)
    f:EnableMouse(true)
    if f.SetClampedToScreen then f:SetClampedToScreen(true) end

    local bar = f:CreateTexture(nil, "ARTWORK")
    bar:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -4)
    bar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    bar:SetHeight(20)
    UI.Gradient(bar, 0.21, 0.21, 0.23, 0.11, 0.11, 0.12)
    f.titleBar = bar

    local rule = f:CreateTexture(nil, "ARTWORK")
    rule:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, 0)
    rule:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", 0, 0)
    rule:SetHeight(1)
    rule:SetTexture(0.36, 0.36, 0.40, 1)
    f.titleRule = rule
    f.titleAlign = opts.titleAlign or "CENTER"

    local x = 6
    if opts.icon then
        local ic = f:CreateTexture(nil, "OVERLAY")
        ic:SetWidth(14)
        ic:SetHeight(14)
        ic:SetPoint("LEFT", bar, "LEFT", 4, 0)
        ic:SetTexture(opts.icon)
        ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        f.icon = ic
        x = 22
    end

    local t = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    UI.Font(t, 11, "OUTLINE")
    t:SetShadowOffset(1, -1)
    t:SetShadowColor(0, 0, 0, 1)
    if (opts.titleAlign or "CENTER") == "LEFT" then
        t:SetPoint("LEFT", bar, "LEFT", x, 0)
    else
        t:SetPoint("CENTER", bar, "CENTER", 0, 0)
    end
    t:SetText(opts.title or "")
    t:SetTextColor(0.95, 0.93, 0.88)
    f.title = t

    if opts.close ~= false then
        local c = UI.CloseButton(f, opts.onClose, 22)
        c:SetPoint("RIGHT", bar, "RIGHT", 4, 0)
        f.closeButton = c
    end

    -- the title strip is the drag handle
    local h = CreateFrame("Button", nil, f)
    h:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
    h:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -20, 0)
    h:RegisterForDrag("LeftButton")
    h:SetScript("OnDragStart", function() f:StartMoving() end)
    h:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        W:SavePosition(f)
    end)
    f.dragHandle = h

    W:TrackPosition(f)
    if opts.classicFrame then
        f.classicFrame = true
        f.chromeIcon = opts.portrait or opts.icon
    end
    if opts.skin then UI.SkinWindow(f) end
    return f
end

-- -- Icon well -----------------------------------------------------------------

function UI.IconBox(parent, size)
    local box = CreateFrame("Frame", nil, parent)
    box:SetWidth(size)
    box:SetHeight(size)
    local bg = box:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(box)
    bg:SetTexture(0, 0, 0, 1)
    local edge = box:CreateTexture(nil, "BORDER")
    edge:SetPoint("TOPLEFT", box, "TOPLEFT", 0, 0)
    edge:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", 0, 0)
    edge:SetTexture(0.35, 0.35, 0.38, 1)
    local icon = box:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", box, "TOPLEFT", 1, -1)
    icon:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -1, 1)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    box.icon = icon
    box.edge = edge
    return box
end

-- -- Bar row -------------------------------------------------------------------
-- A row: optional icon well, a glossy bar on a dark track, and up to three texts.
-- opts: width, height, icon (bool)
function UI.Bar(parent, opts)
    local h = opts.height or 18
    local row = CreateFrame("Button", nil, parent)
    row:SetWidth(opts.width or 180)
    row:SetHeight(h)

    local left = 0
    if opts.icon then
        row.iconBox = UI.IconBox(row, h)
        row.iconBox:SetPoint("LEFT", row, "LEFT", 0, 0)
        row.icon = row.iconBox.icon
        left = h + 3
    end

    local track = row:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("TOPLEFT", row, "TOPLEFT", left, 0)
    track:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
    track:SetTexture(0.04, 0.04, 0.05, 0.85)
    row.track = track

    local sb = CreateFrame("StatusBar", nil, row)
    sb:SetPoint("TOPLEFT", track, "TOPLEFT", 0, 0)
    sb:SetPoint("BOTTOMRIGHT", track, "BOTTOMRIGHT", 0, 0)
    sb:SetStatusBarTexture(UI.BAR)
    sb:SetMinMaxValues(0, 1)
    sb:SetValue(0)
    row.bar = sb

    local textLevel = CreateFrame("Frame", nil, row)
    textLevel:SetAllPoints(track)
    textLevel:SetFrameLevel(sb:GetFrameLevel() + 2)

    local name = textLevel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    name:SetPoint("LEFT", track, "LEFT", 5, 0)
    name:SetJustifyH("LEFT")
    UI.Font(name, 10, "OUTLINE")
    name:SetShadowOffset(1, -1)
    name:SetShadowColor(0, 0, 0, 1)
    name:SetTextColor(1, 1, 1, 1)
    row.left = name

    local value = textLevel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    value:SetPoint("RIGHT", track, "RIGHT", -5, 0)
    value:SetJustifyH("RIGHT")
    UI.Font(value, 10, "OUTLINE")
    value:SetShadowOffset(1, -1)
    value:SetShadowColor(0, 0, 0, 1)
    value:SetTextColor(1, 1, 1, 1)
    row.right = value

    local mid = textLevel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    mid:SetJustifyH("RIGHT")
    UI.Font(mid, 10, "OUTLINE")
    mid:SetShadowOffset(1, -1)
    mid:SetShadowColor(0, 0, 0, 1)
    mid:SetTextColor(0.92, 0.92, 0.95, 1)
    row.mid = mid

    function row:SetColor(r, g, b, a)
        self.bar:SetStatusBarColor(r, g, b, a or 0.95)
    end
    function row:SetFraction(frac)
        if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
        self.bar:SetValue(frac)
    end
    return row
end

-- -- Money ---------------------------------------------------------------------

-- 1.12 font strings have no |T escapes, so coins in text are coloured letters.
function UI.CoinText(copper)
    copper = floor(tonumber(copper) or 0)
    local g = floor(copper / 10000)
    local s = floor((copper - g * 10000) / 100)
    local c = copper - g * 10000 - s * 100
    local out = ""
    if g > 0 then out = g .. "|cffffd700g|r " end
    if g > 0 or s > 0 then out = out .. s .. "|cffc7c7cfs|r " end
    out = out .. c .. "|cffeda55fc|r"
    return out
end

local COIN = { { 0, 0.25 }, { 0.25, 0.5 }, { 0.5, 0.75 } }

-- Gold, silver and copper with the stock coin icons, right-aligned.
function UI.Money(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetWidth(160)
    f:SetHeight(14)
    local parts = {}
    local anchor, anchorPoint = f, "RIGHT"
    for i = 3, 1, -1 do
        local icon = f:CreateTexture(nil, "ARTWORK")
        icon:SetTexture("Interface\\MoneyFrame\\UI-MoneyIcons")
        icon:SetTexCoord(COIN[i][1], COIN[i][2], 0, 1)
        icon:SetWidth(12)
        icon:SetHeight(12)
        icon:SetPoint("RIGHT", anchor, anchorPoint, i == 3 and 0 or -6, 0)
        local text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("RIGHT", icon, "LEFT", -1, 0)
        parts[i] = { icon = icon, text = text }
        anchor, anchorPoint = text, "LEFT"
    end
    function f:SetMoney(copper)
        copper = floor(tonumber(copper) or 0)
        local g = floor(copper / 10000)
        local s = floor((copper - g * 10000) / 100)
        local c = copper - g * 10000 - s * 100
        parts[1].text:SetText(g)
        parts[2].text:SetText(s)
        parts[3].text:SetText(c)
    end
    f:SetMoney(0)
    return f
end

-- -- Buttons -------------------------------------------------------------------

-- The stock red panel button; a plain bordered button if the template is missing.
function UI.Button(parent, text, width, height, onClick)
    local ok, b = pcall(CreateFrame, "Button", nil, parent, "UIPanelButtonTemplate")
    if not ok or not b then
        b = CreateFrame("Button", nil, parent)
        b:SetBackdrop(UI.THIN)
        b:SetBackdropColor(0.35, 0.05, 0.03, 0.95)
        b:SetBackdropBorderColor(0.75, 0.6, 0.3, 1)
        local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("CENTER", b, "CENTER", 0, 0)
        b.label = fs
        b.SetText = function(self, t) self.label:SetText(t) end
    end
    b:SetWidth(width or 80)
    b:SetHeight(height or 20)
    b:SetText(text or "")
    if onClick then b:SetScript("OnClick", onClick) end
    return b
end

-- -- Nameplates ----------------------------------------------------------------
-- 1.12 nameplates are unnamed children of WorldFrame whose first region is the
-- Nameplate-Border texture; regions are border, glow, name, level, boss icon, raid icon,
-- and the first child is the health StatusBar. They carry no unit id, only a name.

W.Plates = { known = {}, list = {}, onNew = {} }
local P = W.Plates
local lastKids = -1

local function isPlate(f)
    if f:GetName() then return false end
    local border = f:GetRegions()
    if not border or not border.GetTexture then return false end
    local tex = border:GetTexture()
    return tex and string.find(string.lower(tex), "nameplate%-border") and true or false
end

function P.Scan()
    local n = WorldFrame:GetNumChildren()
    if n == lastKids then return end
    lastKids = n
    local kids = { WorldFrame:GetChildren() }
    for i = 1, table.getn(kids) do
        local f = kids[i]
        if not P.known[f] and isPlate(f) then
            P.known[f] = true
            table.insert(P.list, f)
            for _, fn in ipairs(P.onNew) do pcall(fn, f) end
        end
    end
end

function P.Parts(f)
    local border, glow, name, level, boss, raid = f:GetRegions()
    local health = f:GetChildren()
    return { border = border, glow = glow, name = name, level = level, health = health, boss = boss, raid = raid }
end

function P.Name(f)
    local _, _, name = f:GetRegions()
    return name and name.GetText and name:GetText()
end

-- Visible plates whose name matches; the target's plate when its health also matches.
function P.Find(name, preferTarget)
    local best
    for _, f in ipairs(P.list) do
        if f:IsVisible() and P.Name(f) == name then
            if not preferTarget then return f end
            local hb = f:GetChildren()
            if hb and UnitExists("target") and UnitName("target") == name then
                local _, max = hb:GetMinMaxValues()
                local hp, hpmax = UnitHealth("target"), UnitHealthMax("target")
                if max and max > 0 and hpmax and hpmax > 0
                    and math.abs(hb:GetValue() / max - hp / hpmax) < 0.02 then
                    return f
                end
            end
            best = best or f
        end
    end
    return best
end

function P.OnNew(fn)
    table.insert(P.onNew, fn)
    for _, f in ipairs(P.list) do pcall(fn, f) end
end

-- ===========================================================================================
-- Kit v2 (Open Vanilla 1.15): switches, tabs, a settings sheet, toasts, scroll lists, menus.
-- Every Classic+ window builds from these so they look and behave alike. Art comes from
-- Interface\ClassicPlus (tools/gen_suite_art.py); each piece has a flat-colour fallback.
-- ===========================================================================================

UI.SLATE = { 0.07, 0.075, 0.09, 0.94 }      -- panel face
UI.INSET = { 0.035, 0.04, 0.05, 0.85 }      -- recessed areas (lists, inputs)
UI.EDGE = { 0.36, 0.38, 0.44, 1 }           -- thin border
UI.MUTED = { 0.62, 0.64, 0.70 }             -- secondary text
UI.ACCENT = { 1, 0.82, 0 }                  -- gold

-- A flat 1 px border + face on any frame, without the tooltip backdrop's rounded look.
-- style: "panel" | "inset" | "raised"
function UI.Skin(f, style)
    local face = (style == "inset") and UI.INSET or UI.SLATE
    if f.SetBackdrop then
        f:SetBackdrop(UI.THIN)
        f.backdropInfo = UI.THIN
        f:SetBackdropColor(face[1], face[2], face[3], face[4])
        if style == "raised" then
            f:SetBackdropBorderColor(0.50, 0.52, 0.58, 1)
        else
            f:SetBackdropBorderColor(UI.EDGE[1], UI.EDGE[2], UI.EDGE[3], UI.EDGE[4])
        end
    end
    return f
end

function UI.Label(parent, size, color, flags, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", "GameFontHighlightSmall")
    UI.Font(fs, size or 11, flags)
    if color then fs:SetTextColor(color[1], color[2], color[3], color[4] or 1) end
    fs:SetJustifyH("LEFT")
    return fs
end

function UI.Divider(parent, width)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetHeight(1)
    if width then t:SetWidth(width) end
    t:SetTexture(UI.EDGE[1], UI.EDGE[2], UI.EDGE[3], 0.55)
    return t
end

-- -- Switch ------------------------------------------------------------------------------
-- A pill toggle with a sliding gold knob. opts: width (default 36; height is half),
-- get() -> bool, set(bool), tooltip, disabled. Methods: SetOn(on, instant), GetOn(),
-- SetEnabled(bool), Refresh() (re-reads get()).

local SWITCH_TIME = 0.12

function UI.Switch(parent, opts)
    opts = opts or {}
    local w = opts.width or 36
    local h = floor(w / 2)
    local s = CreateFrame("Button", opts.name, parent)
    s:SetWidth(w)
    s:SetHeight(h)

    local glow = s:CreateTexture(nil, "BACKGROUND")
    glow:SetPoint("CENTER", s, "CENTER", 0, 0)
    glow:SetWidth(w * 1.25)
    glow:SetHeight(h * 1.25)
    W:Art(glow, "Switch_Glow", { 0.3, 0.9, 0.5, 0 })
    s.glow = glow

    local track = s:CreateTexture(nil, "ARTWORK")
    track:SetAllPoints(s)
    s.track = track

    local knob = s:CreateTexture(nil, "OVERLAY")
    knob:SetWidth(h + 4)
    knob:SetHeight(h + 4)
    s.knob = knob
    s.hasArt = W:Art(knob, "Switch_Knob", nil)
    if not s.hasArt then
        knob:SetTexture(UI.ACCENT[1], UI.ACCENT[2], UI.ACCENT[3], 1)
        knob:SetWidth(h - 4)
        knob:SetHeight(h - 4)
    end

    local travel = w - h            -- knob centre moves from h/2 to w - h/2
    s.pos = 0                       -- 0 = off, 1 = on (animated)
    s.on = false
    s.enabled = true

    local function place()
        knob:ClearAllPoints()
        knob:SetPoint("CENTER", s, "LEFT", h / 2 + travel * s.pos, 0)
    end

    local function paint()
        if s.on then
            if not W:Art(track, "Switch_Track_On", nil) then track:SetTexture(0.20, 0.50, 0.18, 1) end
            glow:SetAlpha(s.enabled and 0.55 or 0)
        else
            if not W:Art(track, "Switch_Track_Off", nil) then track:SetTexture(0.16, 0.17, 0.20, 1) end
            glow:SetAlpha(0)
        end
        local a = s.enabled and 1 or 0.4
        track:SetAlpha(a)
        knob:SetAlpha(a)
    end

    local function onUpdate()
        local target = s.on and 1 or 0
        local step = (arg1 or 0.016) / SWITCH_TIME
        if s.pos < target then s.pos = math.min(target, s.pos + step)
        elseif s.pos > target then s.pos = math.max(target, s.pos - step) end
        place()
        if s.pos == target then s:SetScript("OnUpdate", nil) end
    end

    function s:SetOn(on, instant)
        on = on and true or false
        local changed = (on ~= self.on)
        self.on = on
        paint()
        if instant or not changed then
            self.pos = on and 1 or 0
            place()
        else
            self:SetScript("OnUpdate", onUpdate)
        end
    end
    function s:GetOn() return self.on end
    function s:SetEnabled(e)
        self.enabled = e and true or false
        paint()
    end
    function s:Refresh()
        if opts.get then self:SetOn(opts.get(), true) end
    end
    s:SetScript("OnClick", function()
        if not s.enabled then return end
        s:SetOn(not s.on)
        if PlaySound then PlaySound(s.on and "igMainMenuOptionCheckBoxOn" or "igMainMenuOptionCheckBoxOff") end
        if opts.set then opts.set(s.on) end
    end)
    if opts.tooltip then
        s:SetScript("OnEnter", function()
            if GameTooltip then
                GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
                GameTooltip:SetText(opts.tooltip, 1, 1, 1, 1, 1)
                GameTooltip:Show()
            end
        end)
        s:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    end
    s:SetOn(opts.get and opts.get() or opts.on, true)
    if opts.disabled then s:SetEnabled(false) end
    return s
end

-- A settings row: title (white), description (grey, wraps), and a switch on the right.
-- opts: width, label, sub, get, set. Returns the row; row.switch is the switch.
function UI.SwitchRow(parent, opts)
    local width = opts.width or 340
    local row = CreateFrame("Frame", nil, parent)
    row:SetWidth(width)
    local sw = UI.Switch(row, { width = 34, get = opts.get, set = opts.set, tooltip = opts.tooltip })
    sw:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, -1)
    local lbl = UI.Label(row, 11, { 1, 1, 1 })
    lbl:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    lbl:SetWidth(width - 46)
    lbl:SetText(opts.label or "")
    local sub = UI.Label(row, 10, UI.MUTED)
    sub:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 0, -2)
    sub:SetWidth(width - 46)
    if sub.SetNonSpaceWrap then sub:SetNonSpaceWrap(false) end
    sub:SetText(opts.sub or "")
    row.label, row.sub, row.switch = lbl, sub, sw
    -- height: one line of title + the wrapped description (about 46 characters a line at 10 pt)
    local chars = string.len(opts.sub or "")
    local lines = (chars > 0) and floor((chars * 5.4) / math.max(60, width - 46)) + 1 or 0
    row:SetHeight(16 + lines * 12)
    function row:Refresh() sw:Refresh() end
    return row
end

-- -- Tabs --------------------------------------------------------------------------------
-- Flat tabs joined to a panel's top edge. The active tab has a gold underline; unread tabs a dot.
-- opts: tabs = { {key=, label=, icon=?}, ... }, onSelect(key), onAdd() (shows a "+" tab),
-- onMenu(key, tabButton) (right-click), height (default 20), maxWidth, skin (true: follow the skin).
-- Methods: Select(key, silent), SetTabs(list), SetUnread(key, bool), Selected().

function UI.Tabs(parent, opts)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(opts.height or 20)
    bar.buttons = {}
    bar.selected = nil

    local function style(b)
        local sel = (b.key == bar.selected)
        local th = opts.skin and UI.Theme()
        if th and not th.flat then
            -- Classic / Brass: dark tabs on the stone, the chosen one lit in gold
            b.bg:SetTexture(sel and 0.30 or 0, sel and 0.22 or 0, sel and 0.06 or 0, sel and 0.85 or 0.45)
            b.edge:SetAlpha(0)
        else
            b.bg:SetTexture(sel and 0.13 or 0.06, sel and 0.135 or 0.065, sel and 0.16 or 0.08, sel and 0.98 or 0.85)
            b.edge:SetAlpha(1)
        end
        b.line:SetAlpha(sel and 1 or 0)
        if sel then b.text:SetTextColor(1, 0.85, 0.3) else b.text:SetTextColor(0.72, 0.73, 0.78) end
        if b.dot then b.dot:SetAlpha((b.unread and not sel) and 1 or 0) end
    end

    local function make(i)
        local b = CreateFrame("Button", nil, bar)
        b:SetHeight(bar:GetHeight())
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints(b)
        b.line = b:CreateTexture(nil, "ARTWORK")
        b.line:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 2, 0)
        b.line:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 0)
        b.line:SetHeight(2)
        b.line:SetTexture(UI.ACCENT[1], UI.ACCENT[2], UI.ACCENT[3], 1)
        b.edge = b:CreateTexture(nil, "BORDER")
        b.edge:SetPoint("TOPRIGHT", b, "TOPRIGHT", 0, -3)
        b.edge:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, 3)
        b.edge:SetWidth(1)
        b.edge:SetTexture(UI.EDGE[1], UI.EDGE[2], UI.EDGE[3], 0.5)
        b.text = UI.Label(b, 10, nil, "OUTLINE")
        b.text:SetPoint("CENTER", b, "CENTER", 0, 0)
        b.text:SetJustifyH("CENTER")
        b.dot = b:CreateTexture(nil, "OVERLAY")
        b.dot:SetWidth(5)
        b.dot:SetHeight(5)
        b.dot:SetPoint("TOPRIGHT", b, "TOPRIGHT", -3, -3)
        b.dot:SetTexture(UI.ACCENT[1], UI.ACCENT[2], UI.ACCENT[3], 1)
        b:SetScript("OnClick", function()
            if b.key == "__add" then
                if opts.onAdd then opts.onAdd() end
            elseif arg1 == "RightButton" then
                if opts.onMenu then opts.onMenu(b.key, b) end
            else
                bar:Select(b.key)
            end
        end)
        b:SetScript("OnEnter", function() if b.key ~= bar.selected then b.text:SetTextColor(1, 1, 1) end end)
        b:SetScript("OnLeave", function() style(b) end)
        bar.buttons[i] = b
        return b
    end

    function bar:SetTabs(list)
        self.tabs = list
        local all = {}
        for _, t in ipairs(list) do table.insert(all, t) end
        if opts.onAdd then table.insert(all, { key = "__add", label = "+" }) end
        local x = 0
        for i, t in ipairs(all) do
            local b = self.buttons[i] or make(i)
            b.key = t.key
            b.text:SetText(t.label or t.key)
            local w = (t.key == "__add") and 20 or math.min(opts.maxWidth or 110, (b.text:GetStringWidth() or 40) + 18)
            b:SetWidth(w)
            b:ClearAllPoints()
            b:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", x, 0)
            x = x + w + 1
            b:Show()
            style(b)
        end
        for i = table.getn(all) + 1, table.getn(self.buttons) do self.buttons[i]:Hide() end
        self:SetWidth(math.max(1, x))
        if not self.selected and list[1] then self:Select(list[1].key, true) end
    end
    function bar:Select(key, silent)
        self.selected = key
        for _, b in ipairs(self.buttons) do
            if b.key == key then b.unread = nil end
            style(b)
        end
        if not silent and opts.onSelect then opts.onSelect(key) end
    end
    function bar:Selected() return self.selected end
    function bar:SetUnread(key, on)
        for _, b in ipairs(self.buttons) do
            if b.key == key then b.unread = on and true or nil; style(b) end
        end
    end
    function bar:Button(key)
        for _, b in ipairs(self.buttons) do if b.key == key and b:IsShown() then return b end end
    end
    if opts.tabs then bar:SetTabs(opts.tabs) end
    if opts.skin then UI.OnSkin(function() for _, b in ipairs(bar.buttons) do style(b) end end) end
    return bar
end

-- -- Classic frame: the 1.12 Character / Social frame at any size ---------------------------------
-- The stock frames are four fixed 256/128 textures (UI-Character-General-*) laid out 352x440 with a
-- round portrait top-left, a title strip, a header band and a marble body. Here they are cut into a
-- 3x3 grid: the corners keep their pixels, the middle row and column repeat (never stretch) a slice
-- of the original, so a bigger window keeps the stock look. The textures are the player's own client
-- files; nothing of Blizzard's ships with the suite.
--   f.portrait  60x60 round portrait (SetPortraitToTexture when the client has it)
--   f.title     the title on the strip; f.titleBar the strip itself (for anchoring buttons)
--   f.toolbar   the header band right of the portrait (search boxes, buttons)
--   f.body      the marble area under the band
--   f.tabs      bottom tabs (UI.ClassicTabs) when opts.tabs is given
local GENERAL = "Interface\\PaperDollInfoFrame\\UI-Character-General-"
local CF_COLS = { { 0, 140, false }, { 140, 254, true }, { 256, 352, false } }   -- x0, x1, repeats
local CF_ROWS = { { 0, 110, false }, { 110, 254, true }, { 380, 440, false } }   -- y0, y1, repeats
UI.CLASSIC_MIN_W, UI.CLASSIC_MIN_H = 352, 440

local function cfPiece(cx0, cx1, cy0, cy1)
    local right, bottom = cx0 >= 256, cy0 >= 256
    local file = GENERAL .. (bottom and "Bottom" or "Top") .. (right and "Right" or "Left")
    local tw = right and 128 or 256
    local ox, oy = right and 256 or 0, bottom and 256 or 0
    return file, (cx0 - ox) / tw, (cx1 - ox) / tw, (cy0 - oy) / 256, (cy1 - oy) / 256
end

function UI.LayoutClassicFrame(f)
    -- the chrome round a smaller window may go below the stock size: down to the fixed rows/columns
    local minW, minH = UI.CLASSIC_MIN_W, UI.CLASSIC_MIN_H
    if f.cfAnySize then minW, minH = 240, 180 end
    local W = math.max(minW, math.floor(f:GetWidth() or minW))
    local H = math.max(minH, math.floor(f:GetHeight() or minH))
    if f.cfW == W and f.cfH == H then return end
    f.cfW, f.cfH = W, H
    f.cfPool = f.cfPool or {}
    local used = 0
    local fixedW, fixedH = 0, 0
    for _, c in ipairs(CF_COLS) do if not c[3] then fixedW = fixedW + c[2] - c[1] end end
    for _, r in ipairs(CF_ROWS) do if not r[3] then fixedH = fixedH + r[2] - r[1] end end
    local y = 0
    for _, r in ipairs(CF_ROWS) do
        local rh = r[3] and (H - fixedH) or (r[2] - r[1])
        local x = 0
        for _, c in ipairs(CF_COLS) do
            local cw = c[3] and (W - fixedW) or (c[2] - c[1])
            local pw, ph = c[2] - c[1], r[2] - r[1]
            local yy = 0
            while yy < rh do
                local h = math.min(ph, rh - yy)
                local xx = 0
                while xx < cw do
                    local w = math.min(pw, cw - xx)
                    used = used + 1
                    local t = f.cfPool[used]
                    if not t then
                        t = f:CreateTexture(nil, "BORDER")
                        f.cfPool[used] = t
                    end
                    local file, l, rr, top, bot = cfPiece(c[1], c[1] + w, r[1], r[1] + h)
                    t:SetTexture(file)
                    t:SetTexCoord(l, rr, top, bot)
                    t:ClearAllPoints()
                    t:SetPoint("TOPLEFT", f, "TOPLEFT", x + xx, -(y + yy))
                    t:SetWidth(w)
                    t:SetHeight(h)
                    t:Show()
                    xx = xx + w
                end
                yy = yy + h
            end
            x = x + cw
        end
        y = y + rh
    end
    for i = used + 1, table.getn(f.cfPool) do f.cfPool[i]:Hide() end
    f.cfPieces = used
    if f.title then f.title:SetPoint("CENTER", f, "TOPLEFT", (72 + W - 30) / 2, -21) end
end

function UI.ClassicFrame(name, opts)
    local f = CreateFrame("Frame", name, UIParent)
    f:SetWidth(math.max(UI.CLASSIC_MIN_W, opts.width or UI.CLASSIC_MIN_W))
    f:SetHeight(math.max(UI.CLASSIC_MIN_H, opts.height or UI.CLASSIC_MIN_H))
    f.defaultPoint = opts.point or { "CENTER", UIParent, "CENTER", 0, 0 }
    local d = f.defaultPoint
    f:SetPoint(d[1], d[2] or UIParent, d[3], d[4], d[5])
    f:SetFrameStrata(opts.strata or "MEDIUM")
    f:SetMovable(true)
    f:EnableMouse(true)
    if f.SetClampedToScreen then f:SetClampedToScreen(true) end
    f.classic = true

    -- portrait under the ring (the ring's middle is see-through in the art)
    -- a named texture: the browser engine's SetPortraitToTexture takes the texture's NAME (string),
    -- not the texture object (passing the object raised an error and broke every window built here)
    UI.portraitN = (UI.portraitN or 0) + 1
    local pname = (name or ("WenillaClassicFrame" .. UI.portraitN)) .. "Portrait"
    local p = f:CreateTexture(pname, "BACKGROUND")
    p:SetWidth(60)
    p:SetHeight(60)
    p:SetPoint("TOPLEFT", f, "TOPLEFT", 7, -6)
    f.portrait = p
    f.icon = p
    function f:SetPortrait(path, art)
        if art and W:Art(p, art, nil) then p:SetTexCoord(0, 1, 0, 1) return end
        if not path then return end
        if SetPortraitToTexture and (pcall(SetPortraitToTexture, pname, path) or pcall(SetPortraitToTexture, p, path)) then
            return
        end
        p:SetTexture(path)
    end
    if opts.portrait or opts.portraitArt then f:SetPortrait(opts.portrait, opts.portraitArt) end

    -- the title strip (an invisible region used as the anchor and drag handle)
    local bar = f:CreateTexture(nil, "ARTWORK")
    bar:SetPoint("TOPLEFT", f, "TOPLEFT", 74, -12)
    bar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -32, -12)
    bar:SetHeight(18)
    bar:SetTexture(nil)
    f.titleBar = bar
    local t = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    t:SetText(opts.title or "")
    f.title = t

    local tb = CreateFrame("Frame", nil, f)
    tb:SetPoint("TOPLEFT", f, "TOPLEFT", 74, -38)
    tb:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -38)
    tb:SetHeight(28)
    f.toolbar = tb
    local body = CreateFrame("Frame", nil, f)
    body:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -76)
    body:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 10)
    f.body = body

    if opts.close ~= false then
        local c = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        c:SetWidth(32)
        c:SetHeight(32)
        c:SetPoint("CENTER", f, "TOPRIGHT", -14, -24)
        c:SetScript("OnClick", function() if opts.onClose then opts.onClose() else f:Hide() end end)
        f.closeButton = c
    end

    local h = CreateFrame("Button", nil, f)
    h:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    h:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", -32, -34)
    h:RegisterForDrag("LeftButton")
    h:SetScript("OnDragStart", function() f:StartMoving() end)
    h:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        W:SavePosition(f)
    end)
    f.dragHandle = h

    UI.LayoutClassicFrame(f)
    f:SetScript("OnSizeChanged", function() UI.LayoutClassicFrame(this) end)
    if opts.tabs then
        f.tabs = UI.ClassicTabs(f, { tabs = opts.tabs, onSelect = opts.onTab })
        f.tabs:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 11, 6)
    end
    W:TrackPosition(f)
    return f
end

-- Bottom tabs as the stock Character / Friends frames draw them (UI-Character-ActiveTab /
-- InActiveTab cut into caps and a middle). Same API as UI.Tabs: SetTabs, Select, Selected, Button,
-- SetUnread.
local TAB_ACTIVE = "Interface\\PaperDollInfoFrame\\UI-Character-ActiveTab"
local TAB_INACTIVE = "Interface\\PaperDollInfoFrame\\UI-Character-InActiveTab"
local TAB_HILITE = "Interface\\PaperDollInfoFrame\\UI-Character-Tab-Highlight"

function UI.ClassicTabs(parent, opts)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(32)
    bar.bottomTabs = true                          -- MicroMenu: the window tabs go on after these
    bar.buttons = {}

    local function paint(b)
        local sel = (b.key == bar.selected)
        local file = sel and TAB_ACTIVE or TAB_INACTIVE
        b.l:SetTexture(file); b.m:SetTexture(file); b.r:SetTexture(file)
        b.text:ClearAllPoints()
        b.text:SetPoint("CENTER", b, "CENTER", 0, sel and -3 or 2)
        if sel then b.text:SetTextColor(1, 1, 1) else b.text:SetTextColor(1, 0.82, 0) end
        if sel then b:SetFrameLevel(parent:GetFrameLevel() + 3) else b:SetFrameLevel(parent:GetFrameLevel() + 1) end
        b.dot:SetAlpha((b.unread and not sel) and 1 or 0)
        -- the glow only on the chosen tab or under the mouse (drawn and hidden by hand: a texture on
        -- the HIGHLIGHT layer showed on every tab in the game clients)
        if sel or b.hover then b.hl:Show() else b.hl:Hide() end
        b.hl:SetAlpha(sel and 0.55 or 0.85)
    end

    local function make(i)
        local b = CreateFrame("Button", nil, bar)
        b:SetHeight(32)
        b.l = b:CreateTexture(nil, "BACKGROUND")
        b.l:SetWidth(20); b.l:SetHeight(32)
        b.l:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
        b.l:SetTexCoord(0, 0.15625, 0, 1)
        b.r = b:CreateTexture(nil, "BACKGROUND")
        b.r:SetWidth(20); b.r:SetHeight(32)
        b.r:SetPoint("TOPRIGHT", b, "TOPRIGHT", 0, 0)
        b.r:SetTexCoord(0.84375, 1, 0, 1)
        b.m = b:CreateTexture(nil, "BACKGROUND")
        b.m:SetPoint("TOPLEFT", b.l, "TOPRIGHT", 0, 0)
        b.m:SetPoint("BOTTOMRIGHT", b.r, "BOTTOMLEFT", 0, 0)
        b.m:SetTexCoord(0.15625, 0.84375, 0, 1)
        b.hl = b:CreateTexture(nil, "ARTWORK")
        b.hl:SetTexture(TAB_HILITE)
        b.hl:SetBlendMode("ADD")
        b.hl:SetPoint("TOPLEFT", b, "TOPLEFT", 10, 2)
        b.hl:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -10, 2)
        b.hl:Hide()
        b:SetScript("OnEnter", function() this.hover = true; paint(this) end)
        b:SetScript("OnLeave", function() this.hover = nil; paint(this) end)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        b.dot = b:CreateTexture(nil, "OVERLAY")
        b.dot:SetWidth(6); b.dot:SetHeight(6)
        b.dot:SetPoint("TOPRIGHT", b, "TOPRIGHT", -14, -6)
        b.dot:SetTexture(1, 0.82, 0, 1)
        b:SetScript("OnClick", function()
            if PlaySound then PlaySound("igCharacterInfoTab") end
            bar:Select(b.key)
        end)
        bar.buttons[i] = b
        return b
    end

    function bar:SetTabs(list)
        self.tabs = list
        local x = 0
        for i, t in ipairs(list) do
            local b = self.buttons[i] or make(i)
            b.key = t.key
            b.text:SetText(t.label or t.key)
            local w = math.max(64, (b.text:GetStringWidth() or 40) + 40)
            b:SetWidth(w)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", self, "TOPLEFT", x, 0)
            x = x + w - 16          -- the stock tabs overlap by 16
            b:Show()
            paint(b)
        end
        for i = table.getn(list) + 1, table.getn(self.buttons) do self.buttons[i]:Hide() end
        self:SetWidth(math.max(1, x + 16))
        if not self.selected and list[1] then self:Select(list[1].key, true) end
    end
    function bar:Select(key, silent)
        self.selected = key
        for _, b in ipairs(self.buttons) do
            if b.key == key then b.unread = nil end
            paint(b)
        end
        if not silent and opts.onSelect then opts.onSelect(key) end
    end
    function bar:Selected() return self.selected end
    function bar:SetUnread(key, on)
        for _, b in ipairs(self.buttons) do
            if b.key == key then b.unread = on and true or nil; paint(b) end
        end
    end
    function bar:Button(key)
        for _, b in ipairs(self.buttons) do if b.key == key and b:IsShown() then return b end end
    end
    if opts.tabs then bar:SetTabs(opts.tabs) end
    return bar
end

-- -- Gear button -------------------------------------------------------------------------

function UI.GearButton(parent, onClick, size)
    local b = CreateFrame("Button", nil, parent)
    size = size or 16
    b:SetWidth(size)
    b:SetHeight(size)
    local t = b:CreateTexture(nil, "ARTWORK")
    t:SetAllPoints(b)
    if not W:Art(t, "Gear", nil) then
        t:SetTexture("Interface\\Icons\\INV_Misc_Gear_01")
        t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
    b.icon = t
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(b)
    hl:SetTexture(1, 1, 1, 0.15)
    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnter", function()
        if GameTooltip then
            GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
            GameTooltip:SetText("Settings", 1, 1, 1)
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    return b
end

-- -- Settings sheet ----------------------------------------------------------------------
-- A panel that slides out beside a window (right side, or left when there is no room).
-- sheet = UI.Sheet(window, { width = 230, title = "Settings" })
-- sheet:AddSwitch(label, sub, get, set) / AddChoice(label, choices, get, set) /
-- AddSlider(label, min, max, step, get, set, fmt) / AddButton(text, onClick) / AddHeader(text)
-- sheet:Toggle(), sheet:Refresh(). Rows are laid out top to bottom as they are added.

function UI.Sheet(win, opts)
    opts = opts or {}
    local width = opts.width or 230
    local sh = CreateFrame("Frame", opts.name, win)
    UI.Skin(sh, "panel")
    sh:SetWidth(width)
    sh:SetFrameStrata(win:GetFrameStrata() or "MEDIUM")
    sh:SetFrameLevel((win:GetFrameLevel() or 1) + 5)
    sh:EnableMouse(true)
    sh.rows = {}
    sh.y = -28

    local title = UI.Label(sh, 11, UI.ACCENT, "OUTLINE")
    title:SetPoint("TOPLEFT", sh, "TOPLEFT", 10, -9)
    title:SetText(opts.title or "Settings")
    sh.title = title
    local close = UI.CloseButton(sh, function() sh:Hide() end, 20)
    close:SetPoint("TOPRIGHT", sh, "TOPRIGHT", 2, 0)

    function sh:Anchor()
        self:ClearAllPoints()
        local right = win.GetRight and win:GetRight() or 0
        local screen = (UIParent and UIParent.GetWidth and UIParent:GetWidth()) or 1024
        if right + width + 4 > screen then
            self:SetPoint("TOPRIGHT", win, "TOPLEFT", -2, 0)
        else
            self:SetPoint("TOPLEFT", win, "TOPRIGHT", 2, 0)
        end
    end

    local function add(row, h)
        row:SetPoint("TOPLEFT", sh, "TOPLEFT", 10, sh.y)
        sh.y = sh.y - h - 8
        table.insert(sh.rows, row)
        sh:SetHeight(-sh.y + 6)
        return row
    end

    function sh:AddHeader(text)
        local f = CreateFrame("Frame", nil, self)
        f:SetWidth(width - 20)
        f:SetHeight(14)
        local l = UI.Label(f, 10, UI.MUTED, "OUTLINE")
        l:SetPoint("LEFT", f, "LEFT", 0, 0)
        l:SetText(string.upper(text))
        local d = UI.Divider(f)
        d:SetPoint("LEFT", l, "RIGHT", 6, 0)
        d:SetPoint("RIGHT", f, "RIGHT", 0, 0)
        return add(f, 14)
    end
    function sh:AddSwitch(label, sub, get, set)
        local r = UI.SwitchRow(self, { width = width - 20, label = label, sub = sub, get = get, set = set })
        return add(r, r:GetHeight())
    end
    -- choices = { {value=, label=}, ... }; a button that cycles (left-click forward, right back)
    function sh:AddChoice(label, choices, get, set)
        local f = CreateFrame("Frame", nil, self)
        f:SetWidth(width - 20)
        f:SetHeight(20)
        local l = UI.Label(f, 11, { 1, 1, 1 })
        l:SetPoint("LEFT", f, "LEFT", 0, 0)
        l:SetText(label)
        local b = CreateFrame("Button", nil, f)
        UI.Skin(b, "inset")
        b:SetWidth(96)
        b:SetHeight(18)
        b:SetPoint("RIGHT", f, "RIGHT", 0, 0)
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        local v = UI.Label(b, 10, UI.ACCENT)
        v:SetPoint("CENTER", b, "CENTER", 0, 0)
        v:SetJustifyH("CENTER")
        local function index()
            local cur = get()
            for i, c in ipairs(choices) do if c.value == cur then return i end end
            return 1
        end
        function f:Refresh() v:SetText(choices[index()].label) end
        b:SetScript("OnClick", function()
            local n = table.getn(choices)
            local i = index() + ((arg1 == "RightButton") and -1 or 1)
            if i > n then i = 1 elseif i < 1 then i = n end
            set(choices[i].value)
            f:Refresh()
        end)
        f.button, f.value = b, v
        f:Refresh()
        return add(f, 20)
    end
    function sh:AddSlider(label, min, max, step, get, set, fmt)
        local f = CreateFrame("Frame", nil, self)
        f:SetWidth(width - 20)
        f:SetHeight(30)
        local l = UI.Label(f, 11, { 1, 1, 1 })
        l:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
        l:SetText(label)
        local v = UI.Label(f, 10, UI.ACCENT)
        v:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
        v:SetJustifyH("RIGHT")
        local sl = CreateFrame("Slider", nil, f)
        sl:SetOrientation("HORIZONTAL")
        sl:SetWidth(width - 20)
        sl:SetHeight(10)
        sl:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
        local track = sl:CreateTexture(nil, "BACKGROUND")
        track:SetPoint("LEFT", sl, "LEFT", 0, 0)
        track:SetPoint("RIGHT", sl, "RIGHT", 0, 0)
        track:SetHeight(4)
        track:SetTexture(0.16, 0.17, 0.20, 1)
        local thumb = sl:CreateTexture(nil, "OVERLAY")
        thumb:SetWidth(10)
        thumb:SetHeight(10)
        if not W:Art(thumb, "Switch_Knob", nil) then thumb:SetTexture(UI.ACCENT[1], UI.ACCENT[2], UI.ACCENT[3], 1) end
        sl:SetThumbTexture(thumb)
        sl:SetMinMaxValues(min, max)
        if sl.SetValueStep then sl:SetValueStep(step or 1) end
        local function show(x)
            if fmt then v:SetText(string.format(fmt, x)) else v:SetText(tostring(x)) end
        end
        sl:SetScript("OnValueChanged", function()
            local x = sl:GetValue()
            if step and step > 0 then x = floor(x / step + 0.5) * step end
            show(x)
            if not f.loading then set(x) end
        end)
        function f:Refresh()
            f.loading = true
            sl:SetValue(get())
            show(get())
            f.loading = nil
        end
        f.slider = sl
        f:Refresh()
        return add(f, 30)
    end
    function sh:AddButton(text, onClick)
        local b = UI.Button(self, text, width - 20, 20, onClick)
        return add(b, 20)
    end
    function sh:Refresh()
        for _, r in ipairs(self.rows) do if r.Refresh then r:Refresh() end end
    end
    function sh:Toggle()
        if self:IsShown() then self:Hide() else self:Anchor(); self:Refresh(); self:Show() end
    end
    sh:Hide()
    return sh
end

-- -- Context menu --------------------------------------------------------------------------
-- One small menu frame shared by the suite (not UIDropDownMenu, so it never fights the stock
-- menus). items = { {text=, func=, checked=?, disabled=?, title=?, color={r,g,b}?, icon=?}, ... }

local menu
function UI.Menu(anchor, items)
    if not menu then
        menu = CreateFrame("Frame", "WenillaCore_Menu", UIParent)
        UI.Skin(menu, "raised")
        menu:SetFrameStrata("FULLSCREEN_DIALOG")
        menu:EnableMouse(true)
        menu.buttons = {}
        if UISpecialFrames then table.insert(UISpecialFrames, "WenillaCore_Menu") end
        menu:SetScript("OnUpdate", function()
            -- close after the mouse has been away for a moment
            if MouseIsOver and not MouseIsOver(menu) then
                menu.away = (menu.away or 0) + (arg1 or 0)
                if menu.away > 1.2 then menu:Hide() end
            else
                menu.away = 0
            end
        end)
    end
    local width = 120
    for i, it in ipairs(items) do
        local b = menu.buttons[i]
        if not b then
            b = CreateFrame("Button", nil, menu)
            b:SetHeight(16)
            b.text = UI.Label(b, 10)
            b.text:SetPoint("LEFT", b, "LEFT", 16, 0)
            b.check = b:CreateTexture(nil, "OVERLAY")
            b.check:SetWidth(12)
            b.check:SetHeight(12)
            b.check:SetPoint("LEFT", b, "LEFT", 2, 0)
            b.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
            b.icon = b:CreateTexture(nil, "OVERLAY")
            b.icon:SetWidth(13)
            b.icon:SetHeight(13)
            b.icon:SetPoint("LEFT", b, "LEFT", 16, 0)
            b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            local hl = b:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints(b)
            hl:SetTexture(1, 0.82, 0, 0.12)
            menu.buttons[i] = b
        end
        b.text:SetText(it.text or "")
        local c = it.color or (it.title and UI.ACCENT) or (it.disabled and UI.MUTED) or { 1, 1, 1 }
        b.text:SetTextColor(c[1], c[2], c[3])
        if it.checked then b.check:Show() else b.check:Hide() end
        b.text:ClearAllPoints()
        if it.icon then
            b.icon:SetTexture(it.icon)
            b.icon:Show()
            b.text:SetPoint("LEFT", b, "LEFT", 33, 0)
        else
            b.icon:Hide()
            b.text:SetPoint("LEFT", b, "LEFT", 16, 0)
        end
        b:SetScript("OnClick", function()
            if it.title or it.disabled then return end
            menu:Hide()
            if it.func then it.func() end
        end)
        width = math.max(width, (b.text:GetStringWidth() or 60) + (it.icon and 45 or 28))
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", menu, "TOPLEFT", 4, -4 - (i - 1) * 16)
        b:Show()
    end
    for i = table.getn(items) + 1, table.getn(menu.buttons) do menu.buttons[i]:Hide() end
    for _, b in ipairs(menu.buttons) do b:SetWidth(width) end
    menu:SetWidth(width + 8)
    menu:SetHeight(table.getn(items) * 16 + 8)
    menu:ClearAllPoints()
    if anchor then
        menu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    else
        menu:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
    menu.away = 0
    menu:Show()
    return menu
end

-- -- Toasts --------------------------------------------------------------------------------
-- UI.Toast({ icon=, title=, text=, color={r,g,b}, sound=, duration=5 }): a small banner at the
-- top centre; up to three stack, newest on top, each fades out by itself.

local toastPool, toastActive = {}, {}

local function layoutToasts()
    local y = -110
    for _, t in ipairs(toastActive) do
        t:ClearAllPoints()
        t:SetPoint("TOP", UIParent, "TOP", 0, y)
        y = y - 52
    end
end

local function dropToast(t)
    for i, x in ipairs(toastActive) do if x == t then table.remove(toastActive, i) break end end
    layoutToasts()
end

local function newToast()
    local t = CreateFrame("Frame", nil, UIParent)
    t:SetWidth(280)
    t:SetHeight(46)
    t:SetFrameStrata("HIGH")
    UI.Skin(t, "raised")
    t.icon = UI.IconBox(t, 34)
    t.icon:SetPoint("LEFT", t, "LEFT", 6, 0)
    t.title = UI.Label(t, 11, UI.ACCENT, "OUTLINE")
    t.title:SetPoint("TOPLEFT", t.icon, "TOPRIGHT", 8, -2)
    t.title:SetWidth(222)
    t.text = UI.Label(t, 10, { 0.92, 0.92, 0.95 })
    t.text:SetPoint("TOPLEFT", t.title, "BOTTOMLEFT", 0, -3)
    t.text:SetWidth(222)
    t.line = t:CreateTexture(nil, "ARTWORK")
    t.line:SetPoint("BOTTOMLEFT", t, "BOTTOMLEFT", 3, 3)
    t.line:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", -3, 3)
    t.line:SetHeight(1)
    t:EnableMouse(true)
    t:SetScript("OnMouseUp", function() if t.onClick then t.onClick() end t:Hide() end)
    t:SetScript("OnUpdate", function()
        t.age = (t.age or 0) + (arg1 or 0)
        local d = t.duration or 5
        if t.age > d then t:Hide() return end
        if t.age > d - 0.6 then t:SetAlpha((d - t.age) / 0.6) else t:SetAlpha(1) end
    end)
    t:SetScript("OnHide", function() dropToast(t) end)
    table.insert(toastPool, t)
    return t
end

function UI.Toast(opts)
    local t
    for _, x in ipairs(toastPool) do if not x:IsShown() then t = x break end end
    if not t then
        if table.getn(toastPool) < 3 then t = newToast() else
            t = toastActive[table.getn(toastActive)]   -- reuse the oldest
            t:Hide()
        end
    end
    t.icon.icon:SetTexture(opts.icon or UI.UNKNOWN_ICON)
    t.title:SetText(opts.title or "")
    t.text:SetText(opts.text or "")
    local c = opts.color or UI.ACCENT
    t.line:SetTexture(c[1], c[2], c[3], 0.8)
    t.title:SetTextColor(c[1], c[2], c[3])
    t.duration = opts.duration or 5
    t.onClick = opts.onClick
    t.age = 0
    t:SetAlpha(1)
    table.insert(toastActive, 1, t)
    t:Show()
    layoutToasts()
    if opts.sound and PlaySound then PlaySound(opts.sound) end
    return t
end

-- -- Scroll list -----------------------------------------------------------------------------
-- A virtual list: a fixed pool of rows over any number of items, scrolled by the mouse wheel
-- and a thin bar that shows on hover. opts: width, height, rowHeight, build(row, i),
-- update(row, item, index). list:SetItems(t), list:Scroll(delta), list:Refresh().

function UI.ScrollList(parent, opts)
    local L = CreateFrame("Frame", opts.name, parent)
    L:SetWidth(opts.width or 200)
    L:SetHeight(opts.height or 200)
    L:EnableMouseWheel(true)
    L.items = {}
    L.offset = 0
    L.rowHeight = opts.rowHeight or 18
    L.rows = {}
    local n = floor((opts.height or 200) / L.rowHeight)
    L.visibleRows = n
    for i = 1, n do
        local row = CreateFrame("Button", nil, L)
        row:SetWidth((opts.width or 200) - 6)
        row:SetHeight(L.rowHeight)
        row:SetPoint("TOPLEFT", L, "TOPLEFT", 0, -(i - 1) * L.rowHeight)
        if opts.build then opts.build(row, i) end
        L.rows[i] = row
    end
    local bar = L:CreateTexture(nil, "OVERLAY")
    bar:SetWidth(3)
    bar:SetTexture(UI.EDGE[1], UI.EDGE[2], UI.EDGE[3], 0.9)
    L.bar = bar

    function L:Refresh()
        local total = table.getn(self.items)
        local maxOff = math.max(0, total - n)
        if self.offset > maxOff then self.offset = maxOff end
        if self.offset < 0 then self.offset = 0 end
        for i = 1, n do
            local item = self.items[self.offset + i]
            local row = self.rows[i]
            if item then
                row.item = item
                if opts.update then opts.update(row, item, self.offset + i) end
                row:Show()
            else
                row.item = nil
                row:Hide()
            end
        end
        if total > n then
            local h = self:GetHeight()
            local bh = math.max(12, h * n / total)
            bar:SetHeight(bh)
            bar:ClearAllPoints()
            bar:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, -((h - bh) * self.offset / maxOff))
            bar:SetAlpha((MouseIsOver and MouseIsOver(self)) and 0.9 or 0.35)
            bar:Show()
        else
            bar:Hide()
        end
    end
    function L:SetItems(t)
        self.items = t or {}
        self:Refresh()
    end
    function L:Scroll(delta)
        self.offset = self.offset - delta * (opts.wheelStep or 2)
        self:Refresh()
    end
    function L:ScrollToEnd()
        self.offset = math.max(0, table.getn(self.items) - n)
        self:Refresh()
    end
    L:SetScript("OnMouseWheel", function() L:Scroll(arg1 or 0) end)
    return L
end

-- -- Search box ----------------------------------------------------------------------------
-- An inset edit box with a grey placeholder. opts: width, placeholder, onChange(text).

function UI.SearchBox(parent, opts)
    local e = CreateFrame("EditBox", opts.name, parent)
    UI.Skin(e, "inset")
    e:SetWidth(opts.width or 140)
    e:SetHeight(18)
    e:SetAutoFocus(false)
    e:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
    if e.SetTextInsets then e:SetTextInsets(6, 6, 0, 0) end
    local ph = UI.Label(e, 10, UI.MUTED)
    ph:SetPoint("LEFT", e, "LEFT", 6, 0)
    ph:SetText(opts.placeholder or "Search")
    e:SetScript("OnTextChanged", function()
        local t = e:GetText() or ""
        if t == "" then ph:Show() else ph:Hide() end
        if opts.onChange then opts.onChange(t) end
    end)
    e:SetScript("OnEscapePressed", function() e:SetText(""); e:ClearFocus() end)
    e:SetScript("OnEnterPressed", function() e:ClearFocus() end)
    e.placeholder = ph
    return e
end

-- -- Note box --------------------------------------------------------------------------------
-- A multi-line text field you can click anywhere in and type: an inset well holding a scroll frame whose
-- child is the edit box (the 1.12 client only lays out a multi-line EditBox properly as a scroll child; on
-- its own it shrinks to one line and may never take the keyboard). UI.NoteBox(parent, name, width, height,
-- maxLetters) -> well; well.edit is the EditBox (GetText/SetText/SetFocus/ClearFocus as usual).

function UI.NoteBox(parent, name, width, height, maxLetters)
    local well = CreateFrame("Button", name and (name .. "Well") or nil, parent)
    UI.Skin(well, "inset")
    well:SetWidth(width); well:SetHeight(height)
    well:EnableMouse(true)
    local sf = CreateFrame("ScrollFrame", name and (name .. "Scroll") or nil, well)
    sf:SetPoint("TOPLEFT", well, "TOPLEFT", 6, -4)
    sf:SetPoint("BOTTOMRIGHT", well, "BOTTOMRIGHT", -6, 4)
    sf:EnableMouse(true)
    local e = CreateFrame("EditBox", name, sf)
    e:SetMultiLine(true)
    e:SetAutoFocus(false)
    e:EnableMouse(true)
    if e.EnableKeyboard then e:EnableKeyboard(true) end
    e:SetMaxLetters(maxLetters or 0)
    e:SetWidth(width - 12)
    e:SetHeight(height - 8)
    e:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
    e:SetTextColor(1, 1, 1)
    e:SetPoint("TOPLEFT", sf, "TOPLEFT", 0, 0)
    sf:SetScrollChild(e)
    -- keep the cursor in view while typing past the bottom
    e:SetScript("OnCursorChanged", function()
        local y, h = -(arg2 or 0), (arg4 or 0)
        local top = sf:GetVerticalScroll() or 0
        local view = sf:GetHeight() or height
        if y < top then sf:SetVerticalScroll(y)
        elseif y + h > top + view then sf:SetVerticalScroll(y + h - view) end
    end)
    local function focus() e:SetFocus() end
    well:SetScript("OnClick", focus)
    sf:SetScript("OnMouseDown", focus)
    e:SetScript("OnEscapePressed", function() e:ClearFocus() end)
    well.edit, well.scroll = e, sf
    return well
end

-- -- Prompt ----------------------------------------------------------------------------------
-- A small "type a name" dialog in the suite's look (StaticPopup's edit box differs between
-- clients). UI.Prompt({ title=, text=, default=, maxLetters=24, accept="Save",
-- onAccept(text) }). Enter accepts, Escape cancels; an empty name keeps the dialog open.

local prompt
function UI.Prompt(opts)
    if not prompt then
        prompt = CreateFrame("Frame", "WenillaCore_Prompt", UIParent)
        UI.Skin(prompt, "raised")
        prompt:SetWidth(260)
        prompt:SetHeight(108)
        prompt:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
        prompt:SetFrameStrata("DIALOG")
        prompt:EnableMouse(true)
        if UISpecialFrames then table.insert(UISpecialFrames, "WenillaCore_Prompt") end
        prompt.title = UI.Label(prompt, 11, UI.ACCENT, "OUTLINE")
        prompt.title:SetPoint("TOPLEFT", prompt, "TOPLEFT", 12, -10)
        prompt.text = UI.Label(prompt, 10, UI.MUTED)
        prompt.text:SetPoint("TOPLEFT", prompt.title, "BOTTOMLEFT", 0, -4)
        prompt.text:SetWidth(236)
        local e = CreateFrame("EditBox", "WenillaCore_PromptEdit", prompt)
        UI.Skin(e, "inset")
        e:SetWidth(236)
        e:SetHeight(20)
        e:SetPoint("TOPLEFT", prompt, "TOPLEFT", 12, -50)
        e:SetAutoFocus(false)
        e:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
        if e.SetTextInsets then e:SetTextInsets(6, 6, 0, 0) end
        prompt.edit = e
        local function accept()
            local t = W.Trim(e:GetText() or "")
            if t == "" then return end
            local fn = prompt.onAccept
            prompt:Hide()
            if fn then fn(t) end
        end
        prompt.ok = UI.Button(prompt, "Save", 90, 20, accept)
        prompt.ok:SetPoint("BOTTOMRIGHT", prompt, "BOTTOM", -4, 10)
        prompt.cancel = UI.Button(prompt, "Cancel", 90, 20, function() prompt:Hide() end)
        prompt.cancel:SetPoint("BOTTOMLEFT", prompt, "BOTTOM", 4, 10)
        e:SetScript("OnEnterPressed", accept)
        e:SetScript("OnEscapePressed", function() prompt:Hide() end)
        prompt:SetScript("OnHide", function() e:ClearFocus() end)
    end
    prompt.title:SetText(opts.title or "Name")
    prompt.text:SetText(opts.text or "")
    prompt.edit:SetMaxLetters(opts.maxLetters or 24)
    prompt.edit:SetText(opts.default or "")
    prompt.ok:SetText(opts.accept or "Save")
    prompt.onAccept = opts.onAccept
    prompt:Show()
    prompt.edit:SetFocus()
    if prompt.edit.HighlightText then prompt.edit:HighlightText() end
    return prompt
end

-- ===========================================================================================
-- Skins: one theme table for the Classic+ windows that follow the player's choice.
--   classic  the stock 1.12 look: dialog-box border, header plaque, quick-slot item borders (default)
--   brass    the Classic+ gold-and-stone art (Interface\ClassicPlus\: Ach_Corner, Ach_TitleCrest,
--            Slot); each piece falls back to a stock texture when the art is missing
--   slick    the flat dark panels from before
-- The choice lives in WenillaCore_Config.settings.Themes.skin (SavedVariables), set in the Addons
-- window (Themes > Window skin) or with /skin. A window follows it with UI.Window{ skin = true },
-- inner panels with UI.Themed(frame, "panel"|"inset"), icon wells with UI.SkinIcon(box), and
-- anything else with UI.OnSkin(function(theme) ... end), which runs now and on every change.
-- ===========================================================================================

local DIALOG_BG = "Interface\\DialogFrame\\UI-DialogBox-Background"
local TIP_BG = "Interface\\Tooltips\\UI-Tooltip-Background"
local TIP_EDGE = "Interface\\Tooltips\\UI-Tooltip-Border"

UI.SKIN_ORDER = { "classic", "brass", "slick" }
UI.SKINS = {
    classic = {
        key = "classic", label = "Classic",
        backdrop = { bgFile = DIALOG_BG, edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 24, insets = { left = 7, right = 7, top = 7, bottom = 7 } },
        bg = { 1, 1, 1, 1 }, border = { 1, 1, 1, 1 },
        inset = { bgFile = TIP_BG, edgeFile = TIP_EDGE, tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 } },
        insetBg = { 0, 0, 0, 0.5 }, insetBorder = { 0.65, 0.65, 0.65, 1 },
        panel = { bgFile = DIALOG_BG, edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 16, insets = { left = 5, right = 5, top = 5, bottom = 5 } },
        header = { file = "Interface\\DialogFrame\\UI-DialogBox-Header", y = 18, textY = -14, plaque = 139 / 256 },
        title = { 1, 0.82, 0 }, accent = { 1, 0.82, 0 }, muted = { 0.8, 0.8, 0.8 },
        slotBorder = "Interface\\Buttons\\UI-Quickslot2",
        rowHighlight = "Interface\\QuestFrame\\UI-QuestTitleHighlight",
        close = { size = 30, x = 3, y = 3 },
    },
    brass = {
        key = "brass", label = "Brass",
        backdrop = { bgFile = DIALOG_BG, edgeFile = TIP_EDGE, tile = true, tileSize = 32, edgeSize = 14,
            insets = { left = 3, right = 3, top = 3, bottom = 3 } },
        bg = { 1, 1, 1, 1 }, border = { 0.86, 0.66, 0.28, 1 },
        inset = { bgFile = TIP_BG, edgeFile = TIP_EDGE, tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 } },
        insetBg = { 0.06, 0.045, 0.02, 0.85 }, insetBorder = { 0.70, 0.52, 0.20, 1 },
        header = { art = "Ach_TitleCrest", file = "Interface\\DialogFrame\\UI-DialogBox-Gold-Header",
            artHeight = 26, y = 12, artTextY = -7, textY = -14, plaque = 139 / 256 },
        corners = "Ach_Corner",
        title = { 1, 0.86, 0.45 }, accent = { 1, 0.82, 0 }, muted = { 0.78, 0.72, 0.60 },
        slotArt = "Slot", slotFallback = "Interface\\Buttons\\UI-EmptySlot-Disabled",
        rowHighlight = "Interface\\QuestFrame\\UI-QuestTitleHighlight",
        close = { size = 26, x = 4, y = 4 },
    },
    slick = {
        key = "slick", label = "Slick",
        backdrop = UI.BACKDROP, bg = { 0.07, 0.07, 0.08, 0.94 }, border = { 0.62, 0.62, 0.66, 1 },
        inset = UI.THIN, insetBg = UI.INSET, insetBorder = UI.EDGE,
        bar = true,
        title = { 0.95, 0.93, 0.88 }, accent = UI.ACCENT, muted = UI.MUTED,
        flat = true,
    },
}
UI.skinHooks = {}

function UI.SkinKey()
    local k = W.Setting and W:Setting("Themes", "skin", nil)
    if not (k and UI.SKINS[k]) then k = "classic" end
    return k
end

function UI.Theme() return UI.SKINS[UI.SkinKey()] end

-- fn(theme) now and on every skin change.
function UI.OnSkin(fn)
    table.insert(UI.skinHooks, fn)
    local ok, err = pcall(fn, UI.Theme())
    if not ok then W:Error("skin", err) end
end

function UI.ApplySkin()
    local th = UI.Theme()
    UI.appliedSkin = th.key
    for _, fn in ipairs(UI.skinHooks) do
        local ok, err = pcall(fn, th)
        if not ok then W:Error("skin", err) end
    end
end

-- Save the player's choice and re-skin every window that follows it. Returns false for an unknown key.
function UI.SetSkin(key)
    if not key or not UI.SKINS[key] then return false end
    local s = W:Settings("Themes")
    s.skin = key
    UI.ApplySkin()
    if UI.onSkinChanged then UI.onSkinChanged(key) end
    return true
end

-- the saved skin, once SavedVariables are in
if W.OnConfig then W:OnConfig(function() UI.ApplySkin() end) end

local function backdrop(f, bd, bg, border)
    if not f.SetBackdrop then return end
    f:SetBackdrop(bd)
    f.backdropInfo = bd   -- what this skin put on it (1.12 has no GetBackdrop)
    f:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
    f:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 1)
end

-- An inner panel ("panel" | "inset" | "raised") that follows the skin.
function UI.Themed(f, style)
    UI.OnSkin(function(th)
        if th.flat then
            UI.Skin(f, style)
        elseif style == "inset" then
            backdrop(f, th.inset, th.insetBg, th.insetBorder)
        else
            backdrop(f, th.panel or th.backdrop, th.bg, th.border)
        end
    end)
    return f
end

-- An icon well (UI.IconBox) that follows the skin: a quick-slot border (classic), a stone slot (brass)
-- or the flat edge (slick). box.edge keeps carrying quality colours in every skin.
function UI.PaintIcon(box, th)
    local size = box:GetWidth() or 24
    if th.slotBorder then
        if not box.skinBorder then box.skinBorder = box:CreateTexture(nil, "OVERLAY") end
        local t = box.skinBorder
        t:SetTexture(th.slotBorder)
        t:SetTexCoord(0, 1, 0, 1)
        t:SetWidth(size * 64 / 37)
        t:SetHeight(size * 64 / 37)
        t:ClearAllPoints()
        t:SetPoint("CENTER", box, "CENTER", 0, -1)
        t:SetDrawLayer("OVERLAY")
        t:Show()
    elseif th.slotArt then
        if not box.skinBorder then box.skinBorder = box:CreateTexture(nil, "BACKGROUND") end
        local t = box.skinBorder
        W:Art(t, th.slotArt, th.slotFallback)
        t:SetWidth(size + 8)
        t:SetHeight(size + 8)
        t:ClearAllPoints()
        t:SetPoint("CENTER", box, "CENTER", 0, 0)
        t:SetDrawLayer("BACKGROUND")
        t:Show()
    elseif box.skinBorder then
        box.skinBorder:Hide()
    end
end

function UI.SkinIcon(box)
    UI.OnSkin(function(th) UI.PaintIcon(box, th) end)
    return box
end

local CORNERS = {
    { "TOPLEFT", 0, 1, 0, 1, -2, 2 }, { "TOPRIGHT", 1, 0, 0, 1, 2, 2 },
    { "BOTTOMLEFT", 0, 1, 1, 0, -2, -2 }, { "BOTTOMRIGHT", 1, 0, 1, 0, 2, -2 },
}

-- The chrome of a UI.Window in the given theme.
-- -- Classic chrome: the Guild Finder's frame round a UI.Window -------------------------------------
-- A window made with opts.classicFrame keeps its own layout; under the Classic skin the stock
-- Character-frame art (UI.LayoutClassicFrame: round portrait, title strip, header band, dark body)
-- is drawn round it, reaching CL px left, CT up, CR right and CB down, so the window's content
-- (which starts about 26 px below its top) sits where the stock frame's body starts. The portrait
-- is the window's icon; the title and the close button move onto the strip.
local CL, CT, CR, CB = 16, 50, 10, 8
UI.CHROME = { left = CL, top = CT, right = CR, bottom = CB }

function UI.ClassicChrome(f)
    if f.chrome then return f.chrome end
    local c = CreateFrame("Frame", nil, f)
    c:SetFrameLevel(math.max(0, (f:GetFrameLevel() or 1) - 1))
    c:SetPoint("TOPLEFT", f, "TOPLEFT", -CL, CT)
    c:EnableMouse(true)                          -- clicks on the frame art don't fall through to the world
    c.cfAnySize = true
    UI.portraitN = (UI.portraitN or 0) + 1
    local pname = (f:GetName() or ("WenillaChrome" .. UI.portraitN)) .. "ChromePortrait"
    local p = c:CreateTexture(pname, "BACKGROUND")
    p:SetWidth(60)
    p:SetHeight(60)
    p:SetPoint("TOPLEFT", c, "TOPLEFT", 7, -6)
    c.portrait = p
    function c:SetPortrait(path)
        if not path then return end
        if SetPortraitToTexture and (pcall(SetPortraitToTexture, pname, path) or pcall(SetPortraitToTexture, p, path)) then
            p:SetTexCoord(0, 1, 0, 1)
            return
        end
        p:SetTexture(path)
        p:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
    c:SetPortrait(f.chromeIcon or (f.icon and f.icon.GetTexture and f.icon:GetTexture()))
    -- the title strip drags the window
    local h = CreateFrame("Button", nil, c)
    h:SetPoint("TOPLEFT", c, "TOPLEFT", 70, 0)
    h:SetPoint("BOTTOMRIGHT", c, "TOPRIGHT", -32, -34)
    h:RegisterForDrag("LeftButton")
    h:SetScript("OnDragStart", function() f:StartMoving() end)
    h:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        W:SavePosition(f)
    end)
    -- sized from the window (a size from two anchors reads 0 until drawn); follows its resizes
    function c:Fit()
        local w, h = (f:GetWidth() or 0) + CL + CR, (f:GetHeight() or 0) + CT + CB
        if w ~= self.fitW or h ~= self.fitH then
            self.fitW, self.fitH = w, h
            self:SetWidth(w)
            self:SetHeight(h)
            UI.LayoutClassicFrame(self)
            if f.title then f.title:ClearAllPoints(); f.title:SetPoint("CENTER", self, "TOPLEFT", (72 + w - 30) / 2, -21) end
        end
    end
    c:SetScript("OnUpdate", function() this:Fit() end)
    f.chrome = c
    return c
end

local function paintChrome(f)
    local c = UI.ClassicChrome(f)
    c:Show()
    c.fitW = nil
    if f.SetBackdrop then f:SetBackdrop(nil) end
    if f.titleBar then f.titleBar:SetTexture(nil) end
    if f.titleRule then f.titleRule:Hide() end
    if f.header then f.header:Hide() end
    if f.icon then f.icon:Hide() end
    for _, k in ipairs(f.corners or {}) do k:Hide() end
    local title = f.title
    UI.Font(title, 12)
    title:SetTextColor(1, 1, 1)
    c:Fit()
    local cb = f.closeButton
    if cb then
        cb:ClearAllPoints()
        cb:SetWidth(30)
        cb:SetHeight(30)
        cb:SetPoint("CENTER", c, "TOPRIGHT", -14, -24)
    end
end

function UI.PaintWindow(f, th)
    if f.classicFrame then
        if th.key == "classic" then paintChrome(f) return end
        if f.chrome then f.chrome:Hide() end
        if f.title then UI.Font(f.title, 11, "OUTLINE") end
    end
    backdrop(f, th.backdrop, th.bg, th.border)
    local bar, title = f.titleBar, f.title
    if th.bar then
        UI.Gradient(bar, 0.21, 0.21, 0.23, 0.11, 0.11, 0.12)
        if f.titleRule then f.titleRule:Show() end
    else
        bar:SetTexture(nil)
        if f.titleRule then f.titleRule:Hide() end
    end
    -- header plaque with the title on it, or the title on the strip
    local h = th.header
    title:ClearAllPoints()
    if h then
        if not f.header then f.header = f:CreateTexture(nil, "OVERLAY") end
        local hd = f.header
        local art = h.art and W:Art(hd, h.art, nil)
        local tw = (title.GetStringWidth and title:GetStringWidth()) or 60
        hd:ClearAllPoints()
        if art then
            hd:SetTexCoord(0, 1, 0, 1)
            hd:SetWidth(math.min((f:GetWidth() or 200) - 16, math.max(140, tw + 70)))
            hd:SetHeight(h.artHeight or 26)
            hd:SetPoint("TOP", f, "TOP", 0, h.y)
            title:SetPoint("TOP", hd, "TOP", 0, h.artTextY or -7)
        else
            hd:SetTexture(h.file)
            hd:SetTexCoord(0, 1, 0, 1)
            local w = math.min(360, math.max(200, (tw + 56) / (h.plaque or 0.55)))
            hd:SetWidth(w)
            hd:SetHeight(64)
            hd:SetPoint("TOP", f, "TOP", 0, h.y)
            title:SetPoint("TOP", hd, "TOP", 0, h.textY)
        end
        hd:Show()
        if f.icon then f.icon:Hide() end
    else
        if f.header then f.header:Hide() end
        if f.icon then f.icon:Show() end
        if f.titleAlign == "LEFT" then
            title:SetPoint("LEFT", bar, "LEFT", f.icon and 22 or 6, 0)
        else
            title:SetPoint("CENTER", bar, "CENTER", 0, 0)
        end
    end
    local tc = th.title
    title:SetTextColor(tc[1], tc[2], tc[3])
    -- brass corners
    f.corners = f.corners or {}
    for i, c in ipairs(CORNERS) do
        local t = f.corners[i]
        if th.corners then
            if not t then
                t = f:CreateTexture(nil, "OVERLAY")
                t:SetWidth(18)
                t:SetHeight(18)
                t:SetPoint(c[1], f, c[1], c[6], c[7])
                f.corners[i] = t
            end
            if W:Art(t, th.corners, nil) then
                t:SetTexCoord(c[2], c[3], c[4], c[5])
                t:Show()
            else
                t:Hide()
            end
        elseif t then
            t:Hide()
        end
    end
    -- close button: on the strip (slick) or in the corner of the border
    local cb = f.closeButton
    if cb then
        cb:ClearAllPoints()
        if th.close then
            cb:SetWidth(th.close.size)
            cb:SetHeight(th.close.size)
            cb:SetPoint("TOPRIGHT", f, "TOPRIGHT", th.close.x, th.close.y)
        else
            cb:SetWidth(22)
            cb:SetHeight(22)
            cb:SetPoint("RIGHT", bar, "RIGHT", 4, 0)
        end
    end
end

function UI.SkinWindow(f)
    UI.OnSkin(function(th)
        if f.paintSkin then f.paintSkin(th) else UI.PaintWindow(f, th) end
    end)
    return f
end

SLASH_CPSKIN1 = "/skin"
SlashCmdList["CPSKIN"] = function(msg)
    local key = string.lower(W.Trim and W.Trim(msg or "") or (msg or ""))
    if UI.SetSkin(key) then
        W.Print("window skin: " .. UI.SKINS[key].label .. ".")
    else
        local names = {}
        for _, k in ipairs(UI.SKIN_ORDER) do table.insert(names, UI.SKINS[k].label) end
        W.Print("window skin is " .. UI.Theme().label .. ". /skin classic | brass | slick  (" .. table.concat(names, ", ") .. ")")
    end
end
