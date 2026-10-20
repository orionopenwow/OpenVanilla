--[[
    Welcome.lua  (WenillaCore)
    A small welcome, once per account: a few seconds after the first time you enter the world it
    says what to know on day one (World chat and its Discord link, the bug button, the Discord).
    "Got it" closes it for good (WenillaCore_Config.welcomed); /welcome shows it again.

    Lua 5.0 rules (1.12.1 client): no '#', no '%', handlers read this/event/arg1.
]]--

local W = WenillaCore
local UI = W.UI
local Wl = {}
W.Welcome = Wl

Wl.DELAY = 6                         -- seconds after entering the world
Wl.DISCORD = "discord.gg/r6nj5p8U4"  -- launcher/defaults.json "discord"
Wl.LINES = {
    "You're in |cffffd100World chat|r automatically. It is linked to our Discord: type |cffffd100/world|r or open the World tab.",
    "Found something broken? Click the blue |cff6fb6ffbug button|r by the chat or type |cffffd100/bug|r.",
    "Join the community on Discord: |cff7289da" .. Wl.DISCORD .. "|r",
    "Want a break? Click |cffe9c46aHerald|r (the eagle eye by the minimap) and he plays your character while you watch.",
}

local win

local function build()
    if win then return win end
    win = UI.Window("WenillaCore_Welcome", { width = 340, height = 280, title = "Welcome to Open Vanilla", strata = "DIALOG",
        point = { "CENTER", UIParent, "CENTER", 0, 80 }, skin = true })
    if UISpecialFrames then table.insert(UISpecialFrames, "WenillaCore_Welcome") end
    win:Hide()
    win.lines = {}
    local y = -34
    for i, text in ipairs(Wl.LINES) do
        local l = UI.Label(win, 11, { 0.92, 0.92, 0.95 })
        l:SetPoint("TOPLEFT", win, "TOPLEFT", 16, y)
        l:SetWidth(308)
        if l.SetJustifyH then l:SetJustifyH("LEFT") end
        l:SetText(text)
        win.lines[i] = l
        y = y - 50
    end
    win.ok = UI.Button(win, "Got it", 100, 22, function() Wl.Close() end)
    win.ok:SetPoint("BOTTOM", win, "BOTTOM", 0, 12)
    return win
end

function Wl.Show()
    if not (UI and UI.Window) then return false end
    build():Show()
    return true
end

function Wl.Close()
    if WenillaCore_Config then WenillaCore_Config.welcomed = true end
    if win then win:Hide() end
end

function Wl.Seen() return WenillaCore_Config and WenillaCore_Config.welcomed and true or false end

-- first time in the world on this account: show it after a short pause
local ev = CreateFrame("Frame", "WenillaCore_WelcomeEvents")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:SetScript("OnEvent", function()
    if Wl.asked or Wl.Seen() then return end
    Wl.asked = true
    Wl.at = GetTime() + Wl.DELAY
end)
-- the first-time setup window (Setup.lua) comes first: the welcome waits until it is closed or answered
local function setupOpen()
    local S = W.Setup
    if S and S.window then return S.window:IsShown() and true or false end      -- shown: wait; closed either way: our turn
    local c = WenillaCore_Config                                                -- not built yet: wait while it is still to come
    return c and type(c.setup) == "table" and not c.setup.done and not W.isVanillaMode and (Wl.waited or 0) < 60
end
ev:SetScript("OnUpdate", function()
    if Wl.at and GetTime() >= Wl.at then
        if setupOpen() then Wl.waited = (Wl.waited or 0) + 2; Wl.at = GetTime() + 2 return end
        Wl.at = nil
        if not Wl.Seen() then Wl.Show() end
    end
end)

SLASH_WNLWELCOME1 = "/welcome"
SlashCmdList["WNLWELCOME"] = function() Wl.Show() end
