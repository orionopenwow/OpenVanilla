--[[
    Duels.lua  (Open Vanilla / Duels realm)
    The Duels panel: on a Duels realm (the realm's "WF" hello ends in 1) a small window shows your 1v1
    rating and record, queues you for a rated duel or a practice duel, keeps the score of the rounds
    (best of 3), shows the result with Rematch, and how many are queued and fighting right now.
    Gear, kits and enchants are Warfront's window (/wf): "Gear and kits" opens it.

    It rides on the Warfront addon: Warfront talks to the realm (".wnl wf ..."), and this addon adds
    itself after Warfront's handlers for WF (hello), WQ (the arena queue) and WC (live counts).
    Server lines (the world server's OpenVanilla/WarfrontArena.h, realm/mangos/0021-openvanilla-duels.patch):
      WF 1,<tier>,<kills>,<best>,<first>,<duels 0|1>
      WQ q,<mode>,<waited>,<queued>  pop,<mode>,<match>,<team>  round,<n>,<mine>,<theirs>  prep,<s>  go
         end,<won>,<delta>,<rating>[,<mine>-<theirs>]  left  r,<r2>,<r3>,<d1>  err,<reason>
      WC <s2>,<s3>,<r2>,<r3>,<d1>,<matches>,<bg queued>,<bg playing>,<bg bots>,<u1>
    Does nothing on other realms. Lua 5.0 rules: no #, no %, this/arg1 in scripts.
]]--

local W = WenillaCore
local UI = W.UI
local F = Warfront

Duels = Duels or {}
local D = Duels

local getn = table.getn
local ICON = "Interface\\Icons\\Ability_Dualwield"

D.on = false
D.mode = nil          -- the mode we are queued for (d1 / u1)
D.lastMode = "d1"     -- what Rematch queues
D.match = nil         -- { mode, mine, theirs, round }
D.prepEnds = nil
D.rating = nil
D.wins, D.losses = 0, 0
D.result = nil        -- the last result line
D.live = nil          -- { d1 queued, u1 queued, matches }

local MODE_LABEL = { d1 = "Rated duel", u1 = "Practice duel" }

local function say(msg) W.Print("|cffff8040Duels:|r " .. msg) end
D.Say = say

local function send(args)
    if not (F and F.Send) then return nil end
    return F.Send(args)
end

-- -- the panel ---------------------------------------------------------------------------------

local win

local function line(parent, font, y)
    local t = parent:CreateFontString(nil, "OVERLAY", font)
    t:SetPoint("TOPLEFT", parent, "TOPLEFT", 14, y)
    t:SetPoint("RIGHT", parent, "RIGHT", -14, 0)
    t:SetJustifyH("LEFT")
    return t
end

function D:Build()
    if win then return win end
    win = UI.Window("DuelsFrame", { classicFrame = true, width = 300, height = 262, title = "Duels", icon = ICON, skin = true,
                                   point = { "RIGHT", UIParent, "RIGHT", -40, 40 } })
    win:Hide()
    D.win = win

    win.record = line(win, "GameFontHighlight", -34)
    win.state = line(win, "GameFontNormalLarge", -58)
    win.detail = line(win, "GameFontHighlightSmall", -82)

    local rated = UI.Button(win, "Duel now (rated)", 132, 24, function() D:Join("d1") end)
    rated:SetPoint("TOPLEFT", win, "TOPLEFT", 14, -112)
    win.rated = rated
    local practice = UI.Button(win, "Practice duel", 132, 24, function() D:Join("u1") end)
    practice:SetPoint("LEFT", rated, "RIGHT", 8, 0)
    win.practice = practice

    local rematch = UI.Button(win, "Rematch", 132, 24, function() D:Join(D.lastMode or "d1") end)
    rematch:SetPoint("TOPLEFT", rated, "BOTTOMLEFT", 0, -6)
    win.rematch = rematch
    local leave = UI.Button(win, "Leave queue", 132, 24, function() D:Leave() end)
    leave:SetPoint("LEFT", rematch, "RIGHT", 8, 0)
    win.leave = leave

    local gear = UI.Button(win, "Gear and kits", 132, 22, function() if F and F.Toggle then F:Toggle("kits") end end)
    gear:SetPoint("TOPLEFT", rematch, "BOTTOMLEFT", 0, -10)
    local ladder = UI.Button(win, "Ladder", 132, 22, function()
        if F and F.Toggle then
            F:Toggle("arena")
            if F.Arena and F.Arena.Ladder then F.Arena:Ladder("d1") end
        end
    end)
    ladder:SetPoint("LEFT", gear, "RIGHT", 8, 0)

    win.live = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    win.live:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 14, 12)
    win.live:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -14, 12)
    win.live:SetJustifyH("LEFT")
    D:Refresh()
    return win
end

function D:Show()
    D:Build()
    win:Show()
    D:Refresh()
end

function D:Toggle()
    if not D.on then
        say("Duels works on the Duels realm only.")
        return
    end
    D:Build()
    if win:IsShown() then win:Hide() else D:Show() end
end

local function score(m)
    return "You " .. (m.mine or 0) .. " - " .. (m.theirs or 0) .. " Them"
end

function D:Refresh()
    if not win then return end
    local rec = "Rating " .. (D.rating or "...")
    if D.wins + D.losses > 0 then rec = rec .. "   " .. D.wins .. " won, " .. D.losses .. " lost this session" end
    win.record:SetText(rec)
    local busy = D.match ~= nil
    if D.match then
        local m = D.match
        local head = "Round " .. (m.round or 1) .. "   " .. score(m)
        win.state:SetText("|cffff8040" .. head .. "|r")
        if D.prepEnds then
            win.detail:SetText("The gates open in " .. math.max(0, math.ceil(D.prepEnds - GetTime())) .. " s. Best of 3.")
        else
            win.detail:SetText((MODE_LABEL[m.mode] or "Duel") .. ". Best of 3.")
        end
    elseif D.mode then
        win.state:SetText("|cff40ff40Looking for an opponent...|r")
        win.detail:SetText((MODE_LABEL[D.mode] or D.mode) .. ". The match starts as soon as someone is found.")
    else
        win.state:SetText(D.result or "Ready to duel")
        win.detail:SetText(D.result and "Go again with the same kind of duel, or pick another." or "Pick your gear in Gear and kits, then duel. Best of 3 rounds.")
    end
    if busy then win.rated:Disable(); win.practice:Disable(); win.rematch:Disable() else win.rated:Enable(); win.practice:Enable(); win.rematch:Enable() end
    if D.mode then win.leave:Enable() else win.leave:Disable() end
    if D.live then
        local L = D.live
        win.live:SetText("|cffffd100Live|r  " .. L[1] .. " waiting to duel, " .. L[2] .. " practising, " .. L[3] .. " fights on")
    else
        win.live:SetText("")
    end
end

function D:Join(mode)
    if not D.on then return say("Duels works on the Duels realm only.") end
    if send("q join " .. mode) then
        D.lastMode = mode
        D.result = nil
        D:Refresh()
    end
end

function D:Leave()
    send("q leave")
end

-- -- what the realm says (after Warfront's own handlers) ----------------------------------------

local function after(tag, fn)
    local prev = W.modules and W.modules[tag]
    W:RegisterModule(tag, function(body)
        if prev then prev(body) end
        local ok, err = pcall(fn, body or "")
        if not ok then W.Print("|cffff4040Duels:|r " .. tostring(err)) end
    end)
end

after("WF", function(body)
    local parts = W.Split(body, ",")
    local was = D.on
    D.on = parts[1] == "1" and parts[6] == "1"
    if not D.on then
        if win then win:Hide() end
        return
    end
    if not was then
        if W.MicroMenuAdd then W:MicroMenuAdd("Duels", ICON, "DUELS") end
        D:Show()
        send("q rating")
        send("live")
        if parts[5] ~= "1" then
            say("Welcome to Duels. Duel now for the ladder, or Practice duel to warm up. /duels shows this window.")
        end
    end
end)

after("WQ", function(body)
    if not D.on then return end
    local parts = W.Split(body, ",")
    local what = parts[1]
    if what == "q" then
        if parts[2] == "d1" or parts[2] == "u1" then D.mode = parts[2] end
    elseif what == "none" or what == "left" then
        D.mode = nil
        if what == "left" then D.match = nil; D.prepEnds = nil end
    elseif what == "pop" then
        D.mode = nil
        D.match = { mode = parts[2], mine = 0, theirs = 0, round = 1 }
        D:Show()
    elseif what == "round" then
        if D.match then
            D.match.round = tonumber(parts[2]) or (D.match.round + 1)
            D.match.mine = tonumber(parts[3]) or D.match.mine
            D.match.theirs = tonumber(parts[4]) or D.match.theirs
            local up = D.match.mine > D.match.theirs and "You lead" or (D.match.mine < D.match.theirs and "You trail" or "All square")
            if UI.Toast then UI.Toast({ icon = ICON, title = "Round " .. D.match.round, text = up .. ": " .. score(D.match), color = { 1, 0.82, 0.2 } }) end
        end
    elseif what == "prep" then
        D.prepEnds = GetTime() + (tonumber(parts[2]) or 15)
    elseif what == "go" then
        D.prepEnds = nil
    elseif what == "end" then
        local won, delta, rating, sc = parts[2], tonumber(parts[3]) or 0, parts[4], parts[5]
        local text = won == "1" and "|cff40ff40Victory|r" or (won == "0" and "|cffff4040Defeat|r" or "Draw")
        if won == "1" then D.wins = D.wins + 1 elseif won == "0" then D.losses = D.losses + 1 end
        if sc and sc ~= "" then text = text .. "  " .. sc end
        if delta > 0 then text = text .. "  |cff40ff40+" .. delta .. "|r" elseif delta < 0 then text = text .. "  |cffff4040" .. delta .. "|r" end
        D.result = text
        if rating and D.match and D.match.mode == "d1" then D.rating = rating end
        D.match = nil
        D.prepEnds = nil
    elseif what == "r" then
        D.rating = parts[4] or D.rating
    elseif what == "err" then
        if D.match then D.match = nil; D.prepEnds = nil end
    end
    D:Refresh()
end)

after("WC", function(body)
    if not D.on then return end
    local parts = W.Split(body, ",")
    D.live = { tonumber(parts[5]) or 0, tonumber(parts[10]) or 0, tonumber(parts[6]) or 0 }
    D:Refresh()
end)

-- the countdown, and live counts every 10 seconds while the panel is open
local tick = CreateFrame("Frame", "Duels_Tick")
local acc, liveAcc = 0, 0
tick:SetScript("OnUpdate", function()
    if not D.on or not win or not win:IsShown() then return end
    local e = arg1 or 0
    acc = acc + e
    liveAcc = liveAcc + e
    if acc >= 0.5 and D.prepEnds then
        acc = 0
        D:Refresh()
    end
    if liveAcc >= 10 then
        liveAcc = 0
        send("live")
    end
end)

SLASH_DUELS1 = "/duels"
SlashCmdList["DUELS"] = function(msg)
    msg = string.lower(W.Trim(msg or ""))
    if msg == "" then D:Toggle()
    elseif msg == "rated" or msg == "d1" then D:Join("d1")
    elseif msg == "practice" or msg == "u1" then D:Join("u1")
    elseif msg == "leave" then D:Leave()
    else say("/duels opens the panel; /duels rated or /duels practice queues; /duels leave leaves the queue.") end
end

BINDING_HEADER_DUELS = "Duels"
