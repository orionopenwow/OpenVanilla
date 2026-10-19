--[[
    Setup.lua
    First-time interface setup. A brand-new player starts with a light Classic+ interface (quests,
    chat, bags, loot, mail, the vendor helper, Social and the everyday Essentials) instead of all
    of it at once. A few seconds after they first enter the world, a small window offers three
    choices; nothing changes until they pick one, and every addon stays one click away in /addons.

        /setup      open the window again

    Players who already had Classic+ before this window existed keep everything as it was: they
    are recognised by WenillaCore_Config being there when WenillaCore loads.
    The choice lives in WenillaCore_Config.setup = { done = true|false, preset = key }.
    Lua 5.0 rules (1.12.1 client): no '#', no select(), handlers read this/event/arg1.
]]--

local W = WenillaCore
local UI = W.UI
local S = {}
W.Setup = S

-- Always on: the everyday basics a first session needs.
S.CORE = { "Quests", "Chat", "Bags", "Essentials", "Loot", "Vendor", "Mail", "Social" }

-- Off until chosen, in the order the Recommended / Everything presets add them.
S.RECOMMENDED = { "Talents", "Achievements", "Dungeons", "Casting", "Prices", "Raid", "Guilds" }
S.EXTRA = { "Meters", "Threat", "Plates", "GuildHub", "Persona", "Assistant" }

S.PRESETS = {
    {
        key = "light", label = "Light",
        line = "Just the basics: quests, chat, bags, loot, mail and Social. Add more any time.",
        on = {},
    },
    {
        key = "recommended", label = "Recommended",
        line = "Plus talents, achievements, the dungeon finder, cast bars, prices, raid tools and guilds.",
        on = S.RECOMMENDED,
    },
    {
        key = "everything", label = "Everything",
        line = "Every Classic+ addon, including damage meters, threat and nameplates.",
        on = "all",
    },
}

local function optional()
    local out = {}
    for _, id in ipairs(S.RECOMMENDED) do table.insert(out, id) end
    for _, id in ipairs(S.EXTRA) do table.insert(out, id) end
    return out
end

local function contains(list, id)
    for _, x in ipairs(list) do if x == id then return true end end
    return false
end

-- Switch an addon on or off without the manager's chat line, before or after the world is up.
local function setState(c, id, on)
    on = on and true or false
    c.addons = c.addons or {}
    c.addons[id] = on
    W.addonStates[id] = on
    local s = W:Settings(id)
    if s then s.enabled = on end
end

-- -- Who is new ------------------------------------------------------------------------------

-- WenillaCore_Config is restored just before WenillaCore's ADDON_LOADED. A player who has played
-- with Classic+ before already has one; a brand-new player does not.
S.sawLoad = false
S.wasExisting = nil

local watch = CreateFrame("Frame")
watch:RegisterEvent("ADDON_LOADED")
watch:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" and arg1 == "WenillaCore" and not S.sawLoad then
        S.sawLoad = true
        S.wasExisting = type(WenillaCore_Config) == "table" and WenillaCore_Config.version ~= nil
        watch:UnregisterEvent("ADDON_LOADED")
    end
end)

W:OnConfig(function(c)
    if type(c.setup) == "table" then return end
    -- Not seen loading (an unusual load path): keep everything, as before.
    if not S.sawLoad or S.wasExisting then
        c.setup = { done = true, preset = "existing" }
        return
    end
    c.setup = { done = false, preset = "light" }
    for _, id in ipairs(optional()) do setState(c, id, false) end
end)

-- -- Applying a choice -------------------------------------------------------------------------

function S:Apply(key)
    local c = WenillaCore_Config
    if not c then return end
    local preset
    for _, p in ipairs(S.PRESETS) do if p.key == key then preset = p end end
    if not preset then return end
    for _, id in ipairs(optional()) do
        local on = preset.on == "all" or contains(preset.on, id)
        setState(c, id, on)
    end
    for _, id in ipairs(S.CORE) do setState(c, id, true) end
    c.setup = { done = true, preset = key }
    W:RefreshAll()
    if W.UpdateManagerUI then W:UpdateManagerUI() end
    if UI and UI.Toast then
        UI.Toast({
            title = "Interface ready: " .. preset.label,
            text = "Change any addon in /addons, or run /setup again.",
            icon = "Interface\\Icons\\INV_Misc_Note_01",
            duration = 7,
        })
    else
        W.Print("Interface set to " .. preset.label .. ". Change any addon in /addons, or run /setup again.")
    end
    if S.window then S.window:Hide() end
end

-- -- The window --------------------------------------------------------------------------------

local WIDTH, PAD = 380, 16

function S:Build()
    if S.window then return S.window end
    local f = UI.Window("ClassicPlusSetup", {
        width = WIDTH, height = 300, title = "Set up your interface",
        icon = "Interface\\Icons\\INV_Misc_Note_01", skin = true, strata = "DIALOG",
        onClose = function() S:Later() end,
    })
    f:SetFrameStrata("DIALOG")

    local intro = UI.Label(f, 12, { 0.86, 0.84, 0.78 })
    intro:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -36)
    intro:SetWidth(WIDTH - PAD * 2)
    intro:SetText("Welcome to Open Vanilla. Classic+ comes with a set of addons. Pick how much you want to start with; you can change any of it later.")

    local y = -36 - 56
    f.rows = {}
    for i, p in ipairs(S.PRESETS) do
        local preset = p
        local b = UI.Button(f, preset.label, 110, 24, function() S:Apply(preset.key) end)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)
        local line = UI.Label(f, 11, { 0.70, 0.70, 0.74 })
        line:SetPoint("TOPLEFT", b, "TOPRIGHT", 10, 1)
        line:SetWidth(WIDTH - PAD * 2 - 120)
        line:SetText(preset.line)
        f.rows[i] = { button = b, line = line }
        y = y - 52
    end

    -- Shown only on a first visit with lite textures (the page sets W.liteTextures).
    local note = UI.Label(f, 11, { 0.62, 0.84, 1.00 })
    note:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y + 4)
    note:SetWidth(WIDTH - PAD * 2)
    note:SetText(S.TEXTURE_NOTE)
    f.note = note
    f.baseHeight = -y + 50

    local own = UI.Button(f, "Choose addons myself", 170, 22, function()
        S:Later()
        if ClassicPlus_ToggleManager then ClassicPlus_ToggleManager() end
    end)
    own:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD, 14)

    local hint = UI.Label(f, 10, { 0.55, 0.55, 0.60 })
    hint:SetPoint("LEFT", own, "RIGHT", 10, 0)
    hint:SetWidth(WIDTH - PAD * 2 - 180)
    hint:SetText("/setup opens this again")

    f:SetHeight(f.baseHeight)
    f:Hide()
    S.window = f
    return f
end

-- Closed without a choice: keep the light start, don't ask again on its own.
function S:Later()
    local c = WenillaCore_Config
    if c and type(c.setup) == "table" and not c.setup.done then
        c.setup.done = true
        W.Print("Keeping the light interface. |cffffd100/setup|r or |cffffd100/addons|r adds more any time.")
    end
    if S.window then S.window:Hide() end
end

S.TEXTURE_NOTE = "Faster first visit: world textures are lighter this time so you get in quickly. Full detail loads from your next visit."

function S:Show()
    local f = S:Build()
    if W.liteTextures then
        f.note:Show()
        f:SetHeight(f.baseHeight + 34)
        S.noteShown = true
    else
        f.note:Hide()
        f:SetHeight(f.baseHeight)
    end
    f:Show()
end

-- Players who get no setup window still hear about the lighter textures, once, in chat. The page
-- sets W.liteTextures shortly after entering the world; look for it for half a minute.
local noteWatch = CreateFrame("Frame")
noteWatch:Hide()
noteWatch:SetScript("OnUpdate", function()
    this.left = (this.left or 30) - arg1
    if S.noteShown or this.left <= 0 then this:Hide() return end
    if not W.liteTextures then return end
    local c = WenillaCore_Config
    -- the setup window is about to say it
    if c and type(c.setup) == "table" and not c.setup.done and this.left > 24 then return end
    if S.window and S.window:IsShown() then return end
    S.noteShown = true
    this:Hide()
    W.Print("|cff9fd8ff" .. S.TEXTURE_NOTE .. "|r")
end)

-- First time in the world: wait a moment so the player sees the world before a window.
local DELAY = 4
local timer = CreateFrame("Frame")
timer:Hide()
timer:SetScript("OnUpdate", function()
    this.left = (this.left or DELAY) - arg1
    if this.left > 0 then return end
    this:Hide()
    local c = WenillaCore_Config
    if c and type(c.setup) == "table" and not c.setup.done and not W.isVanillaMode then S:Show() end
end)

local enter = CreateFrame("Frame")
enter:RegisterEvent("PLAYER_ENTERING_WORLD")
enter:SetScript("OnEvent", function()
    local c = WenillaCore_Config
    if c and type(c.setup) == "table" and not c.setup.done then
        timer.left = DELAY
        timer:Show()
    end
    noteWatch.left = 30
    noteWatch:Show()
    enter:UnregisterEvent("PLAYER_ENTERING_WORLD")
end)

SLASH_CLASSICPLUSSETUP1 = "/setup"
SlashCmdList["CLASSICPLUSSETUP"] = function() S:Show() end
