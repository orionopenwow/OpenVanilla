--[[
    Pit.lua  (Duels)
    Everything around the open duels in Gurubashi Arena (realm/mangos/0061-openvanilla-duels-pit.patch,
    OpenVanilla/DuelsPit.h): works with or without the queue.
      the arrival     a title card and a slow turn of the camera over the pit, once a session
      the announcer   streaks, ended streaks, challenges, the brawl and the cup, across the screen
      the cards       who offered you a duel (record, streak, title, the rules), the 3-2-1-FIGHT countdown,
                      and the result (damage, healing, time, your record, Duel Points, Rematch)
      the tracker     the pit by the minimap: the champion, who's fighting, the line (winner stays on),
                      your place, Join the line, the hourly brawl and the Weekly Duel Cup
    Lines: DA DL DO DC DR DP DB DX DU (DuelsPit.h). Commands: .wnl wf pit info | line join|leave | brawl
      | challenge <name> <dp> | cup [leave].
      /duels line   /duels line leave   /duels brawl   /duels cup   /duels challenge <name> <dp>   /duels pit
      /duels arrival on|off   /duels announcer on|off
    Lua 5.0 rules: no #, no %, this/arg1 in scripts.
]]--

local W = WenillaCore
local UI = W.UI
local D = Duels

local P = {}
D.Pit = P

DuelsPitPrefs = DuelsPitPrefs or {}

P.on = nil            -- nil: not known yet; false: the realm has no pit
P.info = nil          -- DP: { wins, losses, streak, best, points, brawls, cups, title, inLine, brawl, cup, brawlAt, cupState, cupIn, line, challengeMax }
P.line = nil          -- DL: { state, champion, streak, challenger, place, champ, names }
P.arrived = false

local getn = table.getn
local ICON = "Interface\\Icons\\Ability_Dualwield"
local CLASS = { ["1"] = "Warrior", ["2"] = "Paladin", ["3"] = "Hunter", ["4"] = "Rogue", ["5"] = "Priest",
                ["7"] = "Shaman", ["8"] = "Mage", ["9"] = "Warlock", ["11"] = "Druid" }
local RACE = { ["1"] = "Human", ["2"] = "Orc", ["3"] = "Dwarf", ["4"] = "Night Elf", ["5"] = "Undead", ["6"] = "Tauren",
               ["7"] = "Gnome", ["8"] = "Troll" }

local function send(args) return Warfront and Warfront.Send and Warfront.Send(args) end
local function say(msg) if D.Say then D.Say(msg) else W.Print(msg) end end
local function pref(key) D.EnsureSaved(); return DuelsPitPrefs[key] ~= false end
local function sound(s) if PlaySound and pref("sound") then PlaySound(s) end end

local function hex(r, g, b) return string.format("%02x%02x%02x", math.floor(r * 255), math.floor(g * 255), math.floor(b * 255)) end
-- a name in its class colour
function P.Colored(name, classId)
    if not name or name == "" then return "?" end
    local r, g, b = UI.ClassColor(tonumber(classId))
    return "|cff" .. hex(r, g, b) .. name .. "|r"
end
local colored = P.Colored

function P.Clock(secs)
    secs = math.max(0, math.floor(tonumber(secs) or 0))
    local m = math.floor(secs / 60)
    local s = secs - m * 60
    return m .. ":" .. (s < 10 and "0" or "") .. s
end
local clock = P.Clock

local function n(x) return tonumber(x) or 0 end
local function commas(v)
    local s = tostring(math.floor(n(v)))
    local out = s
    while true do
        local k
        out, k = string.gsub(out, "^(-?%d+)(%d%d%d)", "%1,%2")
        if k == 0 then break end
    end
    return out
end
P.Commas = commas

-- -- the banner (the announcer) -----------------------------------------------------------------

local banner
local function buildBanner()
    if banner then return banner end
    banner = CreateFrame("Frame", "DuelsPitBanner", UIParent)
    banner:SetWidth(640); banner:SetHeight(90)
    banner:SetPoint("TOP", UIParent, "TOP", 0, -150)
    banner:SetFrameStrata("HIGH")
    banner.glow = banner:CreateTexture(nil, "BACKGROUND")
    banner.glow:SetTexture("Interface\\Tooltips\\UI-Tooltip-Background")
    banner.glow:SetPoint("TOPLEFT", banner, "TOPLEFT", 60, -8)
    banner.glow:SetPoint("BOTTOMRIGHT", banner, "BOTTOMRIGHT", -60, 8)
    banner.glow:SetVertexColor(0, 0, 0, 0.55)
    banner.edge = banner:CreateTexture(nil, "BORDER")
    banner.edge:SetHeight(2)
    banner.edge:SetPoint("BOTTOMLEFT", banner.glow, "BOTTOMLEFT", 0, 0)
    banner.edge:SetPoint("BOTTOMRIGHT", banner.glow, "BOTTOMRIGHT", 0, 0)
    banner.title = banner:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    UI.Font(banner.title, 28, "THICKOUTLINE")
    banner.title:SetPoint("TOP", banner, "TOP", 0, -16)
    banner.sub = banner:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    UI.Font(banner.sub, 13, "OUTLINE")
    banner.sub:SetPoint("TOP", banner.title, "BOTTOM", 0, -6)
    banner:Hide()
    return banner
end

-- title, a line under it, colour { r, g, b }, seconds on screen
function P.Banner(title, sub, color, secs, snd)
    if not pref("announcer") then return end
    local b = buildBanner()
    local c = color or UI.GOLD
    b.title:SetText(title or "")
    b.title:SetTextColor(c[1], c[2], c[3])
    b.sub:SetText(sub or "")
    b.edge:SetTexture(c[1], c[2], c[3], 0.9)
    b.ends = GetTime() + (secs or 4)
    b.born = GetTime()
    b:SetAlpha(1)
    b:Show()
    if snd then sound(snd) end
end

-- -- the countdown -------------------------------------------------------------------------------

local count
local function buildCount()
    if count then return count end
    count = CreateFrame("Frame", "DuelsPitCount", UIParent)
    count:SetWidth(300); count:SetHeight(140)
    count:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    count:SetFrameStrata("HIGH")
    count.num = count:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    UI.Font(count.num, 72, "THICKOUTLINE")
    count.num:SetPoint("CENTER", count, "CENTER", 0, 10)
    count.vs = count:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    UI.Font(count.vs, 13, "OUTLINE")
    count.vs:SetPoint("TOP", count.num, "BOTTOM", 0, -4)
    count:Hide()
    return count
end

function P.Countdown(secs, opponent, kind)
    local c = buildCount()
    c.zero = GetTime() + (tonumber(secs) or 3)
    c.last = math.ceil(tonumber(secs) or 3)
    c.num:SetText(tostring(c.last))
    c.num:SetTextColor(1, 0.82, 0.2)
    c.vs:SetText("vs " .. (opponent or "?") .. ((kind == "line" and "   |cffffd100winner stays on|r") or (kind == "cup" and "   |cffffd100Weekly Duel Cup|r")
        or (kind == "challenge" and "   |cffffd100formal challenge|r") or ""))
    c:SetAlpha(1)
    c:Show()
    if StaticPopup_Hide then StaticPopup_Hide("DUEL_REQUESTED") end
end

-- -- the card (opponent, then result) ----------------------------------------------------------

local card
local function buildCard()
    if card then return card end
    card = UI.Window("DuelsPitCard", { width = 290, height = 170, title = "Duel", skin = true, icon = ICON,
                                       point = { "TOP", UIParent, "TOP", 0, -250 }, strata = "DIALOG" })
    card:Hide()
    card.head = UI.Label(card, 18, UI.WHITE, "OUTLINE")
    card.head:SetPoint("TOPLEFT", card, "TOPLEFT", 14, -32)
    card.who = UI.Label(card, 12, UI.WHITE)
    card.who:SetPoint("TOPLEFT", card.head, "BOTTOMLEFT", 0, -4)
    card.who:SetWidth(262)
    card.l1 = UI.Label(card, 11, UI.WHITE)
    card.l1:SetPoint("TOPLEFT", card.who, "BOTTOMLEFT", 0, -6)
    card.l1:SetWidth(262)
    card.l2 = UI.Label(card, 11, UI.ACCENT)
    card.l2:SetPoint("TOPLEFT", card.l1, "BOTTOMLEFT", 0, -3)
    card.l2:SetWidth(262)
    card.l3 = UI.Label(card, 9, UI.MUTED)
    card.l3:SetPoint("TOPLEFT", card.l2, "BOTTOMLEFT", 0, -5)
    card.l3:SetWidth(262)
    card.a = UI.Button(card, "Rematch", 120, 20, function() P.CardAction(1) end)
    card.a:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 12, 10)
    card.b = UI.Button(card, "Join the line", 120, 20, function() P.CardAction(2) end)
    card.b:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -12, 10)
    return card
end

function P.CardAction(i)
    local c = buildCard()
    local act = i == 1 and c.actA or c.actB
    if act then act() end
end

local function showCard(secs)
    local c = buildCard()
    c.ends = GetTime() + (secs or 15)
    c:SetAlpha(1)
    c:Show()
end

-- DO <name>,<class>,<race>,<level>,<wins>,<losses>,<streak>,<best>,<title>,<dp>,<kind>,<rules>
function P.OnOffer(body)
    local p = W.Split(body, ",")
    local rules = p[12] or ""
    local k = 13
    while p[k] do rules = rules .. "," .. p[k]; k = k + 1 end
    local c = buildCard()
    c.mode = "offer"
    c.opponent = p[1]
    local stake, kind = n(p[10]), p[11] or "pit"
    if c.title then
        c.title:SetText(kind == "challenge" and "Formal challenge" or (kind == "line" and "Winner stays on" or (kind == "cup" and "Weekly Duel Cup" or "Duel")))
    end
    c.head:SetText(colored(p[1], p[2]))
    c.who:SetText((RACE[p[3] or ""] or "") .. " " .. (CLASS[p[2] or ""] or "") .. ", level " .. (p[4] or "60") .. ((p[9] or "") ~= "" and ("   |cffffd100" .. p[9] .. "|r") or ""))
    local rec = n(p[5]) .. " won, " .. n(p[6]) .. " lost"
    if n(p[7]) > 0 then rec = rec .. "   |cff40ff40" .. n(p[7]) .. " in a row|r" end
    if n(p[8]) > 1 then rec = rec .. "   best " .. n(p[8]) end
    c.l1:SetText(rec)
    c.l2:SetText(stake > 0 and (stake .. " DP at stake: the winner takes them") or "")
    c.l3:SetText(rules)
    c.a:Hide(); c.b:Hide()
    showCard(25)
end

-- DR <won>,<opponent>,<class>,<dealt>,<taken>,<healed>,<secs>,<streak>,<wins>,<losses>,<dp>,<counted>,<fled>,<kind>
function P.OnResult(body)
    local p = W.Split(body, ",")
    local won = p[1] == "1"
    local c = buildCard()
    c.mode = "result"
    c.opponent = p[2]
    local kind = p[14] or "pit"
    if c.title then c.title:SetText(kind == "line" and "Winner stays on" or (kind == "cup" and "Weekly Duel Cup" or (kind == "challenge" and "Formal challenge" or "Duel"))) end
    c.head:SetText(won and "|cff40ff40VICTORY|r" or "|cffff4040DEFEAT|r")
    c.who:SetText("vs " .. colored(p[2], p[3]) .. "  ·  " .. clock(p[7]) .. (p[13] == "1" and (won and "  ·  they fled" or "  ·  you fled") or ""))
    c.l1:SetText("Dealt " .. commas(p[4]) .. "   Taken " .. commas(p[5]) .. (n(p[6]) > 0 and ("   Healed " .. commas(p[6])) or ""))
    local dp = n(p[11])
    if p[12] == "1" then
        local line = "Record " .. n(p[9]) .. "-" .. n(p[10])
        if won and n(p[8]) > 1 then line = line .. "   |cff40ff40" .. n(p[8]) .. " in a row|r" end
        if dp > 0 then line = line .. "   |cffffd100+" .. dp .. " DP|r" elseif dp < 0 then line = line .. "   |cffff6040" .. dp .. " DP|r" end
        c.l2:SetText(line)
        c.l3:SetText("")
    else
        c.l2:SetText("|cff9d9d9dNot on the record|r")
        c.l3:SetText("Only wins between different accounts on different networks count, 5 a day against the same opponent.")
    end
    if kind == "pit" or kind == "challenge" then
        c.a:SetText("Rematch")
        c.actA = function() if StartDuel then StartDuel(c.opponent) end; c:Hide() end
        c.a:Show()
    else
        c.a:Hide()
    end
    local inLine = P.info and P.info.inLine
    if P.on and P.info and P.info.line and not inLine and kind ~= "cup" then
        c.b:SetText("Join the line")
        c.actB = function() P.Line(true); c:Hide() end
        c.b:Show()
    else
        c.b:Hide()
    end
    showCard(15)
    if count then count:Hide() end
    sound(won and "LEVELUPSOUND" or "igQuestFailed")
end

-- -- the tracker ---------------------------------------------------------------------------------

local tr
local function buildTracker()
    if tr then return tr end
    tr = CreateFrame("Frame", "DuelsPitTracker", UIParent)
    tr:SetWidth(200); tr:SetHeight(150)
    tr:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -16, -205)
    tr:SetBackdrop(UI.THIN)
    tr:SetBackdropColor(0.05, 0.05, 0.06, 0.82)
    tr:SetBackdropBorderColor(0.55, 0.45, 0.25, 0.9)
    tr:SetMovable(true)
    tr:EnableMouse(true)
    tr.head = UI.Label(tr, 12, UI.ACCENT, "OUTLINE")
    tr.head:SetPoint("TOPLEFT", tr, "TOPLEFT", 8, -7)
    tr.head:SetText("The Pit")
    tr.fold = CreateFrame("Button", nil, tr)
    tr.fold:SetWidth(16); tr.fold:SetHeight(16)
    tr.fold:SetPoint("TOPRIGHT", tr, "TOPRIGHT", -4, -4)
    tr.fold.t = tr.fold:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tr.fold.t:SetPoint("CENTER", tr.fold, "CENTER", 0, 0)
    tr.fold:SetScript("OnClick", function() D.EnsureSaved(); DuelsPitPrefs.folded = not DuelsPitPrefs.folded; P.Paint() end)
    tr.champ = UI.Label(tr, 11, UI.WHITE)
    tr.champ:SetPoint("TOPLEFT", tr.head, "BOTTOMLEFT", 0, -5)
    tr.champ:SetWidth(184)
    tr.now = UI.Label(tr, 11, UI.WHITE)
    tr.now:SetPoint("TOPLEFT", tr.champ, "BOTTOMLEFT", 0, -3)
    tr.now:SetWidth(184)
    tr.list = UI.Label(tr, 10, UI.MUTED)
    tr.list:SetPoint("TOPLEFT", tr.now, "BOTTOMLEFT", 0, -3)
    tr.list:SetWidth(184)
    tr.you = UI.Label(tr, 10, UI.ACCENT)
    tr.you:SetPoint("TOPLEFT", tr.list, "BOTTOMLEFT", 0, -3)
    tr.you:SetWidth(184)
    tr.join = UI.Button(tr, "Join the line", 92, 18, function() P.Line(not (P.info and P.info.inLine)) end)
    tr.join:SetPoint("BOTTOMLEFT", tr, "BOTTOMLEFT", 6, 6)
    tr.brawl = UI.Button(tr, "Brawl", 92, 18, function() P.Brawl() end)
    tr.brawl:SetPoint("BOTTOMRIGHT", tr, "BOTTOMRIGHT", -6, 6)
    tr.cup = UI.Button(tr, "Weekly Cup", 188, 18, function() P.Cup() end)
    tr.cup:SetPoint("BOTTOMLEFT", tr.join, "TOPLEFT", 0, 3)
    tr:SetScript("OnMouseDown", function() if IsShiftKeyDown and IsShiftKeyDown() then this:StartMoving() end end)
    tr:SetScript("OnMouseUp", function() this:StopMovingOrSizing() end)
    tr:Hide()
    return tr
end

local function brawlLeft()
    if not P.info or not P.info.brawlAt then return nil end
    return math.max(0, P.info.brawlAt - GetTime())
end

local function cupLeft()
    if not P.info or not P.info.cupAt then return nil end
    return P.info.cupAt - GetTime()
end

function P.Paint()
    if not (D.on and P.on and P.info) then
        if tr then tr:Hide() end
        return
    end
    local t = buildTracker()
    D.EnsureSaved()
    if DuelsPitPrefs.tracker == false then t:Hide() return end
    t:Show()
    local folded = DuelsPitPrefs.folded
    t.fold.t:SetText(folded and "+" or "-")
    local L = P.line or {}
    local info = P.info
    local champ = L.champion and L.champion ~= "" and L.champion or nil
    local header = "The Pit"
    if L.state == "fight" and champ and L.challenger ~= "" then header = "The Pit  |cffff8040LIVE|r" end
    t.head:SetText(header)
    for _, r in ipairs({ t.champ, t.now, t.list, t.you, t.join, t.brawl, t.cup }) do if folded then r:Hide() else r:Show() end end
    if folded then t:SetHeight(26) return end
    if not info.line then
        t.champ:SetText("Duel anyone in the pit.")
        t.now:SetText("")
        t.list:SetText("")
        t.join:Hide()
    else
        t.champ:SetText(champ and ("Champion: |cffffd100" .. champ .. "|r" .. (n(L.streak) > 0 and ("  (" .. n(L.streak) .. " in a row)") or ""))
                        or "No champion yet: join the line")
        if L.state == "paused" then t.now:SetText("|cff9d9d9dThe line waits for the brawl or the cup|r")
        elseif (L.state == "fight" or L.state == "call") and L.challenger and L.challenger ~= "" then t.now:SetText("|cffff8040" .. (champ or "?") .. "|r vs |cffff8040" .. L.challenger .. "|r")
        elseif L.state == "break" then t.now:SetText("Next fight in a moment")
        elseif champ and getn(L.names or {}) == 0 then t.now:SetText("Waiting for a challenger")
        else t.now:SetText("") end
        local names = L.names or {}
        local shown = {}
        for i = 1, math.min(3, getn(names)) do table.insert(shown, i .. ". " .. names[i]) end
        if getn(names) > 3 then table.insert(shown, "+" .. (getn(names) - 3)) end
        t.list:SetText(getn(shown) > 0 and ("Next: " .. table.concat(shown, "  ")) or "")
        t.join:SetText(info.inLine and "Leave the line" or "Join the line")
        t.join:Show()
    end
    local you
    if L.champ then you = "You hold the pit"
    elseif n(L.place) > 0 then you = "You are " .. (n(L.place) == 1 and "next" or (n(L.place) .. " in line")) end
    local rec = n(info.wins) .. "-" .. n(info.losses) .. "  ·  " .. n(info.points) .. " DP"
    t.you:SetText((you and (you .. "   ") or "") .. "|cffbbbbbb" .. rec .. "|r")
    local bl = brawlLeft()
    if not info.brawlOn then t.brawl:Hide()
    elseif info.brawlNow then t.brawl:SetText("Brawl on!"); t.brawl:Disable()
    else
        t.brawl:Enable()
        t.brawl:SetText((info.brawl and "In: " or "Brawl ") .. clock(bl or 0))
    end
    local cs = info.cupState or "off"
    if cs == "signup" then
        t.cup:SetText(info.cup and ("Cup: signed up (" .. clock(cupLeft() or 0) .. ")") or ("Sign up: Weekly Cup (" .. clock(cupLeft() or 0) .. ")"))
        t.cup:Enable(); t.cup:Show()
    elseif cs == "run" then
        t.cup:SetText("Weekly Duel Cup: on now"); t.cup:Disable(); t.cup:Show()
    else
        t.cup:Hide()
    end
    t:SetHeight(t.cup:IsShown() and 150 or 128)
end

-- -- commands -------------------------------------------------------------------------------------

function P.Line(join)
    if not P.on then return say("No pit on this realm.") end
    send("pit line " .. (join and "join" or "leave"))
    if join then say("You're in the line. Stay in the arena: when your turn comes you're put in the pit and the duel starts by itself.") end
end

function P.Brawl()
    if not P.on then return say("No pit on this realm.") end
    send("pit brawl")
end

function P.Cup(leave)
    if not P.on then return say("No pit on this realm.") end
    send("pit cup" .. (leave and " leave" or ""))
end

function P.Challenge(name, dp)
    if not P.on then return say("No pit on this realm.") end
    name = W.Trim(name or "")
    if name == "" or not tonumber(dp or "") then
        return say("/duels challenge <name> <Duel Points>: a formal challenge, announced to the arena; the winner takes the points.")
    end
    send("pit challenge " .. name .. " " .. math.floor(tonumber(dp)))
end

-- -- what the realm says --------------------------------------------------------------------------

local function after(tag, fn)
    local prev = W.modules and W.modules[tag]
    W:RegisterModule(tag, function(body)
        if prev then prev(body) end
        local ok, err = pcall(fn, body or "")
        if not ok then W.Print("|cffff4040Duels pit:|r " .. tostring(err)) end
    end)
end

local WHY = {
    away = "Come to Gurubashi Arena first.", off = "That's off on this realm.", running = "It has started already.",
    busy = "One of you is in a fight.", name = "Nobody by that name is online.", full = "The cup is full.",
}

-- the camera turns slowly over the pit, once a session
function P.Arrive()
    if P.arrived then return end
    P.arrived = true
    if not pref("arrival") then return end
    P.Banner("GURUBASHI ARENA", "Duel anyone  ·  Winner stays on  ·  The brawl on the hour", UI.GOLD, 6, "RaidWarning")
    if MoveViewLeftStart and MoveViewLeftStop and not (UnitAffectingCombat and UnitAffectingCombat("player")) then
        MoveViewLeftStart(0.12)
        P.panEnds = GetTime() + 4
    end
end

after("DP", function(body)
    if not D.on then return end
    if body == "off" then
        P.on = false
        P.Paint()
        return
    end
    local p = W.Split(body, ",")
    P.on = true
    local brawlIn = n(p[12])
    local cupBits = W.Split(p[13] or "", ":")
    P.info = {
        wins = n(p[1]), losses = n(p[2]), streak = n(p[3]), best = n(p[4]), points = n(p[5]), brawls = n(p[6]), cups = n(p[7]),
        title = p[8] or "", inLine = p[9] == "1", brawl = p[10] == "1", cup = p[11] == "1",
        brawlOn = brawlIn >= 0, brawlNow = p[12] == "0", brawlAt = brawlIn > 0 and (GetTime() + brawlIn) or nil,
        cupState = cupBits[1], cupAt = cupBits[2] and (GetTime() + n(cupBits[2])) or nil,
        line = p[14] ~= "0", challengeMax = n(p[15]),
    }
    P.Arrive()
    P.Paint()
    if D.Refresh then D:Refresh() end
end)

after("DL", function(body)
    if not D.on then return end
    if body == "off" then
        if P.info then P.info.line = false end
        return P.Paint()
    end
    local parts = W.Split(body, ";")
    local p = W.Split(parts[1] or "", ",")
    if p[1] == "err" then return say(WHY[p[2] or ""] or "The line said no.") end
    local names = {}
    for i = 2, getn(parts) do if parts[i] ~= "" then table.insert(names, parts[i]) end end
    local was = P.line
    P.line = { state = p[1], champion = p[2] or "", streak = n(p[3]), challenger = p[4] or "", place = n(p[5]), champ = p[6] == "1", names = names }
    if P.info then P.info.inLine = P.line.champ or P.line.place > 0 end
    -- your turn
    if P.line.place == 1 and (not was or was.place ~= 1) and P.line.state ~= "fight" then
        if UI.Toast then UI.Toast({ icon = ICON, title = "You're next", text = "Stay in the arena: you're called into the pit after this fight.", color = UI.GOLD }) end
    end
    P.Paint()
end)

after("DO", function(body) if D.on then P.OnOffer(body) end end)
after("DC", function(body)
    if not D.on then return end
    local p = W.Split(body, ",")
    P.Countdown(p[1], p[2], p[3])
    if card and card.mode == "offer" then card.ends = GetTime() + 3 end
end)
after("DR", function(body)
    if not D.on then return end
    P.OnResult(body)
    send("pit info")
end)

after("DB", function(body)
    if not D.on then return end
    local p = W.Split(body, ",")
    if p[1] == "joined" then
        say("You're in the brawl" .. (n(p[2]) > 0 and (": it starts in " .. clock(p[2])) or "") .. ". Stay in the arena. " .. n(p[3]) .. " in so far. Nobody dies: the last one standing wins.")
        if P.info then P.info.brawl = true end
    elseif p[1] == "left" then
        say("You're out of the brawl.")
        if P.info then P.info.brawl = false end
    elseif p[1] == "err" then
        say(WHY[p[2] or ""] or "The brawl said no.")
    end
    P.Paint()
end)

after("DU", function(body)
    if not D.on then return end
    local p = W.Split(body, ",")
    if p[1] == "joined" then
        say("You're signed up for the Weekly Duel Cup (" .. n(p[2]) .. " so far). Be in the arena when it starts: one duel at a time, lose and you're out.")
        if P.info then P.info.cup = true end
    elseif p[1] == "left" then
        say("You left the cup.")
        if P.info then P.info.cup = false end
    elseif p[1] == "err" then
        if p[2] == "closed" then
            local s = n(p[3])
            say("The Weekly Duel Cup isn't open for sign-ups" .. (s > 0 and (": it starts in " .. P.Until(s) .. ", sign-ups the hour before.") or "."))
        else
            say(WHY[p[2] or ""] or "The cup said no.")
        end
    end
    P.Paint()
end)

after("DX", function(body)
    if not D.on then return end
    local p = W.Split(body, ",")
    if p[1] == "ok" then
        say("Your challenge to " .. (p[2] or "?") .. " for " .. n(p[3]) .. " DP is announced. The duel request goes out now: stand near them.")
        if StartDuel then StartDuel(p[2]) end
    elseif p[2] == "stake" then say("Put 1 to " .. n(p[3]) .. " Duel Points at stake.")
    elseif p[2] == "points" then say("You have " .. n(p[3]) .. " Duel Points: you can't stake more.")
    elseif p[2] == "theirs" then say("They have only " .. n(p[3]) .. " Duel Points.")
    else say(WHY[p[2] or ""] or "The challenge said no.") end
end)

function P.Until(secs)
    secs = n(secs)
    if secs >= 86400 then
        local d = math.floor(secs / 86400)
        return d .. (d == 1 and " day" or " days")
    end
    if secs >= 3600 then
        local h = math.floor(secs / 3600)
        return h .. (h == 1 and " hour" or " hours")
    end
    return clock(secs)
end

local lastChat = 0
-- DA: the announcer
after("DA", function(body)
    if not D.on then return end
    local p = W.Split(body, ",")
    local what = p[1]
    if what == "win" then
        -- win,<winner>,<wclass>,<loser>,<lclass>,<streak>,<ended>,<kind>,<secs>,<stake>
        local wn, ln = colored(p[2], p[3]), colored(p[4], p[5])
        local streak, ended, kind, stake = n(p[6]), n(p[7]), p[8] or "pit", n(p[10])
        local me = UnitName and UnitName("player")
        if ended >= 3 then
            P.Banner(p[4] .. "'s " .. ended .. "-win streak is over", "ended by " .. wn, { 1, 0.45, 0.2 }, 5, "RaidWarning")
        elseif streak == 3 or streak == 5 or (streak >= 10 and streak - math.floor(streak / 5) * 5 == 0) then
            local words = streak >= 10 and "is unstoppable" or (streak >= 5 and "owns the pit" or "is on a streak")
            P.Banner(p[2] .. " " .. words, streak .. " wins in a row", { 1, 0.82, 0.2 }, 5, "RaidWarning")
        elseif kind == "challenge" and stake > 0 then
            P.Banner(p[2] .. " wins the challenge", "takes " .. stake .. " Duel Points from " .. ln, UI.GOLD, 4, "RaidWarning")
        end
        local now = GetTime()
        if kind ~= "pit" or streak >= 2 or ended >= 2 or (me and (p[2] == me or p[4] == me)) or now - lastChat > 8 then
            lastChat = now
            local extra = ""
            if streak >= 2 then extra = "  |cffffd100" .. streak .. " in a row|r" end
            if ended >= 2 then extra = extra .. "  (ended a streak of " .. ended .. ")" end
            local tag = kind == "line" and " in the line" or (kind == "cup" and " in the cup" or (kind == "challenge" and (" for " .. stake .. " DP") or ""))
            W.Print("|cffff8040Arena:|r " .. wn .. " beat " .. ln .. tag .. ", " .. clock(p[9]) .. extra)
        end
    elseif what == "challenge" then
        P.Banner("A formal challenge", colored(p[2]) .. " challenges " .. colored(p[3]) .. " for " .. n(p[4]) .. " Duel Points", UI.GOLD, 5, "RaidWarning")
    elseif what == "brawl" then
        local k = p[2]
        if k == "soon" then
            if UI.Toast then
                UI.Toast({ icon = "Interface\\Icons\\Ability_Warrior_BattleShout", title = "The brawl in " .. clock(p[3]),
                           text = "Everyone against everyone in the pit, 3 minutes, nobody dies. Click to join.", color = { 1, 0.5, 0.2 },
                           duration = 20, onClick = function() P.Brawl() end, sound = "RaidWarning" })
            end
            if P.info then P.info.brawlAt = GetTime() + n(p[3]) end
        elseif k == "start" then
            P.Banner("BRAWL!", n(p[3]) .. " in the pit  ·  last one standing wins", { 1, 0.35, 0.2 }, 4, "RaidWarning")
            if P.info then P.info.brawlNow = true; P.info.brawl = false end
        elseif k == "out" then
            W.Print("|cffff8040Brawl:|r " .. (p[3] or "?") .. " is out" .. ((p[4] or "") ~= "" and (" (" .. p[4] .. ")") or "") .. ", " .. n(p[5]) .. " left")
        elseif k == "win" then
            P.Banner(p[3] .. " wins the brawl", n(p[4]) .. " knocked out", UI.GOLD, 6, "RaidWarning")
            if P.info then P.info.brawlNow = false end
            send("pit info")
        elseif k == "none" then
            W.Print("|cffff8040Brawl:|r not enough fighters this hour" .. (p[3] and (" (" .. n(p[3]) .. " joined)") or "") .. ". Next one on the hour.")
            if P.info then P.info.brawlNow = false; P.info.brawl = false end
            send("pit info")
        end
    elseif what == "cup" then
        local k = p[2]
        if k == "open" then
            if UI.Toast then
                UI.Toast({ icon = "Interface\\Icons\\INV_Misc_Coin_02", title = "Weekly Duel Cup",
                           text = "Sign-ups are open: it starts in " .. n(p[3]) .. " min. Click to sign up.", color = UI.GOLD,
                           duration = 25, onClick = function() P.Cup() end, sound = "RaidWarning" })
            end
            send("pit info")
        elseif k == "soon" then
            W.Print("|cffffd100Weekly Duel Cup|r starts in " .. n(p[3]) .. " min, " .. n(p[4]) .. " signed up. /duels cup to sign up.")
        elseif k == "start" then
            P.Banner("THE WEEKLY DUEL CUP", n(p[3]) .. " duelists  ·  one duel at a time  ·  lose and you're out", UI.GOLD, 6, "RaidWarning")
            send("pit info")
        elseif k == "fight" then
            P.Banner("Cup, round " .. n(p[5]), (p[3] or "?") .. "  vs  " .. (p[4] or "?"), UI.GOLD, 4)
        elseif k == "forfeit" then
            W.Print("|cffffd100Cup:|r " .. (p[3] or "?") .. " didn't come and is out.")
        elseif k == "win" then
            P.Banner((p[3] or "?") .. " is Cup Champion", "the Weekly Duel Cup", UI.GOLD, 8, "RaidWarning")
            send("pit info")
        elseif k == "none" then
            W.Print("|cffffd100Weekly Duel Cup:|r not enough duelists this week.")
        end
    end
    P.Paint()
end)

-- -- the clock: banner fades, the countdown, the camera, the tracker's timers ------------------

local clockFrame = CreateFrame("Frame", "DuelsPit_Clock")
local acc, infoAcc = 0, 0
clockFrame:SetScript("OnUpdate", function()
    local now = GetTime()
    local e = arg1 or 0
    if banner and banner:IsShown() then
        local left = (banner.ends or 0) - now
        if left <= 0 then banner:Hide() elseif left < 1 then banner:SetAlpha(left) end
    end
    if count and count:IsShown() then
        local left = (count.zero or 0) - now
        if left > 0 then
            local s = math.ceil(left)
            if s ~= count.last then
                count.last = s
                count.num:SetText(tostring(s))
                count.num:SetTextColor(1, 0.82, 0.2)
                sound("igMainMenuOptionCheckBoxOn")
            end
        elseif left > -1.2 then
            if count.last ~= 0 then
                count.last = 0
                count.num:SetText("FIGHT!")
                count.num:SetTextColor(1, 0.3, 0.2)
                sound("RaidWarning")
            end
            count:SetAlpha(math.min(1, 1.2 + left))
        else
            count:Hide()
        end
    end
    if card and card:IsShown() and card.ends and now > card.ends then card:Hide() end
    if P.panEnds and now > P.panEnds then
        P.panEnds = nil
        if MoveViewLeftStop then MoveViewLeftStop() end
    end
    if P.askAt and now >= P.askAt then
        P.askAt = nil
        send("pit info")
    end
    acc = acc + e
    if acc >= 1 then
        acc = 0
        if P.on and tr and tr:IsShown() then P.Paint() end
    end
    infoAcc = infoAcc + e
    if D.on and infoAcc >= 60 then
        infoAcc = 0
        if P.on ~= false then send("pit info") end
    end
end)

-- the realm's hello: ask the pit a moment later (the hello's own requests go first)
local helloSeen = false
after("WF", function(body)
    if D.on and not helloSeen then
        helloSeen = true
        P.askAt = GetTime() + 2
    end
end)

-- /duels line | brawl | cup | challenge | pit | arrival | announcer (Duels.lua passes what it doesn't know)
function P.Slash(raw)
    D.EnsureSaved()
    local msg = string.lower(W.Trim(raw or ""))
    if msg == "line" or msg == "line join" or msg == "join line" then P.Line(true) return true end
    if msg == "line leave" or msg == "leave line" then P.Line(false) return true end
    if msg == "brawl" then P.Brawl() return true end
    if msg == "cup" then P.Cup() return true end
    if msg == "cup leave" then P.Cup(true) return true end
    if msg == "pit" or msg == "record" then
        local i = P.info
        if not i then send("pit info") return true end
        say("Your pit record: " .. i.wins .. " won, " .. i.losses .. " lost, best streak " .. i.best .. ", " .. i.points .. " Duel Points, "
            .. i.brawls .. " brawls and " .. i.cups .. " cups won" .. (i.title ~= "" and (". Title: " .. i.title) or "") .. ".")
        return true
    end
    if string.sub(msg, 1, 9) == "challenge" then
        local a = W.Split(W.Trim(string.sub(W.Trim(raw), 10)), " ")
        P.Challenge(a[1], a[2])
        return true
    end
    if msg == "tracker" or msg == "tracker on" or msg == "tracker off" then
        DuelsPitPrefs.tracker = msg ~= "tracker off" and (msg == "tracker on" or DuelsPitPrefs.tracker == false)
        P.Paint()
        return true
    end
    for _, k in ipairs({ "arrival", "announcer", "sound" }) do
        if msg == k .. " on" or msg == k .. " off" then
            DuelsPitPrefs[k] = msg == k .. " on"
            say("The " .. k .. " is " .. (DuelsPitPrefs[k] and "on" or "off") .. ".")
            return true
        end
    end
    return false
end
