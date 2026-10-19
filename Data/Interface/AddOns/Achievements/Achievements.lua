--[[
    Achievements.lua  -  the realm's achievements: data, server packets, progress maths, API.

    The realm keeps achievements (server-authoritative: the client never grants one). This addon
    shows them: the catalogue from Data.lua (generated from realm/achievements/achievements.yml),
    what the server says you earned, progress bars, a banner when you earn one, comparison with
    another player, chat links, a small tracker and a featured achievement for Persona.
    Points and recognition only, never power.

    Server packets (tag AC, see realm/achievements/PROTOCOL.md):
        L <id>,<date>;...              everything you have earned (after login, and on ".wnl ac list")
        E <id>,<date>;...              just earned
        P <id>,<value>[,<goal>];...    progress toward counted achievements
        C <criteria>,<value>;...       one step of a multi-step achievement (a boss, a totem quest)
        R <id>,<name>,<date>;...       realm firsts already claimed on this realm
        F <id>,<name>,<date>           a realm first was just claimed (announced to everyone)
        I <name>,<class>,<points>;<id>,<date>;...   another player's achievements (".wnl ac inspect")
        I <name>,-                     nobody by that name
    Commands: ".wnl ac list", ".wnl ac inspect <name>".

    API for other addons (all safe to call any time):
        Achievements.Points()            your points
        Achievements.Featured()          { id, name, icon, points, total } or nil (Persona)
        Achievements.Get(id)             the catalogue entry
        Achievements.IsEarned(id)        date or nil
        Achievements.Progress(id)        value, goal, label (nil when it has no bar)
        Achievements.Track(id) / Untrack(id) / IsTracked(id) / Tracked()
        Achievements.OnTrackedChanged(fn)        fn() after the tracked list or its progress changes
        Achievements.UseExternalTracker(on)      another tracker draws the tracked list; ours hides
        Achievements.Link(id)            "[Achievement: Name]" into the chat edit box
        Achievements.Compare(name)       ask the realm for someone's achievements
        Achievements_Toggle()            the key binding (Y)

    Lua 5.0 rules (1.12.1 client): no '#', no '%' operator, handlers read this/event/arg1..arg9.
]]--

local W = WenillaCore
local UI = W.UI
local ID = "Achievements"

Achievements = Achievements or {}
local A = Achievements
A.version = "1.0.0"

local strfind, strsub, strlower, strupper, strlen = string.find, string.sub, string.lower, string.upper, string.len
local tinsert, tremove, getn = table.insert, table.remove, table.getn
local floor = math.floor

A.MAX_TRACKED = 5
A.LIST_GAP = 30           -- seconds between ".wnl ac list" requests
A.data = Achievements_Data or { categories = {}, list = {} }

-- -- Catalogue --------------------------------------------------------------------------------

A.byId, A.byCat, A.catByKey = {}, {}, {}
for _, c in ipairs(A.data.categories) do
    A.byCat[c.key] = {}
    A.catByKey[c.key] = c
end
for _, a in ipairs(A.data.list) do
    A.byId[a.id] = a
    if A.byCat[a.c] then tinsert(A.byCat[a.c], a) end
end
-- metas: which achievements does earning `id` move forward?
A.parents = {}
for _, a in ipairs(A.data.list) do
    if a.cr then
        for _, c in ipairs(a.cr) do
            if c.meta then
                A.parents[c.meta] = A.parents[c.meta] or {}
                tinsert(A.parents[c.meta], a.id)
            end
        end
    end
end

-- -- State ------------------------------------------------------------------------------------

A.earned = {}       -- id -> unix date
A.progress = {}     -- id -> { v = value, g = goal from the server or nil }
A.crit = {}         -- criteria id -> value
A.realmFirsts = {}  -- id -> { name = , date = }
A.tracked = {}      -- ids, in order
A.compare = nil     -- { name, class, points, earned = { id -> date } }
A.synced = false    -- the server sent the full list this session
A.lastList = nil
A.listeners = {}

local function charKey()
    return (GetRealmName and GetRealmName() or "?") .. "/" .. (UnitName("player") or "?")
end

function A.DB()
    if type(Achievements_DB) ~= "table" then Achievements_DB = {} end
    local d = Achievements_DB
    d.version = d.version or 1
    d.chars = d.chars or {}
    d.realms = d.realms or {}
    return d
end

-- This character's saved cache: what the server last told us, so the window has something to show
-- before (or without) a connection.
function A.Char()
    local d = A.DB()
    local k = charKey()
    local c = d.chars[k]
    if not c then
        c = {}
        d.chars[k] = c
    end
    c.earned = c.earned or {}
    c.progress = c.progress or {}
    c.crit = c.crit or {}
    c.tracked = c.tracked or {}
    return c
end

function A.RealmCache()
    local d = A.DB()
    local r = GetRealmName and GetRealmName() or "?"
    d.realms[r] = d.realms[r] or {}
    d.realms[r].firsts = d.realms[r].firsts or {}
    return d.realms[r]
end

function A.LoadCache()
    local c = A.Char()
    A.earned, A.progress, A.crit, A.tracked = c.earned, c.progress, c.crit, c.tracked
    A.realmFirsts = A.RealmCache().firsts
    A.cacheLoaded = true
end

-- -- Who can earn what ------------------------------------------------------------------------

function A.PlayerFaction()
    local f = UnitFactionGroup and UnitFactionGroup("player")
    return f
end

function A.PlayerClass()
    local _, token = UnitClass("player")
    return token
end

-- Achievements for the other faction or another class are not shown (unless somehow earned).
function A.Visible(a)
    if not a then return false end
    if A.earned[a.id] then return true end
    if a.f then
        local f = A.PlayerFaction()
        if f and f ~= a.f then return false end
    end
    if a.cl then
        local cls = A.PlayerClass()
        if cls and not a.cl[cls] then return false end
    end
    return true
end

function A.Get(id) return A.byId[tonumber(id) or -1] end
function A.IsEarned(id) return A.earned[tonumber(id) or -1] end

-- -- Numbers ----------------------------------------------------------------------------------

function A.Commas(n)
    n = floor(tonumber(n) or 0)
    local s = tostring(n)
    local out = ""
    while strlen(s) > 3 do
        out = "," .. strsub(s, -3) .. out
        s = strsub(s, 1, -4)
    end
    return s .. out
end

-- "12/04/26" (day/month/year); "" for no date.
function A.Date(t)
    t = tonumber(t)
    if not t or t <= 0 then return "" end
    if date then return date("%d/%m/%y", t) end
    return ""
end

function A.Points()
    local p = 0
    for id in pairs(A.earned) do
        local a = A.byId[id]
        if a then p = p + (a.p or 0) end
    end
    return p
end

-- Points, earned count and total for a category (or every category when key is nil).
function A.CategoryStats(key)
    local earned, total, pts, maxPts = 0, 0, 0, 0
    for _, a in ipairs(A.data.list) do
        if (not key or a.c == key) and A.Visible(a) then
            total = total + 1
            maxPts = maxPts + (a.p or 0)
            if A.earned[a.id] then
                earned = earned + 1
                pts = pts + (a.p or 0)
            end
        end
    end
    return earned, total, pts, maxPts
end

-- -- Progress ---------------------------------------------------------------------------------

local function goalFor(a)
    local f = A.PlayerFaction()
    if f == "Horde" then return a.gh or a.ga end
    return a.ga or a.gh
end

-- Local readings for the few things the 1.12 client knows itself, so bars move between server
-- updates and show something before the server answers. The server alone grants.
local function skillValue(name)
    if not (GetNumSkillLines and GetSkillLineInfo) then return nil end
    for i = 1, GetNumSkillLines() do
        local n, header, _, rank = GetSkillLineInfo(i)
        if not header and n == name then return rank or 0 end
    end
    return 0
end

local function exaltedCount()
    if not (GetNumFactions and GetFactionInfo) then return nil end
    local n = 0
    for i = 1, GetNumFactions() do
        local _, _, standing, _, _, _, _, _, header = GetFactionInfo(i)
        if not header and standing == 8 then n = n + 1 end
    end
    return n
end

local function localValue(a)
    local k = a.k
    if k == "level" then return UnitLevel("player") end
    if k == "money" then return GetMoney and floor(GetMoney() / 10000) or nil end
    if k == "skill" then return skillValue(a.pl) end
    if k == "exalted" then return exaltedCount() end
    if k == "honor_kills" and GetPVPLifetimeStats then
        local hk = GetPVPLifetimeStats()
        return hk
    end
    return nil
end

-- Steps done of a multi-step achievement: metas from the earned list, the rest from C packets.
function A.StepsDone(a)
    if not a.cr then return 0 end
    local n = 0
    for _, c in ipairs(a.cr) do
        if c.meta then
            if A.earned[c.meta] then n = n + 1 end
        elseif (A.crit[c.id] or 0) > 0 then
            n = n + 1
        end
    end
    return n
end

function A.StepDone(c)
    if c.meta then return A.earned[c.meta] and true or false end
    return (A.crit[c.id] or 0) > 0
end

-- value, goal, label for an achievement's bar; nil when it is a plain yes/no.
function A.Progress(id)
    local a = type(id) == "table" and id or A.byId[tonumber(id) or -1]
    if not a then return nil end
    local srv = A.progress[a.id]
    local goal = (srv and srv.g) or goalFor(a)
    if not goal or goal <= 0 then return nil end
    local label = a.pl or "Progress"
    if A.earned[a.id] then return goal, goal, label end
    if a.rf and A.realmFirsts[a.id] then return nil end   -- someone else claimed it
    local v
    if a.cr then
        v = A.StepsDone(a)
    else
        v = srv and srv.v
        local l = localValue(a)
        if l and (not v or l > v) then v = l end
    end
    v = tonumber(v) or 0
    if v > goal then v = goal end
    if v < 0 then v = 0 end
    return v, goal, label
end

-- "Quests: 312/1000"
function A.ProgressText(a)
    local v, g, label = A.Progress(a)
    if not v then return nil end
    return label .. ": " .. A.Commas(v) .. "/" .. A.Commas(g)
end

-- Unearned, with a bar at least half full.
function A.IsClose(a)
    if type(a) ~= "table" then a = A.byId[tonumber(a) or -1] end
    if not a or A.earned[a.id] then return false end
    local v, g = A.Progress(a)
    return v and g and g > 0 and v > 0 and (v / g) >= 0.5 and true or false
end

-- -- Filters ----------------------------------------------------------------------------------
-- filter: "all" | "earned" | "unearned" | "close"; search: plain text, matched in name/description.

function A.Matches(a, filter, search)
    if not A.Visible(a) then return false end
    if filter == "earned" and not A.earned[a.id] then return false end
    if filter == "unearned" and A.earned[a.id] then return false end
    if filter == "close" and not A.IsClose(a) then return false end
    if search and search ~= "" then
        local s = strlower(search)
        if not strfind(strlower(a.n), s, 1, 1) and not strfind(strlower(a.d), s, 1, 1) then return false end
    end
    return true
end

-- The achievements a list shows: one category, or every category while searching.
function A.Filtered(cat, filter, search)
    local out = {}
    local src = (search and search ~= "" or not cat) and A.data.list or (A.byCat[cat] or {})
    for _, a in ipairs(src) do
        if A.Matches(a, filter, search) then tinsert(out, a) end
    end
    return out
end

-- Most recently earned first.
function A.Recent(n)
    local out = {}
    for id, t in pairs(A.earned) do
        if A.byId[id] then tinsert(out, { a = A.byId[id], t = t }) end
    end
    table.sort(out, function(x, y)
        if x.t == y.t then return x.a.id > y.a.id end
        return x.t > y.t
    end)
    local res = {}
    for i = 1, math.min(n or 5, getn(out)) do tinsert(res, out[i].a) end
    return res
end

-- -- Server packets ---------------------------------------------------------------------------

local function records(rest)
    local out = {}
    local recs, n = W.Split(rest or "", ";")
    for i = 1, n do
        if recs[i] ~= "" then
            local f = W.Split(recs[i], ",")
            tinsert(out, f)
        end
    end
    return out
end

local function save()
    local c = A.Char()
    c.earned, c.progress, c.crit, c.tracked = A.earned, A.progress, A.crit, A.tracked
    c.synced = time and time() or 0
end

function A.Changed(what)
    if A.OnDataChanged then A.OnDataChanged(what) end
    for _, fn in ipairs(A.listeners) do pcall(fn) end
end

function A.HandlePacket(body)
    if not A.cacheLoaded then A.LoadCache() end
    local _, _, kind, rest = strfind(body or "", "^(%a)%s?(.*)$")
    if not kind then return end
    kind = strupper(kind)
    if kind == "L" then
        local earned = {}
        for _, f in ipairs(records(rest)) do
            local id, t = tonumber(f[1]), tonumber(f[2])
            if id and A.byId[id] then earned[id] = t or 0 end
        end
        A.earned = earned
        A.synced = true
        A.waiting = nil
        -- earned achievements leave the tracker
        for i = getn(A.tracked), 1, -1 do
            if A.earned[A.tracked[i]] then tremove(A.tracked, i) end
        end
        save()
        A.Changed("list")
    elseif kind == "E" then
        local new = {}
        for _, f in ipairs(records(rest)) do
            local id, t = tonumber(f[1]), tonumber(f[2])
            if id and A.byId[id] and not A.earned[id] then
                A.earned[id] = t or (time and time()) or 0
                A.progress[id] = nil
                tinsert(new, id)
                A.Untrack(id, true)
            end
        end
        save()
        A.Changed("earned")
        for _, id in ipairs(new) do
            if A.OnEarned then A.OnEarned(A.byId[id]) end
        end
    elseif kind == "P" then
        for _, f in ipairs(records(rest)) do
            local id, v, g = tonumber(f[1]), tonumber(f[2]), tonumber(f[3])
            if id and v and A.byId[id] then
                A.progress[id] = { v = v, g = (g and g > 0) and g or nil }
            end
        end
        save()
        A.Changed("progress")
    elseif kind == "C" then
        for _, f in ipairs(records(rest)) do
            local cid, v = tonumber(f[1]), tonumber(f[2])
            if cid and v then A.crit[cid] = v end
        end
        save()
        A.Changed("progress")
    elseif kind == "R" or kind == "F" then
        local fresh = {}
        if kind == "R" then
            for k in pairs(A.realmFirsts) do A.realmFirsts[k] = nil end
        end
        for _, f in ipairs(records(rest)) do
            local id, name, t = tonumber(f[1]), f[2], tonumber(f[3])
            if id and A.byId[id] and name and name ~= "" then
                if not A.realmFirsts[id] then tinsert(fresh, id) end
                A.realmFirsts[id] = { name = name, date = t or 0 }
            end
        end
        A.Changed("realm")
        if kind == "F" and A.OnRealmFirst then
            for _, id in ipairs(fresh) do A.OnRealmFirst(A.byId[id], A.realmFirsts[id]) end
        end
    elseif kind == "I" then
        local recs = records(rest)
        local head = recs[1]
        if not head or not head[1] or head[1] == "" then return end
        local name = head[1]
        A.inspecting = nil
        if head[2] == "-" then
            A.compare = nil
            W.Print("Achievements: nobody called " .. name .. " was found on this realm.")
            A.Changed("compare")
            return
        end
        local cmp = { name = name, class = head[2], points = tonumber(head[3]), earned = {} }
        for i = 2, getn(recs) do
            local id, t = tonumber(recs[i][1]), tonumber(recs[i][2])
            if id and A.byId[id] then cmp.earned[id] = t or 0 end
        end
        if not cmp.points then
            local p = 0
            for id in pairs(cmp.earned) do p = p + (A.byId[id].p or 0) end
            cmp.points = p
        end
        A.compare = cmp
        A.Changed("compare")
        if A.OnCompare then A.OnCompare(cmp) end
    end
end

W:RegisterModule("AC", function(body) A.HandlePacket(body) end)

-- Does the realm keep achievements? true / false / nil (not known yet: no greeting).
function A.ServerHas()
    if not W.connected then return nil end
    local list = W.serverAddons or {}
    if not list[1] then return A.synced and true or nil end
    for _, x in ipairs(list) do
        if x == ID or x == "AC" then return true end
    end
    return A.synced and true or false
end

-- Ask for the full list (at most every A.LIST_GAP seconds).
function A.RequestList(force)
    if not W.connected then return false end
    local now = GetTime()
    if not force and A.lastList and now - A.lastList < A.LIST_GAP then return false end
    A.lastList = now
    A.waiting = true
    return W:SendCommand("ac", "list") and true or false
end

function A.Compare(name)
    name = W.Trim(name or "")
    if name == "" then
        if UnitIsPlayer and UnitIsPlayer("target") then name = UnitName("target") or "" end
    end
    if name == "" then
        W.Print("Achievements: compare with whom? Target a player or type /ach compare Name.")
        return false
    end
    -- "name" -> "Name"
    name = strupper(strsub(name, 1, 1)) .. strlower(strsub(name, 2))
    if name == UnitName("player") then
        A.compare = nil
        A.Changed("compare")
        return false
    end
    if not W.connected then
        W.Print("Achievements: comparing needs an Open Vanilla realm; you're not connected to one.")
        return false
    end
    A.inspecting = name
    W:SendCommand("ac", "inspect " .. name)
    return true
end

function A.StopCompare()
    A.compare = nil
    A.inspecting = nil
    A.Changed("compare")
end

-- -- Tracking ---------------------------------------------------------------------------------

function A.IsTracked(id)
    for _, x in ipairs(A.tracked) do if x == id then return true end end
    return false
end

function A.Track(id)
    id = tonumber(id)
    local a = id and A.byId[id]
    if not a or A.earned[id] or A.IsTracked(id) then return false end
    if getn(A.tracked) >= A.MAX_TRACKED then
        W.Print("Achievements: you can track up to " .. A.MAX_TRACKED .. " at once.")
        return false
    end
    tinsert(A.tracked, id)
    save()
    A.Changed("tracked")
    return true
end

function A.Untrack(id, quiet)
    id = tonumber(id)
    for i, x in ipairs(A.tracked) do
        if x == id then
            tremove(A.tracked, i)
            save()
            if not quiet then A.Changed("tracked") end
            return true
        end
    end
    return false
end

-- { { id, name, icon, text, value, goal }, ... } for any tracker to draw.
function A.Tracked()
    local out = {}
    for _, id in ipairs(A.tracked) do
        local a = A.byId[id]
        if a then
            local v, g = A.Progress(a)
            tinsert(out, { id = id, name = a.n, icon = a.i, text = A.ProgressText(a) or a.d, value = v, goal = g })
        end
    end
    return out
end

function A.OnTrackedChanged(fn)
    if type(fn) == "function" then tinsert(A.listeners, fn) end
end

function A.UseExternalTracker(on)
    A.externalTracker = on and true or false
    A.Changed("tracked")
end

-- -- Links and Persona ------------------------------------------------------------------------

-- 1.12 chat can't carry custom hyperlinks, so the link is plain text everyone can read.
function A.LinkText(id)
    local a = A.byId[tonumber(id) or -1]
    if not a then return nil end
    return "[Achievement: " .. a.n .. "]"
end

function A.Link(id)
    local text = A.LinkText(id)
    if not text then return false end
    if ChatFrameEditBox and ChatFrameEditBox:IsVisible() then
        ChatFrameEditBox:Insert(text)
    elseif ChatFrame_OpenChat then
        ChatFrame_OpenChat(text)
    end
    return true
end

function A.SetFeatured(id)
    local c = A.Char()
    c.featured = tonumber(id)
    A.Changed("featured")
end

-- What Persona (or anyone) may show next to your name: points and one achievement. nil when the
-- player turned sharing off. Defaults to the most recent achievement worth the most points.
function A.Featured()
    if not W:IsActive(ID) or W:Setting(ID, "persona", true) == false then return nil end
    local c = A.Char()
    local a = c.featured and A.earned[c.featured] and A.byId[c.featured]
    if not a then
        local best
        for _, x in ipairs(A.Recent(20)) do
            if not best or (x.p or 0) > (best.p or 0) then best = x end
        end
        a = best
    end
    local total = A.Points()
    if not a then return { points = total } end
    return { id = a.id, name = a.n, icon = a.i, points = total, achievementPoints = a.p, date = A.earned[a.id] }
end

-- -- Startup ----------------------------------------------------------------------------------

-- Bind Y the first time, unless the player already uses Y (or bound the window elsewhere).
BINDING_HEADER_ACHIEVEMENTS = "Achievements"
BINDING_NAME_ACHIEVEMENTS_TOGGLE = "Toggle the Achievements window"

function A.DefaultBinding()
    local d = A.DB()
    if d.boundY or not (SetBinding and GetBindingAction) then return end
    d.boundY = true
    if GetBindingKey and GetBindingKey("ACHIEVEMENTS_TOGGLE") then return end
    local cur = GetBindingAction("Y")
    if cur and cur ~= "" then return end
    if SetBinding("Y", "ACHIEVEMENTS_TOGGLE") and SaveBindings then
        SaveBindings(GetCurrentBindingSet and GetCurrentBindingSet() or 1)
    end
end

local ev = CreateFrame("Frame", "Achievements_Events")
ev:RegisterEvent("VARIABLES_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_LEVEL_UP")
ev:RegisterEvent("PLAYER_MONEY")
ev:RegisterEvent("SKILL_LINES_CHANGED")
ev:RegisterEvent("UPDATE_FACTION")
ev:SetScript("OnEvent", function()
    if event == "VARIABLES_LOADED" then
        A.DB()
    elseif event == "PLAYER_ENTERING_WORLD" then
        A.LoadCache()
        A.DefaultBinding()
        A.Changed("login")
    else
        -- local readings moved (level, gold, skills, reputation): redraw the bars
        A.Changed("local")
    end
end)

-- After the server greets us it sends the list by itself; ask once more if it hasn't come.
local askAt
ev:SetScript("OnUpdate", function()
    if A.synced or not W.connected or not W:IsActive(ID) then return end
    askAt = (askAt or 0) + (arg1 or 0)
    if askAt > 8 then
        askAt = 0
        if A.ServerHas() ~= false then A.RequestList() end
    end
end)
