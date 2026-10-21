--[[
    Window.lua  -  Meters windows, tabs, settings, reports and slash commands.

    Each window (an "instance", as in Details!) holds tabs; each tab shows one mode (Damage,
    DPS, Healing, Deaths, ...) for one fight (current, overall or an earlier one). Tabs can be
    added (+), renamed, moved, closed or torn off into their own window from the right-click
    menu. The layout is saved per character in Meters_Layout; the look (bar height, font size,
    texture, number format, ...) is shared through the Addons window settings.

    The main window keeps its old global name, Chronicle_Frame; torn-off windows are
    Chronicle_Frame2, Chronicle_Frame3, ...
]]--

local W = WenillaCore
local UI = W.UI
local C = Chronicle
local ID = "Meters"

local floor = math.floor
local strfind, strsub, strgsub, strlen, strlower, strupper = string.find, string.sub, string.gsub, string.len, string.lower, string.upper
local tinsert, tremove, getn = table.insert, table.remove, table.getn

-- 300 px wide; the tabs on the title band, the column strip under them, then the rows, which leave
-- room at the right for the scrollbar (Chrome.lua has the measures).
local WIDTH, GAP, MAX_ROWS = 300, 1, 20
-- (rows start at f.rowsTop: Chrome.lua C.BANDED / C.FLAT)
local ROW_X = C.EDGE
-- The rows reach the inner dark box's right edge (6 px in from the window's); they leave room for
-- the scrollbar only while it is shown.
local ROW_RIGHT = 6
local ROW_W = WIDTH - ROW_X - ROW_RIGHT
local ROW_W_SCROLL = ROW_W - C.SCROLL_W - 3
local MIN_H = 112          -- the Classic frame's art doesn't go smaller
local MAX_WINDOWS, MAX_TABS = 5, 6

-- Bar colours: Meters (warrior red, the rest the game's colours) or the game's own for every class.
C.PALETTES = { { value = "meters", label = "Meters" }, { value = "standard", label = "Standard" } }
C.TEXTURES = {
    { value = "bronze", label = "Bronze", path = C.ART.fill },
    { value = "glossy", label = "Glossy", path = "Interface\\TargetingFrame\\UI-StatusBar" },
    { value = "flat", label = "Flat", path = "Interface\\Tooltips\\UI-Tooltip-Background" },
    { value = "skills", label = "Skill bar", path = "Interface\\PaperDollInfoFrame\\UI-Character-Skills-Bar" },
}
local FONT_CHOICES = {
    { value = 9, label = "9 pt" }, { value = 10, label = "10 pt" }, { value = 11, label = "11 pt" },
    { value = 12, label = "12 pt" }, { value = 13, label = "13 pt" },
}
local NUMBER_CHOICES = { { value = "short", label = "1.2k" }, { value = "full", label = "1,234" } }
local LINE_CHOICES = { { value = 3, label = "Top 3" }, { value = 5, label = "Top 5" }, { value = 10, label = "Top 10" }, { value = 25, label = "Top 25" } }

local function S(key, default) return W:Setting(ID, key, default) end

local function clamp(v, lo, hi)
    v = tonumber(v) or lo
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Change a setting the same way the Addons window does (it refreshes every window).
function C:Set(key, value)
    if ClassicPlus_Manager and ClassicPlus_Manager.SetSetting then
        ClassicPlus_Manager:SetSetting(ID, key, value)
    else
        W:Settings(ID)[key] = value
        self:RefreshWindows()
    end
end

-- 12345 -> "12.3k" or "12,345" (the "Number format" setting)
function C.Num(n)
    n = tonumber(n) or 0
    if S("numberFormat", "full") == "full" then
        local s = tostring(floor(n + 0.5))
        local k
        repeat s, k = strgsub(s, "^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
        return s
    end
    return W.Short(n)
end
local Num = C.Num

local function pct(part, whole)
    if not whole or whole <= 0 then return "0.0%" end
    return string.format("%.1f%%", part / whole * 100)
end
C.Pct = pct

-- -- Layout (saved per character) --------------------------------------------------

-- Damage, DPS, Healing and Deaths side by side, Damage chosen.
local function defaultTabs()
    return { { id = 1, mode = "dmg", seg = "current" }, { id = 2, mode = "dps", seg = "current" },
        { id = 3, mode = "heal", seg = "current" }, { id = 4, mode = "deaths", seg = "current" } }
end
local function defaultLayout()
    return { version = 2, nextTab = 5, windows = { { tabs = defaultTabs(), active = 1 } } }
end

-- Meters_Layout, checked once each time the saved table changes (a new login restores it).
function C:Layout()
    local L = Meters_Layout
    if L and L == self.layoutRef then return L end
    if type(L) ~= "table" or type(L.windows) ~= "table" then L = nil end
    if L then
        local wins, seen, maxId = {}, {}, 0
        for _, w in ipairs(L.windows) do
            if type(w) == "table" and type(w.tabs) == "table" then
                local tabs = {}
                for _, t in ipairs(w.tabs) do
                    if type(t) == "table" and C.MODE[t.mode] then
                        t.id = tonumber(t.id)
                        if not t.id or seen[t.id] then t.id = nil end
                        if t.id then seen[t.id] = true; if t.id > maxId then maxId = t.id end end
                        -- earlier fights do not survive a reload
                        if t.seg ~= "overall" then t.seg = "current" end
                        if type(t.name) ~= "string" or t.name == "" then t.name = nil end
                        if getn(tabs) < MAX_TABS then tinsert(tabs, t) end
                    end
                end
                if tabs[1] and getn(wins) < MAX_WINDOWS then
                    w.tabs = tabs
                    tinsert(wins, w)
                end
            end
        end
        for _, w in ipairs(wins) do
            for _, t in ipairs(w.tabs) do
                if not t.id then maxId = maxId + 1; t.id = maxId end
            end
        end
        if wins[1] then
            L.windows = wins
            -- version 1 started with one Damage tab; a layout nobody changed gets the four tabs
            local w1 = wins[1]
            if (tonumber(L.version) or 1) < 2 and not wins[2] and not w1.tabs[2]
                and w1.tabs[1].mode == "dmg" and not w1.tabs[1].name then
                local id1 = w1.tabs[1].id
                w1.tabs = defaultTabs()
                w1.tabs[1].id = id1
                for k = 2, 4 do maxId = maxId + 1; w1.tabs[k].id = maxId end
                w1.active = id1
            end
            L.nextTab = math.max(tonumber(L.nextTab) or 0, maxId + 1)
            L.version = 2
        else
            L = nil
        end
    end
    if not L then L = defaultLayout() end
    Meters_Layout = L
    self.layoutRef = L
    return L
end

local function activeTab(w)
    for _, t in ipairs(w.tabs) do
        if t.id == w.active then return t end
    end
    w.active = w.tabs[1].id
    return w.tabs[1]
end
C.ActiveTab = activeTab

local function findTab(w, id)
    for i, t in ipairs(w.tabs) do
        if t.id == id then return t, i end
    end
end

local function tabLabel(t)
    if t.name then return t.name end
    local m = C.MODE[t.mode]
    return m and m.short or "Meter"
end

-- -- Window frames -------------------------------------------------------------------

C.frames = {}

local function shadowed(fs)
    fs:SetShadowOffset(1, -1)
    fs:SetShadowColor(0, 0, 0, 1)
end

local function tip(frame, text)
    frame:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_TOP")
        GameTooltip:SetText(text, 1, 1, 1, 1, 1)
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function iconButton(parent, size, texture, onClick, tooltip)
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(size)
    b:SetHeight(size)
    b:SetNormalTexture(texture)
    local n = b:GetNormalTexture()
    if n and n.SetTexCoord then n:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square")
    b:SetScript("OnClick", onClick)
    if tooltip then tip(b, tooltip) end
    return b
end

local function styleRow(row)
    local h = clamp(S("barHeight", 18), 12, 28)
    local fs = clamp(S("fontSize", 11), 8, 14)
    local key = S("barTexture", "bronze")
    local tex = C.TEXTURES[1].path
    for _, t in ipairs(C.TEXTURES) do
        if t.value == key then tex = t.path end
    end
    row:SetHeight(h)
    row.bar:SetStatusBarTexture(tex)
    local showRate = S("showDps", true) ~= false
    C.LayoutRow(row, h, ROW_W, showRate)
    -- one clean sans, outlined, in fixed columns (Chrome.lua)
    C.Text(row.left, fs, C.NAME_COLOR)
    C.Text(row.mid, fs, C.NUM_COLOR)
    C.Text(row.rate, fs, C.RATE_COLOR)
    C.Text(row.right, fs, C.SHARE_COLOR)
    row.styledH = h
    row.styledRate = showRate
    row.styledRateCol = nil         -- LayoutRow put the total back: RenderWindow places it for the mode
end

local function makeRow(f, i)
    local row = UI.Bar(f, { width = ROW_W, height = 18, icon = true })
    C.ChromeRow(row)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function() C:RowClick(this, arg1) end)
    row:SetScript("OnEnter", function() C:ShowInspect(this, false) end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:Hide()
    styleRow(row)
    f.rows[i] = row
    return row
end

local function makeWindow(i)
    local name = (i == 1) and "Chronicle_Frame" or ("Chronicle_Frame" .. i)
    local f
    f = UI.Window(name, {
        width = WIDTH, height = MIN_H, title = "Meters",
        icon = "Interface\\Icons\\Ability_Warrior_SavageBlow",
        classicFrame = true, skin = true,
        point = { "BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -24 - (i - 1) * (WIDTH + 12), 140 },
        onClose = function() C:CloseWindow(f.index) end,
    })
    f.index = i
    f.rows = {}
    f.offset = 0
    C.Frame(f)

    -- the title bar drags the window (unless locked)
    local handle = f.dragHandle
    handle:SetScript("OnDragStart", function() if not S("lock", false) then f:StartMoving() end end)

    -- the reset and cog: square buttons at the right end of the tab row
    local gear = C.ToolButton(f, 20, C.ART.gear, function() C:ToggleSettings(f) end, "Settings")
    f.gear = gear
    local reset = C.ToolButton(f, 20, C.ART.reset, function() C:Reset() end, "Reset all fights")
    reset:SetPoint("RIGHT", gear, "LEFT", -4, 0)
    f.reset = reset

    -- tabs
    f.tabOpts = {
        height = C.TAB_H, maxWidth = 84, skin = true,
        onSelect = function(key)
            -- a click on the tab already chosen opens the mode menu
            local w = C:Layout().windows[f.index]
            if w and tonumber(key) == w.active and f.tabsReady then C:ModeMenu(f) return end
            C:SelectTab(f.index, tonumber(key))
        end,
        onAdd = function() C:AddTab(f.index) end,
        onMenu = function(key, b) C:TabMenu(f.index, tonumber(key), b) end,
    }
    local tabs = C.ChromeTabs(UI.Tabs(f, f.tabOpts))
    f.tabs = tabs
    f.tabsReady = true

    local empty = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    C.Text(empty, 11, { 0.72, 0.73, 0.78 })
    f.empty = empty

    -- footer: the fight picker on the left, the report on the right
    local segBtn = CreateFrame("Button", nil, f)
    segBtn:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", ROW_X, 6)
    segBtn:SetWidth(WIDTH - 2 * ROW_X - 20)
    segBtn:SetHeight(14)
    local footer = segBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    footer:SetPoint("LEFT", segBtn, "LEFT", 2, 0)
    footer:SetJustifyH("LEFT")
    C.Text(footer, 10, { 0.86, 0.87, 0.90 })
    segBtn:SetScript("OnClick", function() C:SegmentMenu(f) end)
    tip(segBtn, "Click to pick a fight: current, overall or an earlier one")
    f.footer, f.segBtn = footer, segBtn

    local report = iconButton(f, 12, "Interface\\Icons\\INV_Scroll_03", function() C:ReportMenu(f, this) end, "Report to chat")
    report:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -ROW_X, 7)
    f.report = report


    -- the gold scrollbar, shown when there are more players than rows
    local scroll = C.Scrollbar(f, function(frac)
        f.offset = math.floor(frac * (f.scrollMax or 0) + 0.5)
        C:RenderWindow(f.index)
    end)
    f.scroll = scroll
    -- and its two arrow buttons under it: one row up or down
    local function step(d)
        return function()
            f.offset = f.offset + d
            C:RenderWindow(f.index)
        end
    end
    local up = C.ArtButton(f, C.SCROLL_W, C.ART.up, step(-1), "Scroll up")
    up:SetPoint("TOPLEFT", scroll, "BOTTOMLEFT", 0, -2)
    local down = C.ArtButton(f, C.SCROLL_W, C.ART.down, step(1), "Scroll down")
    down:SetPoint("TOPLEFT", up, "BOTTOMLEFT", 0, -2)
    up:Hide(); down:Hide()
    f.upBtn, f.downBtn = up, down

    -- where the tabs, the tools and the rows go: in the Classic frame's header band beside the
    -- portrait (the rows right at the top), or under the window's own title bar (Chrome.lua)
    function f:Relayout()
        local L = C.Banded(self) and C.BANDED or C.FLAT
        self.rowsTop = L.rowsY
        self.tabs:ClearAllPoints()
        self.tabs:SetPoint("TOPLEFT", self, "TOPLEFT", L.tabsX, L.tabsY)
        self.gear:ClearAllPoints()
        self.gear:SetWidth(L.tool); self.gear:SetHeight(L.tool)
        self.reset:SetWidth(L.tool); self.reset:SetHeight(L.tool)
        if L.toolsY then
            -- on the title strip, left of the close button, centred on it
            self.gear:SetPoint("TOPRIGHT", self, "TOPRIGHT", -L.toolsRight, L.toolsY)
        else
            self.gear:SetPoint("TOPRIGHT", self, "TOPRIGHT", -C.EDGE, L.tabsY)
        end
        self.empty:ClearAllPoints()
        self.empty:SetPoint("TOP", self, "TOP", 0, -self.rowsTop - 4)
        self.scroll:ClearAllPoints()
        self.scroll:SetPoint("TOPRIGHT", self, "TOPRIGHT", -ROW_RIGHT, -self.rowsTop)
        if self.laidOut ~= L then
            self.laidOut = L
            if C.frames[self.index] == self then C:RefreshTabs(self.index); C:RenderWindow(self.index) end
        end
    end
    f:Relayout()

    f:EnableMouseWheel(true)
    f:SetScript("OnMouseWheel", function()
        f.offset = f.offset - (arg1 or 0)
        C:RenderWindow(f.index)
    end)
    return f
end

function C:EnsureFrame(i)
    local f = self.frames[i]
    if not f then
        f = makeWindow(i)
        self.frames[i] = f
    end
    f.index = i
    return f
end

-- -- Settings applied to every window ---------------------------------------------

function C:ApplySettings()
    local scale = clamp(S("scale", 1), 0.5, 2)
    for _, f in ipairs(self.frames) do
        f:SetScale(scale)
        C.Repaint(f)
        for _, row in ipairs(f.rows) do styleRow(row) end
        if f:IsShown() and f.index and self:Layout().windows[f.index] then self:RenderWindow(f.index) end
        if f.sheet and f.sheet:IsShown() then f.sheet:Refresh() end
    end
    self.dirty = true
end

function C:InCombat()
    if UnitAffectingCombat("player") then return true end
    return self.fight and GetTime() - self.fight.last < 4 and true or false
end

function C:UpdateVisibility()
    local L = self:Layout()
    local active = W:IsActive(ID)
    local autoHidden = S("autoHide", false) and not self:InCombat() and not self.peek
    for i = 1, getn(L.windows) do
        local f = self:EnsureFrame(i)
        local show = active and not autoHidden and not (i == 1 and self.userClosed)
        if show then
            if not f:IsShown() then
                f:Show()
                self.dirty = true
            end
        elseif f:IsShown() then
            f:Hide()
        end
    end
    for i = getn(L.windows) + 1, getn(self.frames) do self.frames[i]:Hide() end
    if not active and Chronicle_Detail then Chronicle_Detail:Hide() end
end

function C:RefreshTabs(i)
    local f, w = self.frames[i], self:Layout().windows[i]
    if not f or not w then return end
    local list = {}
    for _, t in ipairs(w.tabs) do tinsert(list, { key = tostring(t.id), label = tabLabel(t) }) end
    -- the tabs share the width of the window (less the "+" tab)
    -- room for the tabs: to the body's right edge in the Classic band, else left of the reset and cog
    local L = C.Banded(f) and C.BANDED or C.FLAT
    f.tabs.maxTotal = C.Banded(f) and (WIDTH - L.tabsX - 4) or (WIDTH - 2 * ROW_X - 2 * L.tool - 10)
    f.tabs:SetTabs(list)
    f.tabs:Select(tostring(activeTab(w).id), true)
end

function C:RefreshWindows()
    local L = self:Layout()
    for i = 1, getn(L.windows) do
        self:EnsureFrame(i)
        self:RefreshTabs(i)
    end
    self:ApplySettings()
    self:UpdateVisibility()
    self:Render()
end

-- -- Rendering --------------------------------------------------------------------------

function C:Render()
    self.dirty = false
    local L = self:Layout()
    for i = 1, getn(L.windows) do
        local f = self.frames[i]
        if f and f:IsShown() then self:RenderWindow(i) end
    end
    if self.RenderDetail and Chronicle_Detail and Chronicle_Detail:IsShown() then self:RenderDetail() end
end

-- "12,453" -> per second unit for a mode
local function perUnit(m)
    if m.value == "heal" then return "HPS" end
    if m.value == "dmg" then return "DPS" end
    return "/s"
end

-- 25.6%: the share in a row
local function share(part, whole)
    if not whole or whole <= 0 then return "0.0%" end
    return string.format("%.1f%%", part / whole * 100)
end

-- A row's three right-hand columns: the total, the per-second figure (dimmer), the share.
-- Modes that show the total alone (no per-second figure, no share): Damage. Its DPS is the DPS tab.
C.TOTAL_ONLY = { dmg = true }

local function rowText(m, item, total, dur, showDps)
    if C.TOTAL_ONLY[m.key] and not item.death and not item.aura then return Num(item.total), "", "" end
    if item.death then
        local d = item.death
        local b = d.blow
        return (b and ((b.abil or "Melee") .. " " .. Num(-b.amt)) or "-"), "", W.Clock(d.t)
    elseif item.aura then
        return W.Clock(item.total), "", share(item.total, dur)
    elseif m.key == "overheal" then
        return Num(item.total), "", ((item.known and item.known > 0) and share(item.total, item.known) or "?")
    elseif m.count then
        return tostring(item.total), "", share(item.total, total)
    elseif m.key == "power" then
        return Num(item.total) .. (item.ptype and (" " .. strlower(item.ptype)) or ""), "", share(item.total, total)
    elseif m.sortRate then      -- the DPS and HPS tabs: the rate first, the total beside it
        return Num(item.perSec), showDps and Num(item.total) or "", share(item.total, total)
    elseif m.rate and showDps then
        return Num(item.total), Num(item.perSec), share(item.total, total)
    end
    return Num(item.total), "", share(item.total, total)
end

-- The column strip: the mode's name over the names, then the labels of the total, per-second and
-- share columns.
local function headerTexts(m, showDps)
    if m.special == "deaths" then return "Killing blow", "", "Time" end
    if m.special == "auras" then return "Time", "", "%" end
    if m.sortRate then return perUnit(m), showDps and "Total" or "", "%" end
    if m.count then return "Count", "", "%" end
    return "Total", (m.rate and showDps) and perUnit(m) or "", "%"
end

function C:RenderWindow(i)
    local f, w = self.frames[i], self:Layout().windows[i]
    if not f or not w then return end
    local tab = activeTab(w)
    local m = C.MODE[tab.mode] or C.MODE.dmg
    if i == 1 then self.mode = m.key end
    local seg, segKind = self:Segment(tab.seg)
    if segKind == "current" and tab.seg ~= "current" then tab.seg = "current" end   -- that fight was dropped
    local list, total, source, dur = self:RowsFor(m.key, seg, segKind)
    local showDps = S("showDps", true) ~= false
    local classColors = S("classColors", true) ~= false
    local showRank = S("showRank", false)

    f.title:SetText("Meters")
    f.mode = m
    C.SetPortrait(f, C.Portrait(m))
    local _, hr = headerTexts(m, showDps)
    local rateCol = hr ~= "" and not C.TOTAL_ONLY[m.key]
    local totalOnly = C.TOTAL_ONLY[m.key] and true or false
    local colKey = totalOnly and "only" or (rateCol and "rate" or "plain")
    local TOP = f.rowsTop or C.FLAT.rowsY

    local maxRows = floor(clamp(S("maxRows", 8), 1, MAX_ROWS))
    local n = getn(list)
    if f.offset > n - maxRows then f.offset = n - maxRows end
    if f.offset < 0 then f.offset = 0 end
    local top = 1
    if list[1] then
        if m.sortRate then top = list[1].perSec else top = list[1].total end
    end
    if not top or top <= 0 then top = 1 end
    if (total or 0) <= 0 then total = 1 end
    local h = clamp(S("barHeight", 18), 12, 28)
    local rowW = (n > maxRows) and ROW_W_SCROLL or ROW_W
    local shown = 0
    for r = 1, maxRows do
        local row = f.rows[r] or makeRow(f, r)
        if row.styledH ~= h then styleRow(row) end
        if row.styledRateCol ~= colKey then
            row.mid:ClearAllPoints()
            row.mid:SetPoint("RIGHT", row.track, "RIGHT", -(totalOnly and C.COL_SHARE or C.TotalRight(rateCol)), 0)
            row.styledRateCol = colKey
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", f, "TOPLEFT", ROW_X, -TOP - (r - 1) * (h + GAP))
        row:SetWidth(rowW)
        local item = list[f.offset + r]
        if item then
            shown = r
            local token = UI.ClassToken(item.class)
            local cr, cg, cb = 0.45, 0.45, 0.5
            if item.aura then
                if item.harmful then cr, cg, cb = 0.72, 0.22, 0.20 else cr, cg, cb = 0.26, 0.62, 0.30 end
            elseif classColors then
                cr, cg, cb = C.BarColor(token)
            end
            row:SetColor(cr, cg, cb, C.FILL_ALPHA)
            if item.aura then
                row:SetFraction(item.total / (dur > 0 and dur or 1))
            elseif item.death then
                row:SetFraction(1)
            elseif m.sortRate then
                row:SetFraction(item.perSec / top)
            else
                row:SetFraction(item.total / top)
            end
            row.icon:SetTexture(item.icon or UI.CLASS_ICONS[token or ""] or UI.UNKNOWN_ICON)
            row.left:SetText((showRank and ((f.offset + r) .. ". ") or "") .. item.name)
            local amount, rate, part = rowText(m, item, total, dur, showDps)
            row.mid:SetText(amount)
            row.rate:SetText(rate)
            row.right:SetText(part)
            row.item = item
            row.playerName = (not item.aura and not item.death) and item.name or nil
            row.mode, row.segSel, row.segKind = m.key, tab.seg, (source == "server") and "server" or segKind
            row:Show()
        else
            row.item, row.playerName = nil, nil
            row:Hide()
        end
    end
    for r = maxRows + 1, getn(f.rows) do
        f.rows[r].item, f.rows[r].playerName = nil, nil
        f.rows[r]:Hide()
    end
    if shown == 0 then
        f.empty:SetText(seg and "Nothing to show for this fight yet" or "No combat recorded yet")
        f.empty:Show()
    else
        f.empty:Hide()
    end
    local rowsH = (shown > 0 and shown or 1) * (h + GAP)
    f:SetHeight(math.max(MIN_H, TOP + rowsH + 24))
    -- the scrollbar: only when the list is longer than the rows
    f.scrollMax = n - maxRows
    if f.scroll then
        if f.scrollMax > 0 then
            f.scroll:SetHeight(math.max(3 * C.SCROLL_W, rowsH - GAP - 2 * (C.SCROLL_W + 2)))
            f.scroll:Show()
            f.upBtn:Show(); f.downBtn:Show()
            f.scroll:SetKnob(f.offset / f.scrollMax)
        else
            f.scroll:Hide()
            f.upBtn:Hide(); f.downBtn:Hide()
        end
    end

    local text
    -- "Fight time" while a fight is on, "Last fight" after it, with its length
    local live = UnitAffectingCombat("player") or (source == "server" and self.server and GetTime() - (self.server.t or 0) < 4)
    if source == "server" then
        text = (live and (C.LIVE .. "Fight time|r  ") or "Last fight  ") .. W.Clock(self.server.dur or 0)
    elseif segKind == "current" then
        if seg then
            text = (live and (C.LIVE .. "Fight time|r  ") or "Last fight  ") .. W.Clock(dur or 0)
            if seg.boss then text = text .. "  " .. seg.boss end
        else
            text = "No fight yet"
        end
    else
        text = self:SegmentName(seg) .. "  " .. W.Clock(dur or 0)
    end
    f.footer:SetText(text .. "  |cff9a9a9a(change)|r")
end

-- -- Tabs and windows ----------------------------------------------------------------

function C:SelectTab(i, id)
    local w = self:Layout().windows[i]
    if not w or not findTab(w, id) then return end
    w.active = id
    if self.frames[i] then self.frames[i].offset = 0 end
    self:RefreshTabs(i)
    self:RenderWindow(i)
end

function C:AddTab(i, mode)
    local L = self:Layout()
    local w = L.windows[i]
    if not w then return end
    if getn(w.tabs) >= MAX_TABS then
        W.Print("Meters: that window is full. Tear a tab off into its own window (right-click the tab).")
        return
    end
    if not mode then
        local used = {}
        for _, t in ipairs(w.tabs) do used[t.mode] = true end
        mode = "dmg"
        for _, m in ipairs(C.MODES) do
            if not used[m.key] then mode = m.key break end
        end
    end
    local t = { id = L.nextTab, mode = mode, seg = "current" }
    L.nextTab = L.nextTab + 1
    tinsert(w.tabs, t)
    w.active = t.id
    self:RefreshTabs(i)
    self:RenderWindow(i)
    return t
end

function C:SetTabMode(i, id, mode)
    local w = self:Layout().windows[i]
    local t = w and findTab(w, id)
    if not t or not C.MODE[mode] then return end
    t.mode = mode
    if self.frames[i] then self.frames[i].offset = 0 end
    self:RefreshTabs(i)
    self:RenderWindow(i)
end

function C:SetTabSegment(i, id, sel)
    local w = self:Layout().windows[i]
    local t = w and findTab(w, id)
    if not t then return end
    t.seg = sel
    self:RenderWindow(i)
end

function C:RenameTab(i, id, name)
    local w = self:Layout().windows[i]
    local t = w and findTab(w, id)
    if not t then return end
    name = W.Trim(name or "")
    if strlen(name) > 24 then name = strsub(name, 1, 24) end
    t.name = (name ~= "") and name or nil
    self:RefreshTabs(i)
end

function C:MoveTab(i, id, dir)
    local w = self:Layout().windows[i]
    if not w then return end
    local t, idx = findTab(w, id)
    local to = idx and idx + dir
    if not t or to < 1 or to > getn(w.tabs) then return end
    w.tabs[idx], w.tabs[to] = w.tabs[to], w.tabs[idx]
    self:RefreshTabs(i)
end

function C:RemoveWindow(i)
    local L = self:Layout()
    if i <= 1 or not L.windows[i] then return end
    tremove(L.windows, i)
    if self.frames[i] and self.frames[i].sheet then self.frames[i].sheet:Hide() end
    self:RefreshWindows()
end

function C:CloseTab(i, id)
    local L = self:Layout()
    local w = L.windows[i]
    if not w then return end
    local t, idx = findTab(w, id)
    if not t then return end
    if getn(w.tabs) <= 1 then
        if i > 1 then self:RemoveWindow(i) end
        return
    end
    tremove(w.tabs, idx)
    if w.active == id then w.active = w.tabs[math.max(1, idx - 1)].id end
    self:RefreshTabs(i)
    self:RenderWindow(i)
end

-- A tab becomes its own window, placed beside the one it came from.
function C:TearOff(i, id)
    local L = self:Layout()
    local w = L.windows[i]
    if not w or getn(w.tabs) < 2 then return end
    if getn(L.windows) >= MAX_WINDOWS then
        W.Print("Meters: " .. MAX_WINDOWS .. " windows is the most you can have open.")
        return
    end
    local t, idx = findTab(w, id)
    if not t then return end
    tremove(w.tabs, idx)
    if w.active == id then w.active = w.tabs[math.max(1, idx - 1)].id end
    tinsert(L.windows, { tabs = { t }, active = t.id })
    local ni = getn(L.windows)
    local src = self.frames[i]
    local f = self:EnsureFrame(ni)
    local x, y = src and src:GetLeft(), src and src:GetTop()
    if x and y then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", math.max(0, x - WIDTH - 12), y)
        W:SavePosition(f)
    end
    self:RefreshWindows()
    return ni
end

-- Move a tab from a torn-off window back into the main one.
function C:DockTab(i, id)
    local L = self:Layout()
    local w = L.windows[i]
    if i <= 1 or not w then return end
    local t, idx = findTab(w, id)
    if not t then return end
    local main = L.windows[1]
    if getn(main.tabs) >= MAX_TABS then
        W.Print("Meters: the main window is full. Close one of its tabs first.")
        return
    end
    tremove(w.tabs, idx)
    tinsert(main.tabs, t)
    main.active = t.id
    if not w.tabs[1] then
        tremove(L.windows, i)
    elseif w.active == id then
        w.active = w.tabs[1].id
    end
    self:RefreshWindows()
end

function C:NewWindow(mode)
    local L = self:Layout()
    if getn(L.windows) >= MAX_WINDOWS then
        W.Print("Meters: " .. MAX_WINDOWS .. " windows is the most you can have open.")
        return
    end
    local t = { id = L.nextTab, mode = mode or "heal", seg = "current" }
    L.nextTab = L.nextTab + 1
    tinsert(L.windows, { tabs = { t }, active = t.id })
    self:RefreshWindows()
    return getn(L.windows)
end

-- The close button: the main window hides (/meters brings it back); a torn-off window
-- closes and its tabs go back into the main window, as many as fit.
function C:CloseWindow(i)
    if i == 1 then
        self.userClosed = true
        if self.frames[1] then self.frames[1]:Hide() end
        return
    end
    local L = self:Layout()
    local w = L.windows[i]
    if not w then return end
    local main = L.windows[1]
    for _, t in ipairs(w.tabs) do
        if getn(main.tabs) < MAX_TABS then tinsert(main.tabs, t) end
    end
    self:RemoveWindow(i)
end

-- -- Menus ----------------------------------------------------------------------------

function C:ModeMenu(f)
    local i = f.index
    local w = self:Layout().windows[i]
    if not w then return end
    local t = activeTab(w)
    local id = t.id
    local items = { { text = "Show in this tab", title = true } }
    for _, m in ipairs(C.MODES) do
        local key = m.key
        tinsert(items, { text = m.label, icon = m.icon, checked = (t.mode == key),
            func = function() C:SetTabMode(i, id, key) end })
    end
    tinsert(items, { text = "Threat (opens the Threat window)", icon = "Interface\\Icons\\Ability_Warrior_DefensiveStance",
        func = function() C:OpenThreat() end })
    return UI.Menu(f.dragHandle, items)
end

function C:SegmentMenu(f)
    local i = f.index
    local w = self:Layout().windows[i]
    if not w then return end
    local t = activeTab(w)
    local id = t.id
    local function pick(sel) return function() C:SetTabSegment(i, id, sel) end end
    local items = {
        { text = "Fight", title = true },
        { text = "Current fight" .. (self.fight and ("  " .. W.Clock(self:Duration(self.fight))) or ""),
            checked = (t.seg == "current"), func = pick("current") },
        { text = "Overall" .. (self.overall and ("  " .. W.Clock(self:Duration(self.overall))) or ""),
            checked = (t.seg == "overall"), func = pick("overall") },
    }
    if self.history[1] then
        tinsert(items, { text = "Earlier fights", title = true })
        for _, s in ipairs(self.history) do
            tinsert(items, { text = self:SegmentName(s) .. "  " .. W.Clock(s.dur), checked = (t.seg == s.id),
                icon = s.boss and "Interface\\TargetingFrame\\UI-TargetingFrame-Skull" or nil,
                color = s.boss and { 1, 0.86, 0.45 } or nil, func = pick(s.id) })
        end
    else
        tinsert(items, { text = "No earlier fights yet", disabled = true })
    end
    return UI.Menu(f.segBtn, items)
end

function C:TabMenu(i, id, anchor)
    local L = self:Layout()
    local w = L.windows[i]
    if not w then return end
    local t, idx = findTab(w, id)
    if not t then return end
    local n = getn(w.tabs)
    local items = {
        { text = tabLabel(t), title = true },
        { text = "Rename", func = function() C:StartRename(i, id, anchor) end },
        { text = "Move left", disabled = idx <= 1, func = function() C:MoveTab(i, id, -1) end },
        { text = "Move right", disabled = idx >= n, func = function() C:MoveTab(i, id, 1) end },
    }
    if n > 1 then
        tinsert(items, { text = "Tear off into its own window", disabled = getn(L.windows) >= MAX_WINDOWS,
            func = function() C:TearOff(i, id) end })
    end
    if i > 1 then
        tinsert(items, { text = "Move to the main window", func = function() C:DockTab(i, id) end })
    end
    tinsert(items, { text = "Close tab", disabled = (n <= 1 and i == 1), func = function() C:CloseTab(i, id) end })
    return UI.Menu(anchor, items)
end

-- A small edit box over the tab; Enter keeps the name, Escape cancels, empty restores the mode name.
function C:StartRename(i, id, anchor)
    local w = self:Layout().windows[i]
    local t = w and findTab(w, id)
    if not t then return end
    local box = Meters_RenameBox
    if not box then
        box = CreateFrame("EditBox", "Meters_RenameBox", UIParent)
        UI.Skin(box, "raised")
        box:SetWidth(120)
        box:SetHeight(18)
        box:SetFrameStrata("DIALOG")
        box:SetAutoFocus(false)
        box:SetMaxLetters(24)
        box:SetFontObject(GameFontHighlightSmall)
        if box.SetTextInsets then box:SetTextInsets(5, 5, 0, 0) end
        box:SetScript("OnEnterPressed", function()
            local b = Meters_RenameBox
            b:Hide()
            C:RenameTab(b.win, b.tab, b:GetText())
        end)
        box:SetScript("OnEscapePressed", function() Meters_RenameBox:Hide() end)
        box:Hide()
    end
    box.win, box.tab = i, id
    box:ClearAllPoints()
    box:SetPoint("BOTTOMLEFT", anchor or self.frames[i].tabs, "BOTTOMLEFT", 0, 0)
    box:SetText(tabLabel(t))
    box:Show()
    box:SetFocus()
    box:HighlightText()
end

function C:OpenThreat()
    if not Vanguard_Frame then
        W.Print("Meters: the Threat addon is not installed.")
        return
    end
    if not W:IsActive("Threat") then
        W.Print("Meters: Threat is turned off. Turn it on in /addons.")
        return
    end
    if Vanguard then Vanguard.userClosed = nil end
    if Vanguard and GetTime() - (Vanguard.last or 0) <= 6 then
        Vanguard_Frame:Show()
        if Vanguard_Frame.Raise then Vanguard_Frame:Raise() end
    else
        W.Print("Meters: Threat opens by itself as soon as the realm sends your target's threat.")
    end
end

-- -- Settings sheet ---------------------------------------------------------------------

function C:BuildSheet(f)
    local sh = UI.Sheet(f, { title = "Meters settings", width = 236, name = (f.index == 1) and "Meters_Settings" or nil })
    local function get(k, d) return function() return S(k, d) end end
    local function getOn(k, d) return function() return S(k, d) and true or false end end
    local function set(k) return function(v) C:Set(k, v) end end
    sh:AddHeader("Bars")
    sh.rowsSlider = sh:AddSlider("Rows", 1, MAX_ROWS, 1, get("maxRows", 8), set("maxRows"))
    sh.heightSlider = sh:AddSlider("Bar height", 12, 28, 1, get("barHeight", 18), set("barHeight"), "%d px")
    sh.fontChoice = sh:AddChoice("Text size", FONT_CHOICES, get("fontSize", 11), set("fontSize"))
    sh.textureChoice = sh:AddChoice("Bar texture", C.TEXTURES, get("barTexture", "bronze"), set("barTexture"))
    sh.paletteChoice = sh:AddChoice("Class colours", C.PALETTES, get("classPalette", "meters"), set("classPalette"))
    sh.rowFontChoice = sh:AddChoice("Row font", C.ROW_FONTS, get("rowFont", "sans"), set("rowFont"))
    sh.frameChoice = sh:AddChoice("Window frame", C.FRAMES, get("frameStyle", "window"), set("frameStyle"))
    sh.frameSwitch = sh:AddSwitch("Bar frame", "A weathered iron frame with bronze studs round each bar.", getOn("barFrame", false), set("barFrame"))
    sh.classSwitch = sh:AddSwitch("Class colours", "Colour each bar by the player's class.", getOn("classColors", true), set("classColors"))
    sh:AddHeader("Numbers")
    sh.numberChoice = sh:AddChoice("Number format", NUMBER_CHOICES, get("numberFormat", "full"), set("numberFormat"))
    sh.dpsSwitch = sh:AddSwitch("Show per second", "A DPS or HPS column beside the totals.", getOn("showDps", true), set("showDps"))
    sh.rankSwitch = sh:AddSwitch("Rank numbers", "Put 1. 2. 3. in front of the names.", getOn("showRank", false), set("showRank"))
    sh:AddHeader("Windows")
    sh.hideSwitch = sh:AddSwitch("Hide out of combat", "The windows fade out after a fight and come back with the next one.", getOn("autoHide", false), set("autoHide"))
    sh.lockSwitch = sh:AddSwitch("Lock windows", "Stop the windows from being dragged.", getOn("lock", false), set("lock"))
    sh.scaleSlider = sh:AddSlider("Scale", 0.6, 1.6, 0.05, get("scale", 1), set("scale"), "%.2f")
    sh.clickSwitch = sh:AddSwitch("Click a bar for its breakdown", "Spells and targets; Shift-click a second player to compare.", getOn("inspectOnClick", true), set("inspectOnClick"))
    sh:AddButton("Open a new window", function() C:NewWindow() end)
    sh:AddButton("Reset all fights", function() C:Reset() end)
    return sh
end

function C:ToggleSettings(f)
    f = f or self.frames[1]
    if not f.sheet then f.sheet = self:BuildSheet(f) end
    f.sheet:Toggle()
    return f.sheet
end

-- -- Breakdown tooltip and clicks ----------------------------------------------------------

function C:ShowInspect(row, ask)
    local name = row.playerName
    if not name then return end
    if not W:Setting(ID, "inspectOnClick", true) then return end
    local m = C.MODE[row.mode or self.mode] or C.MODE.dmg
    GameTooltip:SetOwner(row, "ANCHOR_LEFT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(name .. "  |cff909090" .. m.label .. "|r", 1, 0.82, 0)
    local current = (row.segKind == "current" or row.segKind == "server")
    local list = (m.value == "dmg" and current) and self.inspectData[name] or nil   -- the server sends damage only
    if not list then
        local seg = self:Segment(row.segSel)
        local p = seg and seg.players[name]
        local abil = p and m.value and p.abilities[m.value]
        if abil then
            local sum = 0
            list = {}
            for k, v in pairs(abil) do
                if v > 0 then
                    tinsert(list, { name = k, amount = v })
                    sum = sum + v
                end
            end
            table.sort(list, function(a, b) return a.amount > b.amount end)
            for _, a in ipairs(list) do a.pct = pct(a.amount, sum) end
        end
    end
    if ask and W.connected and m.value == "dmg" and current then W:SendCommand("ch inspect", name) end
    if not list or not list[1] then
        GameTooltip:AddLine("No ability breakdown yet.", 0.7, 0.7, 0.7)
    else
        for i = 1, math.min(5, getn(list)) do
            local a = list[i]
            local amount = m.count and tostring(a.amount) or Num(a.amount)
            GameTooltip:AddDoubleLine(a.name, amount .. "  |cff909090" .. (a.pct or "") .. "|r", 0.9, 0.9, 0.9, 1, 1, 1)
        end
    end
    if not ask then GameTooltip:AddLine("Click for spells and targets. Shift-click to compare.", 0.55, 0.57, 0.62) end
    GameTooltip:Show()
end

function C:RowClick(row, button)
    local item = row.item
    if not item then return end
    if item.death then
        if self.ShowDeath then self:ShowDeath(item.death) end
        return
    end
    if not row.playerName then return end
    if not W:Setting(ID, "inspectOnClick", true) then return end
    self:ShowInspect(row, true)
    if not self.ShowDetail then return end
    local d = self.detail
    if IsShiftKeyDown() and d and d.name and not d.death and d.name ~= row.playerName
        and Chronicle_Detail and Chronicle_Detail:IsShown() then
        self:ShowCompare(d.name, row.playerName, row.mode, row.segSel)
    else
        self:ShowDetail(row.playerName, row.mode, row.segSel)
    end
end

-- -- Reports --------------------------------------------------------------------------

C.queue = {}
C.sendWait = 0
local SEND_GAP = 0.4    -- seconds between lines, under the server's chat flood limit

local function plain(s)
    s = strgsub(s, "|c%x%x%x%x%x%x%x%x", "")
    s = strgsub(s, "|r", "")
    s = strgsub(s, "|H.-|h(.-)|h", "%1")
    s = strgsub(s, "|", "/")
    if strlen(s) > 250 then s = strsub(s, 1, 250) end
    return s
end
C.Plain = plain

function C:Send(msg, chan, target)
    msg = plain(msg)
    if ChatThrottleLib and ChatThrottleLib.SendChatMessage then
        ChatThrottleLib:SendChatMessage("NORMAL", "Meters", msg, chan, nil, target)
        return
    end
    tinsert(self.queue, { msg, chan, target })
end

function C:PumpQueue(elapsed)
    self.sendWait = self.sendWait - (elapsed or 0)
    while self.queue[1] and self.sendWait <= 0 do
        local q = tremove(self.queue, 1)
        SendChatMessage(q[1], q[2], nil, q[3])
        self.sendWait = SEND_GAP
    end
    if not self.queue[1] and self.sendWait < 0 then self.sendWait = 0 end
end

function C:PlainValue(m, item, total, dur)
    if item.death then
        local d, b = item.death, item.death.blow
        local s = "died at " .. W.Clock(d.t)
        if b then
            s = s .. " - " .. (b.abil or "Melee")
            if b.src and b.src ~= "" then s = s .. " (" .. b.src .. ")" end
            s = s .. " " .. Num(-b.amt)
        end
        return s
    elseif item.aura then
        return W.Clock(item.total) .. " (" .. pct(item.total, dur) .. ")"
    elseif m.key == "overheal" then
        return Num(item.total) .. " (" .. ((item.known and item.known > 0) and pct(item.total, item.known) or "?") .. " of heals)"
    elseif m.count then
        return item.total .. " (" .. pct(item.total, total) .. ")"
    elseif m.rate then
        return Num(item.total) .. " (" .. Num(item.perSec) .. "/s, " .. pct(item.total, total) .. ")"
    end
    return Num(item.total) .. " (" .. pct(item.total, total) .. ")"
end

-- The lines a report would send for window i (nil when there is nothing to report).
function C:ReportLines(i, n)
    local L = self:Layout()
    local w = L.windows[i or 1] or L.windows[1]
    local t = activeTab(w)
    local m = C.MODE[t.mode] or C.MODE.dmg
    local seg, kind = self:Segment(t.seg)
    local list, total, source, dur = self:RowsFor(m.key, seg, kind)
    if not list[1] then return nil end
    local where = (source == "server") and "Current fight" or self:SegmentName(seg)
    local out = { "Meters: " .. m.label .. " - " .. where .. " (" .. W.Clock(dur or 0) .. ")" }
    n = n or S("reportLines", 5)
    for r = 1, math.min(n, getn(list)) do
        local it = list[r]
        tinsert(out, plain(r .. ". " .. it.name .. " " .. self:PlainValue(m, it, total, dur)))
    end
    return out
end

-- chan: SAY, PARTY, RAID, GUILD or WHISPER (with a target name).
function C:Report(i, chan, target, n)
    chan = strupper(chan or "SAY")
    if chan == "PARTY" and (GetNumPartyMembers() or 0) == 0 and (GetNumRaidMembers() or 0) == 0 then
        W.Print("Meters: you are not in a party.")
        return
    elseif chan == "RAID" and (GetNumRaidMembers() or 0) == 0 then
        W.Print("Meters: you are not in a raid.")
        return
    elseif chan == "GUILD" and not (IsInGuild and IsInGuild()) then
        W.Print("Meters: you are not in a guild.")
        return
    elseif chan == "WHISPER" and (not target or target == "") then
        W.Print("Meters: whisper whom? Target a player, or type /meters report whisper Name.")
        return
    elseif chan ~= "SAY" and chan ~= "PARTY" and chan ~= "RAID" and chan ~= "GUILD" and chan ~= "WHISPER" then
        W.Print("Meters: report to say, party, raid, guild or whisper.")
        return
    end
    local lines = self:ReportLines(i, n)
    if not lines then
        W.Print("Meters: nothing to report yet.")
        return
    end
    for _, l in ipairs(lines) do self:Send(l, chan, target) end
    self:PumpQueue(0)
    return lines
end

function C:ReportMenu(f, anchor)
    local i = f.index
    local w = self:Layout().windows[i]
    if not w then return end
    local m = C.MODE[activeTab(w).mode] or C.MODE.dmg
    local n = S("reportLines", 5)
    local inRaid = (GetNumRaidMembers() or 0) > 0
    local inParty = inRaid or (GetNumPartyMembers() or 0) > 0
    local items = {
        { text = "Report " .. m.label .. " (top " .. n .. ")", title = true },
        { text = "Say", func = function() C:Report(i, "SAY") end },
        { text = "Party", disabled = not inParty, func = function() C:Report(i, "PARTY") end },
        { text = "Raid", disabled = not inRaid, func = function() C:Report(i, "RAID") end },
        { text = "Guild", disabled = not (IsInGuild and IsInGuild()), func = function() C:Report(i, "GUILD") end },
    }
    if UnitExists("target") and UnitIsPlayer("target") and not UnitIsUnit("target", "player") then
        local who = UnitName("target")
        tinsert(items, { text = "Whisper " .. who, func = function() C:Report(i, "WHISPER", who) end })
    else
        tinsert(items, { text = "Whisper (target a player first)", disabled = true })
    end
    tinsert(items, { text = "Lines", title = true })
    for _, c in ipairs(LINE_CHOICES) do
        local k = c.value
        tinsert(items, { text = c.label, checked = (n == k), func = function()
            C:Set("reportLines", k)
            C:ReportMenu(f, anchor)
        end })
    end
    return UI.Menu(anchor or f.report, items)
end

-- -- Events & refresh ----------------------------------------------------------------------

local ev = CreateFrame("Frame", "Chronicle_Events")
ev:RegisterEvent("VARIABLES_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PARTY_MEMBERS_CHANGED")
ev:RegisterEvent("RAID_ROSTER_UPDATE")
ev:RegisterEvent("UNIT_PET")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("PLAYER_TARGET_CHANGED")
for _, e in ipairs(C.EVENTS) do ev:RegisterEvent(e) end

ev:SetScript("OnEvent", function()
    if event == "VARIABLES_LOADED" then
        C:RefreshWindows()
        return
    end
    if event == "PLAYER_ENTERING_WORLD" or event == "PARTY_MEMBERS_CHANGED"
        or event == "RAID_ROSTER_UPDATE" or event == "UNIT_PET" then
        C:UpdateRoster()
        return
    end
    if not W:IsActive(ID) then return end
    if event == "PLAYER_REGEN_DISABLED" then
        if C.fight and GetTime() - C.fight.last > 3 then C:EndFight() end
        C.peek = nil
        C:UpdateVisibility()
        C.dirty = true
        return
    elseif event == "PLAYER_REGEN_ENABLED" then
        C.dirty = true
        return
    elseif event == "PLAYER_TARGET_CHANGED" then
        C:ScanBoss()
        return
    end
    C:OnLine(arg1)
end)

local elapsed = 0
ev:SetScript("OnUpdate", function()
    C:PumpQueue(arg1)
    elapsed = elapsed + arg1
    if elapsed < 0.5 then return end
    elapsed = 0
    if not W:IsActive(ID) then return end
    if C.fight and C.fight.boss == nil and C:IsLive() then C:ScanBoss() end
    if S("autoHide", false) then C:UpdateVisibility() end
    if C.dirty or UnitAffectingCombat("player") then C:Render() end
end)

W:RegisterAddon(ID, function(active)
    C:RefreshWindows()
end)

W:RegisterSchema(ID, {
    icon = "Interface\\Icons\\Ability_Warrior_SavageBlow",
    title = "Meters - Damage, Healing & More",
    desc = "Damage, healing, deaths, interrupts, dispels and more for you, your group and your pets, fight by fight. Uses the realm's numbers when it sends them, otherwise your own combat log. The gear on each window has the same settings.",
    defaults = {
        maxRows = 8, showDps = true, classColors = true, inspectOnClick = true,
        barHeight = 18, fontSize = 11, barTexture = "bronze", numberFormat = "full", classPalette = "meters", rowFont = "sans",
        frameStyle = "window", barFrame = false,
        autoHide = false, lock = false, scale = 1, reportLines = 5, showRank = false,
    },
    options = {
        { key = "classColors", label = "Class-coloured bars", sub = "Colour each bar by the player's class." },
        { key = "barFrame", label = "Bar frame", sub = "A weathered iron frame with bronze studs round each bar." },
        { key = "showDps", label = "Show DPS", sub = "A per-second column beside the damage and healing totals." },
        { key = "inspectOnClick", label = "Click a bar for its breakdown", sub = "Clicking a player shows their spells and targets; Shift-click a second player to compare." },
        { key = "autoHide", label = "Hide out of combat", sub = "The windows fade out after a fight and come back with the next one." },
        { key = "lock", label = "Lock windows", sub = "Stop the windows from being dragged." },
        { key = "showRank", label = "Rank numbers", sub = "Put 1. 2. 3. in front of the names." },
        { key = "numberFormat", label = "Number format", type = "choice", choices = NUMBER_CHOICES },
        { key = "barTexture", label = "Bar texture", type = "choice", choices = C.TEXTURES },
        { key = "classPalette", label = "Class colours", type = "choice", choices = C.PALETTES },
        { key = "rowFont", label = "Row font", type = "choice", choices = C.ROW_FONTS },
        { key = "frameStyle", label = "Window frame", type = "choice", choices = C.FRAMES },
        { key = "fontSize", label = "Text size", type = "choice", choices = FONT_CHOICES },
        { key = "reportLines", label = "Lines in a report", type = "choice", choices = LINE_CHOICES },
        { key = "maxRows", label = "Rows", type = "slider", min = 1, max = MAX_ROWS, step = 1, fmt = "%d" },
        { key = "barHeight", label = "Bar height", type = "slider", min = 12, max = 28, step = 1, fmt = "%d px" },
        { key = "scale", label = "Scale", type = "slider", min = 0.6, max = 1.6, step = 0.05, fmt = "%.2f" },
    },
})

C:UpdateRoster()
C:EnsureFrame(1)
C:RefreshWindows()

-- -- Slash commands -----------------------------------------------------------------------

local MODE_ALIASES = {
    dmg = "dmg", damage = "dmg", dps = "dps", heal = "heal", healing = "heal", hps = "hps",
    overheal = "overheal", overhealing = "overheal", taken = "dtaken", dtaken = "dtaken",
    healed = "htaken", htaken = "htaken", deaths = "deaths", death = "deaths",
    interrupts = "interrupts", kicks = "interrupts", dispels = "dispels", cc = "cc",
    auras = "auras", uptime = "auras", buffs = "auras", power = "power", resources = "power",
    mana = "power", res = "res", resurrects = "res", ff = "ff", friendly = "ff",
}

-- Same slash key as the bundled "Meters" stub, so this replaces it instead of racing it.
SLASH_METERS1 = "/meters"
SLASH_METERS2 = "/dps"
SLASH_METERS3 = "/chronicle"
SlashCmdList["METERS"] = function(msg)
    local raw = W.Trim(msg)
    local _, _, cmdRaw, restRaw = strfind(raw, "^(%S*)%s*(.*)$")
    local cmd = strlower(cmdRaw or "")
    local frame = C:EnsureFrame(1)
    if cmd == "reset" then C:Reset() return end
    if cmd == "help" then
        W.Print("/meters  show or hide  |  /meters <damage, healing, deaths, interrupts, ...>  |  /meters report <say, party, raid, guild, whisper Name> [lines]  |  /meters new  |  /meters settings  |  /meters reset")
        return
    end
    if not W:IsActive(ID) then return end
    if cmd == "report" then
        local _, _, chan, a1, a2 = strfind(restRaw or "", "^(%S*)%s*(%S*)%s*(%S*)")
        chan = strlower(chan or "")
        if chan == "w" or chan == "tell" then chan = "whisper" end
        if chan == "" then chan = "say" end
        if chan == "whisper" then
            C:Report(1, "WHISPER", a1, tonumber(a2))
        else
            C:Report(1, chan, nil, tonumber(a1))
        end
        return
    end
    if cmd == "new" or cmd == "window" then C:NewWindow() return end
    if cmd == "settings" or cmd == "config" or cmd == "options" then
        C.userClosed = nil
        C.peek = true
        C:UpdateVisibility()
        C:ToggleSettings(frame)
        return
    end
    local mode = MODE_ALIASES[cmd]
    if mode then
        local w = C:Layout().windows[1]
        C:SetTabMode(1, activeTab(w).id, mode)
    end
    if frame:IsShown() and raw == "" then
        C.userClosed = true
        frame:Hide()
    else
        C.userClosed = nil
        C.peek = true
        C:UpdateVisibility()
        C:Render()
    end
end
