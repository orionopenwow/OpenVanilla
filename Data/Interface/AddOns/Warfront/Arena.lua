--[[
    Arena.lua  (Open Vanilla / Warfront)
    The arena tab of the Warfront window: queue for skirmish 2v2/3v3, rated 2v2/3v3 or the 1v1 duel
    ladder, leave, see your ratings and the ladder; and the match itself: the pop, the 60 second
    preparation countdown, "Fight!" and the result.
    Live counts: while the window is open it asks ".wnl wf live" every 10 seconds and shows how many
    are queued for each mode and for battlegrounds (WC, OpenVanilla/Warfront.h).
    Server lines: WQ (see the world server's OpenVanilla/WarfrontArena.h), WC, WG. Lua 5.0 rules.
]]--

local W = WenillaCore
local UI = W.UI
local F = Warfront

local strfind, format = string.find, string.format
local getn = table.getn

local MODES = {
    { "s2", "2v2 Skirmish" }, { "s3", "3v3 Skirmish" },
    { "r2", "2v2 Rated" }, { "r3", "3v3 Rated" }, { "d1", "1v1 Duel Ladder" },
}
local MODE_LABEL = {}
for _, m in ipairs(MODES) do MODE_LABEL[m[1]] = m[2] end

local ARENA_REASON = {
    mode = "Pick an arena mode.", level = "Arena is for level 60 characters.", dead = "Not while dead.",
    combat = "Not in combat.", battleground = "Leave the battleground (or its queue) first.",
    instance = "Not from inside a dungeon.", leader = "Only your party leader can queue the party.",
    group = "Your party is too big for that mode.", offline = "Everyone in your party must be online.",
    match = "You are already in a match.", none = "You are not in a queue.", command = "Unknown arena command.",
    flying = "Not while on a flight.",
}

local A = {}
F.Arena = A
A.queued = nil       -- mode
A.waited = 0
A.match = nil        -- { id, mode, team }
A.prepEnds = nil

table.insert(F.tabList, { key = "arena", label = "Arena" })

local function status(t) F.Status(t) end

local function reason(code, extra)
    local r = ARENA_REASON[code or ""]
    if code == "locked" then return "You left a rated match: the queue opens again in " .. math.ceil((tonumber(extra) or 0) / 60) .. " min." end
    if r then return r .. (extra and (" (" .. extra .. ")") or "") end
    return F.Reason(code)
end

F.builders.arena = function(p)
    local head = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    head:SetPoint("TOPLEFT", p, "TOPLEFT", 2, -2)
    head:SetPoint("TOPRIGHT", p, "TOPRIGHT", -2, -2)
    head:SetJustifyH("LEFT")
    head:SetText("Ring of Law, Blackrock Depths. 60 seconds to prepare, buffs from flasks, elixirs and the world removed, cooldowns reset. 15 minutes; then the team with more health wins. Lead your party to queue together.")
    p.head = head
    p.modeButtons = {}
    for i, m in ipairs(MODES) do
        local mode = m[1]
        local b = UI.Button(p, m[2], 140, 22, function() A:Join(mode) end)
        b:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -50 - (i - 1) * 26)
        p.modeButtons[mode] = b
        local c = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        c:SetPoint("LEFT", b, "RIGHT", 6, 0)
        c:SetText("")
        p.modeCounts = p.modeCounts or {}
        p.modeCounts[mode] = c
    end
    local live = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    live:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 2, 2)
    live:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -2, 2)
    live:SetJustifyH("LEFT")
    p.live = live
    local leave = UI.Button(p, "Leave queue", 140, 22, function() A:Leave() end)
    leave:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -50 - getn(MODES) * 26 - 8)
    p.leave = leave
    local state = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    state:SetPoint("TOPLEFT", p, "TOPLEFT", 214, -52)
    state:SetPoint("RIGHT", p, "RIGHT", -4, 0)
    state:SetJustifyH("LEFT")
    p.state = state
    local ratings = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ratings:SetPoint("TOPLEFT", state, "BOTTOMLEFT", 0, -10)
    ratings:SetJustifyH("LEFT")
    p.ratings = ratings
    local ladderHead = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    ladderHead:SetPoint("TOPLEFT", ratings, "BOTTOMLEFT", 0, -12)
    ladderHead:SetText("Ladder")
    p.ladderHead = ladderHead
    p.ladderButtons = {}
    local x = 0
    for _, m in ipairs({ "r2", "r3", "d1" }) do
        local mode = m
        local b = UI.Button(p, m == "d1" and "1v1" or (m == "r2" and "2v2" or "3v3"), 44, 18, function() A:Ladder(mode) end)
        b:SetPoint("LEFT", ladderHead, "RIGHT", 8 + x, 0)
        x = x + 48
        p.ladderButtons[mode] = b
    end
    local ladder = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ladder:SetPoint("TOPLEFT", ladderHead, "BOTTOMLEFT", 0, -6)
    ladder:SetJustifyH("LEFT")
    p.ladder = ladder
    F.onSelect.arena = function()
        A:Refresh()
        if F.Send("q rating") then A.askedRating = true end
        A:AskLive()
    end
end

function A:Refresh()
    local p = F.pages.arena
    if not p then return end
    if A.match then
        p.state:SetText("|cffff8040In a " .. (MODE_LABEL[A.match.mode] or "") .. " match|r" .. (A.prepEnds and ("  starts in " .. math.max(0, math.ceil(A.prepEnds - GetTime())) .. " s") or ""))
    elseif A.queued then
        p.state:SetText("|cff40ff40Queued: " .. (MODE_LABEL[A.queued] or A.queued) .. "|r  |cff9d9d9d" .. (A.queuedCount or 1) .. " in queue|r")
    else
        p.state:SetText("Not queued.")
    end
    if A.ratings then
        p.ratings:SetText("Your ratings:  2v2 " .. A.ratings[1] .. "   3v3 " .. A.ratings[2] .. "   1v1 " .. A.ratings[3])
    end
end

-- -- live counts (WC) --------------------------------------------------------------------------

A.live = nil         -- { s2, s3, r2, r3, d1, matches, bgQueued, bgPlaying, bgBots }
A.liveAsked = 0

function A:AskLive()
    if GetTime() - A.liveAsked < 3 then return end
    if F.Send("live") then A.liveAsked = GetTime() end
end

local function plural(n, one, many) return n .. " " .. (n == 1 and one or many) end

function A:ShowLive()
    local p = F.pages.arena
    if not p or not A.live then return end
    local L = A.live
    for i, m in ipairs(MODES) do
        local c = p.modeCounts and p.modeCounts[m[1]]
        if c then
            local n = L[i] or 0
            c:SetText(n > 0 and ("|cff40ff40" .. n .. " queued|r") or "")
        end
    end
    local bg = "Battlegrounds: " .. plural(L[7] or 0, "player", "players") .. " queued, " .. (L[8] or 0) .. " playing"
    if (L[9] or 0) > 0 then bg = bg .. " |cff9d9d9d(+" .. plural(L[9], "realm bot", "realm bots") .. " filling)|r" end
    p.live:SetText("|cffffd100Live|r  Arena: " .. plural(L[6] or 0, "match", "matches") .. " on.   " .. bg)
end

W:RegisterModule("WC", function(body)
    local parts = W.Split(body, ",")
    A.live = {}
    for i = 1, 9 do A.live[i] = tonumber(parts[i]) or 0 end
    A:ShowLive()
end)

-- entering a battle that has realm bots in it: the realm says so (bot fill is labelled, never hidden)
W:RegisterModule("WG", function(body)
    local parts = W.Split(body, ",")
    if parts[1] == "bots" then
        F.Toast("Bots in this battle", (parts[2] or "?") .. " realm bots are filling empty spots. They never count for streaks or bounties.", { 0.6, 0.8, 1 })
    end
end)

local livePoll = CreateFrame("Frame", "Warfront_LivePoll")
local liveAcc = 0
livePoll:SetScript("OnUpdate", function()
    liveAcc = liveAcc + (arg1 or 0)
    if liveAcc < 10 then return end
    liveAcc = 0
    if F.win and F.win:IsShown() and F.current == "arena" then A:AskLive() end
end)

function A:Join(mode)
    if F.Send("q join " .. mode) then status("Joining the " .. (MODE_LABEL[mode] or mode) .. " queue...") end
end

function A:Leave()
    if F.Send("q leave") then status("Leaving the queue...") end
end

function A:Ladder(mode)
    if F.Send("q top " .. mode) then status("Loading the ladder...") end
end

W:RegisterModule("WQ", function(body)
    local parts = W.Split(body, ",")
    local what = parts[1]
    if what == "q" then
        A.queued = parts[2]
        A.waited = tonumber(parts[3]) or 0
        A.queuedCount = tonumber(parts[4]) or 1
        status("In the " .. (MODE_LABEL[A.queued] or A.queued) .. " queue.")
    elseif what == "none" or what == "left" then
        A.queued = nil
        if what == "left" then
            if A.match then A.match = nil; A.prepEnds = nil end
            status("You are out of the queue.")
        end
    elseif what == "pop" then
        A.queued = nil
        A.match = { mode = parts[2], id = tonumber(parts[3]), team = tonumber(parts[4]) }
        F.Toast("Arena match found", (MODE_LABEL[parts[2]] or "") .. ": taking you to the Ring of Law.")
        if PlaySound then PlaySound("ReadyCheck") end
    elseif what == "prep" then
        A.prepEnds = GetTime() + (tonumber(parts[2]) or 60)
        status("The gates open in " .. (parts[2] or 60) .. " seconds. Buff up.")
    elseif what == "go" then
        A.prepEnds = nil
        F.Toast("Fight!", "The gates are open.", { 1, 0.2, 0.2 })
        status("Fight!")
    elseif what == "end" then
        local won, delta, rating = parts[2], tonumber(parts[3]) or 0, parts[4] or "?"
        local text
        if won == "1" then text = "Victory" elseif won == "0" then text = "Defeat" else text = "Draw" end
        local change = ""
        if delta > 0 then change = "  +" .. delta .. " rating (" .. rating .. ")" elseif delta < 0 then change = "  " .. delta .. " rating (" .. rating .. ")" end
        F.Toast(text, "Back home in 10 seconds." .. change, won == "1" and { 0.3, 1, 0.3 } or { 1, 0.4, 0.3 })
        status(text .. "." .. change)
        A.match = nil
        A.prepEnds = nil
        if F.Send("q rating") then A.askedRating = true end
    elseif what == "r" then
        A.ratings = { tonumber(parts[2]) or 1500, tonumber(parts[3]) or 1500, tonumber(parts[4]) or 1500 }
    elseif what == "top" then
        local recs = W.Split(body, ";")
        local lines = {}
        for i = 2, getn(recs) do
            local f = W.Split(recs[i], ",")
            table.insert(lines, (i - 1) .. ". " .. (f[1] or "?") .. "  " .. (f[2] or ""))
        end
        local p = F.pages.arena
        if p then p.ladder:SetText(getn(lines) > 0 and table.concat(lines, "\n") or "Nobody on this ladder yet.") end
        status("")
    elseif what == "err" then
        -- after a pop, an error means the realm took us out of that match (went into a battleground, ...)
        if A.match then A.match = nil; A.prepEnds = nil end
        status("|cffff4040" .. reason(parts[2], parts[3]) .. "|r")
    end
    A:Refresh()
end)

-- the preparation countdown on the arena tab
local tick = CreateFrame("Frame", "Warfront_ArenaTick")
local acc = 0
tick:SetScript("OnUpdate", function()
    if not A.prepEnds then return end
    acc = acc + (arg1 or 0)
    if acc < 0.5 then return end
    acc = 0
    A:Refresh()
end)

SLASH_WARFRONTARENA1 = "/arena"
SlashCmdList["WARFRONTARENA"] = function(msg)
    msg = string.lower(W.Trim(msg or ""))
    if msg == "" then F:Toggle("arena")
    elseif MODE_LABEL[msg] then A:Join(msg)
    elseif msg == "leave" then A:Leave()
    else F.Say("/arena opens the arena tab; /arena s2|s3|r2|r3|d1 queues; /arena leave leaves.") end
end
