--[[
    Window.lua  (Essentials)
    /essentials (/ess): every feature's switch on one page, and an Accessibility page with the
    colour-blind palette (and a live preview of it), the interface scale and the text size.
    The same settings are in the Addons window (/addons > Essentials).

    Lua 5.0 rules (1.12.1 client): no '#', no '%', handlers read this/event/arg1.
]]--

local E = Essentials
local W = WenillaCore
local UI = W.UI
local ID = E.ID

local WIDTH, HEIGHT = 420, 470

local function get(key) return W:Setting(ID, key, E.DEFAULTS[key]) end
local function set(key, v)
    if ClassicPlus_Manager and ClassicPlus_Manager.SetSetting then ClassicPlus_Manager:SetSetting(ID, key, v) end
end

local FEATURES = {
    { "cooldownText", "Cooldown numbers", "Seconds left on action buttons and bag items: red when nearly ready." },
    { "rangeColor", "Range and mana colours", "Buttons turn red when your target is out of range and blue without enough mana." },
    { "reagentCount", "Reagent and ammo counts", "Soul shards, reagents, arrows and bullets left, on the spells that use them." },
    { "autoDismount", "Auto dismount and stand", "Casting while mounted or sitting gets you down or up, then casts." },
    { "macroConditions", "Smarter /cast", "/cast [mod:shift] Frost Nova; [target=mouseover,help] Flash Heal; Smite" },
    { "keybinds", "Keybind mode", "Type /kb, hover a button and press a key to bind it. Escape to finish." },
    { "auraTimers", "Aura timers on your target", "Estimated time left on your target's buffs and debuffs." },
}

local function sliderRow(parent, label, key, min, max, step, fmt)
    local f = CreateFrame("Frame", nil, parent)
    f:SetWidth(WIDTH - 40)
    f:SetHeight(34)
    local l = UI.Label(f, 11, { 1, 1, 1 })
    l:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    l:SetText(label)
    local v = UI.Label(f, 10, UI.ACCENT)
    v:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    v:SetJustifyH("RIGHT")
    local sl = CreateFrame("Slider", "EssentialsSlider_" .. key, f)
    sl:SetOrientation("HORIZONTAL")
    sl:SetWidth(WIDTH - 40)
    sl:SetHeight(10)
    sl:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 2)
    local track = sl:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("LEFT", sl, "LEFT", 0, 0)
    track:SetPoint("RIGHT", sl, "RIGHT", 0, 0)
    track:SetHeight(4)
    track:SetTexture(0.16, 0.17, 0.20, 1)
    local thumb = sl:CreateTexture(nil, "OVERLAY")
    thumb:SetWidth(12)
    thumb:SetHeight(12)
    if not W:Art(thumb, "Switch_Knob", nil) then thumb:SetTexture(UI.ACCENT[1], UI.ACCENT[2], UI.ACCENT[3], 1) end
    sl:SetThumbTexture(thumb)
    sl:SetMinMaxValues(min, max)
    if sl.SetValueStep then sl:SetValueStep(step) end
    local function show(x) v:SetText(string.format(fmt, x)) end
    sl:SetScript("OnValueChanged", function()
        local x = math.floor(sl:GetValue() / step + 0.5) * step
        show(x)
        if not f.loading then set(key, x) end
    end)
    function f:Refresh()
        f.loading = true
        local x = tonumber(get(key)) or 1
        sl:SetValue(x)
        show(x)
        f.loading = nil
    end
    f.slider = sl
    return f
end

local function build()
    if E.window then return E.window end
    local win = UI.Window("EssentialsFrame", { width = WIDTH, height = HEIGHT, title = "Essentials",
        icon = "Interface\\Icons\\INV_Misc_Gear_01", titleAlign = "LEFT", skin = true })
    win:Hide()
    table.insert(UISpecialFrames, "EssentialsFrame")
    E.window = win

    local pages = {}
    local tabs = UI.Tabs(win, {
        tabs = { { key = "features", label = "Features" }, { key = "access", label = "Accessibility" } },
        onSelect = function(key)
            for k, p in pairs(pages) do if k == key then p:Show() else p:Hide() end end
        end,
        skin = true,
    })
    tabs:SetPoint("TOPLEFT", win, "TOPLEFT", 10, -30)
    win.tabs = tabs
    win.pages = pages

    local function page(key)
        local p = CreateFrame("Frame", nil, win)
        p:SetPoint("TOPLEFT", win, "TOPLEFT", 8, -52)
        p:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -8, 8)
        UI.Skin(p, "inset")
        p.rows = {}
        pages[key] = p
        return p
    end

    -- Features
    local feat = page("features")
    local y = -10
    for _, f in ipairs(FEATURES) do
        local key = f[1]
        local row = UI.SwitchRow(feat, { width = WIDTH - 40, label = f[2], sub = f[3],
            get = function() return get(key) and true or false end,
            set = function(on) set(key, on) end })
        row:SetPoint("TOPLEFT", feat, "TOPLEFT", 12, y)
        y = y - row:GetHeight() - 10
        table.insert(feat.rows, row)
    end

    -- Accessibility
    local acc = page("access")
    local cbRow = UI.SwitchRow(acc, { width = WIDTH - 40, label = "Colour-blind friendly colours",
        sub = "Class, difficulty and reaction colours that stay apart without red and green, in every Classic+ window and on nameplates.",
        get = function() return get("colorBlind") and true or false end,
        set = function(on) set("colorBlind", on) end })
    cbRow:SetPoint("TOPLEFT", acc, "TOPLEFT", 12, -10)
    table.insert(acc.rows, cbRow)

    -- preview: five levels around yours, and the nine classes
    local prev = CreateFrame("Frame", nil, acc)
    prev:SetWidth(WIDTH - 40)
    prev:SetHeight(44)
    prev:SetPoint("TOPLEFT", cbRow, "BOTTOMLEFT", 0, -8)
    local plabel = UI.Label(prev, 10, UI.MUTED)
    plabel:SetPoint("TOPLEFT", prev, "TOPLEFT", 0, 0)
    plabel:SetText("Levels:")
    prev.levels = {}
    for i = 1, 5 do
        local t = UI.Label(prev, 11, nil, "OUTLINE")
        t:SetPoint("LEFT", plabel, "RIGHT", 10 + (i - 1) * 34, 0)
        prev.levels[i] = t
    end
    local clabel = UI.Label(prev, 10, UI.MUTED)
    clabel:SetPoint("TOPLEFT", plabel, "BOTTOMLEFT", 0, -8)
    clabel:SetText("Classes:")
    prev.classes = {}
    local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
    for i, c in ipairs(CLASSES) do
        local t = UI.Label(prev, 9, nil, "OUTLINE")
        t:SetPoint("LEFT", clabel, "RIGHT", 6 + (i - 1) * 36, 0)
        t:SetText(string.sub(c, 1, 1) .. string.lower(string.sub(c, 2, 4)))
        t.class = c
        prev.classes[i] = t
    end
    acc.preview = prev

    local scale = sliderRow(acc, "Interface scale", "uiScale", 0.65, 1.15, 0.05, "%.2f")
    scale:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -14)
    local font = sliderRow(acc, "Text size", "fontScale", 0.8, 1.5, 0.05, "%.2fx")
    font:SetPoint("TOPLEFT", scale, "BOTTOMLEFT", 0, -12)
    acc.sliders = { scale, font }
    local note = UI.Label(acc, 10, UI.MUTED)
    note:SetPoint("TOPLEFT", font, "BOTTOMLEFT", 0, -10)
    note:SetWidth(WIDTH - 40)
    note:SetText("The interface scale changes at once. Text size changes the game's fonts at once; some Classic+ windows follow after a /reload.")
    local reset = UI.Button(acc, "Reset sizes", 110, 20, function()
        set("fontScale", 1)
        set("uiScale", 1)
        E.RenderWindow()
    end)
    reset:SetPoint("TOPLEFT", note, "BOTTOMLEFT", 0, -10)

    tabs:Select("features")
    return win
end

function E.RenderWindow()
    local win = E.window
    if not win then return end
    for _, p in pairs(win.pages) do
        for _, r in ipairs(p.rows) do r:Refresh() end
        for _, sl in ipairs(p.sliders or {}) do sl:Refresh() end
    end
    local prev = win.pages.access.preview
    local pl = UnitLevel("player") or 60
    local levels = { pl - 15, pl - 6, pl, pl + 3, pl + 6 }
    for i, t in ipairs(prev.levels) do
        local lv = math.max(1, levels[i])
        t:SetText(lv)
        t:SetTextColor(W.Palette.Difficulty(lv))
    end
    for _, t in ipairs(prev.classes) do t:SetTextColor(W.Palette.Class(t.class)) end
end

function E.ToggleWindow(tab)
    local win = build()
    if win:IsShown() and not tab then win:Hide() return end
    win:Show()
    if tab then win.tabs:Select(tab) end
    E.RenderWindow()
end

SLASH_ESSENTIALS1 = "/essentials"
SLASH_ESSENTIALS2 = "/ess"
SlashCmdList["ESSENTIALS"] = function(msg)
    msg = string.lower(W.Trim(msg or ""))
    if msg == "access" or msg == "accessibility" then E.ToggleWindow("access") return end
    E.ToggleWindow()
end
