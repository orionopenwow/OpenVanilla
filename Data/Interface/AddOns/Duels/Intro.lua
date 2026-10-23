--[[
    Intro.lua  (Duels)
    A first-visit guide to Duels, like the leveling realm's welcome: five short pages, once per account
    (DuelsIntro.seen), a few seconds after arriving; "/duels intro" shows it again.
    Lua 5.0 rules: no #, no %, this/arg1 in scripts.
]]--

local W = WenillaCore
local UI = W.UI
local D = Duels

DuelsIntro = DuelsIntro or {}

local I = {}
D.Intro = I
I.PAGES = {
    { title = "Welcome to Duels", icon = "Interface\\Icons\\Ability_Dualwield",
      text = "You're in Gurubashi Arena, the hangout: everyone waits, chats and spars here. You're level 60, geared, with your class's abilities on your bars. Nobody can attack you here unless you agree to a /duel." },
    { title = "Fight", icon = "Interface\\Icons\\INV_Sword_27",
      text = "Open the Duels window (the Duels button, or /duels). Duel now for the ladder, Practice duel to warm up, or 2v2 and 3v3 with friends or strangers. When a match pops you go to a private copy of the arena: best of three rounds, then back here." },
    { title = "Your gear", icon = "Interface\\Icons\\INV_Chest_Plate04",
      text = "The ARMORY tab on the left edge of the screen changes your gear piece by piece, puts on a whole kit, saves loadouts, and shares them as a code. Every transmog look is unlocked too." },
    { title = "Watch and bet", icon = "Interface\\Icons\\INV_Misc_Coin_02",
      text = "Watch a fight from the stands, unseen. Bet Duel Gold on it before round one, or stake gold on your own rated duel. Duel Gold is earned, never bought: 100 to start, more for every rated win." },
    { title = "Bring friends", icon = "Interface\\Icons\\INV_Letter_15",
      text = "Invite a friend gives you a link. Whoever opens it plays free in the browser and lands in your party here, ready for 2v2 or a practice duel. Host a server makes your own duel world with your rules and its own ladder. Have fun!" },
}

local win
function I.Build()
    if win then return win end
    win = UI.Window("DuelsIntroFrame", { width = 380, height = 220, title = "Duels", skin = true,
        icon = "Interface\\Icons\\Ability_Dualwield", point = { "CENTER", UIParent, "CENTER", 0, 100 } })
    win:Hide()
    win.icon = UI.IconBox(win, 44)
    win.icon:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -36)
    win.head = UI.Label(win, 14, UI.ACCENT)
    win.head:SetPoint("TOPLEFT", win.icon, "TOPRIGHT", 12, -2)
    win.text = UI.Label(win, 11, UI.WHITE)
    win.text:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -90)
    win.text:SetWidth(348)
    if win.text.SetJustifyH then win.text:SetJustifyH("LEFT") end
    win.dots = UI.Label(win, 10, UI.MUTED)
    win.dots:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 16, 14)
    win.back = UI.Button(win, "Back", 80, 22, function() I.Show(I.page - 1) end)
    win.back:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -100, 10)
    win.next = UI.Button(win, "Next", 84, 22, function()
        if I.page >= table.getn(I.PAGES) then win:Hide() else I.Show(I.page + 1) end
    end)
    win.next:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -12, 10)
    win:SetScript("OnHide", function() DuelsIntro.seen = 1 end)
    return win
end

function I.Show(n)
    I.Build()
    local count = table.getn(I.PAGES)
    n = math.max(1, math.min(count, n or 1))
    I.page = n
    local p = I.PAGES[n]
    win.icon.icon:SetTexture(p.icon)
    win.head:SetText(p.title)
    win.text:SetText(p.text)
    win.dots:SetText(n .. " of " .. count)
    if n > 1 then win.back:Show() else win.back:Hide() end
    win.next:SetText(n == count and "Let's go" or "Next")
    win:Show()
end

-- once per account, a few seconds after the Duels realm says hello
local f = CreateFrame("Frame")
f:SetScript("OnUpdate", function()
    if DuelsIntro.seen or not D.on then this.t = nil return end
    this.t = (this.t or 0) + arg1
    if this.t > 4 and not (win and win:IsShown()) then I.Show(1); this:Hide() end
end)
