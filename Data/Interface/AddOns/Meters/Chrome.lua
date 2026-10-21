--[[
    Chrome.lua  -  the Meters look. A Meters window is a normal Open Vanilla window: the same frame,
    header and title ("Meters") as the Guild Finder or the Achievements window, following the
    player's window skin (/skin). Inside it, everything is built for reading in a fight:
      - one clean sans for every small text: Roboto Medium (Apache 2.0, Fonts\LICENSE-Roboto.txt),
        whose digits are all the same width, so numbers never jitter as they count up;
      - a 1 px black outline on every text over a bar, so it reads on any class colour;
      - tabs like every other window's: plain labels, the chosen one white with a gold line under it;
      - a column strip on its own dark band with a divider under it, the labels over their columns;
      - rows: the class icon in its own square left of the bar (never over it), then the bar with
        the name, the total, the per-second figure (dimmer) and the share, each in a fixed column.
    Settings: "Window frame" = Window (the normal frame) or Minimal (a thin dark frame, no portrait
    or ornaments, more room for the numbers); "Row font" = Roboto, Arial Narrow or Rounded.
    The art in Meters\Art is Open Vanilla's own; class icons are the player's own game icons.
]]--

local W = WenillaCore
local UI = W.UI
local C = Chronicle

local ART = "Interface\\AddOns\\Meters\\Art\\"
C.ART = {
    reset = ART .. "Meters_Reset", gear = ART .. "Meters_Gear", fill = ART .. "Meters_Fill",
    scrollTop = ART .. "Meters_ScrollTop", scrollTrack = ART .. "Meters_ScrollTrack",
    scrollBottom = ART .. "Meters_ScrollBottom", thumb = ART .. "Meters_Thumb",
    up = ART .. "Meters_Up", down = ART .. "Meters_Down", tab = ART .. "Meters_Tab",
    tabEdge = ART .. "Meters_TabEdge", tabGlow = ART .. "Meters_TabGlow", barFrame = ART .. "Meters_BarFrame",
}
C.GOLD = { 1, 0.82, 0.42 }

-- Layout. Under the Classic skin the frame art (portrait, title strip, header band) is drawn round
-- the window, above its top edge: the tabs sit in that header band beside the portrait and the rows
-- start right at the window's top. Under the other skins and the Minimal frame there is no band:
-- the tabs go under the window's own title bar and the rows under them.
C.EDGE = 8                  -- content starts this far in from the sides
C.TAB_H = 22                -- tabs: 22 px, the label with room above and below
-- The Classic frame round a window (UI.CHROME: 16 px left, 50 up, 10 right): its title strip spans
-- y +20..+35 over the window, the header band +20..-23, and the body starts at -23. The tabs stand
-- on the body's top edge in the band, from just right of the portrait; the reset and cog sit on the
-- title strip, left of the close button.
C.BANDED = { tabsY = 1, tabsX = 58, rowsY = 25, toolsY = 35, toolsRight = 30, tool = 16 }  -- y: up is positive
C.FLAT = { tabsY = -26, tabsX = C.EDGE, rowsY = 50, tool = 20 }
C.TABS_Y = -C.FLAT.tabsY    -- (the Breakdown window keeps the flat layout)
C.ROWS_Y = C.FLAT.rowsY

-- Whether the window wears the Classic frame art with its header band right now.
function C.Banded(f)
    if W:Setting("Meters", "frameStyle", "window") == "minimal" then return false end
    local th = UI.Theme and UI.Theme()
    return th and th.key == "classic" and f.classicFrame and true or false
end

-- Each mode's portrait: its icon, the Healing Touch leaf for healing.
C.PORTRAITS = {
    dmg = "Interface\\Icons\\Ability_Warrior_SavageBlow", dps = "Interface\\Icons\\Ability_Warrior_SavageBlow",
    heal = "Interface\\Icons\\Spell_Nature_HealingTouch", hps = "Interface\\Icons\\Spell_Nature_HealingTouch",
    htaken = "Interface\\Icons\\Spell_Nature_HealingTouch", overheal = "Interface\\Icons\\Spell_Nature_HealingTouch",
}
function C.Portrait(m)
    return (m and (C.PORTRAITS[m.key] or m.icon)) or C.PORTRAITS.dmg
end
function C.SetPortrait(f, path)
    if not path or f.portraitPath == path then return end
    f.portraitPath = path
    f.chromeIcon = path
    if f.chrome and f.chrome.SetPortrait then f.chrome:SetPortrait(path) end
    if f.icon then f.icon:SetTexture(path) end
end

-- -- Fonts -------------------------------------------------------------------------------------------
local FONTS = "Interface\\AddOns\\Meters\\Fonts\\"
C.FONT_SANS = FONTS .. "Roboto-Medium.ttf"
C.FONT_ROUNDED = FONTS .. "Nunito-ExtraBold.ttf"
C.FONT_NARROW = "Fonts\\ARIALN.TTF"
C.ROW_FONTS = { { value = "sans", label = "Roboto" }, { value = "narrow", label = "Arial Narrow" }, { value = "rounded", label = "Rounded" } }
function C.RowFontPath()
    local k = W:Setting("Meters", "rowFont", "sans")
    if k == "narrow" then return C.FONT_NARROW end
    if k == "rounded" then return C.FONT_ROUNDED end
    return C.FONT_SANS
end

-- Text over a bar or the frame: the row font, a 1 px black outline and a soft drop shadow.
function C.Text(fs, size, color)
    if fs.SetFont then fs:SetFont(C.RowFontPath(), size, "OUTLINE") end
    fs:SetShadowOffset(1, -1)
    fs:SetShadowColor(0, 0, 0, 0.6)
    if color then fs:SetTextColor(color[1], color[2], color[3], color[4] or 1) end
end
C.RowText = C.Text

C.NAME_COLOR = { 1, 1, 1 }
C.NUM_COLOR = { 1, 1, 1 }
C.RATE_COLOR = { 1, 1, 1, 0.7 }       -- the per-second figure: the same white, 70%
C.SHARE_COLOR = { 0.80, 0.82, 0.86 }
C.LABEL_COLOR = { 0.78, 0.76, 0.70 }
C.LIVE = "|cffffb347"                  -- "in combat" in the footer: amber, readable on the dark frame

-- -- The window frame ------------------------------------------------------------------------------
C.FRAMES = { { value = "window", label = "Window" }, { value = "minimal", label = "Minimal" } }

-- Minimal: no portrait, header plaque or ornaments; a thin dark frame and a slim title strip.
local function paintMinimal(f)
    if f.chrome then f.chrome:Hide() end
    for _, k in ipairs(f.corners or {}) do k:Hide() end
    if f.header then f.header:Hide() end
    f:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Buttons\\WHITE8X8",
        tile = true, tileSize = 16, edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    f:SetBackdropColor(0.04, 0.045, 0.055, 0.88)
    f:SetBackdropBorderColor(0.22, 0.23, 0.26, 1)
    if f.titleBar then f.titleBar:SetTexture(0.10, 0.105, 0.12, 0.95) end
    if f.titleRule then f.titleRule:Show() end
    if f.icon then f.icon:Hide() end
    local t = f.title
    if t then
        t:ClearAllPoints()
        t:SetPoint("LEFT", f.titleBar, "LEFT", 6, 0)
        C.Text(t, 11, { 1, 0.86, 0.5 })
    end
    local cb = f.closeButton
    if cb then
        cb:ClearAllPoints()
        cb:SetWidth(22); cb:SetHeight(22)
        cb:SetPoint("RIGHT", f.titleBar, "RIGHT", 4, 0)
    end
end

-- The frame follows the player's skin (the normal window), or Minimal from the settings.
function C.Frame(f)
    f.paintSkin = function(th)
        if W:Setting("Meters", "frameStyle", "window") == "minimal" then
            paintMinimal(f)
        else
            UI.PaintWindow(f, th or UI.Theme())
            if f.chrome and f.chromeIcon and f.chrome.SetPortrait then f.chrome:SetPortrait(f.chromeIcon) end
            if f.chrome then C.CentreTitle(f) end
        end
        if f.Relayout then f:Relayout() end
    end
    f.paintSkin(UI.Theme())
end

-- The title, 13 pt, centred on the window over the title strip. The Classic frame puts it back on
-- every resize (its Fit), so Fit is wrapped to centre it again.
function C.CentreTitle(f)
    local c, t = f.chrome, f.title
    if not c or not t then return end
    UI.Font(t, 13)
    t:SetTextColor(1, 1, 1)
    local function place()
        t:ClearAllPoints()
        t:SetPoint("CENTER", f, "TOP", 0, 27)
    end
    if not c.meterFit then
        local fit = c.Fit
        c.meterFit = true
        function c:Fit() fit(self); place() end
    end
    place()
end

function C.Repaint(f)
    if f and f.paintSkin then f.paintSkin(UI.Theme()) end
end

-- -- Buttons -----------------------------------------------------------------------------------------

-- A small art button; the highlight is the same art, brightened.
function C.ArtButton(parent, size, path, onClick, tooltip)
    local b = CreateFrame("Button", nil, parent)
    b:SetWidth(size)
    b:SetHeight(size)
    b:SetNormalTexture(path)
    b:SetPushedTexture(path)
    local pushed = b:GetPushedTexture()
    if pushed and pushed.SetVertexColor then pushed:SetVertexColor(0.7, 0.7, 0.7, 1) end
    b:SetHighlightTexture(path)
    local hl = b:GetHighlightTexture()
    if hl then
        if hl.SetBlendMode then hl:SetBlendMode("ADD") end
        if hl.SetVertexColor then hl:SetVertexColor(1, 1, 1, 0.3) end
    end
    b:SetScript("OnClick", onClick)
    if tooltip then
        b:SetScript("OnEnter", function()
            GameTooltip:SetOwner(this, "ANCHOR_TOP")
            GameTooltip:SetText(tooltip, 1, 1, 1, 1, 1)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    return b
end

C.TOOL_SIZE = 16
-- The reset and cog: bare gold glyphs (Meters_Reset / Meters_Gear.tga, 32x32, a thin dark outline),
-- no box round them; the highlight brightens the glyph.
function C.ToolButton(parent, size, path, onClick, tooltip)
    local b = C.ArtButton(parent, size, path, onClick, tooltip)
    b.icon = b:GetNormalTexture()
    return b
end

-- -- Tabs ----------------------------------------------------------------------------------------------
-- Rounded tabs, three layers of three slices each (an 8 px cap each side, a repeating middle):
-- Meters_Tab.tga the fill (7 px round top corners, rows 0..21 of 32), Meters_TabEdge.tga a fine rim the same shape.
-- The chosen tab: a warm fill, a gold rim, a gold line along its foot with a soft glow, a white label.
-- The others: dark slate with a faint light rim and a soft grey label.
C.TAB_SEL, C.TAB_OFF = { 1, 1, 1 }, { 0.74, 0.75, 0.79 }
C.TAB_BG_SEL, C.TAB_BG_OFF = { 0.24, 0.18, 0.08, 0.96 }, { 0.10, 0.11, 0.13, 0.92 }
C.TAB_RIM_SEL, C.TAB_RIM_OFF = { 0.95, 0.74, 0.30, 1 }, { 0.42, 0.42, 0.46, 0.55 }
C.TAB_CAP = 8
local TV = C.TAB_H / 32
local function slices(b, layer, path)
    local out = {}
    local cap = C.TAB_CAP
    local coords = { { 0, cap / 64 }, { 24 / 64, 40 / 64 }, { (64 - cap) / 64, 1 } }
    for i = 1, 3 do
        local t = b:CreateTexture(nil, layer)
        t:SetTexture(path)
        t:SetTexCoord(coords[i][1], coords[i][2], 0, TV)
        out[i] = t
    end
    out[1]:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0); out[1]:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0); out[1]:SetWidth(cap)
    out[3]:SetPoint("TOPRIGHT", b, "TOPRIGHT", 0, 0); out[3]:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, 0); out[3]:SetWidth(cap)
    out[2]:SetPoint("TOPLEFT", out[1], "TOPRIGHT", 0, 0); out[2]:SetPoint("BOTTOMRIGHT", out[3], "BOTTOMLEFT", 0, 0)
    return out
end
local function tabPieces(b)
    if b.round then return b.round end
    b.round = slices(b, "BACKGROUND", C.ART.tab)
    b.rim = slices(b, "BORDER", C.ART.tabEdge)
    local glow = b:CreateTexture(nil, "ARTWORK")
    glow:SetTexture(C.ART.tabGlow)
    glow:SetBlendMode("ADD")
    glow:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 2, -5)
    glow:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, -5)
    glow:SetHeight(12)
    glow:SetVertexColor(1, 0.75, 0.25, 0.8)
    b.glow = glow
    if b.line then
        b.line:ClearAllPoints()
        b.line:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 6, 1)
        b.line:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -6, 1)
    end
    return b.round
end

function C.SkinTabs(bar)
    if not bar or not bar.buttons then return end
    for _, b in ipairs(bar.buttons) do
        if b:IsShown() then
            local sel = (b.key == bar.selected) and b.key ~= "__add"
            local pieces = tabPieces(b)
            local bg = sel and C.TAB_BG_SEL or C.TAB_BG_OFF
            local rim = sel and C.TAB_RIM_SEL or C.TAB_RIM_OFF
            for i = 1, 3 do
                pieces[i]:SetVertexColor(bg[1], bg[2], bg[3], bg[4])
                b.rim[i]:SetVertexColor(rim[1], rim[2], rim[3], rim[4])
            end
            b.glow:SetAlpha(sel and 1 or 0)
            if b.bg then b.bg:SetTexture(0, 0, 0, 0) end
            if b.edge then b.edge:SetAlpha(0) end
            if b.line then
                b.line:SetHeight(2)
                b.line:SetTexture(1, 0.80, 0.30, 1)
                b.line:SetAlpha(sel and 1 or 0)
            end
            C.Text(b.text, bar.tabFont or 11)
            b.text:SetShadowOffset(1, -1)
            b.text:SetShadowColor(0, 0, 0, 0.8)
            b.text:ClearAllPoints()
            b.text:SetPoint("CENTER", b, "CENTER", 0, 1)
            local c = sel and C.TAB_SEL or C.TAB_OFF
            b.text:SetTextColor(c[1], c[2], c[3])
            if not b.ovHooked then
                b.ovHooked = true
                b:SetScript("OnLeave", function() C.SkinTabs(bar) end)
            end
        end
    end
end

-- Every tab on whole pixels, the label's width plus 7 px each side, all C.TAB_H tall, 3 px apart.
-- Each tab as wide as its label plus 8 px a side (never cut), 3 px apart. When they don't fit in
-- bar.maxTotal the labels step down a size (11, 10, 9 pt) and then the padding narrows.
C.TAB_PAD, C.TAB_GAP = 16, 3
local function tabWidths(bar, size, pad)
    local list, total = {}, 0
    for _, b in ipairs(bar.buttons) do
        if b:IsShown() then
            if b.text.SetFont then b.text:SetFont(C.RowFontPath(), size, "OUTLINE") end
            local tw = (b.text.GetStringWidth and b.text:GetStringWidth()) or 30
            local w = (b.key == "__add") and 22 or math.ceil(tw + pad)
            table.insert(list, { b, w })
            total = total + w + C.TAB_GAP
        end
    end
    return list, total - C.TAB_GAP
end
local function snapTabs(bar)
    bar:SetHeight(C.TAB_H)
    local room = bar.maxTotal or 9999
    local list, size
    for _, try in ipairs({ { 11, C.TAB_PAD }, { 10, C.TAB_PAD }, { 10, 12 }, { 9, 10 } }) do
        local l, total = tabWidths(bar, try[1], try[2])
        list, size = l, try[1]
        if total <= room then break end
    end
    bar.tabFont = size
    local x = 0
    for _, e in ipairs(list) do
        local b, w = e[1], e[2]
        b:SetWidth(w)
        b:SetHeight(C.TAB_H)
        b:ClearAllPoints()
        b:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", x, 0)
        x = x + w + C.TAB_GAP
    end
    bar:SetWidth(math.max(1, x - C.TAB_GAP))
end
C.SnapTabs = snapTabs

function C.ChromeTabs(bar)
    local setTabs, choose = bar.SetTabs, bar.Select
    function bar:SetTabs(list) setTabs(self, list); C.SkinTabs(self); snapTabs(self); C.SkinTabs(self) end
    function bar:Select(key, silent) choose(self, key, silent); C.SkinTabs(self) end
    if UI.OnSkin then UI.OnSkin(function() C.SkinTabs(bar) end) end
    C.SkinTabs(bar)
    return bar
end

-- -- Rows ---------------------------------------------------------------------------------------------

-- The fill colours. "Meters" (the default): warrior red, the rest the game's class colours.
-- "Standard": the game's class colours for every class (warrior tan).
C.METERS_COLORS = { WARRIOR = { 0.78, 0.20, 0.20 }, SHAMAN = { 0.0, 0.44, 0.87 } }
C.FILL_ALPHA = 0.85
function C.BarColor(token)
    local palette = W:Setting("Meters", "classPalette", "meters")
    local own = palette ~= "standard" and token and C.METERS_COLORS[token]
    if own then return own[1], own[2], own[3] end
    local rc = RAID_CLASS_COLORS and token and RAID_CLASS_COLORS[token]
    if rc and rc.r then return rc.r, rc.g, rc.b end
    return UI.ClassColor(token)
end

function C.ChromeRow(row)
    row.track:SetTexture(0.07, 0.07, 0.08, 0.9)
    if row.iconBox then
        -- a quiet 1 px frame the colour of the window's edge, the icon's own border cropped off
        if row.iconBox.edge then row.iconBox.edge:SetTexture(0.18, 0.18, 0.20, 1) end
        if row.icon and row.icon.SetTexCoord then row.icon:SetTexCoord(0.1, 0.9, 0.1, 0.9) end
    end
    -- the per-second figure gets its own column (the stock row has left, mid and right)
    if not row.rate then
        local lvl = row.left:GetParent()
        row.rate = lvl:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.rate:SetJustifyH("RIGHT")
    end
    C.BarFrame(row)
    row.left:SetJustifyH("LEFT")
    row.mid:SetJustifyH("RIGHT")
    row.right:SetJustifyH("RIGHT")
    function row:SetColor(r, g, b, a)
        self.bar:SetStatusBarColor(r, g, b, a or C.FILL_ALPHA)
    end
    function row:SetFraction(frac)
        if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
        self.bar:SetValue(frac)
    end
end

-- The bar's frame: weathered dark iron, bevelled (light on the top and left of its outer edge, dark
-- inside), oxidised in spots, a bronze stud in each corner (Meters_BarFrame.tga, 64x32, a 6 px corner
-- slice, the edges in between). Drawn over the fill and under the text, round the bar (not the icon).
-- Settings: Bar frame (off by default).
C.FRAME_CORNER = 5
function C.BarFrame(row)
    if row.frameRim then return row.frameRim end
    local f = CreateFrame("Frame", nil, row)
    f:SetFrameLevel(row.bar:GetFrameLevel() + 1)
    f:SetAllPoints(row.track)
    local cu, cv = 6 / 64, 6 / 32
    local us, vs = { 0, cu, 1 - cu, 1 }, { 0, cv, 1 - cv, 1 }
    f.p = {}
    for r = 1, 3 do
        for c = 1, 3 do
            if not (r == 2 and c == 2) then
                local t = f:CreateTexture(nil, "OVERLAY")
                t:SetTexture(C.ART.barFrame)
                t:SetTexCoord(us[c], us[c + 1], vs[r], vs[r + 1])
                f.p[(r - 1) * 3 + c] = t
            end
        end
    end
    row.frameRim = f
    C.LayoutBarFrame(row)
    return f
end

function C.LayoutBarFrame(row)
    local f = row.frameRim
    if not f then return end
    local k = C.FRAME_CORNER
    local p = f.p
    p[1]:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0); p[1]:SetWidth(k); p[1]:SetHeight(k)
    p[3]:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0); p[3]:SetWidth(k); p[3]:SetHeight(k)
    p[7]:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0); p[7]:SetWidth(k); p[7]:SetHeight(k)
    p[9]:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0); p[9]:SetWidth(k); p[9]:SetHeight(k)
    p[2]:SetPoint("TOPLEFT", p[1], "TOPRIGHT", 0, 0); p[2]:SetPoint("BOTTOMRIGHT", p[3], "BOTTOMLEFT", 0, 0)
    p[8]:SetPoint("TOPLEFT", p[7], "TOPRIGHT", 0, 0); p[8]:SetPoint("BOTTOMRIGHT", p[9], "BOTTOMLEFT", 0, 0)
    p[4]:SetPoint("TOPLEFT", p[1], "BOTTOMLEFT", 0, 0); p[4]:SetPoint("BOTTOMRIGHT", p[7], "TOPRIGHT", 0, 0)
    p[6]:SetPoint("TOPLEFT", p[3], "BOTTOMLEFT", 0, 0); p[6]:SetPoint("BOTTOMRIGHT", p[9], "TOPRIGHT", 0, 0)
    if W:Setting("Meters", "barFrame", false) then f:Show() else f:Hide() end
end

-- Column right edges from the row's right (share, per second, total) and their widths.
C.COL_SHARE, C.COL_RATE = 4, 50
C.W_SHARE, C.W_RATE, C.W_TOTAL = 40, 40, 64
function C.TotalRight(showRate) return showRate and (C.COL_RATE + C.W_RATE + 10) or C.COL_RATE end

-- Sizes a row for height h: the icon square at the left, the bar from 2 px after it to the end;
-- the name after the bar's start, then the fixed columns at the right.
function C.LayoutRow(row, h, width, showRate)
    row.iconW = h
    if row.iconBox then
        row.iconBox:SetWidth(h); row.iconBox:SetHeight(h)
        row.iconBox:ClearAllPoints()
        row.iconBox:SetPoint("LEFT", row, "LEFT", 0, 0)
    end
    local x0 = row.iconBox and (h + 2) or 0
    row.track:ClearAllPoints()
    row.track:SetPoint("TOPLEFT", row, "TOPLEFT", x0, 0)
    row.track:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
    row.bar:ClearAllPoints()
    row.bar:SetAllPoints(row.track)
    row.left:ClearAllPoints(); row.left:SetPoint("LEFT", row.track, "LEFT", 5, 0)
    C.LayoutBarFrame(row)
    row.right:ClearAllPoints(); row.right:SetPoint("RIGHT", row.track, "RIGHT", -C.COL_SHARE, 0); row.right:SetWidth(C.W_SHARE)
    row.rate:ClearAllPoints(); row.rate:SetPoint("RIGHT", row.track, "RIGHT", -C.COL_RATE, 0); row.rate:SetWidth(C.W_RATE)
    row.mid:ClearAllPoints(); row.mid:SetPoint("RIGHT", row.track, "RIGHT", -C.TotalRight(showRate), 0)
    row.left:SetPoint("RIGHT", row.mid, "LEFT", -6, 0)
end

-- -- Scrollbar ----------------------------------------------------------------------------------------
-- A dark track with chevron caps and a square thumb; a click on the track pages there.
C.SCROLL_W = 10
local function tex(parent, layer, path)
    local t = parent:CreateTexture(nil, layer)
    t:SetTexture(path)
    return t
end
function C.Scrollbar(f, onClick)
    local s = CreateFrame("Button", nil, f)
    local w = C.SCROLL_W
    s:SetWidth(w)
    local top = tex(s, "ARTWORK", C.ART.scrollTop)
    top:SetPoint("TOPLEFT", s, "TOPLEFT", 0, 0); top:SetWidth(w); top:SetHeight(w)
    local bottom = tex(s, "ARTWORK", C.ART.scrollBottom)
    bottom:SetPoint("BOTTOMLEFT", s, "BOTTOMLEFT", 0, 0); bottom:SetWidth(w); bottom:SetHeight(w)
    local track = tex(s, "BACKGROUND", C.ART.scrollTrack)
    track:SetPoint("TOPLEFT", top, "BOTTOMLEFT", 0, 2); track:SetPoint("BOTTOMRIGHT", bottom, "TOPRIGHT", 0, -2)
    local knob = tex(s, "OVERLAY", C.ART.thumb)
    knob:SetWidth(w - 2); knob:SetHeight(w - 2)
    s.top, s.bottom, s.rod, s.knob = top, bottom, track, knob
    s:SetScript("OnClick", function()
        local _, y = GetCursorPosition()
        local scale = (s.GetEffectiveScale and s:GetEffectiveScale()) or 1
        if scale <= 0 then scale = 1 end
        local t, b = s:GetTop(), s:GetBottom()
        if not t or not b or t <= b then return end
        if onClick then onClick((t - y / scale) / (t - b)) end
    end)
    function s:SetKnob(frac)
        local h = self:GetHeight() or 0
        if frac < 0 then frac = 0 elseif frac > 1 then frac = 1 end
        local run = h - 2 * w - (w - 2)
        self.knob:ClearAllPoints()
        self.knob:SetPoint("TOP", self, "TOP", 0, -(w + math.floor(math.max(0, run) * frac + 0.5)))
    end
    s:Hide()
    return s
end
