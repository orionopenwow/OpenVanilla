--[[
    Plates.lua  -  Visage
    Cleaner nameplates: a dark-cased health bar that ends in a grey bevelled cap holding the
    level (coloured by difficulty; a skull for bosses), names coloured by reaction, a click area
    (1.12 plates take no clicks: left-click targets, right-click targets and opens the unit menu),
    and your target's debuffs above it with type-coloured borders.
    Debuff timers come from the server ("VS" packets); without telemetry the icons show
    without countdowns, because the 1.12 client does not know debuff durations.

    Placement: the engine hangs each plate from its TOP centre at the unit's head point plus
    2/3 yd, so the stock bar sits ~25 px below that point, over the model. We re-anchor the bar
    (and the name and raid icon with it) so the pill sits `lift` px ABOVE that point, stack
    plates whose pills still collide (nearer = lower on screen keeps its spot), dim the others
    while you have a target, and hide the plates of untargeted units while you are out of combat
    (they appear when you target one or a fight starts; "Hide idle plates" turns that off, and
    then full-health bars go slim out of combat instead).

    VS packet: "<unitName>;<iconName>,<remainingMs>;..."
]]--

local W = WenillaCore
local UI = W.UI
local ID = "Plates"

Visage = Visage or {}
local P = Visage
P.timers = {}    -- unit name -> { [iconName lower] = expiresAt }

local DEBUFF_COLORS = {
    Magic = { 0.20, 0.60, 1.00 }, Curse = { 0.60, 0.00, 1.00 }, Disease = { 0.60, 0.40, 0.00 },
    Poison = { 0.00, 0.60, 0.00 }, none = { 0.80, 0.00, 0.00 },
}
local MAX_DEBUFFS = 4
local CAP_WIDTH = 26
local SKULL = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull"

-- driver frame: shown = Visage active
local driver = CreateFrame("Frame", "Visage_Frame", UIParent)

local function iconKey(path)
    local _, _, base = string.find(string.lower(path or ""), "([^\\]+)$")
    return base
end

-- -- Colours -------------------------------------------------------------------------------
-- W.Palette (Essentials) swaps in colour-blind friendly colours; these are the stock ones.

local function greenRange(pl)
    if pl <= 5 then return 5 end
    if pl <= 39 then return math.floor(pl / 10) + 5 end
    return math.floor(pl / 5) + 1
end

-- 1.12's difficulty bands (GetDifficultyColor): red, orange, yellow, green, grey.
function P.DifficultyColor(level)
    if W.Palette and W.Palette.Difficulty then return W.Palette.Difficulty(level) end
    level = tonumber(level)
    if not level then return 1, 0.1, 0.1 end
    local d = level - (UnitLevel("player") or 1)
    if d >= 5 then return 1, 0.1, 0.1 end
    if d >= 3 then return 1, 0.5, 0.25 end
    if d >= -2 then return 1, 1, 0 end
    if -d <= greenRange(UnitLevel("player") or 1) then return 0.25, 0.75, 0.25 end
    return 0.5, 0.5, 0.5
end

-- The engine paints the health bar by reaction: red hostile, yellow neutral, green friendly
-- NPC, blue friendly player.
function P.Reaction(plate)
    local hb = W.Plates.Parts(plate).health
    if not hb then return "hostile" end
    local r, g, b = hb:GetStatusBarColor()
    r, g, b = r or 1, g or 0, b or 0
    if b > 0.8 and r < 0.3 then return "player" end
    if r > 0.8 and g > 0.8 then return "neutral" end
    if g > 0.8 and r < 0.3 then return "friendly" end
    return "hostile"
end

local NAME_COLORS = {
    hostile = { 1, 0.35, 0.30 }, neutral = { 1, 0.90, 0.30 }, friendly = { 0.40, 1, 0.40 }, player = { 0.55, 0.75, 1 },
}
function P.ReactionColor(kind)
    if W.Palette and W.Palette.Reaction then return W.Palette.Reaction(kind) end
    local c = NAME_COLORS[kind] or NAME_COLORS.hostile
    return c[1], c[2], c[3]
end

-- -- Targeting a plate ---------------------------------------------------------------------

local function healthMatches(plate)
    local hb = W.Plates.Parts(plate).health
    if not hb then return true end
    local _, max = hb:GetMinMaxValues()
    local hp, hpmax = UnitHealth("target"), UnitHealthMax("target")
    if not (max and max > 0 and hpmax and hpmax > 0) then return true end
    return math.abs(hb:GetValue() / max - hp / hpmax) < 0.02
end

local function isTargetOf(plate, name)
    return UnitExists("target") and UnitName("target") == name and healthMatches(plate)
end

-- Target the unit a plate belongs to: by exact name, and when several share the name, Tab
-- through enemies to the one whose health matches the plate.
function P.TargetPlate(plate)
    local name = W.Plates.Name(plate)
    if not name or name == "" then return false end
    if isTargetOf(plate, name) then return true end
    if TargetByName then TargetByName(name, 1) end
    if isTargetOf(plate, name) then return true end
    if UnitExists("target") and UnitName("target") == name and TargetNearestEnemy
        and UnitCanAttack("player", "target") then
        for _ = 1, 8 do
            TargetNearestEnemy()
            if isTargetOf(plate, name) then return true end
        end
        if TargetByName then TargetByName(name, 1) end
    end
    return UnitExists("target") and UnitName("target") == name
end

-- -- Level cap, skull, name ----------------------------------------------------------------

local function updateCap(plate)
    local v = plate.visage
    if not v then return end
    local parts = W.Plates.Parts(plate)
    local bossShown = parts.boss and parts.boss:IsShown()
    local text = parts.level and parts.level:GetText()
    if bossShown then
        v.capText:SetText("")
        v.skull:Show()
    else
        v.skull:Hide()
        v.capText:SetText(text or "")
        if W:Setting(ID, "levelDifficulty", true) then
            v.capText:SetTextColor(P.DifficultyColor(text))
        else
            v.capText:SetTextColor(1, 0.82, 0)        -- the stock gold-yellow
        end
    end
    -- the stock level number and skull stay hidden while ours show (the engine shows and
    -- hides them itself, so alpha, not Hide)
    if parts.level and parts.level.SetAlpha then parts.level:SetAlpha(0) end
    if parts.boss and parts.boss.SetAlpha then parts.boss:SetAlpha(0) end
    if parts.name then
        if v.styled and W:Setting(ID, "colorNames", true) then
            parts.name:SetTextColor(P.ReactionColor(P.Reaction(plate)))
        else
            parts.name:SetTextColor(1, 1, 1)
        end
    end
end

-- -- Restyling a plate ---------------------------------------------------------------------

-- The frame art: ours (Plate_Frame, 128x16), else the client's own Nameplate-Border; both tinted
-- a dark charcoal grey (the art alone read as pale, flat silver over grass and snow).
-- Coordinates in art pixels: the three slices' x edges, the bar well's top and height, the level
-- box's x range and the box's top/bottom overhang past the well.
P.FRAME_OURS = { art = "Plate_Frame", w = 128, texH = 16, h = 16, y0 = 0, x = { 0, 8, 96, 128 },
    wellL = 3, wellTop = 3, wellH = 10, box = { 99, 125 }, boxOver = 1, tint = { 0.50, 0.51, 0.56 } }
P.FRAME_STOCK = { file = "Interface\\Tooltips\\Nameplate-Border", w = 128, texH = 32, h = 16, y0 = 16,
    x = { 0, 6, 104, 128 }, wellL = 4, wellTop = 3, wellH = 8, box = { 107, 126 }, boxOver = 1,
    tint = { 0.45, 0.46, 0.51 } }

-- Lay the frame round the bar at the bar's current height (it changes with the window size and
-- the slim bars); only re-anchors when that height changes.
local function layFrame(v, hb)
    local bh = hb:GetHeight() or 0
    if bh <= 0 then bh = v.frameArt.wellH end
    if v.frameH == bh then return end
    v.frameH = bh
    local a = v.frameArt
    local sc = bh / a.wellH
    local top, bot = a.wellTop * sc, (a.h - a.wellTop - a.wellH) * sc
    local x = a.x
    local wellL = a.wellL                             -- art x where the bar well starts
    local L, M, R = v.frame[1], v.frame[2], v.frame[3]
    local function tc(t, x0, x1)
        t:SetTexCoord(x0 / a.w, x1 / a.w, a.y0 / a.texH, (a.y0 + a.h) / a.texH)
    end
    tc(L, x[1], x[2]); tc(M, x[2], x[3]); tc(R, x[3], x[4])
    L:ClearAllPoints(); M:ClearAllPoints(); R:ClearAllPoints()
    L:SetPoint("TOPLEFT", hb, "TOPLEFT", -wellL * sc, top)
    L:SetPoint("BOTTOMRIGHT", hb, "BOTTOMLEFT", (x[2] - wellL) * sc, -bot)
    M:SetPoint("TOPLEFT", L, "TOPRIGHT", 0, 0)
    M:SetPoint("BOTTOMRIGHT", hb, "BOTTOMRIGHT", 0, -bot)
    R:SetPoint("TOPLEFT", hb, "TOPRIGHT", 0, top)
    R:SetPoint("BOTTOMRIGHT", hb, "BOTTOMRIGHT", (x[4] - x[3]) * sc, -bot)
    v.case:ClearAllPoints()
    v.case:SetPoint("TOPLEFT", L, "TOPLEFT", 0, 0)
    v.case:SetPoint("BOTTOMRIGHT", R, "BOTTOMRIGHT", 0, 0)
    local cap = v.cap
    cap:ClearAllPoints()
    cap:SetPoint("TOPLEFT", hb, "TOPRIGHT", (a.box[1] - x[3]) * sc, a.boxOver * sc)
    cap:SetPoint("BOTTOMRIGHT", hb, "BOTTOMRIGHT", (a.box[2] - x[3]) * sc, -a.boxOver * sc)
    -- the number keeps inside its box on slim bars
    -- the number fills its box and has a drop shadow, not an outline (an outline smudged it)
    if v.capText then
        UI.Font(v.capText, math.max(8, math.min(12, math.floor(bh * 1.05 + 0.5))))
        v.capText:SetShadowColor(0, 0, 0, 1)
        v.capText:SetShadowOffset(1, -1)
    end
end
P.LayFrame = layFrame

local function style(plate)
    if plate.visage then return end
    local parts = W.Plates.Parts(plate)
    local hb = parts.health
    if not hb then return end
    local v = {}
    plate.visage = v

    -- The frame: the stock 1.12 nameplate border's shape (soft corners, a rim round the bar, a
    -- box for the level at the right end) in grey metal, drawn ABOVE the bar so its rounded inner
    -- lip covers the bar's square ends (1.12 has no masks). Cut in three: fixed ends, stretched
    -- middle, all scaled to the bar's height (layFrame).
    local case = CreateFrame("Frame", nil, plate)
    case:SetFrameLevel(hb:GetFrameLevel() > 0 and hb:GetFrameLevel() - 1 or 0)
    v.case = case
    local well = case:CreateTexture(nil, "BACKGROUND")          -- dark behind the empty bar
    well:SetAllPoints(hb)
    well:SetTexture(0.02, 0.02, 0.03, 0.9)
    v.well = well

    local rim = CreateFrame("Frame", nil, case)
    rim:SetAllPoints(case)
    rim:SetFrameLevel(hb:GetFrameLevel() + 2)
    v.rim = rim
    v.frame = {}
    for i = 1, 3 do v.frame[i] = rim:CreateTexture(nil, "ARTWORK") end
    if W:Art(v.frame[1], P.FRAME_OURS.art, nil) then
        v.frameArt = P.FRAME_OURS
        W:Art(v.frame[2], P.FRAME_OURS.art, nil); W:Art(v.frame[3], P.FRAME_OURS.art, nil)
        local c = P.FRAME_OURS.tint
        for i = 1, 3 do v.frame[i]:SetVertexColor(c[1], c[2], c[3]) end
    else
        v.frameArt = P.FRAME_STOCK
        local c = P.FRAME_STOCK.tint
        for i = 1, 3 do
            v.frame[i]:SetTexture(P.FRAME_STOCK.file)
            v.frame[i]:SetVertexColor(c[1], c[2], c[3])
        end
    end

    -- the level sits in the frame's grey box at the right end
    local cap = CreateFrame("Frame", nil, plate)
    cap:SetFrameLevel(hb:GetFrameLevel() + 3)
    local capTex = cap:CreateTexture(nil, "BACKGROUND")          -- kept for skins; the box is art
    capTex:Hide()
    v.capTex = capTex
    local capText = cap:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    UI.Font(capText, 10)
    capText:SetPoint("CENTER", cap, "CENTER", 1, 0)
    capText:SetJustifyH("CENTER")
    capText:SetShadowOffset(1, -1)
    capText:SetShadowColor(0, 0, 0, 1)
    v.capText = capText
    local skull = cap:CreateTexture(nil, "OVERLAY")
    skull:SetWidth(12)
    skull:SetHeight(12)
    skull:SetPoint("CENTER", cap, "CENTER", 0, 0)
    skull:SetTexture(SKULL)
    skull:Hide()
    v.skull = skull
    v.cap = cap
    layFrame(v, hb)
    hb:SetStatusBarTexture(UI.BAR)

    -- click area over the name, the bar and the cap
    local click = CreateFrame("Button", nil, plate)
    click:SetPoint("TOPLEFT", case, "TOPLEFT", 0, 14)
    click:SetPoint("BOTTOMRIGHT", cap, "BOTTOMRIGHT", 0, 0)
    click:SetFrameLevel(rim:GetFrameLevel() + 1)
    click:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    click:SetScript("OnClick", function()
        if not P.TargetPlate(plate) then return end
        if arg1 == "RightButton" and W.UnitMenu then W.UnitMenu.Open("target") end
    end)
    v.click = click

    updateCap(plate)

    local oldOnShow = plate:GetScript("OnShow")
    plate:SetScript("OnShow", function()
        if oldOnShow then oldOnShow() end
        updateCap(plate)
    end)

    -- debuff row
    v.debuffs = {}
    for i = 1, MAX_DEBUFFS do
        local d = CreateFrame("Frame", nil, plate)
        d:SetWidth(18)
        d:SetHeight(18)
        d:SetPoint("BOTTOMLEFT", hb, "TOPLEFT", (i - 1) * 21, 18)  -- above the name
        local bg = d:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(d)
        bg:SetTexture(0, 0, 0, 1)
        d.border = bg
        local ic = d:CreateTexture(nil, "ARTWORK")
        ic:SetPoint("TOPLEFT", d, "TOPLEFT", 1, -1)
        ic:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", -1, 1)
        ic:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        d.icon = ic
        local t = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        UI.Font(t, 9, "OUTLINE")
        t:SetPoint("BOTTOM", d, "BOTTOM", 0, -1)
        d.timer = t
        d:Hide()
        v.debuffs[i] = d
    end
    v.borderTex = parts.border
    v.glowTex = parts.glow
    v.baseLevel = plate:GetFrameLevel() or 1
    v.stock = {}      -- the engine's own anchors, per part, restored when placement is off
    v.nudge, v.nudgeTarget = 0, 0
end

-- -- Placement: lift above the head, stacking, focus, compact -------------------------------
-- The engine owns the plate frame: it seats the plate's TOP centre on the projected head point
-- + 2/3 yd every frame and solves plate-vs-plate overlap on that frame's rect (benilla-app
-- vplates.rs, smart_rect.rs). The bar, name and raid icon anchors are written only when the
-- window changes, so an addon's re-anchor sticks; we re-check them each tick and re-apply.
-- The engine sets the plate's alpha to 1 for your target and 178/255 for the rest (only when
-- that changes), so `GetAlpha() == 1` with a target is the target's plate.

local LIFT_DEFAULT = 8                 -- px between the head point (+2/3 yd) and the bar bottom
local PILL_PAD = 4                     -- the case reaches 4 px past the bar on each side
local PILL_DX = -(CAP_WIDTH - 2) / 2   -- bar offset that centres bar + cap on the plate
local NAME_GAP = 4                     -- name bottom above the bar top
local NAME_H = 13
local STACK_GAP = 1
local MAX_NUDGE = 60                   -- never push a plate more than this far up
local STICKY = 3                       -- a stacked plate needs a clear 3 px lead to swap places
local SMOOTH = 10                      -- ease rate (1/s): nudges glide instead of jumping
local ENGINE_DIM = 178 / 255           -- what the engine dims non-target plates to
local FADE_ALPHA = 0.6
local TARGET_BOOST = 20                -- frame levels the target's plate is raised by
local COMPACT = 0.6                    -- compact bar height, a fraction of the stock height

function P.Lift() return tonumber(W:Setting(ID, "lift", LIFT_DEFAULT)) or LIFT_DEFAULT end
local function raised(v) return v.styled and W:Setting(ID, "liftPlates", true) and true or false end

local function readPoint(r)
    if not (r and r.GetPoint) then return nil end
    local a, rel, b, x, y = r:GetPoint(1)
    if not a then return nil end
    return { a, rel, b, x or 0, y or 0 }
end

-- Anchor `region` (part `key`) at the given point unless it is already there; whatever anchor
-- it had that is not ours is the engine's, remembered for the way back.
local function anchor(v, key, region, a, rel, b, x, y)
    if not (region and region.SetPoint) then return end
    local cur = readPoint(region)
    if cur and cur[1] == a and cur[2] == rel and cur[3] == b
        and math.abs(cur[4] - x) < 0.01 and math.abs(cur[5] - y) < 0.01
        and region:GetNumPoints() == 1 then
        return
    end
    if not (cur and cur[1] == a and cur[2] == rel and cur[3] == b) then v.stock[key] = cur end
    region:ClearAllPoints()
    region:SetPoint(a, rel, b, x, y)
end

local function unanchor(v, key, region)
    if not (region and region.ClearAllPoints) then return end
    local p = v.stock[key]
    region:ClearAllPoints()
    if p then region:SetPoint(p[1], p[2], p[3], p[4], p[5]) end
end

-- Bar height: the engine's (re-read whenever it is not what we last set), or the slim one.
local function sizeBar(v, hb)
    local h = hb:GetHeight() or 0
    if not v.setH or math.abs(h - v.setH) > 0.01 then v.stockH = h end
    local want = v.stockH or 0
    if want <= 0 then v.setH = h return end
    if v.compact and raised(v) then want = math.max(4, math.floor(want * COMPACT + 0.5)) end
    if math.abs(want - h) > 0.01 then hb:SetHeight(want) end
    v.setH = want
    if v.frame then layFrame(v, hb) end     -- the frame follows the bar's height
end

-- Put a plate's bar, name and raid icon where the settings say.
function P.Place(plate)
    local v = plate.visage
    if not v then return end
    local parts = W.Plates.Parts(plate)
    local hb = parts.health
    if not hb then return end
    if raised(v) then
        local y = math.floor(P.Lift() + (v.nudge or 0) + 0.5)
        anchor(v, "health", hb, "BOTTOM", plate, "TOP", PILL_DX, y)
        anchor(v, "name", parts.name, "BOTTOM", hb, "TOP", -PILL_DX, NAME_GAP)
        anchor(v, "raid", parts.raid, "RIGHT", v.case, "LEFT", -2, 0)
        v.placedY = y
        v.lifted = true
    elseif v.lifted then
        unanchor(v, "health", hb)
        unanchor(v, "name", parts.name)
        unanchor(v, "raid", parts.raid)
        v.lifted, v.placedY = nil, nil
        v.nudge, v.nudgeTarget = 0, 0
    end
    sizeBar(v, hb)
end

-- Target on top, the rest faded; out of combat, untargeted plates hidden (or compact at full
-- health when "hideIdle" is off).
local function focus(plate, hasTarget, targetName, inCombat)
    local v = plate.visage
    local alpha = plate:GetAlpha() or 1
    local on = v.styled
    -- in combat every plate stays at full strength (no fading); then the alpha can't tell the
    -- target apart, so the name does
    local lift = on and inCombat
    local isTarget = hasTarget and W.Plates.Name(plate) == targetName and (lift or v.lifted or alpha >= 0.99)
    v.isTarget = isTarget and true or nil
    local level = v.baseLevel + ((on and isTarget) and TARGET_BOOST or 0)
    if plate:GetFrameLevel() ~= level then plate:SetFrameLevel(level) end
    if lift then
        if alpha < 0.999 then plate:SetAlpha(1) end
        v.lifted, v.faded = true, nil
    elseif v.lifted then
        -- the fight is over: the engine's dim for the untargeted ones, then the usual fading
        v.lifted = nil
        plate:SetAlpha((hasTarget and not isTarget) and ENGINE_DIM or 1)
        alpha = plate:GetAlpha() or 1
    end
    if not lift and on and hasTarget and not isTarget and W:Setting(ID, "fadeOthers", true) then
        if math.abs(alpha - FADE_ALPHA) > 0.001 then plate:SetAlpha(FADE_ALPHA) end
        v.faded = true
    elseif v.faded then
        -- give the engine's alpha back
        if not hasTarget then plate:SetAlpha(1) elseif not isTarget then plate:SetAlpha(ENGINE_DIM) end
        v.faded = nil
    end
    local hb = W.Plates.Parts(plate).health
    local full = false
    if hb then
        local _, max = hb:GetMinMaxValues()
        full = max and max > 0 and (hb:GetValue() or 0) >= max
    end
    v.compact = on and W:Setting(ID, "compact", true) and full and not isTarget and not inCombat or nil
    -- idle: you are out of combat and this is not your target, so no plate at all; the engine
    -- puts the target's plate back to alpha 1 when you target it, which shows it again
    local idle = on and W:Setting(ID, "hideIdle", true) and not isTarget and not inCombat
    if idle then
        if (plate:GetAlpha() or 1) > 0.001 then plate:SetAlpha(0) end
        if v.click then v.click:Hide() end
        v.idle = true
    elseif v.idle then
        v.idle = nil
        plate:SetAlpha((hasTarget and not isTarget) and ENGINE_DIM or 1)
        if v.click and W:Setting(ID, "clickToTarget", true) then v.click:Show() end
    end
end

-- Collect the visible pills' screen rects and push colliding ones up, lowest on screen first.
local function stack(plates)
    local on = W:Setting(ID, "stacking", true)
    local lift = P.Lift()
    local items = {}
    for i, plate in ipairs(plates) do
        local v = plate.visage
        local placed = false
        if on and v and raised(v) and plate:IsVisible() then
            local top, l, r = plate:GetTop(), plate:GetLeft(), plate:GetRight()
            local hb = W.Plates.Parts(plate).health
            if top and l and r and hb then
                local bw, bh = hb:GetWidth() or 0, hb:GetHeight() or 0
                local w = (bw > 0) and (bw + CAP_WIDTH + 2 + PILL_PAD) or (r - l)
                local base = top + lift - PILL_PAD
                local key = base + (((v.nudgeTarget or 0) > 0.5) and STICKY or 0)
                table.insert(items, { v = v, i = i, cx = (l + r) / 2, w = w, base = base, key = key,
                    h = bh + 2 * PILL_PAD + NAME_GAP + NAME_H })
                placed = true
            end
        end
        if v and not placed then v.nudgeTarget = 0 end
    end
    table.sort(items, function(a, b)
        if a.key ~= b.key then return a.key < b.key end
        return a.i < b.i
    end)
    local done = {}
    for _, it in ipairs(items) do
        local y = it.base
        for _ = 1, table.getn(done) + 1 do
            local moved = false
            for _, d in ipairs(done) do
                if math.abs(it.cx - d.cx) < (it.w + d.w) / 2 and y < d.y + d.h and d.y < y + it.h then
                    y = d.y + d.h + STACK_GAP
                    moved = true
                end
            end
            if not moved then break end
        end
        local nudge = math.min(y - it.base, MAX_NUDGE)
        it.v.nudgeTarget = nudge
        table.insert(done, { cx = it.cx, w = it.w, h = it.h, y = it.base + nudge })
    end
end

-- One placement pass over every plate (the driver runs it every 0.1 s).
function P.Arrange()
    local plates = W.Plates.list
    local hasTarget = UnitExists("target") and true or false
    local targetName = hasTarget and UnitName("target")
    local inCombat = UnitAffectingCombat and UnitAffectingCombat("player") and true or false
    for _, plate in ipairs(plates) do
        if plate.visage then focus(plate, hasTarget, targetName, inCombat) end
    end
    stack(plates)
    for _, plate in ipairs(plates) do
        if plate.visage and plate:IsVisible() then P.Place(plate) end
    end
end

-- Ease each nudge toward its target; re-anchor only when the rounded offset moves.
local function ease(dt)
    for _, plate in ipairs(W.Plates.list) do
        local v = plate.visage
        if v and v.lifted then
            local t, n = v.nudgeTarget or 0, v.nudge or 0
            if n ~= t then
                local d = t - n
                if math.abs(d) < 0.5 then n = t else n = n + d * (1 - math.exp(-dt * SMOOTH)) end
                v.nudge = n
                if math.floor(P.Lift() + n + 0.5) ~= v.placedY then P.Place(plate) end
            end
        end
    end
end

local function applyStyle(plate, on)
    local v = plate.visage
    if not v then return end
    local s = W:Settings(ID)
    local parts = W.Plates.Parts(plate)
    v.styled = on and s.showHealthBar ~= false
    if v.styled then
        v.case:Show()
        v.cap:Show()
        if v.borderTex then v.borderTex:SetAlpha(0) end
        updateCap(plate)
    else
        v.case:Hide()
        v.cap:Hide()
        if v.borderTex then v.borderTex:SetAlpha(1) end
        if parts.level and parts.level.SetAlpha then parts.level:SetAlpha(1) end
        if parts.boss and parts.boss.SetAlpha then parts.boss:SetAlpha(1) end
        if parts.name then parts.name:SetTextColor(1, 1, 1) end
    end
    if on and s.clickToTarget ~= false then v.click:Show() else v.click:Hide() end
    if not on then
        for i = 1, MAX_DEBUFFS do v.debuffs[i]:Hide() end
    end
    if not v.styled then
        -- back to the engine's level and alpha
        if plate:GetFrameLevel() ~= v.baseLevel then plate:SetFrameLevel(v.baseLevel) end
        if v.faded then
            plate:SetAlpha(UnitExists("target") and ENGINE_DIM or 1)
            v.faded = nil
        end
        v.compact, v.isTarget = nil, nil
    end
    P.Place(plate)
end

W.Plates.OnNew(function(plate)
    style(plate)
    applyStyle(plate, W:IsActive(ID))
end)

-- -- Target debuffs ------------------------------------------------------------------------

local function updateDebuffs(plate, isTarget)
    local v = plate.visage
    if not v then return end
    local s = W:Settings(ID)
    local name = W.Plates.Name(plate)
    local timers = name and P.timers[name]
    local now = GetTime()
    for i = 1, MAX_DEBUFFS do
        local d = v.debuffs[i]
        local tex, stacks, kind
        if isTarget and s.showDebuffs ~= false then tex, stacks, kind = UnitDebuff("target", i) end
        if tex then
            d.icon:SetTexture(tex)
            local c = (s.coloredBorders ~= false) and (DEBUFF_COLORS[kind or "none"] or DEBUFF_COLORS.none) or { 0, 0, 0 }
            d.border:SetTexture(c[1], c[2], c[3], 1)
            local exp = timers and timers[iconKey(tex)]
            if exp and exp > now and s.showTimerText ~= false then
                d.timer:SetText(math.ceil(exp - now) .. "s")
            elseif stacks and stacks > 1 then
                d.timer:SetText(stacks)
            else
                d.timer:SetText("")
            end
            d:Show()
        else
            d:Hide()
        end
    end
end

local acc, arrangeAcc = 0, 0
driver:SetScript("OnUpdate", function()
    local dt = arg1 or 0
    arrangeAcc = arrangeAcc + dt
    if arrangeAcc >= 0.1 then
        arrangeAcc = 0
        W.Plates.Scan()
        P.Arrange()
    end
    ease(dt)
    acc = acc + dt
    if acc < 0.2 then return end
    acc = 0
    W.Plates.Scan()
    local targetPlate = UnitExists("target") and UnitCanAttack("player", "target")
        and W.Plates.Find(UnitName("target"), true)
    for _, plate in ipairs(W.Plates.list) do
        if plate:IsVisible() and plate.visage then
            updateDebuffs(plate, plate == targetPlate)
            if plate.visage.styled then updateCap(plate) end
        end
    end
end)

-- -- Server packets (VS) -------------------------------------------------------------------

W:RegisterModule("VS", function(body)
    local recs, n = W.Split(body, ";")
    local unit = recs[1]
    if not unit or unit == "" then return end
    local t, now = {}, GetTime()
    for i = 2, n do
        local f = W.Split(recs[i], ",")
        local ms = tonumber(f[2])
        if f[1] ~= "" and ms then t[string.lower(f[1])] = now + ms / 1000 end
    end
    P.timers[unit] = t
end)

W:RegisterSchema(ID, {
    icon = "Interface\\Icons\\Spell_Nature_NullifyPoison",
    title = "Plates - Nameplates",
    desc = "Clean nameplates: a dark-cased health bar ending in a grey cap with the level, names in their reaction colour, click to target, and timers for your debuffs. V shows enemy plates, Shift-V friendly ones.",
    defaults = { showDebuffs = true, showTimerText = true, coloredBorders = true, showHealthBar = true,
        colorNames = true, clickToTarget = true, combatOnly = false,
        liftPlates = true, lift = LIFT_DEFAULT, stacking = true, fadeOthers = true, compact = true, hideIdle = true,
        levelDifficulty = true },
    options = {
        { key = "showHealthBar", label = "Styled health bar", sub = "The cased health bar with the level in a grey cap (a skull for bosses)." },
        { key = "levelDifficulty", label = "Level in difficulty colours", sub = "Grey, green, yellow, orange or red by how hard the unit is. Off: always gold-yellow." },
        { key = "liftPlates", label = "Plates above heads", sub = "Raise the plate clear of the model instead of hanging over it. Off: the stock spot." },
        { key = "lift", type = "slider", label = "Height above the head", min = 0, max = 30, step = 1, fmt = "%d px" },
        { key = "stacking", label = "Stack overlapping plates", sub = "Plates that would cover each other move up; the nearer one keeps its place." },
        { key = "fadeOthers", label = "Fade other plates", sub = "Out of combat, with a target: its plate stays bright and on top, the rest fade. In combat every plate stays bright." },
        { key = "hideIdle", label = "Hide idle plates", sub = "Out of combat, only your target has a plate; the rest appear when a fight starts." },
        { key = "compact", label = "Slim bars at full health", sub = "With idle plates shown: out of combat, untouched units get a thinner bar." },
        { key = "colorNames", label = "Names in reaction colours", sub = "Red for enemies, yellow for neutral, green for friends." },
        { key = "clickToTarget", label = "Click a plate to target", sub = "Left-click targets it; right-click targets it and opens its menu." },
        { key = "showDebuffs", label = "Your target's debuffs", sub = "Icons for the debuffs on your target above its plate." },
        { key = "showTimerText", label = "Countdown numbers", sub = "Seconds left on each debuff." },
        { key = "coloredBorders", label = "Coloured debuff borders", sub = "Poison green, curse purple, magic blue, disease brown." },
        { key = "combatOnly", label = "Enemy plates only in combat", sub = "Enemy plates appear when a fight starts and hide when it ends. V still works." },
    },
})

W:RegisterAddon(ID, function(active)
    if active then driver:Show() else driver:Hide() end
    for _, plate in ipairs(W.Plates.list) do applyStyle(plate, active) end
end)

SLASH_PLATES1 = "/plates"
SLASH_PLATES2 = "/visage"
SlashCmdList["PLATES"] = function()
    W.Plates.Scan()
    W.Print("Plates: styling " .. table.getn(W.Plates.list) .. " nameplate" .. (table.getn(W.Plates.list) == 1 and "" or "s")
        .. ". V shows enemy nameplates, Shift-V friendly ones.")
end
