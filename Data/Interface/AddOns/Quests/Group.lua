--[[
    Group.lua  -  Quests: your party's progress on shared quests, and share replies.

    Party members running Quests tell each other their progress with addon messages (PARTY,
    prefix "CPQ"), so the quest log shows "Brakkus 3/8 · Ilyndra done" under a quest you share:
        U;<complete 0|1>;<have>/<need>,<have>/<need>...;<title>   progress on one quest
        R;<title>                                                  quest left the log
        S                                                          please send me everything
    Sharing a quest collects the replies the game sends ("Brakkus has accepted your quest") into
    one line on the quest's page.
]]--

local W = WenillaCore
local Q = Compass

local PREFIX = "CPQ"
Q.party = {}            -- [name] = { [title] = { complete, objs = { {have, need} } } }
Q.shareReplies = {}     -- [title] = { "Brakkus accepted", ... }

local function inParty() return (GetNumPartyMembers and GetNumPartyMembers() or 0) > 0 or (GetNumRaidMembers and GetNumRaidMembers() or 0) > 0 end

local function channel()
    if GetNumRaidMembers and GetNumRaidMembers() > 0 then return "RAID" end
    return "PARTY"
end

local function send(msg)
    if not Q:Get("groupProgress") or not inParty() or not SendAddonMessage then return end
    if string.len(msg) > 240 then msg = string.sub(msg, 1, 240) end
    SendAddonMessage(PREFIX, msg, channel())
end

function Q:SendProgress(q)
    local parts = {}
    for _, o in ipairs(q.objectives) do table.insert(parts, o.have .. "/" .. o.need) end
    send("U;" .. (q.complete and "1" or "0") .. ";" .. table.concat(parts, ",") .. ";" .. q.title)
end

function Q:SendAll()
    for _, q in ipairs(self.quests) do self:SendProgress(q) end
end

-- Members still in the party (raid members count too).
local function members()
    local out = {}
    for i = 1, 4 do
        local n = UnitName("party" .. i)
        if n then out[n] = true end
    end
    for i = 1, 40 do
        local n = UnitName("raid" .. i)
        if n then out[n] = true end
    end
    return out
end

Q:On("CHAT_MSG_ADDON", function()
    if arg1 ~= PREFIX or arg4 == UnitName("player") then return end
    local sender, msg = arg4, arg2 or ""
    if msg == "S" then
        Q:SendAll()
        return
    end
    local f = W.Split(msg, ";")
    local p = Q.party[sender] or {}
    Q.party[sender] = p
    if f[1] == "U" and f[4] then
        local title = f[4]
        for j = 5, table.getn(f) do title = title .. ";" .. f[j] end
        local objs = {}
        local recs, n = W.Split(f[3] or "", ",")
        for i = 1, n do
            local _, _, h, need = string.find(recs[i], "^(%d+)/(%d+)$")
            if h then table.insert(objs, { tonumber(h), tonumber(need) }) end
        end
        p[title] = { complete = (f[2] == "1"), objs = objs }
        Q:Fire("PartyChanged", title)
    elseif f[1] == "R" and f[2] then
        p[f[2]] = nil
        Q:Fire("PartyChanged", f[2])
    end
end)

-- "Brakkus 3/8 · Ilyndra done" for one quest, or nil when nobody in the party shares it.
function Q:PartyProgress(title)
    local out = {}
    local names = {}
    for name in pairs(self.party) do table.insert(names, name) end
    table.sort(names)
    for _, name in ipairs(names) do
        local e = self.party[name][title]
        if e then
            local text
            if e.complete then
                text = "done"
            else
                local h, n = 0, 0
                for _, o in ipairs(e.objs) do h = h + math.min(o[1], o[2]); n = n + o[2] end
                text = (n > 0) and (h .. "/" .. n) or "on it"
            end
            table.insert(out, { name = name, text = text, complete = e.complete, objs = e.objs })
        end
    end
    return out
end

Q:Listen("Progress", function(q) Q:SendProgress(q) end)
Q:Listen("QuestComplete", function(q) Q:SendProgress(q) end)
Q:Listen("QuestAdded", function(q) Q:SendProgress(q) end)
Q:Listen("QuestRemoved", function(q) send("R;" .. q.title) end)

Q:On("PARTY_MEMBERS_CHANGED", function()
    local still = members()
    for name in pairs(Q.party) do
        if not still[name] then Q.party[name] = nil end
    end
    if inParty() and not Q.partyAsked then
        Q.partyAsked = true
        send("S")
        Q:SendAll()
        Q:After(5, function() Q.partyAsked = nil end)
    end
    Q:Fire("PartyChanged")
end)

-- -- Sharing --------------------------------------------------------------------------------

local REPLIES = {
    { "ERR_QUEST_PUSH_ACCEPTED_S", "%s has accepted your quest", "accepted" },
    { "ERR_QUEST_PUSH_ONQUEST_S", "%s is already on that quest", "already has it" },
    { "ERR_QUEST_PUSH_ALREADY_DONE_S", "%s has completed that quest", "has done it" },
    { "ERR_QUEST_PUSH_DECLINED_S", "%s has declined your quest", "declined" },
    { "ERR_QUEST_PUSH_BUSY_S", "%s is busy", "is busy" },
    { "ERR_QUEST_PUSH_INVALID_S", "%s is not eligible for that quest", "can't take it" },
    { "ERR_QUEST_PUSH_LOG_FULL_S", "%s's quest log is full", "has a full log" },
}

local function pattern(fmt)
    local p = string.gsub(fmt, "([%(%)%.%[%]%*%+%-%?%^%$])", "%%%1")
    p = string.gsub(p, "%%s", "(.+)")
    return "^" .. p
end

for _, r in ipairs(REPLIES) do r.pattern = pattern(getglobal(r[1]) or r[2]) end

-- Share the quest with the party. Returns false (and says why) when it cannot be shared.
function Q:Share(title)
    if not inParty() then
        self:Print("You need to be in a party to share a quest.")
        return false
    end
    return self:WithSelected(title, function()
        if GetQuestLogPushable and not GetQuestLogPushable() then
            Q:Print("\"" .. title .. "\" can't be shared.")
            return false
        end
        Q.sharing = title
        Q.shareReplies[title] = {}
        QuestLogPushQuest()
        Q:Fire("ShareChanged", title)
        return true
    end) and true or false
end

Q:On("CHAT_MSG_SYSTEM", function()
    local title = Q.sharing
    if not title or not arg1 then return end
    for _, r in ipairs(REPLIES) do
        local _, _, who = string.find(arg1, r.pattern)
        if who then
            local list = Q.shareReplies[title] or {}
            Q.shareReplies[title] = list
            table.insert(list, who .. " " .. r[3])
            Q:Fire("ShareChanged", title)
            return
        end
    end
end)
