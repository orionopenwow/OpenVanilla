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
    up = ART .. "Meters_Up", down = ART .. "Meters_Down",
}
C.GOLD = { 1, 0.82, 0.42 }

-- Layout inside a window (the frame's own layout, so it is the same in every skin; the Classic skin
-- draws its portrait and header round it): tabs on the title band, then the column strip, then rows.
C.EDGE = 8                  -- content starts this far in from the sides
C.TABS_Y = 28               -- top of the tab row, from the window's top
C.TAB_H = 20                -- tabs: 20 px, the label with room above and below
C.STRIP_Y = 52              -- the column strip
C.STRIP_H = 16
C.ROWS_Y = C.STRIP_Y + C.STRIP_H + 2

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
        end
    end
    f.paintSkin(UI.Theme())
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

-- The reset and cog: 20 px square buttons drawn on whole pixels at the top left of a 32x32 texture.
C.TOOL_SIZE = 20
function C.ToolButton(parent, size, path, onClick, tooltip)
    local b = C.ArtButton(parent, size, path, onClick, tooltip)
    local u = C.TOOL_SIZE / 32
    for _, t in ipairs({ b:GetNormalTexture(), b:GetPushedTexture(), b:GetHighlightTexture() }) do
        if t and t.SetTexCoord then t:SetTexCoord(0, u, 0, u) end
    end
    b.icon = b:GetNormalTexture()
    return b
end

-- -- Tabs ----------------------------------------------------------------------------------------------
-- The suite's own tabs (as in the Guild Finder), in the row font: the chosen tab's label white with
-- the gold line under it, the others a soft grey; no heavy shadow, just the outline.
C.TAB_SEL, C.TAB_OFF = { 1, 1, 1 }, { 0.70, 0.71, 0.75 }
function C.SkinTabs(bar)
    if not bar or not bar.buttons then return end
    for _, b in ipairs(bar.buttons) do
        if b:IsShown() then
            local sel = (b.key == bar.selected) and b.key ~= "__add"
            C.Text(b.text, 11)
            b.text:SetShadowOffset(0, 0)
            local c = sel and C.TAB_SEL or C.TAB_OFF
            b.text:SetTextColor(c[1], c[2], c[3])
            if b.line then b.line:SetHeight(2) end
            if not b.ovHooked then
                b.ovHooked = true
                b:SetScript("OnLeave", function() C.SkinTabs(bar) end)
            end
        end
    end
end

-- Every tab on whole pixels, the label's width plus 8 px each side, all C.TAB_H tall.
local function snapTabs(bar)
    local x = 0
    bar:SetHeight(C.TAB_H)
    for _, b in ipairs(bar.buttons) do
        if b:IsShown() then
            local tw = (b.text.GetStringWidth and b.text:GetStringWidth()) or 30
            local w = (b.key == "__add") and 20 or math.floor(math.min(bar.maxTab or 84, tw + 16) + 0.5)
            b:SetWidth(w)
            b:SetHeight(C.TAB_H)
            b:ClearAllPoints()
            b:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", x, 0)
            x = x + w + 1
        end
    end
    bar:SetWidth(math.max(1, x))
end

function C.ChromeTabs(bar)
    local setTabs, choose = bar.SetTabs, bar.Select
    function bar:SetTabs(list) setTabs(self, list); C.SkinTabs(self); snapTabs(self); C.SkinTabs(self) end
    function bar:Select(key, silent) choose(self, key, silent); C.SkinTabs(self) end
    if UI.OnSkin then UI.OnSkin(function() C.SkinTabs(bar) end) end
    C.SkinTabs(bar)
    return bar
end

-- -- The column strip ----------------------------------------------------------------------------------
-- Its own dark band with a 1 px divider under it, so the labels never read as part of the first row.
function C.ColumnStrip(header)
    local bg = header:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(header)
    bg:SetTexture(0, 0, 0, 0.45)
    local rule = header:CreateTexture(nil, "BORDER")
    rule:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
    rule:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
    rule:SetHeight(1)
    rule:SetTexture(0.55, 0.45, 0.25, 0.7)
    header.bg, header.rule = bg, rule
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

-- Column right edges from the row's right (share, per second, total) and their widths.
C.COL_SHARE, C.COL_RATE = 4, 46
C.W_SHARE, C.W_RATE, C.W_TOTAL = 40, 40, 64
function C.TotalRight(showRate) return showRate and (C.COL_RATE + C.W_RATE + 4) or C.COL_RATE end

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
