--[[
    Duels.lua  (Open Vanilla / Duels realm)
    The Duels panel: on a Duels realm (the realm's "WF" hello ends in 1) a small window shows your 1v1
    rating and record, queues you for a rated duel or a practice duel, keeps the score of the rounds
    (best of 3), shows the result with Rematch, and how many are queued and fighting right now.
    Gear, kits, enchants and loadout codes are the Armory window (Armory.lua, /duels armory).

    It rides on the Warfront addon: Warfront talks to the realm (".wnl wf ..."), and this addon adds
    itself after Warfront's handlers for WF (hello), WQ (the arena queue) and WC (live counts).
    Server lines (the world server's OpenVanilla/WarfrontArena.h, realm/mangos/0021-openvanilla-duels.patch):
      WF 1,<tier>,<kills>,<best>,<first>,<duels 0|1>
      WQ q,<mode>,<waited>,<queued>  pop,<mode>,<match>,<team>  round,<n>,<mine>,<theirs>  prep,<s>  go
         end,<won>,<delta>,<rating>[,<mine>-<theirs>]  left  r,<r2>,<r3>,<d1>  err,<reason>
      WC <s2>,<s3>,<r2>,<r3>,<d1>,<matches>,<bg queued>,<bg playing>,<bg bots>,<u1>
    And with realm/mangos/0024-openvanilla-duels-arena.patch (Gurubashi Arena, the hangout, spectating):
      WQ sd,<stacks>,<+damage %>,<-healing %>   end,...,p<duel points>   auto,on|off|queued|none
         watch,<match>,<mode>,<name:class:rating>,<name:class:rating>   wstate,<phase>,<round>,<s0>,<s1>,<winner>
         unwatch   fights;<id>,<mode>,<phase>,<round>,<s0>,<s1>,<name:class:rating>,<name:class:rating>,<watchers>;...
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
D.sd = nil            -- sudden death: { stacks, damage %, healing % }
D.watching = nil      -- { id, a, b, round, s0, s1, phase }
D.auto = nil          -- "on" / "off": queued by itself in the hangout
D.points = 0          -- Duel Points this session

local MODE_LABEL = { d1 = "Rated duel", u1 = "Practice duel", s2 = "2v2", s3 = "3v3" }
local CLASS_NAME = { ["1"] = "Warrior", ["2"] = "Paladin", ["3"] = "Hunter", ["4"] = "Rogue", ["5"] = "Priest",
                     ["7"] = "Shaman", ["8"] = "Mage", ["9"] = "Warlock", ["11"] = "Druid" }

-- "name:class:rating" as "Name (Class 1500)"
local function who(s)
    local p = W.Split(s or "", ":")
    if not p[1] or p[1] == "" then return "?" end
    return p[1] .. " (" .. (CLASS_NAME[p[2] or ""] or "?") .. " " .. (p[3] or "?") .. ")"
end

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
    win = UI.Window("DuelsFrame", { classicFrame = true, width = 300, height = 458, title = "Duels", icon = ICON, skin = true,
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

    local gear = UI.Button(win, "Armory", 132, 22, function()
        if D.Armory then D.Armory.Toggle() elseif F and F.Toggle then F:Toggle("kits") end
    end)
    gear:SetPoint("TOPLEFT", rematch, "BOTTOMLEFT", 0, -10)
    win.gear = gear
    local ladder = UI.Button(win, "Ladder", 132, 22, function()
        if F and F.Toggle then
            F:Toggle("arena")
            if F.Arena and F.Arena.Ladder then F.Arena:Ladder("d1") end
        end
    end)
    ladder:SetPoint("LEFT", gear, "RIGHT", 8, 0)

    local watch = UI.Button(win, "Watch a fight", 132, 22, function()
        if D.watching then send("q watch stop") else send("q watch") end
    end)
    watch:SetPoint("TOPLEFT", gear, "BOTTOMLEFT", 0, -6)
    win.watch = watch
    local auto = UI.Button(win, "Auto queue: on", 132, 22, function()
        send("q auto " .. (D.auto == "off" and "on" or "off"))
    end)
    auto:SetPoint("LEFT", watch, "RIGHT", 8, 0)
    win.auto = auto
    local bet = UI.Button(win, "Bet on this fight", 132, 22, function() if D.Bet then D.Bet.FromWatch() end end)
    bet:SetPoint("TOPLEFT", watch, "BOTTOMLEFT", 0, -6)
    win.bet = bet
    local invite = UI.Button(win, "Invite a friend", 132, 22, function() if D.Friends then D.Friends.ShowLink() end end)
    win.invite, win.ladder = invite, ladder
    invite:SetPoint("LEFT", bet, "RIGHT", 8, 0)
    -- team fights: alone (matched with others) or with your party (its leader queues)
    local two = UI.Button(win, "2v2", 132, 22, function() D:Join("s2") end)
    two:SetPoint("TOPLEFT", bet, "BOTTOMLEFT", 0, -10)
    local three = UI.Button(win, "3v3", 132, 22, function() D:Join("s3") end)
    three:SetPoint("LEFT", two, "RIGHT", 8, 0)
    win.two, win.three = two, three
    -- your own duel world: your rules, your link, your ladder (Rooms.lua)
    local host = UI.Button(win, "Host a server", 272, 22, function() if D.Rooms then D.Rooms.Toggle() end end)
    host:SetPoint("TOPLEFT", two, "BOTTOMLEFT", 0, -6)
    win.host = host

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

-- the bare arena (realm OpenVanilla.Duels.Lite, hello field 7): duel anyone in Gurubashi with /duel; the
-- window keeps the gear, the specs and the invite, and nothing of the queue
function D:ApplyLite()
    if not win or win.liteDone == D.lite then return end
    win.liteDone = D.lite
    local queueBits = { win.rated, win.practice, win.rematch, win.leave, win.ladder, win.watch, win.auto, win.bet, win.two, win.three, win.host }
    for _, b in pairs(queueBits) do if b then if D.lite then b:Hide() else b:Show() end end end
    win.gear:ClearAllPoints()
    if D.lite then
        win.gear:SetPoint("TOPLEFT", win, "TOPLEFT", 14, -112)
        win.invite:ClearAllPoints()
        win.invite:SetPoint("LEFT", win.gear, "RIGHT", 8, 0)
        win:SetHeight(220)
        if D.Specs and D.Specs.row then
            D.Specs.row:ClearAllPoints()
            D.Specs.row:SetPoint("TOPLEFT", win.gear, "BOTTOMLEFT", 0, -10)
        end
    else
        win.gear:SetPoint("TOPLEFT", win.rematch, "BOTTOMLEFT", 0, -10)
        win.invite:ClearAllPoints()
        win.invite:SetPoint("LEFT", win.bet, "RIGHT", 8, 0)
        win:SetHeight(458)
    end
end

function D:Refresh()
    if not win then return end
    D:ApplyLite()
    if D.lite then
        win.record:SetText("Gurubashi Arena")
        win.state:SetText("Duel anyone here")
        win.detail:SetText("Right-click a player's portrait and choose Duel (or target them and type /duel). Both of you are healed after. Pick your gear in the Armory.")
        return
    end
    local rec = "Rating " .. (D.rating or "...")
    if D.wins + D.losses > 0 then rec = rec .. "   " .. D.wins .. " won, " .. D.losses .. " lost this session" end
    win.record:SetText(rec)
    if D.Bet and D.Bet.wallet then win.record:SetText(rec .. "   |cffffd100" .. D.Bet.wallet .. " Duel Gold|r") end
    if win.bet then if D.watching then win.bet:Enable() else win.bet:Disable() end end
    local busy = D.match ~= nil or D.watching ~= nil
    if D.watching then
        local w = D.watching
        win.state:SetText("|cff80c0ffWatching|r " .. w.a .. " vs " .. w.b)
        win.detail:SetText("Round " .. (w.round or 1) .. ", " .. (w.s0 or 0) .. " - " .. (w.s1 or 0) .. ". Nobody can see you. Watch a fight again to leave.")
    elseif D.match then
        local m = D.match
        local head = "Round " .. (m.round or 1) .. "   " .. score(m)
        win.state:SetText("|cffff8040" .. head .. "|r")
        if D.prepEnds then
            win.detail:SetText("The gates open in " .. math.max(0, math.ceil(D.prepEnds - GetTime())) .. " s. Best of 3.")
        else
            win.detail:SetText((MODE_LABEL[m.mode] or "Duel") .. ". Best of 3.")
        end
        if D.sd and D.sd[1] > 0 then
            win.detail:SetText("|cffff4040Sudden death|r: +" .. D.sd[2] .. "% damage taken, -" .. D.sd[3] .. "% healing")
        end
    elseif D.mode then
        win.state:SetText("|cff40ff40Looking for an opponent...|r")
        win.detail:SetText((MODE_LABEL[D.mode] or D.mode) .. ". The match starts as soon as someone is found.")
    else
        win.state:SetText(D.result or "Ready to duel")
        if D.auto == "on" then
            win.detail:SetText("In the arena's pit or stands you are queued by yourself in a few seconds. Leave queue stops that until you duel again.")
        else
            win.detail:SetText(D.result and "Go again with the same kind of duel, or pick another." or "Pick your gear in the Armory, then duel. Best of 3 rounds.")
        end
    end
    if D.auto then
        win.auto:Show()
        win.auto:SetText("Auto queue: " .. D.auto)
    else
        win.auto:Hide()
    end
    if D.watching then win.watch:SetText("Stop watching") else win.watch:SetText("Watch a fight") end
    if D.match then win.watch:Disable() else win.watch:Enable() end
    if busy then win.rated:Disable(); win.practice:Disable(); win.rematch:Disable() else win.rated:Enable(); win.practice:Enable(); win.rematch:Enable() end
    -- 2v2 and 3v3 are a party of that size (its leader queues); 1v1 is always just you
    if win.two then
        local party = (GetNumPartyMembers and GetNumPartyMembers() or 0) + 1
        local leader = party == 1 or (IsPartyLeader and IsPartyLeader())
        if busy or party ~= 2 or not leader then win.two:Disable() else win.two:Enable() end
        if busy or party ~= 3 or not leader then win.three:Disable() else win.three:Enable() end
        win.two:SetText(party == 2 and "2v2" or "2v2 (party of 2)")
        win.three:SetText(party == 3 and "3v3" or "3v3 (party of 3)")
    end
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
    D.lite = parts[7] == "1"
    if not D.on then
        if win then win:Hide() end
        return
    end
    if not was then
        if W.MicroMenuAdd then W:MicroMenuAdd("Duels", ICON, "DUELS") end
        -- no window pops up on arrival: /duels or the menu opens it (the intro says how to duel)
        if not D.lite then D:Show() end
        if D.SetupBarsOnce then D.SetupBarsOnce() end
        if not D.lite then
            send("q rating")
            send("live")
        end
        if parts[5] ~= "1" and not D.lite then
            say("Welcome to Duels. Duel now for the ladder, or Practice duel to warm up. /duels shows this window.")
        end
    end
end)

after("WQ", function(body)
    if not D.on then return end
    local parts = W.Split(body, ",")
    local what = parts[1]
    if what == "q" then
        if parts[2] == "d1" or parts[2] == "u1" or parts[2] == "s2" or parts[2] == "s3" then D.mode = parts[2] end
    elseif what == "none" or what == "left" then
        D.mode = nil
        if what == "left" then D.match = nil; D.prepEnds = nil end
    elseif what == "pop" then
        D.mode = nil
        D.sd = nil
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
        D.sd = nil
    elseif what == "sd" then
        D.sd = { tonumber(parts[2]) or 0, parts[3] or "0", parts[4] or "0" }
        if D.sd[1] == 1 and UI.Toast then
            UI.Toast({ icon = "Interface\\Icons\\Spell_Shadow_UnholyFrenzy", title = "Sudden death", text = "The crowd grows impatient: more damage, less healing, every 15 s.", color = { 1, 0.25, 0.25 } })
        end
    elseif what == "watch" then
        D.mode = nil
        D.watching = { id = parts[2], a = who(parts[4]), b = who(parts[5]), round = 1, s0 = 0, s1 = 0 }
        say("Watching " .. D.watching.a .. " vs " .. D.watching.b .. ". /duels stop to leave.")
        D:Show()
    elseif what == "wstate" then
        if D.watching then
            D.watching.phase = parts[2]
            D.watching.round = tonumber(parts[3]) or D.watching.round
            D.watching.s0 = tonumber(parts[4]) or 0
            D.watching.s1 = tonumber(parts[5]) or 0
            if parts[2] == "ending" then
                local wn = parts[6]
                local name = wn == "0" and D.watching.a or (wn == "1" and D.watching.b or nil)
                say(name and (name .. " wins, " .. D.watching.s0 .. " - " .. D.watching.s1 .. ".") or "A draw.")
            end
        end
    elseif what == "unwatch" then
        D.watching = nil
    elseif what == "auto" then
        if parts[2] == "on" or parts[2] == "off" then D.auto = parts[2]
        elseif parts[2] == "queued" then D.auto = "on"
        elseif parts[2] == "none" then D.auto = nil end
    elseif what == "end" then
        local won, delta, rating, sc = parts[2], tonumber(parts[3]) or 0, parts[4], parts[5]
        local pts = nil
        local i = 5
        while parts[i] do
            if string.sub(parts[i], 1, 1) == "p" then
                pts = tonumber(string.sub(parts[i], 2))
                if i == 5 then sc = nil end
            end
            i = i + 1
        end
        D.sd = nil
        local text = won == "1" and "|cff40ff40Victory|r" or (won == "0" and "|cffff4040Defeat|r" or "Draw")
        if won == "1" then D.wins = D.wins + 1 elseif won == "0" then D.losses = D.losses + 1 end
        if sc and sc ~= "" then text = text .. "  " .. sc end
        if delta > 0 then text = text .. "  |cff40ff40+" .. delta .. "|r" elseif delta < 0 then text = text .. "  |cffff4040" .. delta .. "|r" end
        if pts then
            D.points = D.points + pts
            text = text .. "  |cffffd100+" .. pts .. " DP|r"
        end
        D.result = text
        if rating and D.match and D.match.mode == "d1" then D.rating = rating end
        D.match = nil
        D.prepEnds = nil
    elseif what == "r" then
        D.rating = parts[4] or D.rating
    elseif what == "err" then
        if parts[2] == "nofight" then say("No fight to watch right now.")
        elseif parts[2] == "watch" then say("You can watch from the hangout only, alive and out of combat."); D.watching = nil
        elseif parts[2] == "watching" then say("You are watching a fight: /duels stop first.")
        elseif D.match then D.match = nil; D.prepEnds = nil
        elseif parts[2] == "lite" then
            D.mode = nil
            say("This arena has no queue: duel anyone here (right-click their portrait, Duel).")
        else
            -- the queue said no (party size, leader, combat, locked...): say why, out loud
            D.mode = nil
            local why = F and F.Arena and F.Arena.Reason and F.Arena.Reason(parts[2], parts[3]) or parts[2]
            say("|cffff6040" .. tostring(why) .. "|r")
        end
    elseif string.sub(what, 1, 6) == "fights" then
        local list = W.Split(body, ";")
        if not list[2] then
            say("No fights right now.")
        else
            say("Fights now (/duels watch <number>):")
            local k = 2
            while list[k] do
                local f = W.Split(list[k], ",")
                W.Print("  |cffffd100" .. (f[1] or "?") .. "|r  " .. who(f[7]) .. " vs " .. who(f[8]) ..
                        "  round " .. (f[4] or "?") .. ", " .. (f[5] or 0) .. "-" .. (f[6] or 0) ..
                        ((tonumber(f[9]) or 0) > 0 and ("  (" .. f[9] .. " watching)") or ""))
                k = k + 1
            end
        end
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
    local raw = W.Trim(msg or "")
    msg = string.lower(raw)
    if msg == "" then D:Toggle()
    elseif msg == "rooms" or msg == "room list" then send("q room list")
    elseif string.sub(msg, 1, 4) == "spec" and string.sub(msg, 1, 5) ~= "specs" then
        local n = D.Specs and D.Specs.Find(W.Trim(string.sub(msg, 5)))
        if n then D.Specs.Switch(n) else say("/duels spec 1, 2 or 3 (or its name: /duels spec frost).") end
    elseif string.sub(msg, 1, 4) == "room" then
        local rest = W.Trim(string.sub(raw, 5))
        local verb = string.lower(string.sub(rest, 1, 4))
        if rest == "" then if D.Rooms then D.Rooms.Toggle() end
        elseif verb == "join" then
            local a = W.Split(W.Trim(string.sub(rest, 5)), " ")
            if D.Rooms then D.Rooms.Join(a[1], a[2]) end
        elseif string.lower(rest) == "leave" then send("q room leave")
        elseif string.lower(rest) == "info" then send("q room info")
        elseif string.lower(rest) == "fight" then send("q join room")
        else say("/duels room opens Host a server; /duels room join <code> [password]; /duels room leave; /duels room fight; /duels rooms lists public rooms.") end
    elseif msg == "rated" or msg == "d1" then D:Join("d1")
    elseif msg == "practice" or msg == "u1" then D:Join("u1")
    elseif msg == "leave" then D:Leave()
    elseif msg == "fights" then send("q fights")
    elseif msg == "stop" or msg == "unwatch" then send("q watch stop")
    elseif string.sub(msg, 1, 5) == "watch" then send("q watch " .. W.Trim(string.sub(msg, 6)))
    elseif msg == "auto on" or msg == "auto off" then send("q " .. msg)
    elseif string.sub(msg, 1, 3) == "bet" then
        local id = W.Trim(string.sub(msg, 4))
        if id == "" then if D.Bet then D.Bet.FromWatch() end
        elseif D.Bet then D.Bet.Open(id) end
    elseif msg == "gold" or msg == "wallet" then send("q wallet")
    elseif msg == "2v2" then D:Join("s2")
    elseif msg == "3v3" then D:Join("s3")
    elseif string.sub(msg, 1, 6) == "friend" then
        if D.Friends then D.Friends.Join(W.Trim(string.sub(msg, 7))) end
    elseif msg == "invite" then if D.Friends then D.Friends.ShowLink() end
    elseif msg == "intro" or msg == "help" then if D.Intro then D.Intro.Show(1) end
    elseif msg == "armory" or msg == "gear" then if D.Armory then D.Armory.Toggle() end
    elseif msg == "bars" or msg == "bars reset" then
        local n = D.LayOutBars(msg == "bars reset")
        say(n .. " abilities placed on empty buttons; all four extra bars are on.")
    else say("/duels opens the panel; /duels rated or /duels practice queues; /duels leave leaves the queue; /duels fights lists the fights now, /duels watch [number] watches one, /duels stop; /duels auto on|off; /duels bars lays out your action bars; /duels armory opens the Armory; /duels bet [fight] bets Duel Gold; /duels gold shows your wallet; /duels room hosts your own server.") end
end

BINDING_HEADER_DUELS = "Duels"

-- a party made or left: 2v2 and 3v3 light up or grey out
local partyEv = CreateFrame("Frame")
partyEv:RegisterEvent("PARTY_MEMBERS_CHANGED")
partyEv:RegisterEvent("PARTY_LEADER_CHANGED")
partyEv:SetScript("OnEvent", function() if D.on and D.Refresh then D:Refresh() end end)
