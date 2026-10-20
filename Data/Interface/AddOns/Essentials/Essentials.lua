--[[
    Essentials.lua
    The small things every 1.12 player installs a dozen addons for, in one place, each a switch:
        * cooldown numbers on action buttons and bag items          (Actions.lua)
        * out-of-range red and out-of-mana blue action buttons       (Actions.lua)
        * ammo, soul shard and reagent counts on spell buttons       (Actions.lua)
        * auto dismount / stand up when a cast needs it, then retry  (Macros.lua)
        * /cast with [mod:shift] [target=mouseover] [help] ... ;     (Macros.lua)
        * keybind mode: hover a button, press a key (/kb)            (Bindings.lua)
        * buff and debuff timers on your target's auras (estimated)  (Auras.lua, AuraData.lua)
        * accessibility: colour-blind palette, UI scale, font scale  (this file, Window.lua)

    W.Palette (defined here) is what our other addons ask for class, difficulty and reaction
    colours, so the colour-blind palette reaches Plates, the Repack and every window that uses
    UI.CLASS_COLORS.

    Lua 5.0 rules (1.12.1 client): no '#', no '%', handlers read this/event/arg1.
]]--

Essentials = Essentials or {}
local E = Essentials
local W = WenillaCore
local UI = W.UI
local ID = "Essentials"
E.ID = ID

E.DEFAULTS = {
    cooldownText = true, rangeColor = true, reagentCount = true, autoDismount = true,
    macroConditions = true, keybinds = true, auraTimers = true,
    colorBlind = false, uiScale = 1, fontScale = 1,
}

-- Is a feature on? (the addon on, not Pure Vanilla, and the feature's switch on)
function E.On(key)
    if not W:IsActive(ID) then return false end
    local v = W:Setting(ID, key, E.DEFAULTS[key])
    return v and true or false
end

function E.Print(msg) W.Print(msg) end

-- Modules add refreshers: fn(active) runs on every settings change.
E.refreshers = {}
function E.OnRefresh(fn) table.insert(E.refreshers, fn) end

-- -- Palette -----------------------------------------------------------------------------
-- Standard colours are 1.12's; the colour-blind set follows the Okabe-Ito palette, which
-- people with the common red-green deficiencies can tell apart.

local STANDARD = {
    difficulty = { impossible = { 1, 0.1, 0.1 }, hard = { 1, 0.5, 0.25 }, standard = { 1, 1, 0 },
        easy = { 0.25, 0.75, 0.25 }, trivial = { 0.5, 0.5, 0.5 } },
    reaction = { hostile = { 1, 0.35, 0.30 }, neutral = { 1, 0.90, 0.30 }, friendly = { 0.40, 1, 0.40 },
        player = { 0.55, 0.75, 1 } },
    urgency = { soon = { 1, 0.25, 0.20 }, short = { 1, 0.90, 0.25 }, long = { 1, 1, 1 }, hours = { 0.70, 0.70, 0.70 } },
}
local COLORBLIND = {
    difficulty = { impossible = { 0.80, 0.47, 0.65 }, hard = { 0.84, 0.37, 0 }, standard = { 0.94, 0.89, 0.26 },
        easy = { 0.34, 0.71, 0.91 }, trivial = { 0.60, 0.60, 0.60 } },
    reaction = { hostile = { 0.84, 0.37, 0 }, neutral = { 0.94, 0.89, 0.26 }, friendly = { 0.34, 0.71, 0.91 },
        player = { 0.80, 0.80, 1 } },
    urgency = { soon = { 0.84, 0.37, 0 }, short = { 0.94, 0.89, 0.26 }, long = { 1, 1, 1 }, hours = { 0.70, 0.70, 0.70 } },
    class = {
        WARRIOR = { 0.84, 0.37, 0 }, HUNTER = { 0, 0.62, 0.45 }, DRUID = { 0.90, 0.62, 0 },
        ROGUE = { 0.94, 0.89, 0.26 }, MAGE = { 0.34, 0.71, 0.91 }, SHAMAN = { 0, 0.45, 0.70 },
        PALADIN = { 0.80, 0.47, 0.65 }, PRIEST = { 0.92, 0.92, 0.92 }, WARLOCK = { 0.55, 0.45, 0.85 },
    },
}
E.STANDARD, E.COLORBLIND = STANDARD, COLORBLIND

local function cb() return E.On("colorBlind") end
local function set() return cb() and COLORBLIND or STANDARD end
local function rgb(c) return c[1], c[2], c[3] end

local function greenRange(pl)
    if pl <= 5 then return 5 end
    if pl <= 39 then return math.floor(pl / 10) + 5 end
    return math.floor(pl / 5) + 1
end

W.Palette = W.Palette or {}
local Pal = W.Palette

function Pal.ColorBlind() return cb() end

-- 1.12's bands for a level against yours: "impossible" (5+ above or ??), "hard" (3-4),
-- "standard" (2 above to 2 below), "easy" (green), "trivial" (grey).
function Pal.Band(level)
    level = tonumber(level)
    if not level then return "impossible" end
    local pl = UnitLevel("player") or 1
    local d = level - pl
    if d >= 5 then return "impossible" end
    if d >= 3 then return "hard" end
    if d >= -2 then return "standard" end
    if -d <= greenRange(pl) then return "easy" end
    return "trivial"
end
function Pal.Difficulty(level) return rgb(set().difficulty[Pal.Band(level)]) end
function Pal.Reaction(kind) return rgb(set().reaction[kind or "hostile"] or set().reaction.hostile) end
function Pal.Urgency(seconds)
    local u = set().urgency
    if seconds < 5 then return rgb(u.soon) end
    if seconds < 60 then return rgb(u.short) end
    if seconds < 3600 then return rgb(u.long) end
    return rgb(u.hours)
end
function Pal.Class(token)
    local c = UI.CLASS_COLORS[UI.ClassToken(token) or ""]
    if c then return c[1], c[2], c[3] end
    return 0.55, 0.55, 0.58
end
-- A unit's bar colour with the colour-blind palette on (nil otherwise: keep your own).
function Pal.Unit(unit)
    if not cb() or not UnitExists(unit) then return nil end
    if UnitIsPlayer(unit) then
        local _, cls = UnitClass(unit)
        return Pal.Class(cls)
    end
    local r = UnitReaction(unit, "player")
    if r and r <= 3 then return Pal.Reaction("hostile") end
    if r == 4 then return Pal.Reaction("neutral") end
    return Pal.Reaction("friendly")
end

-- The colour-blind palette swaps the suite's class colours in place, so every window that
-- reads UI.CLASS_COLORS follows it.
local savedClass
local function applyClassColors(on)
    if on then
        if not savedClass then
            savedClass = {}
            for k, c in pairs(UI.CLASS_COLORS) do savedClass[k] = { c[1], c[2], c[3] } end
        end
        for k, c in pairs(COLORBLIND.class) do UI.CLASS_COLORS[k] = { c[1], c[2], c[3] } end
    elseif savedClass then
        for k, c in pairs(savedClass) do UI.CLASS_COLORS[k] = { c[1], c[2], c[3] } end
        savedClass = nil
    end
end

-- -- UI scale & font scale ---------------------------------------------------------------
-- The game's own scale stays untouched until you move the slider here.

local function currentGameScale()
    local ok, use = pcall(GetCVar, "useUiScale")
    local ok2, v = pcall(GetCVar, "uiScale")
    if ok and use == "1" and ok2 and tonumber(v) then return tonumber(v) end
    return 1
end

local function round2(v) return math.floor(v * 100 + 0.5) / 100 end

function E.ApplyUIScale(v)
    v = round2(math.max(0.64, math.min(1.15, tonumber(v) or 1)))
    if SetCVar then
        pcall(SetCVar, "useUiScale", "1")
        pcall(SetCVar, "uiScale", tostring(v))
    end
    UIParent:SetScale(v)
    return v
end

local FONTS = {
    "GameFontNormal", "GameFontNormalSmall", "GameFontNormalLarge", "GameFontHighlight",
    "GameFontHighlightSmall", "GameFontHighlightLarge", "GameFontDisable", "GameFontDisableSmall",
    "GameFontGreen", "GameFontRed", "GameFontWhite", "GameFontBlack", "NumberFontNormal",
    "NumberFontNormalSmall", "SystemFont", "GameTooltipText", "GameTooltipTextSmall", "GameTooltipHeaderText",
    "QuestFont", "QuestTitleFont", "ItemTextFontNormal",
}
local baseFonts = {}
E.fontScale = 1

function E.ApplyFontScale(v)
    v = round2(math.max(0.8, math.min(1.5, tonumber(v) or 1)))
    for _, n in ipairs(FONTS) do
        local f = getglobal(n)
        if f and f.GetFont and f.SetFont then
            if not baseFonts[n] then
                local path, size, flags = f:GetFont()
                if path and size then baseFonts[n] = { path, size, flags } end
            end
            local b = baseFonts[n]
            if b then f:SetFont(b[1], b[2] * v, b[3] or "") end
        end
    end
    E.fontScale = v
    return v
end

-- Our own windows build their text through UI.Font: they follow the font scale (windows that
-- are already open pick a new size up after /reload).
do
    local font = UI.Font
    UI.Font = function(fs, size, flags)
        return font(fs, (size or 11) * (E.fontScale or 1), flags)
    end
end

local lastScale, lastFont
local function applyAccessibility(active)
    local s = W:Settings(ID)
    applyClassColors(active and s.colorBlind and true or false)
    -- UI scale: on the first refresh, show the game's own scale unless you set one here
    local scale = tonumber(s.uiScale) or 1
    if lastScale == nil then
        if s.uiScaleOwn and active then E.ApplyUIScale(scale) else s.uiScale = round2(currentGameScale()) end
    elseif active and scale ~= lastScale then
        s.uiScaleOwn = true
        s.uiScale = E.ApplyUIScale(scale)
    end
    lastScale = tonumber(s.uiScale) or 1
    local fscale = tonumber(s.fontScale) or 1
    if active and (fscale ~= 1 or (lastFont and lastFont ~= 1)) then
        E.ApplyFontScale(fscale)
    elseif not active and E.fontScale ~= 1 then
        E.ApplyFontScale(1)
    end
    lastFont = active and fscale or 1
end

-- -- Settings ------------------------------------------------------------------------------

W:RegisterSchema(ID, {
    icon = "Interface\\Icons\\INV_Misc_Gear_01",
    title = "Essentials",
    desc = "Cooldown numbers, range and mana colours, reagent counts, auto dismount, smarter /cast, keybind mode, aura timers and accessibility. /essentials",
    defaults = E.DEFAULTS,
    options = {
        { key = "cooldownText", label = "Cooldown numbers", sub = "Seconds left on action buttons and bag items: red when nearly ready." },
        { key = "rangeColor", label = "Range and mana colours", sub = "Action buttons turn red out of range and blue without enough mana." },
        { key = "reagentCount", label = "Reagent and ammo counts", sub = "How many soul shards, reagents or arrows you have, on the spells that use them." },
        { key = "autoDismount", label = "Auto dismount and stand", sub = "Casting while mounted or sitting gets you down or up, then casts." },
        { key = "macroConditions", label = "Smarter /cast", sub = "/cast [mod:shift] Frost Nova; [target=mouseover,help] Flash Heal; Smite" },
        { key = "keybinds", label = "Keybind mode", sub = "Type /kb, hover a button and press a key to bind it." },
        { key = "auraTimers", label = "Aura timers on your target", sub = "Estimated time left on your target's buffs and debuffs." },
        { key = "colorBlind", label = "Colour-blind friendly colours", sub = "Class, difficulty and reaction colours that stay apart without red and green." },
        { key = "uiScale", type = "slider", label = "Interface scale", min = 0.65, max = 1.15, step = 0.05, fmt = "%.2f" },
        { key = "fontScale", type = "slider", label = "Text size", min = 0.8, max = 1.5, step = 0.05, fmt = "%.2fx" },
    },
})

W:RegisterAddon(ID, function(active)
    applyAccessibility(active)
    for _, fn in ipairs(E.refreshers) do
        local ok, err = pcall(fn, active)
        if not ok then W:Error(ID, err) end
    end
    if E.window and E.window:IsShown() and E.RenderWindow then E.RenderWindow() end
end)

-- Hidden tooltip for reading spell, aura and buff names.
function E.ScanTip()
    if not E.tip then
        E.tip = CreateFrame("GameTooltip", "EssentialsScanTip", nil, "GameTooltipTemplate")
    end
    E.tip:SetOwner(WorldFrame, "ANCHOR_NONE")
    return E.tip
end
function E.TipLine(i, side)
    local fs = getglobal("EssentialsScanTipText" .. (side or "Left") .. i)
    return fs and fs:GetText()
end
