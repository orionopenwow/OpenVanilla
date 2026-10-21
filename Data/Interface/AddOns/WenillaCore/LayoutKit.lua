--[[
    LayoutKit.lua  (WenillaCore)
    Applies UI Studio's Layout.lua (WenillaCore_Layout.frames) to the windows and their pieces.
    Players still move things themselves with /move (Themes' Move Anything) or a window's title bar;
    those positions win, and UI Studio can import them into Layout.lua as the new defaults.

    A frame override is keyed by a path: a global frame name ("Loot_Recap") or a name followed by
    the fields that lead to a piece ("Loot_Recap.title", "Loot_Recap.rows.2.text"); ".@text" is a
    button's own label ("WenillaCore_BugFrame.send.@text"). Fields:
        point  = { "TOPLEFT", "UIParent" | "parent" | "<path>", "TOPLEFT", x, y }
        w, h, scale, alpha, hide
        color  = { r, g, b [, a] }   text colour (FontString) or vertex colour (Texture)
        fill   = { r, g, b, a }      a plain colour texture's colour
        bg, border = { r, g, b, a }  a backdrop's face and edge
        fontSize = n                 a FontString's size (keeps its font and outline)
        font = "Fonts\\ARIALN.TTF"   a FontString's font file (keeps its size and outline)
        art = "Name"                 a Texture shows WenillaCore art (Media\Name.tga / ClassicPlus\Name.blp)
        backdrop = { bg = "Name", edge = "Name", edgeSize = 16, tile = true, tileSize = 16,
                     insets = 4 }    a frame's backdrop from WenillaCore art (UI Studio's 9-slice)
        sticky = true                apply again whenever the addon moves it back (otherwise once)
    UI.Window places a window from its entry as it is made; the rest of every entry is applied as
    soon as the object exists (checked twice a second; cheap: only the paths in Layout.lua are
    looked at). A window the player placed (dragged, or /move) keeps their spot.
    Lua 5.0 rules.
]]--

local W = WenillaCore
local UI = W.UI
local L = {}
W.LayoutKit = L

local strfind, strsub = string.find, string.sub

local function layout() return WenillaCore_Layout or {} end

-- "Name.field.2.text" -> the object, or nil
function L.Resolve(path)
    if type(path) ~= "string" or path == "" then return nil end
    local parts, i = {}, 1
    while true do
        local s, e = strfind(path, ".", i, true)
        if not s then table.insert(parts, strsub(path, i)); break end
        table.insert(parts, strsub(path, i, s - 1))
        i = e + 1
    end
    local o = getglobal(parts[1])
    for k = 2, table.getn(parts) do
        if type(o) ~= "table" then return nil end
        local key = parts[k]
        if key == "@text" then
            o = o.GetFontString and o:GetFontString()       -- a button's own label
        else
            o = o[tonumber(key) or key]
        end
    end
    if type(o) == "table" and o.GetObjectType then return o end
    return nil
end

local function rgba(t, a) return t[1] or 1, t[2] or 1, t[3] or 1, t[4] or a or 1 end

-- a window the player placed (dragged by its title, or with /move): their spot wins
local function playerPlaced(o)
    local name = o.GetName and o:GetName()
    if not name then return false end
    local c = WenillaCore_Config
    if c and c.positions and c.positions[name] then return true end
    local m = ClassicPlus_UI
    if type(m) == "table" and type(m.pos) == "table" and m.pos[name] then return true end
    return false
end
L.PlayerPlaced = playerPlaced

function L.Apply(o, ov, keepPoint)
    if not o or type(ov) ~= "table" then return end
    if ov.w and o.SetWidth then o:SetWidth(ov.w) end
    if ov.h and o.SetHeight then o:SetHeight(ov.h) end
    if ov.point and o.SetPoint and not keepPoint and not playerPlaced(o) then
        local p = ov.point
        local rel = p[2]
        local r
        if rel == nil or rel == "parent" then r = o.GetParent and o:GetParent() or UIParent
        elseif rel == "UIParent" then r = UIParent
        else r = L.Resolve(rel) end
        if r then
            o:ClearAllPoints()
            o:SetPoint(p[1] or "CENTER", r, p[3] or p[1] or "CENTER", p[4] or 0, p[5] or 0)
        end
    end
    if ov.scale and o.SetScale then o:SetScale(ov.scale) end
    if ov.alpha and o.SetAlpha then o:SetAlpha(ov.alpha) end
    if ov.color then
        if o.SetTextColor then o:SetTextColor(rgba(ov.color))
        elseif o.SetVertexColor then o:SetVertexColor(rgba(ov.color)) end
    end
    if ov.fill and o.SetTexture then o:SetTexture(rgba(ov.fill)) end
    if (ov.fontSize or ov.font) and o.SetFont and o.GetFont then
        local font, size, flags = o:GetFont()
        o:SetFont(ov.font or font or UI.FONT, ov.fontSize or size or 12, flags or "")
    end
    if ov.art and o.SetTexture and o.GetObjectType and o:GetObjectType() == "Texture" then
        W:Art(o, ov.art, nil)
    end
    if type(ov.backdrop) == "table" and o.SetBackdrop then
        local b = ov.backdrop
        local root = W.artRoot or W.ART_ROOTS[1]
        local i = b.insets or 0
        o:SetBackdrop({
            bgFile = b.bg and (root .. b.bg) or nil, edgeFile = b.edge and (root .. b.edge) or nil,
            tile = b.tile and true or false, tileSize = b.tileSize or 16, edgeSize = b.edgeSize or 16,
            insets = { left = i, right = i, top = i, bottom = i },
        })
        if not ov.bg and o.SetBackdropColor then o:SetBackdropColor(1, 1, 1, 1) end
        if not ov.border and o.SetBackdropBorderColor then o:SetBackdropBorderColor(1, 1, 1, 1) end
    end
    if ov.bg and o.SetBackdropColor then o:SetBackdropColor(rgba(ov.bg)) end
    if ov.border and o.SetBackdropBorderColor then o:SetBackdropBorderColor(rgba(ov.border)) end
    if ov.hide and o.Hide then o:Hide() end
end

L.applied = setmetatable({}, { __mode = "k" })     -- object -> the override last applied to it
L.placed = setmetatable({}, { __mode = "k" })      -- windows UI.Window already placed

-- a window made by UI.Window: its own entry, now (before the saved position goes on). Applied
-- again once the addon has finished building it (its own SetBackdrop, colours), without the point.
function W:LayoutApply(f, name)
    local ov = name and layout().frames and layout().frames[name]
    if ov then L.Apply(f, ov); L.placed[f] = ov end
end

-- every entry whose object exists and hasn't had it yet (sticky ones every time)
function L.ApplyAll()
    local frames = layout().frames
    if type(frames) == "table" then
        for path, ov in pairs(frames) do
            local o = L.Resolve(path)
            if o and (L.applied[o] ~= ov or ov.sticky) then
                L.Apply(o, ov, L.placed[o] == ov and not ov.sticky)
                L.applied[o] = ov
            end
        end
    end
end
W.LayoutApplyAll = L.ApplyAll

local ticker = CreateFrame("Frame", "WenillaCore_LayoutTicker")
ticker.wait = 0
ticker:SetScript("OnUpdate", function()
    ticker.wait = ticker.wait - (arg1 or 0)
    if ticker.wait > 0 then return end
    ticker.wait = 0.5
    L.ApplyAll()
end)
